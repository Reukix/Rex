import Foundation
import Testing
@testable import RexApp

private struct ExtensionTestPaths {
    let sandbox: URL
    let source: URL
    let storeRoot: URL

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("rex-extension-tests-\(UUID().uuidString)", isDirectory: true)
        source = sandbox.appendingPathComponent("Source", isDirectory: true)
        storeRoot = sandbox.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }
}

private func writeManifest(_ manifest: [String: Any], to directory: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
}

private func writeFile(_ data: Data, relativePath: String, in directory: URL) throws {
    let destination = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
}

private func validManifest(
    manifestVersion: Any = 3,
    version: String = "1.0.0",
    key: String? = "stable-test-key"
) -> [String: Any] {
    var manifest: [String: Any] = [
        "manifest_version": manifestVersion,
        "name": "Rex Test Extension",
        "version": version,
        "description": "A local test extension",
        "author": "Rex Tests",
        "homepage_url": "https://example.com/extension",
        "permissions": ["storage", "tabs"],
        "optional_permissions": ["bookmarks"],
        "host_permissions": ["https://example.com/*"]
    ]
    if let key { manifest["key"] = key }
    return manifest
}

private struct LegacyExtensionPackage: Encodable {
    let id: String
    let name: String
    let version: String
    let description: String
    let author: String?
    let homepageURL: URL?
    let path: URL
    let isEnabled: Bool
    let permissions: [String]
    let runtimeStatus: String
    let installedAt: Date
    let updatedAt: Date
}

@Test("iCloud Passwords reports an Apple native connection limitation without changing runtime state")
func iCloudPasswordsNativeConnectionLimitationIsComputed() throws {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let package = BrowserExtensionPackage(
        id: "local-icloud-passwords",
        name: "iCloud Passwords",
        version: "3.3.0",
        description: "",
        author: nil,
        homepageURL: nil,
        path: URL(fileURLWithPath: "/tmp/icloud-passwords"),
        isEnabled: true,
        permissions: ["nativeMessaging"],
        runtimeStatus: .ready,
        installedAt: timestamp,
        updatedAt: timestamp,
        manifestVersion: 3,
        iconRelativePath: nil,
        statusDetail: "扩展包已在本次启动时交给 Chromium。",
        storeID: BrowserExtensionPackage.iCloudPasswordsExtensionID,
        installationSource: .chromeWebStore,
        runtimeID: BrowserExtensionPackage.iCloudPasswordsExtensionID
    )

    #expect(package.runtimeStatus == .ready)
    #expect(
        package.appleNativeConnectionLimitation ==
            BrowserExtensionPackage.iCloudPasswordsNativeConnectionLimitation
    )

    let encoded = try JSONEncoder().encode(package)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("appleNativeConnectionLimitation"))
    let decoded = try JSONDecoder().decode(BrowserExtensionPackage.self, from: encoded)
    #expect(decoded.runtimeStatus == .ready)
    #expect(decoded.appleNativeConnectionLimitation != nil)

    var unrelated = package
    unrelated.storeID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    unrelated.runtimeID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    #expect(unrelated.appleNativeConnectionLimitation == nil)
}

