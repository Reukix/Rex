import CryptoKit
import Foundation
import Security
import zlib

enum BrowserExtensionCatalogInstallPhase: String, Codable, Sendable {
    case downloading
    case verifying
    case extracting
    case importing
    case installed
    case failed
}

struct BrowserExtensionCatalogInstallState: Equatable, Sendable {
    let extensionID: String
    var phase: BrowserExtensionCatalogInstallPhase
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64?
    var message: String

    var progress: Double? {
        guard phase == .downloading,
              let expectedBytes,
              expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    var requiresRestart: Bool {
        false
    }
}

protocol ChromeWebStorePackageFetching: Sendable {
    func fetchPackage(
        extensionID: String,
        destinationURL: URL,
        progress: @escaping @Sendable (_ receivedBytes: Int64, _ expectedBytes: Int64?) -> Void
    ) async throws
}

struct ChromeWebStorePackageFetcher: ChromeWebStorePackageFetching {
    static let maximumDownloadBytes: Int64 = 256 * 1_024 * 1_024

    func fetchPackage(
        extensionID: String,
        destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        guard let requestURL = ChromeWebStoreDownloadPolicy.downloadURL(extensionID: extensionID) else {
            throw ChromeWebStoreInstallError.invalidCatalogItem
        }
        let delegate = ChromeWebStoreDownloadDelegate(
            destinationURL: destinationURL,
            maximumBytes: Self.maximumDownloadBytes,
            progress: progress
        )
        try await delegate.download(from: requestURL)
    }
}

enum ChromeWebStoreDownloadPolicy {
    static let updateHost = "clients2.google.com"
    static let packageHost = "clients2.googleusercontent.com"
    static let allowedHosts: Set<String> = [updateHost, packageHost]

    static func downloadURL(extensionID: String) -> URL? {
        guard BrowserExtensionCatalog.isValidChromeExtensionID(extensionID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = updateHost
        components.path = "/service/update2/crx"
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "150.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(extensionID)&installsource=ondemand&uc")
        ]
        return components.url
    }

    static func permits(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else { return false }
        return true
    }
}

private final class ChromeWebStoreDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64?
    private var completed = false
    private var lastProgressUpdateNanoseconds: UInt64 = 0

    private static let progressUpdateIntervalNanoseconds: UInt64 = 80_000_000

    init(
        destinationURL: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
        self.destinationURL = destinationURL
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    func download(from url: URL) async throws {
        guard ChromeWebStoreDownloadPolicy.permits(url) else {
            throw ChromeWebStoreInstallError.unsafeDownloadURL
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ChromeWebStoreInstallError.unsafeStagingDirectory
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ChromeWebStoreInstallError.cannotCreateDownload
        }
        fileHandle = try FileHandle(forWritingTo: destinationURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue()
        queue.name = "Rex.ChromeWebStoreDownload"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        self.continuation = continuation
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                        request.timeoutInterval = 60
                        let task = session.dataTask(with: request)
                        self.task = task
                        task.resume()
                    }
                }
            } onCancel: {
                self.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard ChromeWebStoreDownloadPolicy.permits(request.url) else {
            completionHandler(nil)
            finish(.failure(ChromeWebStoreInstallError.unsafeRedirect))
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
              ChromeWebStoreDownloadPolicy.permits(response.url) else {
            completionHandler(.cancel)
            finish(.failure(ChromeWebStoreInstallError.invalidDownloadResponse))
            return
        }
        let length = response.expectedContentLength
        guard length <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(ChromeWebStoreInstallError.downloadTooLarge(maximumBytes)))
            return
        }
        expectedBytes = length > 0 ? length : nil
        reportProgress(force: true)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (nextSize, overflowed) = receivedBytes.addingReportingOverflow(Int64(data.count))
        guard !overflowed, nextSize <= maximumBytes else {
            finish(.failure(ChromeWebStoreInstallError.downloadTooLarge(maximumBytes)))
            dataTask.cancel()
            return
        }
        do {
            try fileHandle?.write(contentsOf: data)
            receivedBytes = nextSize
            reportProgress()
        } catch {
            finish(.failure(ChromeWebStoreInstallError.cannotWriteDownload))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if receivedBytes == 0 {
            finish(.failure(ChromeWebStoreInstallError.emptyDownload))
        } else {
            reportProgress(force: true)
            finish(.success(()))
        }
    }

    private func reportProgress(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force
                || lastProgressUpdateNanoseconds == 0
                || now &- lastProgressUpdateNanoseconds >= Self.progressUpdateIntervalNanoseconds
        else {
            return
        }
        lastProgressUpdateNanoseconds = now
        progress(receivedBytes, expectedBytes)
    }

    private func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return }
        try? fileHandle?.close()
        fileHandle = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

