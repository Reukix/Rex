import AppKit
import Combine
import SwiftUI

@MainActor
enum RexApplicationLifecycle {
    private(set) static var isTerminating = false

    static func beginTermination() {
        isTerminating = true
    }
}

struct RexWindowSessionFlushReport: Sendable {
    let savedWindowIDs: Set<UUID>
    let failedWindows: [UUID: String]
    let skippedPrivateWindowIDs: Set<UUID>
}

@MainActor
final class RexActiveWindowSessionRegistry {
    static let shared = RexActiveWindowSessionRegistry()

    private final class WeakStore {
        weak var value: BrowserStore?

        init(_ value: BrowserStore) {
            self.value = value
        }
    }

    private var storesByWindowID: [UUID: WeakStore] = [:]
    private var activeStandardWindowID: UUID?
    private var pendingExternalURLs: [URL] = []

    func register(_ store: BrowserStore) {
        storesByWindowID[store.windowID] = WeakStore(store)
        guard !store.profile.isPrivate else { return }
        if activeStandardWindowID == nil {
            activeStandardWindowID = store.windowID
        }
        routePendingExternalURLsIfPossible()
    }

    func unregister(_ store: BrowserStore) {
        guard storesByWindowID[store.windowID]?.value === store else { return }
        storesByWindowID.removeValue(forKey: store.windowID)
        if activeStandardWindowID == store.windowID {
            activeStandardWindowID = nil
        }
    }

    func markActive(_ store: BrowserStore) {
        guard !store.profile.isPrivate,
              storesByWindowID[store.windowID]?.value === store else { return }
        activeStandardWindowID = store.windowID
    }

    func openExternalURLs(_ urls: [URL]) {
        let webURLs = urls.filter(Self.isSupportedExternalURL)
        guard !webURLs.isEmpty else { return }
        pendingExternalURLs.append(contentsOf: webURLs)
        routePendingExternalURLsIfPossible()
    }

    var hasPendingExternalURLs: Bool {
        !pendingExternalURLs.isEmpty
    }

    func flushStandardWindowSessionsForApplicationTermination() async
        -> RexWindowSessionFlushReport {
        storesByWindowID = storesByWindowID.filter { $0.value.value != nil }
        let activeStores = storesByWindowID.values.compactMap(\.value)
        let privateWindowIDs = Set(activeStores.filter(\.profile.isPrivate).map(\.windowID))
        let standardStores = activeStores
            .filter { !$0.profile.isPrivate }
            .sorted { $0.windowID.uuidString < $1.windowID.uuidString }

        var savedWindowIDs = Set<UUID>()
        var failedWindows: [UUID: String] = [:]
        for store in standardStores {
            if Task.isCancelled { break }
            do {
                try await store.persistLatestSessionSnapshotForApplicationTermination()
                savedWindowIDs.insert(store.windowID)
            } catch is CancellationError {
                break
            } catch {
                failedWindows[store.windowID] = error.localizedDescription
            }
        }
        return RexWindowSessionFlushReport(
            savedWindowIDs: savedWindowIDs,
            failedWindows: failedWindows,
            skippedPrivateWindowIDs: privateWindowIDs
        )
    }

    private func routePendingExternalURLsIfPossible() {
        storesByWindowID = storesByWindowID.filter { $0.value.value != nil }
        guard !pendingExternalURLs.isEmpty,
              let store = preferredStandardStore() else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        store.openExternalURLs(urls)
    }

    private func preferredStandardStore() -> BrowserStore? {
        if let activeStandardWindowID,
           let store = storesByWindowID[activeStandardWindowID]?.value,
           !store.profile.isPrivate {
            return store
        }
        return storesByWindowID.values
            .compactMap(\.value)
            .filter { !$0.profile.isPrivate }
            .sorted { $0.windowID.uuidString < $1.windowID.uuidString }
            .first
    }

    private static func isSupportedExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

@MainActor
final class RexWindowCoordinator: ObservableObject {
    let persistence: BrowserSQLitePersistence
    let primaryWindowID: UUID
    let preferences: BrowserPreferences

    private var didRestoreWindows = false
    private var openedWindowIDs = Set<UUID>()

