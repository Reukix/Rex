import AppKit
import CryptoKit
import Security
import SwiftUI

struct BrowserRootView: View {
    @EnvironmentObject private var store: BrowserStore
    let toolbarLeadingInset: CGFloat
    let isFullScreen: Bool
    @State private var developerToolsDragWidth: CGFloat?
    @State private var certificateViewerSnapshot: CertificateViewerSnapshot?
    @State private var isPerformanceMonitorPresented = false

    init(
        toolbarLeadingInset: CGFloat = BrowserWindowChromeLayout.toolbarLeadingInset(
            trafficLightTrailingEdge: nil,
            isFullScreen: false
        ),
        isFullScreen: Bool = false
    ) {
        self.toolbarLeadingInset = toolbarLeadingInset
        self.isFullScreen = isFullScreen
    }

    var body: some View {
        GeometryReader { windowProxy in
            ZStack(alignment: .top) {
                RexWindowBackground()

                if let fullscreenTabID = store.webFullscreenTabID {
                    BrowserContentView(
                        windowSize: windowProxy.size,
                        webFullscreenTabID: fullscreenTabID
                    )
                    .ignoresSafeArea()
                } else {
                    VStack(spacing: 4) {
                    BrowserToolbar(
                        preferences: store.preferences,
                        certificateViewerSnapshot: $certificateViewerSnapshot,
                        onShowPerformanceMonitor: { isPerformanceMonitorPresented = true },
                        onOpenExtensionPage: { package in
                            guard let url = package.optionsURL else {
                                store.isExtensionsPresented = true
                                return
                            }
                            store.openExtensionPage(url, title: package.name)
                        }
                    )
                    .padding(
                        .leading,
                        isFullScreen ? BrowserWindowChromeLayout.windowEdgePadding : toolbarLeadingInset
                    )
                    .padding(.trailing, BrowserWindowChromeLayout.windowEdgePadding)
                    .padding(.top, 2)

                    GeometryReader { proxy in
                        let sidebarWidth = store.isSidebarCollapsed
                            ? RexMetrics.collapsedSidebarWidth
                            : RexMetrics.sidebarWidth
                        let browserAreaWidth = max(0, floor(proxy.size.width - sidebarWidth - 6))
                        let developerToolsMaximum = max(320, min(760, browserAreaWidth - 280))
                        let activeDeveloperToolsWidth = developerToolsDragWidth ?? store.developerToolsWidth
                        let developerToolsWidth = min(
                            max(floor(activeDeveloperToolsWidth), 320),
                            developerToolsMaximum
                        )
                        let contentWidth = store.developerToolsTabID == nil
                            ? browserAreaWidth
                            : max(240, browserAreaWidth - developerToolsWidth - 6)
                        let isResizingDeveloperTools =
                            store.isDeveloperToolsResizing || developerToolsDragWidth != nil

                        HStack(spacing: 6) {
                            BrowserSidebar()
                                .frame(width: sidebarWidth)
                                .animation(.snappy(duration: 0.22), value: store.isSidebarCollapsed)

                            ZStack(alignment: .topTrailing) {
                                BrowserContentView(windowSize: windowProxy.size)

                                if store.isFindPresented {
                                    BrowserFindBar()
                                        .padding(10)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                            .frame(width: contentWidth)
                            .frame(maxHeight: .infinity)
                            .transaction { transaction in
                                if isResizingDeveloperTools {
                                    transaction.animation = nil
                                    transaction.disablesAnimations = true
                                }
                            }

                            if let tabID = store.developerToolsTabID {
                                DeveloperToolsPanel(
                                    tabID: tabID,
                                    availableWidth: browserAreaWidth,
                                    windowSize: windowProxy.size,
                                    dragWidth: $developerToolsDragWidth
                                )
                                .frame(width: developerToolsWidth)
                                .frame(maxHeight: .infinity)
                                .transaction { transaction in
                                    // Keep drag-resizing snappy; only animate open/close.
                                    if isResizingDeveloperTools {
                                        transaction.animation = nil
                                        transaction.disablesAnimations = true
                                    }
                                }
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .animation(nil, value: developerToolsWidth)
                    }
                    .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }

                    if let prompt = store.pendingPermissionPrompts.first {
                        WebsitePermissionPromptBar(prompt: prompt)
                            .padding(.top, 48)
                            .padding(.horizontal, 24)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .coordinateSpace(name: RexCoordinateSpace.window)
            .background {
                RexWindowBackground()
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.isReleaseNotesPresented) {
            ReleaseNotesView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .sheet(isPresented: $store.isLibraryPresented) {
            BrowserLibraryView()
        }
        .sheet(isPresented: $store.isPermissionCenterPresented) {
            PermissionCenterView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isSettingsPresented) {
            BrowserSettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: Binding(
            get: { !store.profile.isPrivate && store.isExtensionsPresented },
            set: { store.isExtensionsPresented = $0 && !store.profile.isPrivate }
        )) {
            BrowserExtensionsView()
                .environmentObject(store)
                .frame(minWidth: 640, minHeight: 480)
        }
        .sheet(isPresented: $isPerformanceMonitorPresented) {
            PerformanceMonitorView()
                .environmentObject(store)
        }
        .sheet(item: $certificateViewerSnapshot) { snapshot in
            CertificateDetailsView(info: snapshot.info, certificate: snapshot.certificate)
        }
        .alert("Rex", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("好") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .animation(.snappy(duration: 0.22), value: store.isSidebarCollapsed)
        .animation(.snappy(duration: 0.24), value: store.splitSession?.orientation)
        .animation(.snappy(duration: 0.18), value: store.isFindPresented)
        .animation(store.isDeveloperToolsResizing ? nil : .snappy(duration: 0.2), value: store.developerToolsTabID)
        // Width changes must never animate: CEF host views thrash if SwiftUI interpolates frames.
        .animation(nil, value: store.developerToolsWidth)
        .animation(nil, value: developerToolsDragWidth)
        .animation(.snappy(duration: 0.2), value: store.pendingPermissionPrompts.first?.id)
    }
}

private struct BrowserTitlebarCardSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(
                reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        RexChromeColor.stroke(colorScheme, emphasized: true),
                        lineWidth: 0.75
                    )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private enum ChromiumDeveloperToolsHostTheme {
    static let background = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let border = Color.white.opacity(0.08)
}

private struct DeveloperToolsPanel: View {
    @EnvironmentObject private var store: BrowserStore
    let tabID: UUID
    let availableWidth: CGFloat
    let windowSize: CGSize
    @Binding var dragWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @State private var isResizeHandleHovered = false

    var body: some View {
        VStack(spacing: 0) {
#if REX_CEF
            ChromiumDeveloperToolsSurface(
                tabID: tabID,
                inspectX: store.developerToolsInspectX,
                inspectY: store.developerToolsInspectY,
                requestID: store.developerToolsRequestID
            )
            .id("chromium-devtools-\(tabID)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
            ContentUnavailableView("开发者工具需要 Chromium 运行时", systemImage: "hammer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ChromiumDeveloperToolsHostTheme.background)
#endif
        }
        .background(ChromiumDeveloperToolsHostTheme.background)
        .overlay {
            ZStack {
                WindowedCEFViewportCornerCover(cornerRadius: 8, windowSize: windowSize)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ChromiumDeveloperToolsHostTheme.border, lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            ZStack {
                Rectangle()
                    .fill(.clear)
                Capsule()
                    .fill(isResizeHandleHovered ? Color.accentColor.opacity(0.75) : .clear)
                    .frame(width: 3, height: 44)
            }
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { isResizeHandleHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = floor(store.developerToolsWidth)
                            dragWidth = dragStartWidth
                            store.beginDeveloperToolsResize()
                        }
                        let initialWidth = dragStartWidth ?? store.developerToolsWidth
                        // Keep drag width local so the store does not publish every tick.
                        let maximum = max(320, min(760, availableWidth * 0.68))
                        let next = floor(min(max(initialWidth - floor(value.translation.width), 320), maximum))
                        if abs(next - (dragWidth ?? store.developerToolsWidth)) >= 1 {
                            dragWidth = next
                        }
                    }
                    .onEnded { _ in
                        if let dragWidth {
                            store.resizeDeveloperTools(
                                to: dragWidth,
                                availableWidth: availableWidth,
                                force: true
                            )
                        }
                        dragStartWidth = nil
                        dragWidth = nil
                        store.endDeveloperToolsResize()
                    }
            )
            .help("拖动调整开发者工具宽度")
        }
        .accessibilityLabel("开发者工具，正在检查 \(inspectedTabTitle)")
    }

    private var inspectedTabTitle: String {
        store.tabs.first(where: { $0.id == tabID })?.title ?? "当前页面"
    }
}

private struct BrowserToolbar: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var preferences: BrowserPreferences
    @ObservedObject private var extensionsStore = BrowserExtensionsStore.shared
    @StateObject private var extensionActionPanel = RexToolbarPanelController()
    @StateObject private var siteInfoPanel = RexToolbarPanelController()
    @StateObject private var privacyPanel = RexToolbarPanelController()
    @StateObject private var downloadsPanel = RexToolbarPanelController()
    @Binding var certificateViewerSnapshot: CertificateViewerSnapshot?
    let onShowPerformanceMonitor: () -> Void
    let onOpenExtensionPage: (BrowserExtensionPackage) -> Void
    @FocusState private var addressFocused: Bool
    @State private var isSavingComposition = false
    @State private var compositionName = ""
    @State private var isDownloadsPanelPresented = false

    var body: some View {
        HStack(spacing: 6) {
            if preferences.showPerformanceMetrics {
                ToolbarStatusCluster(onShowDetails: onShowPerformanceMonitor)
            }

            if !store.profile.isPrivate {
                LiquidGlassIconButton(
                    systemName: "puzzlepiece.extension",
                    label: "扩展",
                    isSelected: extensionActionPanel.isPresented
                ) {
                    if extensionActionPanel.isPresented {
                        extensionActionPanel.dismiss()
                    } else {
                        store.isSiteInfoPresented = false
                        store.isPrivacyPresented = false
                        isDownloadsPanelPresented = false
                        presentExtensionsList()
                    }
                }
                .background {
                    RexToolbarPanelAnchor(controller: extensionActionPanel)
                }
            }

            LiquidGlassIconButton(systemName: "sidebar.left", label: "显示或隐藏侧栏") {
                store.isSidebarCollapsed.toggle()
            }

            if store.profile.isPrivate {
                Label("隐私", systemImage: "eye.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            LiquidGlassIconButton(
                systemName: "chevron.left",
                label: "后退",
                isDisabled: store.navigationStates[store.selectedTabID]?.canGoBack != true
            ) { store.goBack() }
            LiquidGlassIconButton(
                systemName: "chevron.right",
                label: "前进",
                isDisabled: store.navigationStates[store.selectedTabID]?.canGoForward != true
            ) { store.goForward() }
            LiquidGlassIconButton(
                systemName: store.isCurrentPageLoading ? "xmark" : "arrow.clockwise",
                label: store.isCurrentPageLoading ? "停止加载" : "重新加载"
            ) { store.reloadOrStop() }

            HStack(spacing: 8) {
                Button {
                    store.isSiteInfoPresented.toggle()
                } label: {
                    Image(systemName: siteSecuritySymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(siteSecurityColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("网站信息与证书")
                .accessibilityLabel("查看网站信息与证书")
                .background {
                    RexToolbarPanelAnchor(controller: siteInfoPanel)
                }

                TextField("搜索或输入网址", text: $store.addressText)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit { store.submitAddress() }
                    .accessibilityLabel("地址和搜索")

                if store.isCurrentPageLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        addressFocused
                            ? Color.accentColor.opacity(0.75)
                            : RexChromeColor.stroke(colorScheme, emphasized: true),
                        lineWidth: addressFocused ? 1.5 : 0.75
                    )
            }

            LiquidGlassIconButton(
                systemName: "rectangle.split.2x1",
                label: store.splitSession == nil ? "创建分屏" : "关闭分屏",
                isSelected: store.splitSession != nil
            ) { store.toggleSplit() }

            if store.splitSession != nil {
                LiquidGlassIconButton(systemName: "arrow.left.arrow.right", label: "交换分屏页面") {
                    store.swapSplitPages()
                }
                LiquidGlassIconButton(systemName: "square.and.arrow.down", label: "保存分屏组合") {
                    compositionName = defaultCompositionName
                    isSavingComposition = true
                }

            }

            if !store.currentSpaceSplitCompositions.isEmpty {
                Menu {
                    ForEach(store.currentSpaceSplitCompositions) { composition in
                        Button {
                            _ = store.restoreSplitComposition(composition.id)
                        } label: {
                            Label(composition.name, systemImage: "rectangle.split.2x1")
                        }
                        Button("删除 \(composition.name)", role: .destructive) {
                            store.deleteSplitComposition(composition.id)
                        }
                    }
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("恢复分屏组合")
            }

            LiquidGlassIconButton(
                systemName: "shield.checkered",
                label: "隐私盾牌",
                isSelected: store.isPrivacyPresented
            ) { store.isPrivacyPresented.toggle() }
            .background {
                RexToolbarPanelAnchor(controller: privacyPanel)
            }

            LiquidGlassIconButton(
                systemName: "hammer",
                label: "开发者工具",
                isSelected: store.developerToolsTabID != nil
            ) { store.openDeveloperTools() }

            LiquidGlassIconButton(
                systemName: downloadButtonSymbol,
                label: "下载",
                isSelected: isDownloadsPanelPresented
            ) {
                isDownloadsPanelPresented.toggle()
            }
            .background {
                RexToolbarPanelAnchor(controller: downloadsPanel)
            }

            if !store.profile.isPrivate {
                LiquidGlassIconButton(
                    systemName: store.isCurrentPageBookmarked ? "star.fill" : "star",
                    label: store.isCurrentPageBookmarked ? "取消收藏" : "收藏当前页面",
                    isSelected: store.isCurrentPageBookmarked
                ) { store.toggleBookmark() }

                LiquidGlassIconButton(
                    systemName: "books.vertical",
                    label: "打开资料库",
                    isSelected: store.isLibraryPresented
                ) { store.isLibraryPresented = true }
            }

            Menu {
                Button {
                    store.newTab()
                } label: {
                    Label("打开新的标签页", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("t", modifiers: .command)
                Button {
                    openWindow(id: "browser", value: UUID())
                } label: {
                    Label("打开新的窗口", systemImage: "macwindow.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                Button {
                    openWindow(id: "private-browser", value: UUID())
                } label: {
                    Label("打开新的隐私窗口", systemImage: "eye.slash")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                if !store.profile.isPrivate {
                    Button {
                        store.presentLibrary(.history)
                    } label: {
                        Label("历史记录", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        store.presentLibrary(.downloads)
                    } label: {
                        Label("下载内容", systemImage: "arrow.down.circle")
                    }
                    Button {
                        store.presentLibrary(.bookmarks)
                    } label: {
                        Label("书签和收藏", systemImage: "star")
                    }
                    Divider()
                }
                Menu {
                    Button("放大") { store.adjustZoom(by: 1) }
                        .keyboardShortcut("+", modifiers: .command)
                    Button("缩小") { store.adjustZoom(by: -1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("恢复为 100%") { store.resetZoom() }
                        .keyboardShortcut("0", modifiers: .command)
                } label: {
                    Label("缩放 · \(zoomPercentage)%", systemImage: "magnifyingglass")
                }
                Button {
                    store.printCurrentPage()
                } label: {
                    Label("打印…", systemImage: "printer")
                }
                .keyboardShortcut("p", modifiers: .command)
                Button {
                    store.showFind()
                } label: {
                    Label("在页面中查找…", systemImage: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                Menu {
                    Button {
                        store.openDeveloperTools()
                    } label: {
                        Label("开发者工具", systemImage: "hammer")
                    }
                    if !store.profile.isPrivate {
                        Button {
                            store.isExtensionsPresented = true
                        } label: {
                            Label("扩展", systemImage: "puzzlepiece.extension")
                        }
                    }
                    Button {
                        store.isPermissionCenterPresented = true
                    } label: {
                        Label("网站权限", systemImage: "hand.raised")
                    }
                    Button {
                        store.isReleaseNotesPresented = true
                    } label: {
                        Label("版本与功能", systemImage: "sparkles")
                    }
                } label: {
                    Label("更多工具", systemImage: "wrench.and.screwdriver")
                }
                Divider()
                Button {
                    store.presentSettings(.general)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Text("Rex \(AppVersion.releaseVersion)")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多")
        }
        .padding(.horizontal, BrowserWindowChromeLayout.windowEdgePadding)
        .frame(height: RexMetrics.toolbarHeight)
        .background {
            BrowserTitlebarCardSurface()
        }
        .onChange(of: store.addressFocusRequest) { _, _ in addressFocused = true }
        .onChange(of: store.isSiteInfoPresented) { _, isPresented in
            if isPresented {
                presentSiteInfoPanel()
            } else {
                siteInfoPanel.dismiss()
            }
        }
        .onChange(of: siteInfoPanel.isPresented) { _, isPresented in
            if !isPresented {
                store.isSiteInfoPresented = false
            }
        }
        .onChange(of: store.isPrivacyPresented) { _, isPresented in
            if isPresented {
                presentPrivacyPanel()
            } else {
                privacyPanel.dismiss()
            }
        }
        .onChange(of: privacyPanel.isPresented) { _, isPresented in
            if !isPresented {
                store.isPrivacyPresented = false
            }
        }
        .onChange(of: isDownloadsPanelPresented) { _, isPresented in
            if isPresented {
                presentDownloadsPanel()
            } else {
                downloadsPanel.dismiss()
            }
        }
        .onChange(of: downloadsPanel.isPresented) { _, isPresented in
            if !isPresented {
                isDownloadsPanelPresented = false
            }
        }
        .onChange(of: store.downloadPanelRequest) { _, _ in
            guard !downloadsPanel.isPresented else { return }
            isDownloadsPanelPresented = true
        }
        .onDisappear {
            extensionActionPanel.dismiss()
            siteInfoPanel.dismiss()
            privacyPanel.dismiss()
            downloadsPanel.dismiss()
            store.isSiteInfoPresented = false
            store.isPrivacyPresented = false
            isDownloadsPanelPresented = false
        }
        .alert("保存分屏组合", isPresented: $isSavingComposition) {
            TextField("组合名称", text: $compositionName)
            Button("取消", role: .cancel) { compositionName = "" }
            Button("保存") {
                _ = store.saveCurrentSplitComposition(name: compositionName)
                compositionName = ""
            }
            .disabled(compositionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("保存当前空间的两个页面、方向、比例和焦点")
        }
    }

    private var defaultCompositionName: String {
        let primary = store.primaryTab?.title ?? "页面 A"
        let secondary = store.secondaryTab?.title ?? "页面 B"
        return "\(primary) + \(secondary)"
    }

    private var zoomPercentage: Int {
        Int(((store.navigationStates[store.selectedTabID]?.zoomLevel ?? 1) * 100).rounded())
    }

    private var downloadButtonSymbol: String {
        if store.downloads.contains(where: \.canCancel) {
            return "arrow.down.circle.fill"
        }
        if store.downloads.first?.state == .failed {
            return "exclamationmark.circle"
        }
        return "arrow.down.circle"
    }

    private var siteSecuritySymbol: String {
        switch store.currentSiteSecurityInfo?.level {
        case .secure: return "lock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .dangerous: return "exclamationmark.octagon.fill"
        case .insecure: return "lock.open.fill"
        case .internalPage: return "doc.text"
        case .pending: return "ellipsis.circle"
        case .unknown, nil: return "globe"
        }
    }

    private var siteSecurityColor: Color {
        switch store.currentSiteSecurityInfo?.level {
        case .secure: return .green
        case .warning, .insecure: return .orange
        case .dangerous: return .red
        case .pending, .internalPage, .unknown, nil: return .secondary
        }
    }

    private func presentSiteInfoPanel() {
        dismissToolbarPanels(except: siteInfoPanel)
        let size = CGSize(width: RexMetrics.popoverWidth, height: 380)
        let content = LiquidGlassPanel(cornerRadius: 12, showsShadow: false) {
            SiteInfoPopover(certificateViewerSnapshot: $certificateViewerSnapshot)
                .environmentObject(store)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .environment(\.colorScheme, colorScheme)
        .frame(width: size.width, height: size.height)
        guard siteInfoPanel.present(rootView: AnyView(content), size: size) else {
            store.isSiteInfoPresented = false
            store.lastError = "网站信息面板暂时无法在当前窗口中打开。"
            return
        }
    }

    private func presentPrivacyPanel() {
        dismissToolbarPanels(except: privacyPanel)
        let size = CGSize(width: RexMetrics.popoverWidth, height: 400)
        let content = LiquidGlassPanel(cornerRadius: 12, showsShadow: false) {
            ScrollView {
                PrivacyShieldView(report: store.privacyReport(for: store.currentTab))
                    .environmentObject(store)
                    .environmentObject(preferences)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .environment(\.colorScheme, colorScheme)
        .frame(width: size.width, height: size.height)
        guard privacyPanel.present(rootView: AnyView(content), size: size) else {
            store.isPrivacyPresented = false
            store.lastError = "隐私面板暂时无法在当前窗口中打开。"
            return
        }
    }

    private func presentDownloadsPanel() {
        dismissToolbarPanels(except: downloadsPanel)
        let size = BrowserDownloadsPanel.preferredSize
        let content = BrowserDownloadsPanel(
            onShowAll: {
                isDownloadsPanelPresented = false
                store.presentLibrary(.downloads)
            },
            onOpenSettings: {
                isDownloadsPanelPresented = false
                store.presentSettings(.downloads)
            },
            onClose: {
                isDownloadsPanelPresented = false
            }
        )
        .environmentObject(store)
        .environment(\.colorScheme, colorScheme)
        .frame(width: size.width, height: size.height)
        guard downloadsPanel.present(rootView: AnyView(content), size: size) else {
            isDownloadsPanelPresented = false
            store.lastError = "下载面板暂时无法在当前窗口中打开。"
            return
        }
    }

    private func dismissToolbarPanels(except retainedPanel: RexToolbarPanelController) {
        let panels = [extensionActionPanel, siteInfoPanel, privacyPanel, downloadsPanel]
        for panel in panels where panel !== retainedPanel {
            panel.dismiss()
        }
        if retainedPanel !== siteInfoPanel {
            store.isSiteInfoPresented = false
        }
        if retainedPanel !== privacyPanel {
            store.isPrivacyPresented = false
        }
        if retainedPanel !== downloadsPanel {
            isDownloadsPanelPresented = false
        }
    }

    private func presentExtensionsList() {
        dismissToolbarPanels(except: extensionActionPanel)
        extensionActionPanel.presentList(
            packages: extensionsStore.extensions,
            store: store,
            onSelect: { package in
                extensionActionPanel.dismiss()
                DispatchQueue.main.async {
                    presentExtensionAction(package)
                }
            },
            onOpenExtensionPage: { package in
                extensionActionPanel.dismiss()
                onOpenExtensionPage(package)
            },
            onManage: {
                extensionActionPanel.dismiss()
                store.isExtensionsPresented = true
            }
        )
    }

    private func presentExtensionAction(_ package: BrowserExtensionPackage) {
        extensionActionPanel.present(
            package: package,
            store: store,
            onBack: {
                extensionActionPanel.dismiss()
                DispatchQueue.main.async {
                    presentExtensionsList()
                }
            },
            onManage: {
                extensionActionPanel.dismiss()
                store.isExtensionsPresented = true
            },
            onOpenOptions: {
                extensionActionPanel.dismiss()
                onOpenExtensionPage(package)
            }
        )
    }
}

private struct RexExtensionsListPanel: View {
    let packages: [BrowserExtensionPackage]
    let onSelect: (BrowserExtensionPackage) -> Void
    let onOpenExtensionPage: (BrowserExtensionPackage) -> Void
    let onManage: () -> Void
    let onClose: () -> Void

    static func preferredSize(for packages: [BrowserExtensionPackage]) -> CGSize {
        guard !packages.isEmpty else {
            return CGSize(width: 360, height: 320)
        }
        return CGSize(
            width: 360,
            height: min(520, max(252, 184 + CGFloat(packages.count) * 68))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.95),
                                        Color.indigo.opacity(0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.accentColor.opacity(0.24), radius: 8, y: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rex 扩展")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(packages.isEmpty ? "打造你的浏览体验" : "\(packages.count) 个扩展已就绪")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.1), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                    .accessibilityLabel("关闭扩展程序")
                }
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 13)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 0.75)

                if packages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 64, height: 64)
                            .background(Color.accentColor.opacity(0.12), in: Circle())
                        Text("还没有扩展")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("从扩展管理中安装工具，让 Rex 更符合你的使用方式。")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 230)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 18)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("快捷访问")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.72))
                            Spacer()
                            Text("点击打开扩展面板")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 3)

                        ScrollView {
                            LazyVStack(spacing: 7) {
                                ForEach(packages) { package in
                                    RexExtensionListRow(
                                        package: package,
                                        onSelect: { onSelect(package) },
                                        onOpenSettings: {
                                            onOpenExtensionPage(package)
                                        },
                                        onManage: onManage
                                    )
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 11)
                    .padding(.bottom, 10)
                }

                Button(action: onManage) {
                    HStack(spacing: 11) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text("扩展管理")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("安装、停用与更新")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.56))
                        }

                        Spacer()

                        Text("\(packages.count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(
                        Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "17233F"),
                            Color(hex: "202A52"),
                            Color(hex: "291F4D")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(hex: "4F7DFF").opacity(0.2),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 280
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.34), radius: 22, y: 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(width: 360)
        .frame(minHeight: packages.isEmpty ? 320 : 252)
    }
}

private struct RexExtensionListRow: View {
    @State private var isHovered = false

    let package: BrowserExtensionPackage
    let onSelect: () -> Void
    let onOpenSettings: () -> Void
    let onManage: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onSelect) {
                HStack(spacing: 11) {
                    RexExtensionPanelIcon(package: package, size: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.name)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text(packageStatus)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(
                                    package.isEnabled ? Color.white.opacity(0.62) : Color.orange
                                )
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(
                            isHovered ? Color(hex: "8FB0FF") : Color.white.opacity(0.58)
                        )
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 59)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(package.name)")

            Menu {
                Button(action: onSelect) {
                    Label("打开扩展面板", systemImage: "rectangle.on.rectangle")
                }
                Button(action: onOpenSettings) {
                    Label("扩展设置", systemImage: "gearshape")
                }
                Divider()
                Button(action: onManage) {
                    Label("管理扩展程序", systemImage: "puzzlepiece.extension")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("\(package.name) 的更多操作")
            .accessibilityLabel("\(package.name) 的更多操作")
        }
        .padding(.trailing, 7)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isHovered
                        ? Color(hex: "557EFF").opacity(0.22)
                        : Color.white.opacity(0.07)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHovered
                        ? Color(hex: "8FB0FF").opacity(0.48)
                        : Color.white.opacity(0.11),
                    lineWidth: 0.75
                )
        }
        .scaleEffect(isHovered ? 1.006 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        if !package.isEnabled { return .orange }
        if package.appleNativeConnectionLimitation != nil { return .orange }
        if package.runtimeStatus != .ready { return .yellow }
        return .green
    }

    private var packageStatus: String {
        if !package.isEnabled {
            return "已停用"
        }
        if package.runtimeStatus != .ready {
            return package.runtimeStatus.displayName
        }
        if package.appleNativeConnectionLimitation != nil {
            return "Apple 原生连接受限"
        }
        return package.permissionSummary
    }
}

private struct RexRuntimeExtensionActionPanel: View {
    let package: BrowserExtensionPackage
    let onBack: () -> Void
    let onManage: () -> Void
    let onOpenOptions: () -> Void
    let onPageClose: () -> Void
    let onPanelSizeChange: (CGSize) -> Void

    static func preferredSize(for package: BrowserExtensionPackage) -> CGSize {
        guard package.canUseRuntimeResources,
              package.appleNativeConnectionLimitation == nil,
              package.actionPopupURL != nil else {
            return CGSize(width: 390, height: 260)
        }
        return CGSize(width: 360, height: 600)
    }

    private var canRunPopupPage: Bool {
        guard package.canUseRuntimeResources,
              package.appleNativeConnectionLimitation == nil,
              package.actionPopupURL != nil else { return false }
        return true
    }

    private var panelSize: CGSize {
        Self.preferredSize(for: package)
    }

    var body: some View {
#if REX_CEF
        if canRunPopupPage, let relativePath = package.actionPopupRelativePath {
            ChromiumExtensionPageSurface(
                package: package,
                relativePath: relativePath,
                surfaceID: "toolbar-popup-\(package.id)",
                onClose: onPageClose,
                onPreferredContentSizeChange: onPanelSizeChange
            )
            .frame(
                minWidth: 25,
                maxWidth: .infinity,
                minHeight: 25,
                maxHeight: .infinity
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityLabel("\(package.name) 扩展面板")
        } else {
            unavailableContent
                .frame(width: panelSize.width, height: panelSize.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear {
                    onPanelSizeChange(panelSize)
                }
        }
#else
        unavailableContent
            .frame(width: panelSize.width, height: panelSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                onPanelSizeChange(panelSize)
            }
#endif
    }

    private var unavailableContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                unavailableTitle,
                systemImage: unavailableSymbol,
                description: Text(unavailableDetail)
            )

            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.borderedProminent)
                Button(action: onManage) {
                    Label("管理", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                if package.optionsURL != nil {
                    Button(action: onOpenOptions) {
                        Label("扩展设置", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(20)
    }

    private var unavailableTitle: String {
        if !package.isEnabled {
            return "扩展已停用"
        }
        if package.runtimeStatus != .ready {
            return package.runtimeStatus.displayName
        }
        if package.appleNativeConnectionLimitation != nil {
            return "iCloud Passwords 原生连接受限"
        }
        if package.runtimeID.map(RexExtensionResourceURL.isValidRuntimeID) != true {
            return "扩展尚未接入运行时"
        }
        if package.actionPopupRelativePath == nil {
            return "此扩展没有小型面板"
        }
        return "扩展页面不可用"
    }

    private var unavailableDetail: String {
        if !package.isEnabled {
            return "在扩展管理中启用后可使用扩展页面。"
        }
        if package.runtimeStatus != .ready {
            return package.statusDetail ?? "扩展运行时尚未准备完成。"
        }
        if let limitation = package.appleNativeConnectionLimitation {
            return limitation
        }
        if package.runtimeID.map(RexExtensionResourceURL.isValidRuntimeID) != true {
            return "扩展缺少有效的 Chromium 运行时标识。"
        }
        if package.actionPopupRelativePath == nil {
            return "扩展清单没有声明 action.default_popup。"
        }
        return "Chromium 无法打开扩展包内页面。"
    }

    private var unavailableSymbol: String {
        if !package.isEnabled {
            return "pause.circle"
        }
        if package.runtimeStatus != .ready ||
            package.appleNativeConnectionLimitation != nil ||
            package.runtimeID.map(RexExtensionResourceURL.isValidRuntimeID) != true {
            return "exclamationmark.triangle"
        }
        return "puzzlepiece.extension"
    }
}

private final class RexToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RexToolbarPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false

    weak var anchorView: NSView?

    private weak var parentWindow: NSWindow?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var outsideMouseMonitor: Any?
    private var parentWindowObservers: [NSObjectProtocol] = []
    private var preferredSizesByPackageID: [String: CGSize] = [:]
    private var revealFallback: DispatchWorkItem?
    private var sessionID: UUID?

    func presentList(
        packages: [BrowserExtensionPackage],
        store: BrowserStore,
        onSelect: @escaping (BrowserExtensionPackage) -> Void,
        onOpenExtensionPage: @escaping (BrowserExtensionPackage) -> Void,
        onManage: @escaping () -> Void
    ) {
        let size = RexExtensionsListPanel.preferredSize(for: packages)
        let rootView = RexExtensionsListPanel(
            packages: packages,
            onSelect: onSelect,
            onOpenExtensionPage: onOpenExtensionPage,
            onManage: onManage,
            onClose: { [weak self] in self?.dismiss() }
        )
        .environmentObject(store)
        .frame(width: size.width, height: size.height)
        if !present(rootView: AnyView(rootView), size: size, revealAfterLayout: false) {
            store.lastError = "扩展面板暂时无法在当前窗口中打开。"
        }
    }

    func present(
        package: BrowserExtensionPackage,
        store: BrowserStore,
        onBack: @escaping () -> Void,
        onManage: @escaping () -> Void,
        onOpenOptions: @escaping () -> Void
    ) {
        let isRuntimePopup = package.canUseRuntimeResources
            && package.appleNativeConnectionLimitation == nil
            && package.actionPopupURL != nil
        let initialSize = preferredSizesByPackageID[package.id]
            ?? RexRuntimeExtensionActionPanel.preferredSize(for: package)
        let expectedSessionID = UUID()

        let rootView = RexRuntimeExtensionActionPanel(
            package: package,
            onBack: onBack,
            onManage: onManage,
            onOpenOptions: onOpenOptions,
            onPageClose: { [weak self] in
                DispatchQueue.main.async {
                    self?.dismiss(sessionID: expectedSessionID)
                }
            },
            onPanelSizeChange: { [weak self] size in
                self?.applyPreferredSize(
                    size,
                    packageID: package.id,
                    sessionID: expectedSessionID
                )
            }
        )
        .environmentObject(store)
        if !present(
            rootView: AnyView(rootView),
            size: initialSize,
            revealAfterLayout: isRuntimePopup,
            sessionID: expectedSessionID
        ) {
            store.lastError = "扩展面板暂时无法在当前窗口中打开。"
        }
    }

    private func present(
        rootView: AnyView,
        size: CGSize,
        revealAfterLayout: Bool,
        sessionID preparedSessionID: UUID = UUID()
    ) -> Bool {
        dismiss()
        guard let anchorView, let parentWindow = anchorView.window else {
            return false
        }

        let panel = RexToolbarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.alphaValue = revealAfterLayout ? 0 : 1
        panel.backgroundColor = .clear
        panel.hasShadow = !revealAfterLayout
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.delegate = self
        panel.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 1)

        let hostingController = NSHostingController(rootView: rootView)
        panel.contentViewController = hostingController

        self.parentWindow = parentWindow
        self.panel = panel
        self.hostingController = hostingController
        sessionID = preparedSessionID

        observeParentWindow(parentWindow)
        installOutsideMouseMonitor()
        positionPanel(size: size)
#if REX_CEF
        guard RexOrderAuxiliaryWindowFrontSafely(panel) else {
            dismiss()
            return false
        }
#else
        panel.orderFront(nil)
#endif
        isPresented = true
        if revealAfterLayout {
            scheduleRevealFallback(for: panel)
        }
        return true
    }

    func present(rootView: AnyView, size: CGSize) -> Bool {
        present(
            rootView: rootView,
            size: size,
            revealAfterLayout: false,
            sessionID: UUID()
        )
    }

    func dismiss() {
        dismiss(sessionID: nil)
    }

    private func dismiss(sessionID expectedSessionID: UUID?) {
        if let expectedSessionID, sessionID != expectedSessionID {
            return
        }
        sessionID = nil
        revealFallback?.cancel()
        revealFallback = nil
        removeOutsideMouseMonitor()
        guard let panel else {
            removeParentWindowObservers()
            hostingController = nil
            parentWindow = nil
            isPresented = false
            return
        }
        panel.delegate = nil
        removeParentWindowObservers()
        panel.contentViewController = nil
        hostingController = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        parentWindow = nil
        isPresented = false
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        revealFallback?.cancel()
        revealFallback = nil
        removeOutsideMouseMonitor()
        removeParentWindowObservers()
        panel?.contentViewController = nil
        hostingController = nil
        sessionID = nil
        panel = nil
        parentWindow = nil
        isPresented = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dismiss()
        }
    }

    private func applyPreferredSize(
        _ requestedSize: CGSize,
        packageID: String,
        sessionID expectedSessionID: UUID
    ) {
        guard sessionID == expectedSessionID else { return }
        let size = normalizedPanelSize(requestedSize)
        preferredSizesByPackageID[packageID] = size
        resizePanel(to: size)
        revealPanelIfNeeded()
    }

    private func resizePanel(to requestedSize: CGSize) {
        guard let panel else { return }
        let size = normalizedPanelSize(requestedSize)
        panel.setContentSize(size)
        positionPanel(size: size)
    }

    private func normalizedPanelSize(_ requestedSize: CGSize) -> CGSize {
        CGSize(
            width: min(800, max(25, requestedSize.width.rounded(.up))),
            height: min(600, max(25, requestedSize.height.rounded(.up)))
        )
    }

    private func scheduleRevealFallback(for expectedPanel: NSPanel) {
        revealFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self, weak expectedPanel] in
            guard let self, let expectedPanel, self.panel === expectedPanel else {
                return
            }
            self.revealPanelIfNeeded()
        }
        revealFallback = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(1),
            execute: fallback
        )
    }

    private func revealPanelIfNeeded() {
        guard let panel, panel.alphaValue < 1 else { return }
        revealFallback?.cancel()
        revealFallback = nil
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.hasShadow = true
        panel.alphaValue = 1
        panel.invalidateShadow()
    }

    private func positionPanel(size: CGSize) {
        guard let panel, let anchorView, let anchorWindow = anchorView.window else {
            return
        }
        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorOnScreen = anchorWindow.convertToScreen(anchorInWindow)
        let visibleFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferredX = anchorOnScreen.minX
        let preferredY = anchorOnScreen.minY - size.height - 2
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let origin = NSPoint(
            x: min(max(preferredX, visibleFrame.minX), maximumX),
            y: min(max(preferredY, visibleFrame.minY), maximumY)
        )
        panel.setFrameOrigin(origin)
    }

    private func observeParentWindow(_ window: NSWindow) {
        removeParentWindowObservers()
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            parentWindowObservers.append(
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel else { return }
                        self.positionPanel(size: panel.frame.size)
                    }
                }
            )
        }
        parentWindowObservers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                }
            }
        )
    }

    private func installOutsideMouseMonitor() {
        removeOutsideMouseMonitor()
        outsideMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard let panel = self.panel, event.window !== panel else { return }
                // Don't dismiss when clicking the anchor view (the button that
                // toggles the panel). The button's own toggle handles it.
                if let anchorView = self.anchorView,
                   let anchorWindow = anchorView.window,
                   event.window === anchorWindow {
                    let locationInAnchor = anchorView.convert(event.locationInWindow, from: nil)
                    if anchorView.bounds.contains(locationInAnchor) {
                        return
                    }
                }
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self, self.panel === panel else { return }
                    self.dismiss()
                }
            }
            return event
        }
    }

    private func removeOutsideMouseMonitor() {
        guard let outsideMouseMonitor else { return }
        NSEvent.removeMonitor(outsideMouseMonitor)
        self.outsideMouseMonitor = nil
    }

    private func removeParentWindowObservers() {
        let center = NotificationCenter.default
        parentWindowObservers.forEach(center.removeObserver)
        parentWindowObservers.removeAll()
    }
}

private struct RexToolbarPanelAnchor: NSViewRepresentable {
    let controller: RexToolbarPanelController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            controller.anchorView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.anchorView !== nsView {
            controller.anchorView = nsView
        }
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: Void
    ) {
        // The controller is owned by the toolbar and dismisses its panel during teardown.
    }
}

private struct RexExtensionPanelIcon: View {
    let package: BrowserExtensionPackage
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let iconURL = package.iconURL,
               let image = NSImage(contentsOf: iconURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: max(13, size * 0.4), weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ToolbarStatusCluster: View {
    @ObservedObject private var metrics = ProcessMetricsMonitor.shared
    @Environment(\.colorScheme) private var colorScheme
    let onShowDetails: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onShowDetails) {
            HStack(spacing: 6) {
                metricChip(
                    symbol: "memorychip",
                    title: "内存",
                    value: metrics.memoryLabel,
                    minWidth: 72
                )
                metricChip(
                    symbol: "cpu",
                    title: "CPU",
                    value: metrics.cpuLabel,
                    minWidth: 54
                )
            }
            .frame(width: BrowserWindowChromeLayout.performanceClusterWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovered = $0 }
        .help("打开性能监视器")
        .accessibilityLabel("性能监视器，内存 \(metrics.memoryLabel)，CPU \(metrics.cpuLabel)")
        .onAppear { metrics.start() }
        .onDisappear { metrics.stop() }
    }

    private func metricChip(
        symbol: String,
        title: String,
        value: String,
        minWidth: CGFloat
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .frame(minWidth: minWidth, idealWidth: minWidth, maxWidth: minWidth, alignment: .leading)
        .frame(height: 26)
        .background(
            RexChromeColor.fill(colorScheme, hovered: isHovered),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

struct CertificateViewerSnapshot: Identifiable {
    struct ID: Hashable {
        let url: URL?
        let navigationGeneration: UInt64
        let serialNumberHex: String
    }

    let info: SiteSecurityInfo
    let certificate: SiteCertificate

    var id: ID {
        ID(
            url: info.url,
            navigationGeneration: info.navigationGeneration,
            serialNumberHex: certificate.serialNumberHex
        )
    }
}

private enum SiteInfoPage {
    case summary
    case certificate
    case permissions
}

private struct SiteInfoPopover: View {
    @EnvironmentObject private var store: BrowserStore
    @Binding var certificateViewerSnapshot: CertificateViewerSnapshot?
    @State private var page: SiteInfoPage = .summary
    @State private var selectedChainIndex = 0

    private var pushAnimation: Animation { .easeInOut(duration: 0.18) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch page {
            case .summary:
                summaryPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .certificate:
                certificatePage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .permissions:
                permissionsPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .padding(14)
        .frame(width: RexMetrics.popoverWidth)
        .clipped()
        .onChange(of: store.currentSiteSecurityInfo?.navigationGeneration) { _, _ in
            // A navigation invalidates the drill-down context.
            if page == .certificate {
                withAnimation(pushAnimation) { page = .summary }
            }
        }
    }

    private var summaryPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: securitySymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(securityColor)
                    .frame(width: 28, height: 28)
                    .background(securityColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(securityTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(store.currentTab?.url?.host ?? "本地页面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            Text(securityDescription)
                .font(.caption)
                .foregroundStyle(securityColor)
                .fixedSize(horizontal: false, vertical: true)

            if let info = store.currentSiteSecurityInfo {
                siteInfoRow(
                    symbol: "network",
                    title: "连接",
                    value: connectionSummary(info)
                )

                if let certificate = info.certificate {
                    Button {
                        selectedChainIndex = 0
                        withAnimation(pushAnimation) { page = .certificate }
                    } label: {
                        siteInfoRow(
                            symbol: "checkmark.seal",
                            title: "证书",
                            value: certificate.issuer?.displayName.nonEmpty ?? "查看证书详情",
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看证书详情")
                }
            }

            Button {
                withAnimation(pushAnimation) { page = .permissions }
            } label: {
                siteInfoRow(
                    symbol: "hand.raised",
                    title: "网站权限",
                    value: store.currentSitePermissions.isEmpty
                        ? "使用默认设置"
                        : "\(store.currentSitePermissions.count) 项自定义设置",
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看此网站的权限设置")

            siteInfoRow(
                symbol: "shield.checkered",
                title: "隐私保护",
                value: "已拦截 \(store.currentTab?.privacyState.blockedCount ?? 0) 项"
            )

            HStack(spacing: 8) {
                Button("隐私盾牌") {
                    store.isSiteInfoPresented = false
                    store.isPrivacyPresented = true
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 证书钻取页

    @ViewBuilder
    private var certificatePage: some View {
        if let info = store.currentSiteSecurityInfo, let certificate = info.certificate {
            let chain = certificate.derChain
            VStack(alignment: .leading, spacing: 12) {
                drillDownHeader(title: "证书")

                if chain.indices.contains(selectedChainIndex) {
                    let data = chain[selectedChainIndex]
                    let isLeaf = selectedChainIndex == 0
                    HStack(spacing: 10) {
                        Image(systemName: certificateHasError(info) && isLeaf
                              ? "xmark.seal.fill" : "checkmark.seal.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(certificateHasError(info) && isLeaf ? Color.red : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CertificateInspector.subjectSummary(for: data, fallbackIndex: selectedChainIndex))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(certificateStatusSummary(info))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    if chain.count > 1 {
                        Picker("证书链", selection: $selectedChainIndex) {
                            ForEach(Array(chain.indices), id: \.self) { index in
                                Text(index == 0 ? "站点证书" : "颁发机构 \(index)").tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            if isLeaf {
                                compactDetailRow("颁发给", certificate.subject?.displayName.nonEmpty ?? "—")
                                compactDetailRow("颁发者", certificate.issuer?.displayName.nonEmpty ?? "—")
                                compactDetailRow("序列号", certificate.serialNumberHex.nonEmpty ?? "—")
                                compactDetailRow(
                                    "有效期开始",
                                    certificate.validFrom?.formatted(date: .abbreviated, time: .shortened) ?? "—"
                                )
                                compactDetailRow(
                                    "有效期结束",
                                    certificate.validTo?.formatted(date: .abbreviated, time: .shortened) ?? "—"
                                )
                            }
                            compactDetailRow("SHA-256", CertificateInspector.sha256Fingerprint(data))
                            compactDetailRow(
                                "DER 大小",
                                ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                            )
                        }
                    }
                    .frame(maxHeight: 190)

                    Divider()

                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                CertificatePEMEncoder.encode(data),
                                forType: .string
                            )
                        } label: {
                            Label("复制 PEM", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        Spacer(minLength: 0)
                        Button {
                            certificateViewerSnapshot = CertificateViewerSnapshot(
                                info: info,
                                certificate: certificate
                            )
                            store.isSiteInfoPresented = false
                        } label: {
                            Label("完整证书查看器", systemImage: "macwindow")
                                .font(.caption)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                drillDownHeader(title: "证书")
                Label("当前页面没有可用的证书信息", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - 网站权限钻取页

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            drillDownHeader(title: "网站权限")

            if store.currentSitePermissions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("此网站还没有保存的权限决定", systemImage: "hand.raised")
                        .font(.caption.weight(.semibold))
                    Text("网站请求摄像头、麦克风或位置等权限时，Rex 会先询问，你的决定会出现在这里。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.currentSitePermissions) { permission in
                            HStack(spacing: 8) {
                                Image(systemName: permission.kind.symbolName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18)
                                Text(permission.kind.displayName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if permission.decision.isPersistent {
                                    Picker(
                                        "决定",
                                        selection: Binding(
                                            get: { permission.decision },
                                            set: { store.updatePermission(permission, decision: $0) }
                                        )
                                    ) {
                                        ForEach(PermissionDecision.permissionCenterCases, id: \.self) { decision in
                                            Text(decision.displayName).tag(decision)
                                        }
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 108)
                                } else {
                                    Text(permission.decision.displayName)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    store.revokePermission(permission)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("删除权限")
                            }
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            Divider()

            Button {
                store.isSiteInfoPresented = false
                store.isPermissionCenterPresented = true
            } label: {
                HStack(spacing: 6) {
                    Label("在权限中心管理全部网站", systemImage: "macwindow")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func drillDownHeader(title: String) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(pushAnimation) { page = .summary }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回网站信息")
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 6)
            Text(store.currentTab?.url?.host ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactDetailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.caption2.monospacedDigit())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func certificateHasError(_ info: SiteSecurityInfo) -> Bool {
        info.hasCertificateError || info.certificateErrorCode != nil ||
            info.certificateStatus.hasBlockingError
    }

    private func certificateStatusSummary(_ info: SiteSecurityInfo) -> String {
        guard info.hasCertificateError || info.certificateErrorCode != nil else {
            return info.certificateStatus.summary
        }
        if let code = info.certificateErrorCode {
            return "Chromium 检测到证书错误（代码 \(code)）"
        }
        return "Chromium 检测到证书错误"
    }

    private func siteInfoRow(
        symbol: String,
        title: String,
        value: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var securitySymbol: String {
        switch store.currentSiteSecurityInfo?.level {
        case .secure: return "lock.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .dangerous: return "exclamationmark.octagon.fill"
        case .insecure: return "lock.open.fill"
        case .internalPage: return "doc.text.fill"
        case .pending: return "ellipsis.circle.fill"
        case .unknown, nil: return "globe"
        }
    }

    private var securityColor: Color {
        switch store.currentSiteSecurityInfo?.level {
        case .secure: return .green
        case .warning, .insecure: return .orange
        case .dangerous: return .red
        case .pending, .internalPage, .unknown, nil: return .secondary
        }
    }

    private var securityTitle: String {
        switch store.currentSiteSecurityInfo?.level {
        case .secure: return "连接是安全的"
        case .warning: return "连接存在安全警告"
        case .dangerous: return "连接不安全"
        case .insecure: return "此连接未加密"
        case .internalPage: return "Rex 内部页面"
        case .pending: return "正在检查连接"
        case .unknown, nil: return "网站信息"
        }
    }

    private var securityDescription: String {
        switch store.currentSiteSecurityInfo?.level {
        case .secure:
            return "发送到此网站的信息会经过加密。"
        case .warning:
            return "连接已加密，但页面包含不安全内容或证书存在警告。"
        case .dangerous:
            return "请勿在此页面输入密码、银行卡等敏感信息。"
        case .insecure:
            return "此页面未使用加密连接，传输内容可能被读取或修改。"
        case .internalPage:
            return "此页面由 Rex 在本地提供，不通过网络加载。"
        case .pending:
            return "Chromium 正在验证当前连接和服务器证书。"
        case .unknown, nil:
            return "尚未取得当前页面的连接安全信息。"
        }
    }

    private func connectionSummary(_ info: SiteSecurityInfo) -> String {
        var components = [info.tlsVersion.displayName]
        if info.contentStatus.contains(.ranInsecureContent) {
            components.append("运行了不安全内容")
        } else if info.contentStatus.contains(.displayedInsecureContent) {
            components.append("显示了不安全内容")
        }
        return components.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct CertificateDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let info: SiteSecurityInfo
    let certificate: SiteCertificate
    @State private var selection = 0

    private var chain: [Data] { certificate.derChain }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(chain.indices), id: \.self) { index in
                    Label(
                        CertificateInspector.subjectSummary(for: chain[index], fallbackIndex: index),
                        systemImage: index == 0 ? "checkmark.seal.fill" : "seal"
                    )
                    .tag(index)
                }
            }
            .navigationTitle("证书链")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("证书查看器")
                            .font(.title2.weight(.semibold))
                        Text(info.url?.host ?? certificate.subject?.displayName ?? "当前网站")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)

                Divider()

                if chain.indices.contains(selection) {
                    CertificateEntryDetails(
                        data: chain[selection],
                        leaf: selection == 0 ? certificate : nil,
                        status: selection == 0 ? info.certificateStatus : [],
                        hasCertificateError: selection == 0 && info.hasCertificateError,
                        certificateErrorCode: selection == 0 ? info.certificateErrorCode : nil
                    )
                } else {
                    ContentUnavailableView("证书不可用", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 580)
    }
}

private struct CertificateEntryDetails: View {
    let data: Data
    let leaf: SiteCertificate?
    let status: SiteCertificateStatus
    let hasCertificateError: Bool
    let certificateErrorCode: Int?

    private var decodedFields: [(String, String)] {
        CertificateInspector.decodedFields(for: data)
    }

    private var hasBlockingError: Bool {
        status.hasBlockingError || hasCertificateError || certificateErrorCode != nil
    }

    private var statusSummary: String {
        guard hasCertificateError || certificateErrorCode != nil else { return status.summary }
        if let certificateErrorCode {
            return "Chromium 检测到证书错误（代码 \(certificateErrorCode)）"
        }
        return "Chromium 检测到证书错误"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: hasBlockingError ? "xmark.seal.fill" : "checkmark.seal.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(hasBlockingError ? Color.red : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CertificateInspector.subjectSummary(for: data, fallbackIndex: 0))
                            .font(.headline)
                        Text(statusSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let leaf {
                    certificateSection("常规") {
                        detailRow("颁发给", leaf.subject?.displayName.nonEmpty ?? "—")
                        detailRow("颁发者", leaf.issuer?.displayName.nonEmpty ?? "—")
                        detailRow("序列号", leaf.serialNumberHex.nonEmpty ?? "—")
                        detailRow("有效期开始", leaf.validFrom?.formatted(date: .long, time: .standard) ?? "—")
                        detailRow("有效期结束", leaf.validTo?.formatted(date: .long, time: .standard) ?? "—")
                    }
                }

                certificateSection("指纹") {
                    detailRow("SHA-256", CertificateInspector.sha256Fingerprint(data))
                    detailRow("DER 大小", ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                }

                if !decodedFields.isEmpty {
                    certificateSection("详细信息") {
                        ForEach(Array(decodedFields.enumerated()), id: \.offset) { _, field in
                            detailRow(field.0, field.1)
                        }
                    }
                }

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CertificatePEMEncoder.encode(data), forType: .string)
                    } label: {
                        Label("复制 PEM", systemImage: "doc.on.doc")
                    }
                    Spacer()
                }
            }
            .padding(22)
        }
    }

    private func certificateSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum CertificatePEMEncoder {
    static func encode(_ data: Data) -> String {
        let body = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let separator = body.hasSuffix("\n") ? "" : "\n"
        return "-----BEGIN CERTIFICATE-----\n\(body)\(separator)-----END CERTIFICATE-----\n"
    }
}

private enum CertificateInspector {
    static func certificate(for data: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, data as CFData)
    }

    static func subjectSummary(for data: Data, fallbackIndex: Int) -> String {
        guard let certificate = certificate(for: data) else { return "证书 \(fallbackIndex + 1)" }
        return (SecCertificateCopySubjectSummary(certificate) as String?)?.nonEmpty
            ?? "证书 \(fallbackIndex + 1)"
    }

    static func sha256Fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    static func decodedFields(for data: Data) -> [(String, String)] {
        guard let certificate = certificate(for: data),
              let values = SecCertificateCopyValues(certificate, nil, nil) as NSDictionary? else {
            return []
        }
        return values.compactMap { key, rawValue -> (String, String)? in
            guard let dictionary = rawValue as? NSDictionary else { return nil }
            let label = (dictionary[kSecPropertyKeyLabel] as? String)?.nonEmpty
                ?? String(describing: key)
            let value = displayValue(dictionary[kSecPropertyKeyValue])
            return value.isEmpty ? nil : (label, value)
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private static func displayValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as Date:
            return value.formatted(date: .long, time: .standard)
        case let value as Data:
            return value.map { String(format: "%02X", $0) }.joined(separator: " ")
        case let value as NSNumber:
            return value.stringValue
        case let value as [Any]:
            return value.map(displayValue).filter { !$0.isEmpty }.joined(separator: "\n")
        case let value as NSDictionary:
            if let nested = value[kSecPropertyKeyValue] {
                return displayValue(nested)
            }
            return value.allValues.map(displayValue).filter { !$0.isEmpty }.joined(separator: "\n")
        default:
            return value.map { String(describing: $0) } ?? ""
        }
    }
}

private extension SiteTLSVersion {
    var displayName: String {
        switch self {
        case .unknown: return "未识别的协议"
        case .ssl2: return "SSL 2.0"
        case .ssl3: return "SSL 3.0"
        case .tls1: return "TLS 1.0"
        case .tls1_1: return "TLS 1.1"
        case .tls1_2: return "TLS 1.2"
        case .tls1_3: return "TLS 1.3"
        case .quic: return "QUIC"
        }
    }
}

private extension SiteCertificateStatus {
    var hasBlockingError: Bool {
        !intersection(.blockingStatuses).isEmpty
    }

    var summary: String {
        if contains(.revoked) { return "证书已被吊销" }
        if contains(.dateInvalid) { return "证书已过期或尚未生效" }
        if contains(.commonNameInvalid) { return "证书名称与网站不匹配" }
        if contains(.authorityInvalid) { return "证书颁发机构不受信任" }
        if hasBlockingError { return "Chromium 检测到证书错误" }
        if !intersection(.warningStatuses).isEmpty { return "证书有效，但存在安全警告" }
        return "此证书由 Chromium 验证"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct WebsitePermissionPromptBar: View {
    @EnvironmentObject private var store: BrowserStore
    let prompt: WebsitePermissionPrompt

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: prompt.request.kinds.first?.symbolName ?? "hand.raised.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(permissionDescription)
                    .font(.system(size: 13, weight: .semibold))
                Text(prompt.request.requestingOrigin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Button("阻止") { store.respond(to: prompt, with: .blockAlways) }
                .buttonStyle(.bordered)
            Button("允许") { store.respond(to: prompt, with: .allowOnce) }
                .buttonStyle(.borderedProminent)

            Menu {
                Button("始终允许") { store.respond(to: prompt, with: .allowAlways) }
                Button("关闭标签页时撤销") { store.respond(to: prompt, with: .revokeOnTabClose) }
                Divider()
                Button("暂不决定") { store.respond(to: prompt, with: .ask) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多权限选项")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 620, minHeight: 54)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var permissionDescription: String {
        let names = prompt.request.kinds.map(\.displayName).joined(separator: "、")
        return "是否允许此网站使用\(names)？"
    }
}

private struct BrowserFindBar: View {
    @EnvironmentObject private var store: BrowserStore
    @FocusState private var findFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("在页面中查找", text: $store.findText)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .frame(width: 210)
                .onSubmit { store.findNext() }
                .onChange(of: store.findText) { _, _ in store.updateFind() }

            findButton(systemName: "chevron.up", label: "查找上一个") {
                store.findNext(forward: false)
            }
            findButton(systemName: "chevron.down", label: "查找下一个") {
                store.findNext()
            }
            findButton(systemName: "xmark", label: "关闭查找") {
                store.dismissFind()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .onAppear { findFocused = true }
        .onChange(of: store.findFocusRequest) { _, _ in findFocused = true }
        .onExitCommand { store.dismissFind() }
    }

    private func findButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