struct VerifiedChromeExtensionArchive: Sendable {
    let crxURL: URL
    let zipOffset: Int
    let zipLength: Int
    let extensionID: String
    let publicKey: Data
}

enum ChromeExtensionArchiveVerifier {
    private static let magic = Data([0x43, 0x72, 0x32, 0x34])
    private static let crx3Context = Data("CRX3 SignedData\0".utf8)
    private static let maximumHeaderBytes = 1 * 1_024 * 1_024
    private static let maximumProofCount = 32

    private struct VerifiedPayload {
        let zipOffset: Int
        let publicKey: Data
    }

    static func verify(
        crxAt url: URL,
        expectedExtensionID: String,
        maximumBytes: Int64 = ChromeWebStorePackageFetcher.maximumDownloadBytes
    ) throws -> VerifiedChromeExtensionArchive {
        guard BrowserExtensionCatalog.isValidChromeExtensionID(expectedExtensionID) else {
            throw ChromeWebStoreInstallError.invalidCatalogItem
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        let fileSize = Int64(values.fileSize ?? -1)
        guard fileSize > 0, fileSize <= maximumBytes else {
            throw ChromeWebStoreInstallError.downloadTooLarge(maximumBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12, data.prefix(4) == magic else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        let version = try data.littleEndianUInt32(at: 4)
        let payload: VerifiedPayload
        switch version {
        case 2:
            payload = try verifyCRX2(data, expectedExtensionID: expectedExtensionID)
        case 3:
            payload = try verifyCRX3(data, expectedExtensionID: expectedExtensionID)
        default:
            throw ChromeWebStoreInstallError.unsupportedCRXVersion(version)
        }
        guard extensionID(forPublicKey: payload.publicKey) == expectedExtensionID else {
            throw ChromeWebStoreInstallError.extensionIDMismatch
        }
        let zipOffset = payload.zipOffset
        guard zipOffset < data.count,
              data[zipOffset..<min(zipOffset + 4, data.count)] == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        return VerifiedChromeExtensionArchive(
            crxURL: url,
            zipOffset: zipOffset,
            zipLength: data.count - zipOffset,
            extensionID: expectedExtensionID,
            publicKey: payload.publicKey
        )
    }

    private static func verifyCRX2(
        _ data: Data,
        expectedExtensionID: String
    ) throws -> VerifiedPayload {
        guard data.count >= 16 else { throw ChromeWebStoreInstallError.invalidCRX }
        let publicKeyLength = try Int(exactly: data.littleEndianUInt32(at: 8))
            .unwrapped(or: ChromeWebStoreInstallError.invalidCRX)
        let signatureLength = try Int(exactly: data.littleEndianUInt32(at: 12))
            .unwrapped(or: ChromeWebStoreInstallError.invalidCRX)
        let publicKeyStart = 16
        let signatureStart = try checkedAdd(publicKeyStart, publicKeyLength)
        let zipOffset = try checkedAdd(signatureStart, signatureLength)
        guard publicKeyLength > 0, signatureLength > 0, zipOffset < data.count else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        let publicKey = Data(data[publicKeyStart..<signatureStart])
        let signature = Data(data[signatureStart..<zipOffset])
        try verifyIdentity(publicKey: publicKey, expectedExtensionID: expectedExtensionID)

        var hasher = Insecure.SHA1()
        hasher.update(data: data[zipOffset...])
        let digest = Data(hasher.finalize())
        let key = try makeSecurityKey(publicKey: publicKey, kind: .rsa)
        guard SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureDigestPKCS1v15SHA1),
              SecKeyVerifySignature(
                  key,
                  .rsaSignatureDigestPKCS1v15SHA1,
                  digest as CFData,
                  signature as CFData,
                  nil
              ) else {
            throw ChromeWebStoreInstallError.invalidCRXSignature
        }
        return VerifiedPayload(zipOffset: zipOffset, publicKey: publicKey)
    }

    private static func verifyCRX3(
        _ data: Data,
        expectedExtensionID: String
    ) throws -> VerifiedPayload {
        let headerLength = try Int(exactly: data.littleEndianUInt32(at: 8))
            .unwrapped(or: ChromeWebStoreInstallError.invalidCRX)
        guard headerLength > 0, headerLength <= maximumHeaderBytes else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        let headerEnd = try checkedAdd(12, headerLength)
        guard headerEnd < data.count else { throw ChromeWebStoreInstallError.invalidCRX }
        let header = Data(data[12..<headerEnd])
        let parsed = try parseCRX3Header(header)
        let expectedIDBytes = try extensionIDBytes(expectedExtensionID)
        guard parsed.crxID == expectedIDBytes else {
            throw ChromeWebStoreInstallError.extensionIDMismatch
        }

        var digest = SHA256()
        digest.update(data: crx3Context)
        var signedHeaderLength = UInt32(parsed.signedHeaderData.count).littleEndian
        withUnsafeBytes(of: &signedHeaderLength) { digest.update(bufferPointer: $0) }
        digest.update(data: parsed.signedHeaderData)
        digest.update(data: data[headerEnd...])
        let signedDigest = Data(digest.finalize())

        var foundIdentityProof = false
        for proof in parsed.proofs {
            guard extensionID(forPublicKey: proof.publicKey) == expectedExtensionID else { continue }
            foundIdentityProof = true
            let key: SecKey
            do {
                key = try makeSecurityKey(publicKey: proof.publicKey, kind: proof.kind)
            } catch {
                continue
            }
            let algorithm: SecKeyAlgorithm = proof.kind == .rsa
                ? .rsaSignatureDigestPKCS1v15SHA256
                : .ecdsaSignatureDigestX962SHA256
            guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { continue }
            if SecKeyVerifySignature(
                key,
                algorithm,
                signedDigest as CFData,
                proof.signature as CFData,
                nil
            ) {
                return VerifiedPayload(zipOffset: headerEnd, publicKey: proof.publicKey)
            }
        }
        if !foundIdentityProof {
            throw ChromeWebStoreInstallError.extensionIDMismatch
        }
        throw ChromeWebStoreInstallError.invalidCRXSignature
    }

    private static func parseCRX3Header(_ data: Data) throws -> CRX3Header {
        var reader = ProtobufReader(data)
        var proofs: [CRX3Proof] = []
        var signedHeaderData: Data?
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (2, .bytes(let proofData)):
                proofs.append(try parseProof(proofData, kind: .rsa))
            case (3, .bytes(let proofData)):
                proofs.append(try parseProof(proofData, kind: .ecdsa))
            case (10_000, .bytes(let value)):
                guard signedHeaderData == nil else { throw ChromeWebStoreInstallError.invalidCRX }
                signedHeaderData = value
            default:
                continue
            }
            guard proofs.count <= maximumProofCount else {
                throw ChromeWebStoreInstallError.invalidCRX
            }
        }
        guard let signedHeaderData, !proofs.isEmpty else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        var signedReader = ProtobufReader(signedHeaderData)
        var crxID: Data?
        while let field = try signedReader.nextField() {
            if case (1, .bytes(let value)) = (field.number, field.value) {
                guard crxID == nil else { throw ChromeWebStoreInstallError.invalidCRX }
                crxID = value
            }
        }
        guard let crxID, crxID.count == 16 else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        return CRX3Header(proofs: proofs, signedHeaderData: signedHeaderData, crxID: crxID)
    }