    init(
        persistence: BrowserSQLitePersistence = BrowserSQLitePersistence(),
        preferences: BrowserPreferences = .shared
    ) {
        self.persistence = persistence
        self.preferences = preferences
        let defaultsKey = "Rex.primaryWindowID"
        if RexQAEnvironment.isIsolated {
            primaryWindowID = UUID()
            return
        }
        if let rawID = UserDefaults.standard.string(forKey: defaultsKey),
           let savedID = UUID(uuidString: rawID) {
            primaryWindowID = savedID
        } else {
            let newID = UUID()
            primaryWindowID = newID
            UserDefaults.standard.set(newID.uuidString, forKey: defaultsKey)
        }
    }

    func restoreOtherWindows(using openWindow: OpenWindowAction) {
        guard !didRestoreWindows else { return }
        didRestoreWindows = true
        // When Rex is the default browser and another app opens a link, the
        // external URL arrives around the same time the primary window appears.
        // Restoring previous-session windows in that launch path stacks many
        // windows on top of the one tab the user actually wanted to open, so
        // skip session restoration while an external URL is pending.
        guard !RexActiveWindowSessionRegistry.shared.hasPendingExternalURLs,
              preferences.restorePreviousSession else { return }
        let persistence = persistence
        let primaryWindowID = primaryWindowID
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-check after the async gap: an external URL may have arrived
            // between the synchronous guard above and the database load.
            guard !RexActiveWindowSessionRegistry.shared.hasPendingExternalURLs else { return }
            do {
                let sessions = try await persistence.loadAllWindows()
                for session in sessions
                where session.id != primaryWindowID
                    && !openedWindowIDs.contains(session.id) {
                    openWindow(id: "browser", value: session.id)
                    openedWindowIDs.insert(session.id)
                }
            } catch {
                // The primary window remains usable with its in-memory defaults.
            }
        }
    }

    func registerNewWindow(_ windowID: UUID) {
        openedWindowIDs.insert(windowID)
    }

    func unregisterWindow(_ windowID: UUID) {
        openedWindowIDs.remove(windowID)
    }

    func shouldRemovePersistedSession(
        for windowID: UUID,
        profile: BrowserProfile,
        applicationIsTerminating: Bool = RexApplicationLifecycle.isTerminating
    ) -> Bool {
        Self.shouldRemovePersistedSession(
            for: windowID,
            primaryWindowID: primaryWindowID,
            profile: profile,
            applicationIsTerminating: applicationIsTerminating
        )
    }

    static func shouldRemovePersistedSession(
        for windowID: UUID,
        primaryWindowID: UUID,
        profile: BrowserProfile,
        applicationIsTerminating: Bool
    ) -> Bool {
        !profile.isPrivate
            && windowID != primaryWindowID
            && !applicationIsTerminating
    }
}

struct RexWindowScene: View {
    let windowID: UUID
    let profile: BrowserProfile
    let preferences: BrowserPreferences
    @EnvironmentObject private var coordinator: RexWindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: BrowserStore
    @State private var windowChromeState = BrowserWindowChromeState.initial
    @State private var browserWindowNumber: Int?
    @State private var webFullscreenOwnsWindow = false

    init(
        windowID: UUID,
        persistence: BrowserSQLitePersistence,
        profile: BrowserProfile = .standard,
        preferences: BrowserPreferences = .shared
    ) {
        self.windowID = windowID
        self.profile = profile
        self.preferences = preferences
        _store = StateObject(wrappedValue: BrowserStore(
            databasePersistence: persistence,
            windowID: windowID,
            profile: profile,
            preferences: preferences
        ))
    }

