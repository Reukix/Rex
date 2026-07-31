import CryptoKit
import Foundation

enum SecurityAssetKind: String, Codable, CaseIterable, Sendable {
    case privacyCatalog
    case publicSuffixList

    var filename: String {
        switch self {
        case .privacyCatalog: "privacy_catalog.json"
        case .publicSuffixList: "public_suffix_list.dat"
        }
    }

    var maximumBytes: Int {
        switch self {
        case .privacyCatalog: 1 * 1_024 * 1_024
        case .publicSuffixList: 5 * 1_024 * 1_024
        }
    }
}

struct SecurityAssetDescriptor: Codable, Equatable, Sendable {
    let kind: SecurityAssetKind
    let filename: String
    let version: String
    let size: Int
    let sha256: String
}

struct SecurityAssetControls: Codable, Equatable, Sendable {
    let forceBundledAssets: Bool?
    let rollbackToSequence: Int?
    let revokedSequences: [Int]?
    let suspendRemoteUpdatesUntil: String?

    init(
        forceBundledAssets: Bool? = nil,
        rollbackToSequence: Int? = nil,
        revokedSequences: [Int]? = nil,
        suspendRemoteUpdatesUntil: String? = nil
    ) {
        self.forceBundledAssets = forceBundledAssets
        self.rollbackToSequence = rollbackToSequence
        self.revokedSequences = revokedSequences
        self.suspendRemoteUpdatesUntil = suspendRemoteUpdatesUntil
    }
}

struct SecurityAssetManifest: Codable, Equatable, Sendable {
    static let trustDomain = "com.rex.browser.security-assets"

    let trustDomain: String
    let schemaVersion: Int
    let sequence: Int
    let issuedAt: String
    let expiresAt: String
    let minimumBuild: Int
    let assets: [SecurityAssetDescriptor]
    let controls: SecurityAssetControls?
}

struct SecurityAssetUpdateConfiguration: Equatable, Sendable {
    let endpoint: URL
    let publicKey: Data

    init(endpoint: URL, publicKey: Data) throws {
        _ = try SecurityAssetNetworkPolicy(baseURL: endpoint)
        guard publicKey.count == 32 else {
            throw SecurityAssetError.invalidTrustConfiguration
        }
        self.endpoint = endpoint
        self.publicKey = publicKey
    }

    static func load(from bundle: Bundle) -> SecurityAssetUpdateConfiguration? {
        guard let endpointValue = bundle.object(
            forInfoDictionaryKey: "RexSecurityAssetEndpoint"
        ) as? String,
        let keyValue = bundle.object(
            forInfoDictionaryKey: "RexSecurityAssetPublicKey"
        ) as? String,
        !endpointValue.isEmpty,
        !keyValue.isEmpty,
        !endpointValue.contains("$("),
        !keyValue.contains("$("),
        let endpoint = URL(string: endpointValue),
        let publicKey = Data(base64Encoded: keyValue)
        else {
            return nil
        }
        return try? SecurityAssetUpdateConfiguration(endpoint: endpoint, publicKey: publicKey)
    }
}

struct SecurityAssetNetworkPolicy: Equatable, Sendable {
    private let scheme: String
    private let host: String
    private let port: Int
    private let basePath: String

    init(baseURL: URL) throws {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host?.lowercased(),
              !host.isEmpty,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw SecurityAssetError.invalidTrustConfiguration
        }
        scheme = "https"
        self.host = host
        port = baseURL.port ?? 443
        let path = baseURL.path.isEmpty ? "/" : baseURL.path
        basePath = path.hasSuffix("/") ? path : path + "/"
    }

    func url(for filename: String, relativeTo endpoint: URL) throws -> URL {
        guard SecurityAssetKind.allCases.map(\.filename).contains(filename)
                || filename == "manifest.json"
                || filename == "manifest.sig" else {
            throw SecurityAssetError.invalidManifest
        }
        let url = endpoint.appending(path: filename, directoryHint: .notDirectory)
        guard permits(url) else { throw SecurityAssetError.unsafeNetworkLocation }
        return url
    }

    func permits(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              (url.port ?? 443) == port,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix(basePath),
              !url.path.dropFirst(basePath.count).contains("/") else {
            return false
        }
        return true
    }
}