    private static func parseProof(_ data: Data, kind: CRX3KeyKind) throws -> CRX3Proof {
        var reader = ProtobufReader(data)
        var publicKey: Data?
        var signature: Data?
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (1, .bytes(let value)):
                guard publicKey == nil else { throw ChromeWebStoreInstallError.invalidCRX }
                publicKey = value
            case (2, .bytes(let value)):
                guard signature == nil else { throw ChromeWebStoreInstallError.invalidCRX }
                signature = value
            default:
                continue
            }
        }
        guard let publicKey, !publicKey.isEmpty,
              let signature, !signature.isEmpty else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        return CRX3Proof(kind: kind, publicKey: publicKey, signature: signature)
    }

    private static func verifyIdentity(publicKey: Data, expectedExtensionID: String) throws {
        guard extensionID(forPublicKey: publicKey) == expectedExtensionID else {
            throw ChromeWebStoreInstallError.extensionIDMismatch
        }
    }

    static func extensionID(forPublicKey publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).flatMap { byte in
            [Character(UnicodeScalar(97 + Int(byte >> 4))!), Character(UnicodeScalar(97 + Int(byte & 0x0f))!)]
        }.reduce(into: "") { $0.append($1) }
    }

    static func extensionIDBytes(_ extensionID: String) throws -> Data {
        guard BrowserExtensionCatalog.isValidChromeExtensionID(extensionID) else {
            throw ChromeWebStoreInstallError.invalidCatalogItem
        }
        let scalars = Array(extensionID.utf8)
        var result = Data(capacity: 16)
        for index in stride(from: 0, to: scalars.count, by: 2) {
            result.append(((scalars[index] - 97) << 4) | (scalars[index + 1] - 97))
        }
        return result
    }

    private static func makeSecurityKey(publicKey: Data, kind: CRX3KeyKind) throws -> SecKey {
        let rawKey = try DERSubjectPublicKeyInfo.unwrap(publicKey)
        let keyType = kind == .rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: keyType,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(rawKey as CFData, attributes as CFDictionary, &error) else {
            throw ChromeWebStoreInstallError.invalidPublicKey
        }
        return key
    }

    private static func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflowed) = left.addingReportingOverflow(right)
        guard !overflowed else { throw ChromeWebStoreInstallError.invalidCRX }
        return value
    }

    private struct CRX3Header {
        let proofs: [CRX3Proof]
        let signedHeaderData: Data
        let crxID: Data
    }

    private struct CRX3Proof {
        let kind: CRX3KeyKind
        let publicKey: Data
        let signature: Data
    }

    private enum CRX3KeyKind {
        case rsa
        case ecdsa
    }
}