    var body: some View {
        BrowserRootView(
            toolbarLeadingInset: windowChromeState.toolbarLeadingInset,
            isFullScreen: windowChromeState.isFullScreen
        )
            .environmentObject(store)
            .environmentObject(preferences)
            .focusedObject(store)
            .frame(minWidth: 980, minHeight: 640)
            .background {
                RexWindowChromeConfigurator(
                    windowChromeState: $windowChromeState,
                    windowNumber: $browserWindowNumber
                )
            }
            .onAppear {
                RexMenuLocalization.schedule()
                RexActiveWindowSessionRegistry.shared.register(store)
                if !profile.isPrivate {
                    coordinator.registerNewWindow(windowID)
                    coordinator.restoreOtherWindows(using: openWindow)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    RexMenuLocalization.schedule()
                } else {
                    store.flushSession()
                }
            }
            .onChange(of: store.webFullscreenTabID) { _, _ in
                synchronizeWebFullscreen()
            }
            .onChange(of: browserWindowNumber) { _, _ in
                synchronizeWebFullscreen()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification
            )) { notification in
                guard let window = notification.object as? NSWindow,
                      window.windowNumber == browserWindowNumber else { return }
                RexActiveWindowSessionRegistry.shared.markActive(store)
            }
            .onChange(of: windowChromeState.isFullScreen) { _, _ in
                handleNativeFullscreenChange()
            }
            .onDisappear {
                RexActiveWindowSessionRegistry.shared.unregister(store)
                let removesPersistedSession = coordinator.shouldRemovePersistedSession(
                    for: windowID,
                    profile: profile
                )
                if removesPersistedSession {
                    coordinator.unregisterWindow(windowID)
                }
                store.closeWindow(removingPersistedSession: removesPersistedSession)
            }
    }

    private var browserWindow: NSWindow? {
        guard let browserWindowNumber else { return nil }
        return NSApp.window(withWindowNumber: browserWindowNumber)
    }

    private func synchronizeWebFullscreen() {
        guard let window = browserWindow else { return }
        if store.webFullscreenTabID != nil {
            guard !window.styleMask.contains(.fullScreen) else { return }
            webFullscreenOwnsWindow = true
            window.toggleFullScreen(nil)
        } else if webFullscreenOwnsWindow,
                  window.styleMask.contains(.fullScreen) {
            webFullscreenOwnsWindow = false
            window.toggleFullScreen(nil)
        }
    }

    private func handleNativeFullscreenChange() {
        guard let window = browserWindow else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if !isFullScreen, store.webFullscreenTabID != nil {
            webFullscreenOwnsWindow = false
            store.exitWebFullscreen()
        } else if isFullScreen, webFullscreenOwnsWindow,
                  store.webFullscreenTabID == nil {
            webFullscreenOwnsWindow = false
            window.toggleFullScreen(nil)
        }
    }
}

private struct RexWindowChromeConfigurator: NSViewRepresentable {
    @Binding var windowChromeState: BrowserWindowChromeState
    @Binding var windowNumber: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(windowChromeState: $windowChromeState, windowNumber: $windowNumber)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.windowChromeState = $windowChromeState
        context.coordinator.windowNumber = $windowNumber
        context.coordinator.scheduleRefresh()
    }

    static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct TrafficLightPosition {
            let baselineY: CGFloat
            let adjustedY: CGFloat
        }

        var windowChromeState: Binding<BrowserWindowChromeState>
        var windowNumber: Binding<Int?>
        private weak var window: NSWindow?
        private var notificationTokens: [NSObjectProtocol] = []
        private var trafficLightPositions: [ObjectIdentifier: TrafficLightPosition] = [:]

        init(
            windowChromeState: Binding<BrowserWindowChromeState>,
            windowNumber: Binding<Int?>
        ) {
            self.windowChromeState = windowChromeState
            self.windowNumber = windowNumber
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                scheduleRefresh()
                return
            }
            detach()
            self.window = window
            windowNumber.wrappedValue = window?.windowNumber
            guard let window else { return }

            configure(window)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in names {
                notificationTokens.append(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.refresh() }
                    }
                )
            }
            scheduleRefresh()
        }

        func detach() {
            if let window {
                restoreTrafficLights(in: window)
            }
            trafficLightPositions.removeAll()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
            window = nil
            windowNumber.wrappedValue = nil
        }

        func scheduleRefresh() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.refresh()
            }
        }

        private func configure(_ window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
        }

        private func refresh() {
            guard let window else { return }
            configure(window)
            let isFullScreen = window.styleMask.contains(.fullScreen)
            positionTrafficLights(in: window, isFullScreen: isFullScreen)
            let trafficLightTrailingEdge = [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ]
                .compactMap { window.standardWindowButton($0) }
                .filter { !$0.isHidden }
                .map { $0.convert($0.bounds, to: nil).maxX }
                .max()
            let nextState = BrowserWindowChromeState(
                toolbarLeadingInset: BrowserWindowChromeLayout.toolbarLeadingInset(
                    trafficLightTrailingEdge: trafficLightTrailingEdge,
                    isFullScreen: isFullScreen
                ),
                isFullScreen: isFullScreen
            )
            let currentState = windowChromeState.wrappedValue
            if currentState.isFullScreen != nextState.isFullScreen ||
                abs(currentState.toolbarLeadingInset - nextState.toolbarLeadingInset) >= 0.5 {
                windowChromeState.wrappedValue = nextState
            }
        }

        private func positionTrafficLights(in window: NSWindow, isFullScreen: Bool) {
            guard !isFullScreen else {
                restoreTrafficLights(in: window)
                return
            }

            for buttonType in trafficLightButtonTypes {
                guard let button = window.standardWindowButton(buttonType), !button.isHidden else {
                    continue
                }

                let identifier = ObjectIdentifier(button)
                let currentY = button.frame.origin.y
                let baselineY: CGFloat
                if let position = trafficLightPositions[identifier],
                   abs(currentY - position.adjustedY) < 0.5 {
                    baselineY = position.baselineY
                } else {
                    baselineY = currentY
                }

                let adjustedY = BrowserWindowChromeLayout.trafficLightAdjustedY(
                    baselineY: baselineY,
                    superviewIsFlipped: button.superview?.isFlipped == true
                )
                trafficLightPositions[identifier] = TrafficLightPosition(
                    baselineY: baselineY,
                    adjustedY: adjustedY
                )

                if abs(currentY - adjustedY) >= 0.5 {
                    button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: adjustedY))
                }
            }
        }

        private func restoreTrafficLights(in window: NSWindow) {
            for buttonType in trafficLightButtonTypes {
                guard let button = window.standardWindowButton(buttonType),
                      let position = trafficLightPositions[ObjectIdentifier(button)],
                      abs(button.frame.origin.y - position.adjustedY) < 0.5 else {
                    continue
                }
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: position.baselineY))
            }
            trafficLightPositions.removeAll()
        }

        private var trafficLightButtonTypes: [NSWindow.ButtonType] {
            [.closeButton, .miniaturizeButton, .zoomButton]
        }
    }

    @MainActor
    final class WindowProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