private final class CorruptingMoveFileManager: FileManager, @unchecked Sendable {
    var corruptNextImportedDestination = false

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.moveItem(at: sourceURL, to: destinationURL)
        guard corruptNextImportedDestination,
              sourceURL.lastPathComponent.hasPrefix(".import-"),
              destinationURL.lastPathComponent.hasPrefix("local-") else { return }
        corruptNextImportedDestination = false
        try Data("{broken".utf8).write(
            to: destinationURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}

private actor ExtensionRuntimeTestEngine: BrowserEngine {
    enum Failure: LocalizedError {
        case synchronization

        var errorDescription: String? { "Simulated extension runtime failure" }
    }

    private let observedPackagePath: String
    private var failNextSync = false
    private var synchronizedPathSets: [[String]] = []
    private var synchronizedManagedPathSets: [[String]] = []
    private var removedPathSets: [[String]] = []
    private var forcedReloadPathSets: [[String]] = []
    private var synchronizedVersions: [String?] = []
    private var packageExistedDuringEmptySync = false
    private var blockNextSync = false
    private var blockedSyncContinuation: CheckedContinuation<Void, Never>?

    init(observedPackagePath: String) {
        self.observedPackagePath = observedPackagePath
    }

    func execute(_ command: BrowserCommand) async throws {
        guard case let .reloadExtensionRules(
            managedPaths,
            enabledPaths,
            removedPaths,
            forceReloadPaths
        ) = command else { return }
        synchronizedManagedPathSets.append(managedPaths)
        synchronizedPathSets.append(enabledPaths)
        removedPathSets.append(removedPaths)
        forcedReloadPathSets.append(forceReloadPaths)
        synchronizedVersions.append(
            enabledPaths.first.flatMap { path in
                let manifestURL = URL(fileURLWithPath: path)
                    .appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return manifest["version"] as? String
            }
        )
        if removedPaths.contains(observedPackagePath) {
            packageExistedDuringEmptySync =
                FileManager.default.fileExists(atPath: observedPackagePath)
        }
        if blockNextSync {
            blockNextSync = false
            await withCheckedContinuation { continuation in
                blockedSyncContinuation = continuation
            }
        }
        if failNextSync {
            failNextSync = false
            throw Failure.synchronization
        }
    }

    func eventStream() -> AsyncStream<BrowserEvent> {
        AsyncStream { $0.finish() }
    }

    func failNextExtensionSync() {
        failNextSync = true
    }

    func blockNextExtensionSync() {
        blockNextSync = true
    }

    func waitForBlockedExtensionSync() async {
        while blockedSyncContinuation == nil {
            await Task.yield()
        }
    }

    func resumeBlockedExtensionSync() {
        blockedSyncContinuation?.resume()
        blockedSyncContinuation = nil
    }

    func syncPathSets() -> [[String]] {
        synchronizedPathSets
    }

    func managedPathSets() -> [[String]] {
        synchronizedManagedPathSets
    }

    func removedPaths() -> [[String]] {
        removedPathSets
    }

    func syncVersions() -> [String?] {
        synchronizedVersions
    }

    func latestForcedReloadPaths() -> [String] {
        forcedReloadPathSets.last ?? []
    }

    func sawPackageDuringEmptySync() -> Bool {
        packageExistedDuringEmptySync
    }

    func waitForSyncCount(_ count: Int) async {
        while synchronizedPathSets.count < count {
            await Task.yield()
        }
    }
}

private func writeLegacyCatalog(
    _ packages: [LegacyExtensionPackage],
    to storeRoot: URL
) throws {
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(packages).write(
        to: storeRoot.appendingPathComponent("catalog.json"),
        options: .atomic
    )
}

@Test("Extension execution capabilities and hot runtime boundary are explicit")
func extensionRuntimeCapabilitiesAreExplicit() {
    let capabilities = BrowserExtensionRuntimeCapabilities.current
    #expect(capabilities.supportsChromeWebStoreInstall)
    #expect(capabilities.supportsCRXInstall)
    #expect(capabilities.supportsUnpackedExecution)
    #expect(capabilities.supportsManifestV3Execution)
    #expect(capabilities.supportsExtensionOwnedPages)
    #expect(!capabilities.supportsNativeExtensionSurfaces)
    #expect(capabilities.supportsChromeTabContext)
    #expect(!capabilities.supportsExactDomainDNR)
    #expect(capabilities.limitationText.contains("Chromium"))
    #expect(capabilities.limitationText.contains("活动标签"))
    #expect(capabilities.limitationText.contains("activeTab"))
    #expect(capabilities.limitationText.contains("立即同步"))
}

@Test("Curated extension catalog uses validated official URLs and local filters")
func extensionCatalogUsesOfficialURLs() throws {
    #expect(!BrowserExtensionCatalog.items.isEmpty)
    for item in BrowserExtensionCatalog.items {
        #expect(BrowserExtensionCatalog.isValidChromeExtensionID(item.id))
        #expect(item.officialURL.scheme == "https")
        #expect(item.officialURL.host == BrowserExtensionCatalog.sourceHost)
    }

    let recommended = BrowserExtensionCatalog.filteredItems(query: "", filter: .recommended)
    #expect(recommended.allSatisfy { $0.isRecommended })
    let privacy = BrowserExtensionCatalog.filteredItems(query: "", filter: .privacy)
    #expect(privacy.allSatisfy { $0.category == .privacy })
    let darkReader = BrowserExtensionCatalog.filteredItems(query: "dark reader", filter: .all)
    #expect(darkReader.map(\.name) == ["Dark Reader"])

    let searchURL = try #require(BrowserExtensionCatalog.chromeWebStoreSearchURL(query: "dark reader/安全"))
    #expect(searchURL.scheme == "https")
    #expect(searchURL.host == BrowserExtensionCatalog.sourceHost)
    #expect(searchURL.absoluteString.contains("dark%20reader%2F"))
    #expect(BrowserExtensionCatalog.chromeWebStoreSearchURL(query: "  ")?.absoluteString
        == "https://\(BrowserExtensionCatalog.sourceHost)/")

    let extensionID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    #expect(BrowserExtensionCatalog.extensionID(fromWebStoreInput: extensionID) == extensionID)
    #expect(BrowserExtensionCatalog.extensionID(
        fromWebStoreInput: "https://chromewebstore.google.com/detail/u-block-origin-lite/\(extensionID)?hl=zh-CN"
    ) == extensionID)
    #expect(BrowserExtensionCatalog.extensionID(
        fromWebStoreInput: "https://example.com/detail/\(extensionID)"
    ) == nil)
}