enum ChromeExtensionManifestIdentity {
    static let maximumManifestBytes = 2 * 1_024 * 1_024

    static func ensurePublicKey(
        in extensionDirectoryURL: URL,
        expectedExtensionID: String,
        publicKey: Data
    ) throws {
        guard BrowserExtensionCatalog.isValidChromeExtensionID(expectedExtensionID),
              !publicKey.isEmpty,
              ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
                == expectedExtensionID else {
            throw ChromeWebStoreInstallError.extensionIDMismatch
        }

        let directoryURL = extensionDirectoryURL.standardizedFileURL
        let directoryValues: URLResourceValues
        do {
            directoryValues = try directoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
        } catch {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        guard directoryURL.isFileURL,
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              directoryURL.resolvingSymlinksInPath().standardizedFileURL == directoryURL else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }

        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        var manifest = try loadManifest(at: manifestURL)
        if try hasValidPublicKey(in: manifest, expectedExtensionID: expectedExtensionID) {
            return
        }

        manifest["key"] = publicKey.base64EncodedString()
        guard JSONSerialization.isValidJSONObject(manifest),
              let encodedManifest = try? JSONSerialization.data(
                  withJSONObject: manifest,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              encodedManifest.count <= maximumManifestBytes else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        do {
            try encodedManifest.write(to: manifestURL, options: .atomic)
        } catch {
            throw ChromeWebStoreInstallError.cannotWriteExtensionManifest
        }

        let persistedManifest = try loadManifest(at: manifestURL)
        guard try hasValidPublicKey(
            in: persistedManifest,
            expectedExtensionID: expectedExtensionID
        ) else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
    }

    private static func loadManifest(at url: URL) throws -> [String: Any] {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
        } catch {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumManifestBytes else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        return manifest
    }

    private static func hasValidPublicKey(
        in manifest: [String: Any],
        expectedExtensionID: String
    ) throws -> Bool {
        guard let value = manifest["key"] else { return false }
        guard let encodedKey = value as? String else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        let trimmedKey = encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let decodedKey = Data(base64Encoded: trimmedKey) else {
            throw ChromeWebStoreInstallError.invalidExtensionManifest
        }
        guard ChromeExtensionArchiveVerifier.extensionID(forPublicKey: decodedKey)
                == expectedExtensionID else {
            throw ChromeWebStoreInstallError.extensionIDMismatch
        }
        return true
    }
}

enum ChromeExtensionZIPExtractor {
    static let maximumEntryCount = 10_000
    static let maximumUncompressedBytes: UInt64 = 256 * 1_024 * 1_024