@MainActor
enum RexMenuLocalization {
    private enum MenuRole {
        case application
        case file
        case edit
        case view
        case window
        case help
        case other
    }

    private static let topLevelTitles: [String: String] = [
        "File": "文件",
        "Edit": "编辑",
        "View": "显示",
        "Window": "窗口",
        "Help": "帮助"
    ]

    private static let actionTitles: [String: String] = [
        "showPreferencesWindow:": "设置…",
        "showSettingsWindow:": "设置…",
        "performClose:": "关闭窗口",
        "saveDocument:": "存储",
        "saveDocumentAs:": "存储为…",
        "runPageLayout:": "页面设置…",
        "print:": "打印…",
        "undo:": "撤销",
        "redo:": "重做",
        "cut:": "剪切",
        "copy:": "复制",
        "paste:": "粘贴",
        "pasteAsPlainText:": "粘贴并匹配样式",
        "delete:": "删除",
        "selectAll:": "全选",
        "startDictation:": "开始听写…",
        "orderFrontCharacterPalette:": "表情与符号",
        "runToolbarCustomizationPalette:": "自定工具栏…",
        "performMiniaturize:": "最小化",
        "performZoom:": "缩放",
        "arrangeInFront:": "前置全部窗口"
    ]

    private static let editSectionTitles: [String: String] = [
        "Find": "查找",
        "Spelling and Grammar": "拼写和语法",
        "Substitutions": "替换",
        "Transformations": "转换",
        "Speech": "语音"
    ]

    static func schedule() {
        apply(to: NSApplication.shared.mainMenu)
        Task { @MainActor in
            await Task.yield()
            apply(to: NSApplication.shared.mainMenu)
        }
    }

    static func apply(to mainMenu: NSMenu?) {
        guard let mainMenu else { return }
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Rex"
        for item in mainMenu.items {
            let role = topLevelRole(for: item.title, applicationName: applicationName)
            item.title = topLevelTitles[item.title] ?? item.title
            guard let submenu = item.submenu else { continue }
            submenu.title = item.title
            localize(menu: submenu, role: role, applicationName: applicationName)
        }
    }

