import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RexApp

private actor ExtensionPageRecordingEngine: BrowserEngine {
    private var commands: [BrowserCommand] = []
    private var queriedExtensionIDs: [String] = []
    private var updatedExtensionIDs: [String] = []
    private var receivedUpdates: [BrowserExtensionRuntimeConfigurationUpdate] = []
    private let queryConfiguration: BrowserExtensionRuntimeConfiguration?
    private let updatedConfiguration: BrowserExtensionRuntimeConfiguration?
    private let maximumSuccessfulUpdates: Int?

    init(
        queryConfiguration: BrowserExtensionRuntimeConfiguration? = nil,
        updatedConfiguration: BrowserExtensionRuntimeConfiguration? = nil,
        maximumSuccessfulUpdates: Int? = nil
    ) {
        self.queryConfiguration = queryConfiguration
        self.updatedConfiguration = updatedConfiguration
        self.maximumSuccessfulUpdates = maximumSuccessfulUpdates
    }

    func execute(_ command: BrowserCommand) {
        commands.append(command)
    }

    func eventStream() -> AsyncStream<BrowserEvent> {
        AsyncStream { $0.finish() }
    }

    func extensionRuntimeConfiguration(
        extensionID: String
    ) throws -> BrowserExtensionRuntimeConfiguration {
        queriedExtensionIDs.append(extensionID)
        guard let queryConfiguration else {
            throw BrowserEngineError.chromiumUnavailable
        }
        return queryConfiguration
    }

    func updateExtensionRuntimeConfiguration(
        extensionID: String,
        update: BrowserExtensionRuntimeConfigurationUpdate
    ) throws -> BrowserExtensionRuntimeConfiguration {
        updatedExtensionIDs.append(extensionID)
        receivedUpdates.append(update)
        if let maximumSuccessfulUpdates,
           receivedUpdates.count > maximumSuccessfulUpdates {
            throw BrowserEngineError.chromiumUnavailable
        }
        guard let updatedConfiguration else {
            throw BrowserEngineError.chromiumUnavailable
        }
        return updatedConfiguration
    }

    func loadURLs() -> [URL] {
        commands.compactMap { command in
            guard case let .loadURL(_, url) = command else { return nil }
            return url
        }
    }

    func queriedIDs() -> [String] {
        queriedExtensionIDs
    }

    func updateIDs() -> [String] {
        updatedExtensionIDs
    }

    func updates() -> [BrowserExtensionRuntimeConfigurationUpdate] {
        receivedUpdates
    }

    func waitForPageSetup(tabID: UUID) async -> Bool {
        for _ in 0..<1_000 {
            if commands.contains(where: { command in
                guard case let .setPrivacyPolicy(commandTabID, _, _, _, _) = command else {
                    return false
                }
                return commandTabID == tabID
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private func extensionRuntimeConfigurationPayload(
    extensionID: String,
    hostAccess: BrowserExtensionHostAccess? = .onClick,
    hasAllHosts: Bool = false,
    sites: [(host: String, granted: Bool)] = [],
    userScriptsAvailable: Bool = true,
    userScriptsAllowed: Bool = false,
    fileAccessAvailable: Bool = true,
    fileAccessAllowed: Bool = false
) -> [String: Any] {
    var payload: [String: Any] = [
        "extensionID": extensionID,
        "isEnabled": true,
        "userMayModify": true,
        "hasAllHosts": hasAllHosts,
        "hosts": sites.map { ["host": $0.host, "granted": $0.granted] },
        "userScriptsAvailable": userScriptsAvailable,
        "userScriptsAllowed": userScriptsAllowed,
        "fileAccessAvailable": fileAccessAvailable,
        "fileAccessAllowed": fileAccessAllowed,
        "incognitoAccessAvailable": true,
        "incognitoAccessAllowed": false
    ]
    if let hostAccess {
        payload["hostAccess"] = hostAccess.rawValue
    }
    return payload
}

@Test("Rex extensions URLs remain Rex-owned and migrate legacy Chromium routes")
func rexExtensionsURLsAreRexOwned() throws {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    #expect(RexExtensionsPage.url.absoluteString == "rex://extensions")
    #expect(RexExtensionsPage.canonicalURL(
        from: URL(string: "REX://EXTENSIONS/")!
    ) == RexExtensionsPage.url)

    let detailURL = try #require(RexExtensionsPage.url(forRuntimeID: runtimeID))
    #expect(detailURL.absoluteString == "rex://extensions?id=\(runtimeID)")
    #expect(RexExtensionsPage.detailRuntimeID(from: detailURL) == runtimeID)
    #expect(RexExtensionsPage.url(forRuntimeID: "invalid") == nil)

    let legacyURL = try #require(URL(
        string: "chrome://extensions/?id=\(runtimeID)"
    ))
    let migratedURL = try #require(RexExtensionsPage.userVisibleURL(from: legacyURL))
    #expect(migratedURL == detailURL)
    #expect(RexExtensionsPage.userVisibleURL(from: migratedURL) == migratedURL)
    #expect(RexExtensionsPage.canonicalURL(from: legacyURL) == nil)
    #expect(RexExtensionsPage.userVisibleURL(
        from: URL(string: "chrome://settings/")!
    ) == nil)
    #expect(RexExtensionsPage.detailRuntimeID(
        from: URL(string: "rex://extensions?id=\(runtimeID)&id=\(runtimeID)")!
    ) == nil)
    #expect(RexExtensionsPage.detailRuntimeID(
        from: URL(string: "rex://extensions?id=invalid")!
    ) == nil)

    let rejected = [
        "rex://user@extensions",
        "rex://extensions:443",
        "rex://extensions/../settings",
        "rex://settings",
        "https://extensions"
    ]
    for value in rejected {
        #expect(!RexExtensionsPage.matches(URL(string: value)!))
    }
}