@Test("Manifest V3 import becomes ready after a simulated runtime restart")
@MainActor
func manifestV3ImportPersistsManagedPackage() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    var manifest = validManifest()
    manifest["icons"] = ["16": "icons/icon.bin", "128": "icons/icon-128.bin"]
    manifest["action"] = ["default_popup": "popup.html"]
    manifest["options_ui"] = ["page": "options.html", "open_in_tab": true]
    try writeManifest(manifest, to: paths.source)
    try writeFile(Data([0x01]), relativePath: "icons/icon.bin", in: paths.source)
    try writeFile(Data([0x02]), relativePath: "icons/icon-128.bin", in: paths.source)
    try writeFile(Data("<!doctype html><title>Popup</title>".utf8), relativePath: "popup.html", in: paths.source)
    try writeFile(
        Data("<!doctype html><title>Options</title>".utf8),
        relativePath: "options.html",
        in: paths.source
    )

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)

    #expect(imported.id.hasPrefix("local-"))
    #expect(imported.id.count == 38)
    #expect(imported.path.deletingLastPathComponent().lastPathComponent == "Packages")
    #expect(FileManager.default.fileExists(atPath: imported.path.path))
    #expect(imported.manifestVersion == 3)
    #expect(imported.runtimeStatus == .pendingRuntime)
    #expect(imported.statusDetail?.contains("正在") == true)
    #expect(imported.permissions == ["https://example.com/*", "optional:bookmarks", "storage", "tabs"])
    #expect(imported.iconRelativePath == "icons/icon-128.bin")
    #expect(imported.actionPopupRelativePath == "popup.html")
    #expect(imported.optionsRelativePath == "options.html")
    #expect(imported.actionPopupURL == nil)
    #expect(imported.optionsURL == nil)
    #expect(store.startupExtensionPaths.isEmpty)
    #expect(store.nativeRuleExtensionPaths == [imported.path.path])
    #expect(store.managedRuntimeExtensionPaths == [imported.path.path])

    let reloaded = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let persisted = try #require(reloaded.extensions.first)
    #expect(reloaded.extensions.count == 1)
    #expect(persisted.id == imported.id)
    #expect(persisted.runtimeStatus == .ready)
    #expect(persisted.homepageURL?.absoluteString == "https://example.com/extension")
    let runtimeID = try #require(persisted.runtimeID)
    #expect(persisted.actionPopupURL?.absoluteString
        == "rex-extension://\(runtimeID)/popup.html")
    #expect(persisted.optionsURL?.absoluteString
        == "rex-extension://\(runtimeID)/options.html")
    #expect(reloaded.setEnabled(true, for: persisted.id))
    #expect(reloaded.nativeRuleExtensionPaths == [persisted.path.path])
    #expect(reloaded.managedRuntimeExtensionPaths == [persisted.path.path])

    let reloadedAgain = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(reloadedAgain.extensions.first?.runtimeStatus == .ready)
    #expect(reloadedAgain.startupExtensionPaths == [persisted.path.path])
    #expect(reloadedAgain.managedRuntimeExtensionPaths == [persisted.path.path])
}

@Test("Manifest V2 is recognized while invalid manifest versions are rejected")
@MainActor
func manifestVersionsAreValidated() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(manifestVersion: 2), to: paths.source)
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)
    #expect(imported.manifestVersion == 2)
    #expect(imported.runtimeStatus == .pendingRuntime)

    try writeManifest(validManifest(manifestVersion: 4), to: paths.source)
    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("Manifest V4 should be rejected")
    } catch ExtensionStoreError.unsupportedManifestVersion(let version) {
        #expect(version == 4)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    try writeManifest(validManifest(manifestVersion: true), to: paths.source)
    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("A Boolean manifest version should be rejected")
    } catch ExtensionStoreError.missingManifestVersion {
        // Expected: JSON booleans must not bridge to NSNumber version values.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Missing and malformed manifests produce specific import errors")
@MainActor
func malformedManifestsAreRejected() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)

    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("A folder without manifest.json should be rejected")
    } catch ExtensionStoreError.missingManifest {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    try Data("{not-json".utf8).write(
        to: paths.source.appendingPathComponent("manifest.json"),
        options: .atomic
    )
    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("Malformed JSON should be rejected")
    } catch ExtensionStoreError.invalidManifest {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    var missingVersion = validManifest()
    missingVersion.removeValue(forKey: "manifest_version")
    try writeManifest(missingVersion, to: paths.source)
    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("A missing manifest_version should be rejected")
    } catch ExtensionStoreError.missingManifestVersion {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Localized manifest text resolves from the default locale")
@MainActor
func localizedManifestTextIsResolved() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    var manifest = validManifest()
    manifest["name"] = "__MSG_extensionName__"
    manifest["description"] = "__MSG_extensionDescription__"
    manifest["default_locale"] = "zh_CN"
    try writeManifest(manifest, to: paths.source)
    let messages: [String: Any] = [
        "extensionName": ["message": "本地化扩展"],
        "extensionDescription": ["message": "本地化描述"]
    ]
    let messagesData = try JSONSerialization.data(withJSONObject: messages, options: .sortedKeys)
    try writeFile(messagesData, relativePath: "_locales/zh_CN/messages.json", in: paths.source)

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)
    #expect(imported.name == "本地化扩展")
    #expect(imported.description == "本地化描述")
}

