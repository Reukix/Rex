import AppKit
import Foundation
import Testing
@testable import RexApp

private func temporarySessionPersistence() -> BrowserSessionPersistence {
    BrowserSessionPersistence(
        fileURL: FileManager.default.temporaryDirectory
            .appending(path: "rex-tests-\(UUID().uuidString)/session-v1.json")
    )
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "rex-sqlite-tests-\(UUID().uuidString)/Browser.sqlite")
}

private actor RecordingBrowserEngine: BrowserEngine {
    private var commands: [BrowserCommand] = []

    func execute(_ command: BrowserCommand) {
        commands.append(command)
    }

    func eventStream() -> AsyncStream<BrowserEvent> {
        AsyncStream { $0.finish() }
    }

    func createPageCount() -> Int {
        commands.reduce(into: 0) { count, command in
            if case .createPage = command { count += 1 }
        }
    }

    func waitForCreatePages(_ expectedCount: Int) async {
        while createPageCount() < expectedCount {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func destroyedPageIDs() -> [UUID] {
        commands.compactMap { command in
            guard case let .destroyPage(tabID) = command else { return nil }
            return tabID
        }
    }

    func waitForDestroyedPages(_ expectedCount: Int) async {
        while destroyedPageIDs().count < expectedCount {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func loadURLs() -> [URL] {
        commands.compactMap { command in
            guard case let .loadURL(_, url) = command else { return nil }
            return url
        }
    }

    func recordedCommands() -> [BrowserCommand] {
        commands
    }

    func pagePriorityCommands() -> [BrowserCommand] {
        commands.filter { command in
            if case .setPagePriority = command { return true }
            return false
        }
    }

    func waitForPagePriorityCount(_ expectedCount: Int) async {
        while pagePriorityCommands().count < expectedCount {
            await Task.yield()
        }
    }

    func pageSuspensions(for tabID: UUID) -> [Bool] {
        commands.compactMap { command in
            guard case let .setPageSuspended(id, isSuspended) = command,
                  id == tabID else { return nil }
            return isSuspended
        }
    }

    func thirdPartyCookiePolicies() -> [Bool] {
        commands.compactMap { command in
            guard case let .setPrivacyPolicy(_, _, _, _, cookies) = command else { return nil }
            return cookies
        }
    }

    func contentBlockingStates() -> [Bool] {
        commands.compactMap { command in
            guard case let .setContentBlocking(enabled) = command else { return nil }
            return enabled
        }
    }

    func waitForSuspensionCount(_ expectedCount: Int, tabID: UUID) async {
        while pageSuspensions(for: tabID).count < expectedCount {
            await Task.yield()
        }
    }

    func containsAll(_ expected: [BrowserCommand]) -> Bool {
        expected.allSatisfy(commands.contains)
    }
}

private struct RecordedPrivacyPolicyCommand {
    let index: Int
    let enabled: Bool
    let level: PrivacyLevel
    let fingerprintProtection: Bool
}

private struct RecordedLoadURLCommand {
    let index: Int
    let url: URL
}

private func firstPrivacyPolicyCommand(
    for tabID: UUID,
    in commands: [BrowserCommand]
) -> RecordedPrivacyPolicyCommand? {
    for (index, command) in commands.enumerated() {
        guard case let .setPrivacyPolicy(
            commandTabID,
            enabled,
            level,
            fingerprintProtection,
            _
        ) = command,
        commandTabID == tabID else {
            continue
        }
        return RecordedPrivacyPolicyCommand(
            index: index,
            enabled: enabled,
            level: level,
            fingerprintProtection: fingerprintProtection
        )
    }
    return nil
}

private func firstLoadURLCommand(
    for tabID: UUID,
    in commands: [BrowserCommand]
) -> RecordedLoadURLCommand? {
    for (index, command) in commands.enumerated() {
        guard case let .loadURL(commandTabID, url) = command,
              commandTabID == tabID else {
            continue
        }
        return RecordedLoadURLCommand(index: index, url: url)
    }
    return nil
}

private func commandsThroughFirstLoad(
    for tabID: UUID,
    from engine: RecordingBrowserEngine
) async -> [BrowserCommand] {
    for _ in 0..<1_000 {
        let commands = await engine.recordedCommands()
        if firstLoadURLCommand(for: tabID, in: commands) != nil {
            return commands
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await engine.recordedCommands()
}

private actor ControlledBrowserEngine: BrowserEngine {
    private var commands: [BrowserCommand] = []
    private var continuation: AsyncStream<BrowserEvent>.Continuation?

    func execute(_ command: BrowserCommand) {
        commands.append(command)
    }

    func eventStream() -> AsyncStream<BrowserEvent> {
        AsyncStream { continuation = $0 }
    }

    func waitForSubscriber() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func emit(_ event: BrowserEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func recordedCommands() -> [BrowserCommand] {
        commands
    }
}

private actor DelayedSetupBrowserEngine: BrowserEngine {
    private var commands: [BrowserCommand] = []
    private var isConfiguringPolicy = false

    func execute(_ command: BrowserCommand) async {
        if case .setPrivacyPolicy = command {
            isConfiguringPolicy = true
            try? await Task.sleep(for: .milliseconds(50))
        }
        commands.append(command)
    }

    func eventStream() -> AsyncStream<BrowserEvent> {
        AsyncStream { $0.finish() }
    }

    func waitForPolicyConfiguration() async {
        while !isConfiguringPolicy {
            await Task.yield()
        }
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        while loadURLs().count < expectedCount {
            await Task.yield()
        }
    }

    func loadURLs() -> [URL] {
        commands.compactMap { command in
            guard case let .loadURL(_, url) = command else { return nil }
            return url
        }
    }
}

@Test("Closing a window persists it and destroys only its pages once")
@MainActor
func closingWindowTearsDownOnlyOwnedPages() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let suiteName = "RexTests.CloseWindow.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let firstWindowID = UUID()
    let secondWindowID = UUID()
    let firstStore = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: firstWindowID,
        preferences: preferences
    )
    let secondStore = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: secondWindowID,
        preferences: preferences
    )
    let firstTabIDs = Set(firstStore.tabs.map(\.id))
    let secondTabIDs = Set(secondStore.tabs.map(\.id))
    await engine.waitForCreatePages(firstTabIDs.count + secondTabIDs.count)

    firstStore.closeWindow()
    firstStore.closeWindow()
    await engine.waitForDestroyedPages(firstTabIDs.count)

    let destroyedPageIDs = await engine.destroyedPageIDs()
    #expect(Set(destroyedPageIDs) == firstTabIDs)
    #expect(destroyedPageIDs.count == firstTabIDs.count)
    #expect(Set(destroyedPageIDs).isDisjoint(with: secondTabIDs))

    var savedSnapshot: BrowserSessionSnapshot?
    for _ in 0..<100 {
        savedSnapshot = try await persistence.load(windowID: firstWindowID)
        if savedSnapshot != nil { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(Set(savedSnapshot?.tabs.map(\.id) ?? []) == firstTabIDs)
    #expect(try await persistence.load(windowID: secondWindowID) == nil)

    secondStore.closeWindow()
    await engine.waitForDestroyedPages(firstTabIDs.count + secondTabIDs.count)
    var secondSnapshot = try await persistence.load(windowID: secondWindowID)
    for _ in 0..<100 where secondSnapshot == nil {
        try? await Task.sleep(for: .milliseconds(5))
        secondSnapshot = try await persistence.load(windowID: secondWindowID)
    }
    #expect(Set(secondSnapshot?.tabs.map(\.id) ?? []) == secondTabIDs)
}

@Test("Closing during startup restore preserves the previously saved window")
@MainActor
func closingWindowDuringRestoreDoesNotOverwriteSnapshot() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let suiteName = "RexTests.CloseDuringRestore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let windowID = UUID()
    let persistedSnapshot = testSnapshot(windowID: windowID, title: "Persisted")
    try await persistence.save(persistedSnapshot)

    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    let placeholderTabIDs = Set(store.tabs.map(\.id))
    #expect(store.isRestoringSession)

    store.closeWindow()
    await engine.waitForDestroyedPages(placeholderTabIDs.count)

    let reloadedSnapshot = try await persistence.load(windowID: windowID)
    let reloadedTabIDs = Set(reloadedSnapshot?.tabs.map(\.id) ?? [])
    #expect(reloadedSnapshot == persistedSnapshot)
    #expect(reloadedTabIDs.isDisjoint(with: placeholderTabIDs))
}

@Test("Application termination flushes the newest state for every standard window")
@MainActor
func applicationTerminationFlushesAllStandardWindowsAndSkipsPrivateWindows() async throws {
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let suiteName = "RexTests.TerminationFlush.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let firstWindowID = UUID()
    let secondWindowID = UUID()
    let privateWindowID = UUID()
    let firstStore = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: persistence,
        windowID: firstWindowID,
        preferences: preferences
    )
    let secondStore = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: persistence,
        windowID: secondWindowID,
        preferences: preferences
    )
    let privateStore = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: persistence,
        windowID: privateWindowID,
        profile: .privateWindow(id: privateWindowID),
        preferences: preferences
    )
    let registry = RexActiveWindowSessionRegistry()
    registry.register(firstStore)
    registry.register(secondStore)
    registry.register(privateStore)

    let firstURL = try #require(URL(string: "https://example.org/first-window"))
    let secondURL = try #require(URL(string: "https://example.org/second-window"))
    firstStore.addressText = firstURL.absoluteString
    firstStore.submitAddress()
    secondStore.addressText = secondURL.absoluteString
    secondStore.submitAddress()
    privateStore.addressText = "https://example.org/private-window"
    privateStore.submitAddress()

    // Do not wait for the ordinary 350 ms debounce: the termination barrier
    // must persist these exact in-memory URLs immediately.
    let report = await registry.flushStandardWindowSessionsForApplicationTermination()

    #expect(report.savedWindowIDs == [firstWindowID, secondWindowID])
    #expect(report.failedWindows.isEmpty)
    #expect(report.skippedPrivateWindowIDs == [privateWindowID])
    #expect(try await persistence.load(windowID: firstWindowID)?.tabs
        .contains(where: { $0.url == firstURL }) == true)
    #expect(try await persistence.load(windowID: secondWindowID)?.tabs
        .contains(where: { $0.url == secondURL }) == true)
    #expect(try await persistence.load(windowID: privateWindowID) == nil)

    registry.unregister(firstStore)
    registry.unregister(secondStore)
    registry.unregister(privateStore)
    firstStore.closeWindow()
    secondStore.closeWindow()
    privateStore.closeWindow()
}

@Test("Application termination waits for startup restoration before replacing its snapshot")
@MainActor
func applicationTerminationFlushWaitsForSessionRestoration() async throws {
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let suiteName = "RexTests.TerminationRestore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let windowID = UUID()
    let restoredSnapshot = testSnapshot(windowID: windowID, title: "RestoredBeforeQuit")
    try await persistence.save(restoredSnapshot)
    let store = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    let placeholderTabIDs = Set(store.tabs.map(\.id))
    let registry = RexActiveWindowSessionRegistry()
    registry.register(store)

    #expect(store.isRestoringSession)
    let report = await registry.flushStandardWindowSessionsForApplicationTermination()
    let persisted = try #require(try await persistence.load(windowID: windowID))

    #expect(report.savedWindowIDs == [windowID])
    #expect(report.failedWindows.isEmpty)
    #expect(persisted.tabs.first?.title == "RestoredBeforeQuit")
    #expect(Set(persisted.tabs.map(\.id)).isDisjoint(with: placeholderTabIDs))

    registry.unregister(store)
    store.closeWindow()
}

@Test("A failed window write does not block the remaining termination barrier")
@MainActor
func applicationTerminationFlushReportsWriteFailure() async throws {
    let blockedParent = FileManager.default.temporaryDirectory
        .appending(path: "rex-termination-write-failure-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: blockedParent)
    defer { try? FileManager.default.removeItem(at: blockedParent) }
    let persistence = BrowserSQLitePersistence(
        databaseURL: blockedParent.appending(path: "Browser.sqlite"),
        legacyPersistence: nil
    )
    let suiteName = "RexTests.TerminationWriteFailure.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let failingWindowID = try #require(UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    ))
    let savedWindowID = try #require(UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    ))
    let failingStore = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: persistence,
        windowID: failingWindowID,
        preferences: preferences
    )
    let workingPersistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let savedStore = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: workingPersistence,
        windowID: savedWindowID,
        preferences: preferences
    )
    let registry = RexActiveWindowSessionRegistry()
    registry.register(failingStore)
    registry.register(savedStore)

    let report = await registry.flushStandardWindowSessionsForApplicationTermination()

    #expect(report.savedWindowIDs == [savedWindowID])
    #expect(report.failedWindows[failingWindowID] != nil)
    #expect(try await workingPersistence.load(windowID: savedWindowID) != nil)

    registry.unregister(failingStore)
    registry.unregister(savedStore)
    failingStore.closeWindow()
    savedStore.closeWindow()
}

@Test("Closing a secondary window deletes its persisted session after pending saves")
@MainActor
func closingSecondaryWindowDeletesPersistedSession() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let suiteName = "RexTests.DeleteClosedWindow.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let windowID = UUID()
    try await persistence.save(testSnapshot(windowID: windowID, title: "Secondary"))

    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    let tabIDs = Set(store.tabs.map(\.id))
    store.flushSession()
    store.closeWindow(removingPersistedSession: true)
    await engine.waitForDestroyedPages(tabIDs.count)

    var sessions = try await persistence.loadAllWindows()
    for _ in 0..<100 where sessions.contains(where: { $0.id == windowID }) {
        try? await Task.sleep(for: .milliseconds(5))
        sessions = try await persistence.loadAllWindows()
    }
    #expect(!sessions.contains(where: { $0.id == windowID }))
    #expect(try await persistence.load(windowID: windowID) == nil)
}

@Test("Window persistence distinguishes manual secondary close from app termination")
@MainActor
func windowPersistenceCloseSemantics() {
    let primaryWindowID = UUID()
    let secondaryWindowID = UUID()

    #expect(!RexWindowCoordinator.shouldRemovePersistedSession(
        for: primaryWindowID,
        primaryWindowID: primaryWindowID,
        profile: .standard,
        applicationIsTerminating: false
    ))
    #expect(RexWindowCoordinator.shouldRemovePersistedSession(
        for: secondaryWindowID,
        primaryWindowID: primaryWindowID,
        profile: .standard,
        applicationIsTerminating: false
    ))
    #expect(!RexWindowCoordinator.shouldRemovePersistedSession(
        for: secondaryWindowID,
        primaryWindowID: primaryWindowID,
        profile: .standard,
        applicationIsTerminating: true
    ))
    #expect(!RexWindowCoordinator.shouldRemovePersistedSession(
        for: secondaryWindowID,
        primaryWindowID: primaryWindowID,
        profile: .privateWindow(),
        applicationIsTerminating: false
    ))
}

