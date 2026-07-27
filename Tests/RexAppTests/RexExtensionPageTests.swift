import Foundation
import Testing
@testable import RexApp

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