@Test("Address bar migrates only Chromium's extension management route")
@MainActor
func addressBarMigratesLegacyChromiumExtensionsURL() async throws {
    let suiteName = "RexLegacyExtensionsAddressTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-legacy-extensions-address-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let engine = ExtensionPageRecordingEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences
    )
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let detailURL = try #require(RexExtensionsPage.url(forRuntimeID: runtimeID))

    store.addressText = "chrome://extensions/"
    store.submitAddress()
    #expect(store.currentTab?.url == RexExtensionsPage.url)
    #expect(store.addressText == RexExtensionsPage.url.absoluteString)

    store.addressText = "chrome://extensions/?id=\(runtimeID)"
    store.submitAddress()
    #expect(store.currentTab?.url == detailURL)
    #expect(store.addressText == detailURL.absoluteString)

    store.lastError = nil
    store.addressText = "chrome://settings/"
    store.submitAddress()
    #expect(store.currentTab?.url == detailURL)
    #expect(store.lastError == "无法打开这个地址")
    #expect(!(await engine.loadURLs()).contains(where: {
        $0.scheme?.lowercased() == "chrome"
    }))

    store.closeWindow()
}

@Test("Opening Rex's internal extensions page reuses its tab without engine navigation")
@MainActor
func rexInternalExtensionsPageTabIsReused() async throws {
    let suiteName = "RexNativeExtensionsPageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-native-extensions-page-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let engine = ExtensionPageRecordingEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences
    )

    let initialCount = store.tabs.count
    store.isExtensionsPresented = true
    store.openExtensionsPage()
    let internalExtensionsTabID = store.selectedTabID

    #expect(store.tabs.count == initialCount + 1)
    #expect(store.currentTab?.url == RexExtensionsPage.url)
    #expect(store.currentTab?.title == RexExtensionsPage.title)
    #expect(store.addressText == RexExtensionsPage.url.absoluteString)
    #expect(!store.isExtensionsPresented)

    store.newTab()
    let countBeforeReuse = store.tabs.count
    store.openExtensionsPage()
    #expect(store.tabs.count == countBeforeReuse)
    #expect(store.selectedTabID == internalExtensionsTabID)
    #expect(store.currentTab?.url == RexExtensionsPage.url)
    #expect(store.addressText == RexExtensionsPage.url.absoluteString)
    #expect(await engine.waitForPageSetup(tabID: internalExtensionsTabID))
    #expect(!(await engine.loadURLs()).contains(where: { url in
        RexExtensionsPage.matches(url)
    }))
}