@Test("Browser store deinit destroys pages when no window hook runs")
@MainActor
func browserStoreDeinitTearsDownPages() async {
    let engine = RecordingBrowserEngine()
    var store: BrowserStore? = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(),
            legacyPersistence: nil
        )
    )
    let tabIDs = Set(store?.tabs.map(\.id) ?? [])
    await engine.waitForCreatePages(tabIDs.count)
    weak let weakStore = store

    store = nil

    #expect(weakStore == nil)
    await engine.waitForDestroyedPages(tabIDs.count)
    let destroyedPageIDs = await engine.destroyedPageIDs()
    #expect(Set(destroyedPageIDs) == tabIDs)
    #expect(destroyedPageIDs.count == tabIDs.count)
}

private func testSnapshot(windowID: UUID = UUID(), title: String = "Example") -> BrowserSessionSnapshot {
    let space = BrowserSpace(
        id: UUID(), name: "测试空间", symbolName: "circle", tintHex: "48A9A6",
        privacyLevel: .standard, downloadDirectoryBookmark: nil
    )
    let tab = BrowserTab(
        url: URL(string: "https://example.com/\(title.lowercased())"),
        title: title, spaceID: space.id
    )
    return BrowserSessionSnapshot(
        schemaVersion: BrowserSessionSnapshot.schemaVersion,
        windowID: windowID,
        spaces: [space], tabs: [tab], currentSpaceID: space.id,
        selectedTabID: tab.id, splitSession: nil,
        savedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test("Startup restore applies saved website privacy before first navigation")
@MainActor
func startupRestoreAppliesSavedPrivacyBeforeFirstNavigation() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
    )
    let suiteName = "RexTests.StartupSitePrivacy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let windowID = UUID()
    let snapshot = testSnapshot(windowID: windowID, title: "Privacy")
    let restoredTab = try #require(snapshot.tabs.first)
    try await persistence.save(snapshot)
    try await persistence.saveSitePrivacyPolicy(SitePrivacyPolicy(
        profileID: BrowserProfile.standard.id,
        host: "example.com",
        protectionEnabled: false,
        level: .strict,
        fingerprintProtectionEnabled: true
    ))

    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    let commands = await commandsThroughFirstLoad(for: restoredTab.id, from: engine)
    let firstLoad = try #require(firstLoadURLCommand(for: restoredTab.id, in: commands))
    let firstPolicy = try #require(firstPrivacyPolicyCommand(for: restoredTab.id, in: commands))

    #expect(store.currentTab?.id == restoredTab.id)
    #expect(firstLoad.url == restoredTab.url)
    #expect(firstPolicy.index < firstLoad.index)
    #expect(!firstPolicy.enabled)
    #expect(firstPolicy.level == .strict)
    #expect(firstPolicy.fingerprintProtection)
}

@Test("Duplicating a tab applies saved website privacy before first navigation")
@MainActor
func duplicateTabAppliesSavedPrivacyBeforeFirstNavigation() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
    )
    let suiteName = "RexTests.DuplicateSitePrivacy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let windowID = UUID()
    let snapshot = testSnapshot(windowID: windowID, title: "Duplicate")
    try await persistence.save(snapshot)
    try await persistence.saveSitePrivacyPolicy(SitePrivacyPolicy(
        profileID: BrowserProfile.standard.id,
        host: "example.com",
        protectionEnabled: false,
        level: .strict,
        fingerprintProtectionEnabled: true
    ))
    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    let sourceTab = try #require(snapshot.tabs.first)
    _ = await commandsThroughFirstLoad(for: sourceTab.id, from: engine)
    for _ in 0..<400 where store.sitePrivacyPolicies.isEmpty {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.sitePrivacyPolicies.first?.level == .strict)

    store.duplicateTab(sourceTab.id)
    let duplicateTab = try #require(store.currentTab)
    #expect(duplicateTab.id != sourceTab.id)
    let commands = await commandsThroughFirstLoad(for: duplicateTab.id, from: engine)
    let firstLoad = try #require(firstLoadURLCommand(for: duplicateTab.id, in: commands))
    let firstPolicy = try #require(firstPrivacyPolicyCommand(for: duplicateTab.id, in: commands))

    #expect(firstLoad.url == sourceTab.url)
    #expect(firstPolicy.index < firstLoad.index)
    #expect(!firstPolicy.enabled)
    #expect(firstPolicy.level == .strict)
    #expect(firstPolicy.fingerprintProtection)
}

@Test("Restoring a closed tab applies saved website privacy before first navigation")
@MainActor
func restoreClosedTabAppliesSavedPrivacyBeforeFirstNavigation() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
    )
    let suiteName = "RexTests.RestoreClosedSitePrivacy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let windowID = UUID()
    let snapshot = testSnapshot(windowID: windowID, title: "Restore")
    try await persistence.save(snapshot)
    try await persistence.saveSitePrivacyPolicy(SitePrivacyPolicy(
        profileID: BrowserProfile.standard.id,
        host: "example.com",
        protectionEnabled: false,
        level: .strict,
        fingerprintProtectionEnabled: true
    ))
    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    let sourceTab = try #require(snapshot.tabs.first)
    _ = await commandsThroughFirstLoad(for: sourceTab.id, from: engine)
    for _ in 0..<400 where store.sitePrivacyPolicies.isEmpty {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.sitePrivacyPolicies.first?.level == .strict)

    store.closeCurrentTab()
    #expect(store.canRestoreClosedTab)
    store.restoreClosedTab()
    let restoredTab = try #require(store.currentTab)
    #expect(restoredTab.id != sourceTab.id)
    let commands = await commandsThroughFirstLoad(for: restoredTab.id, from: engine)
    let firstLoad = try #require(firstLoadURLCommand(for: restoredTab.id, in: commands))
    let firstPolicy = try #require(firstPrivacyPolicyCommand(for: restoredTab.id, in: commands))

    #expect(firstLoad.url == sourceTab.url)
    #expect(firstPolicy.index < firstLoad.index)
    #expect(!firstPolicy.enabled)
    #expect(firstPolicy.level == .strict)
    #expect(firstPolicy.fingerprintProtection)
}

@Test("Split session clamps ratios")
func splitRatioIsClamped() {
    let session = SplitViewSession(
        primaryTabID: UUID(),
        secondaryTabID: UUID(),
        ratio: 0.95,
        spaceID: UUID()
    )
    #expect(session.ratio == 0.75)
}

@Test("Saved split composition clamps ratios")
func savedSplitCompositionRatioIsClamped() {
    let composition = SavedSplitComposition(
        name: "Research",
        spaceID: UUID(),
        primaryTabID: UUID(),
        secondaryTabID: UUID(),
        orientation: .vertical,
        ratio: -1,
        focusedPane: .secondary,
        createdAt: Date(timeIntervalSince1970: 1_700_000_030),
        lastUsedAt: Date(timeIntervalSince1970: 1_700_000_040)
    )
    #expect(composition.ratio == 0.25)
}

@Test("Split layout geometry follows the active divider ratio")
func splitLayoutGeometryFollowsActiveRatio() {
    let size = CGSize(width: 1_000, height: 600)
    let quarter = SplitLayoutGeometry(size: size, ratio: 0.25, dividerWidth: 12)

    #expect(quarter.dividerFrame == CGRect(x: 244, y: 0, width: 12, height: 600))
    #expect(quarter.paneFrame(for: .primary) == CGRect(x: 0, y: 0, width: 244, height: 600))
    #expect(quarter.paneFrame(for: .secondary) == CGRect(x: 256, y: 0, width: 744, height: 600))

    let seventy = SplitLayoutGeometry(size: size, ratio: 0.70, dividerWidth: 12)
    #expect(seventy.dividerFrame == CGRect(x: 694, y: 0, width: 12, height: 600))
    #expect(seventy.paneFrame(for: .primary).maxX == seventy.dividerFrame.minX)
    #expect(seventy.paneFrame(for: .secondary).minX == seventy.dividerFrame.maxX)

    let invalid = SplitLayoutGeometry(size: .zero, ratio: 0.5, dividerWidth: 12)
    #expect(invalid.dividerFrame == .zero)
    #expect(invalid.paneFrame(for: .primary) == .zero)
}

@Test("Browser tab survives Codable round trip")
func browserTabCodableRoundTrip() throws {
    let tab = BrowserTab(
        url: URL(string: "https://example.com"),
        title: "Example",
        spaceID: UUID(),
        isPinned: true,
        blockedCount: 11
    )
    let data = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(BrowserTab.self, from: data)
    #expect(tab == decoded)
}

@Test("Session persistence atomically round-trips spaces, tabs, and split state")
func sessionPersistenceRoundTrip() async throws {
    let space = BrowserSpace(
        id: UUID(), name: "测试", symbolName: "testtube.2",
        tintHex: "7C6FF2", privacyLevel: .strict, downloadDirectoryBookmark: nil
    )
    var primary = BrowserTab(
        url: URL(string: "https://example.com"), title: "Primary", spaceID: space.id
    )
    var secondary = BrowserTab(
        url: URL(string: "https://www.rfc-editor.org"), title: "Secondary", spaceID: space.id
    )
    primary.lastAccessedAt = Date(timeIntervalSince1970: 1_700_000_010)
    secondary.lastAccessedAt = Date(timeIntervalSince1970: 1_700_000_020)
    let split = SplitViewSession(
        primaryTabID: primary.id, secondaryTabID: secondary.id,
        orientation: .vertical, ratio: 0.42, spaceID: space.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let paneStates = [
        SplitPaneState(
            pane: .primary,
            tabID: primary.id,
            navigation: NavigationState(url: primary.url, title: primary.title, zoomLevel: 1.25),
            scrollPosition: 120,
            isMuted: false
        ),
        SplitPaneState(
            pane: .secondary,
            tabID: secondary.id,
            navigation: NavigationState(url: secondary.url, title: secondary.title, zoomLevel: 0.9),
            scrollPosition: 60,
            isMuted: true
        )
    ]
    let composition = SavedSplitComposition(
        name: "RFC research",
        spaceID: space.id,
        primaryTabID: primary.id,
        secondaryTabID: secondary.id,
        orientation: .vertical,
        ratio: 0.42,
        focusedPane: .secondary,
        createdAt: Date(timeIntervalSince1970: 1_700_000_030),
        lastUsedAt: Date(timeIntervalSince1970: 1_700_000_040)
    )
    let snapshot = BrowserSessionSnapshot(
        schemaVersion: BrowserSessionSnapshot.schemaVersion,
        spaces: [space], tabs: [primary, secondary],
        currentSpaceID: space.id, selectedTabID: secondary.id,
        splitSession: split,
        splitPaneStates: paneStates,
        splitSessionsBySpace: [split],
        savedSplitCompositions: [composition],
        savedAt: Date(timeIntervalSince1970: 1_700_000_200)
    )
    let persistence = temporarySessionPersistence()

    try await persistence.save(snapshot)

    #expect(try await persistence.load() == snapshot)

    var replacement = snapshot
    replacement.tabs[0].title = "Updated primary"
    replacement.savedAt = Date(timeIntervalSince1970: 1_700_000_300)
    try await persistence.save(replacement)

    #expect(try await persistence.load() == replacement)
}

@Test("Version two snapshots decode with empty version three split collections")
func versionTwoSnapshotCompatibility() throws {
    let snapshot = testSnapshot()
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["schemaVersion"] = 2
    object.removeValue(forKey: "splitPaneStates")
    object.removeValue(forKey: "splitSessionsBySpace")
    object.removeValue(forKey: "savedSplitCompositions")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: legacyData)
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.splitPaneStates.isEmpty)
    #expect(decoded.splitSessionsBySpace.isEmpty)
    #expect(decoded.savedSplitCompositions.isEmpty)
    try decoded.validate()
}

@Test("SQLite keeps window sessions isolated")
func sqliteWindowSessionRoundTripAndIsolation() async throws {
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let firstWindow = UUID()
    let secondWindow = UUID()
    let first = testSnapshot(windowID: firstWindow, title: "First")
    let second = testSnapshot(windowID: secondWindow, title: "Second")

    try await persistence.save(first)
    try await persistence.save(second)

    #expect(try await persistence.load(windowID: firstWindow) == first)
    #expect(try await persistence.load(windowID: secondWindow) == second)
    #expect(try await persistence.loadAllWindows().map(\.id).contains(firstWindow))
    #expect(try await persistence.loadAllWindows().map(\.id).contains(secondWindow))
}

