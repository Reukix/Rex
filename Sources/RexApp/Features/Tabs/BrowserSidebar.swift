import AppKit
import Combine
import SwiftUI

private final class BrowserSidebarViewModel: ObservableObject {
    @Published var isCreatingGroup = false
    @Published var groupName = ""
}

struct BrowserSidebar: View {
    @EnvironmentObject private var store: BrowserStore
    @StateObject private var model = BrowserSidebarViewModel()

    var body: some View {
        LiquidGlassPanel(showsShadow: false) {
            VStack(spacing: 0) {
                spaceSwitcher
                    .padding(store.isSidebarCollapsed ? 6 : 8)

                Divider().opacity(0.3)

                if store.isSidebarCollapsed {
                    collapsedTabs
                } else {
                    searchField
                    expandedTabs
                }

                Divider().opacity(0.3)
                bottomBar
            }
        }
        .alert("新建标签分组", isPresented: $model.isCreatingGroup) {
            TextField("分组名称", text: $model.groupName)
            Button("取消", role: .cancel) { model.groupName = "" }
            Button("创建") {
                _ = store.createGroup(name: model.groupName)
                model.groupName = ""
            }
            .disabled(model.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var spaceSwitcher: some View {
        Group {
            if store.isSidebarCollapsed {
                VStack(spacing: 6) {
                    ForEach(store.spaces) { space in
                        spaceButton(space)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 6) {
                    ForEach(store.spaces) { space in
                        spaceButton(space)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func spaceButton(_ space: BrowserSpace) -> some View {
        Button {
            store.switchSpace(to: space.id)
        } label: {
            Image(systemName: space.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.currentSpaceID == space.id ? .white : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        store.currentSpaceID == space.id
                            ? Color(hex: space.tintHex)
                            : Color.white.opacity(0.07)
                    )
                )
        }
        .buttonStyle(.plain)
        .help(space.name)
        .accessibilityLabel("\(space.name)工作空间")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索标签页", text: $store.searchQuery)
                .textFieldStyle(.plain)
            if !store.searchQuery.isEmpty {
                Button { store.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var collapsedTabs: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if !store.sidebarBookmarks.isEmpty {
                    collapsedSectionHeader("收藏", symbol: "star.fill")
                    ForEach(store.sidebarBookmarks) { bookmark in
                        SidebarBookmarkButton(bookmark: bookmark, size: 34)
                            .frame(width: 38, height: 38)
                            .frame(maxWidth: .infinity)
                    }
                }

                if !store.sidebarPinnedTabs.isEmpty {
                    collapsedSectionHeader("固定", symbol: "pin.fill")
                    ForEach(store.sidebarPinnedTabs) { tab in
                        CollapsedTabButton(tab: tab)
                    }
                }

                if !store.sidebarRegularTabs.isEmpty {
                    if !store.sidebarBookmarks.isEmpty || !store.sidebarPinnedTabs.isEmpty {
                        collapsedSectionHeader("标签页", symbol: "rectangle.stack")
                    }
                    ForEach(store.sidebarRegularTabs) { tab in
                        CollapsedTabButton(tab: tab)
                    }
                }

                if store.sidebarBookmarks.isEmpty && store.visibleTabs.isEmpty &&
                    !store.searchQuery.isEmpty {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .help("没有匹配结果")
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private var expandedTabs: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                let favorites = store.sidebarBookmarks
                if !favorites.isEmpty {
                    sectionHeader("收藏", symbol: "star.fill")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(favorites) { bookmark in
                            SidebarBookmarkButton(bookmark: bookmark, size: 36)
                        }
                    }
                    .padding(.horizontal, 10)
                }

                let pinned = store.visibleTabs.filter { $0.isPinned && $0.groupID == nil }
                if !pinned.isEmpty {
                    sectionHeader("固定", symbol: "pin.fill")
                    ForEach(pinned) { tab in
                        LiquidGlassTabRow(tab: tab, isSelected: store.selectedTabID == tab.id)
                    }
                }

                ForEach(store.currentGroups) { group in
                    let groupTabs = store.visibleTabs.filter { group.tabIDs.contains($0.id) }
                    if !groupTabs.isEmpty || store.searchQuery.isEmpty {
                        GroupHeader(group: group, tabCount: groupTabs.count)
                        if !group.isCollapsed {
                            ForEach(groupTabs) { tab in
                                LiquidGlassTabRow(tab: tab, isSelected: store.selectedTabID == tab.id, isIndented: true)
                            }
                        }
                    }
                }

                let ungrouped = store.visibleTabs.filter { !$0.isPinned && $0.groupID == nil }
                if !ungrouped.isEmpty {
                    sectionHeader("标签页", symbol: "rectangle.stack")
                    ForEach(ungrouped) { tab in
                        LiquidGlassTabRow(tab: tab, isSelected: store.selectedTabID == tab.id)
                            .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: TabDropDelegate(tabID: tab.id, store: store))
                    }
                }

                if !store.archivedTabs.isEmpty && store.searchQuery.isEmpty {
                    sectionHeader("归档", symbol: "archivebox.fill")
                    ForEach(store.archivedTabs) { tab in
                        ArchivedTabRow(tab: tab)
                    }
                }

                if store.visibleTabs.isEmpty && store.sidebarBookmarks.isEmpty &&
                    !store.searchQuery.isEmpty {
                    ContentUnavailableView.search(text: store.searchQuery)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(.vertical, 5)
        }
    }

    private var bottomBar: some View {
        Group {
            if store.isSidebarCollapsed {
                VStack(spacing: 6) {
                    Button(action: store.newTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("新建标签页")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 4) {
                    Button(action: store.newTab) {
                        Label("新建标签页", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("新建标签页")

                    Button {
                        model.groupName = ""
                        model.isCreatingGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("新建标签分组")
                }
                .padding(8)
            }
        }
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 7)
    }

    private func collapsedSectionHeader(_ title: String, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 16)
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct SidebarBookmarkButton: View {
    @EnvironmentObject private var store: BrowserStore
    let bookmark: BrowserBookmark
    let size: CGFloat

    var body: some View {
        Button {
            store.openBookmark(bookmark)
        } label: {
            BookmarkFavicon(bookmark: bookmark)
                .frame(width: size, height: size)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(bookmark.title)
        .contextMenu {
            Button("打开") { store.openBookmark(bookmark) }
            Button("取消收藏", role: .destructive) {
                store.removeBookmark(bookmark)
            }
        }
        .accessibilityLabel(bookmark.title)
    }
}

private struct BookmarkFavicon: View {
    @EnvironmentObject private var store: BrowserStore
    let bookmark: BrowserBookmark

    var body: some View {
        Group {
            if let tab = store.tabs.first(where: { $0.url == bookmark.url }),
               let data = store.faviconData(for: tab.id),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(1)
            } else {
                FallbackFavicon(title: bookmark.title, url: bookmark.url)
            }
        }
        .frame(width: 19, height: 19)
    }
}

private struct GroupHeader: View {
    @EnvironmentObject private var store: BrowserStore
    let group: TabGroup
    let tabCount: Int

    var body: some View {
        Button { store.toggleGroup(group.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
                Image(systemName: group.symbolName)
                Text(group.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(tabCount)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除分组", role: .destructive) { store.deleteGroup(group.id) }
        }
        .padding(.horizontal, 7)
    }
}

private struct LiquidGlassTabRow: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: BrowserTab
    let isSelected: Bool
    var isIndented = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button { store.selectTab(tab.id) } label: {
                HStack(spacing: 9) {
                    TabFavicon(tab: tab)

                    Text(tab.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if tab.isPlayingAudio {
                        Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption2)
                    }
                    if tab.splitSessionID != nil {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.caption2)
                    }
                    if tab.privacyState.blockedCount > 0 && !isHovered && !isSelected {
                        Text("\(tab.privacyState.blockedCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .padding(.leading, isIndented ? 22 : 10)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovered || isSelected ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(.white.opacity(isHovered || isSelected ? 0.16 : 0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("关闭标签页")
            .opacity(isHovered || isSelected ? 1 : 0.72)
            .padding(.trailing, 8)
            .accessibilityLabel("关闭 \(tab.title)")
        }
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: RexMetrics.compactRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.white.opacity(isHovered ? 0.12 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: RexMetrics.compactRadius, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.26 : 0.1), lineWidth: 0.75)
        }
        .padding(.horizontal, 7)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu { TabContextActions(tab: tab) }
        .fastTooltip(tab.url.map { "\(tab.title)\n\($0.absoluteString)" } ?? tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "当前标签页" : "")
        .accessibilityAction(named: "关闭") { store.closeTab(tab.id) }
    }
}

private struct CollapsedTabButton: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: BrowserTab
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { store.selectTab(tab.id) } label: {
                TabFavicon(tab: tab)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(store.selectedTabID == tab.id ? Color.accentColor.opacity(0.23) : .white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .fastTooltip(tab.url.map { "\(tab.title)\n\($0.absoluteString)" } ?? tab.title)

            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 13, height: 13)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .offset(x: 3, y: -3)
            .opacity(isHovered || store.selectedTabID == tab.id ? 1 : 0.55)
            .help("关闭标签页")
            .accessibilityLabel("关闭 \(tab.title)")
        }
        .frame(width: 38, height: 38)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .contextMenu { TabContextActions(tab: tab) }
        .accessibilityLabel(tab.title)
        .accessibilityAction(named: "关闭") { store.closeTab(tab.id) }
    }
}

private struct ArchivedTabRow: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 9) {
            TabFavicon(tab: tab)
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.restoreArchivedTab(tab.id) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("恢复标签页")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .padding(.horizontal, 7)
        .fastTooltip(tab.url.map { "\(tab.title)\n\($0.absoluteString)" } ?? tab.title)
        .contextMenu {
            Button("恢复") { store.restoreArchivedTab(tab.id) }
            Button("永久关闭", role: .destructive) { store.closeTab(tab.id) }
        }
    }
}

private struct TabContextActions: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        Button("新建标签页") { store.newTab() }
        Button("重新加载") { store.reloadTab(tab.id) }
        Divider()
        Button("复制标签页") { store.duplicateTab(tab.id) }
        Button(tab.isMuted ? "取消静音" : "将标签页静音") {
            store.toggleMuted(tab.id)
        }
        Divider()
        Button(tab.isPinned ? "取消固定" : "固定标签页") {
            store.togglePinned(tab.id)
        }
        Button(tab.isFavorite ? "取消收藏" : "收藏页面") {
            store.toggleBookmark(for: tab)
        }
        Menu {
            splitMenuContent
        } label: {
            Label("分屏", systemImage: "rectangle.split.2x1")
        }

        Menu("移动到分组") {
            Button("不属于分组") { store.moveTab(tab.id, toGroup: nil) }
            Divider()
            ForEach(store.currentGroups) { group in
                Button(group.name) { store.moveTab(tab.id, toGroup: group.id) }
            }
        }

        Menu("移动到工作空间") {
            ForEach(store.spaces.filter { $0.id != tab.spaceID }) { space in
                Button(space.name) { store.moveTab(tab.id, toSpace: space.id) }
            }
        }
        .disabled(store.spaces.count < 2 || tab.splitSessionID != nil)

        Button(tab.isSleeping ? "唤醒标签页" : "休眠标签页") {
            store.setTabSleeping(tab.id, sleeping: !tab.isSleeping)
        }
        .disabled(!tab.isSleeping && (tab.id == store.selectedTabID || tab.isPinned || tab.isPlayingAudio || tab.splitSessionID != nil))

        Divider()
        Button("归档") { store.archiveTab(tab.id) }
            .disabled(tab.splitSessionID != nil)
        Button("关闭", role: .destructive) { store.closeTab(tab.id) }
    }

    @ViewBuilder
    private var splitMenuContent: some View {
        if store.splitSession == nil {
            if store.selectedTabID == tab.id {
                Button {
                    store.toggleSplit()
                } label: {
                    Label("创建分屏", systemImage: "rectangle.split.2x1")
                }
            } else {
                placeButton(in: .primary, title: "放到左侧")
                placeButton(in: .secondary, title: "放到右侧")
            }
        } else if let sourcePane = activeSplitPane {
            let targetPane: SplitPane = sourcePane == .primary ? .secondary : .primary
            placeButton(
                in: targetPane,
                title: sourcePane == .primary ? "移到右侧" : "移到左侧"
            )
            Divider()
            Button {
                store.endSplit(keeping: tab.id)
            } label: {
                Label("关闭分屏，仅保留此标签页", systemImage: "rectangle")
            }
        } else {
            placeButton(in: .primary, title: "替换左侧页面")
            placeButton(in: .secondary, title: "替换右侧页面")
        }
    }

    private var activeSplitPane: SplitPane? {
        guard let session = store.splitSession else { return nil }
        if session.primaryTabID == tab.id { return .primary }
        if session.secondaryTabID == tab.id { return .secondary }
        return nil
    }

    private func placeButton(in pane: SplitPane, title: String) -> some View {
        Button {
            _ = store.placeTab(tab.id, in: pane)
        } label: {
            Label(
                title,
                systemImage: pane == .primary
                    ? "rectangle.leadinghalf.inset.filled"
                    : "rectangle.trailinghalf.inset.filled"
            )
        }
        .disabled(!store.canPlaceTab(tab.id, in: pane))
    }
}

struct TabFavicon: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        Group {
            if let data = store.faviconData(for: tab.id),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(1)
            } else {
                fallbackFavicon
            }
        }
        .frame(width: 19, height: 19)
        .overlay(alignment: .bottomTrailing) {
            if tab.lifecycle == .sleeping {
                Image(systemName: "moon.fill")
                    .font(.system(size: 6))
            }
        }
    }

    private var fallbackFavicon: some View {
        FallbackFavicon(title: tab.title, url: tab.url)
    }
}

private struct FallbackFavicon: View {
    let title: String
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(faviconColor.opacity(0.2))
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(faviconColor)
        }
    }

    private var faviconColor: Color {
        let colors: [Color] = [.indigo, .cyan, .pink, .orange, .green]
        // Swift 的 hashValue 每次启动都会变化；用稳定的 FNV-1a 使同一站点
        // 在多次启动间保持相同的后备色。
        let seed = url?.host ?? title
        let hash = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

private struct TabDropDelegate: DropDelegate {
    let tabID: UUID
    let store: BrowserStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let str = object as? String,
                  let fromID = UUID(uuidString: str),
                  fromID != tabID else { return }
            DispatchQueue.main.async {
                store.moveTab(fromID, before: tabID)
            }
        }
        return true
    }
}