@Test("Extensions page reuse ignores a sidebar search that hides its tab")
@MainActor
func rexExtensionsPageReuseIgnoresSidebarSearch() throws {
    let suiteName = "RexExtensionsSearchReuseTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extensions-search-reuse-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = BrowserStore(
        engine: ExtensionPageRecordingEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences
    )

    store.openExtensionsPage()
    let extensionsTabID = store.selectedTabID
    store.newTab()
    let tabCount = store.tabs.count
    store.searchQuery = "a search that does not match the extensions tab"
    #expect(!store.visibleTabs.contains(where: { $0.id == extensionsTabID }))

    store.openExtensionsPage()

    #expect(store.tabs.count == tabCount)
    #expect(store.selectedTabID == extensionsTabID)
    #expect(store.currentTab?.url == RexExtensionsPage.url)
    #expect(store.tabs.filter { RexExtensionsPage.matches($0.url) }.count == 1)
    #expect(store.searchQuery.isEmpty)
}

@Test("A removed extension detail route normalizes when its page appears")
@MainActor
func rexExtensionsRemovedDetailRouteNormalizesToList() async throws {
    let suiteName = "RexExtensionsInvalidDetailRouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extensions-invalid-detail-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let extensionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extensions-invalid-detail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: extensionRoot) }
    let extensionsStore = BrowserExtensionsStore(rootDirectoryURL: extensionRoot)
    let store = BrowserStore(
        engine: ExtensionPageRecordingEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences,
        extensionsStore: extensionsStore
    )

    let removedRuntimeID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let removedDetailURL = try #require(RexExtensionsPage.url(
        forRuntimeID: removedRuntimeID
    ))
    #expect(extensionsStore.package(runtimeID: removedRuntimeID) == nil)
    store.openExtensionsPage(removedDetailURL)
    let extensionsTabID = store.selectedTabID
    #expect(store.currentTab?.url == removedDetailURL)

    let hostingView = NSHostingView(rootView: RexExtensionsPageView(
        url: removedDetailURL
    ).environmentObject(store))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    for _ in 0..<100 where store.currentTab?.url != RexExtensionsPage.url {
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(store.selectedTabID == extensionsTabID)
    #expect(store.currentTab?.url == RexExtensionsPage.url)
    #expect(store.addressText == RexExtensionsPage.url.absoluteString)
}

@Test("Opening extension options clears the source management detail route")
@MainActor
func openingExtensionOptionsClearsManagementDetailRoute() throws {
    let suiteName = "RexExtensionOptionsRouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-options-route-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let extensionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-options-route-\(UUID().uuidString)", isDirectory: true)
    let extensionSource = extensionRoot.appendingPathComponent("Source", isDirectory: true)
    let extensionStoreRoot = extensionRoot.appendingPathComponent("Store", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: extensionRoot) }
    try FileManager.default.createDirectory(
        at: extensionSource,
        withIntermediateDirectories: true
    )
    let manifestData = try JSONSerialization.data(
        withJSONObject: [
            "manifest_version": 3,
            "name": "Options Route Test",
            "version": "1.0.0",
            "options_ui": ["page": "options.html"]
        ],
        options: [.prettyPrinted, .sortedKeys]
    )
    try manifestData.write(
        to: extensionSource.appendingPathComponent("manifest.json"),
        options: .atomic
    )
    try Data("<!doctype html><title>Options</title>".utf8).write(
        to: extensionSource.appendingPathComponent("options.html"),
        options: .atomic
    )
    let installingStore = BrowserExtensionsStore(rootDirectoryURL: extensionStoreRoot)
    _ = try installingStore.installUnpacked(from: extensionSource)
    let runtimeStore = BrowserExtensionsStore(rootDirectoryURL: extensionStoreRoot)
    let package = try #require(runtimeStore.extensions.first)
    let runtimeID = try #require(package.runtimeID)
    let detailURL = try #require(RexExtensionsPage.url(forRuntimeID: runtimeID))
    let optionsURL = try #require(package.optionsURL)
    let store = BrowserStore(
        engine: ExtensionPageRecordingEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences,
        extensionsStore: runtimeStore
    )

    store.openExtensionsPage(detailURL)
    let managementTabID = store.selectedTabID
    store.openExtensionPage(optionsURL, title: package.name)
    let optionsTabID = store.selectedTabID

    #expect(optionsTabID != managementTabID)
    #expect(store.currentTab?.url == optionsURL)
    #expect(store.tab(withID: managementTabID)?.url == RexExtensionsPage.url)
    #expect(store.selectedTabID == optionsTabID)
}