    static func extract(
        _ archive: VerifiedChromeExtensionArchive,
        to destinationURL: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ChromeWebStoreInstallError.unsafeStagingDirectory
        }
        let crxData = try Data(contentsOf: archive.crxURL, options: .mappedIfSafe)
        let (zipEnd, overflowed) = archive.zipOffset.addingReportingOverflow(archive.zipLength)
        guard archive.zipOffset >= 0,
              archive.zipLength > 0,
              !overflowed,
              zipEnd <= crxData.count else {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        let zipData = Data(crxData[archive.zipOffset..<zipEnd])
        let entries = try parseEntries(zipData)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        do {
            for entry in entries {
                try extract(entry, zipData: zipData, destinationRoot: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func parseEntries(_ data: Data) throws -> [ZIPEntry] {
        let eocdOffset = try locateEndOfCentralDirectory(data)
        let diskNumber = try data.littleEndianUInt16(at: eocdOffset + 4)
        let centralDisk = try data.littleEndianUInt16(at: eocdOffset + 6)
        let diskEntries = try data.littleEndianUInt16(at: eocdOffset + 8)
        let totalEntries = try data.littleEndianUInt16(at: eocdOffset + 10)
        let centralSize = try Int(data.littleEndianUInt32(at: eocdOffset + 12))
        let centralOffset = try Int(data.littleEndianUInt32(at: eocdOffset + 16))
        guard diskNumber == 0, centralDisk == 0, diskEntries == totalEntries,
              totalEntries != UInt16.max,
              centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max),
              Int(totalEntries) <= maximumEntryCount,
              centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize == eocdOffset else {
            throw ChromeWebStoreInstallError.unsupportedZIP
        }

        var cursor = centralOffset
        var entries: [ZIPEntry] = []
        var names = Set<String>()
        var localOffsets = Set<Int>()
        var totalUncompressed: UInt64 = 0
        for _ in 0..<Int(totalEntries) {
            guard try data.littleEndianUInt32(at: cursor) == 0x0201_4b50,
                  cursor + 46 <= eocdOffset else {
                throw ChromeWebStoreInstallError.invalidZIP
            }
            let versionMadeBy = try data.littleEndianUInt16(at: cursor + 4)
            let flags = try data.littleEndianUInt16(at: cursor + 8)
            let method = try data.littleEndianUInt16(at: cursor + 10)
            let checksum = try data.littleEndianUInt32(at: cursor + 16)
            let compressedSize = try Int(data.littleEndianUInt32(at: cursor + 20))
            let uncompressedSize = try Int(data.littleEndianUInt32(at: cursor + 24))
            let nameLength = try Int(data.littleEndianUInt16(at: cursor + 28))
            let extraLength = try Int(data.littleEndianUInt16(at: cursor + 30))
            let commentLength = try Int(data.littleEndianUInt16(at: cursor + 32))
            let startingDisk = try data.littleEndianUInt16(at: cursor + 34)
            let externalAttributes = try data.littleEndianUInt32(at: cursor + 38)
            let localOffset = try Int(data.littleEndianUInt32(at: cursor + 42))
            let recordEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard recordEnd <= eocdOffset,
                  startingDisk == 0,
                  flags & 0x0001 == 0,
                  flags & 0x0040 == 0,
                  [UInt16(0), UInt16(8)].contains(method),
                  compressedSize >= 0, uncompressedSize >= 0,
                  localOffsets.insert(localOffset).inserted else {
                throw ChromeWebStoreInstallError.unsupportedZIP
            }
            let nameData = Data(data[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(data: nameData, encoding: .utf8),
                  isSafeArchivePath(name),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ChromeWebStoreInstallError.unsafeArchivePath
            }
            let isDirectory = name.hasSuffix("/")
            if versionMadeBy >> 8 == 3 {
                let fileType = (externalAttributes >> 16) & 0xf000
                guard fileType == 0 || fileType == 0x8000 || (isDirectory && fileType == 0x4000) else {
                    throw ChromeWebStoreInstallError.unsafeArchiveEntry
                }
            }
            guard !isDirectory || uncompressedSize == 0 else {
                throw ChromeWebStoreInstallError.invalidZIP
            }
            let (nextTotal, overflowed) = totalUncompressed.addingReportingOverflow(UInt64(uncompressedSize))
            guard !overflowed, nextTotal <= maximumUncompressedBytes else {
                throw ChromeWebStoreInstallError.unpackedPackageTooLarge(Int64(maximumUncompressedBytes))
            }
            totalUncompressed = nextTotal
            let entry = try validatedLocalEntry(
                data: data,
                centralDirectoryOffset: centralOffset,
                nameData: nameData,
                name: name,
                flags: flags,
                method: method,
                checksum: checksum,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localOffset: localOffset,
                isDirectory: isDirectory
            )
            entries.append(entry)
            cursor = recordEnd
        }
        guard cursor == eocdOffset, !entries.isEmpty else {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        let sortedRanges = entries.map(\.archiveRange).sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sortedRanges.count where sortedRanges[index].lowerBound < sortedRanges[index - 1].upperBound {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        return entries
    }

    private static func validatedLocalEntry(
        data: Data,
        centralDirectoryOffset: Int,
        nameData: Data,
        name: String,
        flags: UInt16,
        method: UInt16,
        checksum: UInt32,
        compressedSize: Int,
        uncompressedSize: Int,
        localOffset: Int,
        isDirectory: Bool
    ) throws -> ZIPEntry {
        guard localOffset >= 0, localOffset + 30 <= centralDirectoryOffset,
              try data.littleEndianUInt32(at: localOffset) == 0x0403_4b50 else {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        let localFlags = try data.littleEndianUInt16(at: localOffset + 6)
        let localMethod = try data.littleEndianUInt16(at: localOffset + 8)
        let localNameLength = try Int(data.littleEndianUInt16(at: localOffset + 26))
        let localExtraLength = try Int(data.littleEndianUInt16(at: localOffset + 28))
        let nameStart = localOffset + 30
        let dataStart = nameStart + localNameLength + localExtraLength
        let dataEnd = dataStart + compressedSize
        guard localFlags == flags,
              localMethod == method,
              localNameLength == nameData.count,
              dataStart >= nameStart,
              dataEnd >= dataStart,
              dataEnd <= centralDirectoryOffset,
              Data(data[nameStart..<(nameStart + localNameLength)]) == nameData else {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        if flags & 0x0008 == 0 {
            guard try data.littleEndianUInt32(at: localOffset + 14) == checksum,
                  try Int(data.littleEndianUInt32(at: localOffset + 18)) == compressedSize,
                  try Int(data.littleEndianUInt32(at: localOffset + 22)) == uncompressedSize else {
                throw ChromeWebStoreInstallError.invalidZIP
            }
        }
        return ZIPEntry(
            name: name,
            method: method,
            checksum: checksum,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            dataRange: dataStart..<dataEnd,
            archiveRange: localOffset..<dataEnd,
            isDirectory: isDirectory
        )
    }

    private static func locateEndOfCentralDirectory(_ data: Data) throws -> Int {
        guard data.count >= 22 else { throw ChromeWebStoreInstallError.invalidZIP }
        let lowerBound = max(0, data.count - 22 - 65_535)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if (try? data.littleEndianUInt32(at: offset)) == 0x0605_4b50 {
                let commentLength = try Int(data.littleEndianUInt16(at: offset + 20))
                if offset + 22 + commentLength == data.count { return offset }
            }
        }
        throw ChromeWebStoreInstallError.invalidZIP
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for (index, component) in components.enumerated() {
            if component.isEmpty {
                guard index == components.count - 1 else { return false }
                continue
            }
            guard component != ".", component != ".." else { return false }
        }
        return true
    }

    private static func extract(_ entry: ZIPEntry, zipData: Data, destinationRoot: URL) throws {
        let relativeComponents = entry.name.split(separator: "/").map(String.init)
        var destination = destinationRoot
        for component in relativeComponents {
            destination.appendPathComponent(component, isDirectory: false)
        }
        let rootPath = destinationRoot.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath.hasPrefix(rootPath + "/") else {
            throw ChromeWebStoreInstallError.unsafeArchivePath
        }
        if entry.isDirectory {
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ChromeWebStoreInstallError.unsafeArchiveEntry
                }
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ChromeWebStoreInstallError.unsafeArchiveEntry
        }
        let compressed = Data(zipData[entry.dataRange])
        let contents: Data
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw ChromeWebStoreInstallError.invalidZIP
            }
            contents = compressed
        case 8:
            contents = try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ChromeWebStoreInstallError.unsupportedZIP
        }
        guard crc32(contents) == entry.checksum else {
            throw ChromeWebStoreInstallError.invalidZIPChecksum
        }
        try contents.write(to: destination, options: .withoutOverwriting)
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, UInt64(expectedSize) <= maximumUncompressedBytes else {
            throw ChromeWebStoreInstallError.unpackedPackageTooLarge(Int64(maximumUncompressedBytes))
        }
        var output = Data(count: max(expectedSize, 1))
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw ChromeWebStoreInstallError.invalidZIP }
        defer { inflateEnd(&stream) }
        let status: Int32 = compressed.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END,
              stream.total_out == expectedSize,
              stream.avail_in == 0 else {
            throw ChromeWebStoreInstallError.invalidZIP
        }
        output.count = expectedSize
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }

    private struct ZIPEntry {
        let name: String
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let dataRange: Range<Int>
        let archiveRange: Range<Int>
        let isDirectory: Bool
    }
}

enum ChromeWebStoreInstallError: LocalizedError, Equatable {
    case invalidCatalogItem
    case installAlreadyInProgress
    case unsafeDownloadURL
    case unsafeRedirect
    case invalidDownloadResponse
    case downloadTooLarge(Int64)
    case emptyDownload
    case cannotCreateDownload
    case cannotWriteDownload
    case unsafeStagingDirectory
    case invalidCRX
    case unsupportedCRXVersion(UInt32)
    case extensionIDMismatch
    case invalidPublicKey
    case invalidCRXSignature
    case invalidExtensionManifest
    case cannotWriteExtensionManifest
    case invalidZIP
    case unsupportedZIP
    case unsafeArchivePath
    case unsafeArchiveEntry
    case unpackedPackageTooLarge(Int64)
    case invalidZIPChecksum

    var errorDescription: String? {
        switch self {
        case .invalidCatalogItem:
            "请输入有效的 Chrome Web Store 链接或 32 位扩展 ID。"
        case .installAlreadyInProgress:
            "这个扩展正在安装。"
        case .unsafeDownloadURL:
            "Chrome Web Store 下载地址不安全。"
        case .unsafeRedirect:
            "Chrome Web Store 下载被重定向到未授权的主机。"
        case .invalidDownloadResponse:
            "Chrome Web Store 未返回有效的扩展包。"
        case .downloadTooLarge(let maximum):
            "扩展下载超过上限（\(maximum / 1_024 / 1_024) MB）。"
        case .emptyDownload:
            "Chrome Web Store 返回了空扩展包。"
        case .cannotCreateDownload, .cannotWriteDownload:
            "无法在 Rex 受管目录中保存扩展下载。"
        case .unsafeStagingDirectory:
            "Rex 扩展暂存目录不安全，已停止安装。"
        case .invalidCRX:
            "下载内容不是有效的 CRX 扩展包。"
        case .unsupportedCRXVersion(let version):
            "不支持 CRX \(version) 扩展包。"
        case .extensionIDMismatch:
            "扩展包公钥身份与商店条目不匹配。"
        case .invalidPublicKey:
            "扩展包的签名公钥无效。"
        case .invalidCRXSignature:
            "扩展包签名验证失败，已拒绝安装。"
        case .invalidExtensionManifest:
            "扩展包的 manifest.json 无效，无法绑定商店身份。"
        case .cannotWriteExtensionManifest:
            "无法把已验证的商店身份写入扩展清单。"
        case .invalidZIP:
            "扩展包中的 ZIP 数据无效。"
        case .unsupportedZIP:
            "扩展包使用了 Rex 不支持的 ZIP 格式。"
        case .unsafeArchivePath:
            "扩展包包含不安全或重复的文件路径。"
        case .unsafeArchiveEntry:
            "扩展包包含符号链接或其他不安全文件类型。"
        case .unpackedPackageTooLarge(let maximum):
            "扩展解压后超过上限（\(maximum / 1_024 / 1_024) MB）。"
        case .invalidZIPChecksum:
            "扩展包文件校验失败。"
        }
    }
}

private struct ProtobufReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func nextField() throws -> (number: Int, value: ProtobufValue)? {
        guard offset < data.count else { return nil }
        let tag = try readVarint()
        let number = Int(tag >> 3)
        guard number > 0 else { throw ChromeWebStoreInstallError.invalidCRX }
        switch tag & 0x07 {
        case 0:
            return (number, .varint(try readVarint()))
        case 1:
            try skip(8)
            return (number, .fixed)
        case 2:
            let length = try Int(exactly: readVarint())
                .unwrapped(or: ChromeWebStoreInstallError.invalidCRX)
            guard length >= 0, offset <= data.count - length else {
                throw ChromeWebStoreInstallError.invalidCRX
            }
            let value = Data(data[offset..<(offset + length)])
            offset += length
            return (number, .bytes(value))
        case 5:
            try skip(4)
            return (number, .fixed)
        default:
            throw ChromeWebStoreInstallError.invalidCRX
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw ChromeWebStoreInstallError.invalidCRX }
            let byte = data[offset]
            offset += 1
            if shift == 63, byte > 1 { throw ChromeWebStoreInstallError.invalidCRX }
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw ChromeWebStoreInstallError.invalidCRX
    }

    private mutating func skip(_ length: Int) throws {
        guard length >= 0, offset <= data.count - length else {
            throw ChromeWebStoreInstallError.invalidCRX
        }
        offset += length
    }
}

private enum ProtobufValue {
    case varint(UInt64)
    case bytes(Data)
    case fixed
}

private enum DERSubjectPublicKeyInfo {
    static func unwrap(_ data: Data) throws -> Data {
        var outer = DERReader(data)
        let sequence = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw ChromeWebStoreInstallError.invalidPublicKey }
        var body = DERReader(sequence)
        _ = try body.read(tag: 0x30)
        let bitString = try body.read(tag: 0x03)
        guard body.isAtEnd, bitString.count > 1, bitString.first == 0 else {
            throw ChromeWebStoreInstallError.invalidPublicKey
        }
        return Data(bitString.dropFirst())
    }
}

private struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func read(tag expectedTag: UInt8) throws -> Data {
        guard offset < data.count, data[offset] == expectedTag else {
            throw ChromeWebStoreInstallError.invalidPublicKey
        }
        offset += 1
        let length = try readLength()
        guard length >= 0, offset <= data.count - length else {
            throw ChromeWebStoreInstallError.invalidPublicKey
        }
        let value = Data(data[offset..<(offset + length)])
        offset += length
        return value
    }

    private mutating func readLength() throws -> Int {
        guard offset < data.count else { throw ChromeWebStoreInstallError.invalidPublicKey }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7f)
        guard count > 0, count <= 4, offset <= data.count - count else {
            throw ChromeWebStoreInstallError.invalidPublicKey
        }
        var length = 0
        for _ in 0..<count {
            let (shifted, overflowed) = length.multipliedReportingOverflow(by: 256)
            guard !overflowed else { throw ChromeWebStoreInstallError.invalidPublicKey }
            length = shifted + Int(data[offset])
            offset += 1
        }
        guard length >= 128 else { throw ChromeWebStoreInstallError.invalidPublicKey }
        return length
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw ChromeWebStoreInstallError.invalidZIP }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw ChromeWebStoreInstallError.invalidCRX }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

private extension Optional {
    func unwrapped(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