@Test("SQLite stores one privacy policy per profile and website")
func sqliteSitePrivacyPolicyRoundTrip() async throws {
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let profileID = UUID()
    let otherProfileID = UUID()
    let original = SitePrivacyPolicy(
        profileID: profileID,
        host: "WWW.Example.COM",
        protectionEnabled: false,
        level: .strict,
        fingerprintProtectionEnabled: true,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try await persistence.saveSitePrivacyPolicy(original)

    var updated = original
    updated.protectionEnabled = true
    updated.level = .custom
    updated.updatedAt = Date(timeIntervalSince1970: 1_800_000_100)
    try await persistence.saveSitePrivacyPolicy(updated)
    try await persistence.saveSitePrivacyPolicy(original)
    try await persistence.saveSitePrivacyPolicy(SitePrivacyPolicy(
        profileID: otherProfileID,
        host: original.host,
        protectionEnabled: false
    ))

    let policies = try await persistence.sitePrivacyPolicies(profileID: profileID)
    #expect(policies.count == 1)
    #expect(policies.first?.id == original.id)
    #expect(policies.first?.host == "www.example.com")
    #expect(policies.first?.protectionEnabled == true)
    #expect(policies.first?.level == .custom)
}

@Test("Mozilla PSL scopes ICANN, private, wildcard, exception, IDN, localhost, and IP sites")
func publicSuffixListScopesSiteOwnership() {
    let list = PublicSuffixList.current
    #expect(list.version == "2026-07-25_14-20-03_UTC")
    #expect(list.registrableDomain(for: "assets.news.example.co.uk") == "example.co.uk")
    #expect(list.registrableDomain(for: "a.blogspot.com") == "a.blogspot.com")
    #expect(list.registrableDomain(for: "a.b.ck") == "a.b.ck")
    #expect(list.registrableDomain(for: "a.www.ck") == "www.ck")
    #expect(list.registrableDomain(for: "食狮.com.cn") == "xn--85x722f.com.cn")
    #expect(list.registrableDomain(for: "localhost") == "localhost")
    #expect(list.registrableDomain(for: "127.0.0.1") == "127.0.0.1")
    #expect(list.registrableDomain(for: "2001:db8::1") == "2001:db8::1")
}

@Test("PSL site-policy migration atomically merges host records by newest update")
func pslSitePolicyMigrationCanReplaceLegacyRows() async throws {
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let profileID = UUID()
    let older = SitePrivacyPolicy(
        profileID: profileID,
        host: "www.example.co.uk",
        protectionEnabled: false,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newer = SitePrivacyPolicy(
        profileID: profileID,
        host: "shop.example.co.uk",
        protectionEnabled: true,
        level: .strict,
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    try await persistence.saveSitePrivacyPolicy(older)
    try await persistence.saveSitePrivacyPolicy(newer)

    var migrated = newer
    migrated.host = PublicSuffixList.current.registrableDomain(for: newer.host)
    try await persistence.replaceSitePrivacyPolicies(profileID: profileID, with: [migrated])

    let policies = try await persistence.sitePrivacyPolicies(profileID: profileID)
    #expect(policies.count == 1)
    #expect(policies.first?.host == "example.co.uk")
    #expect(policies.first?.level == .strict)
    #expect(policies.first?.protectionEnabled == true)
}

@Test("SQLite imports the legacy JSON session only once")
func sqliteMigratesLegacySessionOnce() async throws {
    let legacy = BrowserSessionPersistence(
        fileURL: FileManager.default.temporaryDirectory
            .appending(path: "rex-legacy-tests-\(UUID().uuidString)/session-v1.json")
    )
    let legacySnapshot = testSnapshot(title: "Legacy")
    var schemaOneSnapshot = legacySnapshot
    schemaOneSnapshot.schemaVersion = 1
    try await legacy.save(schemaOneSnapshot)

    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(), legacyPersistence: legacy
    )
    let firstWindow = UUID()
    let secondWindow = UUID()
    let migrated = try await persistence.load(windowID: firstWindow)

    #expect(migrated?.windowID == firstWindow)
    #expect(migrated?.schemaVersion == BrowserSessionSnapshot.schemaVersion)
    #expect(try await persistence.load(windowID: secondWindow) == nil)
    #expect(try await persistence.load(windowID: firstWindow)?.windowID == firstWindow)
}

@Test("SQLite libraries round-trip history, bookmarks, and downloads")
func sqliteLibraryRoundTrips() async throws {
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let history = BrowserHistoryEntry(
        url: URL(string: "https://example.com/history")!, title: "History",
        visitedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let bookmark = BrowserBookmark(
        url: URL(string: "https://example.com/bookmark")!, title: "Bookmark",
        createdAt: Date(timeIntervalSince1970: 1_700_000_002),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_003), folderName: "工作"
    )
    let download = BrowserDownloadTask(
        id: UUID(), sourceURL: URL(string: "https://example.com/file.zip")!,
        suggestedFilename: "file.zip", receivedBytes: 128, expectedBytes: 256,
        state: .downloading, createdAt: Date(timeIntervalSince1970: 1_700_000_004)
    )

    try await persistence.addHistory(history)
    try await persistence.saveBookmark(bookmark)
    try await persistence.saveDownload(download)

    #expect(try await persistence.history() == [history])
    #expect(try await persistence.bookmarks() == [bookmark])
    #expect(try await persistence.downloads() == [download])

    try await persistence.removeHistory(id: history.id)
    try await persistence.removeBookmark(id: bookmark.id)
    try await persistence.removeDownload(id: download.id)
    #expect(try await persistence.history().isEmpty)
    #expect(try await persistence.bookmarks().isEmpty)
    #expect(try await persistence.downloads().isEmpty)
}

@Test("SQLite history range deletion includes the cutoff boundary")
func sqliteHistoryRangeDeletionUsesInclusiveCutoff() async throws {
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
    let older = BrowserHistoryEntry(
        url: URL(string: "https://example.com/older")!,
        title: "Older",
        visitedAt: cutoff.addingTimeInterval(-0.001)
    )
    let boundary = BrowserHistoryEntry(
        url: URL(string: "https://example.com/boundary")!,
        title: "Boundary",
        visitedAt: cutoff
    )
    let newer = BrowserHistoryEntry(
        url: URL(string: "https://example.com/newer")!,
        title: "Newer",
        visitedAt: cutoff.addingTimeInterval(0.001)
    )

    for entry in [older, boundary, newer] {
        try await persistence.addHistory(entry)
    }
    try await persistence.removeHistory(visitedAtOrAfter: cutoff)

    #expect(try await persistence.history() == [older])
}

@Test("SQLite all-time history deletion clears every record")
func sqliteAllTimeHistoryDeletionClearsAllRecords() async throws {
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    for offset in [0.0, 3_600, 604_800] {
        try await persistence.addHistory(BrowserHistoryEntry(
            url: URL(string: "https://example.com/\(Int(offset))")!,
            title: "History \(offset)",
            visitedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        ))
    }

    try await persistence.removeHistory(visitedAtOrAfter: nil)

    #expect(try await persistence.history().isEmpty)
}

@Test("Browsing data ranges calculate hour, day, and week cutoffs")
func browsingDataRangesCalculateCutoffs() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(BrowsingDataTimeRange.lastHour.cutoff(relativeTo: now) == now.addingTimeInterval(-3_600))
    #expect(BrowsingDataTimeRange.last24Hours.cutoff(relativeTo: now) == now.addingTimeInterval(-86_400))
    #expect(BrowsingDataTimeRange.last7Days.cutoff(relativeTo: now) == now.addingTimeInterval(-604_800))
    #expect(BrowsingDataTimeRange.allTime.cutoff(relativeTo: now) == nil)
}

@Test("Download records decode paths added after v0.5")
func downloadRecordDecodesLegacyPayload() throws {
    let id = UUID()
    let payload = Data("""
        {
          "id": "\(id.uuidString)",
          "sourceURL": "https://example.com/archive.zip",
          "suggestedFilename": "archive.zip",
          "receivedBytes": 12,
          "expectedBytes": 24,
          "state": "completed",
          "createdAt": 0
        }
        """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let download = try decoder.decode(BrowserDownloadTask.self, from: payload)

    #expect(download.id == id)
    #expect(download.destinationURL == nil)
    #expect(download.errorDescription == nil)
    #expect(download.progress == 0.5)
    #expect(!download.canOpen)
}

@Test("Download progress maps Chromium percent before byte fallback")
func downloadProgressPrefersChromiumPercent() {
    let download = BrowserDownloadTask(
        id: UUID(),
        sourceURL: URL(string: "https://example.com/archive.zip")!,
        suggestedFilename: "archive.zip",
        receivedBytes: 20,
        expectedBytes: 100,
        state: .downloading,
        createdAt: .now,
        chromiumPercentComplete: 37
    )

    #expect(download.progress == 0.37)
}

@Test("Unknown Chromium download state is not actionable")
func unknownChromiumDownloadStateIsNotActionable() {
    let download = BrowserDownloadTask(
        id: UUID(),
        sourceURL: URL(string: "https://example.com/archive.zip")!,
        suggestedFilename: "archive.zip",
        receivedBytes: 0,
        expectedBytes: nil,
        state: .unknown,
        createdAt: .now
    )

    #expect(!download.canCancel)
    #expect(!download.canRetry)
    #expect(!download.isTerminal)
}

@Test("Download manager cancels and retries with the same task identity")
@MainActor
func downloadManagerDispatchesCancelAndRetry() async throws {
    let engine = ControlledBrowserEngine()
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let store = BrowserStore(engine: engine, databasePersistence: persistence)
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let downloadID = UUID()
    let sourceURL = try #require(URL(string: "https://example.com/archive.zip"))
    let active = BrowserDownloadTask(
        id: downloadID,
        sourceURL: sourceURL,
        suggestedFilename: "archive.zip",
        receivedBytes: 25,
        expectedBytes: 100,
        state: .downloading,
        createdAt: .now
    )

    await engine.emit(.downloadUpdated(tabID: tabID, download: active))
    try? await Task.sleep(for: .milliseconds(10))
    let storedActive = try #require(store.downloads.first)
    #expect(storedActive.progress == 0.25)
    #expect(storedActive.canCancel)
    #expect(store.downloadPanelRequest == 1)

    store.cancelDownload(storedActive)
    await engine.emit(.downloadUpdated(
        tabID: tabID,
        download: BrowserDownloadTask(
            id: downloadID,
            sourceURL: sourceURL,
            suggestedFilename: "archive.zip",
            receivedBytes: 25,
            expectedBytes: 100,
            state: .cancelled,
            createdAt: active.createdAt
        )
    ))
    try? await Task.sleep(for: .milliseconds(10))
    let cancelled = try #require(store.downloads.first)
    #expect(store.downloadPanelRequest == 1)
    store.retryDownload(cancelled)
    try? await Task.sleep(for: .milliseconds(10))

    #expect(store.downloads.first?.id == downloadID)
    // Retry remains in the last Chromium-reported state until Chromium emits
    // the new task lifecycle snapshot.
    #expect(store.downloads.first?.state == .cancelled)
    #expect(await engine.recordedCommands().contains(.cancelDownload(downloadID: downloadID)))
    #expect(await engine.recordedCommands().contains(.retryDownload(
        downloadID: downloadID,
        tabID: tabID,
        url: sourceURL
    )))
    await engine.finish()
}

@Test("Default download directory is Downloads/Rex")
@MainActor
func defaultDownloadDirectoryUsesRexFolder() {
    let home = URL(fileURLWithPath: "/tmp/rex-test-home", isDirectory: true)
    #expect(
        BrowserStore.defaultDownloadDirectory(homeDirectory: home).path ==
            "/tmp/rex-test-home/Downloads/Rex"
    )
}

@Test("A direct download response cannot trap session restore in a download loop")
@MainActor
func directDownloadResponseIsNotRestoredAsNavigation() throws {
    let spaceID = UUID()
    let downloadURL = try #require(URL(
        string: "https://github.com/example/rex/releases/download/v1/Rex.pkg"
    ))
    var tab = BrowserTab(url: downloadURL, title: "Rex.pkg", spaceID: spaceID)
    tab.faviconURL = URL(string: "https://github.com/favicon.ico")
    tab.isLoading = true
    tab.loadingProgress = 0.4

    let restorable = BrowserStore.restorableTabAfterDownload(
        tab,
        nonRestorableURL: downloadURL
    )
    #expect(BrowserStartPage.matches(restorable.url))
    #expect(restorable.title == BrowserStartPage.title)
    #expect(restorable.faviconURL == nil)
    #expect(!restorable.isLoading)
    #expect(restorable.loadingProgress == 1)

    let ordinaryPage = BrowserStore.restorableTabAfterDownload(
        tab,
        nonRestorableURL: URL(string: "https://objects.githubusercontent.com/Rex.pkg")
    )
    #expect(ordinaryPage == tab)
}

@Test("GitHub release assets are removed before restored pages are created")
@MainActor
func githubReleaseAssetsAreNotRestoredAsNavigation() throws {
    let spaceID = UUID()
    let releaseURL = try #require(URL(
        string: "https://github.com/example/rex/releases/latest/download/Rex.dmg"
    ))
    let assetURL = try #require(URL(
        string: "https://release-assets.githubusercontent.com/github-production-release-asset/Rex.dmg"
    ))
    let releasePageURL = try #require(URL(
        string: "https://github.com/example/rex/releases/tag/v0.9.8"
    ))

    #expect(BrowserStore.isLikelyDirectDownloadNavigation(releaseURL))
    #expect(BrowserStore.isLikelyDirectDownloadNavigation(assetURL))
    #expect(!BrowserStore.isLikelyDirectDownloadNavigation(releasePageURL))

    let restored = BrowserStore.restorableTabForSession(BrowserTab(
        url: releaseURL,
        title: "Rex.dmg",
        spaceID: spaceID
    ))
    #expect(BrowserStartPage.matches(restored.url))
    #expect(restored.title == BrowserStartPage.title)

    let releasePage = BrowserStore.restorableTabForSession(BrowserTab(
        url: releasePageURL,
        title: "Rex release",
        spaceID: spaceID
    ))
    #expect(releasePage.url == releasePageURL)
}

@Test("Download directory is stored per workspace and sent to browser pages")
@MainActor
func downloadDirectoryIsConfiguredPerSpace() async throws {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForCreatePages(store.tabs.count)
    let directoryURL = FileManager.default.temporaryDirectory
        .appending(path: "rex-download-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    store.setDownloadDirectory(directoryURL)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.currentDownloadDirectoryURL?.standardizedFileURL == directoryURL.standardizedFileURL)
    let currentSpaceTabIDs = Set(store.tabs.filter { $0.spaceID == store.currentSpaceID }.map(\.id))
    let configuredTabIDs = Set(await engine.recordedCommands().compactMap { command -> UUID? in
        guard case let .setDownloadDirectory(tabID, configuredURL) = command,
              configuredURL?.standardizedFileURL == directoryURL.standardizedFileURL else { return nil }
        return tabID
    })
    #expect(configuredTabIDs == currentSpaceTabIDs)

    let commandCountBeforeReset = await engine.recordedCommands().count
    store.setDownloadDirectory(nil)
    try? await Task.sleep(for: .milliseconds(20))
    let defaultDirectory = BrowserStore.defaultDownloadDirectory().standardizedFileURL
    #expect(store.usesDefaultDownloadDirectory)
    let commandsAfterReset = (await engine.recordedCommands()).dropFirst(commandCountBeforeReset)
    let resetTabIDs = Set(commandsAfterReset.compactMap { command -> UUID? in
        guard case let .setDownloadDirectory(tabID, configuredURL) = command,
              configuredURL?.standardizedFileURL == defaultDirectory else { return nil }
        return tabID
    })
    #expect(resetTabIDs == currentSpaceTabIDs)
}

@Test("SQLite permissions use profile and origin scope")
func sqlitePermissionsRoundTrip() async throws {
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let profile = BrowserProfile.standard
    let permission = WebsitePermission(
        id: UUID(), profileID: profile.id,
        topLevelOrigin: "https://example.com",
        requestingOrigin: "https://media.example.com",
        kind: .microphone, decision: .allowAlways,
        tabID: nil, expiresAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )

    try await persistence.savePermission(permission)
    #expect(try await persistence.permissions(profileID: profile.id) == [permission])
    #expect(try await persistence.permissions(profileID: UUID()).isEmpty)

    let updated = WebsitePermission(
        id: UUID(), profileID: profile.id,
        topLevelOrigin: permission.topLevelOrigin,
        requestingOrigin: permission.requestingOrigin,
        kind: permission.kind, decision: .blockAlways,
        tabID: nil, expiresAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_011)
    )
    try await persistence.savePermission(updated)
    #expect(try await persistence.permissions(profileID: profile.id) == [updated])

    try await persistence.removePermission(id: updated.id)
    #expect(try await persistence.permissions(profileID: profile.id).isEmpty)
}

@Test("SQLite permission storage rejects transient decisions")
func sqlitePermissionsRejectTransientDecisions() async throws {
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let decisions: [PermissionDecision] = [.allowOnce, .revokeOnTabClose, .ask]

    for (index, decision) in decisions.enumerated() {
        let permission = WebsitePermission(
            id: UUID(),
            profileID: BrowserProfile.standard.id,
            topLevelOrigin: "https://transient-\(index).example.com",
            requestingOrigin: "https://transient-\(index).example.com",
            kind: .camera,
            decision: decision,
            tabID: decision == .revokeOnTabClose ? UUID() : nil,
            expiresAt: nil,
            updatedAt: .now
        )
        try await persistence.savePermission(permission)
    }

    #expect(try await persistence.permissions(profileID: BrowserProfile.standard.id).isEmpty)
    #expect(PermissionDecision.permissionCenterCases == [.ask, .allowAlways, .blockAlways])
}