@Test("Extension runtime payload decodes host, user-script, file, and site access")
func extensionRuntimeConfigurationPayloadDecodes() throws {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let payload = extensionRuntimeConfigurationPayload(
        extensionID: runtimeID,
        hostAccess: .onSpecificSites,
        hasAllHosts: true,
        sites: [
            ("https://z.example/*", false),
            ("https://a.example/*", true)
        ],
        userScriptsAvailable: true,
        userScriptsAllowed: true,
        fileAccessAvailable: true,
        fileAccessAllowed: true
    )
    let configuration = try #require(BrowserExtensionRuntimeConfiguration(payload))

    #expect(configuration.extensionID == runtimeID)
    #expect(configuration.hostAccess == .onSpecificSites)
    #expect(configuration.hasAllHosts)
    #expect(configuration.sites.map(\.host) == [
        "https://a.example/*",
        "https://z.example/*"
    ])
    #expect(configuration.sites.map(\.isGranted) == [true, false])
    #expect(configuration.userScriptsAvailable)
    #expect(configuration.userScriptsAllowed)
    #expect(configuration.fileAccessAvailable)
    #expect(configuration.fileAccessAllowed)

    var futureHostAccessPayload = payload
    futureHostAccessPayload["hostAccess"] = "FUTURE_HOST_MODE"
    #expect(BrowserExtensionRuntimeConfiguration(futureHostAccessPayload) == nil)

    var noHostCapabilityPayload = payload
    noHostCapabilityPayload.removeValue(forKey: "hostAccess")
    noHostCapabilityPayload.removeValue(forKey: "hasAllHosts")
    noHostCapabilityPayload.removeValue(forKey: "hosts")
    let noHostCapability = try #require(BrowserExtensionRuntimeConfiguration(
        noHostCapabilityPayload
    ))
    #expect(noHostCapability.hostAccess == nil)
    #expect(!noHostCapability.hasAllHosts)
    #expect(noHostCapability.sites.isEmpty)
}

@Test("Extension runtime payload rejects invalid IDs and malformed required values")
func extensionRuntimeConfigurationPayloadRejectsInvalidValues() {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let validPayload = extensionRuntimeConfigurationPayload(extensionID: runtimeID)

    var invalidIDPayload = validPayload
    invalidIDPayload["extensionID"] = "invalid"
    #expect(BrowserExtensionRuntimeConfiguration(invalidIDPayload) == nil)

    let requiredFields = [
        "extensionID",
        "isEnabled",
        "userMayModify",
        "hasAllHosts",
        "userScriptsAvailable",
        "userScriptsAllowed",
        "fileAccessAvailable",
        "fileAccessAllowed",
        "incognitoAccessAvailable",
        "incognitoAccessAllowed"
    ]
    for field in requiredFields {
        var missingFieldPayload = validPayload
        missingFieldPayload.removeValue(forKey: field)
        #expect(BrowserExtensionRuntimeConfiguration(missingFieldPayload) == nil)
    }

    var wrongExtensionIDType = validPayload
    wrongExtensionIDType["extensionID"] = [runtimeID]
    #expect(BrowserExtensionRuntimeConfiguration(wrongExtensionIDType) == nil)

    for field in requiredFields where field != "extensionID" {
        var wrongBooleanType = validPayload
        wrongBooleanType[field] = "true"
        #expect(BrowserExtensionRuntimeConfiguration(wrongBooleanType) == nil)
    }

    var malformedSitePayload = validPayload
    malformedSitePayload["hosts"] = [[
        "host": "https://example.com/*",
        "granted": "true"
    ]]
    #expect(BrowserExtensionRuntimeConfiguration(malformedSitePayload) == nil)

    var inconsistentHostCapabilityPayload = validPayload
    inconsistentHostCapabilityPayload.removeValue(forKey: "hostAccess")
    #expect(BrowserExtensionRuntimeConfiguration(inconsistentHostCapabilityPayload) == nil)
}

