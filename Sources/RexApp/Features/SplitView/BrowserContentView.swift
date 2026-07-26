import Combine
import AppKit
import SwiftUI
import WebKit

struct BrowserContentView: View {
    @EnvironmentObject private var store: BrowserStore
    let windowSize: CGSize

    var body: some View {
        LiquidGlassPanel(cornerRadius: 18, clipsContent: false, showsShadow: false) {
            GeometryReader { proxy in
                let layoutGeometry = SplitLayoutGeometry(
                    size: proxy.size,
                    ratio: store.splitSession?.ratio ?? 0.5,
                    dividerWidth: RexMetrics.dividerHitWidth
                )

                Group {
                    if store.isRestoringSession {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("正在恢复会话")
                    } else if store.currentTab != nil {
                        browserLayout(geometry: layoutGeometry)
                    } else {
                        ContentUnavailableView("没有打开的标签页", systemImage: "rectangle.on.rectangle.slash")
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            ZStack {
                WindowedCEFViewportCornerCover(cornerRadius: 18, windowSize: windowSize)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Browser surfaces stay keyed by tab ID while split operations move them.
    private func browserLayout(geometry: SplitLayoutGeometry) -> some View {
        let items = splitLayoutItems(geometry: geometry)

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                BrowserPane(
                    tab: item.tab,
                    pane: item.pane,
                    isFocused: item.isFocused
                )
                    .frame(width: item.frame.width, height: item.frame.height)
                    .position(x: item.frame.midX, y: item.frame.midY)
            }

            if items.count == 2 {
                LiquidGlassSplitDivider(
                    orientation: .horizontal,
                    availableLength: geometry.size.width
                )
                .frame(
                    width: geometry.dividerFrame.width,
                    height: geometry.dividerFrame.height
                )
                .position(x: geometry.dividerFrame.midX, y: geometry.dividerFrame.midY)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    private func splitLayoutItems(geometry: SplitLayoutGeometry) -> [SplitLayoutItem] {
        if let session = store.splitSession,
           let primary = store.primaryTab,
           let secondary = store.secondaryTab {
            return [
                SplitLayoutItem(
                    tab: primary,
                    pane: .primary,
                    frame: geometry.paneFrame(for: .primary),
                    isFocused: session.focusedPane == .primary
                ),
                SplitLayoutItem(
                    tab: secondary,
                    pane: .secondary,
                    frame: geometry.paneFrame(for: .secondary),
                    isFocused: session.focusedPane == .secondary
                )
            ]
        }
        guard let tab = store.currentTab else { return [] }
        return [
            SplitLayoutItem(
                tab: tab,
                pane: nil,
                frame: CGRect(origin: .zero, size: geometry.size),
                isFocused: true
            )
        ]
    }
}

private struct SplitLayoutItem: Identifiable {
    let tab: BrowserTab
    let pane: SplitPane?
    let frame: CGRect
    let isFocused: Bool

    var id: UUID { tab.id }
}

private struct BrowserPane: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: BrowserTab
    let pane: SplitPane?
    let isFocused: Bool

    var body: some View {
        Group {
            if BrowserStartPage.matches(tab.url) {
                BrowserStartPageView(tabID: tab.id)
            } else {
#if REX_CEF
                ChromiumBrowserSurface(tab: tab, profile: store.profile)
                    .id(tab.id)
#else
                PrototypeWebSurface(url: tab.url)
                    .id(tab.id)
#endif
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if let pane { store.focus(pane) }
        })
        .accessibilityLabel("\(tab.title)网页，\(isFocused ? "已聚焦" : "未聚焦")")
    }
}

private struct BrowserStartPageView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.openWindow) private var openWindow
    let tabID: UUID
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private var recentHistory: [BrowserHistoryEntry] {
        store.history
            .filter { !BrowserStartPage.matches($0.url) }
            .prefix(6)
            .map { $0 }
    }

    private var topBookmarks: [BrowserBookmark] {
        Array(store.bookmarks.prefix(8))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    Color.accentColor.opacity(0.07),
                    Color(nsColor: .textBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ScrollView {
                VStack(spacing: 28) {
                    header
                    searchField
                    quickActions
                    if !store.profile.isPrivate || !topBookmarks.isEmpty || !recentHistory.isEmpty {
                        contentGrid
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 36)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if store.selectedTabID == tabID {
                isSearchFocused = true
            }
        }
        .onChange(of: store.selectedTabID) { _, selected in
            if selected == tabID {
                isSearchFocused = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("R")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(greeting)")
                    .font(.system(size: 22, weight: .semibold))
                Text("使用 \(store.preferences.searchEngine.displayName) 搜索，或直接输入网址")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                store.presentSettings(.search)
            } label: {
                Label("搜索引擎设置", systemImage: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("在设置中更改默认搜索引擎")
        }
        .frame(maxWidth: 720)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: store.preferences.searchEngine.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            TextField("搜索或输入网址", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { submit() }
                .accessibilityLabel("起始页搜索框")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }

            Button(action: submit) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("打开")
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 720)
        .frame(height: 48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? Color.accentColor.opacity(0.75) : .white.opacity(0.14),
                    lineWidth: isSearchFocused ? 1.5 : 0.75
                )
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction(symbol: "plus.rectangle.on.rectangle", title: "新标签页") {
                store.newTab()
            }
            quickAction(symbol: "eye.slash", title: "隐私窗口") {
                openWindow(id: "private-browser", value: UUID())
            }
            if !store.profile.isPrivate {
                quickAction(symbol: "clock.arrow.circlepath", title: "历史记录") {
                    store.presentLibrary(.history)
                }
                quickAction(symbol: "star", title: "书签") {
                    store.presentLibrary(.bookmarks)
                }
                quickAction(symbol: "arrow.down.circle", title: "下载") {
                    store.presentLibrary(.downloads)
                }
            }
            quickAction(
                symbol: "arrow.uturn.backward",
                title: "恢复标签",
                isDisabled: !store.canRestoreClosedTab
            ) {
                store.restoreClosedTab()
            }
            quickAction(symbol: "puzzlepiece.extension", title: "扩展") {
                store.isExtensionsPresented = true
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var favoriteSitesSection: some View {
        startSection(title: "收藏网站", symbol: "square.grid.2x2.fill") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                ForEach(store.newTabFavorites.prefix(12)) { favorite in
                    favoriteSiteCard(favorite)
                }
                addFavoriteCard
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
    }

    private var contentGrid: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !store.profile.isPrivate || !recentHistory.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    if !recentHistory.isEmpty {
                        recentHistorySection
                            .frame(maxWidth: 320, alignment: .topLeading)
                    }

                    if !store.profile.isPrivate {
                        favoriteSitesSection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }

            if !topBookmarks.isEmpty {
                startSection(title: "书签", symbol: "star.fill") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(topBookmarks) { bookmark in
                            Button {
                                open(url: bookmark.url)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 24, height: 24)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Text(bookmark.url.host ?? bookmark.url.absoluteString)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(bookmark.url.absoluteString)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
    }

    private var recentHistorySection: some View {
        startSection(title: "最近访问", symbol: "clock.fill") {
            VStack(spacing: 6) {
                ForEach(recentHistory) { entry in
                    Button {
                        open(url: entry.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(entry.url.host ?? entry.url.absoluteString)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(entry.visitedAt, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(entry.url.absoluteString)
                }
            }
        }
    }

    private func startSection<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
        }
    }

    private func quickAction(
        symbol: String,
        title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 76)
            .opacity(isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
    }

    private func favoriteSiteCard(_ favorite: NewTabFavoriteSite) -> some View {
        Button {
            open(url: favorite.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(favorite.url.host ?? favorite.url.absoluteString)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .help(favorite.url.absoluteString)
        .contextMenu {
            Button("打开") { open(url: favorite.url) }
            Button("移除", role: .destructive) {
                store.removeNewTabFavorite(favorite)
            }
        }
    }

    private var addFavoriteCard: some View {
        Menu {
            if let url = store.currentTab?.url, !BrowserStartPage.matches(url) {
                Button("收藏当前页面") {
                    store.addNewTabFavorite(title: store.currentTab?.title, url: url)
                }
            }
            Button("从剪贴板添加网址") {
                addFavoriteFromPasteboard()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加网站")
                        .font(.system(size: 12, weight: .semibold))
                    Text("仅新标签页")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .menuStyle(.borderlessButton)
        .help("添加仅在新标签页显示的收藏网站，与网页收藏独立")
    }

    private func addFavoriteFromPasteboard() {
        let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            store.lastError = "剪贴板中没有可用的网址"
            return
        }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate), url.host != nil else {
            store.lastError = "无法识别剪贴板中的网址"
            return
        }
        store.addNewTabFavorite(title: url.host, url: url)
    }

    private func open(url: URL) {
        if store.selectedTabID != tabID {
            store.selectTab(tabID)
        }
        store.addressText = url.absoluteString
        store.submitAddress()
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.selectedTabID != tabID {
            store.selectTab(tabID)
        }
        store.addressText = trimmed
        store.submitAddress()
    }
}

private final class SplitDividerViewModel: ObservableObject {
    @Published var initialRatio: Double?
    @Published var isHovering = false
}

private struct LiquidGlassSplitDivider: View {
    @EnvironmentObject private var store: BrowserStore
    let orientation: SplitOrientation
    let availableLength: CGFloat
    @StateObject private var model = SplitDividerViewModel()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.clear)

            Capsule()
                .fill(model.isHovering ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.28))
                .frame(
                    width: orientation == .horizontal ? (model.isHovering ? 4 : 1) : 42,
                    height: orientation == .horizontal ? 42 : (model.isHovering ? 4 : 1)
                )

            if model.isHovering {
                Image(systemName: orientation == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .frame(
            width: orientation == .horizontal ? RexMetrics.dividerHitWidth : nil,
            height: orientation == .vertical ? RexMetrics.dividerHitWidth : nil
        )
        .contentShape(Rectangle())
        .onHover { model.isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let base = model.initialRatio ?? store.splitSession?.ratio ?? 0.5
                    if model.initialRatio == nil { model.initialRatio = base }
                    let delta = orientation == .horizontal ? value.translation.width : value.translation.height
                    store.setSplitRatio(base + delta / max(availableLength, 1))
                }
                .onEnded { _ in model.initialRatio = nil }
        )
        .help("拖动调整分屏比例")
        .accessibilityLabel("分屏分隔条")
        .accessibilityValue("\(Int((store.splitSession?.ratio ?? 0.5) * 100))%")
    }
}

/// Temporary visual-design surface. The production implementation will be an
/// AppKit host for CEF and must preserve one native browser instance per tab.
private struct PrototypeWebSurface: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        loadIfNeeded(in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        loadIfNeeded(in: view, coordinator: context.coordinator)
    }

    private func loadIfNeeded(in view: WKWebView, coordinator: Coordinator) {
        guard coordinator.lastURL != url else { return }
        coordinator.lastURL = url
        guard let url, !BrowserStartPage.matches(url) else {
            view.loadHTMLString(Self.startPage, baseURL: nil)
            return
        }
        view.load(URLRequest(url: url))
    }

    final class Coordinator {
        var lastURL: URL?
    }

    private static let startPage = """
    <!doctype html><html><head><meta name='viewport' content='width=device-width'>
    <style>body{margin:0;font:15px -apple-system;color:#667;display:grid;place-items:center;height:100vh;
    background:linear-gradient(145deg,#f4f1ff,#e8f5f5)}.card{text-align:center;padding:42px;border-radius:28px;
    background:rgba(255,255,255,.68);box-shadow:0 24px 80px #6672}.mark{font-size:42px;font-weight:750;color:#6e62da}
    h1{margin:12px 0 5px;color:#273047}p{max-width:340px;line-height:1.55}</style></head>
    <body><div class='card'><div class='mark'>R</div><h1>欢迎使用 Rex</h1>
    <p>输入网址或搜索内容。这里是交互设计预览，生产版本将接入 Chromium。</p></div></body></html>
    """
}