@Test("Reimport updates one package while preserving install date and enabled preference")
@MainActor
func reimportPreservesPackageIdentityAndPreference() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(key: "unsafe/key+=still-hashed"), to: paths.source)
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let first = try store.installUnpacked(from: paths.source)
    #expect(!first.id.contains("/"))
    #expect(store.setEnabled(false, for: first.id))

    try writeManifest(
        validManifest(version: "2.0.0", key: "unsafe/key+=still-hashed"),
        to: paths.source
    )
    let updated = try store.installUnpacked(from: paths.source)
    #expect(store.extensions.count == 1)
    #expect(updated.id == first.id)
    #expect(updated.installedAt == first.installedAt)
    #expect(updated.version == "2.0.0")
    #expect(!updated.isEnabled)
    #expect(updated.runtimeStatus == .disabled)
    let replacementTokens = store.pendingRuntimeReplacementTokens
    store.acknowledgeRuntimePaths([])
    #expect(store.commitPendingRuntimeReplacements(tokens: replacementTokens).isEmpty)

    let reloaded = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(reloaded.extensions.first?.runtimeStatus == .disabled)
    #expect(reloaded.extensions.first?.version == "2.0.0")
    #expect(reloaded.setEnabled(true, for: first.id))
    #expect(reloaded.extensions.first?.runtimeStatus == .pendingRuntime)
}

@Test("A running local extension can be replaced and acknowledged without restart")
@MainActor
func runningLocalExtensionUpdatesInPlace() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(version: "1.0.0", key: nil), to: paths.source)

    let installingStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try installingStore.installUnpacked(from: paths.source)
    let runningStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installedManifestURL = installed.path.appendingPathComponent("manifest.json")
    let originalManifest = try Data(contentsOf: installedManifestURL)

    try writeManifest(validManifest(version: "2.0.0", key: nil), to: paths.source)
    let updated = try runningStore.installUnpacked(from: paths.source)

    #expect(updated.id == installed.id)
    #expect(updated.version == "2.0.0")
    #expect(updated.runtimeStatus == .pendingRuntime)
    #expect(try Data(contentsOf: installedManifestURL) != originalManifest)
    runningStore.acknowledgeRuntimePaths([updated.path.path])
    _ = runningStore.commitPendingRuntimeReplacements(
        tokens: runningStore.pendingRuntimeReplacementTokens
    )
    #expect(runningStore.extensions.first?.runtimeStatus == .ready)
    let packageEntries = try FileManager.default.contentsOfDirectory(
        atPath: paths.storeRoot.appendingPathComponent("Packages").path
    )
    #expect(!packageEntries.contains { $0.hasPrefix(".runtime-backup-") })
}

@Test("A package without a manifest key keeps its identity when its managed copy is selected")
@MainActor
func noKeyManagedCopyDoesNotDuplicatePackage() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(key: nil), to: paths.source)
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let first = try store.installUnpacked(from: paths.source)

    let refreshed = try store.installUnpacked(from: first.path)

    #expect(store.extensions.count == 1)
    #expect(refreshed.id == first.id)
    #expect(refreshed.path == first.path)
    #expect(store.forcedRuntimeReloadPaths == [first.path.path])
    #expect(FileManager.default.fileExists(atPath: first.path.appendingPathComponent("manifest.json").path))
}

@Test("Reimporting an edited managed payload forces a Chromium reload")
@MainActor
func editedManagedPayloadForcesRuntimeReload() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    try Data("globalThis.rexProbeVersion = 1;".utf8)
        .write(to: paths.source.appendingPathComponent("content.js"))
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)

    try Data("globalThis.rexProbeVersion = 2;".utf8)
        .write(to: installed.path.appendingPathComponent("content.js"))
    _ = try await browserStore.installUnpackedExtension(from: installed.path)

    #expect(await engine.latestForcedReloadPaths() == [installed.path.path])
    #expect(extensionsStore.forcedRuntimeReloadPaths.isEmpty)
}