@Test("Specific-site input follows Chromium runtime host pattern normalization")
func extensionSpecificSitePatternNormalization() throws {
    #expect(BrowserExtensionSitePattern.normalizedPermissionPattern(
        from: " Example.COM "
    ) == "*://example.com/*")
    #expect(BrowserExtensionSitePattern.normalizedPermissionPattern(
        from: "https://*.Example.com/"
    ) == "https://*.example.com/*")
    #expect(BrowserExtensionSitePattern.normalizedPermissionPattern(
        from: "localhost"
    ) == "*://localhost/*")
    #expect(BrowserExtensionSitePattern.normalizedPermissionPattern(
        from: "*://sub.example.com/*"
    ) == "*://sub.example.com/*")

    let invalidInputs = [
        "",
        "https://example.com/private",
        "javascript://example.com",
        "https://exa_mple.com",
        "https://example",
        "https://-example.com",
        "https://example-.com",
        "https://example..com",
        "https://localhost:8080",
        "https://999.1.1.1",
        "*://*/*",
        "https://example.com/\nmalformed"
    ]
    for input in invalidInputs {
        #expect(BrowserExtensionSitePattern.normalizedPermissionPattern(from: input) == nil)
    }

    let update = try #require(BrowserExtensionSitePermissionUpdate(
        host: "https://example.com/*",
        isGranted: true
    ))
    #expect(update.host == "https://example.com/*")
    #expect(update.isGranted)
    #expect(BrowserExtensionSitePermissionUpdate(
        host: "https://Example.com/*",
        isGranted: true
    ) == nil)
}

@Test("Browser store caches authoritative extension runtime configuration")
@MainActor
func browserStoreCachesAuthoritativeExtensionRuntimeConfiguration() async throws {
    let suiteName = "RexExtensionRuntimeConfigurationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-configuration-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let extensionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-configuration-\(UUID().uuidString)", isDirectory: true)
    let extensionSource = extensionRoot.appendingPathComponent("Source", isDirectory: true)
    let extensionStoreRoot = extensionRoot.appendingPathComponent("Store", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: extensionRoot) }
    try FileManager.default.createDirectory(
        at: extensionSource,
        withIntermediateDirectories: true
    )
    let manifestData = try JSONSerialization.data(
        withJSONObject: [
            "manifest_version": 3,
            "name": "Runtime Configuration Test",
            "version": "1.0.0"
        ],
        options: [.prettyPrinted, .sortedKeys]
    )
    try manifestData.write(
        to: extensionSource.appendingPathComponent("manifest.json"),
        options: .atomic
    )
    let installingStore = BrowserExtensionsStore(rootDirectoryURL: extensionStoreRoot)
    _ = try installingStore.installUnpacked(from: extensionSource)
    let runtimeStore = BrowserExtensionsStore(rootDirectoryURL: extensionStoreRoot)
    let package = try #require(runtimeStore.extensions.first)
    let runtimeID = try #require(package.runtimeID)
    #expect(package.runtimeStatus == .ready)

    let refreshedConfiguration = try #require(BrowserExtensionRuntimeConfiguration(
        extensionRuntimeConfigurationPayload(
            extensionID: runtimeID,
            hostAccess: .onClick,
            sites: [("https://initial.example/*", true)],
            userScriptsAllowed: true,
            fileAccessAllowed: true
        )
    ))
    let authoritativeUpdateConfiguration = try #require(
        BrowserExtensionRuntimeConfiguration(
            extensionRuntimeConfigurationPayload(
                extensionID: runtimeID,
                hostAccess: .onSpecificSites,
                sites: [("https://authoritative.example/*", true)],
                userScriptsAllowed: false,
                fileAccessAllowed: false
            )
        )
    )
    let engine = ExtensionPageRecordingEngine(
        queryConfiguration: refreshedConfiguration,
        updatedConfiguration: authoritativeUpdateConfiguration,
        maximumSuccessfulUpdates: 1
    )
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences,
        extensionsStore: runtimeStore
    )

    let initialRevision = runtimeStore.runtimeConfigurationRevision
    #expect(await store.refreshExtensionRuntimeConfiguration(for: package))
    #expect(store.extensionRuntimeConfiguration(for: package) == refreshedConfiguration)
    #expect(await engine.queriedIDs() == [runtimeID])
    #expect(runtimeStore.runtimeConfigurationRevision == initialRevision)

    let requestedSitePermission = try #require(BrowserExtensionSitePermissionUpdate(
        host: "https://requested.example/*",
        isGranted: true
    ))
    let requestedUpdate = BrowserExtensionRuntimeConfigurationUpdate(
        hostAccess: .onAllSites,
        sitePermission: requestedSitePermission,
        userScriptsAccess: true,
        fileAccess: true
    )
    #expect(await store.updateExtensionRuntimeConfiguration(
        for: package,
        update: requestedUpdate
    ))
    #expect(await engine.updateIDs() == [runtimeID])
    #expect(await engine.updates() == [requestedUpdate])
    #expect(store.extensionRuntimeConfiguration(for: package)
        == authoritativeUpdateConfiguration)
    #expect(store.extensionRuntimeConfiguration(for: package)?.hostAccess == .onSpecificSites)
    #expect(store.extensionRuntimeConfiguration(for: package)?.userScriptsAllowed == false)
    #expect(store.extensionRuntimeConfiguration(for: package)?.fileAccessAllowed == false)
    #expect(runtimeStore.runtimeConfigurationRevision == initialRevision + 1)

    #expect(await store.refreshExtensionRuntimeConfiguration(for: package))
    #expect(await engine.queriedIDs() == [runtimeID, runtimeID])
    #expect(runtimeStore.runtimeConfigurationRevision == initialRevision + 1)

    let failedSitePermission = try #require(BrowserExtensionSitePermissionUpdate(
        host: "https://failed.example/*",
        isGranted: true
    ))
    #expect(!(await store.updateExtensionRuntimeConfiguration(
        for: package,
        update: BrowserExtensionRuntimeConfigurationUpdate(
            hostAccess: .onSpecificSites,
            sitePermission: failedSitePermission
        )
    )))
    #expect(await engine.queriedIDs() == [runtimeID, runtimeID, runtimeID])
    #expect(store.extensionRuntimeConfiguration(for: package) == refreshedConfiguration)
    #expect(store.extensionRuntimeConfigurationError(for: package) != nil)
    #expect(runtimeStore.runtimeConfigurationRevision == initialRevision + 2)

    #expect(await store.setExtensionEnabled(false, id: package.id))
    #expect(runtimeStore.runtimeConfigurationRevision == initialRevision + 3)
    #expect(await store.setExtensionEnabled(false, id: package.id))
    #expect(runtimeStore.runtimeConfigurationRevision == initialRevision + 3)
}

