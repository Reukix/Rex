import AppKit
import Combine
import CoreFoundation
import CryptoKit
import Foundation

struct BrowserExtensionRuntimeCapabilities: Equatable, Sendable {
    static let current = BrowserExtensionRuntimeCapabilities(
        supportsChromeWebStoreInstall: true,
        supportsCRXInstall: true,
        supportsUnpackedExecution: true,
        supportsManifestV3Execution: true,
        supportsExtensionOwnedPages: true,
        supportsNativeExtensionSurfaces: false,
        supportsChromeTabContext: false,
        supportsExactDomainDNR: false
    )

    let supportsChromeWebStoreInstall: Bool
    let supportsCRXInstall: Bool
    let supportsUnpackedExecution: Bool
    let supportsManifestV3Execution: Bool
    let supportsExtensionOwnedPages: Bool
    let supportsNativeExtensionSurfaces: Bool
    let supportsChromeTabContext: Bool
    let supportsExactDomainDNR: Bool

    var limitationText: String {
        "扩展包内页面由 Chromium 运行；安装、启停、更新与移除会立即同步。原生 action 与活动标签上下文暂不支持。"
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
    var removalRequestedAt: Date? = nil
    var manifestVersion: Int?
    var iconRelativePath: String?
    var statusDetail: String?
    var storeID: String? = nil
    var installationSource: InstallationSource? = nil
    var runtimeID: String? = nil
    var actionPopupRelativePath: String? = nil
    var optionsRelativePath: String? = nil

    enum InstallationSource: String, Codable, Sendable {
        case localUnpacked
        case chromeWebStore
    }

    var resolvedInstallationSource: InstallationSource {
        installationSource ?? .localUnpacked
    }

    enum RuntimeStatus: String, Codable, Sendable, CaseIterable {
        case ready
        case pendingRuntime
        case invalidManifest
        case missingFiles
        case disabled

        var displayName: String {
            switch self {
            case .ready: "已接入"
            case .pendingRuntime: "正在接入"
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

    var canUseRuntimeResources: Bool {
        isEnabled
            && runtimeStatus == .ready
            && removalRequestedAt == nil
            && runtimeID.map(RexExtensionResourceURL.isValidRuntimeID) == true
    }

    func resourceURL(relativePath: String) -> URL? {
        guard canUseRuntimeResources, let runtimeID else { return nil }
        return RexExtensionResourceURL(
            runtimeID: runtimeID,
            relativePath: relativePath
        )?.rexURL
    }

    var actionPopupURL: URL? {
        actionPopupRelativePath.flatMap { resourceURL(relativePath: $0) }
    }

    var optionsURL: URL? {
        optionsRelativePath.flatMap { resourceURL(relativePath: $0) }
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
    @Published private(set) var catalogInstallStates: [String: BrowserExtensionCatalogInstallState] = [:]
    @Published private(set) var isRuntimeMutationInProgress = false

    let runtimeCapabilities = BrowserExtensionRuntimeCapabilities.current

    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private let catalogURL: URL
    private let runtimeReplacementsURL: URL
    private let packagesDirectoryURL: URL
    private let stagingDirectoryURL: URL
    private let configuredRootWasSymbolicLink: Bool
    private let packageFetcher: any ChromeWebStorePackageFetching
    private var runtimeLoadedPackageIDs = Set<String>()
    private var forcedRuntimeReloadPackageIDs = Set<String>()
    private var pendingRuntimeReplacements: [String: PendingRuntimeReplacement] = [:]
    private var runtimeMutationOwned = false
    private var runtimeMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var initialRuntimeSyncClaimed = false

    private struct PendingRuntimeReplacement: Codable {
        enum Phase: String, Codable {
            case prepared
            case swapped
            case committed
        }

        let token: UUID
        let packageID: String
        let destination: URL
        let backup: URL
        let previousPackage: BrowserExtensionPackage?
        var phase: Phase
    }

    private enum ImportLimits {
        static let maximumEntryCount = 10_000
        static let maximumTotalBytes: Int64 = 256 * 1_024 * 1_024
        static let maximumManifestBytes = 2 * 1_024 * 1_024
        static let maximumMessagesBytes = 2 * 1_024 * 1_024
        static let maximumCatalogBytes = 8 * 1_024 * 1_024
        static let maximumRuntimeJournalBytes = 8 * 1_024 * 1_024
    }

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil,
        packageFetcher: any ChromeWebStorePackageFetching = ChromeWebStorePackageFetcher()
    ) {
        self.fileManager = fileManager
        self.packageFetcher = packageFetcher
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = rootDirectoryURL
            ?? support.appendingPathComponent("Rex/Extensions", isDirectory: true)
        let configuredRoot = root.standardizedFileURL
        configuredRootWasSymbolicLink = Self.isSymbolicLink(at: configuredRoot)
        self.rootDirectoryURL = configuredRoot.resolvingSymlinksInPath().standardizedFileURL
        packagesDirectoryURL = self.rootDirectoryURL.appendingPathComponent("Packages", isDirectory: true)
        stagingDirectoryURL = self.rootDirectoryURL.appendingPathComponent("Staging", isDirectory: true)
        catalogURL = self.rootDirectoryURL.appendingPathComponent("catalog.json", isDirectory: false)
        runtimeReplacementsURL = self.rootDirectoryURL.appendingPathComponent(
            "runtime-replacements.json",
            isDirectory: false
        )
        load()
        var runtimeRecoverySucceeded = true
        do {
            try recoverPendingRuntimeReplacementsFromPreviousLaunch()
        } catch {
            runtimeRecoverySucceeded = false
            lastError = "无法恢复未确认的扩展更新：\(error.localizedDescription)"
        }
        purgePendingRemovalsFromPreviousLaunch()
        if runtimeRecoverySucceeded {
            runtimeLoadedPackageIDs = Set(extensions.lazy.filter {
                $0.isEnabled
                    && ($0.runtimeStatus == .ready || $0.runtimeStatus == .pendingRuntime)
            }.map(\.id))
        } else {
            runtimeLoadedPackageIDs = []
        }
        // load() already performs the expensive package-tree validation. Only
        // update the ephemeral runtime state here so startup scans each package once.
        extensions = extensions.map(packageUpdatingRuntimeState)
    }

    var enabledCount: Int {
        extensions.filter(\.isEnabled).count
    }

    func performSerializedRuntimeMutation<T>(
        _ operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        await acquireRuntimeMutation()
        defer { releaseRuntimeMutation() }
        return try await operation()
    }

    private func acquireRuntimeMutation() async {
        if !runtimeMutationOwned {
            runtimeMutationOwned = true
            isRuntimeMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            runtimeMutationWaiters.append(continuation)
        }
    }

    private func releaseRuntimeMutation() {
        guard !runtimeMutationWaiters.isEmpty else {
            runtimeMutationOwned = false
            isRuntimeMutationInProgress = false
            return
        }
        runtimeMutationWaiters.removeFirst().resume()
    }

    func claimInitialRuntimeSync() -> Bool {
        guard !initialRuntimeSyncClaimed else { return false }
        initialRuntimeSyncClaimed = true
        return true
    }

    func finishInitialRuntimeSync(succeeded: Bool) {
        if !succeeded {
            initialRuntimeSyncClaimed = false
        }
    }

    func package(runtimeID: String) -> BrowserExtensionPackage? {
        guard RexExtensionResourceURL.isValidRuntimeID(runtimeID) else { return nil }
        return extensions.first { $0.runtimeID == runtimeID }
    }

    func runnablePackage(runtimeID: String) -> BrowserExtensionPackage? {
        guard let package = package(runtimeID: runtimeID),
              package.canUseRuntimeResources else {
            return nil
        }
        return package
    }

    var startupExtensionPaths: [String] {
        Self.startupExtensionPaths(
            for: extensions,
            runtimeLoadedPackageIDs: runtimeLoadedPackageIDs
        )
    }

    static func startupExtensionPaths(
        for packages: [BrowserExtensionPackage],
        runtimeLoadedPackageIDs: Set<String>
    ) -> [String] {
        packages.compactMap { package in
            guard runtimeLoadedPackageIDs.contains(package.id),
                  package.isEnabled,
                  package.runtimeStatus == .ready else { return nil }
            return package.path.path
        }
    }

    var nativeRuleExtensionPaths: [String] {
        extensions.compactMap { package in
            guard package.isEnabled,
                  package.runtimeStatus == .ready || package.runtimeStatus == .pendingRuntime else {
                return nil
            }
            return package.path.path
        }
    }

    func catalogInstallState(for extensionID: String) -> BrowserExtensionCatalogInstallState? {
        catalogInstallStates[extensionID]
    }

    @discardableResult
    func installFromCatalog(_ item: BrowserExtensionCatalogItem) async throws -> BrowserExtensionPackage {
        guard BrowserExtensionCatalog.isValidChromeExtensionID(item.id),
              BrowserExtensionCatalog.items.contains(item) else {
            throw ChromeWebStoreInstallError.invalidCatalogItem
        }
        return try await installFromWebStore(extensionID: item.id, displayName: item.name)
    }

    @discardableResult
    func installFromWebStore(
        extensionID: String,
        displayName: String? = nil
    ) async throws -> BrowserExtensionPackage {
        guard BrowserExtensionCatalog.isValidChromeExtensionID(extensionID) else {
            throw ChromeWebStoreInstallError.invalidCatalogItem
        }
        if let state = catalogInstallStates[extensionID],
           [.downloading, .verifying, .extracting, .importing].contains(state.phase) {
            throw ChromeWebStoreInstallError.installAlreadyInProgress
        }

        let installName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstallName = installName.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Chrome Web Store 扩展"
        do {
            try prepareManagedDirectories()
            let operationDirectory = stagingDirectoryURL.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            guard operationDirectory.standardizedFileURL.path.hasPrefix(stagingDirectoryURL.path + "/"),
                  !fileManager.fileExists(atPath: operationDirectory.path) else {
                throw ChromeWebStoreInstallError.unsafeStagingDirectory
            }
            try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: false)
            guard isTrustedDirectory(operationDirectory) else {
                throw ChromeWebStoreInstallError.unsafeStagingDirectory
            }
            defer {
                if fileManager.fileExists(atPath: operationDirectory.path),
                   isDescendant(operationDirectory, of: stagingDirectoryURL) {
                    try? fileManager.removeItem(at: operationDirectory)
                }
            }

            let crxURL = operationDirectory.appendingPathComponent("package.crx", isDirectory: false)
            let extractedURL = operationDirectory.appendingPathComponent(extensionID, isDirectory: true)
            setCatalogInstallState(extensionID, phase: .downloading, message: "正在从 Chrome Web Store 下载")
            try await packageFetcher.fetchPackage(
                extensionID: extensionID,
                destinationURL: crxURL
            ) { [weak self] receivedBytes, expectedBytes in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.catalogInstallStates[extensionID]?.phase == .downloading else { return }
                    self.catalogInstallStates[extensionID]?.receivedBytes = receivedBytes
                    self.catalogInstallStates[extensionID]?.expectedBytes = expectedBytes
                }
            }

            setCatalogInstallState(extensionID, phase: .verifying, message: "正在验证扩展身份与签名")
            let archive = try await Task.detached(priority: .userInitiated) {
                try ChromeExtensionArchiveVerifier.verify(
                    crxAt: crxURL,
                    expectedExtensionID: extensionID
                )
            }.value
            setCatalogInstallState(extensionID, phase: .extracting, message: "正在安全解压扩展包")
            try await Task.detached(priority: .userInitiated) {
                try ChromeExtensionZIPExtractor.extract(archive, to: extractedURL)
            }.value

            setCatalogInstallState(extensionID, phase: .importing, message: "正在导入 Rex 受管扩展目录")
            try await Task.detached(priority: .userInitiated) {
                try ChromeExtensionManifestIdentity.ensurePublicKey(
                    in: extractedURL,
                    expectedExtensionID: extensionID,
                    publicKey: archive.publicKey
                )
            }.value
            let installed = try installVerifiedWebStorePackage(
                from: extractedURL,
                extensionID: extensionID
            )
            setCatalogInstallState(
                extensionID,
                phase: .installed,
                message: "已从 Chrome Web Store 验签并安装到 Rex"
            )
            return installed
        } catch {
            let message = error.localizedDescription
            setCatalogInstallState(extensionID, phase: .failed, message: message)
            lastError = "无法安装 \(resolvedInstallName)：\(message)"
            throw error
        }
    }

    private func setCatalogInstallState(
        _ extensionID: String,
        phase: BrowserExtensionCatalogInstallPhase,
        message: String
    ) {
        catalogInstallStates[extensionID] = BrowserExtensionCatalogInstallState(
            extensionID: extensionID,
            phase: phase,
            message: message
        )
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
        try installPackage(
            from: sourceDirectory,
            storeID: nil,
            installationSource: .localUnpacked
        )
    }

    private func installVerifiedWebStorePackage(
        from sourceDirectory: URL,
        extensionID: String
    ) throws -> BrowserExtensionPackage {
        try installPackage(
            from: sourceDirectory,
            storeID: extensionID,
            installationSource: .chromeWebStore
        )
    }

    private func installPackage(
        from sourceDirectory: URL,
        storeID: String?,
        installationSource: BrowserExtensionPackage.InstallationSource
    ) throws -> BrowserExtensionPackage {
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
            let refreshed = try updateCatalogEntry(
                package(
                    from: parsed,
                    id: managedSource.id,
                    path: managedSource.path,
                    installedAt: managedSource.installedAt,
                    isEnabled: managedSource.isEnabled,
                    storeID: storeID,
                    installationSource: installationSource
                )
            )
            if refreshed.isEnabled {
                // Existing JS/CSS files can change without changing the
                // directory or manifest stat used by the native fast path.
                forcedRuntimeReloadPackageIDs.insert(refreshed.id)
            }
            return refreshed
        }

        guard source.path != packagesDirectoryURL.path,
              !isDescendant(source, of: packagesDirectoryURL) else {
            throw ExtensionStoreError.unsafeSourceDirectory
        }

        let proposedPackageID = packageIdentifier(for: parsed, sourceDirectory: source)
        let existingPackage = storeID.flatMap { expectedStoreID in
            extensions.first { package in
                package.storeID == expectedStoreID
                    && isManagedPackageURL(package.path, id: package.id, requireExistingDirectory: false)
            }
        } ?? matchingExistingPackage(for: parsed, proposedID: proposedPackageID)
        let packageID = existingPackage?.id ?? proposedPackageID
        guard isSafePackageIdentifier(packageID) else {
            throw ExtensionStoreError.unsafePackagePath
        }
        guard pendingRuntimeReplacements[packageID] == nil else {
            throw ExtensionStoreError.runtimeSynchronizationPending
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
            ".runtime-backup-\(UUID().uuidString)",
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
        var replacement: PendingRuntimeReplacement?
        do {
            if hadExistingFiles {
                let preparedReplacement = PendingRuntimeReplacement(
                    token: UUID(),
                    packageID: packageID,
                    destination: destination,
                    backup: backup,
                    previousPackage: existingPackage,
                    phase: .prepared
                )
                pendingRuntimeReplacements[packageID] = preparedReplacement
                try persistPendingRuntimeReplacements()
                replacement = preparedReplacement
                try fileManager.moveItem(at: destination, to: backup)
                movedExistingFiles = true
            }
            try fileManager.moveItem(at: staging, to: destination)
            try validateImportTree(at: destination)
            let installedManifest = try parseManifest(in: destination)
            guard packageIdentifier(for: installedManifest, sourceDirectory: source) == proposedPackageID else {
                throw ExtensionStoreError.invalidManifest
            }
            if var replacement {
                replacement.phase = .swapped
                pendingRuntimeReplacements[packageID] = replacement
                try persistPendingRuntimeReplacements()
            }

            let installed = package(
                from: installedManifest,
                id: packageID,
                path: destination,
                installedAt: installedAt,
                isEnabled: isEnabled,
                storeID: storeID,
                installationSource: installationSource
            )
            let result = try updateCatalogEntry(installed)
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
            if replacement != nil {
                pendingRuntimeReplacements.removeValue(forKey: packageID)
                try? persistPendingRuntimeReplacements()
            }
            throw error
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for id: String) -> Bool {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return false }
        let previous = extensions[index]
        let hadForcedRuntimeReload = forcedRuntimeReloadPackageIDs.contains(id)
        extensions[index].isEnabled = enabled
        if enabled {
            extensions[index].removalRequestedAt = nil
        } else {
            forcedRuntimeReloadPackageIDs.remove(id)
        }
        extensions[index].updatedAt = .now
        extensions[index] = packageUpdatingRuntimeState(extensions[index])
        do {
            try persist()
            lastError = nil
            return true
        } catch {
            extensions[index] = previous
            if hadForcedRuntimeReload {
                forcedRuntimeReloadPackageIDs.insert(id)
            } else {
                forcedRuntimeReloadPackageIDs.remove(id)
            }
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
        let hadForcedRuntimeReload = forcedRuntimeReloadPackageIDs.contains(id)
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
            forcedRuntimeReloadPackageIDs.remove(id)
            do {
                try persist()
            } catch {
                extensions = previousExtensions
                if hadForcedRuntimeReload {
                    forcedRuntimeReloadPackageIDs.insert(id)
                }
                if canMoveFiles, fileManager.fileExists(atPath: quarantine.path) {
                    try? fileManager.moveItem(at: quarantine, to: package.path)
                }
                throw error
            }
            if fileManager.fileExists(atPath: quarantine.path) {
                try? fileManager.removeItem(at: quarantine)
            }
            if let storeID = package.storeID {
                catalogInstallStates[storeID] = nil
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

    var pendingRuntimeReplacementTokens: Set<UUID> {
        Set(pendingRuntimeReplacements.values.compactMap { replacement in
            replacement.phase == .committed ? nil : replacement.token
        })
    }

    var forcedRuntimeReloadPaths: [String] {
        extensions.compactMap { package in
            guard forcedRuntimeReloadPackageIDs.contains(package.id),
                  package.isEnabled,
                  package.runtimeStatus == .ready || package.runtimeStatus == .pendingRuntime else {
                return nil
            }
            return package.path.path
        }
    }

    func acknowledgeForcedRuntimeReloadPaths(_ paths: [String]) {
        let acknowledgedPaths = Set(paths.map {
            URL(fileURLWithPath: $0)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        })
        forcedRuntimeReloadPackageIDs.subtract(extensions.compactMap { package in
            let packagePath = package.path
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            return acknowledgedPaths.contains(packagePath) ? package.id : nil
        })
    }

    /// Restores packages replaced on disk before Chromium acknowledged their
    /// new manifest identity and version.
    @discardableResult
    func rollbackPendingRuntimeReplacements(tokens: Set<UUID>) throws -> Bool {
        let replacements = pendingRuntimeReplacements.values
            .filter { tokens.contains($0.token) && $0.phase != .committed }
            .sorted { $0.packageID < $1.packageID }
        guard !replacements.isEmpty else { return false }
        try prepareManagedDirectories()

        typealias RestoredReplacement = (
            replacement: PendingRuntimeReplacement,
            displaced: URL?
        )
        let previousExtensions = extensions
        var restored: [RestoredReplacement] = []

        do {
            for replacement in replacements {
                guard isManagedPackageURL(
                    replacement.destination,
                    id: replacement.packageID,
                    requireExistingDirectory: false
                ),
                isRuntimeBackupURL(replacement.backup),
                isTrustedDirectory(replacement.backup) else {
                    throw ExtensionStoreError.recoveryRequired(replacement.backup)
                }

                var displaced: URL?
                if fileManager.fileExists(atPath: replacement.destination.path) {
                    guard isManagedPackageURL(
                        replacement.destination,
                        id: replacement.packageID,
                        requireExistingDirectory: true
                    ) else {
                        throw ExtensionStoreError.recoveryRequired(replacement.backup)
                    }
                    let failedReplacement = packagesDirectoryURL.appendingPathComponent(
                        ".failed-runtime-update-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    try fileManager.moveItem(
                        at: replacement.destination,
                        to: failedReplacement
                    )
                    displaced = failedReplacement
                }

                do {
                    try fileManager.moveItem(
                        at: replacement.backup,
                        to: replacement.destination
                    )
                } catch {
                    if let displaced {
                        try? fileManager.moveItem(
                            at: displaced,
                            to: replacement.destination
                        )
                    }
                    throw ExtensionStoreError.recoveryRequired(replacement.backup)
                }
                restored.append((replacement, displaced))
            }

            for replacement in replacements {
                extensions.removeAll { $0.id == replacement.packageID }
                if let previousPackage = replacement.previousPackage {
                    extensions.append(previousPackage)
                }
            }
            extensions.sort { $0.updatedAt > $1.updatedAt }
            extensions = extensions.map(packageUpdatingRuntimeState)
            try persist()
        } catch {
            extensions = previousExtensions
            for item in restored.reversed() {
                let replacement = item.replacement
                if fileManager.fileExists(atPath: replacement.destination.path) {
                    try? fileManager.moveItem(
                        at: replacement.destination,
                        to: replacement.backup
                    )
                }
                if let displaced = item.displaced,
                   fileManager.fileExists(atPath: displaced.path) {
                    try? fileManager.moveItem(
                        at: displaced,
                        to: replacement.destination
                    )
                }
            }
            throw error
        }

        for replacement in replacements {
            pendingRuntimeReplacements.removeValue(
                forKey: replacement.packageID
            )
        }
        try persistPendingRuntimeReplacements()
        for item in restored {
            if let displaced = item.displaced,
               fileManager.fileExists(atPath: displaced.path) {
                try? fileManager.removeItem(at: displaced)
            }
        }
        return true
    }

    func acknowledgeRuntimePaths(_ paths: [String]) {
        let loadedPaths = Set(paths.compactMap { path -> String? in
            guard !path.isEmpty, URL(fileURLWithPath: path).isFileURL else { return nil }
            return URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        })
        runtimeLoadedPackageIDs = Set(extensions.compactMap { package in
            let packagePath = package.path
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            return loadedPaths.contains(packagePath) ? package.id : nil
        })
        extensions = extensions.map(packageUpdatingRuntimeState)
        lastError = nil
    }

    func recordRuntimeSyncFailure(_ error: Error, loadedPaths: [String]? = nil) {
        if let loadedPaths {
            acknowledgeRuntimePaths(loadedPaths)
        } else {
            extensions = extensions.map { package in
                var result = packageUpdatingRuntimeState(package)
                if result.isEnabled,
                   ![.invalidManifest, .missingFiles].contains(result.runtimeStatus) {
                    result.runtimeStatus = .pendingRuntime
                    result.statusDetail = "Chromium 扩展运行时同步失败：\(error.localizedDescription)"
                }
                return result
            }
        }
        lastError = "无法同步扩展运行时：\(error.localizedDescription)"
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

    func commitPendingRuntimeReplacements(tokens: Set<UUID>) -> [String] {
        var failures: [String] = []
        for (packageID, replacement) in Array(pendingRuntimeReplacements) {
            guard tokens.contains(replacement.token),
                  replacement.phase != .committed else { continue }
            guard isRuntimeBackupURL(replacement.backup) else {
                failures.append(packageID)
                continue
            }
            do {
                var committed = replacement
                committed.phase = .committed
                pendingRuntimeReplacements[packageID] = committed
                try persistPendingRuntimeReplacements()
                if fileManager.fileExists(atPath: replacement.backup.path) {
                    try fileManager.removeItem(at: replacement.backup)
                }
                pendingRuntimeReplacements.removeValue(forKey: packageID)
                try persistPendingRuntimeReplacements()
            } catch {
                if var pending = pendingRuntimeReplacements[packageID] {
                    pending.phase = .committed
                    pendingRuntimeReplacements[packageID] = pending
                    try? persistPendingRuntimeReplacements()
                }
                failures.append("\(packageID)：\(error.localizedDescription)")
            }
        }
        return failures
    }

    private func recoverPendingRuntimeReplacementsFromPreviousLaunch() throws {
        try prepareManagedDirectories()
        guard fileManager.fileExists(atPath: runtimeReplacementsURL.path) else {
            return
        }
        let data = try boundedRegularFileData(
            at: runtimeReplacementsURL,
            maximumByteCount: ImportLimits.maximumRuntimeJournalBytes,
            label: "runtime-replacements.json"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let replacements = try decoder.decode([PendingRuntimeReplacement].self, from: data)
        var decodedByPackageID: [String: PendingRuntimeReplacement] = [:]
        var tokens = Set<UUID>()
        for replacement in replacements {
            guard decodedByPackageID[replacement.packageID] == nil,
                  tokens.insert(replacement.token).inserted,
                  isManagedPackageURL(
                    replacement.destination,
                    id: replacement.packageID,
                    requireExistingDirectory: false
                  ),
                  isRuntimeBackupURL(replacement.backup),
                  replacement.previousPackage.map({
                      $0.id == replacement.packageID
                          && $0.path.standardizedFileURL
                              == replacement.destination.standardizedFileURL
                  }) ?? true else {
                throw ExtensionStoreError.unsafePackagePath
            }
            decodedByPackageID[replacement.packageID] = replacement
        }
        pendingRuntimeReplacements = decodedByPackageID

        for replacement in replacements where replacement.phase == .committed {
            if fileManager.fileExists(atPath: replacement.backup.path) {
                guard isTrustedDirectory(replacement.backup) else {
                    throw ExtensionStoreError.recoveryRequired(replacement.backup)
                }
                try fileManager.removeItem(at: replacement.backup)
            }
            pendingRuntimeReplacements.removeValue(forKey: replacement.packageID)
        }
        try persistPendingRuntimeReplacements()

        let rollbackTokens = Set(pendingRuntimeReplacements.values.compactMap { replacement in
            fileManager.fileExists(atPath: replacement.backup.path)
                ? replacement.token
                : nil
        })
        if !rollbackTokens.isEmpty {
            try rollbackPendingRuntimeReplacements(tokens: rollbackTokens)
        }

        var catalogChanged = false
        for replacement in Array(pendingRuntimeReplacements.values) {
            guard replacement.phase != .committed else { continue }
            if let previousPackage = replacement.previousPackage {
                guard isManagedPackageURL(
                    replacement.destination,
                    id: replacement.packageID,
                    requireExistingDirectory: true
                ) else {
                    throw ExtensionStoreError.recoveryRequired(replacement.backup)
                }
                let restoredPackage = revalidatedPackage(previousPackage)
                guard restoredPackage.version == previousPackage.version,
                      restoredPackage.runtimeID == previousPackage.runtimeID else {
                    throw ExtensionStoreError.recoveryRequired(replacement.backup)
                }
                extensions.removeAll { $0.id == replacement.packageID }
                extensions.append(restoredPackage)
            } else {
                extensions.removeAll { $0.id == replacement.packageID }
            }
            pendingRuntimeReplacements.removeValue(forKey: replacement.packageID)
            catalogChanged = true
        }
        if catalogChanged {
            extensions.sort { $0.updatedAt > $1.updatedAt }
            try persist()
        }
        try persistPendingRuntimeReplacements()
    }

    private func persistPendingRuntimeReplacements() throws {
        try prepareManagedDirectories()
        if pendingRuntimeReplacements.isEmpty {
            if fileManager.fileExists(atPath: runtimeReplacementsURL.path) {
                let values = try runtimeReplacementsURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw ExtensionStoreError.unsafeManagedRoot
                }
                try fileManager.removeItem(at: runtimeReplacementsURL)
            }
            return
        }
        if fileManager.fileExists(atPath: runtimeReplacementsURL.path) {
            let values = try runtimeReplacementsURL.resourceValues(forKeys: [
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
        let replacements = pendingRuntimeReplacements.values.sorted {
            $0.packageID < $1.packageID
        }
        let data = try encoder.encode(replacements)
        try data.write(to: runtimeReplacementsURL, options: .atomic)
    }

    private func isRuntimeBackupURL(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        return candidate.deletingLastPathComponent() == packagesDirectoryURL.standardizedFileURL
            && candidate.lastPathComponent.hasPrefix(".runtime-backup-")
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
            let runtimeID = runtimeIdentifier(for: parsed, packagePath: result.path)
            result.runtimeID = runtimeID
            result.actionPopupRelativePath = parsed.actionPopupRelativePath
            result.optionsRelativePath = parsed.optionsRelativePath

            if result.resolvedInstallationSource == .chromeWebStore {
                guard let storeID = result.storeID,
                      BrowserExtensionCatalog.isValidChromeExtensionID(storeID),
                      let identityKey = parsed.identityKey,
                      let publicKey = Data(base64Encoded: identityKey),
                      !publicKey.isEmpty,
                      runtimeID == storeID else {
                    result.runtimeStatus = .invalidManifest
                    result.statusDetail =
                        "Chrome Web Store 扩展身份与验签安装记录不一致；请重新安装此扩展。"
                    return result
                }
            }

            result.runtimeStatus = if result.isEnabled {
                runtimeLoadedPackageIDs.contains(result.id) ? .ready : .pendingRuntime
            } else {
                .disabled
            }
            result.statusDetail = runtimeStatusDetail(for: result)
        } catch {
            result.runtimeStatus = .invalidManifest
            result.statusDetail = error.localizedDescription
        }
        return result
    }

    private func packageUpdatingRuntimeState(
        _ package: BrowserExtensionPackage
    ) -> BrowserExtensionPackage {
        var result = package
        guard ![.invalidManifest, .missingFiles].contains(result.runtimeStatus) else {
            return result
        }
        result.runtimeStatus = if result.isEnabled {
            runtimeLoadedPackageIDs.contains(result.id) ? .ready : .pendingRuntime
        } else {
            .disabled
        }
        result.statusDetail = runtimeStatusDetail(for: result)
        return result
    }

    private func package(
        from manifest: ParsedManifest,
        id: String,
        path: URL,
        installedAt: Date,
        isEnabled: Bool,
        storeID: String?,
        installationSource: BrowserExtensionPackage.InstallationSource
    ) -> BrowserExtensionPackage {
        let statusDetail: String? = if isEnabled {
            switch installationSource {
            case .chromeWebStore:
                "已从 Chrome Web Store 下载、验签并安装；正在交给 Chromium 扩展运行时加载。"
            case .localUnpacked:
                "扩展已导入；正在交给 Chromium 扩展运行时加载。"
            }
        } else {
            nil
        }
        return BrowserExtensionPackage(
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
            statusDetail: statusDetail,
            storeID: storeID,
            installationSource: installationSource,
            runtimeID: runtimeIdentifier(for: manifest, packagePath: path),
            actionPopupRelativePath: manifest.actionPopupRelativePath,
            optionsRelativePath: manifest.optionsRelativePath
        )
    }

    private func runtimeStatusDetail(for package: BrowserExtensionPackage) -> String? {
        if package.removalRequestedAt != nil {
            return "扩展正在从 Chromium 卸载并清理文件。"
        }
        return switch package.runtimeStatus {
        case .ready:
            "扩展包已在本次启动时交给 Chromium；后台服务、内容脚本和 Chrome API 由扩展自身运行。"
        case .pendingRuntime:
            "扩展已安装，正在与 Chromium 运行时同步。"
        case .disabled:
            runtimeLoadedPackageIDs.contains(package.id)
                ? "扩展已停用，正在从 Chromium 运行时卸载。"
                : nil
        case .invalidManifest, .missingFiles:
            package.statusDetail
        }
    }

    private func purgePendingRemovalsFromPreviousLaunch() {
        guard extensions.contains(where: { $0.removalRequestedAt != nil }) else { return }

        var retained: [BrowserExtensionPackage] = []
        var didChange = false
        var cleanupErrors: [String] = []

        for package in extensions {
            guard package.removalRequestedAt != nil else {
                retained.append(package)
                continue
            }

            let packageExists = fileManager.fileExists(atPath: package.path.path)
            guard packageExists else {
                didChange = true
                continue
            }
            guard isManagedPackageURL(
                package.path,
                id: package.id,
                requireExistingDirectory: true
            ) else {
                // A tampered record must never delete a path outside Rex's
                // managed package directory.
                didChange = true
                continue
            }

            do {
                try fileManager.removeItem(at: package.path)
                didChange = true
            } catch {
                var failedPackage = package
                failedPackage.isEnabled = false
                failedPackage.runtimeStatus = .disabled
                failedPackage.statusDetail =
                    "上次请求的扩展移除尚未完成：\(error.localizedDescription)"
                retained.append(failedPackage)
                cleanupErrors.append(package.name)
            }
        }

        guard didChange else {
            extensions = retained
            if !cleanupErrors.isEmpty {
                lastError = "无法完成扩展移除：\(cleanupErrors.joined(separator: "、"))"
            }
            return
        }

        let previousExtensions = extensions
        extensions = retained
        do {
            try persist()
            if cleanupErrors.isEmpty {
                lastError = nil
            } else {
                lastError = "无法完成扩展移除：\(cleanupErrors.joined(separator: "、"))"
            }
        } catch {
            extensions = previousExtensions
            lastError = "无法保存扩展移除结果：\(error.localizedDescription)"
        }
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

        let localizedMessages = try localizedManifestMessages(
            for: [manifest["name"], manifest["description"]],
            manifest: manifest,
            directory: directory
        )
        let name = try localizedManifestValue(
            manifest["name"],
            messages: localizedMessages,
            required: true
        )
        let version = (manifest["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name.count <= 256,
              let version, !version.isEmpty, version.count <= 128 else {
            throw ExtensionStoreError.invalidManifest
        }

        let description = try localizedManifestValue(
            manifest["description"],
            messages: localizedMessages,
            required: false
        ) ?? ""
        let author = (manifest["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let homepageURL = safeWebURL(from: manifest["homepage_url"] as? String)
        let key = (manifest["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (manifest["action"] as? [String: Any])
            ?? (manifest["browser_action"] as? [String: Any])
        let actionPopupRelativePath = safeExtensionPagePath(
            action?["default_popup"] as? String,
            directory: directory
        )
        let optionsRelativePath = safeExtensionPagePath(
            (manifest["options_ui"] as? [String: Any])?["page"] as? String
                ?? manifest["options_page"] as? String,
            directory: directory
        )

        return ParsedManifest(
            name: name,
            version: version,
            description: description,
            author: author?.isEmpty == false ? author : nil,
            homepageURL: homepageURL,
            manifestVersion: manifestVersion,
            permissions: Self.extractPermissions(from: manifest),
            iconRelativePath: preferredIconPath(from: manifest, directory: directory),
            identityKey: key?.isEmpty == false ? key : nil,
            actionPopupRelativePath: actionPopupRelativePath,
            optionsRelativePath: optionsRelativePath
        )
    }

    private func safeExtensionPagePath(_ value: String?, directory: URL) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !trimmed.contains("?"),
              !trimmed.contains("#") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let candidate = directory.appendingPathComponent(trimmed).standardizedFileURL
        guard isDescendant(candidate, of: directory),
              let values = try? candidate.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return trimmed
    }

    private func runtimeIdentifier(for manifest: ParsedManifest, packagePath: URL) -> String {
        if let identityKey = manifest.identityKey,
           let publicKey = Data(base64Encoded: identityKey),
           !publicKey.isEmpty {
            return ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
        }
        let canonicalPath = packagePath.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(canonicalPath.utf8)).prefix(16).flatMap { byte in
            [
                Character(UnicodeScalar(97 + Int(byte >> 4))!),
                Character(UnicodeScalar(97 + Int(byte & 0x0f))!)
            ]
        }.reduce(into: "") { $0.append($1) }
    }

    private func localizedManifestValue(
        _ value: Any?,
        messages: [String: Any]?,
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
              let messages,
              let record = messages[messageKey] as? [String: Any],
              let message = record["message"] as? String,
              !message.isEmpty else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(messageKey)
        }
        return message
    }

    private func localizedManifestMessages(
        for values: [Any?],
        manifest: [String: Any],
        directory: URL
    ) throws -> [String: Any]? {
        let needsMessages = values.contains { value in
            guard let rawValue = value as? String else { return false }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("__MSG_") && trimmed.hasSuffix("__")
        }
        guard needsMessages else { return nil }
        let unresolvedKey = values.compactMap { value -> String? in
            guard let rawValue = value as? String else { return nil }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("__MSG_"), trimmed.hasSuffix("__") else { return nil }
            return String(trimmed.dropFirst(6).dropLast(2))
        }.first ?? ""
        guard let locale = manifest["default_locale"] as? String,
              locale.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(unresolvedKey)
        }
        let messagesURL = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard fileManager.fileExists(atPath: messagesURL.path) else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(unresolvedKey)
        }
        let data = try boundedRegularFileData(
            at: messagesURL,
            maximumByteCount: ImportLimits.maximumMessagesBytes,
            label: "messages.json"
        )
        guard let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionStoreError.unresolvedLocalizedMessage(unresolvedKey)
        }
        return messages
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

        if fileManager.fileExists(atPath: stagingDirectoryURL.path) {
            guard isTrustedDirectory(stagingDirectoryURL) else {
                throw ExtensionStoreError.unsafeManagedRoot
            }
        } else {
            try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)
            guard isTrustedDirectory(stagingDirectoryURL) else {
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
        let actionPopupRelativePath: String?
        let optionsRelativePath: String?
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
    case runtimeSynchronizationPending
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
        case .runtimeSynchronizationPending:
            "上一轮扩展更新仍在等待 Chromium 确认，请稍后重试。"
        case .recoveryRequired(let backupURL):
            "无法自动恢复原扩展，旧文件保留在 \(backupURL.lastPathComponent)。"
        }
    }
}