    private static func localize(menu: NSMenu, role: MenuRole, applicationName: String) {
        for item in menu.items {
            item.title = localizedTitle(for: item, role: role, applicationName: applicationName)
            guard let submenu = item.submenu else { continue }
            submenu.title = item.title
            // Descendants can still be translated by a known action, but their
            // titles may belong to services, windows, or user-defined content.
            localize(menu: submenu, role: .other, applicationName: applicationName)
        }
    }

    private static func localizedTitle(
        for item: NSMenuItem,
        role: MenuRole,
        applicationName: String
    ) -> String {
        if let action = item.action {
            let actionName = NSStringFromSelector(action)
            switch actionName {
            case "orderFrontStandardAboutPanel:": return "关于 \(applicationName)"
            case "hide:": return "隐藏 \(applicationName)"
            case "hideOtherApplications:": return "隐藏其他应用"
            case "unhideAllApplications:": return "全部显示"
            case "terminate:": return "退出 \(applicationName)"
            case "toggleToolbarShown:":
                return ["Hide Toolbar", "隐藏工具栏"].contains(item.title) ? "隐藏工具栏" : "显示工具栏"
            case "toggleFullScreen:":
                return ["Exit Full Screen", "退出全屏幕"].contains(item.title) ? "退出全屏幕" : "进入全屏幕"
            default:
                if let localized = actionTitles[actionName] { return localized }
            }
        }

        switch role {
        case .application:
            if item.title == "Services" { return "服务" }
            if item.title == "About \(applicationName)" { return "关于 \(applicationName)" }
            if item.title == "Hide \(applicationName)" { return "隐藏 \(applicationName)" }
            if item.title == "Quit \(applicationName)" { return "退出 \(applicationName)" }
        case .edit:
            if let localized = editSectionTitles[item.title] { return localized }
        case .help:
            if item.title == "\(applicationName) Help" { return "\(applicationName) 帮助" }
        case .file, .view, .window, .other:
            break
        }
        return item.title
    }

    private static func topLevelRole(for title: String, applicationName: String) -> MenuRole {
        if title == applicationName { return .application }
        switch title {
        case "File", "文件": return .file
        case "Edit", "编辑": return .edit
        case "View", "显示": return .view
        case "Window", "窗口": return .window
        case "Help", "帮助": return .help
        default: return .other
        }
    }
}

struct BrowserCommands: Commands {
    @FocusedObject private var store: BrowserStore?
    @Environment(\.openWindow) private var openWindow

    private struct MenuEntry: Identifiable {
        let position: Int
        let title: String
        var id: Int { position }
    }

    /// Visible tab jump targets only. Empty slots are omitted so the menu
    /// reflects the real tab count instead of always listing 1...9.
    private var tabMenuEntries: [MenuEntry] {
        let count = store?.visibleTabs.count ?? 0
        guard count > 0 else { return [] }
        var entries: [MenuEntry] = []
        let numbered = min(8, count)
        for position in 1...numbered {
            entries.append(MenuEntry(position: position, title: "标签页 \(position)"))
        }
        // Chrome-style ⌘9 always jumps to the last tab when any tab exists.
        entries.append(MenuEntry(position: 9, title: "最后一个标签页"))
        return entries
    }