@Test("Rex extension resource URLs preserve Chromium extension content")
func rexExtensionResourceURLsRoundTrip() throws {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let resource = try #require(RexExtensionResourceURL(
        rexURL: URL(
            string: "rex-extension://\(runtimeID)/pages/options.html?view=compact%20mode#advanced"
        )!
    ))

    #expect(resource.runtimeID == runtimeID)
    #expect(resource.rexURL.absoluteString
        == "rex-extension://\(runtimeID)/pages/options.html?view=compact%20mode#advanced")
    #expect(resource.chromiumURL.absoluteString
        == "chrome-extension://\(runtimeID)/pages/options.html?view=compact%20mode#advanced")
    #expect(RexExtensionResourceURL(
        chromiumURL: resource.chromiumURL
    )?.rexURL == resource.rexURL)
    #expect(RexExtensionResourceURL.chromiumURL(
        fromRexURL: resource.rexURL
    ) == resource.chromiumURL)
    #expect(RexExtensionResourceURL.rexURL(
        fromChromiumURL: resource.chromiumURL
    ) == resource.rexURL)

    let constructed = try #require(RexExtensionResourceURL(
        runtimeID: runtimeID,
        relativePath: "popup/账户 选项.html"
    ))
    #expect(constructed.rexURL.absoluteString
        == "rex-extension://\(runtimeID)/popup/%E8%B4%A6%E6%88%B7%20%E9%80%89%E9%A1%B9.html")
    #expect(constructed.chromiumURL.absoluteString
        == "chrome-extension://\(runtimeID)/popup/%E8%B4%A6%E6%88%B7%20%E9%80%89%E9%A1%B9.html")
}

