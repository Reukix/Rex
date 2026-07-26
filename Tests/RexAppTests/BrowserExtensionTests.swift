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

@Test("Extension runtime capabilities do not promise unsupported CEF features")
func extensionRuntimeCapabilitiesAreExplicit() {
    let capabilities = BrowserExtensionRuntimeCapabilities.current
    #expect(!capabilities.supportsChromeWebStoreInstall)
    #expect(!capabilities.supportsCRXInstall)
    #expect(!capabilities.supportsUnpackedExecution)
    #expect(!capabilities.supportsManifestV3Execution)
    #expect(capabilities.limitationText.contains("不会执行"))
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
}

@Test("Manifest V3 import is copied, parsed, and persisted without execution claims")
@MainActor
func manifestV3ImportPersistsManagedPackage() throws {
    let paths = try ExtensionTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.sandbox) }
    var manifest = validManifest()
    manifest["icons"] = ["16": "icons/icon.bin", "128": "icons/icon-128.bin"]
    try writeManifest(manifest, to: paths.source)
    try writeFile(Data([0x01]), relativePath: "icons/icon.bin", in: paths.source)
    try writeFile(Data([0x02]), relativePath: "icons/icon-128.bin", in: paths.source)

    let store = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let imported = try store.installUnpacked(from: paths.source)

    #expect(imported.id.hasPrefix("local-"))
    #expect(imported.id.count == 38)
    #expect(imported.path.deletingLastPathComponent().lastPathComponent == "Packages")
    #expect(FileManager.default.fileExists(atPath: imported.path.path))
    #expect(imported.manifestVersion == 3)
    #expect(imported.runtimeStatus == .pendingRuntime)
    #expect(imported.statusDetail?.contains("不会执行") == true)
    #expect(imported.permissions == ["https://example.com/*", "optional:bookmarks", "storage", "tabs"])
    #expect(imported.iconRelativePath == "icons/icon-128.bin")

    let reloaded = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    let persisted = try #require(reloaded.extensions.first)
    #expect(reloaded.extensions.count == 1)
    #expect(persisted.id == imported.id)
    #expect(persisted.runtimeStatus == .pendingRuntime)
    #expect(persisted.homepageURL?.absoluteString == "https://example.com/extension")
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

    let reloaded = BrowserExtensionsStore(rootDirectoryURL: paths.storeRoot)
    #expect(reloaded.extensions.first?.runtimeStatus == .disabled)
    #expect(reloaded.setEnabled(true, for: first.id))
    #expect(reloaded.extensions.first?.runtimeStatus == .pendingRuntime)
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
    #expect(FileManager.default.fileExists(atPath: first.path.appendingPathComponent("manifest.json").path))
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
    try writeManifest(validManifest(version: "2.0.0", key: nil), to: paths.source)

    let updated = try store.installUnpacked(from: paths.source)

    #expect(store.extensions.count == 1)
    #expect(updated.id == legacyID)
    #expect(updated.path.resolvingSymlinksInPath() == legacyPath.resolvingSymlinksInPath())
    #expect(updated.version == "2.0.0")
    #expect(updated.installedAt == installedAt)
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