@Test("Private browser store starts blank and does not persist browser data")
@MainActor
func privateBrowserStoreIsEphemeral() async throws {
    let engine = RecordingBrowserEngine()
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let profile = BrowserProfile.privateWindow()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        profile: profile
    )

    #expect(store.profile.isPrivate)
    #expect(store.tabs.count == 1)
    #expect(BrowserStartPage.matches(store.currentTab?.url))
    #expect(store.currentTab?.title == BrowserStartPage.title)
    #expect(store.addressText.isEmpty)
    #expect(store.history.isEmpty)
    #expect(store.bookmarks.isEmpty)
    await engine.waitForCreatePages(1)
    let createCommand = await engine.recordedCommands().first { command in
        if case let .createPage(_, commandProfile) = command { return commandProfile == profile }
        return false
    }
    #expect(createCommand != nil)

    store.addressText = "https://example.com/private"
    store.submitAddress()
    store.flushSession()
    try? await Task.sleep(for: .milliseconds(30))

    #expect(try await persistence.load(windowID: store.windowID) == nil)
    #expect(try await persistence.history().isEmpty)
    #expect(try await persistence.bookmarks().isEmpty)
    #expect(try await persistence.downloads().isEmpty)
    #expect(try await persistence.permissions(profileID: profile.id).isEmpty)
}

@Test("Permission request uses a saved decision and responds to CEF")
@MainActor
func permissionRequestUsesSavedDecision() async throws {
    let engine = ControlledBrowserEngine()
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let store = BrowserStore(engine: engine, databasePersistence: persistence)
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let requestID = UUID()
    let request = WebsitePermissionRequest(
        id: requestID,
        topLevelOrigin: "https://example.com",
        requestingOrigin: "https://example.com",
        kinds: [.camera, .microphone],
        requestedAt: .now
    )

    await engine.emit(.permissionRequested(tabID: tabID, request: request))
    try? await Task.sleep(for: .milliseconds(10))
    #expect(store.pendingPermissionPrompts.count == 1)
    let prompt = try #require(store.pendingPermissionPrompts.first)
    store.respond(to: prompt, with: .allowAlways)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.pendingPermissionPrompts.isEmpty)
    #expect(Set(store.permissions.map(\.kind)) == Set([.camera, .microphone]))
    #expect(await engine.recordedCommands().contains(.respondToPermission(
        requestID: requestID, decision: .allowAlways
    )))
    await engine.finish()
}

@Test("Blocking an active media permission stops capture by reloading its tab")
@MainActor
func blockingActiveMediaPermissionReloadsItsTab() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let currentURL = try #require(store.currentTab?.url)
    let scheme = try #require(currentURL.scheme)
    let host = try #require(currentURL.host)
    let topLevelOrigin = "\(scheme)://\(host)"
    let request = WebsitePermissionRequest(
        id: UUID(),
        topLevelOrigin: topLevelOrigin,
        requestingOrigin: topLevelOrigin,
        kinds: [.camera],
        requestedAt: .now
    )

    await engine.emit(.permissionRequested(tabID: tabID, request: request))
    try? await Task.sleep(for: .milliseconds(10))
    store.respond(
        to: try #require(store.pendingPermissionPrompts.first),
        with: .allowAlways
    )
    await engine.emit(.mediaAccessChanged(tabID: tabID, isActive: true))
    try? await Task.sleep(for: .milliseconds(10))
    let permission = try #require(store.permissions.first)

    store.updatePermission(permission, decision: .blockAlways)
    for _ in 0..<100 {
        if await engine.recordedCommands().contains(.reload(tabID: tabID)) { break }
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(await engine.recordedCommands().contains(.reload(tabID: tabID)))
    await engine.finish()
}

@Test("Transient permission choices remain session scoped to their source tab")
@MainActor
func transientPermissionChoicesStayScopedToSourceTab() async throws {
    let engine = ControlledBrowserEngine()
    let persistence = BrowserSQLitePersistence(databaseURL: temporaryDatabaseURL(), legacyPersistence: nil)
    let store = BrowserStore(engine: engine, databasePersistence: persistence)
    await engine.waitForSubscriber()
    let sourceTabID = store.selectedTabID

    let oneTimeRequest = WebsitePermissionRequest(
        id: UUID(),
        topLevelOrigin: "https://www.apple.com",
        requestingOrigin: "https://www.apple.com",
        kinds: [.camera],
        requestedAt: .now
    )
    await engine.emit(.permissionRequested(tabID: sourceTabID, request: oneTimeRequest))
    try? await Task.sleep(for: .milliseconds(10))
    let oneTimePrompt = try #require(store.pendingPermissionPrompts.first)
    store.respond(to: oneTimePrompt, with: .allowOnce)
    #expect(store.permissions.isEmpty)

    let tabScopedRequest = WebsitePermissionRequest(
        id: UUID(),
        topLevelOrigin: "https://www.apple.com",
        requestingOrigin: "https://media.apple.com",
        kinds: [.microphone],
        requestedAt: .now
    )
    await engine.emit(.permissionRequested(tabID: sourceTabID, request: tabScopedRequest))
    try? await Task.sleep(for: .milliseconds(10))
    let tabScopedPrompt = try #require(store.pendingPermissionPrompts.first)
    store.respond(to: tabScopedPrompt, with: .revokeOnTabClose)
    let permission = try #require(store.permissions.first)
    #expect(permission.tabID == sourceTabID)

    let unrelatedTabID = store.visibleTabs[2].id
    store.selectTab(unrelatedTabID)
    store.updatePermission(permission, decision: .allowOnce)
    store.updatePermission(permission, decision: .revokeOnTabClose)
    #expect(store.permissions.first?.decision == .revokeOnTabClose)
    #expect(store.permissions.first?.tabID == sourceTabID)

    store.closeTab(unrelatedTabID)
    #expect(store.permissions.first?.tabID == sourceTabID)
    store.closeTab(sourceTabID)
    #expect(store.permissions.isEmpty)
    #expect(try await persistence.permissions(profileID: store.profile.id).isEmpty)
    await engine.finish()
}

@Test("Store supports groups, search, moving, archiving, and restore")
@MainActor
func storeOrganizationActions() {
    let store = BrowserStore(
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let tab = store.visibleTabs[2]
    let groupID = store.createGroup(name: "研究")
    #expect(groupID != nil)
    store.moveTab(tab.id, toGroup: groupID)
    #expect(store.tab(withID: tab.id)?.groupID == groupID)
    store.togglePinned(tab.id)
    #expect(store.tab(withID: tab.id)?.isPinned == true)
    store.searchQuery = "Chromium"
    #expect(store.visibleTabs.contains { $0.id == tab.id })

    store.archiveTab(tab.id)
    #expect(store.archivedTabs.contains { $0.id == tab.id })
    store.restoreArchivedTab(tab.id)
    #expect(store.tab(withID: tab.id)?.isArchived == false)
    #expect(store.selectedTabID == tab.id)

    store.deleteGroup(groupID!)
    #expect(store.tab(withID: tab.id)?.groupID == nil)
}

@Test("Archiving suspends the Chromium page and restoring resumes it")
@MainActor
func archivedTabsDispatchSuspendAndResume() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForCreatePages(store.tabs.count)
    let tabID = store.visibleTabs[2].id

    store.archiveTab(tabID)
    await engine.waitForSuspensionCount(1, tabID: tabID)
    #expect(store.tab(withID: tabID)?.lifecycle == .archived)
    #expect(await engine.pageSuspensions(for: tabID) == [true])

    store.restoreArchivedTab(tabID)
    await engine.waitForSuspensionCount(2, tabID: tabID)
    #expect(store.selectedTabID == tabID)
    #expect(store.tab(withID: tabID)?.isArchived == false)
    #expect(await engine.pageSuspensions(for: tabID) == [true, false])
}

@Test("Automatic sleep protects current, pinned, audio, and split tabs")
@MainActor
func automaticSleepProtection() {
    let store = BrowserStore(
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let visible = store.visibleTabs
    let ordinary = visible[2]
    let pinned = visible[1]
    let audio = visible[3]
    let future = Date(timeIntervalSinceNow: 3_600)

    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: ordinary.id)?.isSleeping == true)
    #expect(store.tab(withID: store.selectedTabID)?.isSleeping == false)
    #expect(store.tab(withID: pinned.id)?.isSleeping == false)
    #expect(store.tab(withID: audio.id)?.isSleeping == false)

    store.setTabSleeping(ordinary.id, sleeping: false)
    store.beginSplit(primaryTabID: store.selectedTabID, secondaryTabID: ordinary.id)
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: store.selectedTabID)?.isSleeping == false)
    #expect(store.tab(withID: ordinary.id)?.isSleeping == false)
}

@Test("Automatic sleep waits for navigation, downloads, permissions, and media work")
@MainActor
func automaticSleepProtectsActivePageWork() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let tab = store.visibleTabs[2]
    let future = Date(timeIntervalSinceNow: 3_600)

    await engine.emit(.navigationChanged(
        tabID: tab.id,
        state: NavigationState(url: tab.url, title: tab.title, isLoading: true)
    ))
    try? await Task.sleep(for: .milliseconds(10))
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: tab.id)?.isSleeping == false)

    await engine.emit(.navigationChanged(
        tabID: tab.id,
        state: NavigationState(url: tab.url, title: tab.title, isLoading: false)
    ))
    let downloadID = UUID()
    let sourceURL = try #require(URL(string: "https://example.com/large-download.bin"))
    await engine.emit(.downloadUpdated(
        tabID: tab.id,
        download: BrowserDownloadTask(
            id: downloadID,
            sourceURL: sourceURL,
            suggestedFilename: "large-download.bin",
            receivedBytes: 512,
            expectedBytes: 1_024,
            state: .downloading,
            createdAt: .now
        )
    ))
    try? await Task.sleep(for: .milliseconds(10))
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: tab.id)?.isSleeping == false)

    await engine.emit(.downloadUpdated(
        tabID: tab.id,
        download: BrowserDownloadTask(
            id: downloadID,
            sourceURL: sourceURL,
            suggestedFilename: "large-download.bin",
            receivedBytes: 1_024,
            expectedBytes: 1_024,
            state: .completed,
            createdAt: .now
        )
    ))
    let permissionRequest = WebsitePermissionRequest(
        id: UUID(),
        topLevelOrigin: "https://www.chromium.org",
        requestingOrigin: "https://www.chromium.org",
        kinds: [.usb],
        requestedAt: .now
    )
    await engine.emit(.permissionRequested(tabID: tab.id, request: permissionRequest))
    try? await Task.sleep(for: .milliseconds(10))
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: tab.id)?.isSleeping == false)

    let prompt = try #require(store.pendingPermissionPrompts.first { $0.id == permissionRequest.id })
    store.respond(to: prompt, with: .revokeOnTabClose)
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: tab.id)?.isSleeping == false)
    let transientPermission = try #require(store.permissions.first { $0.tabID == tab.id })
    store.revokePermission(transientPermission)

    await engine.emit(.mediaAccessChanged(tabID: tab.id, isActive: true))
    try? await Task.sleep(for: .milliseconds(10))
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: tab.id)?.isSleeping == false)

    await engine.emit(.mediaAccessChanged(tabID: tab.id, isActive: false))
    try? await Task.sleep(for: .milliseconds(10))
    store.sleepInactiveTabs(now: future, idleInterval: 0)
    #expect(store.tab(withID: tab.id)?.isSleeping == true)
    await engine.finish()
}

@Test("Sleeping tabs suspend and resume when selected or automatic sleep is disabled")
@MainActor
func sleepingTabsDispatchSuspendAndResume() async {
    let suiteName = "RexTests.SleepCommands.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )
    await engine.waitForCreatePages(store.tabs.count)
    let originalTabID = store.selectedTabID
    let sleepingTabID = store.visibleTabs[2].id

    store.setTabSleeping(sleepingTabID, sleeping: true)
    await engine.waitForSuspensionCount(1, tabID: sleepingTabID)
    #expect(await engine.pageSuspensions(for: sleepingTabID) == [true])

    store.selectTab(sleepingTabID)
    await engine.waitForSuspensionCount(2, tabID: sleepingTabID)
    #expect(store.tab(withID: sleepingTabID)?.isSleeping == false)
    #expect(await engine.pageSuspensions(for: sleepingTabID) == [true, false])

    store.selectTab(originalTabID)
    store.setTabSleeping(sleepingTabID, sleeping: true)
    await engine.waitForSuspensionCount(3, tabID: sleepingTabID)
    preferences.setAutomaticTabSleeping(false)
    await engine.waitForSuspensionCount(4, tabID: sleepingTabID)

    #expect(store.tab(withID: sleepingTabID)?.isSleeping == false)
    #expect(await engine.pageSuspensions(for: sleepingTabID) == [true, false, true, false])
}

@Test("Store creates and ends a split")
@MainActor
func storeCreatesAndEndsSplit() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let visible = store.visibleTabs
    #expect(visible.count >= 2)
    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)
    #expect(store.splitSession != nil)
    #expect(store.primaryTab?.lifecycle == .splitActive)
    #expect(store.secondaryTab?.lifecycle == .splitActive)

    store.endSplit(keeping: visible[1].id)
    #expect(store.splitSession == nil)
    #expect(store.selectedTabID == visible[1].id)
}

@Test("Store clamps interactively updated split ratio")
@MainActor
func storeClampsUpdatedSplitRatio() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let visible = store.visibleTabs
    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)
    store.setSplitRatio(0.01)
    #expect(store.splitSession?.ratio == 0.25)
    store.setSplitRatio(0.98)
    #expect(store.splitSession?.ratio == 0.75)
}

@Test("Store swaps split pages while preserving the focused tab")
@MainActor
func storeSwapPreservesFocusedTab() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let visible = store.visibleTabs
    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)
    store.focus(.secondary)
    let focusedID = store.selectedTabID

    store.swapSplitPages()

    #expect(store.selectedTabID == focusedID)
    #expect(store.splitSession?.focusedPane == .primary)
    #expect(store.addressText == store.currentTab?.url?.absoluteString)
}

@Test("Store keeps split sessions horizontal only")
@MainActor
func storeForcesHorizontalSplit() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let visible = store.visibleTabs
    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)

    #expect(store.splitSession?.orientation == .horizontal)
}