@Test("A v0.8.1 no-key catalog entry is reused instead of duplicated on reimport")
@MainActor
func legacyNoKeyCatalogReimportIsMigratedInPlace() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let legacyID = "rex-test-extension-1.0.0"
    let legacyPath = paths.storeRoot
        .appendingPathComponent("Packages", isDirectory: true)
        .appendingPathComponent(legacyID, isDirectory: true)
    try FileManager.default.createDirectory(at: legacyPath, withIntermediateDirectories: true)
    try writeManifest(validManifest(key: nil), to: legacyPath)
    let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try writeLegacyCatalog([
        LegacyExtensionPackage(
            id: legacyID,
            name: "Rex Test Extension",
            version: "1.0.0",
            description: "A local test extension",
            author: "Rex Tests",
            homepageURL: URL(string: "https://example.com/extension"),
            path: legacyPath,
            isEnabled: true,
            permissions: ["storage", "tabs"],
            runtimeStatus: "pendingRuntime",
            installedAt: installedAt,
            updatedAt: installedAt
        )
    ], to: paths.storeRoot)

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(store.extensions.count == 1)
    #expect(store.setEnabled(false, for: legacyID))
    let stoppedStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    try writeManifest(validManifest(version: "2.0.0", key: nil), to: paths.source)

    let updated = try stoppedStore.installUnpacked(from: paths.source)

    #expect(stoppedStore.extensions.count == 1)
    #expect(updated.id == legacyID)
    #expect(updated.path.resolvingSymlinksInPath() == legacyPath.resolvingSymlinksInPath())
    #expect(updated.version == "2.0.0")
    #expect(updated.installedAt == installedAt)
    let replacementTokens = stoppedStore.pendingRuntimeReplacementTokens
    stoppedStore.acknowledgeRuntimePaths([])
    #expect(stoppedStore.commitPendingRuntimeReplacements(tokens: replacementTokens).isEmpty)
    let reloaded = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(reloaded.extensions.count == 1)
    #expect(reloaded.extensions.first?.id == legacyID)
    #expect(reloaded.extensions.first?.version == "2.0.0")
}

@Test("Selecting a symbolic link to a managed package cannot replace its files")
@MainActor
func managedPackageSourceSymbolicLinkIsHandledWithoutReplacement() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)
    let sourceLink = paths.sandbox.appendingPathComponent("ManagedPackageLink", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: imported.path)

    let refreshed = try store.installUnpacked(from: sourceLink)

    #expect(refreshed.id == imported.id)
    #expect(store.extensions.count == 1)
    #expect(FileManager.default.fileExists(atPath: imported.path.appendingPathComponent("manifest.json").path))
    #expect((try? imported.path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true)
}

@Test("A final-destination validation failure restores the previous package")
@MainActor
func failedFinalValidationRollsBackExistingPackage() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let fileManager = CorruptingMoveFileManager()
    try writeManifest(validManifest(version: "1.0.0"), to: paths.source)
    let store = BrowserExtensionsStore(
        fileManager: fileManager,
        rootDirectoryURL: paths.storeRoot
    )
    let original = try store.installUnpacked(from: paths.source)
    try writeManifest(validManifest(version: "2.0.0"), to: paths.source)
    fileManager.corruptNextImportedDestination = true

    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("A corrupted final destination should fail validation")
    } catch ExtensionStoreError.invalidManifest {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let reloaded = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(reloaded.extensions.count == 1)
    #expect(reloaded.extensions.first?.id == original.id)
    #expect(reloaded.extensions.first?.version == "1.0.0")
    #expect(FileManager.default.fileExists(atPath: original.path.appendingPathComponent("manifest.json").path))
    #expect((try? Data(contentsOf: original.path.appendingPathComponent("manifest.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil)
}

@Test("A symbolic-link manifest is rejected before any managed files are changed")
@MainActor
func symbolicLinkManifestIsRejected() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let externalDirectory = paths.sandbox.appendingPathComponent("ExternalManifest", isDirectory: true)
    try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
    try writeManifest(validManifest(), to: externalDirectory)
    try FileManager.default.createSymbolicLink(
        at: paths.source.appendingPathComponent("manifest.json"),
        withDestinationURL: externalDirectory.appendingPathComponent("manifest.json")
    )
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)

    do {
        _ = try store.installUnpacked(from: paths.source)
        Issue.record("A symbolic-link manifest should be rejected")
    } catch ExtensionStoreError.symbolicLinksNotAllowed {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(store.extensions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent("manifest.json").path))
}

@Test("Managed packages can be removed and missing files are reported")
@MainActor
func managedPackageRemovalAndMissingFileState() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)
    try FileManager.default.removeItem(at: imported.path)

    let missingStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(missingStore.extensions.first?.runtimeStatus == .missingFiles)
    #expect(missingStore.remove(imported.id))
    #expect(missingStore.extensions.isEmpty)

    try writeManifest(validManifest(), to: paths.source)
    let installedAgain = try missingStore.installUnpacked(from: paths.source)
    #expect(FileManager.default.fileExists(atPath: installedAgain.path.path))
    #expect(missingStore.remove(installedAgain.id))
    #expect(!FileManager.default.fileExists(atPath: installedAgain.path.path))
}

@Test("A running extension is removed immediately after runtime unload")
@MainActor
func runningExtensionRemovalIsImmediate() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)

    let installingStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try installingStore.installUnpacked(from: paths.source)
    let runningStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let runningPackage = try #require(runningStore.extensions.first)
    #expect(runningPackage.runtimeStatus == .ready)

    runningStore.acknowledgeRuntimePaths([])
    #expect(runningStore.remove(runningPackage.id))
    #expect(runningStore.extensions.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: imported.path.path))

    let restartedStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(restartedStore.extensions.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: imported.path.path))
}