@Test("Chromium extension values become Rex values at the application boundary")
func chromiumExtensionValuesBecomeUserVisibleRexValues() throws {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let chromiumURL = try #require(URL(
        string: "chrome-extension://\(runtimeID)/popup/main.html?mode=compact#account"
    ))
    let rexURL = try #require(URL(
        string: "rex-extension://\(runtimeID)/popup/main.html?mode=compact#account"
    ))

    #expect(RexExtensionResourceURL.userVisibleURL(from: chromiumURL) == rexURL)
    #expect(RexExtensionResourceURL.userVisibleURL(from: rexURL) == rexURL)
    #expect(RexExtensionResourceURL.userVisibleOrigin(
        from: "chrome-extension://\(runtimeID)"
    ) == "rex-extension://\(runtimeID)")
    #expect(RexExtensionResourceURL.userVisibleString(
        from: chromiumURL.absoluteString
    ) == rexURL.absoluteString)
    #expect(RexExtensionResourceURL.userVisibleString(from: "Extension settings")
        == "Extension settings")
}

@Test("Rex extension resource URLs reject authority and traversal attacks")
func rexExtensionResourceURLsAreStrict() {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let invalidURLs = [
        "rex-extension://short/options.html",
        "rex-extension://abcdefghijklmnopabcdefghijklmnoq/options.html",
        "rex-extension://ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP/options.html",
        "REX-EXTENSION://\(runtimeID)/options.html",
        "rex-extension://user@\(runtimeID)/options.html",
        "rex-extension://\(runtimeID):443/options.html",
        "rex-extension://\(runtimeID)/",
        "rex-extension://\(runtimeID)//options.html",
        "rex-extension://\(runtimeID)/pages//options.html",
        "rex-extension://\(runtimeID)/pages/options.html/",
        "rex-extension://\(runtimeID)/pages/../options.html",
        "rex-extension://\(runtimeID)/pages/%2E%2E/options.html",
        "rex-extension://\(runtimeID)/pages/%2e%2e/options.html",
        "rex-extension://\(runtimeID)/pages%2Foptions.html",
        "rex-extension://\(runtimeID)/pages%5Coptions.html",
        "rex-extension://\(runtimeID)/pages/%252E%252E/options.html",
        "rex-extension://\(runtimeID)/pages/%00/options.html",
        "rex-extension://\(runtimeID)/pages/%6Fptions.html"
    ]

    for rawURL in invalidURLs {
        #expect(RexExtensionResourceURL(rexURL: URL(string: rawURL)!) == nil)
    }
    #expect(RexExtensionResourceURL(
        chromiumURL: URL(string: "rex-extension://\(runtimeID)/options.html")!
    ) == nil)
    #expect(RexExtensionResourceURL(
        rexURL: URL(string: "chrome-extension://\(runtimeID)/options.html")!
    ) == nil)
    #expect(RexExtensionResourceURL(runtimeID: runtimeID, relativePath: "../options.html") == nil)
    #expect(RexExtensionResourceURL(runtimeID: runtimeID, relativePath: "/options.html") == nil)
    #expect(RexExtensionResourceURL(
        runtimeID: runtimeID.uppercased(),
        relativePath: "options.html"
    ) == nil)
    #expect(RexExtensionResourceURL.userVisibleURL(
        from: URL(string: "chrome-extension://short/options.html")!
    ) == nil)
    #expect(RexExtensionResourceURL.userVisibleOrigin(
        from: "chrome-extension://short"
    ) == "chrome-extension://short")
}

