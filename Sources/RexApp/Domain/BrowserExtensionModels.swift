import AppKit
import Combine
import CoreFoundation
import CryptoKit
import Foundation

struct BrowserExtensionRuntimeCapabilities: Equatable, Sendable {
    static let current = BrowserExtensionRuntimeCapabilities(
        supportsChromeWebStoreInstall: false,
        supportsCRXInstall: false,
        supportsUnpackedExecution: false,
        supportsManifestV3Execution: false
    )

    let supportsChromeWebStoreInstall: Bool
    let supportsCRXInstall: Bool
    let supportsUnpackedExecution: Bool
    let supportsManifestV3Execution: Bool

    var limitationText: String {
        "CEF 150 没有公开的扩展加载 API。Rex 可以校验和管理本地未打包扩展，但不会执行其脚本、后台服务或浏览器 API。"
    }
}

struct BrowserExtensionPackage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var homepageURL: URL?
    var path: URL
    var isEnabled: Bool
    var permissions: [String]
    var runtimeStatus: RuntimeStatus
    var installedAt: Date
    var updatedAt: Date
    var manifestVersion: Int?
    var iconRelativePath: String?
    var statusDetail: String?

    enum RuntimeStatus: String, Codable, Sendable, CaseIterable {
        case ready
        case pendingRuntime
        case invalidManifest
        case missingFiles
        case disabled

        var displayName: String {
            switch self {
            case .ready: "运行中"
            case .pendingRuntime: "仅已导入"
            case .invalidManifest: "清单无效"
            case .missingFiles: "文件缺失"
            case .disabled: "已停用"
            }
        }
    }

    var permissionSummary: String {
        if permissions.isEmpty { return "无声明权限" }
        let head = permissions.prefix(4).joined(separator: " · ")
        return permissions.count > 4 ? "\(head) 等 \(permissions.count) 项" : head
    }

    var manifestLabel: String {
        manifestVersion.map { "Manifest V\($0)" } ?? "Manifest 未知"
    }

    var iconURL: URL? {
        guard let iconRelativePath, !iconRelativePath.isEmpty else { return nil }
        let unresolvedCandidate = path.appendingPathComponent(iconRelativePath)
        guard let values = try? unresolvedCandidate.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .fileSizeKey
        ]),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= 8 * 1_024 * 1_024 else { return nil }
        let candidate = unresolvedCandidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let packagePath = path.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.path.hasPrefix(packagePath + "/") else { return nil }
        return candidate
    }
}

@MainActor
final class BrowserExtensionsStore: ObservableObject {
    static let shared = BrowserExtensionsStore()

    @Published private(set) var extensions: [BrowserExtensionPackage] = []
    @Published private(set) var lastError: String?

    let runtimeCapabilities = BrowserExtensionRuntimeCapabilities.current

    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private let catalogURL: URL
    private let packagesDirectoryURL: URL
    private let configuredRootWasSymbolicLink: Bool