@Test("Context menu places a tab on either side of a new split")
@MainActor
func storePlacesTabInNewSplit() {
    for pane in SplitPane.allCases {
        let store = BrowserStore(persistence: temporarySessionPersistence())
        let visible = store.visibleTabs
        let selectedID = store.selectedTabID
        let placedID = visible.first { $0.id != selectedID }!.id

        #expect(store.canPlaceTab(placedID, in: pane))
        #expect(store.placeTab(placedID, in: pane))
        #expect(store.splitSession?.orientation == .horizontal)
        #expect(store.splitSession?.focusedPane == pane)
        #expect(pane == .primary ? store.primaryTab?.id == placedID : store.secondaryTab?.id == placedID)
        #expect(pane == .primary ? store.secondaryTab?.id == selectedID : store.primaryTab?.id == selectedID)
        #expect(!store.canPlaceTab(placedID, in: pane))
        let unchangedSession = store.splitSession
        #expect(!store.placeTab(placedID, in: pane))
        #expect(store.splitSession == unchangedSession)
    }
}

@Test("Context menu replaces either pane while preserving split geometry")
@MainActor
func storeContextMenuReplacesSplitPane() {
    for pane in SplitPane.allCases {
        let store = BrowserStore(persistence: temporarySessionPersistence())
        store.newTab()
        let replacementID = store.selectedTabID
        let others = store.visibleTabs.filter { $0.id != replacementID }
        store.beginSplit(primaryTabID: others[0].id, secondaryTabID: others[1].id)
        store.setSplitRatio(0.41)
        let splitID = store.splitSession?.id
        let replacedID = pane == .primary ? others[0].id : others[1].id
        let retainedID = pane == .primary ? others[1].id : others[0].id

        #expect(store.canPlaceTab(replacementID, in: .primary))
        #expect(store.canPlaceTab(replacementID, in: .secondary))
        #expect(store.placeTab(replacementID, in: pane))
        #expect(store.splitSession?.id == splitID)
        #expect(store.splitSession?.ratio == 0.41)
        #expect(store.splitSession?.focusedPane == pane)
        #expect(pane == .primary ? store.primaryTab?.id == replacementID : store.secondaryTab?.id == replacementID)
        #expect(pane == .primary ? store.secondaryTab?.id == retainedID : store.primaryTab?.id == retainedID)
        #expect(store.tab(withID: replacedID)?.splitSessionID == nil)
        #expect(store.tab(withID: replacedID)?.lifecycle != .splitActive)
    }
}

@Test("Replacing the focused split pane unfocuses the evicted page first")
@MainActor
func replacingFocusedSplitPaneUpdatesEngineFocusInOrder() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(engine: engine, persistence: temporarySessionPersistence())
    await engine.waitForCreatePages(store.tabs.count)
    let visible = store.visibleTabs
    let originalPrimaryID = visible[0].id
    let originalSecondaryID = visible[1].id
    let replacementID = visible[2].id

    store.beginSplit(
        primaryTabID: originalPrimaryID,
        secondaryTabID: originalSecondaryID
    )
    await engine.waitForPagePriorityCount(2)
    let initialPriorityCount = await engine.pagePriorityCommands().count

    #expect(store.placeTab(replacementID, in: .primary))
    await engine.waitForPagePriorityCount(initialPriorityCount + 3)

    let commands = Array(
        (await engine.pagePriorityCommands()).dropFirst(initialPriorityCount)
    )
    #expect(commands == [
        .setPagePriority(tabID: originalPrimaryID, isFocused: false),
        .setPagePriority(tabID: originalSecondaryID, isFocused: false),
        .setPagePriority(tabID: replacementID, isFocused: true),
    ])
}

@Test("Ending a split on its unfocused pane unfocuses the old page first")
@MainActor
func endingSplitOnUnfocusedPaneUpdatesEngineFocusInOrder() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(engine: engine, persistence: temporarySessionPersistence())
    await engine.waitForCreatePages(store.tabs.count)
    let visible = store.visibleTabs
    let originalPrimaryID = visible[0].id
    let originalSecondaryID = visible[1].id

    store.beginSplit(
        primaryTabID: originalPrimaryID,
        secondaryTabID: originalSecondaryID
    )
    await engine.waitForPagePriorityCount(2)
    let initialPriorityCount = await engine.pagePriorityCommands().count

    store.endSplit(keeping: originalSecondaryID)
    await engine.waitForPagePriorityCount(initialPriorityCount + 2)

    let commands = Array(
        (await engine.pagePriorityCommands()).dropFirst(initialPriorityCount)
    )
    #expect(commands == [
        .setPagePriority(tabID: originalPrimaryID, isFocused: false),
        .setPagePriority(tabID: originalSecondaryID, isFocused: true),
    ])
}

@Test("Context menu moves a split tab to the other side and focuses it")
@MainActor
func storeContextMenuSwapsExistingSplitTabs() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let visible = store.visibleTabs
    let originalPrimaryID = visible[0].id
    let originalSecondaryID = visible[1].id
    store.beginSplit(primaryTabID: originalPrimaryID, secondaryTabID: originalSecondaryID)
    store.setSplitRatio(0.38)

    let unchangedSession = store.splitSession
    #expect(!store.canPlaceTab(originalPrimaryID, in: .primary))
    #expect(!store.placeTab(originalPrimaryID, in: .primary))
    #expect(store.splitSession == unchangedSession)

    #expect(store.canPlaceTab(originalPrimaryID, in: .secondary))
    #expect(store.placeTab(originalPrimaryID, in: .secondary))
    #expect(store.primaryTab?.id == originalSecondaryID)
    #expect(store.secondaryTab?.id == originalPrimaryID)
    #expect(store.splitSession?.focusedPane == .secondary)
    #expect(store.selectedTabID == originalPrimaryID)
    #expect(store.splitSession?.ratio == 0.38)

    #expect(store.placeTab(originalPrimaryID, in: .primary))
    #expect(store.primaryTab?.id == originalPrimaryID)
    #expect(store.secondaryTab?.id == originalSecondaryID)
    #expect(store.splitSession?.focusedPane == .primary)
    #expect(store.selectedTabID == originalPrimaryID)
}

@Test("Context menu placement rejects selected, missing, and cross-space tabs")
@MainActor
func storeContextMenuRejectsInvalidSplitPlacement() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let selectedID = store.selectedTabID
    let sourceTab = store.tabs.first { $0.spaceID != store.currentSpaceID }!
    let sourceSpaceID = sourceTab.spaceID
    let missingID = UUID()

    #expect(!store.canPlaceTab(selectedID, in: .primary))
    #expect(!store.placeTab(selectedID, in: .primary))
    #expect(!store.canPlaceTab(sourceTab.id, in: .secondary))
    #expect(!store.placeTab(sourceTab.id, in: .secondary))
    #expect(!store.canPlaceTab(missingID, in: .primary))
    #expect(!store.placeTab(missingID, in: .primary))
    #expect(store.splitSession == nil)
    #expect(store.selectedTabID == selectedID)
    #expect(store.tab(withID: sourceTab.id)?.spaceID == sourceSpaceID)
}

@Test("Saved split compositions restore their layout and can be deleted")
@MainActor
func storeSavesRestoresAndDeletesSplitCompositions() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let visible = store.visibleTabs
    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)
    store.setSplitRatio(0.38)
    store.focus(.secondary)
    let compositionID = store.saveCurrentSplitComposition(name: "Docs")
    #expect(compositionID != nil)

    store.endSplit(keeping: visible[0].id)
    #expect(store.restoreSplitComposition(compositionID!))
    #expect(store.splitSession?.orientation == .horizontal)
    #expect(store.splitSession?.ratio == 0.38)
    #expect(store.splitSession?.focusedPane == .secondary)
    #expect(store.selectedTabID == visible[1].id)

    store.deleteSplitComposition(compositionID!)
    #expect(store.savedSplitCompositions.isEmpty)
}

@Test("Space switching restores each space split without exposing inactive pages")
@MainActor
func storeRestoresSplitAcrossSpaceSwitches() {
    let store = BrowserStore(persistence: temporarySessionPersistence())
    let originalSpaceID = store.currentSpaceID
    let visible = store.visibleTabs
    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)
    let splitID = store.splitSession?.id
    let otherSpaceID = store.spaces.first { $0.id != originalSpaceID }!.id

    store.switchSpace(to: otherSpaceID)
    #expect(store.splitSession == nil)
    #expect(store.tab(withID: visible[0].id)?.lifecycle != .splitActive)

    store.switchSpace(to: originalSpaceID)
    #expect(store.splitSession?.id == splitID)
    #expect(store.splitSession?.orientation == .horizontal)
    #expect(store.tab(withID: visible[0].id)?.lifecycle == .splitActive)
}

@Test("Split layout changes reuse existing browser pages")
@MainActor
func splitLayoutChangesDoNotCreatePages() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let visible = store.visibleTabs
    await engine.waitForCreatePages(store.tabs.count)
    let initialCreateCount = await engine.createPageCount()

    store.beginSplit(primaryTabID: visible[0].id, secondaryTabID: visible[1].id)
    for ratio in stride(from: 0.2, through: 0.8, by: 0.05) {
        store.setSplitRatio(ratio)
    }
    #expect(store.placeTab(visible[0].id, in: .secondary))
    #expect(store.placeTab(visible[2].id, in: .primary))
    store.swapSplitPages()
    try? await Task.sleep(for: .milliseconds(10))

    #expect(await engine.createPageCount() == initialCreateCount)
}

@Test("Address submission dispatches a normalized URL to the browser engine")
@MainActor
func addressSubmissionLoadsTheRequestedPage() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )

    store.addressText = "example.org/docs"
    store.submitAddress()

    let tabID = store.selectedTabID
    let commands = await commandsThroughFirstLoad(for: tabID, from: engine)
    let createIndex = commands.firstIndex { command in
        guard case let .createPage(commandTabID, _) = command else { return false }
        return commandTabID == tabID
    }
    let firstPolicy = firstPrivacyPolicyCommand(for: tabID, in: commands)
    let firstLoad = firstLoadURLCommand(for: tabID, in: commands)

    #expect(createIndex != nil)
    #expect(firstPolicy != nil)
    #expect(firstLoad?.url == URL(string: "https://example.org/docs"))
    if let createIndex, let firstPolicy, let firstLoad {
        #expect(createIndex < firstPolicy.index)
        #expect(firstPolicy.index < firstLoad.index)
    }
    #expect(store.currentTab?.url == URL(string: "https://example.org/docs"))
}

@Test("Loading events without a URL preserve the restored address")
@MainActor
func loadingEventsWithoutURLPreserveRestoredAddress() async throws {
    let suiteName = "RexTests.RestoredAddress.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let engine = ControlledBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
    )
    let windowID = UUID()
    let snapshot = testSnapshot(windowID: windowID, title: "Restored")
    try await persistence.save(snapshot)
    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    #expect(store.isRestoringSession)
    await engine.waitForSubscriber()
    for _ in 0..<100 {
        if store.selectedTabID == snapshot.selectedTabID,
           !store.isRestoringSession {
            break
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.selectedTabID == snapshot.selectedTabID)
    #expect(!store.isRestoringSession)
    let tabID = snapshot.selectedTabID
    let restoredURL = try #require(snapshot.tabs.first?.url)

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: nil,
            title: "",
            isLoading: true,
            loadingProgress: 0,
            zoomLevel: 1
        )
    ))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(store.currentTab?.url == restoredURL)
    #expect(store.navigationStates[tabID]?.url == restoredURL)
    #expect(store.addressText == restoredURL.absoluteString)
    await engine.finish()
}

@Test("Legacy Chromium extension state migrates to Rex URLs")
@MainActor
func legacyChromiumExtensionStateMigratesToRexURLs() async throws {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let chromiumURL = try #require(URL(
        string: "chrome-extension://\(runtimeID)/pages/options.html"
    ))
    let rexURL = try #require(URL(
        string: "rex-extension://\(runtimeID)/pages/options.html"
    ))
    let chromiumOrigin = "chrome-extension://\(runtimeID)"
    let rexOrigin = "rex-extension://\(runtimeID)"
    let suiteName = "RexTests.LegacyExtensionState.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(),
        legacyPersistence: nil
    )
    let windowID = UUID()
    let space = BrowserSpace(
        id: UUID(),
        name: "扩展测试",
        symbolName: "puzzlepiece.extension",
        tintHex: "48A9A6",
        privacyLevel: .standard,
        downloadDirectoryBookmark: nil
    )
    let primary = BrowserTab(
        url: chromiumURL,
        title: chromiumURL.absoluteString,
        spaceID: space.id
    )
    let secondary = BrowserTab(
        url: URL(string: "https://example.com"),
        title: "Example",
        spaceID: space.id
    )
    let split = SplitViewSession(
        primaryTabID: primary.id,
        secondaryTabID: secondary.id,
        spaceID: space.id
    )
    let snapshot = BrowserSessionSnapshot(
        schemaVersion: BrowserSessionSnapshot.schemaVersion,
        windowID: windowID,
        spaces: [space],
        tabs: [primary, secondary],
        currentSpaceID: space.id,
        selectedTabID: primary.id,
        splitSession: split,
        splitPaneStates: [
            SplitPaneState(
                pane: .primary,
                tabID: primary.id,
                navigation: NavigationState(
                    url: chromiumURL,
                    title: chromiumURL.absoluteString
                ),
                scrollPosition: 0,
                isMuted: false
            ),
            SplitPaneState(
                pane: .secondary,
                tabID: secondary.id,
                navigation: NavigationState(
                    url: secondary.url,
                    title: secondary.title
                ),
                scrollPosition: 0,
                isMuted: false
            )
        ],
        savedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let history = BrowserHistoryEntry(
        url: chromiumURL,
        title: chromiumURL.absoluteString
    )
    let bookmark = BrowserBookmark(
        url: chromiumURL,
        title: chromiumURL.absoluteString
    )
    let download = BrowserDownloadTask(
        id: UUID(),
        sourceURL: chromiumURL,
        suggestedFilename: "export.json",
        receivedBytes: 10,
        expectedBytes: 10,
        state: .completed,
        createdAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let permission = WebsitePermission(
        id: UUID(),
        profileID: BrowserProfile.standard.id,
        topLevelOrigin: chromiumOrigin,
        requestingOrigin: chromiumOrigin,
        kind: .clipboard,
        decision: .allowAlways,
        tabID: nil,
        expiresAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    try await persistence.save(snapshot)
    try await persistence.addHistory(history)
    try await persistence.saveBookmark(bookmark)
    try await persistence.saveDownload(download)
    try await persistence.savePermission(permission)

    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        windowID: windowID,
        preferences: preferences
    )
    await engine.waitForSubscriber()
    for _ in 0..<200 {
        if !store.isRestoringSession,
           store.history.contains(where: { $0.id == history.id }),
           store.bookmarks.contains(where: { $0.id == bookmark.id }),
           store.downloads.contains(where: { $0.id == download.id }),
           store.permissions.contains(where: { $0.id == permission.id }) {
            break
        }
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(store.currentTab?.url == rexURL)
    #expect(store.currentTab?.title == rexURL.absoluteString)
    #expect(store.addressText == rexURL.absoluteString)
    #expect(store.navigationStates[primary.id]?.url == rexURL)
    #expect(store.navigationStates[primary.id]?.title == rexURL.absoluteString)
    #expect(store.history.first(where: { $0.id == history.id })?.url == rexURL)
    #expect(store.bookmarks.first(where: { $0.id == bookmark.id })?.url == rexURL)
    #expect(store.downloads.first(where: { $0.id == download.id })?.sourceURL == rexURL)
    #expect(store.permissions.first(where: { $0.id == permission.id })?.topLevelOrigin
        == rexOrigin)
    #expect(store.permissions.first(where: { $0.id == permission.id })?.requestingOrigin
        == rexOrigin)

    #expect(try await persistence.load(windowID: windowID)?.tabs.first?.url == rexURL)
    #expect(try await persistence.history().first(where: { $0.id == history.id })?.url
        == rexURL)
    #expect(try await persistence.bookmarks().first(where: { $0.id == bookmark.id })?.url
        == rexURL)
    #expect(try await persistence.downloads().first(where: { $0.id == download.id })?.sourceURL
        == rexURL)
    #expect(try await persistence.permissions(profileID: BrowserProfile.standard.id)
        .first(where: { $0.id == permission.id })?.topLevelOrigin == rexOrigin)
    await engine.finish()
}