@Test("Runtime acknowledgements track disable and re-enable without restart")
@MainActor
func runtimeAcknowledgementTracksEnableState() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)

    let installingStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    _ = try installingStore.installUnpacked(from: paths.source)
    let runningStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let runningPackage = try #require(runningStore.extensions.first)

    #expect(runningStore.setEnabled(false, for: runningPackage.id))
    runningStore.acknowledgeRuntimePaths([])
    #expect(runningStore.extensions.first?.runtimeStatus == .disabled)
    #expect(runningStore.setEnabled(true, for: runningPackage.id))
    #expect(runningStore.extensions.first?.runtimeStatus == .pendingRuntime)
    runningStore.acknowledgeRuntimePaths([runningPackage.path.path])
    #expect(runningStore.extensions.first?.runtimeStatus == .ready)
}

@Test("Private windows neither synchronize nor open extension runtime pages")
@MainActor
func privateWindowsExcludeExtensionRuntime() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    try writeFile(
        Data("<!doctype html><title>Private boundary</title>".utf8),
        relativePath: "options.html",
        in: paths.source
    )

    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    extensionsStore.acknowledgeRuntimePaths([installed.path.path])
    let runningPackage = try #require(extensionsStore.extensions.first)
    let optionsURL = try #require(
        runningPackage.resourceURL(relativePath: "options.html")
    )
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Private.sqlite"),
            legacyPersistence: nil
        ),
        profile: .privateWindow(),
        extensionsStore: extensionsStore
    )
    for _ in 0..<10 {
        await Task.yield()
    }

    #expect(!browserStore.isRunnableExtension(runtimeID: try #require(runningPackage.runtimeID)))
    let initialTabCount = browserStore.tabs.count
    browserStore.openExtensionPage(optionsURL, title: runningPackage.name)
    #expect(browserStore.tabs.count == initialTabCount)
    #expect(browserStore.lastError == "隐私窗口不运行或打开扩展页面。")
    #expect(await engine.syncPathSets().isEmpty)
}

@Test("A failed hot disable rolls back the persisted preference and runtime set")
@MainActor
func failedHotDisableRollsBack() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)
    #expect(extensionsStore.extensions.first?.runtimeStatus == .ready)

    await engine.failNextExtensionSync()
    #expect(!(await browserStore.setExtensionEnabled(false, id: installed.id)))
    #expect(extensionsStore.extensions.first?.isEnabled == true)
    #expect(extensionsStore.extensions.first?.runtimeStatus == .ready)
    #expect(extensionsStore.lastError?.contains("Simulated extension runtime failure") == true)
    #expect(Array((await engine.syncPathSets()).suffix(2)) == [[], [installed.path.path]])
    #expect(Array((await engine.managedPathSets()).suffix(2)) == [
        [installed.path.path],
        [installed.path.path]
    ])
    #expect(Array((await engine.removedPaths()).suffix(2)) == [[], []])
}

@Test("Hot disable and re-enable preserve the managed extension identity")
@MainActor
func hotEnableStateDoesNotRequestRemoval() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)

    #expect(await browserStore.setExtensionEnabled(false, id: installed.id))
    #expect(await browserStore.setExtensionEnabled(true, id: installed.id))
    #expect(Array((await engine.syncPathSets()).suffix(3)) == [
        [installed.path.path],
        [],
        [installed.path.path]
    ])
    #expect(Array((await engine.managedPathSets()).suffix(3)) == [
        [installed.path.path],
        [installed.path.path],
        [installed.path.path]
    ])
    #expect(Array((await engine.removedPaths()).suffix(3)) == [[], [], []])
}

@Test("A failed hot update restores and reloads the previous package version")
@MainActor
func failedHotUpdateRestoresPreviousVersion() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(version: "1.0.0"), to: paths.source)
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)

    try writeManifest(validManifest(version: "2.0.0"), to: paths.source)
    let updated = try extensionsStore.installUnpacked(from: paths.source)
    #expect(updated.version == "2.0.0")
    #expect(!extensionsStore.pendingRuntimeReplacementTokens.isEmpty)

    await engine.failNextExtensionSync()
    #expect(!(await browserStore.reloadExtensionRules()))
    #expect(extensionsStore.extensions.first?.version == "1.0.0")
    #expect(extensionsStore.extensions.first?.runtimeStatus == .ready)
    #expect(extensionsStore.pendingRuntimeReplacementTokens.isEmpty)
    #expect(Array((await engine.syncVersions()).suffix(2)) == ["2.0.0", "1.0.0"])

    let restoredManifestData = try Data(
        contentsOf: installed.path.appendingPathComponent("manifest.json")
    )
    let restoredManifest = try #require(
        JSONSerialization.jsonObject(with: restoredManifestData) as? [String: Any]
    )
    #expect(restoredManifest["version"] as? String == "1.0.0")
    let packageEntries = try FileManager.default.contentsOfDirectory(
        atPath: paths.storeRoot.appendingPathComponent("Packages").path
    )
    #expect(!packageEntries.contains { $0.hasPrefix(".runtime-backup-") })
    #expect(!packageEntries.contains { $0.hasPrefix(".failed-runtime-update-") })
}