@Test("Extension surface runtime IDs preserve only a validated source tab")
func extensionSurfaceRuntimeIDsAreStrict() throws {
    let sourceTabID = UUID()
    let nonce = UUID()
    let identifier = RexExtensionSurfaceRuntimeID(
        sourceTabID: sourceTabID,
        surfaceID: "Toolbar:Panel/Primary",
        nonce: nonce
    )

    #expect(identifier.surfaceID == "toolbar-panel-primary")
    #expect(identifier.rawValue
        == "rex-extension-surface:\(sourceTabID.uuidString.lowercased()):toolbar-panel-primary:\(nonce.uuidString.lowercased())")
    let decoded = try #require(RexExtensionSurfaceRuntimeID(rawValue: identifier.rawValue))
    #expect(decoded.sourceTabID == sourceTabID)
    #expect(decoded.surfaceID == "toolbar-panel-primary")
    #expect(decoded.nonce == nonce)

    let noSource = RexExtensionSurfaceRuntimeID(
        sourceTabID: nil,
        surfaceID: "",
        nonce: nonce
    )
    #expect(noSource.surfaceID == "extension")
    #expect(RexExtensionSurfaceRuntimeID(rawValue: noSource.rawValue)?.sourceTabID == nil)

    #expect(RexExtensionSurfaceRuntimeID(
        rawValue: "rex-extension-surface:\(sourceTabID):toolbar:\(nonce):extra"
    ) == nil)
    #expect(RexExtensionSurfaceRuntimeID(
        rawValue: "rex-extension-surface:not-a-uuid:toolbar:\(nonce)"
    ) == nil)
    #expect(RexExtensionSurfaceRuntimeID(
        rawValue: "rex-extension-surface:\(sourceTabID):tool_bar:\(nonce)"
    ) == nil)
    #expect(RexExtensionSurfaceRuntimeID(
        rawValue: "not-rex:\(sourceTabID):toolbar:\(nonce)"
    ) == nil)
}

@Test("Extension actions use the selected web tab before newer background tabs")
@MainActor
func extensionActionsPreferSelectedWebTab() throws {
    let suiteName = "RexExtensionActionSourceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-source-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = BrowserStore(
        engine: PrototypeBrowserEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences
    )

    #expect(store.currentTab?.url?.scheme == "https")
    #expect(store.sourceWebTab(
        forExtensionPackageID: "local-0123456789abcdef0123456789abcdef"
    )?.id == store.selectedTabID)
}

@Test("Opening another resource reuses the current Rex extension tab")
@MainActor
func rexExtensionResourceNavigationReusesTab() throws {
    let suiteName = "RexExtensionPageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-page-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let extensionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-extension-runtime-\(UUID().uuidString)", isDirectory: true)
    let extensionSource = extensionRoot.appendingPathComponent("Source", isDirectory: true)
    let extensionStoreRoot = extensionRoot.appendingPathComponent("Store", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: extensionRoot) }
    try FileManager.default.createDirectory(
        at: extensionSource,
        withIntermediateDirectories: true
    )
    let manifest: [String: Any] = [
        "manifest_version": 3,
        "name": "Test Extension",
        "version": "1.0.0",
        "options_ui": ["page": "options.html"]
    ]
    let manifestData = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.prettyPrinted, .sortedKeys]
    )
    try manifestData.write(
        to: extensionSource.appendingPathComponent("manifest.json"),
        options: .atomic
    )
    try Data("<!doctype html><title>Options</title>".utf8).write(
        to: extensionSource.appendingPathComponent("options.html"),
        options: .atomic
    )
    try Data("<!doctype html><title>Details</title>".utf8).write(
        to: extensionSource.appendingPathComponent("details.html"),
        options: .atomic
    )
    let installingStore = BrowserExtensionsStore(rootDirectoryURL: extensionStoreRoot)
    _ = try installingStore.installUnpacked(from: extensionSource)
    let runtimeStore = BrowserExtensionsStore(rootDirectoryURL: extensionStoreRoot)
    let package = try #require(runtimeStore.extensions.first)
    #expect(package.runtimeStatus == .ready)
    let optionsURL = try #require(package.resourceURL(relativePath: "options.html"))
    let detailsURL = try #require(package.resourceURL(relativePath: "details.html"))

    let store = BrowserStore(
        engine: PrototypeBrowserEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        preferences: preferences,
        extensionsStore: runtimeStore
    )

    store.addressText = "https://example.com/login"
    store.submitAddress()
    store.openExtensionPage(optionsURL, title: package.name)
    let extensionTabID = store.selectedTabID
    let sourceTabID = try #require(store.sourceWebTab(
        forExtensionPackageID: package.id
    )?.id)
    store.newTab()
    let tabCount = store.tabs.count
    #expect(store.selectedTabID != extensionTabID)
    store.openExtensionPage(detailsURL, title: package.name)

    #expect(store.tabs.count == tabCount)
    #expect(store.selectedTabID == extensionTabID)
    #expect(store.sourceWebTab(forExtensionPackageID: package.id)?.id == sourceTabID)
    #expect(store.currentTab?.url == detailsURL)
    #expect(store.addressText == detailsURL.absoluteString)
}