@Test("Runtime events cannot expose Chromium extension values")
@MainActor
func runtimeEventsCannotExposeChromiumExtensionValues() async throws {
    let runtimeID = "abcdefghijklmnopabcdefghijklmnop"
    let chromiumURL = try #require(URL(
        string: "chrome-extension://\(runtimeID)/popup.html"
    ))
    let rexURL = try #require(URL(
        string: "rex-extension://\(runtimeID)/popup.html"
    ))
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(),
            legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let requestID = UUID()
    let downloadID = UUID()

    await engine.emit(.titleChanged(
        tabID: tabID,
        title: chromiumURL.absoluteString
    ))
    await engine.emit(.permissionRequested(
        tabID: tabID,
        request: WebsitePermissionRequest(
            id: requestID,
            topLevelOrigin: "chrome-extension://\(runtimeID)",
            requestingOrigin: "chrome-extension://\(runtimeID)",
            kinds: [.clipboard],
            requestedAt: .now
        )
    ))
    await engine.emit(.downloadUpdated(
        tabID: tabID,
        download: BrowserDownloadTask(
            id: downloadID,
            sourceURL: chromiumURL,
            suggestedFilename: "settings.json",
            receivedBytes: 0,
            expectedBytes: nil,
            state: .downloading,
            createdAt: .now
        )
    ))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(store.currentTab?.title == rexURL.absoluteString)
    #expect(store.pendingPermissionPrompts.first(where: { $0.id == requestID })?
        .request.topLevelOrigin == "rex-extension://\(runtimeID)")
    #expect(store.pendingPermissionPrompts.first(where: { $0.id == requestID })?
        .request.requestingOrigin == "rex-extension://\(runtimeID)")
    #expect(store.downloads.first(where: { $0.id == downloadID })?.sourceURL == rexURL)
    await engine.finish()
}

@Test("Address commands wait for page setup and preserve submission order")
@MainActor
func addressCommandsPreserveSubmissionOrder() async {
    let suiteName = "RexTests.AddressCommandOrder.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let engine = DelayedSetupBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )
    await engine.waitForPolicyConfiguration()

    store.addressText = "https://example.org/first"
    store.submitAddress()
    store.addressText = "https://example.org/second"
    store.submitAddress()

    await engine.waitForLoadCount(2)
    #expect(await engine.loadURLs() == [
        URL(string: "https://example.org/first")!,
        URL(string: "https://example.org/second")!
    ])
}

@Test("Browser shortcut actions dispatch navigation, find, zoom, and open developer tools")
@MainActor
func browserShortcutActionsDispatchCommands() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let tabID = store.selectedTabID
    await engine.waitForCreatePages(store.tabs.count)

    store.reload()
    store.hardReloadCurrentPage()
    store.showFind()
    store.findText = "Chromium"
    store.updateFind()
    store.findNext(forward: false)
    store.adjustZoom(by: 1)
    store.resetZoom()
    store.openDeveloperTools()
    store.openDeveloperToolsConsole()
    store.openDeveloperToolsInspect()
    store.dismissFind()

    let expectedCommands: [BrowserCommand] = [
        .reload(tabID: tabID),
        .reloadIgnoringCache(tabID: tabID),
        .find(tabID: tabID, query: "Chromium", forward: true, findNext: false),
        .find(tabID: tabID, query: "Chromium", forward: false, findNext: true),
        .setZoom(tabID: tabID, level: 1.1),
        .setZoom(tabID: tabID, level: 1),
        .openDeveloperToolsConsole(tabID: tabID),
        .openDeveloperToolsInspect(tabID: tabID),
        .stopFinding(tabID: tabID)
    ]
    for _ in 0..<40 {
        if await engine.containsAll(expectedCommands) { break }
        try? await Task.sleep(for: .milliseconds(5))
    }

    let commands = await engine.recordedCommands()
    for expected in expectedCommands {
        #expect(commands.contains(expected))
    }
    #expect(!store.isFindPresented)
    #expect(store.developerToolsTabID == tabID)
}

@Test("Switching developer tools targets closes the previous panel session")
@MainActor
func switchingDeveloperToolsTargetsClosesPreviousSession() {
    let store = BrowserStore(
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let firstTabID = store.selectedTabID

    store.openDeveloperTools()
    let firstRequestID = store.developerToolsRequestID
    store.beginDeveloperToolsResize()
    store.newTab()
    let secondTabID = store.selectedTabID
    store.openDeveloperToolsInspect()

    #expect(firstTabID != secondTabID)
    #expect(store.developerToolsTabID == secondTabID)
    #expect(store.developerToolsRequestID == firstRequestID + 1)
    #expect(!store.isDeveloperToolsResizing)
}

@Test("Browser shortcut actions cycle visible tabs in both directions")
@MainActor
func browserShortcutActionsCycleTabs() {
    let store = BrowserStore(
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let visible = store.visibleTabs
    let initialID = store.selectedTabID
    let initialIndex = visible.firstIndex { $0.id == initialID }!
    let nextID = visible[(initialIndex + 1) % visible.count].id

    store.selectAdjacentTab(forward: true)
    #expect(store.selectedTabID == nextID)
    store.selectAdjacentTab(forward: false)
    #expect(store.selectedTabID == initialID)
}

@Test("Chrome tab actions duplicate and restore closed tabs with fresh identities")
@MainActor
func chromeTabActionsDuplicateAndRestore() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForCreatePages(store.tabs.count)
    let source = store.visibleTabs[2]
    let initialCount = store.tabs.count

    store.duplicateTab(source.id)
    let duplicate = store.currentTab
    #expect(store.tabs.count == initialCount + 1)
    #expect(duplicate?.id != source.id)
    #expect(duplicate?.url == source.url)

    let closedID = duplicate!.id
    store.closeCurrentTab()
    #expect(store.canRestoreClosedTab)
    store.restoreClosedTab()

    #expect(store.tabs.count == initialCount + 1)
    #expect(store.currentTab?.id != closedID)
    #expect(store.currentTab?.url == source.url)
    #expect(!store.canRestoreClosedTab)
}

@Test("Chrome numeric shortcuts select tabs and Rex spaces")
@MainActor
func chromeNumericShortcutsSelectTabsAndSpaces() {
    let store = BrowserStore(
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    let firstTab = store.visibleTabs.first!.id
    let lastTab = store.visibleTabs.last!.id

    store.selectTab(atChromePosition: 9)
    #expect(store.selectedTabID == lastTab)
    store.selectTab(atChromePosition: 1)
    #expect(store.selectedTabID == firstTab)

    let secondSpace = store.spaces[1].id
    store.switchSpace(at: 2)
    #expect(store.currentSpaceID == secondSpace)
}

@Test("Chrome print and mute actions dispatch browser engine commands")
@MainActor
func chromePrintAndMuteDispatchCommands() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForCreatePages(store.tabs.count)
    let tabID = store.selectedTabID

    store.toggleMuted(tabID)
    store.printCurrentPage()
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.currentTab?.isMuted == true)
    #expect(await engine.recordedCommands().contains(.setAudioMuted(tabID: tabID, muted: true)))
    #expect(await engine.recordedCommands().contains(.printPage(tabID: tabID)))
}

@Test("CEF favicon audio and popup events update Rex tabs")
@MainActor
func chromiumPageEventsUpdateTabs() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let sourceID = store.selectedTabID
    let faviconURL = try #require(URL(string: "https://example.com/favicon.ico"))
    let faviconData = Data([0x89, 0x50, 0x4E, 0x47])

    await engine.emit(.faviconChanged(tabID: sourceID, url: faviconURL, imageData: faviconData))
    await engine.emit(.audioStateChanged(tabID: sourceID, isPlaying: true))
    await engine.emit(.popupRequested(
        tabID: sourceID,
        url: try #require(URL(string: "http://example.org/popup?utm_source=test&keep=1")),
        foreground: true
    ))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.tab(withID: sourceID)?.faviconURL == faviconURL)
    #expect(store.faviconData(for: sourceID) == faviconData)
    #expect(store.tab(withID: sourceID)?.isPlayingAudio == true)
    #expect(store.currentTab?.url == URL(string: "https://example.org/popup?keep=1"))
    #expect(store.currentTab?.privacyState.httpsUpgradeCount == 1)
    #expect(store.currentTab?.privacyState.cleanedParameterCount == 1)
    await engine.finish()
}

@Test("Privacy URL policy upgrades HTTPS and removes known tracking parameters")
func privacyURLPolicySanitizesPublicURLs() throws {
    let input = try #require(URL(string: "http://example.org/docs?utm_source=newsletter&keep=1&FBCLID=abc&utm_source=duplicate#section"))
    let result = PrivacyURLPolicy.apply(to: input)

    #expect(result.url == URL(string: "https://example.org/docs?keep=1#section"))
    #expect(result.didUpgradeHTTPS)
    #expect(result.removedParameterCount == 3)
}

@Test("Privacy URL policy keeps local HTTP and respects disabled protection")
func privacyURLPolicyPreservesLocalAndDisabledURLs() throws {
    let local = try #require(URL(string: "http://localhost:8080/?utm_medium=test&view=all"))
    let localResult = PrivacyURLPolicy.apply(to: local)
    #expect(localResult.url == URL(string: "http://localhost:8080/?view=all"))
    #expect(!localResult.didUpgradeHTTPS)
    #expect(localResult.removedParameterCount == 1)

    let publicURL = try #require(URL(string: "http://example.org/?gclid=abc"))
    let disabledResult = PrivacyURLPolicy.apply(to: publicURL, isEnabled: false)
    #expect(disabledResult.url == publicURL)
    #expect(!disabledResult.didChange)
}

@Test("Address submission applies privacy URL policy and records real metrics")
@MainActor
func addressSubmissionAppliesPrivacyURLPolicy() async {
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )

    store.addressText = "http://example.org/docs?utm_campaign=launch&ref=docs&gclid=123"
    store.submitAddress()

    for _ in 0..<20 {
        if !(await engine.loadURLs().isEmpty) { break }
        try? await Task.sleep(for: .milliseconds(5))
    }

    let expectedURL = URL(string: "https://example.org/docs?ref=docs")
    #expect(await engine.loadURLs().last == expectedURL)
    #expect(store.currentTab?.url == expectedURL)
    #expect(store.currentTab?.privacyState.httpsUpgradeCount == 1)
    #expect(store.currentTab?.privacyState.cleanedParameterCount == 2)
    #expect(store.privacyReport(for: store.currentTab).httpsUpgrades == 1)
    #expect(store.privacyReport(for: store.currentTab).cleanedParameters == 2)
}

@Test("Privacy state decodes counters missing from older sessions")
func privacyStateDecodesLegacyPayload() throws {
    let payload = Data(#"{"isEnabled":true,"level":"standard","blockedCount":4,"fingerprintProtectionEnabled":true,"httpsUpgradeEnabled":true}"#.utf8)
    let state = try JSONDecoder().decode(PrivacyState.self, from: payload)

    #expect(state.blockedCount == 4)
    #expect(state.httpsUpgradeCount == 0)
    #expect(state.cleanedParameterCount == 0)
    #expect(state.resources.isEmpty)
}

@Test("Shield controls save Safari-style website policy for every matching tab")
@MainActor
func shieldControlsPushPrivacyPolicy() async throws {
    let engine = ControlledBrowserEngine()
    let persistence = BrowserSQLitePersistence(
        databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
    )
    let suiteName = "RexTests.SitePrivacy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(true)
    let store = BrowserStore(
        engine: engine,
        databasePersistence: persistence,
        preferences: preferences
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    var initialPolicyIsReady = false
    for _ in 0..<400 {
        let commands = await engine.recordedCommands()
        initialPolicyIsReady = !store.isRestoringSession && commands.contains { command in
            guard case let .setPrivacyPolicy(commandTabID, _, _, _, _) = command else {
                return false
            }
            return commandTabID == tabID
        }
        if initialPolicyIsReady { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(initialPolicyIsReady)
    let matchingTabIDs = store.tabs.compactMap { tab in
        tab.url?.host == "www.apple.com" ? tab.id : nil
    }
    #expect(matchingTabIDs.count == 2)
    let originalSpaceLevel = store.currentSpace?.privacyLevel

    store.setPrivacyLevel(.strict)
    store.setPrivacyProtectionEnabled(false)
    var savedPolicies: [SitePrivacyPolicy] = []
    for _ in 0..<100 {
        savedPolicies = try await persistence.sitePrivacyPolicies(
            profileID: store.profile.id
        )
        if savedPolicies.first?.protectionEnabled == false { break }
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(store.currentTab?.privacyState.level == .strict)
    #expect(store.currentTab?.privacyState.isEnabled == false)
    #expect(store.currentTab?.privacyState.fingerprintProtectionEnabled == true)
    #expect(store.currentSpace?.privacyLevel == originalSpaceLevel)
    #expect(matchingTabIDs.allSatisfy {
        store.tab(withID: $0)?.privacyState.level == .strict
            && store.tab(withID: $0)?.privacyState.isEnabled == false
    })
    #expect(savedPolicies.count == 1)
    #expect(savedPolicies.first?.host == "apple.com")
    #expect(savedPolicies.first?.level == .strict)
    #expect(savedPolicies.first?.protectionEnabled == false)

    let commands = await engine.recordedCommands()
    #expect(commands.contains(where: {
        if case let .setPrivacyPolicy(id, enabled, level, fingerprint, cookies) = $0 {
            return id == tabID && enabled && level == .strict && fingerprint && cookies
        }
        return false
    }))
    #expect(commands.contains(where: {
        if case let .setPrivacyPolicy(id, enabled, _, _, _) = $0 {
            return id == tabID && enabled == false
        }
        return false
    }))
    await engine.finish()
}

