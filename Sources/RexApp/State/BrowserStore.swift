import AppKit
import Combine
import Foundation

enum BrowsingDataTimeRange: CaseIterable, Hashable, Sendable {
    case lastHour
    case last24Hours
    case last7Days
    case allTime

    func cutoff(relativeTo referenceDate: Date) -> Date? {
        switch self {
        case .lastHour:
            referenceDate.addingTimeInterval(-60 * 60)
        case .last24Hours:
            referenceDate.addingTimeInterval(-24 * 60 * 60)
        case .last7Days:
            referenceDate.addingTimeInterval(-7 * 24 * 60 * 60)
        case .allTime:
            nil
        }
    }
}

@MainActor
final class BrowserStore: ObservableObject {
    let windowID: UUID
    let profile: BrowserProfile
    let preferences: BrowserPreferences

    @Published private(set) var spaces: [BrowserSpace]
    @Published private(set) var groups: [TabGroup]
    @Published private(set) var tabs: [BrowserTab]
    @Published private(set) var history: [BrowserHistoryEntry] = []
    @Published private(set) var bookmarks: [BrowserBookmark] = []
    @Published private(set) var newTabFavorites: [NewTabFavoriteSite] = []
    @Published private(set) var downloads: [BrowserDownloadTask] = []
    @Published private(set) var faviconDataByTabID: [UUID: Data] = [:]
    @Published private(set) var navigationStates: [UUID: NavigationState] = [:]
    @Published private(set) var siteSecurityInfoByTabID: [UUID: SiteSecurityInfo] = [:]
    @Published private(set) var savedSplitCompositions: [SavedSplitComposition] = []
    @Published private(set) var permissions: [WebsitePermission] = []
    @Published private(set) var sitePrivacyPolicies: [SitePrivacyPolicy] = []
    @Published private(set) var pendingPermissionPrompts: [WebsitePermissionPrompt] = []
    @Published private(set) var extensionRuntimeConfigurations: [String: BrowserExtensionRuntimeConfiguration] = [:]
    @Published private(set) var extensionRuntimeConfigurationLoadingIDs = Set<String>()
    @Published private(set) var extensionRuntimeConfigurationErrors: [String: String] = [:]
    @Published var currentSpaceID: UUID
    @Published var selectedTabID: UUID
    @Published var splitSession: SplitViewSession?
    @Published var isSidebarCollapsed: Bool
    @Published var isPrivacyPresented = false
    @Published var isReleaseNotesPresented = false
    @Published var isLibraryPresented = false
    @Published var isSettingsPresented = false
    @Published var settingsSection: BrowserSettingsSection = .general
    @Published var isPermissionCenterPresented = false
    @Published var isExtensionsPresented = false
    @Published private(set) var developerToolsTabID: UUID?
    @Published private(set) var developerToolsInspectX: Int?
    @Published private(set) var developerToolsInspectY: Int?
    @Published private(set) var developerToolsRequestID = 0
    @Published var developerToolsWidth: CGFloat = 500
    @Published private(set) var isDeveloperToolsResizing = false
    @Published var isSiteInfoPresented = false
    @Published var librarySelection: BrowserLibrarySection = .history
    @Published var isFindPresented = false
    @Published private(set) var isRestoringSession: Bool
    @Published var addressText = ""
    @Published var findText = ""
    @Published var searchQuery = ""
    @Published var lastError: String?
    @Published private(set) var addressFocusRequest = 0
    @Published private(set) var findFocusRequest = 0
    @Published private(set) var downloadPanelRequest = 0

    private let engine: any BrowserEngine
    private let persistence: BrowserSQLitePersistence
    private let newTabFavoritesStore: NewTabFavoritesStore
    private let extensionsStore: BrowserExtensionsStore
    private var splitSessionsBySpace: [UUID: SplitViewSession] = [:]
    private var pendingNavigations: [UUID: PendingNavigation] = [:]
    private var deferredNavigationURLs: [UUID: URL] = [:]
    private var httpsUpgradeAttempts: [UUID: HTTPSUpgradeAttempt] = [:]
    private var activeHTTPFallbackURLs: [UUID: URL] = [:]
    private var pageSetupTasks: [UUID: Task<Void, Never>] = [:]
    private var pageSuspensionTasks: [UUID: Task<Void, Never>] = [:]
    private var deferredPageSuspensions: [UUID: (isSuspended: Bool, isFocused: Bool)] = [:]
    private var navigationCommandTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadDirectoryURLsBySpace: [UUID: URL] = [:]
    private var securityScopedDownloadDirectoryURLsBySpace: [UUID: URL] = [:]
    private var activeDownloadTabIDsByDownloadID: [UUID: UUID] = [:]
    private var retryingDownloadIDs = Set<UUID>()
    private var suppressedDownloadIDs = Set<UUID>()
    private var nonRestorableDownloadURLsByTabID: [UUID: URL] = [:]
    private var activeMediaTabIDs = Set<UUID>()
    private var extensionSourceWebTabIDsByPackage: [String: UUID] = [:]
    private var recentlyClosedTabs: [BrowserTab] = []
    private var faviconCacheOrder: [UUID] = []
    private var pendingSave: Task<Void, Never>?
    private var sessionPersistenceTail: Task<Void, Never>?
    private var automaticSleepTask: Task<Void, Never>?
    private var engineEventTask: Task<Void, Never>?
    private var sessionRestorationTask: Task<Void, Never>?
    private var isPreparingApplicationTermination = false
    private var isSitePrivacyPolicyReady = false
    private var didTearDownWindow = false
    private var preferenceCancellables = Set<AnyCancellable>()
    private var observedHTTPSUpgradeEnabled = BrowserPreferences.defaultHTTPSUpgradeEnabled
    private var observedBlockThirdPartyCookies = BrowserPreferences.defaultBlockThirdPartyCookies
    private var observedContentBlockingEnabled = BrowserPreferences.defaultContentBlockingEnabled

    private struct HTTPSUpgradeAttempt {
        let secureURL: URL
        let fallbackURL: URL
    }

    private struct PendingNavigation {
        let requestedURL: URL
        let previousURL: URL?
        let generationBaseline: UInt64?
    }