protocol SecurityAssetFetching: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data
}

struct SecurityAssetHTTPFetcher: SecurityAssetFetching {
    let policy: SecurityAssetNetworkPolicy

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard policy.permits(url) else { throw SecurityAssetError.unsafeNetworkLocation }
        return try await SecurityAssetDownloadDelegate(
            policy: policy,
            maximumBytes: maximumBytes
        ).download(from: url)
    }
}

private final class SecurityAssetDownloadDelegate: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private let policy: SecurityAssetNetworkPolicy
    private let maximumBytes: Int
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var data = Data()
    private var completed = false

    init(policy: SecurityAssetNetworkPolicy, maximumBytes: Int) {
        self.policy = policy
        self.maximumBytes = maximumBytes
    }

    func download(from url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue()
        queue.name = "Rex.SecurityAssetDownload"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                    request.timeoutInterval = 30
                    let task = session.dataTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard policy.permits(request.url) else {
            completionHandler(nil)
            finish(.failure(SecurityAssetError.unsafeNetworkLocation))
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              policy.permits(response.url),
              response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(SecurityAssetError.invalidNetworkResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count <= maximumBytes - bytes.count else {
            finish(.failure(SecurityAssetError.downloadTooLarge))
            dataTask.cancel()
            return
        }
        data.append(bytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if data.isEmpty {
            finish(.failure(SecurityAssetError.invalidNetworkResponse))
        } else {
            finish(.success(data))
        }
    }

    private func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return }
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

struct SecurityAssetSelection: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case bundled
        case signedPackage(sequence: Int)
    }

    let publicSuffixListURL: URL
    let privacyCatalogURL: URL
    let source: Source
}

enum SecurityAssetUpdateResult: Equatable, Sendable {
    case disabled
    case suspended(until: Date)
    case installed(sequence: Int)
}

struct SecurityAssetState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var highestAcceptedSequence = 0
    var activeSequence: Int?
    var candidateSequence: Int?
    var validationPendingSequence: Int?
    var knownGoodSequences: [Int] = []
    var failedValidationSequences: [Int] = []
    var revokedSequences: [Int] = []
    var forceBundledAssets = false
    var rollbackToSequence: Int?
    var suspendRemoteUpdatesUntil: String?
}

@MainActor
final class SecurityAssetManager {
    static let manifestMaximumBytes = 128 * 1_024
    static let signatureMaximumBytes = 256

    private let fileManager: FileManager
    private let rootURL: URL
    private let bundledPublicSuffixListURL: URL
    private let bundledPrivacyCatalogURL: URL
    private let appBuild: Int
    private let minimumPublicSuffixRuleCount: Int
    private let configuration: SecurityAssetUpdateConfiguration?

    private var packagesURL: URL {
        rootURL.appending(path: "packages", directoryHint: .isDirectory)
    }

    private var stateURL: URL {
        rootURL.appending(path: "state.json", directoryHint: .notDirectory)
    }

    init(
        rootURL: URL,
        bundledPublicSuffixListURL: URL,
        bundledPrivacyCatalogURL: URL,
        appBuild: Int,
        configuration: SecurityAssetUpdateConfiguration?,
        minimumPublicSuffixRuleCount: Int = 1_000,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.bundledPublicSuffixListURL = bundledPublicSuffixListURL
        self.bundledPrivacyCatalogURL = bundledPrivacyCatalogURL
        self.appBuild = appBuild
        self.configuration = configuration
        self.minimumPublicSuffixRuleCount = minimumPublicSuffixRuleCount
        self.fileManager = fileManager
    }