@Test("Shared privacy preferences update every open browser window")
@MainActor
func sharedPrivacyPreferencesUpdateEveryStore() async {
    let suiteName = "RexTests.SharedPrivacy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)
    let firstEngine = RecordingBrowserEngine()
    let secondEngine = RecordingBrowserEngine()
    let firstStore = BrowserStore(
        engine: firstEngine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )
    let secondStore = BrowserStore(
        engine: secondEngine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )

    preferences.setHTTPSUpgradeEnabled(false)
    preferences.setBlockThirdPartyCookies(false)

    for _ in 0..<100 {
        let firstCommands = await firstEngine.recordedCommands()
        let secondCommands = await secondEngine.recordedCommands()
        let firstUpdated = firstCommands.contains { command in
            guard case let .setPrivacyPolicy(_, _, _, _, cookies) = command else { return false }
            return !cookies
        }
        let secondUpdated = secondCommands.contains { command in
            guard case let .setPrivacyPolicy(_, _, _, _, cookies) = command else { return false }
            return !cookies
        }
        if firstUpdated && secondUpdated { break }
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(firstStore.tabs.allSatisfy { !$0.privacyState.httpsUpgradeEnabled })
    #expect(secondStore.tabs.allSatisfy { !$0.privacyState.httpsUpgradeEnabled })
    let firstCookiePolicies = await firstEngine.thirdPartyCookiePolicies()
    let secondCookiePolicies = await secondEngine.thirdPartyCookiePolicies()
    #expect(firstCookiePolicies.contains(false))
    #expect(secondCookiePolicies.contains(false))
}

@Test("Settings presentation routes to the requested section")
@MainActor
func settingsPresentationRoutesToRequestedSection() {
    let store = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )

    store.presentSettings(.search)
    #expect(store.isSettingsPresented)
    #expect(store.settingsSection == .search)

    store.presentSettings()
    #expect(store.settingsSection == .general)
}

@Test("Blocked resource events aggregate into the privacy report")
@MainActor
func blockedResourceEventsUpdatePrivacyReport() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let firstAd = BlockedResource(
        id: UUID(),
        category: .advertisement,
        host: "doubleclick.net",
        count: 1,
        timestamp: timestamp
    )
    let secondAd = BlockedResource(
        id: UUID(),
        category: .advertisement,
        host: "doubleclick.net",
        count: 1,
        timestamp: timestamp
    )
    let tracker = BlockedResource(
        id: UUID(), category: .tracker, host: "google-analytics.com", count: 2, timestamp: timestamp
    )

    await engine.emit(.resourceBlocked(tabID: tabID, resource: firstAd))
    await engine.emit(.resourceBlocked(tabID: tabID, resource: secondAd))
    await engine.emit(.resourceBlocked(tabID: tabID, resource: tracker))
    try? await Task.sleep(for: .milliseconds(10))

    let report = store.privacyReport(for: store.currentTab)
    #expect(store.currentTab?.privacyState.blockedCount == 16)
    #expect(report.adsBlocked == 2)
    #expect(report.trackersBlocked == 2)
    #expect(report.totalBlocked == 16)
    #expect(report.resources.count == 2)
    await engine.finish()
}

@Test("Renderer navigation cannot expose an unavailable extension origin")
@MainActor
func rendererNavigationCannotExposeUnavailableExtensionOrigin() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let originalURL = store.currentTab?.url
    let internalURL = try #require(RexExtensionResourceURL(
        runtimeID: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        relativePath: "options.html"
    )?.rexURL)

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(url: internalURL)
    ))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(store.currentTab?.url == originalURL)
    await engine.finish()
}

@Test("Pending navigation ignores stale CEF address and title callbacks")
@MainActor
func pendingNavigationIgnoresStaleEvents() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        )
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let staleURL = try #require(store.currentTab?.url)

    store.addressText = "https://example.org"
    store.submitAddress()
    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(url: staleURL, title: "Stale", isLoading: true)
    ))
    await engine.emit(.titleChanged(tabID: tabID, title: "Stale page"))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(store.currentTab?.url == URL(string: "https://example.org"))
    #expect(store.currentTab?.title == "example.org")
    #expect(store.addressText == "https://example.org")

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(url: URL(string: "https://example.org/"), title: "", isLoading: false)
    ))
    await engine.emit(.titleChanged(tabID: tabID, title: "Example"))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(store.currentTab?.url == URL(string: "https://example.org/"))
    #expect(store.currentTab?.title == "Example")
    #expect(store.addressText == "https://example.org/")
    await engine.finish()
}

@Test("Pending navigation accepts Chromium redirects and rejects older generations")
@MainActor
func pendingNavigationAcceptsChromiumRedirectCompletion() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        profile: .privateWindow()
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let previousURL = try #require(store.currentTab?.url)
    let requestedURL = try #require(URL(string: "https://example.org/start"))
    let redirectedURL = try #require(URL(string: "https://www.example.org/final"))

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: previousURL,
            isLoading: false,
            loadingProgress: 1,
            navigationGeneration: 40
        )
    ))
    for _ in 0..<10 { await Task.yield() }

    store.addressText = requestedURL.absoluteString
    store.submitAddress()
    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: previousURL,
            title: "Old page",
            isLoading: false,
            loadingProgress: 1,
            navigationGeneration: 40
        )
    ))
    await engine.emit(.titleChanged(tabID: tabID, title: "Old page"))
    for _ in 0..<10 { await Task.yield() }

    #expect(store.currentTab?.url == requestedURL)
    #expect(store.currentTab?.title == "example.org")
    #expect(store.addressText == requestedURL.absoluteString)

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: nil,
            isLoading: true,
            loadingProgress: 0.2,
            navigationGeneration: 41
        )
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(store.isCurrentPageLoading)
    #expect(store.currentTab?.isLoading == true)
    #expect(store.currentTab?.url == requestedURL)

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: redirectedURL,
            isLoading: false,
            loadingProgress: 1,
            navigationGeneration: 41
        )
    ))
    await engine.emit(.titleChanged(tabID: tabID, title: "Final page"))
    for _ in 0..<10 { await Task.yield() }

    #expect(store.currentTab?.url == redirectedURL)
    #expect(store.currentTab?.title == "Final page")
    #expect(store.addressText == redirectedURL.absoluteString)
    #expect(!store.isCurrentPageLoading)
    #expect(store.currentTab?.isLoading == false)
    #expect(store.navigationStates[tabID]?.isLoading == false)

    store.reloadOrStop()
    for _ in 0..<100 {
        if await engine.recordedCommands().contains(.reload(tabID: tabID)) { break }
        await Task.yield()
    }
    let commands = await engine.recordedCommands()
    #expect(commands.contains(.reload(tabID: tabID)))
    #expect(!commands.contains(.stop(tabID: tabID)))
    await engine.finish()
}

@Test("A new address completes when Chromium remains in the same loading generation")
@MainActor
func pendingNavigationAcceptsSameGenerationReplacement() async throws {
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        profile: .privateWindow()
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let firstURL = try #require(URL(string: "https://first.example/loading"))
    let requestedURL = try #require(URL(string: "https://second.example/start"))
    let redirectedURL = try #require(URL(string: "https://second.example/final"))

    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: firstURL,
            title: "First",
            isLoading: true,
            loadingProgress: 0.4,
            navigationGeneration: 40
        )
    ))
    for _ in 0..<10 { await Task.yield() }

    store.addressText = requestedURL.absoluteString
    store.submitAddress()
    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: requestedURL,
            isLoading: true,
            loadingProgress: 0.6,
            navigationGeneration: 40
        )
    ))
    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(
            url: redirectedURL,
            isLoading: false,
            loadingProgress: 1,
            navigationGeneration: 40
        )
    ))
    await engine.emit(.titleChanged(tabID: tabID, title: "Second final"))
    for _ in 0..<10 { await Task.yield() }

    #expect(store.currentTab?.url == redirectedURL)
    #expect(store.currentTab?.title == "Second final")
    #expect(store.addressText == redirectedURL.absoluteString)
    #expect(!store.isCurrentPageLoading)
    #expect(store.navigationStates[tabID]?.isLoading == false)
    await engine.finish()
}

@Test("Start page helpers recognize blank and new-tab URLs")
func startPageHelpersRecognizeBlankAndNewTabURLs() {
    #expect(BrowserStartPage.matches(BrowserStartPage.url))
    #expect(BrowserStartPage.matches(URL(string: "about:blank")))
    #expect(BrowserStartPage.matches(URL(string: "about:newtab")))
    #expect(BrowserStartPage.matches(nil))
    #expect(!BrowserStartPage.matches(URL(string: "https://example.com")))
    #expect(BrowserStartPage.title == "新标签页")
}

@Test("New-tab favorite drafts trim names and normalize website URLs")
func newTabFavoriteDraftNormalizesInput() throws {
    let draft = try #require(NewTabFavoriteDraft(
        title: "  Rex 文档  ",
        urlText: " HTTPS://Example.COM:443/docs?q=swift "
    ))

    #expect(draft.title == "Rex 文档")
    #expect(draft.url == URL(string: "https://example.com/docs?q=swift"))
    #expect(NewTabFavoriteDraft.normalizedURL(from: "example.com") == URL(string: "https://example.com/"))
    #expect(NewTabFavoriteDraft.normalizedURL(from: "http://localhost:80") == URL(string: "http://localhost/"))
}

@Test("New-tab favorite drafts reject incomplete and unsafe input")
func newTabFavoriteDraftRejectsInvalidInput() {
    #expect(NewTabFavoriteDraft(title: "", urlText: "example.com") == nil)
    #expect(NewTabFavoriteDraft(title: "Example", urlText: "") == nil)
    #expect(NewTabFavoriteDraft(title: "Example", urlText: "ftp://example.com") == nil)
    #expect(NewTabFavoriteDraft(title: "Example", urlText: "https://") == nil)
    #expect(NewTabFavoriteDraft(title: "Example", urlText: "https://user:secret@example.com") == nil)
}

@Test("New-tab favorites stay synchronized across normal windows")
@MainActor
func newTabFavoritesSynchronizeAcrossWindows() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rex-favorites-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalogURL = root.appending(path: "newtab-favorites.json")
    let favoritesStore = NewTabFavoritesStore(catalogURL: catalogURL)
    let suiteName = "RexTests.NewTabFavorites.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setRestorePreviousSession(false)

    let firstWindow = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: root.appending(path: "First.sqlite"),
            legacyPersistence: nil
        ),
        preferences: preferences,
        newTabFavoritesStore: favoritesStore
    )
    let secondWindow = BrowserStore(
        engine: RecordingBrowserEngine(),
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: root.appending(path: "Second.sqlite"),
            legacyPersistence: nil
        ),
        preferences: preferences,
        newTabFavoritesStore: favoritesStore
    )

    #expect(firstWindow.addNewTabFavorite(
        title: "Example",
        url: URL(string: "https://example.com")
    ))
    #expect(secondWindow.newTabFavorites.map(\.title) == ["Example"])
    #expect(secondWindow.addNewTabFavorite(
        title: "Rex",
        url: URL(string: "https://rex.example")
    ))
    #expect(firstWindow.newTabFavorites.map(\.title) == ["Rex", "Example"])
    #expect(secondWindow.newTabFavorites == firstWindow.newTabFavorites)

    let reloaded = NewTabFavoritesStore(catalogURL: catalogURL)
    #expect(reloaded.favorites.map(\.title) == ["Rex", "Example"])
}

@Test("New-tab favorite writes report persistence failures without publishing")
@MainActor
func newTabFavoriteWriteFailureIsReported() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rex-favorites-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalogDirectory = root.appending(path: "catalog", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
    let favoritesStore = NewTabFavoritesStore(catalogURL: catalogDirectory)

    #expect(throws: (any Error).self) {
        try favoritesStore.add(NewTabFavoriteSite(
            url: URL(string: "https://example.com")!,
            title: "Example"
        ))
    }
    #expect(favoritesStore.favorites.isEmpty)
}

@Test("New-tab search engines map to distinct bundled brand assets")
@MainActor
func newTabSearchEngineBrandAssetsAreAvailable() {
    let expectedAssets: [SearchEngine: String] = [
        .google: "SearchEngineGoogle",
        .bing: "SearchEngineBing",
        .duckDuckGo: "SearchEngineDuckDuckGo",
        .brave: "SearchEngineBrave",
        .ecosia: "SearchEngineEcosia"
    ]

    let actualAssets = Dictionary(
        uniqueKeysWithValues: SearchEngine.allCases.map { ($0, $0.brandAssetName) }
    )
    #expect(actualAssets == expectedAssets)
    #expect(Set(expectedAssets.values).count == SearchEngine.allCases.count)
    #expect(SearchEngine.allCases.allSatisfy {
        SearchEngineBrandAssets.image(for: $0)?.isValid == true
    })
}

@Test("Window chrome keeps the toolbar clear of traffic lights")
func windowChromeToolbarInset() {
    #expect(BrowserWindowChromeLayout.toolbarLeadingInset(
        trafficLightTrailingEdge: 92.2,
        isFullScreen: false
    ) == 101)
    #expect(BrowserWindowChromeLayout.toolbarLeadingInset(
        trafficLightTrailingEdge: 56.2,
        isFullScreen: false
    ) == 65)
    #expect(BrowserWindowChromeLayout.toolbarLeadingInset(
        trafficLightTrailingEdge: nil,
        isFullScreen: false
    ) == 88)
    #expect(BrowserWindowChromeLayout.toolbarLeadingInset(
        trafficLightTrailingEdge: 92.2,
        isFullScreen: true
    ) == BrowserWindowChromeLayout.windowEdgePadding)
    #expect(BrowserWindowChromeLayout.trafficLightAdjustedY(
        baselineY: 12,
        superviewIsFlipped: false
    ) == 4)
    #expect(BrowserWindowChromeLayout.trafficLightAdjustedY(
        baselineY: 12,
        superviewIsFlipped: true
    ) == 20)

    #expect(RexMetrics.titlebarHeight == 50)
    #expect(RexMetrics.toolbarHeight == 44)
}