    init(
        engine: (any BrowserEngine)? = nil,
        databasePersistence: BrowserSQLitePersistence = BrowserSQLitePersistence(),
        windowID: UUID = UUID(),
        profile: BrowserProfile = .standard,
        preferences: BrowserPreferences = .shared,
        newTabFavoritesStore: NewTabFavoritesStore = .shared,
        extensionsStore: BrowserExtensionsStore = .shared
    ) {
        let activeEngine = engine ?? BrowserEngineFactory.makeDefault()
        let work = BrowserSpace(
            id: UUID(), name: "工作", symbolName: "briefcase.fill",
            tintHex: "7C6FF2", privacyLevel: .standard, downloadDirectoryBookmark: nil
        )
        let personal = BrowserSpace(
            id: UUID(), name: "个人", symbolName: "person.fill",
            tintHex: "E46E9B", privacyLevel: .standard, downloadDirectoryBookmark: nil
        )
        let research = BrowserSpace(
            id: UUID(), name: "研究", symbolName: "books.vertical.fill",
            tintHex: "48A9A6", privacyLevel: .strict, downloadDirectoryBookmark: nil
        )
        let sampleTabs = [
            BrowserTab(
                url: URL(string: "https://www.apple.com/macos/"), title: "macOS",
                spaceID: work.id, isPinned: true, isFavorite: true, blockedCount: 12
            ),
            BrowserTab(
                url: URL(string: "https://developer.apple.com/documentation/swiftui"),
                title: "SwiftUI Documentation", spaceID: work.id, isPinned: true, blockedCount: 7
            ),
            BrowserTab(
                url: URL(string: "https://www.chromium.org/developers/"),
                title: "Chromium for Developers", spaceID: work.id, blockedCount: 18
            ),
            BrowserTab(
                url: URL(string: "https://example.com"), title: "Product research notes",
                spaceID: work.id, isPlayingAudio: true, blockedCount: 4
            ),
            BrowserTab(
                url: URL(string: "https://www.apple.com"), title: "Apple",
                spaceID: personal.id, isFavorite: true, blockedCount: 9
            ),
            BrowserTab(
                url: URL(string: "https://www.rfc-editor.org"), title: "RFC Editor",
                spaceID: research.id, isPinned: true, blockedCount: 21
            )
        ]

        let initialSpaces: [BrowserSpace]
        let initialTabs: [BrowserTab]
        if profile.isPrivate {
            let privateSpace = BrowserSpace(
                id: UUID(), name: "隐私窗口", symbolName: "eye.slash.fill",
                tintHex: "5C6370", privacyLevel: .strict, downloadDirectoryBookmark: nil
            )
            let privateTab = BrowserTab(
                url: BrowserStartPage.url,
                title: BrowserStartPage.title,
                spaceID: privateSpace.id
            )
            initialSpaces = [privateSpace]
            initialTabs = [privateTab]
        } else if preferences.restorePreviousSession {
            initialSpaces = [work, personal, research]
            initialTabs = sampleTabs
        } else {
            initialSpaces = [work, personal, research]
            initialTabs = [BrowserTab(
                url: BrowserStartPage.url,
                title: BrowserStartPage.title,
                spaceID: work.id
            )]
        }

        let qaInitialURL = Self.isolatedQAInitialURL()
        let qaDownloadDirectory = Self.isolatedQADownloadDirectory()
        var configuredInitialTabs: [BrowserTab]
        if let qaInitialURL, !profile.isPrivate {
            configuredInitialTabs = [BrowserTab(
                url: qaInitialURL,
                title: "Rex QA",
                spaceID: initialSpaces[0].id
            )]
        } else {
            configuredInitialTabs = initialTabs
        }
        for index in configuredInitialTabs.indices {
            configuredInitialTabs[index] = Self.userVisibleTab(configuredInitialTabs[index])
            configuredInitialTabs[index].isLoading = false
            configuredInitialTabs[index].loadingProgress = 1
            configuredInitialTabs[index].privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
        }

        self.windowID = windowID
        self.profile = profile
        self.preferences = preferences
        self.isSidebarCollapsed = preferences.defaultSidebarCollapsed
        self.isRestoringSession = !profile.isPrivate && preferences.restorePreviousSession
        self.spaces = initialSpaces
        self.groups = []
        self.tabs = configuredInitialTabs
        self.currentSpaceID = initialSpaces[0].id
        self.selectedTabID = configuredInitialTabs[0].id
        let initialURL = configuredInitialTabs[0].url
        self.addressText = BrowserStartPage.matches(initialURL)
            ? ""
            : (initialURL?.absoluteString ?? "")
        self.engine = activeEngine
        self.persistence = databasePersistence
        self.newTabFavoritesStore = newTabFavoritesStore
        self.extensionsStore = extensionsStore
        self.observedHTTPSUpgradeEnabled = preferences.httpsUpgradeEnabled
        self.observedBlockThirdPartyCookies = preferences.blockThirdPartyCookies
        self.newTabFavorites = profile.isPrivate ? [] : newTabFavoritesStore.favorites
        self.isSitePrivacyPolicyReady = profile.isPrivate
        if let qaDownloadDirectory, !profile.isPrivate {
            for space in initialSpaces {
                downloadDirectoryURLsBySpace[space.id] = qaDownloadDirectory
            }
        }

        createEnginePages(for: configuredInitialTabs.map(\.id))
        let shouldPerformInitialRuntimeSync =
            !profile.isPrivate && extensionsStore.claimInitialRuntimeSync()
        engineEventTask = Task { @MainActor [weak self, activeEngine, extensionsStore] in
            let events = await activeEngine.eventStream()
            if shouldPerformInitialRuntimeSync {
                let succeeded = await self?.reloadExtensionRules() ?? false
                extensionsStore.finishInitialRuntimeSync(succeeded: succeeded)
            }
            for await event in events { self?.apply(event) }
        }
        if !profile.isPrivate {
            sessionRestorationTask = Task { @MainActor [weak self, databasePersistence, profile] in
                do {
                    if preferences.restorePreviousSession,
                       let snapshot = try await databasePersistence.load(windowID: windowID) {
                        guard !Task.isCancelled else { return }
                        let visibleSnapshot = Self.userVisibleSnapshot(snapshot)
                        self?.restore(visibleSnapshot)
                        if visibleSnapshot != snapshot {
                            try await databasePersistence.save(visibleSnapshot)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    let storedPrivacyPolicies = try await databasePersistence
                        .sitePrivacyPolicies(profileID: profile.id)
                    guard !Task.isCancelled else { return }
                    let normalizedPrivacyPolicies = Self.normalizedSitePrivacyPolicies(
                        storedPrivacyPolicies,
                        profileID: profile.id
                    )
                    if normalizedPrivacyPolicies != storedPrivacyPolicies {
                        try await databasePersistence.replaceSitePrivacyPolicies(
                            profileID: profile.id,
                            with: normalizedPrivacyPolicies
                        )
                    }
                    if let self {
                        self.mergeLoadedSitePrivacyPolicies(normalizedPrivacyPolicies)
                        self.finishSitePrivacyPolicyLoading()
                    }
                    self?.finishSessionRestoration()
                    let storedHistory = try await databasePersistence.history()
                    guard !Task.isCancelled else { return }
                    let persistedHistory = storedHistory.compactMap(Self.userVisibleHistoryEntry)
                    for storedEntry in storedHistory {
                        guard let visibleEntry = Self.userVisibleHistoryEntry(storedEntry) else {
                            try? await databasePersistence.removeHistory(id: storedEntry.id)
                            continue
                        }
                        if visibleEntry != storedEntry {
                            try? await databasePersistence.addHistory(visibleEntry)
                        }
                    }
                    if let self {
                        let liveHistoryIDs = Set(self.history.map(\.id))
                        self.history.append(contentsOf: persistedHistory.filter {
                            !liveHistoryIDs.contains($0.id)
                        })
                        self.history.sort { $0.visitedAt > $1.visitedAt }
                    }
                    let storedBookmarks = try await databasePersistence.bookmarks()
                    guard !Task.isCancelled else { return }
                    let persistedBookmarks = storedBookmarks.compactMap(Self.userVisibleBookmark)
                    for storedBookmark in storedBookmarks {
                        guard let visibleBookmark = Self.userVisibleBookmark(storedBookmark) else {
                            try? await databasePersistence.removeBookmark(id: storedBookmark.id)
                            continue
                        }
                        if visibleBookmark != storedBookmark {
                            try? await databasePersistence.saveBookmark(visibleBookmark)
                        }
                    }
                    if let self {
                        let liveBookmarkURLs = Set(self.bookmarks.map(\.url))
                        self.bookmarks.append(contentsOf: persistedBookmarks.filter {
                            !liveBookmarkURLs.contains($0.url)
                        })
                        self.bookmarks.sort { $0.updatedAt > $1.updatedAt }
                    }
                    let storedDownloads = try await databasePersistence.downloads()
                    guard !Task.isCancelled else { return }
                    let persistedDownloads = storedDownloads.compactMap { storedDownload in
                        Self.userVisibleDownload(storedDownload).map(Self.restoredDownloadSnapshot)
                    }
                    for storedDownload in storedDownloads {
                        guard let visibleDownload = Self.userVisibleDownload(storedDownload) else {
                            try? await databasePersistence.removeDownload(id: storedDownload.id)
                            continue
                        }
                        if visibleDownload != storedDownload {
                            try? await databasePersistence.saveDownload(visibleDownload)
                        }
                    }
                    if let self {
                        let liveDownloadIDs = Set(self.downloads.map(\.id))
                        self.downloads.append(contentsOf: persistedDownloads.filter {
                            !liveDownloadIDs.contains($0.id)
                                && !self.suppressedDownloadIDs.contains($0.id)
                        })
                        self.downloads.sort { $0.createdAt > $1.createdAt }
                    }
                    let storedPermissions = try await databasePersistence.permissions(profileID: profile.id)
                    guard !Task.isCancelled else { return }
                    let persistedPermissions = storedPermissions.map(Self.userVisiblePermission)
                    for (storedPermission, visiblePermission) in zip(
                        storedPermissions,
                        persistedPermissions
                    ) where storedPermission != visiblePermission {
                        do {
                            try await databasePersistence.removePermission(id: storedPermission.id)
                            do {
                                try await databasePersistence.savePermission(visiblePermission)
                            } catch {
                                try? await databasePersistence.savePermission(storedPermission)
                            }
                        } catch {
                            continue
                        }
                    }
                    let durablePermissions = persistedPermissions.filter(\.decision.isPersistent)
                    for permission in persistedPermissions where !permission.decision.isPersistent {
                        try? await databasePersistence.removePermission(id: permission.id)
                    }
                    if let self {
                        let livePermissionScopes = Set(self.permissions.map(Self.permissionScope))
                        self.permissions.append(contentsOf: durablePermissions.filter {
                            !livePermissionScopes.contains(Self.permissionScope($0))
                        })
                        self.permissions.sort { $0.updatedAt > $1.updatedAt }
                    }
                    self?.synchronizeBookmarkFlags()
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.finishSitePrivacyPolicyLoading()
                    self?.finishSessionRestoration()
                    self?.lastError = "会话恢复失败：\(error.localizedDescription)"
                }
            }
        }
        preferences.$automaticTabSleeping
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.automaticTabSleepingDidChange(enabled)
            }
            .store(in: &preferenceCancellables)
        if !profile.isPrivate {
            newTabFavoritesStore.$favorites
                .removeDuplicates()
                .sink { [weak self] favorites in
                    self?.newTabFavorites = favorites
                }
                .store(in: &preferenceCancellables)
        }
        preferences.$httpsUpgradeEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, self.observedHTTPSUpgradeEnabled != enabled else { return }
                self.observedHTTPSUpgradeEnabled = enabled
                self.applyHTTPSUpgradePreference(enabled)
            }
            .store(in: &preferenceCancellables)
        preferences.$blockThirdPartyCookies
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, self.observedBlockThirdPartyCookies != enabled else { return }
                self.observedBlockThirdPartyCookies = enabled
                self.pushPrivacyPolicies(
                    for: self.tabs.map(\.id),
                    blockThirdPartyCookies: enabled
                )
            }
            .store(in: &preferenceCancellables)
        observedContentBlockingEnabled = preferences.contentBlockingEnabled
        preferences.$contentBlockingEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, self.observedContentBlockingEnabled != enabled else { return }
                self.observedContentBlockingEnabled = enabled
                let engine = self.engine
                Task { try? await engine.execute(.setContentBlocking(enabled: enabled)) }
            }
            .store(in: &preferenceCancellables)
        updateTabLifecycles()
    }

    static func isolatedQAInitialURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard RexQAEnvironment.isolatedHome(environment: environment) != nil,
              let rawURL = environment["REX_QA_INITIAL_URL"] else { return nil }
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "http",
              url.user == nil,
              url.password == nil,
              url.host == "127.0.0.1" || url.host == "localhost" else {
            return nil
        }
        return url
    }

    static func isolatedQADownloadDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard isolatedQAInitialURL(environment: environment) != nil,
              let home = RexQAEnvironment.isolatedHome(environment: environment),
              let rawPath = environment["REX_QA_DOWNLOAD_DIRECTORY"] else {
            return nil
        }
        let directory = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard directory.path == defaultDownloadDirectory(homeDirectory: home).path else {
            return nil
        }
        return directory
    }

    static func defaultDownloadDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appending(path: "Downloads", directoryHint: .isDirectory)
            .appending(path: "Rex", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    convenience init(engine: (any BrowserEngine)? = nil, persistence: BrowserSessionPersistence) {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "rex-store-tests-\(UUID().uuidString)/Browser.sqlite")
        self.init(
            engine: engine,
            databasePersistence: BrowserSQLitePersistence(
                databaseURL: databaseURL,
                legacyPersistence: persistence
            )
        )
    }

    isolated deinit {
        tearDownWindowResources()
    }

    func closeWindow(removingPersistedSession: Bool = false) {
        guard !didTearDownWindow else { return }
        if removingPersistedSession {
            pendingSave?.cancel()
            let pendingSave = pendingSave
            let persistenceTail = sessionPersistenceTail
            let restorationTask = sessionRestorationTask
            let persistence = persistence
            let windowID = windowID
            tearDownWindowResources()
            Task {
                await pendingSave?.value
                await restorationTask?.value
                await persistenceTail?.value
                try? await persistence.deleteWindow(windowID: windowID)
            }
            return
        }

        flushSession()
        tearDownWindowResources()
    }

    private func tearDownWindowResources() {
        guard !didTearDownWindow else { return }
        didTearDownWindow = true

        let tabIDs = tabs.map(\.id)
        let pageTasks = Array(pageSetupTasks.values)
            + Array(pageSuspensionTasks.values)
            + Array(navigationCommandTasks.values)

        pendingSave?.cancel()
        pendingSave = nil
        automaticSleepTask?.cancel()
        automaticSleepTask = nil
        engineEventTask?.cancel()
        engineEventTask = nil
        sessionRestorationTask?.cancel()
        sessionRestorationTask = nil
        for task in pageTasks { task.cancel() }
        pageSetupTasks.removeAll()
        pageSuspensionTasks.removeAll()
        deferredPageSuspensions.removeAll()
        deferredNavigationURLs.removeAll()
        navigationCommandTasks.removeAll()
        preferenceCancellables.removeAll()
        for url in securityScopedDownloadDirectoryURLsBySpace.values {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedDownloadDirectoryURLsBySpace.removeAll()

        Task { [engine] in
            for task in pageTasks {
                await task.value
            }
            for tabID in tabIDs {
                try? await engine.execute(.destroyPage(tabID: tabID))
            }
        }
    }

    var currentSpace: BrowserSpace? {
        spaces.first { $0.id == currentSpaceID }
    }

    var currentDownloadDirectoryURL: URL? {
        downloadDirectoryURL(for: currentSpaceID)
    }

    var currentDownloadDirectoryName: String {
        currentDownloadDirectoryURL?.lastPathComponent ?? "Rex"
    }

    var usesDefaultDownloadDirectory: Bool {
        currentDownloadDirectoryURL?.standardizedFileURL ==
            Self.defaultDownloadDirectory().standardizedFileURL
    }

    var visibleTabs: [BrowserTab] {
        let candidates = tabs.filter { $0.spaceID == currentSpaceID && !$0.isArchived }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var archivedTabs: [BrowserTab] {
        tabs.filter { $0.spaceID == currentSpaceID && $0.isArchived }
    }

    var currentGroups: [TabGroup] {
        groups.filter { $0.spaceID == currentSpaceID }
    }

    var currentTab: BrowserTab? {
        tab(withID: selectedTabID)
    }

    /// Loading is Chromium-owned. BrowserTab keeps a persistence-compatible
    /// mirror, but commands and UI must read the live engine state.
    var isCurrentPageLoading: Bool {
        navigationStates[selectedTabID]?.isLoading == true
    }

    var currentSiteSecurityInfo: SiteSecurityInfo? {
        if let url = currentTab?.url,
           RexExtensionResourceURL(rexURL: url) != nil || RexExtensionsPage.matches(url) {
            return SiteSecurityInfo(
                url: url,
                navigationGeneration: 0,
                isPending: false,
                isSecureConnection: false,
                hasCertificateError: false,
                certificateErrorCode: nil,
                certificateStatus: [],
                tlsVersion: .unknown,
                contentStatus: [],
                certificate: nil
            )
        }
        guard let info = siteSecurityInfoByTabID[selectedTabID],
              let infoURL = info.url,
              let tabURL = currentTab?.url else { return nil }
        return Self.navigationURLsMatch(infoURL, tabURL) ? info : nil
    }

    var primaryTab: BrowserTab? {
        guard let splitSession else { return currentTab }
        return tab(withID: splitSession.primaryTabID)
    }

    var secondaryTab: BrowserTab? {
        guard let splitSession else { return nil }
        return tab(withID: splitSession.secondaryTabID)
    }

    var isCurrentPageBookmarked: Bool {
        guard let url = currentTab?.url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    var currentSpaceSplitCompositions: [SavedSplitComposition] {
        savedSplitCompositions
            .filter { $0.spaceID == currentSpaceID }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    var canRestoreClosedTab: Bool {
        !recentlyClosedTabs.isEmpty
    }

    func tab(withID id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    func faviconData(for tabID: UUID) -> Data? {
        faviconDataByTabID[tabID]
    }

    func switchSpace(to spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }), spaceID != currentSpaceID else { return }
        rememberCurrentSplit()
        deactivateCurrentSplit()
        currentSpaceID = spaceID
        searchQuery = ""
        if var session = splitSessionsBySpace[spaceID], isValidSplit(session) {
            session.orientation = .horizontal
            splitSession = session
            let focusedID = tabID(for: session.focusedPane, in: session)
            selectedTabID = focusedID
            addressText = addressBarText(for: tab(withID: focusedID)?.url)
            markSplitTabs(session)
            updateSplitPagePriorities(session)
        } else if let first = visibleTabs.first {
            splitSessionsBySpace.removeValue(forKey: spaceID)
            splitSession = nil
            selectTab(first.id)
        } else {
            splitSession = nil
            newTab()
        }
        updateTabLifecycles()
        scheduleSave()
    }

    func switchSpace(at position: Int) {
        guard position > 0, spaces.indices.contains(position - 1) else { return }
        switchSpace(to: spaces[position - 1].id)
    }

    func selectTab(_ tabID: UUID) {
        guard let tab = tab(withID: tabID), tab.spaceID == currentSpaceID, !tab.isArchived else { return }
        selectedTabID = tabID
        addressText = addressBarText(for: tab.url)
        if tab.isSleeping {
            setTabSleeping(tabID, sleeping: false)
        }
        if let session = splitSession {
            if tabID == session.primaryTabID {
                focus(.primary)
                return
            } else if tabID == session.secondaryTabID {
                focus(.secondary)
                return
            } else {
                endSplit(keeping: tabID)
            }
        }
        mutateTab(tabID) {
            $0.lastAccessedAt = .now
        }
        Task { [engine] in try? await engine.execute(.setPagePriority(tabID: tabID, isFocused: true)) }
        updateTabLifecycles()
        scheduleSave()
    }

    func newTab() {
        clearSplit(in: currentSpaceID)
        var tab = BrowserTab(
            url: BrowserStartPage.url,
            title: BrowserStartPage.title,
            spaceID: currentSpaceID
        )
        if let spaceLevel = currentSpace?.privacyLevel {
            tab.privacyState.level = spaceLevel
            if spaceLevel == .strict || spaceLevel == .custom {
                tab.privacyState.fingerprintProtectionEnabled = true
            }
        }
        tab.privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
        tabs.append(tab)
        selectedTabID = tab.id
        addressText = ""
        createEnginePages(for: [tab.id])
        updateTabLifecycles()
        scheduleSave()
    }

    func openExtensionsPage(_ requestedURL: URL = RexExtensionsPage.url) {
        guard !profile.isPrivate else {
            lastError = "隐私窗口不打开扩展设置。"
            return
        }
        guard let pageURL = RexExtensionsPage.canonicalURL(from: requestedURL) else {
            lastError = "扩展程序页面地址无效。"
            return
        }
        isExtensionsPresented = false
        searchQuery = ""
        if let existing = tabs.first(where: {
            $0.spaceID == currentSpaceID
                && !$0.isArchived
                && RexExtensionsPage.matches($0.url)
        }) {
            selectTab(existing.id)
            guard existing.url != pageURL else { return }
            pendingNavigations.removeValue(forKey: existing.id)
            deferredNavigationURLs.removeValue(forKey: existing.id)
            addressText = pageURL.absoluteString
            mutateTab(existing.id) {
                $0.url = pageURL
                $0.title = RexExtensionsPage.title
                $0.isLoading = false
                $0.loadingProgress = 1
            }
            navigationStates[existing.id] = NavigationState(
                url: pageURL,
                title: RexExtensionsPage.title,
                isLoading: false,
                loadingProgress: 1
            )
            scheduleSave()
            return
        }

        clearSplit(in: currentSpaceID)
        var tab = BrowserTab(
            url: pageURL,
            title: RexExtensionsPage.title,
            spaceID: currentSpaceID
        )
        if let spaceLevel = currentSpace?.privacyLevel {
            tab.privacyState.level = spaceLevel
        }
        tab.privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
        tabs.append(tab)
        selectedTabID = tab.id
        addressText = pageURL.absoluteString
        navigationStates[tab.id] = NavigationState(
            url: pageURL,
            title: RexExtensionsPage.title,
            isLoading: false,
            loadingProgress: 1
        )
        createEnginePages(for: [tab.id])
        updateTabLifecycles()
        scheduleSave()
    }

    func openExtensionPage(_ url: URL, title: String) {
        guard !profile.isPrivate else {
            lastError = "隐私窗口不运行或打开扩展页面。"
            return
        }
        guard let resource = RexExtensionResourceURL(rexURL: url),
              let package = extensionsStore.runnablePackage(
                  runtimeID: resource.runtimeID
              ) else {
            lastError = "这个扩展未安装、未启用或尚未在本次启动中加载。"
            return
        }
        if let managementTabID = currentTab?.id,
           RexExtensionsPage.detailRuntimeID(from: currentTab?.url) != nil {
            resetExtensionsDetailRoute(for: managementTabID)
        }
        if let sourceTabID = currentTab.flatMap({ tab -> UUID? in
            guard let scheme = tab.url?.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                return nil
            }
            return tab.id
        }) {
            extensionSourceWebTabIDsByPackage[package.id] = sourceTabID
        }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? package.name
            : title
        if let currentURL = currentTab?.url,
           let currentResource = RexExtensionResourceURL(rexURL: currentURL),
           currentResource.runtimeID == resource.runtimeID {
            navigateExtensionTab(selectedTabID, to: resource.rexURL, title: resolvedTitle)
            return
        }
        if let existing = visibleTabs.first(where: { tab in
            guard let existingURL = tab.url,
                  let existingResource = RexExtensionResourceURL(rexURL: existingURL) else {
                return false
            }
            return existingResource.runtimeID == resource.runtimeID
        }) {
            selectTab(existing.id)
            navigateExtensionTab(existing.id, to: resource.rexURL, title: resolvedTitle)
            return
        }

        clearSplit(in: currentSpaceID)
        var tab = BrowserTab(
            url: resource.rexURL,
            title: resolvedTitle,
            spaceID: currentSpaceID
        )
        if let spaceLevel = currentSpace?.privacyLevel {
            tab.privacyState.level = spaceLevel
        }
        tab.privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
        tabs.append(tab)
        selectedTabID = tab.id
        addressText = resource.rexURL.absoluteString
        createEnginePages(for: [tab.id])
        updateTabLifecycles()
        scheduleSave()
    }

    func isRunnableExtension(runtimeID: String) -> Bool {
        !profile.isPrivate
            && extensionsStore.runnablePackage(runtimeID: runtimeID) != nil
    }

    private func navigateExtensionTab(_ tabID: UUID, to url: URL, title: String) {
        beginPendingNavigation(to: url, from: tab(withID: tabID)?.url, for: tabID)
        httpsUpgradeAttempts.removeValue(forKey: tabID)
        activeHTTPFallbackURLs.removeValue(forKey: tabID)
        siteSecurityInfoByTabID.removeValue(forKey: tabID)
        addressText = url.absoluteString
        mutateTab(tabID) { tab in
            tab.url = url
            tab.title = title
        }
        enqueueNavigation(to: url, for: tabID)
        scheduleSave()
    }

    func sourceWebTab(forExtensionPackageID packageID: String) -> BrowserTab? {
        guard !profile.isPrivate else { return nil }
        if let currentTab,
           currentTab.spaceID == currentSpaceID,
           !currentTab.isArchived,
           let scheme = currentTab.url?.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return currentTab
        }
        if let tabID = extensionSourceWebTabIDsByPackage[packageID],
           let tab = tab(withID: tabID),
           tab.spaceID == currentSpaceID,
           !tab.isArchived,
           let scheme = tab.url?.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return tab
        }
        return tabs
            .filter { tab in
                guard tab.spaceID == currentSpaceID,
                      !tab.isArchived,
                      let scheme = tab.url?.scheme?.lowercased() else {
                    return false
                }
                return ["http", "https"].contains(scheme)
            }
            .max { $0.lastAccessedAt < $1.lastAccessedAt }
    }

    @discardableResult
    func reloadExtensionRules() async -> Bool {
        guard !profile.isPrivate else { return true }
        return await extensionsStore.performSerializedRuntimeMutation {
            await self.reloadExtensionRulesWithoutSerialization()
        }
    }

    private func reloadExtensionRulesWithoutSerialization(
        managedPaths requestedManagedPaths: [String]? = nil,
        enabledPaths requestedEnabledPaths: [String]? = nil,
        removedPaths: [String] = []
    ) async -> Bool {
        let managedPaths = requestedManagedPaths ?? extensionsStore.managedRuntimeExtensionPaths
        let enabledPaths = requestedEnabledPaths ?? extensionsStore.nativeRuleExtensionPaths
        let forceReloadPaths = requestedManagedPaths == nil && requestedEnabledPaths == nil
            ? extensionsStore.forcedRuntimeReloadPaths
            : []
        let replacementTokens = extensionsStore.pendingRuntimeReplacementTokens
        do {
            try await engine.execute(.reloadExtensionRules(
                managedPaths: managedPaths,
                enabledPaths: enabledPaths,
                removedPaths: removedPaths,
                forceReloadPaths: forceReloadPaths
            ))
            extensionsStore.acknowledgeRuntimePaths(enabledPaths)
            extensionsStore.acknowledgeForcedRuntimeReloadPaths(forceReloadPaths)
            let cleanupFailures = extensionsStore.commitPendingRuntimeReplacements(
                tokens: replacementTokens
            )
            if !cleanupFailures.isEmpty {
                extensionsStore.recordRuntimeSyncFailure(
                    BrowserExtensionRuntimeSyncError(
                        message: "新版本已接入，但无法清理旧版本备份：\(cleanupFailures.joined(separator: "；"))"
                    ),
                    loadedPaths: enabledPaths
                )
            }
            return true
        } catch {
            let runtimeError = error as NSError
            extensionsStore.recordRuntimeSyncFailure(
                error,
                loadedPaths: runtimeError.userInfo["loadedPaths"] as? [String]
            )
            guard !replacementTokens.isEmpty else {
                return false
            }

            let originalMessage = error.localizedDescription
            do {
                try extensionsStore.rollbackPendingRuntimeReplacements(
                    tokens: replacementTokens
                )
            } catch {
                extensionsStore.recordRuntimeSyncFailure(
                    BrowserExtensionRuntimeSyncError(
                        message: "\(originalMessage)；旧版本自动恢复失败：\(error.localizedDescription)"
                    )
                )
                return false
            }

            let rollbackManagedPaths = extensionsStore.managedRuntimeExtensionPaths
            let rollbackEnabledPaths = extensionsStore.nativeRuleExtensionPaths
            do {
                try await engine.execute(.reloadExtensionRules(
                    managedPaths: rollbackManagedPaths,
                    enabledPaths: rollbackEnabledPaths,
                    removedPaths: [],
                    forceReloadPaths: []
                ))
                extensionsStore.acknowledgeRuntimePaths(rollbackEnabledPaths)
                extensionsStore.recordRuntimeSyncFailure(
                    BrowserExtensionRuntimeSyncError(
                        message: "\(originalMessage)；已恢复并重新接入上一版本。"
                    ),
                    loadedPaths: rollbackEnabledPaths
                )
            } catch {
                let rollbackError = error as NSError
                extensionsStore.recordRuntimeSyncFailure(
                    BrowserExtensionRuntimeSyncError(
                        message: "\(originalMessage)；旧版本文件已恢复，但 Chromium 重新接入失败：\(error.localizedDescription)"
                    ),
                    loadedPaths: rollbackError.userInfo["loadedPaths"] as? [String]
                )
            }
            return false
        }
    }

    @discardableResult
    func setExtensionEnabled(_ enabled: Bool, id: String) async -> Bool {
        guard !profile.isPrivate else { return false }
        return await extensionsStore.performSerializedRuntimeMutation {
            await self.setExtensionEnabledWithoutSerialization(enabled, id: id)
        }
    }

    func extensionRuntimeConfiguration(
        for package: BrowserExtensionPackage
    ) -> BrowserExtensionRuntimeConfiguration? {
        guard let runtimeID = package.runtimeID else { return nil }
        return extensionRuntimeConfigurations[runtimeID]
    }

    func extensionRuntimeConfigurationError(
        for package: BrowserExtensionPackage
    ) -> String? {
        guard let runtimeID = package.runtimeID else { return nil }
        return extensionRuntimeConfigurationErrors[runtimeID]
    }

    func isLoadingExtensionRuntimeConfiguration(
        for package: BrowserExtensionPackage
    ) -> Bool {
        package.runtimeID.map(extensionRuntimeConfigurationLoadingIDs.contains) == true
    }

    @discardableResult
    func refreshExtensionRuntimeConfiguration(
        for package: BrowserExtensionPackage
    ) async -> Bool {
        guard !profile.isPrivate,
              package.removalRequestedAt == nil,
              let runtimeID = package.runtimeID,
              RexExtensionResourceURL.isValidRuntimeID(runtimeID) else {
            return false
        }
        guard !extensionRuntimeConfigurationLoadingIDs.contains(runtimeID) else {
            return false
        }

        extensionRuntimeConfigurationLoadingIDs.insert(runtimeID)
        extensionRuntimeConfigurationErrors.removeValue(forKey: runtimeID)
        defer { extensionRuntimeConfigurationLoadingIDs.remove(runtimeID) }

        do {
            let configuration = try await extensionsStore.performSerializedRuntimeMutation {
                try await self.engine.extensionRuntimeConfiguration(extensionID: runtimeID)
            }
            guard configuration.extensionID == runtimeID,
                  extensionsStore.extensions.contains(where: {
                      $0.id == package.id && $0.runtimeID == runtimeID
                  }) else {
                return false
            }
            extensionRuntimeConfigurations[runtimeID] = configuration
            return true
        } catch {
            extensionRuntimeConfigurationErrors[runtimeID] = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateExtensionRuntimeConfiguration(
        for package: BrowserExtensionPackage,
        update: BrowserExtensionRuntimeConfigurationUpdate
    ) async -> Bool {
        guard !profile.isPrivate,
              !update.isEmpty,
              package.removalRequestedAt == nil,
              let runtimeID = package.runtimeID,
              RexExtensionResourceURL.isValidRuntimeID(runtimeID) else {
            return false
        }
        guard !extensionRuntimeConfigurationLoadingIDs.contains(runtimeID) else {
            return false
        }

        extensionRuntimeConfigurationLoadingIDs.insert(runtimeID)
        extensionRuntimeConfigurationErrors.removeValue(forKey: runtimeID)
        defer { extensionRuntimeConfigurationLoadingIDs.remove(runtimeID) }

        do {
            let configuration = try await extensionsStore.performSerializedRuntimeMutation {
                try await self.engine.updateExtensionRuntimeConfiguration(
                    extensionID: runtimeID,
                    update: update
                )
            }
            guard configuration.extensionID == runtimeID,
                  extensionsStore.extensions.contains(where: {
                      $0.id == package.id && $0.runtimeID == runtimeID
                  }) else {
                return false
            }
            extensionRuntimeConfigurations[runtimeID] = configuration
            extensionsStore.announceRuntimeConfigurationChange(for: runtimeID)
            return true
        } catch {
            let updateError = error.localizedDescription
            if let configuration = try? await extensionsStore.performSerializedRuntimeMutation({
                try await self.engine.extensionRuntimeConfiguration(extensionID: runtimeID)
            }),
               configuration.extensionID == runtimeID,
               extensionsStore.extensions.contains(where: {
                   $0.id == package.id && $0.runtimeID == runtimeID
               }) {
                extensionRuntimeConfigurations[runtimeID] = configuration
                extensionsStore.announceRuntimeConfigurationChange(for: runtimeID)
            }
            extensionRuntimeConfigurationErrors[runtimeID] = updateError
            return false
        }
    }

    private func setExtensionEnabledWithoutSerialization(
        _ enabled: Bool,
        id: String
    ) async -> Bool {
        guard let package = extensionsStore.extensions.first(where: { $0.id == id }) else {
            return false
        }
        guard package.isEnabled != enabled else {
            return await reloadExtensionRulesWithoutSerialization()
        }
        guard extensionsStore.setEnabled(enabled, for: id) else { return false }
        if await reloadExtensionRulesWithoutSerialization() {
            if let runtimeID = package.runtimeID {
                extensionsStore.announceRuntimeConfigurationChange(for: runtimeID)
            }
            return true
        }

        let runtimeError = extensionsStore.lastError
        _ = extensionsStore.setEnabled(package.isEnabled, for: id)
        _ = await reloadExtensionRulesWithoutSerialization()
        if let runtimeError {
            extensionsStore.recordRuntimeSyncFailure(
                BrowserExtensionRuntimeSyncError(message: runtimeError),
                loadedPaths: extensionsStore.nativeRuleExtensionPaths
            )
        }
        return false
    }

    @discardableResult
    func removeExtension(_ id: String) async -> Bool {
        guard !profile.isPrivate else { return false }
        return await extensionsStore.performSerializedRuntimeMutation {
            await self.removeExtensionWithoutSerialization(id)
        }
    }

    private func removeExtensionWithoutSerialization(_ id: String) async -> Bool {
        guard let package = extensionsStore.extensions.first(where: { $0.id == id }) else {
            return false
        }
        let packagePath = package.path
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let remainingManagedPaths = extensionsStore.managedRuntimeExtensionPaths.filter { path in
            URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path != packagePath
        }
        let remainingEnabledPaths = extensionsStore.nativeRuleExtensionPaths.filter { path in
            URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path != packagePath
        }
        guard await reloadExtensionRulesWithoutSerialization(
            managedPaths: remainingManagedPaths,
            enabledPaths: remainingEnabledPaths,
            removedPaths: [packagePath]
        ) else {
            return false
        }
        guard extensionsStore.remove(id) else {
            _ = await reloadExtensionRulesWithoutSerialization()
            return false
        }
        extensionsStore.acknowledgeRuntimePaths(remainingEnabledPaths)
        return true
    }

    @discardableResult
    func installExtensionFromCatalog(
        _ item: BrowserExtensionCatalogItem
    ) async throws -> BrowserExtensionPackage {
        guard !profile.isPrivate else {
            throw BrowserExtensionRuntimeSyncError(
                message: "隐私窗口不安装或更新扩展。"
            )
        }
        return try await extensionsStore.performSerializedRuntimeMutation {
            let package = try await self.extensionsStore.installFromCatalog(item)
            guard await self.reloadExtensionRulesWithoutSerialization() else {
                throw BrowserExtensionRuntimeSyncError(
                    message: self.extensionsStore.lastError
                        ?? "扩展已导入，但无法接入 Chromium。"
                )
            }
            return package
        }
    }

    @discardableResult
    func installExtensionFromWebStore(
        extensionID: String,
        displayName: String? = nil
    ) async throws -> BrowserExtensionPackage {
        guard !profile.isPrivate else {
            throw BrowserExtensionRuntimeSyncError(
                message: "隐私窗口不安装或更新扩展。"
            )
        }
        return try await extensionsStore.performSerializedRuntimeMutation {
            let package = try await self.extensionsStore.installFromWebStore(
                extensionID: extensionID,
                displayName: displayName
            )
            guard await self.reloadExtensionRulesWithoutSerialization() else {
                throw BrowserExtensionRuntimeSyncError(
                    message: self.extensionsStore.lastError
                        ?? "扩展已导入，但无法接入 Chromium。"
                )
            }
            return package
        }
    }

    @discardableResult
    func installUnpackedExtension(
        from url: URL
    ) async throws -> BrowserExtensionPackage {
        guard !profile.isPrivate else {
            throw BrowserExtensionRuntimeSyncError(
                message: "隐私窗口不安装或更新扩展。"
            )
        }
        return try await extensionsStore.performSerializedRuntimeMutation {
            let package = try self.extensionsStore.installUnpacked(from: url)
            guard await self.reloadExtensionRulesWithoutSerialization() else {
                throw BrowserExtensionRuntimeSyncError(
                    message: self.extensionsStore.lastError
                        ?? "扩展已导入，但无法接入 Chromium。"
                )
            }
            return package
        }
    }

    func focusAddress() {
        addressFocusRequest &+= 1
    }

    func closeCurrentTab() {
        closeTab(selectedTabID)
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if developerToolsTabID == tabID {
            closeDeveloperTools()
        }
        recentlyClosedTabs.append(tabs[index])
        if recentlyClosedTabs.count > 20 {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - 20)
        }
        let closingPrompts = pendingPermissionPrompts.filter { $0.tabID == tabID }
        for prompt in closingPrompts { respond(to: prompt, with: .ask) }
        permissions.removeAll { $0.tabID == tabID && $0.decision == .revokeOnTabClose }
        detachTabFromSplit(tabID)
        savedSplitCompositions.removeAll {
            $0.primaryTabID == tabID || $0.secondaryTabID == tabID
        }
        tabs.remove(at: index)
        for groupIndex in groups.indices {
            groups[groupIndex].tabIDs.removeAll { $0 == tabID }
        }
        if selectedTabID == tabID {
            if let next = visibleTabs.first {
                selectedTabID = next.id
                addressText = addressBarText(for: next.url)
            } else {
                newTab()
            }
        }
        pendingNavigations.removeValue(forKey: tabID)
        deferredNavigationURLs.removeValue(forKey: tabID)
        httpsUpgradeAttempts.removeValue(forKey: tabID)
        activeHTTPFallbackURLs.removeValue(forKey: tabID)
        pageSetupTasks.removeValue(forKey: tabID)?.cancel()
        pageSuspensionTasks.removeValue(forKey: tabID)?.cancel()
        deferredPageSuspensions.removeValue(forKey: tabID)
        navigationCommandTasks.removeValue(forKey: tabID)?.cancel()
        activeDownloadTabIDsByDownloadID = activeDownloadTabIDsByDownloadID.filter { $0.value != tabID }
        nonRestorableDownloadURLsByTabID.removeValue(forKey: tabID)
        activeMediaTabIDs.remove(tabID)
        siteSecurityInfoByTabID.removeValue(forKey: tabID)
        faviconDataByTabID.removeValue(forKey: tabID)
        faviconCacheOrder.removeAll { $0 == tabID }
        Task { [engine] in try? await engine.execute(.destroyPage(tabID: tabID)) }
        updateTabLifecycles()
        scheduleSave()
    }

    func closeOtherTabs(except tabID: UUID) {
        let tabIDs = tabs.filter {
            $0.spaceID == currentSpaceID && !$0.isArchived && $0.id != tabID
        }.map(\.id)
        for candidateID in tabIDs {
            closeTab(candidateID)
        }
        if tab(withID: tabID) != nil {
            selectTab(tabID)
        }
    }

    func closeTabsToRight(of tabID: UUID) {
        let currentTabs = tabs.filter { $0.spaceID == currentSpaceID && !$0.isArchived }
        guard let index = currentTabs.firstIndex(where: { $0.id == tabID }),
              currentTabs.indices.contains(index + 1) else { return }
        for candidate in currentTabs[(index + 1)...].reversed() {
            closeTab(candidate.id)
        }
        if tab(withID: tabID) != nil {
            selectTab(tabID)
        }
    }

    func restoreClosedTab() {
        guard let closedTab = recentlyClosedTabs.popLast() else { return }
        let destinationSpaceID = spaces.contains { $0.id == closedTab.spaceID }
            ? closedTab.spaceID
            : currentSpaceID
        if destinationSpaceID != currentSpaceID {
            switchSpace(to: destinationSpaceID)
        }
        clearSplit(in: destinationSpaceID)
        let groupID = groups.contains { $0.id == closedTab.groupID && $0.spaceID == destinationSpaceID }
            ? closedTab.groupID
            : nil
        var restoredTab = BrowserTab(
            url: closedTab.url,
            title: closedTab.title,
            spaceID: destinationSpaceID,
            groupID: groupID,
            isPinned: closedTab.isPinned,
            isFavorite: closedTab.isFavorite
        )
        restoredTab.faviconURL = closedTab.faviconURL
        restoredTab.isMuted = closedTab.isMuted
        restoredTab.privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
        tabs.append(restoredTab)
        insertTab(restoredTab.id, intoGroup: groupID, after: nil)
        createEnginePages(for: [restoredTab.id])
        selectTab(restoredTab.id)
        scheduleSave()
    }

    func duplicateTab(_ tabID: UUID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID && !$0.isArchived }) else { return }
        let source = tabs[sourceIndex]
        if source.spaceID != currentSpaceID {
            switchSpace(to: source.spaceID)
        }
        clearSplit(in: source.spaceID)
        var duplicate = BrowserTab(
            url: source.url,
            title: source.title,
            spaceID: source.spaceID,
            groupID: source.groupID,
            isPinned: source.isPinned,
            isFavorite: source.isFavorite
        )
        duplicate.faviconURL = source.faviconURL
        duplicate.isMuted = source.isMuted
        duplicate.privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
        tabs.insert(duplicate, at: min(sourceIndex + 1, tabs.endIndex))
        if let faviconData = faviconDataByTabID[source.id] {
            cacheFavicon(faviconData, for: duplicate.id)
        }
        insertTab(duplicate.id, intoGroup: source.groupID, after: source.id)
        createEnginePages(for: [duplicate.id])
        selectTab(duplicate.id)
        scheduleSave()
    }

    func submitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let inputURL = normalizedURL(from: trimmed) else {
            lastError = "无法打开这个地址"
            return
        }
        if RexExtensionsPage.matches(inputURL) {
            openExtensionsPage(inputURL)
            return
        }
        let tabID = selectedTabID
        httpsUpgradeAttempts.removeValue(forKey: tabID)
        activeHTTPFallbackURLs.removeValue(forKey: tabID)
        siteSecurityInfoByTabID.removeValue(forKey: tabID)
        if tab(withID: tabID)?.isSleeping == true {
            setTabSleeping(tabID, sleeping: false)
        }
        let policyResult = applyPrivacyURLPolicy(to: inputURL, tabID: tabID)
        let url = policyResult.url
        let extensionTitle = RexExtensionResourceURL(rexURL: url).flatMap {
            extensionsStore.runnablePackage(runtimeID: $0.runtimeID)?.name
        }
        let navigationTitle = extensionTitle ?? url.host ?? trimmed
        beginPendingNavigation(to: url, from: tab(withID: tabID)?.url, for: tabID)
        addressText = url.absoluteString
        mutateTab(tabID) { tab in
            tab.url = url
            tab.title = navigationTitle
        }
        if extensionTitle == nil {
            recordHistory(url: url, title: navigationTitle, tabID: tabID)
        }
        enqueueNavigation(to: url, for: tabID)
        scheduleSave()
    }

    private func enqueueNavigation(to url: URL, for tabID: UUID) {
        guard isSitePrivacyPolicyReady else {
            deferredNavigationURLs[tabID] = url
            return
        }
        deferredNavigationURLs.removeValue(forKey: tabID)
        let pageSetupTask = pageSetupTasks[tabID]
        let previousNavigationTask = navigationCommandTasks[tabID]
        let navigationTask = Task { [engine] in
            await pageSetupTask?.value
            await previousNavigationTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await engine.execute(.loadURL(tabID: tabID, url: url))
            } catch {
                await MainActor.run {
                    if self.pendingNavigations[tabID]?.requestedURL == url {
                        self.pendingNavigations.removeValue(forKey: tabID)
                    }
                    self.lastError = error.localizedDescription
                }
            }
        }
        navigationCommandTasks[tabID] = navigationTask
    }

    func goBack() {
        Task { [engine, selectedTabID] in try? await engine.execute(.goBack(tabID: selectedTabID)) }
    }

    func goForward() {
        Task { [engine, selectedTabID] in try? await engine.execute(.goForward(tabID: selectedTabID)) }
    }

    func reload() {
        Task { [engine, selectedTabID] in try? await engine.execute(.reload(tabID: selectedTabID)) }
    }

    func reloadTab(_ tabID: UUID) {
        Task { [engine] in try? await engine.execute(.reload(tabID: tabID)) }
    }

    func reloadOrStop() {
        if RexExtensionsPage.matches(currentTab?.url) {
            if let runtimeID = RexExtensionsPage.detailRuntimeID(from: currentTab?.url),
               let package = extensionsStore.extensions.first(where: {
                   $0.runtimeID == runtimeID
               }) {
                Task { await refreshExtensionRuntimeConfiguration(for: package) }
            }
            return
        }
        let command: BrowserCommand = isCurrentPageLoading
            ? .stop(tabID: selectedTabID)
            : .reload(tabID: selectedTabID)
        Task { [engine] in try? await engine.execute(command) }
    }

    func showFind() {
        isFindPresented = true
        findFocusRequest &+= 1
    }

    func updateFind() {
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Task { [engine, selectedTabID] in
                try? await engine.execute(.stopFinding(tabID: selectedTabID))
            }
            return
        }
        Task { [engine, selectedTabID] in
            try? await engine.execute(.find(
                tabID: selectedTabID,
                query: query,
                forward: true,
                findNext: false
            ))
        }
    }

    func findNext(forward: Bool = true) {
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            showFind()
            return
        }
        Task { [engine, selectedTabID] in
            try? await engine.execute(.find(
                tabID: selectedTabID,
                query: query,
                forward: forward,
                findNext: true
            ))
        }
    }

    func dismissFind() {
        isFindPresented = false
        Task { [engine, selectedTabID] in
            try? await engine.execute(.stopFinding(tabID: selectedTabID))
        }
    }

    func adjustZoom(by step: Int) {
        let levels = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
        let current = navigationStates[selectedTabID]?.zoomLevel ?? 1
        let nearest = levels.indices.min { abs(levels[$0] - current) < abs(levels[$1] - current) } ?? 7
        setZoomLevel(levels[min(max(nearest + step, levels.startIndex), levels.index(before: levels.endIndex))])
    }

    func resetZoom() {
        setZoomLevel(1)
    }

    func selectAdjacentTab(forward: Bool) {
        let candidates = visibleTabs
        guard candidates.count > 1,
              let currentIndex = candidates.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let offset = forward ? 1 : candidates.count - 1
        selectTab(candidates[(currentIndex + offset) % candidates.count].id)
    }

    func selectTab(atChromePosition position: Int) {
        let candidates = visibleTabs
        guard !candidates.isEmpty, 1...9 ~= position else { return }
        let index = position == 9 ? candidates.index(before: candidates.endIndex) : position - 1
        guard candidates.indices.contains(index) else { return }
        selectTab(candidates[index].id)
    }

    func printCurrentPage() {
        Task { [engine, selectedTabID] in
            try? await engine.execute(.printPage(tabID: selectedTabID))
        }
    }

    func toggleMuted(_ tabID: UUID) {
        guard let tab = tab(withID: tabID) else { return }
        let muted = !tab.isMuted
        mutateTab(tabID) { $0.isMuted = muted }
        Task { [engine] in
            try? await engine.execute(.setAudioMuted(tabID: tabID, muted: muted))
        }
        scheduleSave()
    }

    func openDeveloperTools() {
        if developerToolsTabID != nil {
            closeDeveloperTools()
            return
        }
        presentDeveloperTools(for: selectedTabID)
    }

    /// Chrome ⌘⌥J — open DevTools focused on Console.
    func openDeveloperToolsConsole() {
        let tabID = selectedTabID
        presentDeveloperTools(for: tabID)
        Task { [engine] in
            try? await engine.execute(.openDeveloperToolsConsole(tabID: tabID))
        }
    }

    /// Chrome ⌘⇧C — open DevTools and enter inspect mode.
    func openDeveloperToolsInspect() {
        let tabID = selectedTabID
        presentDeveloperTools(for: tabID)
        Task { [engine] in
            try? await engine.execute(.openDeveloperToolsInspect(tabID: tabID))
        }
    }

    /// Chrome ⌘⇧R — empty cache and hard reload through CefBrowserHost.
    func hardReloadCurrentPage() {
        let tabID = selectedTabID
        Task { [engine] in
            try? await engine.execute(.reloadIgnoringCache(tabID: tabID))
        }
    }

    func closeDeveloperTools() {
        let closingTabID = developerToolsTabID
        developerToolsTabID = nil
        developerToolsInspectX = nil
        developerToolsInspectY = nil
        if isDeveloperToolsResizing {
            isDeveloperToolsResizing = false
#if REX_CEF
            RexChromiumRuntime.shared.setLayoutSyncSuspended(false)
            RexChromiumRuntime.shared.flushLayoutSync()
#endif
        }
#if REX_CEF
        if let closingTabID {
            RexChromiumRuntime.shared.closeDeveloperTools(forTabID: closingTabID.uuidString)
        }
#endif
    }

    func beginDeveloperToolsResize() {
        guard !isDeveloperToolsResizing else { return }
        isDeveloperToolsResizing = true
#if REX_CEF
        RexChromiumRuntime.shared.setLayoutSyncSuspended(true)
#endif
    }

    func endDeveloperToolsResize() {
        guard isDeveloperToolsResizing else { return }
        isDeveloperToolsResizing = false
#if REX_CEF
        RexChromiumRuntime.shared.setLayoutSyncSuspended(false)
        // Wait one run-loop turn so SwiftUI can commit the final pane frames first.
        DispatchQueue.main.async {
            RexChromiumRuntime.shared.flushLayoutSync()
        }
#endif
    }

    func resizeDeveloperTools(to width: CGFloat, availableWidth: CGFloat, force: Bool = false) {
        let maximum = max(320, min(760, availableWidth * 0.68))
        // Quantize to whole points so SwiftUI and CEF stay on the same grid.
        let next = floor(min(max(width, 320), maximum))
        // During live drag, width is held in view-local state; force commits the final value.
        if !force, abs(next - developerToolsWidth) < 3 { return }
        developerToolsWidth = next
    }

    @discardableResult
    func addNewTabFavorite(title: String? = nil, url: URL? = nil) -> Bool {
        guard !profile.isPrivate else { return false }
        let candidateURL = url ?? currentTab?.url
        guard let candidateURL,
              let resolvedURL = NewTabFavoriteDraft.normalizedURL(candidateURL),
              !BrowserStartPage.matches(resolvedURL) else {
            lastError = "当前页面无法加入新标签页收藏"
            return false
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = currentTab?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle: String
        if let trimmedTitle, !trimmedTitle.isEmpty {
            displayTitle = trimmedTitle
        } else if let fallbackTitle, !fallbackTitle.isEmpty {
            displayTitle = fallbackTitle
        } else {
            displayTitle = resolvedURL.host ?? resolvedURL.absoluteString
        }
        let favorite = NewTabFavoriteSite(
            url: resolvedURL,
            title: displayTitle
        )
        do {
            guard try newTabFavoritesStore.add(favorite) else {
                lastError = "该网站已在新标签页收藏中"
                return false
            }
            return true
        } catch {
            lastError = "无法保存新标签页收藏：\(error.localizedDescription)"
            return false
        }
    }

    func removeNewTabFavorite(_ favorite: NewTabFavoriteSite) {
        guard !profile.isPrivate else { return }
        do {
            try newTabFavoritesStore.remove(id: favorite.id)
        } catch {
            lastError = "无法移除新标签页收藏：\(error.localizedDescription)"
        }
    }

    func removeNewTabFavorite(url: URL) {
        guard !profile.isPrivate else { return }
        do {
            try newTabFavoritesStore.remove(url: url)
        } catch {
            lastError = "无法移除新标签页收藏：\(error.localizedDescription)"
        }
    }

    private func presentDeveloperTools(for tabID: UUID, inspectX: Int? = nil, inspectY: Int? = nil) {
        guard tab(withID: tabID) != nil else { return }
        if let presentedTabID = developerToolsTabID, presentedTabID != tabID {
            closeDeveloperTools()
        }
        developerToolsTabID = tabID
        developerToolsInspectX = inspectX
        developerToolsInspectY = inspectY
        developerToolsRequestID &+= 1
    }

    private func setZoomLevel(_ level: Double) {
        var state = navigationStates[selectedTabID] ?? NavigationState(url: currentTab?.url)
        state.zoomLevel = level
        navigationStates[selectedTabID] = state
        Task { [engine, selectedTabID] in
            try? await engine.execute(.setZoom(tabID: selectedTabID, level: level))
        }
    }

    func togglePinned(_ tabID: UUID) {
        mutateTab(tabID) { $0.isPinned.toggle() }
        scheduleSave()
    }

    @discardableResult
    func createGroup(name: String = "新分组") -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = TabGroup(
            id: UUID(), spaceID: currentSpaceID, name: trimmed,
            symbolName: "folder.fill", isCollapsed: false, tabIDs: []
        )
        groups.append(group)
        scheduleSave()
        return group.id
    }

    func toggleGroup(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isCollapsed.toggle()
        scheduleSave()
    }

    func deleteGroup(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let tabIDs = Set(groups[index].tabIDs)
        groups.remove(at: index)
        for tabIndex in tabs.indices where tabIDs.contains(tabs[tabIndex].id) {
            tabs[tabIndex].groupID = nil
        }
        scheduleSave()
    }

    func moveTab(_ tabID: UUID, toGroup groupID: UUID?) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[tabIndex].spaceID == currentSpaceID else { return }
        for index in groups.indices { groups[index].tabIDs.removeAll { $0 == tabID } }
        tabs[tabIndex].groupID = nil
        if let groupIndex = groups.firstIndex(where: { $0.id == groupID && $0.spaceID == currentSpaceID }) {
            groups[groupIndex].tabIDs.append(tabID)
            tabs[tabIndex].groupID = groups[groupIndex].id
        }
        scheduleSave()
    }

    private func insertTab(_ tabID: UUID, intoGroup groupID: UUID?, after predecessorID: UUID?) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[groupIndex].tabIDs.removeAll { $0 == tabID }
        if let predecessorID,
           let predecessorIndex = groups[groupIndex].tabIDs.firstIndex(of: predecessorID) {
            groups[groupIndex].tabIDs.insert(tabID, at: predecessorIndex + 1)
        } else {
            groups[groupIndex].tabIDs.append(tabID)
        }
    }

    func moveTab(_ tabID: UUID, toSpace spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }),
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              !isTabInAnySplit(tabID) else { return }
        detachTabFromSplit(tabID)
        for index in groups.indices { groups[index].tabIDs.removeAll { $0 == tabID } }
        savedSplitCompositions.removeAll {
            $0.primaryTabID == tabID || $0.secondaryTabID == tabID
        }
        tabs[tabIndex].spaceID = spaceID
        tabs[tabIndex].groupID = nil
        if tabID == selectedTabID && spaceID != currentSpaceID {
            if let next = visibleTabs.first {
                selectTab(next.id)
            } else {
                newTab()
            }
        }
        scheduleSave()
    }

    func setTabSleeping(_ tabID: UUID, sleeping: Bool) {
        guard let tab = tab(withID: tabID), !tab.isArchived else { return }
        if sleeping {
            guard tabID != selectedTabID, !isTabInAnySplit(tabID),
                  !tab.isPlayingAudio, !tab.isPinned,
                  !tabHasActiveWork(tabID) else { return }
        }
        mutateTab(tabID) {
            $0.isSleeping = sleeping
            $0.lifecycle = sleeping ? .sleeping : .background
        }
        schedulePageSuspension(tabID: tabID, isSuspended: sleeping, isFocused: !sleeping)
        scheduleSave()
    }

    private func automaticTabSleepingDidChange(_ enabled: Bool) {
        automaticSleepTask?.cancel()
        automaticSleepTask = nil
        guard enabled else {
            for tab in tabs where tab.isSleeping {
                setTabSleeping(tab.id, sleeping: false)
            }
            return
        }
        automaticSleepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                self?.sleepInactiveTabs()
            }
        }
    }

    func sleepInactiveTabs(now: Date = .now, idleInterval: TimeInterval? = nil) {
        guard preferences.automaticTabSleeping else { return }
        let effectiveIdleInterval = idleInterval
            ?? TimeInterval(preferences.tabSleepDelayMinutes * 60)
        let candidates = tabs.filter {
            !$0.isArchived && !$0.isSleeping && !$0.isPinned && !$0.isPlayingAudio &&
            $0.id != selectedTabID && $0.splitSessionID == nil &&
            !tabHasActiveWork($0.id) &&
            now.timeIntervalSince($0.lastAccessedAt) >= effectiveIdleInterval
        }
        for tab in candidates { setTabSleeping(tab.id, sleeping: true) }
    }

    private func tabHasActiveWork(_ tabID: UUID) -> Bool {
        navigationStates[tabID]?.isLoading == true ||
            activeDownloadTabIDsByDownloadID.values.contains(tabID) ||
            activeMediaTabIDs.contains(tabID) ||
            pendingPermissionPrompts.contains { $0.tabID == tabID } ||
            permissions.contains {
                $0.tabID == tabID && $0.decision == .revokeOnTabClose
            }
    }

    func archiveTab(_ tabID: UUID) {
        guard let tab = tab(withID: tabID), !tab.isArchived, !isTabInAnySplit(tabID) else { return }
        for index in groups.indices { groups[index].tabIDs.removeAll { $0 == tabID } }
        mutateTab(tabID) {
            $0.groupID = nil
            $0.isArchived = true
            $0.isSleeping = false
            $0.lifecycle = .archived
        }
        if selectedTabID == tabID {
            if let next = visibleTabs.first {
                selectTab(next.id)
            } else {
                newTab()
            }
        }
        schedulePageSuspension(tabID: tabID, isSuspended: true, isFocused: false)
        scheduleSave()
    }

    func restoreArchivedTab(_ tabID: UUID) {
        guard tab(withID: tabID)?.isArchived == true else { return }
        mutateTab(tabID) {
            $0.isArchived = false
            $0.isSleeping = false
            $0.lifecycle = .background
            $0.lastAccessedAt = .now
        }
        schedulePageSuspension(tabID: tabID, isSuspended: false, isFocused: true)
        selectTab(tabID)
    }

    func toggleBookmark(for tab: BrowserTab? = nil) {
        guard !profile.isPrivate else { return }
        guard let tab = tab ?? currentTab, let url = tab.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            let removed = bookmarks.remove(at: index)
            Task { [persistence] in try? await persistence.removeBookmark(id: removed.id) }
        } else {
            let bookmark = BrowserBookmark(url: url, title: tab.title)
            bookmarks.insert(bookmark, at: 0)
            Task { [persistence] in try? await persistence.saveBookmark(bookmark) }
        }
        mutateTab(tab.id) { $0.isFavorite = bookmarks.contains { $0.url == url } }
        scheduleSave()
    }

    func removeBookmark(_ bookmark: BrowserBookmark) {
        guard !profile.isPrivate else { return }
        bookmarks.removeAll { $0.id == bookmark.id }
        for index in tabs.indices where tabs[index].url == bookmark.url {
            tabs[index].isFavorite = false
        }
        Task { [persistence] in try? await persistence.removeBookmark(id: bookmark.id) }
        scheduleSave()
    }

    func removeHistory(_ entry: BrowserHistoryEntry) {
        guard !profile.isPrivate else { return }
        history.removeAll { $0.id == entry.id }
        Task { [persistence] in try? await persistence.removeHistory(id: entry.id) }
    }

    func removeHistory(in range: BrowsingDataTimeRange, relativeTo referenceDate: Date = .now) {
        guard !profile.isPrivate else { return }
        let cutoff = range.cutoff(relativeTo: referenceDate)
        if let cutoff {
            history.removeAll { $0.visitedAt >= cutoff }
        } else {
            history.removeAll()
        }
        Task { @MainActor [weak self, persistence] in
            do {
                try await persistence.removeHistory(visitedAtOrAfter: cutoff)
            } catch {
                self?.lastError = "删除浏览历史失败：\(error.localizedDescription)"
            }
        }
    }

    func openLibraryEntry(url: URL) {
        guard let visibleURL = Self.userVisibleURL(url) else {
            lastError = "无法打开这个地址"
            return
        }
        addressText = visibleURL.absoluteString
        submitAddress()
        isLibraryPresented = false
    }

    func presentLibrary(_ section: BrowserLibrarySection) {
        librarySelection = section
        isLibraryPresented = true
    }

    func setDownloadDirectory(_ directoryURL: URL?) {
        guard let spaceIndex = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        if let directoryURL {
            var isDirectory: ObjCBool = false
            guard directoryURL.isFileURL,
                  FileManager.default.fileExists(
                    atPath: directoryURL.path,
                    isDirectory: &isDirectory
                  ),
                  isDirectory.boolValue else {
                lastError = "无法保存下载位置：\(BrowserEngineError.invalidPayload.localizedDescription)"
                return
            }

            stopAccessingDownloadDirectory(for: currentSpaceID)
            if directoryURL.startAccessingSecurityScopedResource() {
                securityScopedDownloadDirectoryURLsBySpace[currentSpaceID] = directoryURL
            }
            // Keep the URL granted by NSOpenPanel alive for the current process. Bookmark
            // persistence can fail independently (for example in a managed test sandbox).
            downloadDirectoryURLsBySpace[currentSpaceID] = directoryURL
            configureDownloadDirectories(for: tabs.filter { $0.spaceID == currentSpaceID }.map(\.id))
            do {
                spaces[spaceIndex].downloadDirectoryBookmark = try directoryURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: [.isDirectoryKey],
                    relativeTo: nil
                )
                scheduleSave()
            } catch {
                spaces[spaceIndex].downloadDirectoryBookmark = nil
                scheduleSave()
                lastError = "无法持久化下载位置：\(error.localizedDescription)"
            }
        } else {
            spaces[spaceIndex].downloadDirectoryBookmark = nil
            stopAccessingDownloadDirectory(for: currentSpaceID)
            downloadDirectoryURLsBySpace.removeValue(forKey: currentSpaceID)
            configureDownloadDirectories(for: tabs.filter { $0.spaceID == currentSpaceID }.map(\.id))
            scheduleSave()
        }
    }

    func cancelDownload(_ download: BrowserDownloadTask) {
        guard canCancelDownload(download) else { return }
        Task { [engine] in
            try? await engine.execute(.cancelDownload(downloadID: download.id))
        }
    }

    func isDownloadActive(_ download: BrowserDownloadTask) -> Bool {
        activeDownloadTabIDsByDownloadID[download.id] != nil
    }

    func canCancelDownload(_ download: BrowserDownloadTask) -> Bool {
        download.canCancel && isDownloadActive(download)
    }

    func isDownloadRetrying(_ download: BrowserDownloadTask) -> Bool {
        retryingDownloadIDs.contains(download.id)
    }

    var hasClearableDownloadRecords: Bool {
        downloads.contains { !isDownloadActive($0) }
    }

    func retryDownload(_ download: BrowserDownloadTask) {
        guard download.canRetry,
              !retryingDownloadIDs.contains(download.id),
              let tabID = currentTab?.id else { return }
        // Do not manufacture a local pending state. Chromium will emit the
        // replacement lifecycle snapshot and ChromiumBrowserEngine will map it
        // back onto this task identity.
        retryingDownloadIDs.insert(download.id)
        activeDownloadTabIDsByDownloadID[download.id] = tabID
        Task { [weak self, engine] in
            do {
                try await engine.execute(.retryDownload(
                    downloadID: download.id,
                    tabID: tabID,
                    url: download.sourceURL
                ))
            } catch {
                self?.retryingDownloadIDs.remove(download.id)
                self?.activeDownloadTabIDsByDownloadID.removeValue(forKey: download.id)
            }
        }
    }

    func openDownloadedFile(_ download: BrowserDownloadTask) {
        guard download.canOpen, let destinationURL = download.destinationURL,
              FileManager.default.fileExists(atPath: destinationURL.path) else {
            lastError = "下载文件已移动、删除，或旧记录没有保存本地路径。"
            return
        }
        NSWorkspace.shared.open(destinationURL)
    }

    func revealDownloadedFile(_ download: BrowserDownloadTask) {
        guard download.canOpen, let destinationURL = download.destinationURL,
              FileManager.default.fileExists(atPath: destinationURL.path) else {
            lastError = "下载文件已移动、删除，或旧记录没有保存本地路径。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    }

    func removeDownload(_ download: BrowserDownloadTask) {
        guard !isDownloadActive(download) else { return }
        let removed = downloads.filter { $0.id == download.id }
        guard !removed.isEmpty else { return }
        suppressedDownloadIDs.formUnion(removed.map(\.id))
        downloads.removeAll { $0.id == download.id }
        guard !profile.isPrivate else { return }
        Task { @MainActor [weak self, persistence] in
            do {
                try await persistence.removeDownload(id: download.id)
            } catch {
                guard let self else { return }
                suppressedDownloadIDs.subtract(removed.map(\.id))
                downloads.append(contentsOf: removed)
                downloads.sort { $0.createdAt > $1.createdAt }
                lastError = "删除下载记录失败：\(error.localizedDescription)"
            }
        }
    }

    func clearDownloadRecords() {
        let removed = downloads.filter { !isDownloadActive($0) }
        guard !removed.isEmpty else { return }
        let removedIDs = removed.map(\.id)
        suppressedDownloadIDs.formUnion(removedIDs)
        downloads.removeAll { removedIDs.contains($0.id) }
        guard !profile.isPrivate else { return }
        Task { @MainActor [weak self, persistence] in
            do {
                try await persistence.removeDownloads(ids: removedIDs)
            } catch {
                guard let self else { return }
                suppressedDownloadIDs.subtract(removedIDs)
                let existingIDs = Set(downloads.map(\.id))
                downloads.append(contentsOf: removed.filter { !existingIDs.contains($0.id) })
                downloads.sort { $0.createdAt > $1.createdAt }
                lastError = "清空下载记录失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleSplit() {
        if let splitSession {
            endSplit(keeping: splitSession.focusedPane == .primary ? splitSession.primaryTabID : splitSession.secondaryTabID)
            return
        }
        guard let second = visibleTabs.first(where: { $0.id != selectedTabID }) else {
            let primaryID = selectedTabID
            newTab()
            beginSplit(primaryTabID: primaryID, secondaryTabID: selectedTabID)
            return
        }
        beginSplit(primaryTabID: selectedTabID, secondaryTabID: second.id)
    }

    func beginSplit(primaryTabID: UUID, secondaryTabID: UUID) {
        guard primaryTabID != secondaryTabID,
              let primary = tab(withID: primaryTabID), !primary.isArchived,
              let secondary = tab(withID: secondaryTabID), !secondary.isArchived,
              primary.spaceID == currentSpaceID,
              secondary.spaceID == currentSpaceID else { return }
        clearSplit(in: currentSpaceID)
        let session = SplitViewSession(
            primaryTabID: primaryTabID,
            secondaryTabID: secondaryTabID,
            orientation: .horizontal,
            spaceID: currentSpaceID
        )
        activateSplit(session)
    }

    func endSplit(keeping tabID: UUID?) {
        let previouslyFocusedTabID = splitSession.map {
            self.tabID(for: $0.focusedPane, in: $0)
        }
        clearSplit(in: currentSpaceID)
        if let tabID, let tab = tab(withID: tabID) {
            selectedTabID = tabID
            addressText = addressBarText(for: tab.url)
            touchTab(tabID)
        }
        updateTabLifecycles()
        updateFocusedPagePriorities(previouslyFocusedTabID: previouslyFocusedTabID)
        scheduleSave()
    }

    func focus(_ pane: SplitPane) {
        guard let session = splitSession else { return }
        splitSession?.focusedPane = pane
        splitSession?.lastOpenedAt = .now
        selectedTabID = tabID(for: pane, in: session)
        addressText = addressBarText(for: currentTab?.url)
        touchTab(selectedTabID)
        rememberCurrentSplit()
        updateTabLifecycles()
        updateSplitPagePriorities(splitSession)
        scheduleSave()
    }

    func swapSplitPages() {
        guard let session = splitSession else { return }
        let focusedTabID = tabID(for: session.focusedPane, in: session)
        let destinationPane: SplitPane = session.focusedPane == .primary ? .secondary : .primary
        _ = swapSplitPages(focusing: destinationPane, selectedTabID: focusedTabID)
    }

    func setSplitRatio(_ ratio: Double) {
        guard splitSession != nil else { return }
        splitSession?.ratio = min(max(ratio, 0.25), 0.75)
        rememberCurrentSplit()
        scheduleSave()
    }

    func canPlaceTab(_ tabID: UUID, in pane: SplitPane) -> Bool {
        guard let candidate = tab(withID: tabID),
              !candidate.isArchived,
              candidate.spaceID == currentSpaceID else { return false }
        if let splitSession {
            return tabID != self.tabID(for: pane, in: splitSession)
        }
        guard tabID != selectedTabID,
              let selected = tab(withID: selectedTabID),
              !selected.isArchived,
              selected.spaceID == currentSpaceID else { return false }
        return true
    }

    /// Places a context-menu tab in the requested side of the current split.
    /// Existing split members swap sides; other tabs replace only that pane.
    @discardableResult
    func placeTab(_ tabID: UUID, in pane: SplitPane) -> Bool {
        guard canPlaceTab(tabID, in: pane) else { return false }

        if let session = splitSession {
            if session.primaryTabID == tabID || session.secondaryTabID == tabID {
                return swapSplitPages(focusing: pane, selectedTabID: tabID)
            }
            return replaceSplitPane(pane, with: tabID, orientation: .horizontal)
        }

        let companionTabID = selectedTabID
        let session = SplitViewSession(
            primaryTabID: pane == .primary ? tabID : companionTabID,
            secondaryTabID: pane == .secondary ? tabID : companionTabID,
            orientation: .horizontal,
            focusedPane: pane,
            spaceID: currentSpaceID
        )
        activateSplit(session)
        return splitSession?.id == session.id
    }

    @discardableResult
    func saveCurrentSplitComposition(name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = splitSession else { return nil }
        let composition = SavedSplitComposition(
            name: trimmed,
            spaceID: session.spaceID,
            primaryTabID: session.primaryTabID,
            secondaryTabID: session.secondaryTabID,
            orientation: session.orientation,
            ratio: session.ratio,
            focusedPane: session.focusedPane
        )
        savedSplitCompositions.append(composition)
        scheduleSave()
        return composition.id
    }

    @discardableResult
    func restoreSplitComposition(_ compositionID: UUID) -> Bool {
        guard let index = savedSplitCompositions.firstIndex(where: { $0.id == compositionID }) else {
            return false
        }
        let composition = savedSplitCompositions[index]
        guard let primary = tab(withID: composition.primaryTabID), !primary.isArchived,
              let secondary = tab(withID: composition.secondaryTabID), !secondary.isArchived,
              primary.spaceID == composition.spaceID,
              secondary.spaceID == composition.spaceID else {
            lastError = "这个分屏组合包含已关闭、已归档或已移动的标签页"
            return false
        }
        if currentSpaceID != composition.spaceID {
            switchSpace(to: composition.spaceID)
        }
        savedSplitCompositions[index].lastUsedAt = .now
        let session = SplitViewSession(
            primaryTabID: composition.primaryTabID,
            secondaryTabID: composition.secondaryTabID,
            orientation: composition.orientation,
            ratio: composition.ratio,
            focusedPane: composition.focusedPane,
            spaceID: composition.spaceID
        )
        clearSplit(in: composition.spaceID)
        activateSplit(session)
        return true
    }

    func deleteSplitComposition(_ compositionID: UUID) {
        guard savedSplitCompositions.contains(where: { $0.id == compositionID }) else { return }
        savedSplitCompositions.removeAll { $0.id == compositionID }
        scheduleSave()
    }

    func setPrivacyProtectionEnabled(_ enabled: Bool, for tabID: UUID? = nil) {
        let targetID = tabID ?? selectedTabID
        guard let target = tab(withID: targetID) else { return }
        guard let host = privacyPolicyHost(for: target.url) else {
            mutateTab(targetID) { $0.privacyState.isEnabled = enabled }
            pushPrivacyPolicy(for: targetID)
            scheduleSave()
            return
        }

        var policy = sitePrivacyPolicy(forHost: host, fallbackTab: target)
        policy.protectionEnabled = enabled
        policy.updatedAt = .now
        updateSitePrivacyPolicy(policy)
        scheduleSave()
    }

    func setPrivacyLevel(_ level: PrivacyLevel, for tabID: UUID? = nil) {
        let targetID = tabID ?? selectedTabID
        guard let target = tab(withID: targetID) else { return }
        if let host = privacyPolicyHost(for: target.url) {
            var policy = sitePrivacyPolicy(forHost: host, fallbackTab: target)
            policy.level = level
            if level == .strict || level == .custom {
                policy.fingerprintProtectionEnabled = true
            }
            policy.updatedAt = .now
            updateSitePrivacyPolicy(policy)
        } else {
            mutateTab(targetID) { tab in
                tab.privacyState.level = level
                if level == .strict || level == .custom {
                    tab.privacyState.fingerprintProtectionEnabled = true
                }
            }
            pushPrivacyPolicy(for: targetID)
        }
        scheduleSave()
    }

    func sitePrivacyPolicy(for tab: BrowserTab?) -> SitePrivacyPolicy? {
        guard let tab, let host = privacyPolicyHost(for: tab.url) else { return nil }
        return sitePrivacyPolicy(forHost: host, fallbackTab: tab)
    }

    private func sitePrivacyPolicy(
        forHost host: String,
        fallbackTab: BrowserTab
    ) -> SitePrivacyPolicy {
        if let stored = sitePrivacyPolicies.first(where: {
            $0.profileID == profile.id && $0.host == host
        }) {
            return stored
        }
        return SitePrivacyPolicy(
            profileID: profile.id,
            host: host,
            protectionEnabled: fallbackTab.privacyState.isEnabled,
            level: fallbackTab.privacyState.level,
            fingerprintProtectionEnabled:
                fallbackTab.privacyState.fingerprintProtectionEnabled
        )
    }

    private func defaultSitePrivacyPolicy(
        forHost host: String,
        spaceID: UUID
    ) -> SitePrivacyPolicy {
        let level = spaces.first(where: { $0.id == spaceID })?.privacyLevel ?? .standard
        return SitePrivacyPolicy(
            profileID: profile.id,
            host: host,
            level: level,
            fingerprintProtectionEnabled: true
        )
    }

    private func updateSitePrivacyPolicy(_ policy: SitePrivacyPolicy) {
        guard !policy.host.isEmpty, policy.profileID == profile.id else { return }
        sitePrivacyPolicies.removeAll {
            $0.profileID == policy.profileID && $0.host == policy.host
        }
        sitePrivacyPolicies.append(policy)
        sitePrivacyPolicies.sort { $0.updatedAt > $1.updatedAt }

        let affectedTabIDs = tabs.compactMap { tab -> UUID? in
            privacyPolicyHost(for: tab.url) == policy.host ? tab.id : nil
        }
        for tabID in affectedTabIDs {
            apply(policy, to: tabID)
        }
        pushPrivacyPolicies(for: affectedTabIDs)
        guard !profile.isPrivate else { return }
        Task { [persistence] in
            try? await persistence.saveSitePrivacyPolicy(policy)
        }
    }

    private func mergeLoadedSitePrivacyPolicies(_ storedPolicies: [SitePrivacyPolicy]) {
        var policiesByHost: [String: SitePrivacyPolicy] = [:]
        for policy in storedPolicies + sitePrivacyPolicies
        where !policy.host.isEmpty && policy.profileID == profile.id {
            if let existing = policiesByHost[policy.host],
               existing.updatedAt > policy.updatedAt {
                continue
            }
            policiesByHost[policy.host] = policy
        }
        sitePrivacyPolicies = policiesByHost.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func normalizedSitePrivacyPolicies(
        _ policies: [SitePrivacyPolicy],
        profileID: UUID
    ) -> [SitePrivacyPolicy] {
        var policiesBySite = [String: SitePrivacyPolicy]()
        for var policy in policies where policy.profileID == profileID {
            let site = PublicSuffixList.current.registrableDomain(for: policy.host)
            guard !site.isEmpty else { continue }
            policy.host = site
            if let existing = policiesBySite[site], existing.updatedAt > policy.updatedAt {
                continue
            }
            policiesBySite[site] = policy
        }
        return policiesBySite.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func apply(_ policy: SitePrivacyPolicy, to tabID: UUID) {
        mutateTab(tabID) { tab in
            tab.privacyState.isEnabled = policy.protectionEnabled
            tab.privacyState.level = policy.level
            tab.privacyState.fingerprintProtectionEnabled =
                policy.fingerprintProtectionEnabled
        }
    }

    @discardableResult
    private func applySitePrivacyPolicy(for url: URL, to tabID: UUID) -> Bool {
        guard let tab = tab(withID: tabID),
              let host = privacyPolicyHost(for: url) else { return false }
        let policy = sitePrivacyPolicies.first(where: {
            $0.profileID == profile.id && $0.host == host
        }) ?? defaultSitePrivacyPolicy(forHost: host, spaceID: tab.spaceID)
        let state = tab.privacyState
        let changed = state.isEnabled != policy.protectionEnabled
            || state.level != policy.level
            || state.fingerprintProtectionEnabled
                != policy.fingerprintProtectionEnabled
        guard changed else { return false }
        apply(policy, to: tabID)
        return true
    }

    private func privacyPolicyHost(for url: URL?) -> String? {
        guard let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        return PublicSuffixList.current.registrableDomain(for: host)
    }

    func applyPrivacyPreferences() {
        applyHTTPSUpgradePreference(preferences.httpsUpgradeEnabled)
    }

    private func applyHTTPSUpgradePreference(_ enabled: Bool) {
        for index in tabs.indices {
            tabs[index].privacyState.httpsUpgradeEnabled = enabled
        }
        pushPrivacyPolicies(for: tabs.map(\.id))
        scheduleSave()
    }

    func presentSettings(_ section: BrowserSettingsSection = .general) {
        settingsSection = section
        isSettingsPresented = true
    }

    func pushPrivacyPolicy(
        for tabID: UUID,
        blockThirdPartyCookies override: Bool? = nil
    ) {
        guard isSitePrivacyPolicyReady,
              let tab = tab(withID: tabID) else { return }
        let state = tab.privacyState
        let blockThirdPartyCookies = override ?? preferences.blockThirdPartyCookies
        Task { [engine] in
            try? await engine.execute(.setPrivacyPolicy(
                tabID: tabID,
                enabled: state.isEnabled,
                level: state.level,
                fingerprintProtection: state.fingerprintProtectionEnabled,
                blockThirdPartyCookies: blockThirdPartyCookies
            ))
        }
    }

    private func pushPrivacyPolicies(
        for tabIDs: [UUID],
        blockThirdPartyCookies: Bool? = nil
    ) {
        for tabID in tabIDs {
            pushPrivacyPolicy(
                for: tabID,
                blockThirdPartyCookies: blockThirdPartyCookies
            )
        }
    }

    func privacyReport(for tab: BrowserTab?) -> PrivacyReport {
        let state = tab?.privacyState
        let blocked = state?.blockedCount ?? 0
        let resources = state?.resources ?? []
        let ads = resources.filter { $0.category == .advertisement }.reduce(0) { $0 + $1.count }
        let trackers = resources.filter { $0.category == .tracker }.reduce(0) { $0 + $1.count }
        let fingerprinting = resources.filter {
            $0.category == .fingerprinting
        }.reduce(0) { $0 + $1.count }
        let cookies = resources.filter { $0.category == .thirdPartyCookie }.reduce(0) { $0 + $1.count }
        let suspiciousScripts = resources.filter { $0.category == .suspiciousScript }.reduce(0) { $0 + $1.count }
        return PrivacyReport(
            siteHost: tab?.url?.host ?? "新标签页",
            adsBlocked: ads,
            trackersBlocked: trackers,
            fingerprintingBlocked: fingerprinting,
            thirdPartyCookiesBlocked: cookies,
            httpsUpgrades: state?.httpsUpgradeCount ?? 0,
            cleanedParameters: state?.cleanedParameterCount ?? 0,
            suspiciousScriptsBlocked: suspiciousScripts,
            resources: resources,
            totalBlocked: blocked
        )
    }

    var currentSitePermissions: [WebsitePermission] {
        guard let url = currentTab?.url, let origin = origin(for: url) else { return [] }
        return permissions.filter { $0.topLevelOrigin == origin }
    }

    func respond(to prompt: WebsitePermissionPrompt, with decision: PermissionDecision) {
        guard pendingPermissionPrompts.contains(where: { $0.id == prompt.id }) else { return }
        pendingPermissionPrompts.removeAll { $0.id == prompt.id }

        if [.allowAlways, .blockAlways, .revokeOnTabClose].contains(decision) {
            for kind in prompt.request.kinds {
                let permission = WebsitePermission(
                    id: UUID(),
                    profileID: profile.id,
                    topLevelOrigin: prompt.request.topLevelOrigin,
                    requestingOrigin: prompt.request.requestingOrigin,
                    kind: kind,
                    decision: decision,
                    tabID: decision == .revokeOnTabClose ? prompt.tabID : nil,
                    expiresAt: nil,
                    updatedAt: .now
                )
                let replacedPermission = replacePermission(permission)
                if !profile.isPrivate {
                    if decision.isPersistent {
                        Task { [persistence] in try? await persistence.savePermission(permission) }
                    } else if replacedPermission?.decision.isPersistent == true,
                              let replacedPermission {
                        Task { [persistence] in
                            try? await persistence.removePermission(id: replacedPermission.id)
                        }
                    }
                }
            }
        }

        Task { [engine] in
            try? await engine.execute(.respondToPermission(requestID: prompt.id, decision: decision))
        }
    }

    func updatePermission(_ permission: WebsitePermission, decision: PermissionDecision) {
        guard let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }
        if decision == .ask {
            revokePermission(permission)
            return
        }
        guard decision.isPersistent else { return }
        permissions[index].decision = decision
        permissions[index].tabID = nil
        permissions[index].expiresAt = nil
        permissions[index].updatedAt = .now
        let updated = permissions[index]
        stopActiveMediaIfNeeded(for: updated, decision: decision)
        guard !profile.isPrivate else { return }
        Task { [persistence] in try? await persistence.savePermission(updated) }
    }

    func revokePermission(_ permission: WebsitePermission) {
        permissions.removeAll { $0.id == permission.id }
        stopActiveMediaIfNeeded(for: permission, decision: .ask)
        guard !profile.isPrivate else { return }
        Task { [persistence] in try? await persistence.removePermission(id: permission.id) }
    }

    private func stopActiveMediaIfNeeded(
        for permission: WebsitePermission,
        decision: PermissionDecision
    ) {
        guard decision != .allowAlways,
              [.camera, .microphone, .screenCapture].contains(permission.kind) else {
            return
        }
        let affectedTabIDs = activeMediaTabIDs.filter { tabID in
            guard let url = tab(withID: tabID)?.url else { return false }
            return origin(for: url) == permission.topLevelOrigin
        }
        for tabID in affectedTabIDs {
            Task { [engine] in
                try? await engine.execute(.reload(tabID: tabID))
            }
        }
    }

    func flushSession() {
        guard !profile.isPrivate,
              !isRestoringSession,
              !isPreparingApplicationTermination else {
            return
        }
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = makeSnapshot()
        enqueueSessionSave(snapshot, reportsErrors: false)
    }

    /// Persists the newest user-visible state before Chromium starts closing.
    /// Unlike the ordinary debounce, this method does not return until the
    /// snapshot has reached SQLite or the write has failed.
    func persistLatestSessionSnapshotForApplicationTermination() async throws {
        guard !profile.isPrivate else { return }

        isPreparingApplicationTermination = true
        pendingSave?.cancel()
        pendingSave = nil

        // Never replace a durable restored session with the temporary startup
        // tabs. The application delegate owns the outer timeout for a restore
        // that cannot finish.
        while isRestoringSession {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        await sessionPersistenceTail?.value
        try Task.checkCancellation()

        // A save may have been scheduled while restoration or an earlier write
        // was awaiting SQLite. The termination snapshot supersedes it.
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = makeSnapshot()
        do {
            try await persistence.save(snapshot)
        } catch {
            lastError = "会话保存失败：\(error.localizedDescription)"
            throw error
        }
    }

    private static func userVisibleURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard let internalURL = RexExtensionsPage.userVisibleURL(from: url) else {
            return nil
        }
        return RexExtensionResourceURL.userVisibleURL(from: internalURL)
    }

    private static func userVisibleTitle(_ title: String) -> String {
        if let url = URL(string: title),
           let visibleURL = userVisibleURL(url),
           visibleURL != url {
            return visibleURL.absoluteString
        }
        return RexExtensionResourceURL.userVisibleString(from: title)
    }

    private static func userVisibleTab(_ tab: BrowserTab) -> BrowserTab {
        var visibleTab = tab
        visibleTab.url = userVisibleURL(tab.url)
        visibleTab.faviconURL = userVisibleURL(tab.faviconURL)
        visibleTab.title = userVisibleTitle(tab.title)
        return visibleTab
    }

    private static func userVisibleNavigationState(
        _ state: NavigationState
    ) -> NavigationState {
        var visibleState = state
        visibleState.url = userVisibleURL(state.url)
        visibleState.title = userVisibleTitle(state.title)
        return visibleState
    }

    private static func userVisibleHistoryEntry(
        _ entry: BrowserHistoryEntry
    ) -> BrowserHistoryEntry? {
        guard let visibleURL = userVisibleURL(entry.url) else { return nil }
        var visibleEntry = entry
        visibleEntry.url = visibleURL
        visibleEntry.title = userVisibleTitle(entry.title)
        return visibleEntry
    }

    private static func userVisibleBookmark(
        _ bookmark: BrowserBookmark
    ) -> BrowserBookmark? {
        guard let visibleURL = userVisibleURL(bookmark.url) else { return nil }
        var visibleBookmark = bookmark
        visibleBookmark.url = visibleURL
        visibleBookmark.title = userVisibleTitle(bookmark.title)
        return visibleBookmark
    }

    private static func userVisibleDownload(
        _ download: BrowserDownloadTask
    ) -> BrowserDownloadTask? {
        guard let visibleSourceURL = userVisibleURL(download.sourceURL) else { return nil }
        var visibleDownload = download
        visibleDownload.sourceURL = visibleSourceURL
        visibleDownload.originalURL = userVisibleURL(download.originalURL)
        visibleDownload.errorDescription = download.errorDescription.map(userVisibleTitle)
        return visibleDownload
    }

    private static func restoredDownloadSnapshot(
        _ download: BrowserDownloadTask
    ) -> BrowserDownloadTask {
        guard !download.isTerminal else { return download }
        var restored = download
        restored.state = .unknown
        restored.errorDescription = "上次运行未完成，当前没有活动下载任务。"
        return restored
    }

    private static func userVisiblePermission(
        _ permission: WebsitePermission
    ) -> WebsitePermission {
        var visiblePermission = permission
        visiblePermission.topLevelOrigin = RexExtensionResourceURL.userVisibleOrigin(
            from: permission.topLevelOrigin
        )
        visiblePermission.requestingOrigin = RexExtensionResourceURL.userVisibleOrigin(
            from: permission.requestingOrigin
        )
        return visiblePermission
    }

    private static func userVisiblePermissionRequest(
        _ request: WebsitePermissionRequest
    ) -> WebsitePermissionRequest {
        var visibleRequest = request
        visibleRequest.topLevelOrigin = RexExtensionResourceURL.userVisibleOrigin(
            from: request.topLevelOrigin
        )
        visibleRequest.requestingOrigin = RexExtensionResourceURL.userVisibleOrigin(
            from: request.requestingOrigin
        )
        return visibleRequest
    }

    private static func userVisibleSiteSecurityInfo(
        _ info: SiteSecurityInfo
    ) -> SiteSecurityInfo {
        var visibleInfo = info
        visibleInfo.url = userVisibleURL(info.url)
        return visibleInfo
    }

    private static func userVisibleSnapshot(
        _ snapshot: BrowserSessionSnapshot
    ) -> BrowserSessionSnapshot {
        var visibleSnapshot = snapshot
        visibleSnapshot.tabs = snapshot.tabs.map { tab in
            restorableTabForSession(userVisibleTab(tab))
        }
        let replacedTabIDs = Set(snapshot.tabs.compactMap { tab in
            tab.url.map(isLikelyDirectDownloadNavigation) == true ? tab.id : nil
        })
        visibleSnapshot.splitPaneStates = snapshot.splitPaneStates.map { paneState in
            var visiblePaneState = paneState
            visiblePaneState.navigation = userVisibleNavigationState(paneState.navigation)
            if replacedTabIDs.contains(paneState.tabID) {
                visiblePaneState.navigation.url = BrowserStartPage.url
                visiblePaneState.navigation.title = BrowserStartPage.title
                visiblePaneState.navigation.isLoading = false
                visiblePaneState.navigation.loadingProgress = 1
            }
            return visiblePaneState
        }
        return visibleSnapshot
    }

    static func restorableTabForSession(_ tab: BrowserTab) -> BrowserTab {
        guard let url = tab.url, isLikelyDirectDownloadNavigation(url) else { return tab }
        return restorableTabAfterDownload(tab, nonRestorableURL: url)
    }

    static func isLikelyDirectDownloadNavigation(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "github.com" {
            return path.contains("/releases/download/")
                || path.contains("/releases/latest/download/")
                || path.contains("/archive/refs/")
        }
        return [
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
            "github-releases.githubusercontent.com"
        ].contains(host)
    }

    private func addressBarText(for url: URL?) -> String {
        let visibleURL = Self.userVisibleURL(url)
        return BrowserStartPage.matches(visibleURL) ? "" : (visibleURL?.absoluteString ?? "")
    }

    private func normalizedURL(from input: String) -> URL? {
        if input.contains(" ") || (!input.contains(".") && !input.contains(":")) {
            return preferences.searchEngine.searchURL(for: input)
        }
        if let direct = URL(string: input), let scheme = direct.scheme?.lowercased() {
            if let extensionsURL = RexExtensionsPage.canonicalURL(from: direct) {
                return extensionsURL
            }
            if scheme == "chrome" {
                // Only Chromium's legacy extension-management route is exposed
                // through the Rex address bar. Other chrome:// WebUI routes stay
                // private to Chromium's internal execution contexts.
                return RexExtensionsPage.userVisibleURL(from: direct)
            }
            if scheme == RexExtensionResourceURL.scheme {
                guard let resource = RexExtensionResourceURL(rexURL: direct),
                      extensionsStore.runnablePackage(
                          runtimeID: resource.runtimeID
                      ) != nil else {
                    return nil
                }
                return resource.rexURL
            }
            return ["http", "https", "about"].contains(scheme) ? direct : nil
        }
        return URL(string: "https://\(input)")
    }

    private func resetExtensionsDetailRoute(for tabID: UUID) {
        guard let tab = tab(withID: tabID),
              RexExtensionsPage.matches(tab.url),
              tab.url != RexExtensionsPage.url else {
            return
        }
        pendingNavigations.removeValue(forKey: tabID)
        deferredNavigationURLs.removeValue(forKey: tabID)
        mutateTab(tabID) {
            $0.url = RexExtensionsPage.url
            $0.title = RexExtensionsPage.title
            $0.isLoading = false
            $0.loadingProgress = 1
        }
        navigationStates[tabID] = NavigationState(
            url: RexExtensionsPage.url,
            title: RexExtensionsPage.title,
            isLoading: false,
            loadingProgress: 1
        )
        if selectedTabID == tabID {
            addressText = RexExtensionsPage.url.absoluteString
        }
        scheduleSave()
    }

    private func applyPrivacyURLPolicy(
        to url: URL,
        tabID: UUID,
        allowHTTPSUpgrade: Bool = true
    ) -> PrivacyURLPolicyResult {
        if applySitePrivacyPolicy(for: url, to: tabID) {
            pushPrivacyPolicy(for: tabID)
        }
        let state = tab(withID: tabID)?.privacyState ?? PrivacyState()
        let result = PrivacyURLPolicy.apply(
            to: url,
            isEnabled: state.isEnabled,
            upgradeHTTPS: allowHTTPSUpgrade && state.httpsUpgradeEnabled
        )
        if result.didUpgradeHTTPS,
           let attempt = httpsUpgradeAttempt(for: result.url) {
            httpsUpgradeAttempts[tabID] = attempt
            activeHTTPFallbackURLs.removeValue(forKey: tabID)
        }
        guard result.didChange else { return result }
        mutateTab(tabID) { tab in
            if result.didUpgradeHTTPS { tab.privacyState.httpsUpgradeCount += 1 }
            tab.privacyState.cleanedParameterCount += result.removedParameterCount
        }
        return result
    }

    private func httpsUpgradeAttempt(for secureURL: URL) -> HTTPSUpgradeAttempt? {
        guard secureURL.scheme?.lowercased() == "https",
              var components = URLComponents(url: secureURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "http"
        guard let fallbackURL = components.url else { return nil }
        return HTTPSUpgradeAttempt(secureURL: secureURL, fallbackURL: fallbackURL)
    }

    private func canFallbackFromHTTPSError(_ errorCode: Int?) -> Bool {
        guard let errorCode else { return false }
        // Only retry errors that can specifically mean "this origin does not serve TLS".
        // Certificate errors (-200 ... -299) and general DNS/network failures never downgrade.
        return [-7, -100, -101, -102, -103, -104, -107, -113, -118].contains(errorCode)
    }

    private func isCertificateError(_ info: SiteSecurityInfo) -> Bool {
        info.hasCertificateError || info.certificateErrorCode != nil ||
            !info.certificateStatus.intersection(.blockingStatuses).isEmpty
    }

    private func beginHTTPFallback(_ attempt: HTTPSUpgradeAttempt, for tabID: UUID) {
        let fallbackURL = attempt.fallbackURL
        activeHTTPFallbackURLs[tabID] = fallbackURL
        beginPendingNavigation(to: fallbackURL, from: tab(withID: tabID)?.url, for: tabID)
        siteSecurityInfoByTabID.removeValue(forKey: tabID)
        mutateTab(tabID) { tab in
            tab.url = fallbackURL
            tab.title = fallbackURL.host ?? fallbackURL.absoluteString
        }
        if tabID == selectedTabID {
            addressText = addressBarText(for: fallbackURL)
            lastError = nil
        }
        recordHistory(
            url: fallbackURL,
            title: fallbackURL.host ?? fallbackURL.absoluteString,
            tabID: tabID
        )

        let previousNavigationTask = navigationCommandTasks[tabID]
        let fallbackTask = Task { [engine] in
            await previousNavigationTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await engine.execute(.loadURL(tabID: tabID, url: fallbackURL))
            } catch {
                await MainActor.run {
                    if self.pendingNavigations[tabID]?.requestedURL == fallbackURL {
                        self.pendingNavigations.removeValue(forKey: tabID)
                    }
                    self.activeHTTPFallbackURLs.removeValue(forKey: tabID)
                    self.lastError = error.localizedDescription
                }
            }
        }
        navigationCommandTasks[tabID] = fallbackTask
        scheduleSave()
    }

    private func beginPendingNavigation(
        to requestedURL: URL,
        from previousURL: URL?,
        for tabID: UUID,
        generationBaseline: UInt64? = nil
    ) {
        pendingNavigations[tabID] = PendingNavigation(
            requestedURL: requestedURL,
            previousURL: previousURL,
            generationBaseline: generationBaseline
                ?? navigationStates[tabID]?.navigationGeneration
        )
    }

    private static func navigationURLsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        if BrowserStartPage.matches(lhs), BrowserStartPage.matches(rhs) {
            return true
        }
        func normalizedComponents(for url: URL) -> URLComponents? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if components.path.isEmpty { components.path = "/" }
            if (components.scheme == "https" && components.port == 443) ||
                (components.scheme == "http" && components.port == 80) {
                components.port = nil
            }
            return components
        }

        guard let left = normalizedComponents(for: lhs),
              let right = normalizedComponents(for: rhs) else {
            return lhs.absoluteString == rhs.absoluteString
        }
        return left == right
    }

    private func mutateTab(_ tabID: UUID, _ mutation: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        mutation(&tabs[index])
    }

    private func tabID(for pane: SplitPane, in session: SplitViewSession) -> UUID {
        pane == .primary ? session.primaryTabID : session.secondaryTabID
    }

    @discardableResult
    private func swapSplitPages(focusing pane: SplitPane, selectedTabID: UUID) -> Bool {
        guard var session = splitSession,
              selectedTabID == session.primaryTabID || selectedTabID == session.secondaryTabID else {
            return false
        }
        let previousPrimaryTabID = session.primaryTabID
        session.primaryTabID = session.secondaryTabID
        session.secondaryTabID = previousPrimaryTabID
        guard tabID(for: pane, in: session) == selectedTabID else { return false }

        session.focusedPane = pane
        session.lastOpenedAt = .now
        splitSession = session
        self.selectedTabID = selectedTabID
        addressText = addressBarText(for: tab(withID: selectedTabID)?.url)
        touchTab(selectedTabID)
        rememberCurrentSplit()
        updateTabLifecycles()
        updateSplitPagePriorities(session)
        scheduleSave()
        return true
    }

    private func isValidSplit(_ session: SplitViewSession) -> Bool {
        guard session.spaceID == currentSpaceID,
              session.primaryTabID != session.secondaryTabID,
              let primary = tab(withID: session.primaryTabID),
              let secondary = tab(withID: session.secondaryTabID) else { return false }
        return !primary.isArchived && !secondary.isArchived &&
            primary.spaceID == session.spaceID && secondary.spaceID == session.spaceID
    }

    private func markSplitTabs(_ session: SplitViewSession) {
        if tab(withID: session.primaryTabID)?.isSleeping == true {
            setTabSleeping(session.primaryTabID, sleeping: false)
        }
        if tab(withID: session.secondaryTabID)?.isSleeping == true {
            setTabSleeping(session.secondaryTabID, sleeping: false)
        }
        mutateTab(session.primaryTabID) {
            $0.splitSessionID = session.id
        }
        mutateTab(session.secondaryTabID) {
            $0.splitSessionID = session.id
        }
    }

    private func activateSplit(_ session: SplitViewSession) {
        guard isValidSplit(session) else { return }
        var session = session
        // v0.8.0 起仅支持左右分屏；旧的上下分屏会话恢复为左右。
        session.orientation = .horizontal
        splitSessionsBySpace[session.spaceID] = session
        splitSession = session
        selectedTabID = tabID(for: session.focusedPane, in: session)
        addressText = addressBarText(for: currentTab?.url)
        markSplitTabs(session)
        touchTab(selectedTabID)
        updateTabLifecycles()
        updateSplitPagePriorities(session)
        scheduleSave()
    }

    private func clearSplit(in spaceID: UUID) {
        if let session = splitSession, session.spaceID == spaceID {
            mutateTab(session.primaryTabID) { $0.splitSessionID = nil }
            mutateTab(session.secondaryTabID) { $0.splitSessionID = nil }
            splitSession = nil
        } else if let session = splitSessionsBySpace[spaceID] {
            mutateTab(session.primaryTabID) { $0.splitSessionID = nil }
            mutateTab(session.secondaryTabID) { $0.splitSessionID = nil }
        }
        splitSessionsBySpace.removeValue(forKey: spaceID)
        updateTabLifecycles()
    }

    private func rememberCurrentSplit() {
        guard let splitSession else { return }
        splitSessionsBySpace[splitSession.spaceID] = splitSession
    }

    private func deactivateCurrentSplit() {
        guard let session = splitSession else { return }
        mutateTab(session.primaryTabID) { $0.splitSessionID = nil }
        mutateTab(session.secondaryTabID) { $0.splitSessionID = nil }
        splitSession = nil
        updateTabLifecycles()
    }

    private func detachTabFromSplit(_ tabID: UUID) {
        let affectedSpaceIDs = splitSessionsBySpace.compactMap { spaceID, session in
            session.primaryTabID == tabID || session.secondaryTabID == tabID ? spaceID : nil
        }
        for spaceID in affectedSpaceIDs { clearSplit(in: spaceID) }
        if let session = splitSession,
           session.primaryTabID == tabID || session.secondaryTabID == tabID {
            clearSplit(in: session.spaceID)
        }
    }

    private func isTabInAnySplit(_ tabID: UUID) -> Bool {
        if let splitSession,
           splitSession.primaryTabID == tabID || splitSession.secondaryTabID == tabID {
            return true
        }
        return splitSessionsBySpace.values.contains {
            $0.primaryTabID == tabID || $0.secondaryTabID == tabID
        }
    }

    @discardableResult
    private func replaceSplitPane(
        _ pane: SplitPane,
        with tabID: UUID,
        orientation: SplitOrientation?
    ) -> Bool {
        guard var session = splitSession,
              let replacement = tab(withID: tabID),
              !replacement.isArchived,
              replacement.spaceID == currentSpaceID,
              tabID != session.primaryTabID,
              tabID != session.secondaryTabID else { return false }

        let previouslyFocusedTabID = self.tabID(for: session.focusedPane, in: session)
        let oldTabID = pane == .primary ? session.primaryTabID : session.secondaryTabID
        mutateTab(oldTabID) { $0.splitSessionID = nil }
        if pane == .primary { session.primaryTabID = tabID }
        else { session.secondaryTabID = tabID }
        if let orientation { session.orientation = orientation }
        session.lastOpenedAt = .now
        session.focusedPane = pane
        splitSession = session
        splitSessionsBySpace[currentSpaceID] = session
        markSplitTabs(session)
        selectedTabID = tabID
        addressText = addressBarText(for: replacement.url)
        touchTab(tabID)
        updateTabLifecycles()
        updateSplitPagePriorities(
            session,
            previouslyFocusedTabID: previouslyFocusedTabID
        )
        scheduleSave()
        return true
    }

    private func touchTab(_ tabID: UUID) {
        if tab(withID: tabID)?.isSleeping == true {
            setTabSleeping(tabID, sleeping: false)
        }
        mutateTab(tabID) {
            $0.lastAccessedAt = .now
        }
    }

    private func updateFocusedPagePriorities(previouslyFocusedTabID: UUID? = nil) {
        guard let splitSession else {
            let focusedID = selectedTabID
            var unfocusedIDs: [UUID] = []
            if let previouslyFocusedTabID, previouslyFocusedTabID != focusedID {
                unfocusedIDs.append(previouslyFocusedTabID)
            }
            updatePagePriorities(focusedID: focusedID, unfocusedIDs: unfocusedIDs)
            return
        }
        updateSplitPagePriorities(
            splitSession,
            previouslyFocusedTabID: previouslyFocusedTabID
        )
    }

    private func updateSplitPagePriorities(
        _ session: SplitViewSession?,
        previouslyFocusedTabID: UUID? = nil
    ) {
        guard let session else { return }
        let focusedID = tabID(for: session.focusedPane, in: session)
        let secondaryID = tabID(for: session.focusedPane == .primary ? .secondary : .primary, in: session)
        var unfocusedIDs: [UUID] = []
        if let previouslyFocusedTabID, previouslyFocusedTabID != focusedID {
            unfocusedIDs.append(previouslyFocusedTabID)
        }
        if secondaryID != focusedID, !unfocusedIDs.contains(secondaryID) {
            unfocusedIDs.append(secondaryID)
        }
        updatePagePriorities(focusedID: focusedID, unfocusedIDs: unfocusedIDs)
    }

    private func updatePagePriorities(focusedID: UUID, unfocusedIDs: [UUID]) {
        Task { [engine] in
            for tabID in unfocusedIDs {
                try? await engine.execute(.setPagePriority(tabID: tabID, isFocused: false))
            }
            try? await engine.execute(.setPagePriority(tabID: focusedID, isFocused: true))
        }
    }

    private func updateTabLifecycles() {
        let splitIDs = Set([splitSession?.primaryTabID, splitSession?.secondaryTabID].compactMap { $0 })
        for index in tabs.indices {
            if tabs[index].isArchived {
                tabs[index].lifecycle = .archived
            } else if tabs[index].isSleeping {
                tabs[index].lifecycle = .sleeping
            } else if splitIDs.contains(tabs[index].id) {
                tabs[index].lifecycle = .splitActive
            } else if tabs[index].id == selectedTabID {
                tabs[index].lifecycle = .active
            } else if tabs[index].lifecycle != .crashed {
                tabs[index].lifecycle = .background
            }
        }
    }

    private func makeSnapshot() -> BrowserSessionSnapshot {
        var snapshotTabs = tabs
        var snapshotPaneStates = makeSplitPaneStates()
        for (tabID, downloadURL) in nonRestorableDownloadURLsByTabID {
            guard let index = snapshotTabs.firstIndex(where: { $0.id == tabID }) else { continue }
            let restorableTab = Self.restorableTabAfterDownload(
                snapshotTabs[index],
                nonRestorableURL: downloadURL
            )
            guard restorableTab != snapshotTabs[index] else { continue }
            snapshotTabs[index] = restorableTab
            if let paneIndex = snapshotPaneStates.firstIndex(where: { $0.tabID == tabID }) {
                snapshotPaneStates[paneIndex].navigation = NavigationState(
                    url: BrowserStartPage.url,
                    title: BrowserStartPage.title,
                    isLoading: false,
                    loadingProgress: 1,
                    zoomLevel: snapshotPaneStates[paneIndex].navigation.zoomLevel
                )
            }
        }
        return Self.userVisibleSnapshot(BrowserSessionSnapshot(
            schemaVersion: BrowserSessionSnapshot.schemaVersion,
            windowID: windowID,
            spaces: spaces,
            groups: groups,
            tabs: snapshotTabs,
            currentSpaceID: currentSpaceID,
            selectedTabID: selectedTabID,
            splitSession: splitSession,
            splitPaneStates: snapshotPaneStates,
            splitSessionsBySpace: Array(splitSessionsBySpace.values),
            savedSplitCompositions: savedSplitCompositions,
            savedAt: .now
        ))
    }

    static func restorableTabAfterDownload(
        _ tab: BrowserTab,
        nonRestorableURL: URL?
    ) -> BrowserTab {
        guard let tabURL = tab.url, let nonRestorableURL,
              Self.navigationURLsMatch(tabURL, nonRestorableURL) else { return tab }
        var restorableTab = tab
        restorableTab.url = BrowserStartPage.url
        restorableTab.title = BrowserStartPage.title
        restorableTab.faviconURL = nil
        restorableTab.isLoading = false
        restorableTab.loadingProgress = 1
        return restorableTab
    }

    private func makeSplitPaneStates() -> [SplitPaneState] {
        guard let session = splitSession else { return [] }
        return [
            SplitPaneState(
                pane: .primary,
                tabID: session.primaryTabID,
                navigation: navigationStates[session.primaryTabID] ?? navigation(for: session.primaryTabID),
                scrollPosition: 0,
                isMuted: tab(withID: session.primaryTabID)?.isMuted ?? false
            ),
            SplitPaneState(
                pane: .secondary,
                tabID: session.secondaryTabID,
                navigation: navigationStates[session.secondaryTabID] ?? navigation(for: session.secondaryTabID),
                scrollPosition: 0,
                isMuted: tab(withID: session.secondaryTabID)?.isMuted ?? false
            )
        ]
    }

    private func navigation(for tabID: UUID) -> NavigationState {
        let tab = tab(withID: tabID)
        return NavigationState(
            url: tab?.url,
            title: tab?.title ?? "",
            isLoading: false,
            loadingProgress: 1,
            zoomLevel: 1
        )
    }

    private func scheduleSave() {
        guard !profile.isPrivate, !isPreparingApplicationTermination else { return }
        pendingSave?.cancel()
        let snapshot = makeSnapshot()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            enqueueSessionSave(snapshot, reportsErrors: true)
        }
    }

    private func enqueueSessionSave(
        _ snapshot: BrowserSessionSnapshot,
        reportsErrors: Bool
    ) {
        let previousPersistenceTask = sessionPersistenceTail
        let persistence = persistence
        sessionPersistenceTail = Task { @MainActor [weak self] in
            await previousPersistenceTask?.value
            do {
                try await persistence.save(snapshot)
            } catch {
                guard reportsErrors else { return }
                self?.lastError = "会话保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func restore(_ snapshot: BrowserSessionSnapshot) {
        guard !snapshot.spaces.isEmpty, !snapshot.tabs.isEmpty,
              snapshot.spaces.contains(where: { $0.id == snapshot.currentSpaceID }),
              snapshot.tabs.contains(where: { $0.id == snapshot.selectedTabID }) else { return }
        let oldTabIDs = Set(tabs.map(\.id))
        let restoredTabIDs = Set(snapshot.tabs.map(\.id))
        for tabID in oldTabIDs.subtracting(restoredTabIDs) {
            pageSuspensionTasks.removeValue(forKey: tabID)?.cancel()
            Task { [engine] in try? await engine.execute(.destroyPage(tabID: tabID)) }
        }
        stopAccessingAllDownloadDirectories()
        spaces = snapshot.spaces
        downloadDirectoryURLsBySpace.removeAll()
        groups = snapshot.groups
        faviconDataByTabID.removeAll()
        faviconCacheOrder.removeAll()
        navigationStates.removeAll()
        pendingNavigations.removeAll()
        nonRestorableDownloadURLsByTabID.removeAll()
        siteSecurityInfoByTabID.removeAll()
        tabs = snapshot.tabs
        for index in tabs.indices {
            tabs[index].isLoading = false
            tabs[index].loadingProgress = 1
            tabs[index].privacyState.httpsUpgradeEnabled = preferences.httpsUpgradeEnabled
            if !preferences.automaticTabSleeping, tabs[index].isSleeping {
                tabs[index].isSleeping = false
                if tabs[index].lifecycle == .sleeping {
                    tabs[index].lifecycle = .background
                }
            }
        }
        currentSpaceID = snapshot.currentSpaceID
        selectedTabID = snapshot.selectedTabID
        if var split = snapshot.splitSession,
           restoredTabIDs.contains(split.primaryTabID),
           restoredTabIDs.contains(split.secondaryTabID) {
            split.orientation = .horizontal
            splitSession = split
        } else {
            splitSession = nil
        }
        splitSessionsBySpace = Dictionary(
            uniqueKeysWithValues: snapshot.splitSessionsBySpace
                .filter { restoredTabIDs.contains($0.primaryTabID) && restoredTabIDs.contains($0.secondaryTabID) }
                .map { session in
                    var session = session
                    session.orientation = .horizontal
                    return (session.spaceID, session)
                }
        )
        if let splitSession { splitSessionsBySpace[splitSession.spaceID] = splitSession }
        savedSplitCompositions = snapshot.savedSplitCompositions.filter {
            restoredTabIDs.contains($0.primaryTabID) && restoredTabIDs.contains($0.secondaryTabID)
        }
        for paneState in snapshot.splitPaneStates {
            var restoredNavigation = paneState.navigation
            restoredNavigation.canGoBack = false
            restoredNavigation.canGoForward = false
            restoredNavigation.isLoading = false
            restoredNavigation.loadingProgress = 1
            restoredNavigation.navigationGeneration = nil
            navigationStates[paneState.tabID] = restoredNavigation
            mutateTab(paneState.tabID) { $0.isMuted = paneState.isMuted }
        }
        if let splitSession { markSplitTabs(splitSession) }
        addressText = addressBarText(for: currentTab?.url)
        createEnginePages(for: Array(restoredTabIDs))
        for tab in tabs {
            let isSuspended = tab.isArchived || tab.isSleeping
            schedulePageSuspension(
                tabID: tab.id,
                isSuspended: isSuspended,
                isFocused: !isSuspended && tab.id == selectedTabID
            )
        }
        synchronizeBookmarkFlags()
        updateTabLifecycles()
    }

    private func finishSessionRestoration() {
        guard isRestoringSession else { return }
        isRestoringSession = false
        addressText = addressBarText(for: currentTab?.url)
    }

    private func finishSitePrivacyPolicyLoading() {
        guard !isSitePrivacyPolicyReady, !didTearDownWindow else { return }
        isSitePrivacyPolicyReady = true
        createEnginePages(for: tabs.map(\.id))
        let deferredNavigations = deferredNavigationURLs
        deferredNavigationURLs.removeAll()
        for (tabID, url) in deferredNavigations
        where tab(withID: tabID) != nil && pendingNavigations[tabID]?.requestedURL == url {
            enqueueNavigation(to: url, for: tabID)
        }
        let deferredSuspensions = deferredPageSuspensions
        deferredPageSuspensions.removeAll()
        for tab in tabs {
            guard let suspension = deferredSuspensions[tab.id] else { continue }
            schedulePageSuspension(
                tabID: tab.id,
                isSuspended: suspension.isSuspended,
                isFocused: suspension.isFocused
            )
        }
    }


    private func synchronizeBookmarkFlags() {
        let bookmarkedURLs = Set(bookmarks.map(\.url))
        for index in tabs.indices {
            tabs[index].isFavorite = tabs[index].url.map(bookmarkedURLs.contains) ?? false
        }
    }

    private func createEnginePages(for tabIDs: [UUID]) {
        guard !didTearDownWindow, isSitePrivacyPolicyReady else { return }
        for tabID in tabIDs {
            guard var tab = tab(withID: tabID) else { continue }
            if let url = tab.url {
                applySitePrivacyPolicy(for: url, to: tabID)
                guard let configuredTab = self.tab(withID: tabID) else { continue }
                tab = configuredTab
            }
            let directoryURL = downloadDirectoryURL(for: tab.spaceID)
            let initialURL: URL? = {
                guard !BrowserStartPage.matches(tab.url),
                      !RexExtensionsPage.matches(tab.url),
                      let url = tab.url else { return nil }
                if let resource = RexExtensionResourceURL(rexURL: url) {
                    guard !profile.isPrivate,
                          extensionsStore.runnablePackage(
                              runtimeID: resource.runtimeID
                          ) != nil else {
                        return nil
                    }
                }
                return url
            }()
            let privacy = tab.privacyState
            let blockThirdPartyCookies = preferences.blockThirdPartyCookies
            pageSetupTasks[tabID]?.cancel()
            pageSetupTasks[tabID] = Task { @MainActor [weak self, engine, profile] in
                guard !Task.isCancelled else { return }
                try? await engine.execute(.createPage(tabID: tabID, profile: profile))
                guard !Task.isCancelled else { return }
                try? await engine.execute(.setDownloadDirectory(
                    tabID: tabID,
                    directoryURL: directoryURL
                ))
                guard !Task.isCancelled else { return }
                try? await engine.execute(.setPrivacyPolicy(
                    tabID: tabID,
                    enabled: privacy.isEnabled,
                    level: privacy.level,
                    fingerprintProtection: privacy.fingerprintProtectionEnabled,
                    blockThirdPartyCookies: blockThirdPartyCookies
                ))
                if !Task.isCancelled,
                   let initialURL,
                   self?.shouldLoadInitialURL(initialURL, for: tabID) == true {
                    try? await engine.execute(.loadURL(tabID: tabID, url: initialURL))
                }
            }
        }
    }

    private func schedulePageSuspension(
        tabID: UUID,
        isSuspended: Bool,
        isFocused: Bool
    ) {
        guard isSitePrivacyPolicyReady else {
            deferredPageSuspensions[tabID] = (isSuspended, isFocused)
            return
        }
        deferredPageSuspensions.removeValue(forKey: tabID)
        pageSuspensionTasks[tabID]?.cancel()
        let setupTask = pageSetupTasks[tabID]
        pageSuspensionTasks[tabID] = Task { @MainActor [weak self, engine] in
            if let setupTask { await setupTask.value }
            guard !Task.isCancelled,
                  let self,
                  let tab = self.tab(withID: tabID),
                  (tab.isArchived || tab.isSleeping) == isSuspended else { return }
            try? await engine.execute(.setPageSuspended(
                tabID: tabID,
                isSuspended: isSuspended
            ))
            guard !Task.isCancelled else { return }
            try? await engine.execute(.setPagePriority(tabID: tabID, isFocused: isFocused))
        }
    }

    private func shouldLoadInitialURL(_ initialURL: URL, for tabID: UUID) -> Bool {
        guard pendingNavigations[tabID] == nil,
              let currentURL = tab(withID: tabID)?.url else { return false }
        return Self.navigationURLsMatch(currentURL, initialURL)
    }

    private func configureDownloadDirectories(for tabIDs: [UUID]) {
        for tabID in tabIDs {
            guard let tab = tab(withID: tabID) else { continue }
            let directoryURL = downloadDirectoryURL(for: tab.spaceID)
            Task { [engine] in
                try? await engine.execute(.setDownloadDirectory(
                    tabID: tabID,
                    directoryURL: directoryURL
                ))
            }
        }
    }

    private func downloadDirectoryURL(for spaceID: UUID) -> URL? {
        if let cachedURL = downloadDirectoryURLsBySpace[spaceID] {
            return cachedURL
        }
        guard let bookmark = spaces.first(where: { $0.id == spaceID })?.downloadDirectoryBookmark else {
            return Self.defaultDownloadDirectory()
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            return Self.defaultDownloadDirectory()
        }
        if url.startAccessingSecurityScopedResource() {
            securityScopedDownloadDirectoryURLsBySpace[spaceID] = url
        }
        downloadDirectoryURLsBySpace[spaceID] = url
        return url
    }

    private func stopAccessingDownloadDirectory(for spaceID: UUID) {
        guard let url = securityScopedDownloadDirectoryURLsBySpace.removeValue(forKey: spaceID) else {
            return
        }
        url.stopAccessingSecurityScopedResource()
    }

    private func stopAccessingAllDownloadDirectories() {
        for url in securityScopedDownloadDirectoryURLsBySpace.values {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedDownloadDirectoryURLsBySpace.removeAll()
    }

    private func recordHistory(url: URL, title: String, tabID: UUID) {
        guard !profile.isPrivate else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let entry = BrowserHistoryEntry(
            url: url, title: title, tabID: tabID, spaceID: tab(withID: tabID)?.spaceID
        )
        history.insert(entry, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        Task { [persistence] in try? await persistence.addHistory(entry) }
    }

    @discardableResult
    private func openPopup(url: URL, sourceTabID: UUID, foreground: Bool) -> UUID? {
        guard let visibleURL = Self.userVisibleURL(url),
              let sourceIndex = tabs.firstIndex(where: { $0.id == sourceTabID }) else {
            return nil
        }
        if profile.isPrivate,
           RexExtensionResourceURL(rexURL: visibleURL) != nil {
            return nil
        }
        let source = tabs[sourceIndex]
        if foreground, source.spaceID != currentSpaceID {
            switchSpace(to: source.spaceID)
        }
        let destinationPolicy = privacyPolicyHost(for: visibleURL).map { host in
            sitePrivacyPolicies.first(where: {
                $0.profileID == profile.id && $0.host == host
            }) ?? defaultSitePrivacyPolicy(forHost: host, spaceID: source.spaceID)
        }
        let policyResult = PrivacyURLPolicy.apply(
            to: visibleURL,
            isEnabled: destinationPolicy?.protectionEnabled
                ?? source.privacyState.isEnabled,
            upgradeHTTPS: source.privacyState.httpsUpgradeEnabled
        )
        let resolvedURL = policyResult.url
        var popup = BrowserTab(
            url: resolvedURL,
            title: resolvedURL.host ?? "新标签页",
            spaceID: source.spaceID,
            groupID: source.groupID
        )
        if let destinationPolicy {
            popup.privacyState.isEnabled = destinationPolicy.protectionEnabled
            popup.privacyState.level = destinationPolicy.level
            popup.privacyState.fingerprintProtectionEnabled =
                destinationPolicy.fingerprintProtectionEnabled
        }
        popup.privacyState.httpsUpgradeCount = policyResult.didUpgradeHTTPS ? 1 : 0
        popup.privacyState.cleanedParameterCount = policyResult.removedParameterCount
        tabs.insert(popup, at: min(sourceIndex + 1, tabs.endIndex))
        if policyResult.didUpgradeHTTPS,
           let attempt = httpsUpgradeAttempt(for: resolvedURL) {
            httpsUpgradeAttempts[popup.id] = attempt
        }
        insertTab(popup.id, intoGroup: source.groupID, after: source.id)
        createEnginePages(for: [popup.id])
        recordHistory(url: resolvedURL, title: popup.title, tabID: popup.id)
        if foreground {
            selectTab(popup.id)
        } else {
            updateTabLifecycles()
        }
        scheduleSave()
        return popup.id
    }

    private func apply(_ event: BrowserEvent) {
        switch event {
        case let .pageCreated(tabID):
            guard tab(withID: tabID) != nil else { return }
        case let .pageFocused(tabID):
            guard tab(withID: tabID) != nil else { return }
            if let splitSession {
                if splitSession.primaryTabID == tabID {
                    focus(.primary)
                } else if splitSession.secondaryTabID == tabID {
                    focus(.secondary)
                }
            } else if selectedTabID != tabID {
                selectTab(tabID)
            }
        case let .navigationChanged(tabID, state):
            guard tab(withID: tabID) != nil else { return }
            if let incomingGeneration = state.navigationGeneration,
               let currentGeneration = navigationStates[tabID]?.navigationGeneration,
               incomingGeneration < currentGeneration {
                return
            }
            var navigationState = Self.userVisibleNavigationState(state)
            if state.url != nil, navigationState.url == nil {
                return
            }
            if let resource = navigationState.url.flatMap(RexExtensionResourceURL.init(rexURL:)) {
                guard !profile.isPrivate,
                      extensionsStore.runnablePackage(
                          runtimeID: resource.runtimeID
                      ) != nil else {
                    return
                }
            }
            if let pending = pendingNavigations[tabID] {
                let matchesRequest = navigationState.url.map {
                    Self.navigationURLsMatch($0, pending.requestedURL)
                } ?? false
                let movedAwayFromPrevious = navigationState.url.map { eventURL in
                    pending.previousURL.map {
                        !Self.navigationURLsMatch(eventURL, $0)
                    } ?? true
                } ?? false
                if let baseline = pending.generationBaseline,
                   let incomingGeneration = navigationState.navigationGeneration,
                   incomingGeneration <= baseline,
                   !matchesRequest {
                    return
                }
                let isNewGeneration = navigationState.navigationGeneration.map { generation in
                    pending.generationBaseline.map { generation > $0 } ?? false
                } ?? false
                if matchesRequest || movedAwayFromPrevious ||
                    (isNewGeneration && !navigationState.isLoading) {
                    pendingNavigations.removeValue(forKey: tabID)
                } else {
                    // Chromium has started the requested navigation but has not
                    // committed its address yet. Keep the submitted address
                    // visible while still accepting Chromium's live load state.
                    navigationState.url = pending.requestedURL
                }
            }
            if navigationState.url == nil {
                navigationState.url = tab(withID: tabID)?.url
            }
            if let nonRestorableURL = nonRestorableDownloadURLsByTabID[tabID],
               navigationState.url.map({ !Self.navigationURLsMatch($0, nonRestorableURL) }) == true {
                nonRestorableDownloadURLsByTabID.removeValue(forKey: tabID)
            }
            if let url = navigationState.url {
                let isHTTPFallback = activeHTTPFallbackURLs[tabID].map {
                    Self.navigationURLsMatch($0, url)
                } ?? false
                let policyResult = applyPrivacyURLPolicy(
                    to: url,
                    tabID: tabID,
                    allowHTTPSUpgrade: !isHTTPFallback
                )
                if policyResult.didChange {
                    let policySourceURL = navigationState.url
                    if isHTTPFallback {
                        activeHTTPFallbackURLs[tabID] = policyResult.url
                    }
                    navigationState.url = policyResult.url
                    beginPendingNavigation(
                        to: policyResult.url,
                        from: policySourceURL,
                        for: tabID,
                        generationBaseline: navigationState.navigationGeneration
                    )
                    Task { [engine] in
                        do {
                            try await engine.execute(.loadURL(tabID: tabID, url: policyResult.url))
                        } catch {
                            await MainActor.run {
                                self.pendingNavigations.removeValue(forKey: tabID)
                                self.lastError = error.localizedDescription
                            }
                        }
                    }
                }
            }
            if !navigationState.isLoading {
                if let completedURL = navigationState.url,
                   let attempt = httpsUpgradeAttempts[tabID],
                   Self.navigationURLsMatch(completedURL, attempt.secureURL) {
                    httpsUpgradeAttempts.removeValue(forKey: tabID)
                }
                if let completedURL = navigationState.url,
                   let fallbackURL = activeHTTPFallbackURLs[tabID],
                   Self.navigationURLsMatch(completedURL, fallbackURL) {
                    activeHTTPFallbackURLs.removeValue(forKey: tabID)
                }
            }
            navigationStates[tabID] = navigationState
            mutateTab(tabID) { tab in
                tab.url = navigationState.url ?? tab.url
                tab.isLoading = navigationState.isLoading
                tab.loadingProgress = navigationState.loadingProgress
                if tab.lifecycle == .crashed { tab.lifecycle = .active }
            }
            if tabID == selectedTabID { addressText = addressBarText(for: navigationState.url) }
            scheduleSave()
        case let .siteSecurityChanged(tabID, info):
            guard let tab = tab(withID: tabID) else { return }
            let info = Self.userVisibleSiteSecurityInfo(info)
            if let current = siteSecurityInfoByTabID[tabID] {
                guard info.navigationGeneration >= current.navigationGeneration else { return }
                if info.navigationGeneration == current.navigationGeneration,
                   !current.isPending, info.isPending {
                    return
                }
                if info.navigationGeneration == current.navigationGeneration,
                   isCertificateError(current), !isCertificateError(info) {
                    return
                }
            }
            if !info.isPending, let eventURL = info.url, let tabURL = tab.url,
               !Self.navigationURLsMatch(eventURL, tabURL) {
                return
            }
            guard siteSecurityInfoByTabID[tabID] != info else { return }
            siteSecurityInfoByTabID[tabID] = info
        case let .titleChanged(tabID, title):
            let title = Self.userVisibleTitle(title)
            guard pendingNavigations[tabID] == nil,
                  !title.isEmpty, tab(withID: tabID) != nil else { return }
            mutateTab(tabID) { $0.title = title }
            scheduleSave()
        case let .faviconChanged(tabID, url, imageData):
            guard tab(withID: tabID) != nil else { return }
            mutateTab(tabID) { $0.faviconURL = Self.userVisibleURL(url) }
            if let imageData, !imageData.isEmpty {
                cacheFavicon(imageData, for: tabID)
            } else {
                faviconDataByTabID.removeValue(forKey: tabID)
                faviconCacheOrder.removeAll { $0 == tabID }
            }
        case let .audioStateChanged(tabID, isPlaying):
            mutateTab(tabID) { $0.isPlayingAudio = isPlaying }
        case let .mediaAccessChanged(tabID, isActive):
            guard tab(withID: tabID) != nil else { return }
            if isActive {
                activeMediaTabIDs.insert(tabID)
            } else {
                activeMediaTabIDs.remove(tabID)
            }
        case let .popupRequested(tabID, url, foreground):
            openPopup(url: url, sourceTabID: tabID, foreground: foreground)
        case let .splitLinkRequested(tabID, url):
            guard let secondaryID = openPopup(
                url: url,
                sourceTabID: tabID,
                foreground: false
            ) else { return }
            if tab(withID: tabID)?.spaceID == currentSpaceID {
                beginSplit(primaryTabID: tabID, secondaryTabID: secondaryID)
            }
        case let .contextSearchRequested(tabID, text):
            guard let url = preferences.searchEngine.searchURL(for: text) else { return }
            openPopup(url: url, sourceTabID: tabID, foreground: true)
        case let .developerToolsRequested(tabID, inspectX, inspectY):
            if inspectX < 0 && inspectY < 0 && developerToolsTabID == tabID {
                closeDeveloperTools()
            } else {
                presentDeveloperTools(for: tabID, inspectX: inspectX, inspectY: inspectY)
            }
        case let .privacyStateChanged(tabID, state):
            mutateTab(tabID) { $0.privacyState = state }
        case let .resourceBlocked(tabID, resource):
            guard tab(withID: tabID) != nil else { return }
            mutateTab(tabID) { tab in
                if let index = tab.privacyState.resources.firstIndex(where: {
                    $0.category == resource.category
                        && $0.host == resource.host
                }) {
                    tab.privacyState.resources[index].count += resource.count
                    tab.privacyState.resources[index].timestamp = resource.timestamp
                } else {
                    tab.privacyState.resources.append(resource)
                }
                tab.privacyState.blockedCount += resource.count
            }
            scheduleSave()
        case let .permissionRequested(tabID, request):
            guard tab(withID: tabID) != nil else { return }
            let request = Self.userVisiblePermissionRequest(request)
            let prompt = WebsitePermissionPrompt(tabID: tabID, request: request)
            if let decision = automaticPermissionDecision(for: prompt) {
                Task { [engine] in
                    try? await engine.execute(.respondToPermission(
                        requestID: request.id,
                        decision: decision
                    ))
                }
            } else if !pendingPermissionPrompts.contains(where: { $0.id == request.id }) {
                pendingPermissionPrompts.append(prompt)
            }
        case let .permissionRequestDismissed(tabID, requestID):
            pendingPermissionPrompts.removeAll { $0.tabID == tabID && $0.id == requestID }
        case let .downloadUpdated(tabID, download):
            guard tab(withID: tabID) != nil,
                  let download = Self.userVisibleDownload(download) else {
                return
            }
            suppressedDownloadIDs.remove(download.id)
            let isNewDownload = !downloads.contains { $0.id == download.id }
            retryingDownloadIDs.remove(download.id)
            if let tabURL = tab(withID: tabID)?.url,
               [download.sourceURL, download.originalURL].compactMap({ $0 }).contains(where: {
                   Self.navigationURLsMatch(tabURL, $0)
               }) {
                nonRestorableDownloadURLsByTabID[tabID] = tabURL
                scheduleSave()
            }
            if download.canCancel {
                activeDownloadTabIDsByDownloadID[download.id] = tabID
            } else {
                activeDownloadTabIDsByDownloadID.removeValue(forKey: download.id)
            }
            downloads.removeAll { $0.id == download.id }
            downloads.insert(download, at: 0)
            if isNewDownload {
                downloadPanelRequest &+= 1
            }
            if !profile.isPrivate {
                Task { [persistence] in try? await persistence.saveDownload(download) }
            }
        case let .navigationFailed(tabID, failedURL, errorCode, reason):
            guard let tab = tab(withID: tabID) else { return }
            let failedURL = Self.userVisibleURL(failedURL)
            let reason = Self.userVisibleTitle(reason)
            if let failedURL {
                let relevantURLs = [
                    pendingNavigations[tabID]?.requestedURL,
                    httpsUpgradeAttempts[tabID]?.secureURL,
                    activeHTTPFallbackURLs[tabID],
                    tab.url
                ].compactMap { $0 }
                guard relevantURLs.contains(where: { Self.navigationURLsMatch($0, failedURL) }) else {
                    return
                }
            }

            if let attempt = httpsUpgradeAttempts[tabID] {
                let failedUpgrade = failedURL.map {
                    Self.navigationURLsMatch($0, attempt.secureURL)
                } ?? pendingNavigations[tabID].map {
                    Self.navigationURLsMatch($0.requestedURL, attempt.secureURL)
                } ?? false
                if failedUpgrade {
                    httpsUpgradeAttempts.removeValue(forKey: tabID)
                    if canFallbackFromHTTPSError(errorCode) {
                        beginHTTPFallback(attempt, for: tabID)
                        return
                    }
                }
            }

            if let fallbackURL = activeHTTPFallbackURLs[tabID],
               failedURL == nil || failedURL.map({ Self.navigationURLsMatch($0, fallbackURL) }) == true {
                activeHTTPFallbackURLs.removeValue(forKey: tabID)
            }
            if failedURL == nil || failedURL.map({ failedURL in
                pendingNavigations[tabID].map {
                    Self.navigationURLsMatch($0.requestedURL, failedURL)
                } ?? false
            }) == true {
                pendingNavigations.removeValue(forKey: tabID)
            }
            if var navigationState = navigationStates[tabID] {
                navigationState.isLoading = false
                navigationStates[tabID] = navigationState
            }
            mutateTab(tabID) { tab in
                tab.isLoading = false
                tab.loadingProgress = 0
            }
            if tabID == selectedTabID { lastError = reason }
        case let .pageCrashed(tabID, reason):
            guard tab(withID: tabID) != nil else { return }
            let reason = Self.userVisibleTitle(reason)
            activeMediaTabIDs.remove(tabID)
            pendingNavigations.removeValue(forKey: tabID)
            httpsUpgradeAttempts.removeValue(forKey: tabID)
            activeHTTPFallbackURLs.removeValue(forKey: tabID)
            siteSecurityInfoByTabID.removeValue(forKey: tabID)
            mutateTab(tabID) { tab in
                tab.lifecycle = .crashed
                tab.isLoading = false
            }
            if tabID == selectedTabID { lastError = reason }
        case let .pageClosed(tabID):
            pageSuspensionTasks.removeValue(forKey: tabID)?.cancel()
            activeDownloadTabIDsByDownloadID = activeDownloadTabIDsByDownloadID.filter {
                $0.value != tabID
            }
            activeMediaTabIDs.remove(tabID)
            pendingNavigations.removeValue(forKey: tabID)
            httpsUpgradeAttempts.removeValue(forKey: tabID)
            activeHTTPFallbackURLs.removeValue(forKey: tabID)
            navigationStates.removeValue(forKey: tabID)
            siteSecurityInfoByTabID.removeValue(forKey: tabID)
            if developerToolsTabID == tabID {
                closeDeveloperTools()
            }
        }
    }

    @discardableResult
    private func replacePermission(_ permission: WebsitePermission) -> WebsitePermission? {
        let replacedPermission = permissions.first {
            $0.profileID == permission.profileID &&
                $0.topLevelOrigin == permission.topLevelOrigin &&
                $0.requestingOrigin == permission.requestingOrigin &&
                $0.kind == permission.kind
        }
        permissions.removeAll {
            $0.profileID == permission.profileID &&
                $0.topLevelOrigin == permission.topLevelOrigin &&
                $0.requestingOrigin == permission.requestingOrigin &&
                $0.kind == permission.kind
        }
        permissions.insert(permission, at: 0)
        return replacedPermission
    }

    private nonisolated static func permissionScope(_ permission: WebsitePermission) -> String {
        [
            permission.profileID.uuidString,
            permission.topLevelOrigin,
            permission.requestingOrigin,
            permission.kind.rawValue
        ].joined(separator: "\u{1F}")
    }

    private func automaticPermissionDecision(
        for prompt: WebsitePermissionPrompt,
        now: Date = .now
    ) -> PermissionDecision? {
        let matching = prompt.request.kinds.compactMap { kind in
            permissions.first {
                $0.profileID == profile.id &&
                    $0.topLevelOrigin == prompt.request.topLevelOrigin &&
                    $0.requestingOrigin == prompt.request.requestingOrigin &&
                    $0.kind == kind &&
                    ($0.expiresAt == nil || $0.expiresAt! > now) &&
                    ($0.tabID == nil || $0.tabID == prompt.tabID)
            }
        }
        guard matching.count == prompt.request.kinds.count else { return nil }
        if matching.contains(where: { $0.decision == .blockAlways }) { return .blockAlways }
        if matching.allSatisfy({ [.allowAlways, .revokeOnTabClose].contains($0.decision) }) {
            return .allowOnce
        }
        return nil
    }

    private func origin(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func cacheFavicon(_ data: Data, for tabID: UUID) {
        faviconDataByTabID[tabID] = data
        faviconCacheOrder.removeAll { $0 == tabID }
        faviconCacheOrder.append(tabID)
        while faviconCacheOrder.count > 128 {
            let evictedID = faviconCacheOrder.removeFirst()
            faviconDataByTabID.removeValue(forKey: evictedID)
        }
    }
}

private struct BrowserExtensionRuntimeSyncError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