    static func applicationManager(
        supportRoot: URL,
        bundle: Bundle = .main
    ) throws -> SecurityAssetManager {
        let publicSuffixURL = bundle.url(
            forResource: "public_suffix_list",
            withExtension: "dat",
            subdirectory: "Privacy"
        ) ?? bundle.url(forResource: "public_suffix_list", withExtension: "dat")
        let privacyCatalogURL = bundle.url(
            forResource: "privacy_catalog",
            withExtension: "json",
            subdirectory: "Privacy"
        ) ?? bundle.url(forResource: "privacy_catalog", withExtension: "json")
        guard let publicSuffixURL, let privacyCatalogURL else {
            throw SecurityAssetError.missingBundledAssets
        }
        return SecurityAssetManager(
            rootURL: supportRoot.appending(path: "SecurityAssets", directoryHint: .isDirectory),
            bundledPublicSuffixListURL: publicSuffixURL,
            bundledPrivacyCatalogURL: privacyCatalogURL,
            appBuild: AppVersion.buildNumber,
            configuration: SecurityAssetUpdateConfiguration.load(from: bundle)
        )
    }

    func bundledSelection() throws -> SecurityAssetSelection {
        try validatePublicSuffixList(at: bundledPublicSuffixListURL)
        try validatePrivacyCatalog(at: bundledPrivacyCatalogURL)
        return SecurityAssetSelection(
            publicSuffixListURL: bundledPublicSuffixListURL,
            privacyCatalogURL: bundledPrivacyCatalogURL,
            source: .bundled
        )
    }

    func prepareForLaunch(now: Date = Date()) throws -> SecurityAssetSelection {
        let bundled = try bundledSelection()
        guard configuration != nil else { return bundled }
        try prepareStorage()
        var state = try loadState()

        if let pending = state.validationPendingSequence {
            state.failedValidationSequences = uniqueSorted(
                state.failedValidationSequences + [pending]
            )
            state.validationPendingSequence = nil
            state.activeSequence = bestKnownGoodSequence(in: state)
        }

        if state.forceBundledAssets {
            state.activeSequence = nil
            state.candidateSequence = nil
            try saveState(state)
            return bundled
        }

        if let rollback = state.rollbackToSequence {
            state.candidateSequence = nil
            if state.knownGoodSequences.contains(rollback),
               !state.revokedSequences.contains(rollback),
               let selection = try? selection(for: rollback, now: now) {
                state.activeSequence = rollback
                state.validationPendingSequence = nil
                try saveState(state)
                return selection
            }
            state.activeSequence = nil
            try saveState(state)
            return bundled
        }

        if let candidate = state.candidateSequence,
           !state.revokedSequences.contains(candidate),
           !state.failedValidationSequences.contains(candidate) {
            do {
                let selection = try selection(for: candidate, now: now)
                state.activeSequence = candidate
                state.candidateSequence = nil
                state.validationPendingSequence = candidate
                try saveState(state)
                return selection
            } catch {
                state.failedValidationSequences = uniqueSorted(
                    state.failedValidationSequences + [candidate]
                )
            }
        }
        state.candidateSequence = nil

        if let active = state.activeSequence,
           state.knownGoodSequences.contains(active),
           !state.revokedSequences.contains(active),
           let selection = try? selection(for: active, now: now) {
            try saveState(state)
            return selection
        }

        state.activeSequence = bestKnownGoodSequence(in: state)
        if let fallback = state.activeSequence,
           let selection = try? selection(for: fallback, now: now) {
            try saveState(state)
            return selection
        }
        state.activeSequence = nil
        try saveState(state)
        return bundled
    }

    func markLaunchHealthy() throws {
        guard configuration != nil else { return }
        var state = try loadState()
        guard let pending = state.validationPendingSequence,
              pending == state.activeSequence else { return }
        state.knownGoodSequences = uniqueSorted(state.knownGoodSequences + [pending])
        state.failedValidationSequences.removeAll { $0 == pending }
        state.validationPendingSequence = nil
        try saveState(state)
    }