@Test("An unacknowledged package update is restored after relaunch")
@MainActor
func unacknowledgedUpdateIsRecoveredAfterRelaunch() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(version: "1.0.0"), to: paths.source)
    let firstStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try firstStore.installUnpacked(from: paths.source)

    try writeManifest(validManifest(version: "2.0.0"), to: paths.source)
    let updated = try firstStore.installUnpacked(from: paths.source)
    #expect(updated.version == "2.0.0")
    #expect(!firstStore.pendingRuntimeReplacementTokens.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: paths.storeRoot.appendingPathComponent("runtime-replacements.json").path
    ))

    let recoveredStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(recoveredStore.extensions.first?.version == "1.0.0")
    #expect(recoveredStore.pendingRuntimeReplacementTokens.isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: paths.storeRoot.appendingPathComponent("runtime-replacements.json").path
    ))
    let restoredManifestData = try Data(
        contentsOf: installed.path.appendingPathComponent("manifest.json")
    )
    let restoredManifest = try #require(
        JSONSerialization.jsonObject(with: restoredManifestData) as? [String: Any]
    )
    #expect(restoredManifest["version"] as? String == "1.0.0")
    let packageEntries = try FileManager.default.contentsOfDirectory(
        atPath: paths.storeRoot.appendingPathComponent("Packages").path
    )
    #expect(!packageEntries.contains { $0.hasPrefix(".runtime-backup-") })
    #expect(!packageEntries.contains { $0.hasPrefix(".failed-runtime-update-") })
}

@Test("Hot removal unloads Chromium before deleting managed files")
@MainActor
func hotRemovalUnloadsBeforeDeletingFiles() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)

    #expect(await browserStore.removeExtension(installed.id))
    #expect(await engine.sawPackageDuringEmptySync())
    #expect((await engine.managedPathSets()).last == [])
    #expect((await engine.syncPathSets()).last == [])
    #expect((await engine.removedPaths()).last == [installed.path.path])
    #expect(!FileManager.default.fileExists(atPath: installed.path.path))
    #expect(extensionsStore.extensions.isEmpty)
}

@Test("Missing package files still request removal from Chromium")
@MainActor
func missingPackageFilesStillRequestRuntimeRemoval() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)
    try FileManager.default.removeItem(at: installed.path)

    #expect(await browserStore.removeExtension(installed.id))
    #expect((await engine.removedPaths()).last == [installed.path.path])
    #expect((await engine.managedPathSets()).last == [])
    #expect(extensionsStore.extensions.isEmpty)
}

@Test("Runtime mutations stay serialized while Chromium synchronization is suspended")
@MainActor
func runtimeMutationsRemainSerializedAcrossAwait() async throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let installed = try extensionsStore.installUnpacked(from: paths.source)
    let engine = ExtensionRuntimeTestEngine(observedPackagePath: installed.path.path)
    let browserStore = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: paths.sandbox.appendingPathComponent("Browser.sqlite"),
            legacyPersistence: nil
        ),
        extensionsStore: extensionsStore
    )
    await engine.waitForSyncCount(1)
    await engine.blockNextExtensionSync()

    let disableTask = Task { @MainActor in
        await browserStore.setExtensionEnabled(false, id: installed.id)
    }
    await engine.waitForBlockedExtensionSync()
    let removalTask = Task { @MainActor in
        await browserStore.removeExtension(installed.id)
    }
    for _ in 0..<20 {
        await Task.yield()
    }

    #expect(FileManager.default.fileExists(atPath: installed.path.path))
    #expect(extensionsStore.extensions.contains { $0.id == installed.id })
    #expect(extensionsStore.isRuntimeMutationInProgress)

    await engine.resumeBlockedExtensionSync()
    #expect(await disableTask.value)
    #expect(await removalTask.value)
    #expect(!FileManager.default.fileExists(atPath: installed.path.path))
    #expect(extensionsStore.extensions.isEmpty)
}