    private enum ImportLimits {
        static let maximumEntryCount = 10_000
        static let maximumTotalBytes: Int64 = 256 * 1_024 * 1_024
        static let maximumManifestBytes = 2 * 1_024 * 1_024
        static let maximumMessagesBytes = 2 * 1_024 * 1_024
        static let maximumCatalogBytes = 8 * 1_024 * 1_024
    }

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = rootDirectoryURL
            ?? support.appendingPathComponent("Rex/Extensions", isDirectory: true)
        let configuredRoot = root.standardizedFileURL
        configuredRootWasSymbolicLink = Self.isSymbolicLink(at: configuredRoot)
        self.rootDirectoryURL = configuredRoot.resolvingSymlinksInPath().standardizedFileURL
        packagesDirectoryURL = self.rootDirectoryURL.appendingPathComponent("Packages", isDirectory: true)
        catalogURL = self.rootDirectoryURL.appendingPathComponent("catalog.json", isDirectory: false)
        load()
    }

    var enabledCount: Int {
        extensions.filter(\.isEnabled).count
    }

    func load() {
        do {
            try prepareManagedDirectories()
            guard fileManager.fileExists(atPath: catalogURL.path) else {
                extensions = []
                lastError = nil
                return
            }
            let data = try boundedRegularFileData(
                at: catalogURL,
                maximumByteCount: ImportLimits.maximumCatalogBytes,
                label: "catalog.json"
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([BrowserExtensionPackage].self, from: data)
            extensions = decoded
                .map(revalidatedPackage)
                .sorted { $0.updatedAt > $1.updatedAt }
            lastError = nil
        } catch {
            lastError = "无法读取扩展目录：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func installUnpacked(from sourceDirectory: URL) throws -> BrowserExtensionPackage {
        try prepareManagedDirectories()
        var isDirectory: ObjCBool = false
        guard sourceDirectory.isFileURL,
              fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExtensionStoreError.notADirectory
        }

        let source = sourceDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        try validateImportTree(at: source)
        let parsed = try parseManifest(in: source)

        if let managedSource = extensions.first(where: { package in
            isManagedPackageURL(package.path, id: package.id, requireExistingDirectory: true)
                && package.path.resolvingSymlinksInPath().standardizedFileURL.path == source.path
        }) {
            return try updateCatalogEntry(
                package(
                    from: parsed,
                    id: managedSource.id,
                    path: managedSource.path,
                    installedAt: managedSource.installedAt,
                    isEnabled: managedSource.isEnabled
                )
            )
        }

        guard source.path != packagesDirectoryURL.path,
              !isDescendant(source, of: packagesDirectoryURL) else {
            throw ExtensionStoreError.unsafeSourceDirectory
        }

        let proposedPackageID = packageIdentifier(for: parsed, sourceDirectory: source)
        let existingPackage = matchingExistingPackage(
            for: parsed,
            proposedID: proposedPackageID
        )
        let packageID = existingPackage?.id ?? proposedPackageID
        guard isSafePackageIdentifier(packageID) else {
            throw ExtensionStoreError.unsafePackagePath
        }
        let destination = packagesDirectoryURL.appendingPathComponent(packageID, isDirectory: true)
        guard isManagedPackageURL(destination, id: packageID, requireExistingDirectory: false) else {
            throw ExtensionStoreError.unsafePackagePath
        }

        let installedAt = existingPackage?.installedAt ?? Date()
        let isEnabled = existingPackage?.isEnabled ?? true

        let staging = packagesDirectoryURL.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = packagesDirectoryURL.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if fileManager.fileExists(atPath: staging.path) { try? fileManager.removeItem(at: staging) }
        }

        try fileManager.copyItem(at: source, to: staging)
        try validateImportTree(at: staging)
        let stagedManifest = try parseManifest(in: staging)
        guard packageIdentifier(for: stagedManifest, sourceDirectory: source) == proposedPackageID else {
            throw ExtensionStoreError.invalidManifest
        }

        let previousExtensions = extensions
        let hadExistingFiles = fileManager.fileExists(atPath: destination.path)
        if hadExistingFiles,
           !isManagedPackageURL(destination, id: packageID, requireExistingDirectory: true) {
            throw ExtensionStoreError.unsafePackagePath
        }
        var movedExistingFiles = false
        do {
            if hadExistingFiles {
                try fileManager.moveItem(at: destination, to: backup)
                movedExistingFiles = true
            }
            try fileManager.moveItem(at: staging, to: destination)
            try validateImportTree(at: destination)
            let installedManifest = try parseManifest(in: destination)
            guard packageIdentifier(for: installedManifest, sourceDirectory: source) == proposedPackageID else {
                throw ExtensionStoreError.invalidManifest
            }

            let installed = package(
                from: installedManifest,
                id: packageID,
                path: destination,
                installedAt: installedAt,
                isEnabled: isEnabled
            )
            let result = try updateCatalogEntry(installed)
            if movedExistingFiles, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.removeItem(at: backup)
            }
            return result
        } catch {
            extensions = previousExtensions
            if fileManager.fileExists(atPath: destination.path),
               isManagedPackageURL(destination, id: packageID, requireExistingDirectory: true) {
                try? fileManager.removeItem(at: destination)
            }
            if movedExistingFiles, fileManager.fileExists(atPath: backup.path) {
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw ExtensionStoreError.recoveryRequired(backup)
                }
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch {
                    throw ExtensionStoreError.recoveryRequired(backup)
                }
            }
            throw error
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for id: String) -> Bool {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return false }
        let previous = extensions[index]
        extensions[index].isEnabled = enabled
        extensions[index].updatedAt = .now
        extensions[index] = revalidatedPackage(extensions[index])
        do {
            try persist()
            lastError = nil
            return true
        } catch {
            extensions[index] = previous
            lastError = "无法保存扩展状态：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        do {
            try prepareManagedDirectories()
        } catch {
            lastError = "无法验证 Rex 扩展目录：\(error.localizedDescription)"
            return false
        }
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return false }
        let package = extensions[index]
        let previousExtensions = extensions
        let quarantine = rootDirectoryURL.appendingPathComponent(
            ".removed-\(UUID().uuidString)",
            isDirectory: true
        )
        let canMoveFiles = isManagedPackageURL(
            package.path,
            id: package.id,
            requireExistingDirectory: true
        )

        do {
            if canMoveFiles {
                try fileManager.moveItem(at: package.path, to: quarantine)
            }
            extensions.remove(at: index)
            do {
                try persist()
            } catch {
                extensions = previousExtensions
                if canMoveFiles, fileManager.fileExists(atPath: quarantine.path) {
                    try? fileManager.moveItem(at: quarantine, to: package.path)
                }
                throw error
            }
            if fileManager.fileExists(atPath: quarantine.path) {
                try? fileManager.removeItem(at: quarantine)
            }
            lastError = nil
            return true
        } catch {
            lastError = "无法移除扩展：\(error.localizedDescription)"
            return false
        }
    }

    func revealInFinder(_ id: String) {
        guard (try? prepareManagedDirectories()) != nil,
              let package = extensions.first(where: { $0.id == id }),
              isManagedPackageURL(
                  package.path,
                  id: package.id,
                  requireExistingDirectory: true
              ) else {
            lastError = "扩展文件已移动或不在 Rex 管理目录中。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([package.path])
    }

    func openPackagesDirectory() {
        do {
            try prepareManagedDirectories()
            NSWorkspace.shared.open(packagesDirectoryURL)
        } catch {
            lastError = "无法打开扩展目录：\(error.localizedDescription)"
        }
    }

    func clearLastError() {
        lastError = nil
    }

    private func updateCatalogEntry(
        _ package: BrowserExtensionPackage
    ) throws -> BrowserExtensionPackage {
        let previousExtensions = extensions
        if let index = extensions.firstIndex(where: { $0.id == package.id }) {
            extensions[index] = package
        } else {
            extensions.insert(package, at: 0)
        }
        extensions.sort { $0.updatedAt > $1.updatedAt }
        do {
            try persist()
            lastError = nil
            return package
        } catch {
            extensions = previousExtensions
            lastError = "无法保存扩展目录：\(error.localizedDescription)"
            throw error
        }
    }

    private func persist() throws {
        try prepareManagedDirectories()
        if fileManager.fileExists(atPath: catalogURL.path) {
            let values = try catalogURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw ExtensionStoreError.unsafeManagedRoot
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(extensions)
        try data.write(to: catalogURL, options: .atomic)
    }

    private func revalidatedPackage(
        _ package: BrowserExtensionPackage
    ) -> BrowserExtensionPackage {
        var result = package
        result.homepageURL = nil
        result.iconRelativePath = nil
        guard isManagedPackageURL(
            result.path,
            id: result.id,
            requireExistingDirectory: false
        ) else {
            result.runtimeStatus = .missingFiles
            result.statusDetail = "记录的路径不在 Rex 扩展目录中；移除记录不会删除外部文件。"
            return result
        }

        guard isManagedPackageURL(
            result.path,
            id: result.id,
            requireExistingDirectory: true
        ) else {
            result.runtimeStatus = .missingFiles
            result.statusDetail = "扩展文件夹不存在，可移除后重新导入。"
            return result
        }

        do {
            try validateImportTree(at: result.path)
            let parsed = try parseManifest(in: result.path)
            result.name = parsed.name
            result.version = parsed.version
            result.description = parsed.description
            result.author = parsed.author
            result.homepageURL = parsed.homepageURL
            result.permissions = parsed.permissions
            result.manifestVersion = parsed.manifestVersion
            result.iconRelativePath = parsed.iconRelativePath
            result.runtimeStatus = result.isEnabled ? .pendingRuntime : .disabled
            result.statusDetail = result.isEnabled ? runtimeCapabilities.limitationText : nil
        } catch {
            result.runtimeStatus = .invalidManifest
            result.statusDetail = error.localizedDescription
        }
        return result
    }

    private func package(
        from manifest: ParsedManifest,
        id: String,
        path: URL,
        installedAt: Date,
        isEnabled: Bool
    ) -> BrowserExtensionPackage {
        BrowserExtensionPackage(
            id: id,
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            author: manifest.author,
            homepageURL: manifest.homepageURL,
            path: path,
            isEnabled: isEnabled,
            permissions: manifest.permissions,
            runtimeStatus: isEnabled ? .pendingRuntime : .disabled,
            installedAt: installedAt,
            updatedAt: .now,
            manifestVersion: manifest.manifestVersion,
            iconRelativePath: manifest.iconRelativePath,
            statusDetail: isEnabled ? runtimeCapabilities.limitationText : nil
        )
    }

    private func parseManifest(in directory: URL) throws -> ParsedManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ExtensionStoreError.missingManifest
        }

        let manifestData = try boundedRegularFileData(
            at: manifestURL,
            maximumByteCount: ImportLimits.maximumManifestBytes,
            label: "manifest.json"
        )
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw ExtensionStoreError.invalidManifest
        }

        guard let manifestVersionNumber = manifest["manifest_version"] as? NSNumber,
              CFGetTypeID(manifestVersionNumber) != CFBooleanGetTypeID() else {
            throw ExtensionStoreError.missingManifestVersion
        }
        let manifestVersion = manifestVersionNumber.intValue
        guard manifestVersionNumber.doubleValue == Double(manifestVersion) else {
            throw ExtensionStoreError.invalidManifest
        }
        guard [2, 3].contains(manifestVersion) else {
            throw ExtensionStoreError.unsupportedManifestVersion(manifestVersion)
        }

        let name = try localizedManifestValue(
            manifest["name"],
            manifest: manifest,
            directory: directory,
            required: true
        )
        let version = (manifest["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name.count <= 256,
              let version, !version.isEmpty, version.count <= 128 else {
            throw ExtensionStoreError.invalidManifest
        }

        let description = try localizedManifestValue(
            manifest["description"],
            manifest: manifest,
            directory: directory,
            required: false
        ) ?? ""
        let author = (manifest["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let homepageURL = safeWebURL(from: manifest["homepage_url"] as? String)
        let key = (manifest["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedManifest(
            name: name,
            version: version,
            description: description,
            author: author?.isEmpty == false ? author : nil,
            homepageURL: homepageURL,
            manifestVersion: manifestVersion,
            permissions: Self.extractPermissions(from: manifest),
            iconRelativePath: preferredIconPath(from: manifest, directory: directory),
            identityKey: key?.isEmpty == false ? key : nil
        )
    }

    private func localizedManifestValue(
        _ value: Any?,
        manifest: [String: Any],
        directory: URL,
        required: Bool
    ) throws -> String? {
        guard let rawValue = value as? String else {
            if required { throw ExtensionStoreError.invalidManifest }
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("__MSG_"), trimmed.hasSuffix("__") else { return trimmed }

        let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 6)
        let keyEnd = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let messageKey = String(trimmed[keyStart..<keyEnd])
        guard !messageKey.isEmpty,
              let locale = manifest["default_locale"] as? String,
              locale.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(messageKey)
        }

        let messagesURL = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard fileManager.fileExists(atPath: messagesURL.path) else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(messageKey)
        }
        let data = try boundedRegularFileData(
            at: messagesURL,
            maximumByteCount: ImportLimits.maximumMessagesBytes,
            label: "messages.json"
        )
        guard let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = messages[messageKey] as? [String: Any],
              let message = record["message"] as? String,
              !message.isEmpty else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(messageKey)
        }
        return message
    }

    private func preferredIconPath(
        from manifest: [String: Any],
        directory: URL
    ) -> String? {
        guard let icons = manifest["icons"] as? [String: Any] else { return nil }
        let candidates = icons.compactMap { size, value -> (Int, String)? in
            guard let size = Int(size), let path = value as? String, !path.isEmpty else { return nil }
            return (size, path)
        }.sorted { $0.0 > $1.0 }

        for (_, relativePath) in candidates {
            let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
            guard isDescendant(candidate, of: directory),
                  let values = try? candidate.resourceValues(forKeys: [
                      .isSymbolicLinkKey,
                      .isRegularFileKey,
                      .fileSizeKey
                  ]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 8 * 1_024 * 1_024 else { continue }
            return relativePath
        }
        return nil
    }

    private func packageIdentifier(
        for manifest: ParsedManifest,
        sourceDirectory: URL
    ) -> String {
        let seed: String
        if let identityKey = manifest.identityKey {
            seed = "key:\(identityKey)"
        } else {
            seed = [
                "metadata",
                manifest.name.lowercased(),
                manifest.author?.lowercased() ?? "",
                manifest.homepageURL?.absoluteString.lowercased() ?? "",
                sourceDirectory.lastPathComponent.lowercased()
            ].joined(separator: "\u{0}")
        }
        let digest = SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "local-\(digest.prefix(32))"
    }

    private func matchingExistingPackage(
        for manifest: ParsedManifest,
        proposedID: String
    ) -> BrowserExtensionPackage? {
        if let exact = extensions.first(where: {
            $0.id == proposedID
                && isManagedPackageURL($0.path, id: $0.id, requireExistingDirectory: false)
        }) {
            return exact
        }

        let legacyID = manifest.identityKey
            ?? "\(manifest.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(manifest.version)"
        if isSafePackageIdentifier(legacyID),
           let exactLegacy = extensions.first(where: {
               $0.id == legacyID
                   && isManagedPackageURL($0.path, id: $0.id, requireExistingDirectory: false)
           }) {
            return exactLegacy
        }

        guard manifest.identityKey == nil else { return nil }
        let legacyMatches = extensions.filter { package in
            !isCanonicalPackageIdentifier(package.id)
                && isManagedPackageURL(package.path, id: package.id, requireExistingDirectory: false)
                && package.name.caseInsensitiveCompare(manifest.name) == .orderedSame
                && normalized(package.author) == normalized(manifest.author)
                && normalized(package.homepageURL?.absoluteString)
                    == normalized(manifest.homepageURL?.absoluteString)
        }
        return legacyMatches.count == 1 ? legacyMatches[0] : nil
    }

    private func prepareManagedDirectories() throws {
        guard !configuredRootWasSymbolicLink else {
            throw ExtensionStoreError.unsafeManagedRoot
        }
        try fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        guard isTrustedDirectory(rootDirectoryURL) else {
            throw ExtensionStoreError.unsafeManagedRoot
        }

        if fileManager.fileExists(atPath: packagesDirectoryURL.path) {
            guard isTrustedDirectory(packagesDirectoryURL) else {
                throw ExtensionStoreError.unsafeManagedRoot
            }
        } else {
            try fileManager.createDirectory(at: packagesDirectoryURL, withIntermediateDirectories: false)
            guard isTrustedDirectory(packagesDirectoryURL) else {
                throw ExtensionStoreError.unsafeManagedRoot
            }
        }
    }

    private func isTrustedDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            == url.standardizedFileURL.path
    }

    private func isManagedPackageURL(
        _ url: URL,
        id: String,
        requireExistingDirectory: Bool
    ) -> Bool {
        guard isSafePackageIdentifier(id),
              isTrustedDirectory(rootDirectoryURL),
              isTrustedDirectory(packagesDirectoryURL),
              url.lastPathComponent == id else { return false }

        let expected = packagesDirectoryURL
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == expected.path else { return false }

        if requireExistingDirectory {
            return isTrustedDirectory(expected)
        }
        if fileManager.fileExists(atPath: expected.path) {
            return isTrustedDirectory(expected)
        }
        return true
    }

    private func isSafePackageIdentifier(_ id: String) -> Bool {
        !id.isEmpty
            && id.utf8.count <= 240
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\0")
    }

    private func isCanonicalPackageIdentifier(_ id: String) -> Bool {
        guard id.count == 38, id.hasPrefix("local-") else { return false }
        return id.dropFirst(6).allSatisfy { $0.isHexDigit }
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func validateImportTree(at directory: URL) throws {
        guard isTrustedDirectory(directory) else {
            throw ExtensionStoreError.symbolicLinksNotAllowed
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ExtensionStoreError.invalidImportTree
        }

        var entryCount = 0
        var totalBytes: Int64 = 0
        for case let itemURL as URL in enumerator {
            entryCount += 1
            guard entryCount <= ImportLimits.maximumEntryCount else {
                throw ExtensionStoreError.tooManyFiles(ImportLimits.maximumEntryCount)
            }
            let values = try itemURL.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw ExtensionStoreError.symbolicLinksNotAllowed
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw ExtensionStoreError.invalidImportTree
            }
            let logicalSize = Int64(values.fileSize ?? 0)
            let allocatedSize = Int64(values.totalFileAllocatedSize ?? 0)
            let (newTotal, overflowed) = totalBytes.addingReportingOverflow(max(logicalSize, allocatedSize))
            guard !overflowed, newTotal <= ImportLimits.maximumTotalBytes else {
                throw ExtensionStoreError.packageTooLarge(ImportLimits.maximumTotalBytes)
            }
            totalBytes = newTotal
        }
        if enumerationError != nil {
            throw ExtensionStoreError.invalidImportTree
        }
    }

    private func boundedRegularFileData(
        at url: URL,
        maximumByteCount: Int,
        label: String
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true else {
            throw ExtensionStoreError.symbolicLinksNotAllowed
        }
        guard values.isRegularFile == true else {
            throw ExtensionStoreError.invalidManifest
        }
        guard (values.fileSize ?? 0) <= maximumByteCount else {
            throw ExtensionStoreError.metadataFileTooLarge(label, maximumByteCount)
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ExtensionStoreError.invalidManifest
        }
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let basePath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(basePath + "/")
    }

    private func safeWebURL(from value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func extractPermissions(from manifest: [String: Any]) -> [String] {
        var values: [String] = []
        if let permissions = manifest["permissions"] as? [String] {
            values.append(contentsOf: permissions)
        }
        if let optional = manifest["optional_permissions"] as? [String] {
            values.append(contentsOf: optional.map { "optional:\($0)" })
        }
        if let host = manifest["host_permissions"] as? [String] {
            values.append(contentsOf: host)
        }
        return Array(Set(values)).sorted()
    }

    private struct ParsedManifest {
        let name: String
        let version: String
        let description: String
        let author: String?
        let homepageURL: URL?
        let manifestVersion: Int
        let permissions: [String]
        let iconRelativePath: String?
        let identityKey: String?
    }
}

enum ExtensionStoreError: LocalizedError {
    case notADirectory
    case missingManifest
    case invalidManifest
    case missingManifestVersion
    case unsupportedManifestVersion(Int)
    case unresolvedLocalizedMessage(String)
    case unsafePackagePath
    case unsafeSourceDirectory
    case unsafeManagedRoot
    case symbolicLinksNotAllowed
    case invalidImportTree
    case tooManyFiles(Int)
    case packageTooLarge(Int64)
    case metadataFileTooLarge(String, Int)
    case recoveryRequired(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory:
            "请选择包含 Chrome 扩展文件的文件夹。"
        case .missingManifest:
            "未找到 manifest.json，这不是有效的未打包扩展。"
        case .invalidManifest:
            "manifest.json 无法解析，或缺少 name/version。"
        case .missingManifestVersion:
            "manifest.json 缺少 manifest_version。"
        case .unsupportedManifestVersion(let version):
            "Rex 只能识别 Manifest V2 或 V3，当前清单为 V\(version)。"
        case .unresolvedLocalizedMessage(let key):
            "无法从 _locales 解析清单文字：\(key)。"
        case .unsafePackagePath:
            "扩展目录路径不安全，无法导入。"
        case .unsafeSourceDirectory:
            "不能把 Rex 管理目录本身作为新的扩展来源。"
        case .unsafeManagedRoot:
            "Rex 扩展目录包含符号链接或已被替换，已停止文件操作。"
        case .symbolicLinksNotAllowed:
            "扩展文件夹包含符号链接。请导入一份完整、独立的源码副本。"
        case .invalidImportTree:
            "扩展文件夹包含无法安全复制的文件。"
        case .tooManyFiles(let maximum):
            "扩展文件数量超过上限（\(maximum) 项）。"
        case .packageTooLarge(let maximumBytes):
            "扩展文件总大小超过上限（\(maximumBytes / 1_024 / 1_024) MB）。"
        case .metadataFileTooLarge(let label, let maximumBytes):
            "\(label) 超过大小上限（\(maximumBytes / 1_024 / 1_024) MB）。"
        case .recoveryRequired(let backupURL):
            "无法自动恢复原扩展，旧文件保留在 \(backupURL.lastPathComponent)。"
        }
    }
}