    func rollbackFailedLaunch() throws {
        guard configuration != nil else { return }
        var state = try loadState()
        if let pending = state.validationPendingSequence {
            state.failedValidationSequences = uniqueSorted(
                state.failedValidationSequences + [pending]
            )
        }
        state.validationPendingSequence = nil
        state.activeSequence = bestKnownGoodSequence(in: state)
        try saveState(state)
    }

    func deferLaunchValidation() throws {
        guard configuration != nil else { return }
        var state = try loadState()
        if let pending = state.validationPendingSequence {
            state.candidateSequence = pending
        }
        state.validationPendingSequence = nil
        state.activeSequence = bestKnownGoodSequence(in: state)
        try saveState(state)
    }

    @discardableResult
    func installPackage(from packageURL: URL, now: Date = Date()) throws -> Int {
        guard let configuration else { throw SecurityAssetError.updatesDisabled }
        try prepareStorage()
        var state = try loadState()
        let validated = try validatePackage(
            at: packageURL,
            publicKey: configuration.publicKey,
            now: now,
            enforceFreshness: true
        )
        guard validated.manifest.sequence > state.highestAcceptedSequence else {
            throw SecurityAssetError.downgradeRejected(
                highest: state.highestAcceptedSequence,
                received: validated.manifest.sequence
            )
        }

        let destination = packageDirectory(for: validated.manifest.sequence)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try validatePackage(
                at: destination,
                publicKey: configuration.publicKey,
                now: now,
                enforceFreshness: true
            )
            guard existing.manifest == validated.manifest else {
                throw SecurityAssetError.packageAlreadyExists
            }
        } else {
            let staging = packagesURL.appending(
                path: ".incoming-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                for filename in validated.filenames {
                    try fileManager.copyItem(
                        at: packageURL.appending(path: filename),
                        to: staging.appending(path: filename)
                    )
                }
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }

        state.highestAcceptedSequence = validated.manifest.sequence
        apply(controls: validated.manifest.controls, to: &state, now: now)
        if !state.forceBundledAssets,
           state.rollbackToSequence == nil,
           !state.revokedSequences.contains(validated.manifest.sequence) {
            state.candidateSequence = validated.manifest.sequence
        } else {
            state.candidateSequence = nil
        }
        if let active = state.activeSequence,
           state.revokedSequences.contains(active) {
            state.activeSequence = bestKnownGoodSequence(in: state)
        }
        try saveState(state)
        return validated.manifest.sequence
    }

    func checkForUpdates(
        now: Date = Date(),
        fetcher: (any SecurityAssetFetching)? = nil
    ) async throws -> SecurityAssetUpdateResult {
        guard let configuration else { return .disabled }
        try prepareStorage()
        let state = try loadState()
        if let rawUntil = state.suspendRemoteUpdatesUntil,
           let until = Self.parseTimestamp(rawUntil),
           until > now {
            return .suspended(until: until)
        }

        let policy = try SecurityAssetNetworkPolicy(baseURL: configuration.endpoint)
        let fetcher = fetcher ?? SecurityAssetHTTPFetcher(policy: policy)
        let manifestURL = try policy.url(for: "manifest.json", relativeTo: configuration.endpoint)
        let signatureURL = try policy.url(for: "manifest.sig", relativeTo: configuration.endpoint)
        async let manifestFetch = fetcher.fetch(
            manifestURL,
            maximumBytes: Self.manifestMaximumBytes
        )
        async let signatureFetch = fetcher.fetch(
            signatureURL,
            maximumBytes: Self.signatureMaximumBytes
        )
        let (manifestData, signatureData) = try await (manifestFetch, signatureFetch)
        let manifest = try verifyAndDecodeManifest(
            manifestData: manifestData,
            signatureData: signatureData,
            publicKey: configuration.publicKey,
            now: now,
            enforceFreshness: true
        )
        guard manifest.sequence > state.highestAcceptedSequence else {
            throw SecurityAssetError.downgradeRejected(
                highest: state.highestAcceptedSequence,
                received: manifest.sequence
            )
        }

        let incoming = rootURL.appending(
            path: ".download-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: incoming,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: incoming) }
        try manifestData.write(to: incoming.appending(path: "manifest.json"), options: .withoutOverwriting)
        try signatureData.write(to: incoming.appending(path: "manifest.sig"), options: .withoutOverwriting)
        for asset in manifest.assets {
            let url = try policy.url(for: asset.filename, relativeTo: configuration.endpoint)
            let data = try await fetcher.fetch(url, maximumBytes: asset.kind.maximumBytes)
            try data.write(to: incoming.appending(path: asset.filename), options: .withoutOverwriting)
        }
        let sequence = try installPackage(from: incoming, now: now)
        return .installed(sequence: sequence)
    }

    func stateSnapshot() throws -> SecurityAssetState {
        try loadState()
    }

    private func selection(for sequence: Int, now: Date) throws -> SecurityAssetSelection {
        guard let configuration else { throw SecurityAssetError.updatesDisabled }
        let package = packageDirectory(for: sequence)
        let validated = try validatePackage(
            at: package,
            publicKey: configuration.publicKey,
            now: now,
            enforceFreshness: false
        )
        guard validated.manifest.sequence == sequence else {
            throw SecurityAssetError.invalidManifest
        }
        return SecurityAssetSelection(
            publicSuffixListURL: package.appending(path: SecurityAssetKind.publicSuffixList.filename),
            privacyCatalogURL: package.appending(path: SecurityAssetKind.privacyCatalog.filename),
            source: .signedPackage(sequence: sequence)
        )
    }

    private func validatePackage(
        at packageURL: URL,
        publicKey: Data,
        now: Date,
        enforceFreshness: Bool
    ) throws -> (manifest: SecurityAssetManifest, filenames: Set<String>) {
        let values = try packageURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SecurityAssetError.unsafePackage
        }
        let entries = try fileManager.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let filenames = Set(entries.map(\.lastPathComponent))
        let expected = Set(["manifest.json", "manifest.sig"] + SecurityAssetKind.allCases.map(\.filename))
        guard filenames == expected else { throw SecurityAssetError.unsafePackage }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SecurityAssetError.unsafePackage
            }
        }

        let manifestData = try boundedData(
            at: packageURL.appending(path: "manifest.json"),
            maximumBytes: Self.manifestMaximumBytes
        )
        let signatureData = try boundedData(
            at: packageURL.appending(path: "manifest.sig"),
            maximumBytes: Self.signatureMaximumBytes
        )
        let manifest = try verifyAndDecodeManifest(
            manifestData: manifestData,
            signatureData: signatureData,
            publicKey: publicKey,
            now: now,
            enforceFreshness: enforceFreshness
        )
        for descriptor in manifest.assets {
            let url = packageURL.appending(path: descriptor.filename)
            let data = try boundedData(at: url, maximumBytes: descriptor.kind.maximumBytes)
            guard data.count == descriptor.size,
                  Self.sha256Hex(data) == descriptor.sha256 else {
                throw SecurityAssetError.assetDigestMismatch(descriptor.kind)
            }
            switch descriptor.kind {
            case .publicSuffixList:
                try validatePublicSuffixList(data: data)
            case .privacyCatalog:
                try validatePrivacyCatalog(data: data)
            }
        }
        return (manifest, filenames)
    }

    private func verifyAndDecodeManifest(
        manifestData: Data,
        signatureData: Data,
        publicKey: Data,
        now: Date,
        enforceFreshness: Bool
    ) throws -> SecurityAssetManifest {
        let signatureText = String(decoding: signatureData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: manifestData) else {
            throw SecurityAssetError.invalidSignature
        }
        try validateManifestJSONShape(manifestData)
        let manifest: SecurityAssetManifest
        do {
            manifest = try JSONDecoder().decode(SecurityAssetManifest.self, from: manifestData)
        } catch {
            throw SecurityAssetError.invalidManifest
        }
        guard manifest.trustDomain == SecurityAssetManifest.trustDomain,
              manifest.schemaVersion == 1,
              manifest.sequence > 0,
              manifest.minimumBuild > 0,
              manifest.minimumBuild <= appBuild,
              let issuedAt = Self.parseTimestamp(manifest.issuedAt),
              let expiresAt = Self.parseTimestamp(manifest.expiresAt),
              issuedAt <= now.addingTimeInterval(5 * 60),
              expiresAt > issuedAt else {
            throw SecurityAssetError.invalidManifest
        }
        if enforceFreshness, expiresAt <= now {
            throw SecurityAssetError.expiredManifest
        }
        guard manifest.assets.count == SecurityAssetKind.allCases.count,
              Set(manifest.assets.map(\.kind)) == Set(SecurityAssetKind.allCases),
              Set(manifest.assets.map(\.filename)).count == manifest.assets.count else {
            throw SecurityAssetError.invalidManifest
        }
        for asset in manifest.assets {
            guard asset.filename == asset.kind.filename,
                  !asset.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...asset.kind.maximumBytes).contains(asset.size),
                  asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw SecurityAssetError.invalidManifest
            }
        }
        let controls = manifest.controls
        let revoked = controls?.revokedSequences ?? []
        guard Set(revoked).count == revoked.count,
              revoked.allSatisfy({ $0 > 0 }),
              !(controls?.forceBundledAssets == true && controls?.rollbackToSequence != nil),
              !(controls?.rollbackToSequence.map(revoked.contains) ?? false) else {
            throw SecurityAssetError.invalidManifest
        }
        if let until = controls?.suspendRemoteUpdatesUntil,
           Self.parseTimestamp(until) == nil {
            throw SecurityAssetError.invalidManifest
        }
        return manifest
    }

    private func validateManifestJSONShape(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SecurityAssetError.invalidManifest
        }
        let allowed = Set([
            "trustDomain", "schemaVersion", "sequence", "issuedAt", "expiresAt",
            "minimumBuild", "assets", "controls"
        ])
        guard Set(object.keys).isSubset(of: allowed),
              let assets = object["assets"] as? [[String: Any]] else {
            throw SecurityAssetError.invalidManifest
        }
        let assetKeys = Set(["kind", "filename", "version", "size", "sha256"])
        guard assets.allSatisfy({ Set($0.keys) == assetKeys }) else {
            throw SecurityAssetError.invalidManifest
        }
        if let controls = object["controls"] as? [String: Any] {
            let controlKeys = Set([
                "forceBundledAssets", "rollbackToSequence", "revokedSequences",
                "suspendRemoteUpdatesUntil"
            ])
            guard Set(controls.keys).isSubset(of: controlKeys) else {
                throw SecurityAssetError.invalidManifest
            }
        }
    }

    private func apply(
        controls: SecurityAssetControls?,
        to state: inout SecurityAssetState,
        now: Date
    ) {
        state.forceBundledAssets = controls?.forceBundledAssets ?? false
        state.rollbackToSequence = controls?.rollbackToSequence
        state.revokedSequences = uniqueSorted(controls?.revokedSequences ?? [])
        if let rawUntil = controls?.suspendRemoteUpdatesUntil,
           let until = Self.parseTimestamp(rawUntil),
           until > now {
            state.suspendRemoteUpdatesUntil = rawUntil
        } else {
            state.suspendRemoteUpdatesUntil = nil
        }
        state.knownGoodSequences.removeAll { state.revokedSequences.contains($0) }
    }

    private func validatePublicSuffixList(at url: URL) throws {
        try validatePublicSuffixList(data: boundedData(
            at: url,
            maximumBytes: SecurityAssetKind.publicSuffixList.maximumBytes
        ))
    }

    private func validatePublicSuffixList(data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw SecurityAssetError.invalidPublicSuffixList
        }
        do {
            _ = try PublicSuffixList.parseValidated(
                source,
                minimumRuleCount: minimumPublicSuffixRuleCount
            )
        } catch {
            throw SecurityAssetError.invalidPublicSuffixList
        }
    }

    private func validatePrivacyCatalog(at url: URL) throws {
        try validatePrivacyCatalog(data: boundedData(
            at: url,
            maximumBytes: SecurityAssetKind.privacyCatalog.maximumBytes
        ))
    }

    private func validatePrivacyCatalog(data: Data) throws {
        struct Catalog: Decodable {
            let schemaVersion: Int
            let catalogVersion: String
            let advertising: [String]
            let tracking: [String]
            let fingerprinting: [String]
            let social: [String]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                "schemaVersion", "catalogVersion", "advertising", "tracking",
                "fingerprinting", "social"
              ]),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.schemaVersion == 1,
              !catalog.catalogVersion.isEmpty else {
            throw SecurityAssetError.invalidPrivacyCatalog
        }
        let groups = [
            catalog.advertising,
            catalog.tracking,
            catalog.fingerprinting,
            catalog.social
        ]
        guard groups.allSatisfy({ !$0.isEmpty && $0.count <= 100_000 }) else {
            throw SecurityAssetError.invalidPrivacyCatalog
        }
        for group in groups {
            guard Set(group).count == group.count,
                  group.allSatisfy(Self.isValidCatalogRule) else {
                throw SecurityAssetError.invalidPrivacyCatalog
            }
        }
    }

    private static func isValidCatalogRule(_ value: String) -> Bool {
        guard value == value.lowercased(),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 512,
              !value.isEmpty,
              !value.contains(":"),
              !value.contains("\\"),
              !value.contains("..") else { return false }
        let pieces = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(pieces[0])
        guard !host.isEmpty,
              host.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty
                      && label.first != "-"
                      && label.last != "-"
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else { return false }
        return pieces.count == 1 || (!pieces[1].isEmpty && !pieces[1].contains("//"))
    }

    private func prepareStorage() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SecurityAssetError.unsafeStorage
            }
        } else {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if fileManager.fileExists(atPath: packagesURL.path) {
            let values = try packagesURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SecurityAssetError.unsafeStorage
            }
        } else {
            try fileManager.createDirectory(
                at: packagesURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func loadState() throws -> SecurityAssetState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return SecurityAssetState()
        }
        let data = try boundedData(at: stateURL, maximumBytes: 256 * 1_024)
        let state: SecurityAssetState
        do {
            state = try JSONDecoder().decode(SecurityAssetState.self, from: data)
        } catch {
            throw SecurityAssetError.invalidState
        }
        guard state.schemaVersion == 1,
              state.highestAcceptedSequence >= 0,
              state.knownGoodSequences.allSatisfy({ $0 > 0 }),
              state.failedValidationSequences.allSatisfy({ $0 > 0 }),
              state.revokedSequences.allSatisfy({ $0 > 0 }) else {
            throw SecurityAssetError.invalidState
        }
        return state
    }

    private func saveState(_ state: SecurityAssetState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func bestKnownGoodSequence(in state: SecurityAssetState) -> Int? {
        state.knownGoodSequences
            .filter { !state.revokedSequences.contains($0) }
            .max()
    }

    private func packageDirectory(for sequence: Int) -> URL {
        packagesURL.appending(path: String(sequence), directoryHint: .isDirectory)
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              (1...maximumBytes).contains(fileSize) else {
            throw SecurityAssetError.downloadTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == fileSize else { throw SecurityAssetError.unsafePackage }
        return data
    }

    private func uniqueSorted(_ values: [Int]) -> [Int] {
        Array(Set(values)).sorted()
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum SecurityAssetError: Error, Equatable {
    case invalidTrustConfiguration
    case missingBundledAssets
    case updatesDisabled
    case unsafeNetworkLocation
    case invalidNetworkResponse
    case downloadTooLarge
    case unsafeStorage
    case unsafePackage
    case invalidSignature
    case invalidManifest
    case expiredManifest
    case invalidPublicSuffixList
    case invalidPrivacyCatalog
    case assetDigestMismatch(SecurityAssetKind)
    case downgradeRejected(highest: Int, received: Int)
    case packageAlreadyExists
    case invalidState
}