    /// One menu item per real workspace (name + ⌃N for the first nine).
    private var workspaceMenuEntries: [MenuEntry] {
        let spaces = store?.spaces ?? []
        return spaces.prefix(9).enumerated().map { index, space in
            MenuEntry(position: index + 1, title: space.name)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 Rex") { store?.presentSettings(.about) }
                .disabled(store == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { store?.presentSettings(.general) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(store == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") { openWindow(id: "browser", value: UUID()) }
                .keyboardShortcut("n", modifiers: .command)
            Button("新建隐私窗口") {
                openWindow(id: "private-browser", value: UUID())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("新建标签页") { store?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(store == nil)
            Button("恢复关闭的标签页") { store?.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store?.canRestoreClosedTab != true)
            Button("关闭当前页面") { store?.closeCurrentTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(store == nil)
            Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("标签页") {
            Button("复制当前标签页") {
                guard let tabID = store?.selectedTabID else { return }
                store?.duplicateTab(tabID)
            }
            .disabled(store == nil)
            Button(store?.currentTab?.isMuted == true ? "取消静音" : "将此标签页静音") {
                guard let tabID = store?.selectedTabID else { return }
                store?.toggleMuted(tabID)
            }
            .disabled(store == nil)
            Divider()
            ForEach(tabMenuEntries, id: \.position) { entry in
                Button(entry.title) {
                    store?.selectTab(atChromePosition: entry.position)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(entry.position)")), modifiers: .command)
            }
        }
        CommandMenu("工作空间") {
            ForEach(workspaceMenuEntries, id: \.position) { entry in
                Button(entry.title) {
                    store?.switchSpace(at: entry.position)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(entry.position)")), modifiers: .control)
            }
        }
        CommandMenu("浏览") {
            Button("聚焦地址栏") { store?.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(store == nil)
            Divider()
            Button("后退") { store?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(store?.navigationStates[store?.selectedTabID ?? UUID()]?.canGoBack != true)
            Button("前进") { store?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(store?.navigationStates[store?.selectedTabID ?? UUID()]?.canGoForward != true)
            Button("重新加载") { store?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store == nil)
            Divider()
            Button("在页面中查找") { store?.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store == nil)
            Button("查找下一个") { store?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(store?.findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            Button("查找上一个") { store?.findNext(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store?.findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            Divider()
            Button("放大") { store?.adjustZoom(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(store == nil)
            Button("缩小") { store?.adjustZoom(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(store == nil)
            Button("实际大小") { store?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(store == nil)
            Button("打印页面") { store?.printCurrentPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(store == nil)
            Button("收藏当前页面") { store?.toggleBookmark() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(store == nil || store?.profile.isPrivate == true)
            Divider()
            Button("下一个标签页") { store?.selectAdjacentTab(forward: true) }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: .control)
                .disabled(store == nil)
            Button("上一个标签页") { store?.selectAdjacentTab(forward: false) }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: [.control, .shift])
                .disabled(store == nil)
            Divider()
            Button("创建或关闭分屏") { store?.toggleSplit() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store == nil)
            Button("交换分屏页面") { store?.swapSplitPages() }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(store?.splitSession == nil)
            Button("聚焦左侧页面") { store?.focus(.primary) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(store?.splitSession == nil)
            Button("聚焦右侧页面") { store?.focus(.secondary) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(store?.splitSession == nil)
            Divider()
            Button("打开资料库") { store?.isLibraryPresented = true }
                .disabled(store == nil)
            Divider()
            Button("开发者工具") { store?.openDeveloperTools() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store == nil)
            Button("JavaScript 控制台") { store?.openDeveloperToolsConsole() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(store == nil)
            Button("检查元素") { store?.openDeveloperToolsInspect() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store == nil)
            Button("强制重新加载") { store?.hardReloadCurrentPage() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store == nil)
        }
        CommandGroup(replacing: .help) {
            Button("版本与功能") { store?.isReleaseNotesPresented = true }
                .disabled(store == nil)
        }
    }
}

private extension BrowserAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct RexApp: App {
    @StateObject private var windowCoordinator = RexWindowCoordinator()
    @StateObject private var preferences = BrowserPreferences.shared
#if REX_CEF
    @NSApplicationDelegateAdaptor(RexAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        WindowGroup("Rex", id: "browser", for: UUID.self) { value in
            RexWindowScene(
                windowID: value.wrappedValue,
                persistence: windowCoordinator.persistence,
                profile: .standard,
                preferences: preferences
            )
            .environmentObject(windowCoordinator)
            .preferredColorScheme(preferences.appearance.preferredColorScheme)
        } defaultValue: {
            windowCoordinator.primaryWindowID
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands()
        }
        // Prevent SwiftUI from opening a new window for each external URL
        // event. External links are handled by the app delegate's
        // application(_:open:) and routed as new tabs in an existing window.
        .handlesExternalEvents(matching: ["browser"])

        WindowGroup("Rex 隐私窗口", id: "private-browser", for: UUID.self) { value in
            if let windowID = value.wrappedValue {
                RexWindowScene(
                    windowID: windowID,
                    persistence: windowCoordinator.persistence,
                    profile: .privateWindow(id: windowID),
                    preferences: preferences
                )
                .environmentObject(windowCoordinator)
                .preferredColorScheme(preferences.appearance.preferredColorScheme)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["private-browser"])
    }
}