@Test("About information is derived from release and feature catalogs")
func aboutInformationUsesReleaseCatalogs() {
    let activeFeature = FeatureRecord(
        id: "active",
        name: "活动功能",
        status: .completed,
        testStatus: "passed",
        introducedIn: "9.0.0",
        updatedIn: "9.1.0",
        description: "测试功能",
        supportsPrivateWindow: true,
        supportsSplitView: false,
        supportsKeyboard: true,
        requiresRestart: false,
        settingsPath: "",
        limitations: []
    )
    let removedFeature = FeatureRecord(
        id: "removed",
        name: "已移除功能",
        status: .removed,
        testStatus: "removed",
        introducedIn: "8.0.0",
        updatedIn: "9.1.0",
        description: "不应列为当前能力",
        supportsPrivateWindow: false,
        supportsSplitView: false,
        supportsKeyboard: false,
        requiresRestart: false,
        settingsPath: "",
        limitations: []
    )
    let features = FeatureCatalog(
        lastUpdatedVersion: "9.1.0",
        categories: [
            FeatureCategory(
                id: "shell",
                name: "应用外壳",
                features: [activeFeature, removedFeature]
            )
        ]
    )
    let release = ReleaseRecord(
        version: "9.1.0",
        build: 910,
        date: "2026-07-27",
        channel: "beta",
        summary: "测试版本",
        added: [],
        improved: [],
        fixed: [],
        changed: [],
        removed: [],
        knownIssues: ["一项已知限制"],
        inProgress: []
    )
    let information = RexAboutInformation.make(
        version: "9.1.0",
        build: 910,
        chromiumVersion: "151.0",
        cefVersion: "151.0.1",
        architecture: "arm64",
        features: features,
        releases: ReleaseCatalog(releases: [release])
    )

    #expect(information.version == "9.1.0")
    #expect(information.build == 910)
    #expect(information.channel == "beta")
    #expect(information.channelDisplayName == "Beta")
    #expect(information.capabilityGroups.count == 1)
    #expect(information.capabilityGroups[0].featureNames == ["活动功能"])
    #expect(information.capabilityGroups[0].statusSummary == "1 已完成")
    #expect(information.knownLimitations == ["一项已知限制"])
}

@Test("Bundled about information matches the app version")
func bundledAboutInformationMatchesAppVersion() throws {
    let information = try ReleaseNotesService.loadAboutInformation()

    #expect(information.version == AppVersion.releaseVersion)
    #expect(information.build == AppVersion.buildNumber)
    #expect(information.chromiumVersion == AppVersion.chromiumVersion)
    #expect(information.cefVersion == AppVersion.cefVersion)
    #expect(information.architecture == AppVersion.supportedArchitecture)
    #expect(information.featureCatalogVersion == AppVersion.releaseVersion)
    #expect(!information.channel.isEmpty)
    #expect(!information.capabilityGroups.isEmpty)
    #expect(!information.knownLimitations.isEmpty)
}

@Test("Release identities distinguish builds that share a version")
func releaseIdentitiesIncludeBuildNumber() throws {
    let data = Data(
        """
        {
          "releases": [
            { "version": "1.0.0-beta.1", "build": 102 },
            { "version": "1.0.0-beta.1", "build": 101 }
          ]
        }
        """.utf8
    )
    let catalog = try JSONDecoder().decode(ReleaseCatalog.self, from: data)

    #expect(catalog.releases[0].id == "1.0.0-beta.1-build-102")
    #expect(catalog.releases[1].id == "1.0.0-beta.1-build-101")
    #expect(catalog.releases[0].id != catalog.releases[1].id)
    #expect(catalog.release(version: "1.0.0-beta.1", build: 101)?.build == 101)
    #expect(catalog.release(version: "1.0.0-beta.1", build: 103) == nil)
}

@Test("Menu localization preserves system command roles and shortcuts")
@MainActor
func menuLocalizationPreservesSystemRoles() {
    let mainMenu = NSMenu(title: "Main")
    let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Rex"
    let applicationItem = NSMenuItem(title: applicationName, action: nil, keyEquivalent: "")
    let applicationMenu = NSMenu(title: applicationName)
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services")
    let thirdPartyServiceItem = NSMenuItem(
        title: "Search",
        action: NSSelectorFromString("performService:"),
        keyEquivalent: ""
    )
    servicesMenu.addItem(thirdPartyServiceItem)
    applicationMenu.addItem(servicesItem)
    applicationMenu.setSubmenu(servicesMenu, for: servicesItem)
    mainMenu.addItem(applicationItem)
    mainMenu.setSubmenu(applicationMenu, for: applicationItem)

    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    let fileMenu = NSMenu(title: "File")
    let target = NSObject()
    let action = NSSelectorFromString("performClose:")
    let closeItem = NSMenuItem(title: "Close Window", action: action, keyEquivalent: "w")
    closeItem.target = target
    closeItem.keyEquivalentModifierMask = [.command, .shift]
    closeItem.state = .on
    fileMenu.addItem(closeItem)
    mainMenu.addItem(fileItem)
    mainMenu.setSubmenu(fileMenu, for: fileItem)

    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    let undoAction = NSSelectorFromString("undo:")
    let undoItem = NSMenuItem(title: "Undo Typing", action: undoAction, keyEquivalent: "z")
    undoItem.keyEquivalentModifierMask = .command
    editMenu.addItem(undoItem)
    mainMenu.addItem(editItem)
    mainMenu.setSubmenu(editMenu, for: editItem)

    let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    let viewMenu = NSMenu(title: "View")
    let exitFullScreenItem = NSMenuItem(
        title: "Exit Full Screen",
        action: NSSelectorFromString("toggleFullScreen:"),
        keyEquivalent: ""
    )
    viewMenu.addItem(exitFullScreenItem)
    mainMenu.addItem(viewItem)
    mainMenu.setSubmenu(viewMenu, for: viewItem)

    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    let minimizeItem = NSMenuItem(
        title: "Minimize",
        action: NSSelectorFromString("performMiniaturize:"),
        keyEquivalent: "m"
    )
    let dynamicWindowItem = NSMenuItem(
        title: "Search",
        action: NSSelectorFromString("makeKeyAndOrderFront:"),
        keyEquivalent: ""
    )
    windowMenu.addItem(minimizeItem)
    windowMenu.addItem(dynamicWindowItem)
    mainMenu.addItem(windowItem)
    mainMenu.setSubmenu(windowMenu, for: windowItem)

    let workspaceItem = NSMenuItem(title: "工作空间", action: nil, keyEquivalent: "")
    let workspaceMenu = NSMenu(title: "工作空间")
    let dynamicWorkspaceItem = NSMenuItem(
        title: "View",
        action: NSSelectorFromString("switchWorkspace:"),
        keyEquivalent: ""
    )
    workspaceMenu.addItem(dynamicWorkspaceItem)
    mainMenu.addItem(workspaceItem)
    mainMenu.setSubmenu(workspaceMenu, for: workspaceItem)

    RexMenuLocalization.apply(to: mainMenu)
    RexMenuLocalization.apply(to: mainMenu)

    #expect(applicationItem.title == applicationName)
    #expect(servicesItem.title == "服务")
    #expect(thirdPartyServiceItem.title == "Search")
    #expect(fileItem.title == "文件")
    #expect(fileMenu.title == "文件")
    #expect(closeItem.title == "关闭窗口")
    #expect(closeItem.action == action)
    #expect(closeItem.target === target)
    #expect(closeItem.keyEquivalent == "w")
    #expect(closeItem.keyEquivalentModifierMask == [.command, .shift])
    #expect(closeItem.state == .on)
    #expect(editItem.title == "编辑")
    #expect(undoItem.title == "撤销")
    #expect(undoItem.action == undoAction)
    #expect(undoItem.keyEquivalent == "z")
    #expect(undoItem.keyEquivalentModifierMask == .command)
    #expect(viewItem.title == "显示")
    #expect(exitFullScreenItem.title == "退出全屏幕")
    #expect(windowItem.title == "窗口")
    #expect(minimizeItem.title == "最小化")
    #expect(dynamicWindowItem.title == "Search")
    #expect(workspaceItem.title == "工作空间")
    #expect(dynamicWorkspaceItem.title == "View")
}

@Test("Search engines build HTTPS URLs with the original query")
func searchEnginesBuildValidURLs() throws {
    let query = "Rex 浏览器 privacy"
    let expectedHosts: [SearchEngine: String] = [
        .google: "www.google.com",
        .bing: "www.bing.com",
        .duckDuckGo: "duckduckgo.com",
        .brave: "search.brave.com",
        .ecosia: "www.ecosia.org"
    ]

    for engine in SearchEngine.allCases {
        let url = try #require(engine.searchURL(for: query))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == expectedHosts[engine])
        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == query)
    }
}

@Test("New tab opens the start page and keeps the selected search engine")
@MainActor
func newTabOpensStartPageWithSelectedSearchEngine() async {
    let suiteName = "RexTests.NewTabHome.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setSearchEngine(.google)
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )

    store.newTab()
    #expect(BrowserStartPage.matches(store.currentTab?.url))
    #expect(store.addressText.isEmpty)
    #expect(store.currentTab?.title == BrowserStartPage.title)
    #expect(store.preferences.searchEngine == .google)

    store.addressText = "Rex browser"
    store.submitAddress()
    for _ in 0..<40 {
        if store.currentTab?.url != BrowserStartPage.url { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.currentTab?.url == SearchEngine.google.searchURL(for: "Rex browser"))
}

@Test("Default search engine preference persists")
@MainActor
func searchEnginePreferencePersists() {
    let suiteName = "RexTests.SearchEngine.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = BrowserPreferences(defaults: defaults)
    #expect(preferences.searchEngine == .duckDuckGo)
    preferences.setSearchEngine(.bing)

    let restored = BrowserPreferences(defaults: defaults)
    #expect(restored.searchEngine == .bing)
}

@Test("Browser preferences persist and reset all typed settings")
@MainActor
func browserPreferencesPersistAndResetAllSettings() {
    let suiteName = "RexTests.Preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setSearchEngine(.ecosia)
    preferences.setAppearance(.dark)
    preferences.setRestorePreviousSession(false)
    preferences.setDefaultSidebarCollapsed(true)
    preferences.setShowPerformanceMetrics(false)
    preferences.setAutomaticTabSleeping(false)
    preferences.setTabSleepDelayMinutes(120)
    preferences.setBlockThirdPartyCookies(false)
    preferences.setHTTPSUpgradeEnabled(false)
    preferences.setContentBlockingEnabled(false)

    let restored = BrowserPreferences(defaults: defaults)
    #expect(restored.searchEngine == .ecosia)
    #expect(restored.appearance == .dark)
    #expect(!restored.restorePreviousSession)
    #expect(restored.defaultSidebarCollapsed)
    #expect(!restored.showPerformanceMetrics)
    #expect(!restored.automaticTabSleeping)
    #expect(restored.tabSleepDelayMinutes == 120)
    #expect(!restored.blockThirdPartyCookies)
    #expect(!restored.httpsUpgradeEnabled)
    #expect(!restored.contentBlockingEnabled)

    restored.resetToDefaults()
    let reset = BrowserPreferences(defaults: defaults)
    #expect(reset.searchEngine == .defaultValue)
    #expect(reset.appearance == .defaultValue)
    #expect(reset.restorePreviousSession == BrowserPreferences.defaultRestorePreviousSession)
    #expect(reset.defaultSidebarCollapsed == BrowserPreferences.defaultSidebarCollapsedValue)
    #expect(reset.showPerformanceMetrics == BrowserPreferences.defaultShowPerformanceMetrics)
    #expect(reset.automaticTabSleeping == BrowserPreferences.defaultAutomaticTabSleeping)
    #expect(reset.tabSleepDelayMinutes == BrowserPreferences.defaultTabSleepDelayMinutes)
    #expect(reset.blockThirdPartyCookies == BrowserPreferences.defaultBlockThirdPartyCookies)
    #expect(reset.httpsUpgradeEnabled == BrowserPreferences.defaultHTTPSUpgradeEnabled)
    #expect(reset.contentBlockingEnabled == BrowserPreferences.defaultContentBlockingEnabled)

    let preferenceKeys = [
        SearchEngine.defaultsKey,
        "Rex.appearance",
        "Rex.restorePreviousSession",
        "Rex.defaultSidebarCollapsed",
        "Rex.showPerformanceMetrics",
        "Rex.automaticTabSleeping",
        "Rex.tabSleepDelayMinutes",
        "Rex.blockThirdPartyCookies",
        "Rex.httpsUpgradeEnabled",
        "Rex.contentBlockingEnabled"
    ]
    #expect(preferenceKeys.allSatisfy { defaults.object(forKey: $0) == nil })
}

@Test("Content-blocking preference change pushes a content blocking command")
@MainActor
func contentBlockingPreferenceChangePushesCommand() async {
    let suiteName = "RexTests.ContentBlocking.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )

    preferences.setContentBlockingEnabled(false)
    var recorded: [Bool] = []
    for _ in 0..<200 {
        recorded = await engine.contentBlockingStates()
        if !recorded.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(recorded.last == false)

    preferences.setContentBlockingEnabled(true)
    for _ in 0..<200 {
        recorded = await engine.contentBlockingStates()
        if recorded.count >= 2 { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(recorded.last == true)
    withExtendedLifetime(store) {}
}

@Test("Address search uses the selected default search engine")
@MainActor
func addressSearchUsesSelectedEngine() async {
    let suiteName = "RexTests.AddressSearch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setSearchEngine(.google)
    let engine = RecordingBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )

    store.addressText = "Rex browser"
    store.submitAddress()
    for _ in 0..<20 {
        if !(await engine.loadURLs().isEmpty) { break }
        try? await Task.sleep(for: .milliseconds(5))
    }

    let url = await engine.loadURLs().last
    #expect(url?.host == "www.google.com")
    #expect(URLComponents(url: url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "q" })?.value == "Rex browser")
}

@Test("Chrome-style tab menu closes other and right-side tabs")
@MainActor
func tabMenuBulkCloseActions() {
    let closeOthersStore = BrowserStore(persistence: temporarySessionPersistence())
    let keepID = closeOthersStore.visibleTabs[1].id
    closeOthersStore.closeOtherTabs(except: keepID)
    #expect(closeOthersStore.visibleTabs.map(\.id) == [keepID])
    #expect(closeOthersStore.selectedTabID == keepID)

    let closeRightStore = BrowserStore(persistence: temporarySessionPersistence())
    let originalIDs = closeRightStore.visibleTabs.map(\.id)
    let pivotID = originalIDs[1]
    closeRightStore.closeTabsToRight(of: pivotID)
    #expect(closeRightStore.visibleTabs.map(\.id) == Array(originalIDs.prefix(2)))
}

@Test("CEF context commands open search results and links in split view")
@MainActor
func contextMenuEventsUpdateTabs() async throws {
    let suiteName = "RexTests.ContextMenu.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = BrowserPreferences(defaults: defaults)
    preferences.setSearchEngine(.bing)
    let engine = ControlledBrowserEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: temporaryDatabaseURL(), legacyPersistence: nil
        ),
        preferences: preferences
    )
    await engine.waitForSubscriber()
    let sourceID = store.selectedTabID
    let splitURL = try #require(URL(string: "https://example.org/split"))

    await engine.emit(.splitLinkRequested(tabID: sourceID, url: splitURL))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(store.splitSession?.primaryTabID == sourceID)
    #expect(store.secondaryTab?.url == splitURL)

    await engine.emit(.contextSearchRequested(tabID: sourceID, text: "Rex privacy"))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(store.currentTab?.url?.host == "www.bing.com")
    #expect(URLComponents(url: store.currentTab!.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "q" })?.value == "Rex privacy")
    await engine.finish()
}