@Test("A Web Store record must keep its signed manifest identity")
@MainActor
func webStoreIdentityIsRevalidatedFromManifestKey() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let packageID = "local-web-store-identity"
    let packagePath = paths.storeRoot
        .appendingPathComponent("Packages", isDirectory: true)
        .appendingPathComponent(packageID, isDirectory: true)
    try FileManager.default.createDirectory(at: packagePath, withIntermediateDirectories: true)

    let publicKey = Data("signed-web-store-test-key".utf8)
    let runtimeID = ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
    try writeManifest(
        validManifest(key: publicKey.base64EncodedString()),
        to: packagePath
    )
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let package = BrowserExtensionPackage(
        id: packageID,
        name: "Web Store Identity",
        version: "1.0.0",
        description: "",
        author: nil,
        homepageURL: nil,
        path: packagePath,
        isEnabled: true,
        permissions: [],
        runtimeStatus: .ready,
        installedAt: timestamp,
        updatedAt: timestamp,
        manifestVersion: 3,
        iconRelativePath: nil,
        statusDetail: nil,
        storeID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        installationSource: .chromeWebStore,
        runtimeID: runtimeID
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([package]).write(
        to: paths.storeRoot.appendingPathComponent("catalog.json"),
        options: .atomic
    )

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(store.extensions.first?.runtimeStatus == .invalidManifest)
    #expect(store.extensions.first?.statusDetail?.contains("身份") == true)
    #expect(store.startupExtensionPaths.isEmpty)

    var malformedKeyPackage = package
    malformedKeyPackage.storeID = runtimeID
    try writeManifest(
        validManifest(key: publicKey.base64EncodedString() + "!"),
        to: packagePath
    )
    try encoder.encode([malformedKeyPackage]).write(
        to: paths.storeRoot.appendingPathComponent("catalog.json"),
        options: .atomic
    )

    let malformedKeyStore = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(malformedKeyStore.extensions.first?.runtimeStatus == .invalidManifest)
    #expect(malformedKeyStore.extensions.first?.statusDetail?.contains("身份") == true)
    #expect(malformedKeyStore.startupExtensionPaths.isEmpty)
}

@Test("Removing a tampered external catalog record never deletes external files")
@MainActor
func externalCatalogPathsAreNotDeleted() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let external = paths.sandbox.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let sentinel = external.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.createDirectory(at: paths.storeRoot, withIntermediateDirectories: true)

    let package = BrowserExtensionPackage(
        id: "local-tampered",
        name: "Tampered",
        version: "1.0",
        description: "",
        author: nil,
        homepageURL: nil,
        path: external,
        isEnabled: true,
        permissions: [],
        runtimeStatus: .pendingRuntime,
        installedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        manifestVersion: 3,
        iconRelativePath: nil,
        statusDetail: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([package]).write(
        to: paths.storeRoot.appendingPathComponent("catalog.json"),
        options: .atomic
    )

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(store.extensions.first?.runtimeStatus == .missingFiles)
    #expect(store.remove(package.id))
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
}

@Test("Replacing the managed Packages directory with a symbolic link blocks removal")
@MainActor
func symbolicLinkManagedRootCannotDeleteExternalDirectory() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    try writeManifest(validManifest(), to: paths.source)
    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)
    let packagesDirectory = imported.path.deletingLastPathComponent()
    try FileManager.default.removeItem(at: packagesDirectory)

    let externalRoot = paths.sandbox.appendingPathComponent("ExternalPackages", isDirectory: true)
    let externalPackage = externalRoot.appendingPathComponent(imported.id, isDirectory: true)
    try FileManager.default.createDirectory(at: externalPackage, withIntermediateDirectories: true)
    let sentinel = externalPackage.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: packagesDirectory, withDestinationURL: externalRoot)

    #expect(!store.remove(imported.id))
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
    #expect(store.extensions.count == 1)
}

@Test("A catalog record cannot delete a different managed package directory")
@MainActor
func mismatchedCatalogIDAndPathOnlyRemovesTheRecord() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let victimID = "local-victim"
    let victimPath = paths.storeRoot
        .appendingPathComponent("Packages", isDirectory: true)
        .appendingPathComponent(victimID, isDirectory: true)
    try FileManager.default.createDirectory(at: victimPath, withIntermediateDirectories: true)
    let sentinel = victimPath.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    try writeLegacyCatalog([
        LegacyExtensionPackage(
            id: "local-other-record",
            name: "Tampered",
            version: "1.0",
            description: "",
            author: nil,
            homepageURL: nil,
            path: victimPath,
            isEnabled: true,
            permissions: [],
            runtimeStatus: "pendingRuntime",
            installedAt: timestamp,
            updatedAt: timestamp
        )
    ], to: paths.storeRoot)

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(store.extensions.first?.runtimeStatus == .missingFiles)
    #expect(store.remove("local-other-record"))
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
}

@Test("Extension icons cannot escape the package through a symbolic link")
func extensionIconRejectsSymbolicLinkEscape() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    let packageDirectory = paths.sandbox.appendingPathComponent("Package", isDirectory: true)
    let externalIcon = paths.sandbox.appendingPathComponent("outside.png")
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    try Data([0x01]).write(to: externalIcon)
    try FileManager.default.createSymbolicLink(
        at: packageDirectory.appendingPathComponent("icon.png"),
        withDestinationURL: externalIcon
    )
    let package = BrowserExtensionPackage(
        id: "local-icon-test",
        name: "Icon Test",
        version: "1.0",
        description: "",
        author: nil,
        homepageURL: nil,
        path: packageDirectory,
        isEnabled: true,
        permissions: [],
        runtimeStatus: .pendingRuntime,
        installedAt: .now,
        updatedAt: .now,
        manifestVersion: 3,
        iconRelativePath: "icon.png",
        statusDetail: nil
    )
    #expect(package.iconURL == nil)
}
