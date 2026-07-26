import AppKit
import SwiftUI

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case general = "常规"
    case search = "搜索引擎"
    case privacy = "隐私与安全"
    case downloads = "下载内容"
    case appearance = "外观"
    case about = "关于 Rex"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .search: "magnifyingglass"
        case .privacy: "shield.lefthalf.filled"
        case .downloads: "arrow.down.circle"
        case .appearance: "paintpalette"
        case .about: "info.circle"
        }
    }

    var searchTerms: String {
        switch self {
        case .general: "默认 恢复 上次会话 继续浏览 标签休眠 自动休眠 延迟 分钟 重置"
        case .search: "Google Bing DuckDuckGo Brave Ecosia 地址栏"
        case .privacy: "权限 Cookie 第三方 HTTPS 自动升级 安全 摄像头 麦克风 广告 拦截 追踪 域名 目录 盾牌"
        case .downloads: "文件夹 保存 下载位置"
        case .appearance: "侧栏 界面 显示 外观 主题 系统 浅色 深色 性能指标 内存 CPU"
        case .about: "版本 Chromium CEF 更新 功能"
        }
    }
}

struct BrowserSettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @EnvironmentObject private var preferences: BrowserPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let aboutInformation: RexAboutInformation?
    private let aboutLoadError: String?

    init() {
        do {
            aboutInformation = try ReleaseNotesService.loadAboutInformation()
            aboutLoadError = nil
        } catch {
            aboutInformation = nil
            aboutLoadError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Label("设置", systemImage: "globe")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)

                List(filteredSections, selection: $store.settingsSection) { section in
                    Label(section.rawValue, systemImage: section.symbolName)
                        .tag(section)
                        .padding(.vertical, 3)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            VStack(spacing: 0) {
                settingsToolbar
                Divider()
                ScrollView {
                    Group {
                        if filteredSections.isEmpty {
                            ContentUnavailableView(
                                "未找到设置",
                                systemImage: "magnifyingglass",
                                description: Text("没有与“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”匹配的设置")
                            )
                            .frame(maxWidth: .infinity, minHeight: 360)
                        } else {
                            selectedContent
                        }
                    }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(28)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 920, minHeight: 620)
        .onChange(of: query) { _, _ in
            guard let firstMatch = filteredSections.first,
                  !filteredSections.contains(store.settingsSection) else { return }
            store.settingsSection = firstMatch
        }
    }

    private var settingsToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索设置", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 520, minHeight: 34)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

            Spacer()

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch store.settingsSection {
        case .general:
            settingsPage(
                title: "常规",
                subtitle: "管理 Rex 的窗口、标签页与工作空间行为"
            ) {
                settingsCard {
                    Toggle(isOn: restorePreviousSessionBinding) {
                        SettingsRow(
                            icon: "clock.arrow.circlepath",
                            title: "恢复上次浏览会话",
                            detail: "启动 Rex 时重新打开之前的窗口、标签页和分屏组合"
                        )
                    }
                    .toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: automaticTabSleepingBinding) {
                        SettingsRow(
                            icon: "moon.zzz.fill",
                            title: "自动休眠闲置标签页",
                            detail: "降低长时间未使用页面的资源占用"
                        )
                    }
                    .toggleStyle(.switch)
                    Divider()
                    HStack(spacing: 14) {
                        SettingsRow(
                            icon: "timer",
                            title: "休眠延迟",
                            detail: "标签页闲置多久后自动进入休眠"
                        )
                        Picker("休眠延迟", selection: tabSleepDelayBinding) {
                            ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
                                Text(sleepDelayLabel(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    .disabled(!preferences.automaticTabSleeping)
                    .opacity(preferences.automaticTabSleeping ? 1 : 0.55)
                    Divider()
                    Button(action: resetPreferences) {
                        SettingsRow(
                            icon: "arrow.counterclockwise",
                            title: "恢复默认设置",
                            detail: "重置搜索、常规、隐私和外观偏好"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .search:
            settingsPage(
                title: "搜索引擎",
                subtitle: "选择在地址栏输入关键词时使用的默认搜索服务"
            ) {
                SearchEnginePicker(preferences: preferences)
            }
        case .privacy:
            settingsPage(
                title: "隐私与安全",
                subtitle: "管理广告拦截、连接升级、Cookie 策略与网站权限"
            ) {
                settingsCard {
                    Toggle(isOn: contentBlockingBinding) {
                        SettingsRow(
                            icon: "shield.lefthalf.filled.badge.checkmark",
                            title: "拦截广告与追踪器",
                            detail: "使用内置的已知广告与追踪服务域名目录，仅拦截第三方请求，不影响网站自身资源；严格级别额外拦截指纹与社交组件"
                        )
                    }
                    .toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: httpsUpgradeBinding) {
                        SettingsRow(
                            icon: "lock.fill",
                            title: "自动升级到 HTTPS",
                            detail: "在支持的网站上优先使用加密连接"
                        )
                    }
                    .toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: blockThirdPartyCookiesBinding) {
                        SettingsRow(
                            icon: "circle.hexagongrid.fill",
                            title: "限制第三方 Cookie",
                            detail: "将第三方 Cookie 限制应用到所有网页"
                        )
                    }
                    .toggleStyle(.switch)
                    Divider()
                    Button {
                        store.isPermissionCenterPresented = true
                        dismiss()
                    } label: {
                        SettingsRow(
                            icon: "hand.raised.fill",
                            title: "网站权限",
                            detail: "查看和修改摄像头、麦克风等网站权限",
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .downloads:
            settingsPage(
                title: "下载内容",
                subtitle: "下载位置独立保存在当前工作空间"
            ) {
                settingsCard {
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("下载位置")
                                .font(.headline)
                            Text(store.currentDownloadDirectoryName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("更改…", action: chooseDownloadDirectory)
                        if store.currentDownloadDirectoryURL != nil {
                            Button("每次询问") { store.setDownloadDirectory(nil) }
                        }
                    }
                }
            }
        case .appearance:
            settingsPage(
                title: "外观",
                subtitle: "调整 Rex 窗口中的常用布局"
            ) {
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRow(
                            icon: "circle.lefthalf.filled",
                            title: "界面主题",
                            detail: "跟随系统，或始终使用浅色或深色外观"
                        )
                        Picker("界面主题", selection: appearanceBinding) {
                            ForEach(BrowserAppearance.allCases) { appearance in
                                Text(appearance.displayName).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Divider()
                    Toggle(isOn: defaultSidebarCollapsedBinding) {
                        SettingsRow(
                            icon: "sidebar.left",
                            title: "默认折叠侧栏",
                            detail: "新窗口默认使用紧凑的侧栏图标轨道"
                        )
                    }
                    .toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: showPerformanceMetricsBinding) {
                        SettingsRow(
                            icon: "gauge.with.dots.needle.50percent",
                            title: "显示性能指标",
                            detail: "在工具栏显示 Rex 的内存与 CPU 占用"
                        )
                    }
                    .toggleStyle(.switch)
                }
            }
        case .about:
            settingsPage(
                title: "关于 Rex",
                subtitle: "版本、运行环境、关键能力与当前限制"
            ) {
                aboutContent
            }
        }
    }

    @ViewBuilder
    private var aboutContent: some View {
        if let information = aboutInformation {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rex \(information.version)")
                                .font(.title2.bold())
                            Text("构建 \(information.build) · \(information.channelDisplayName) 通道")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                aboutSectionTitle("运行环境", detail: "实际随当前应用构建发布")
                settingsCard {
                    aboutMetadataRow("Chromium", value: information.chromiumVersion ?? "不可用")
                    Divider()
                    aboutMetadataRow("CEF", value: information.cefVersion)
                    Divider()
                    aboutMetadataRow("架构", value: information.architecture)
                    Divider()
                    aboutMetadataRow("功能目录", value: "v\(information.featureCatalogVersion)")
                }

                aboutSectionTitle(
                    "关键能力",
                    detail: "来自内置功能目录，共 \(information.capabilityGroups.count) 个分组"
                )
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(information.capabilityGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.name)
                                .font(.headline)
                            Text(group.statusSummary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                            Text(group.featureNames.joined(separator: "、"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
                        }
                    }
                }

                aboutSectionTitle(
                    "已知限制",
                    detail: information.knownLimitations.isEmpty ? "当前版本没有记录限制" : "来自当前版本发布数据"
                )
                settingsCard {
                    if information.knownLimitations.isEmpty {
                        Text("当前版本没有记录已知限制")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(information.knownLimitations.enumerated()), id: \.offset) { index, limitation in
                            Label(limitation, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                            if index < information.knownLimitations.count - 1 {
                                Divider()
                            }
                        }
                    }
                }

                settingsCard {
                    Button {
                        store.isReleaseNotesPresented = true
                        dismiss()
                    } label: {
                        SettingsRow(
                            icon: "sparkles",
                            title: "版本与功能",
                            detail: "查看完整发布说明、功能状态和每项能力的详细限制",
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            ContentUnavailableView(
                "无法读取版本与功能数据",
                systemImage: "exclamationmark.triangle",
                description: Text(aboutLoadError ?? "内置发布数据不可用")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private func aboutSectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func aboutMetadataRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
    }

    private var filteredSections: [BrowserSettingsSection] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return BrowserSettingsSection.allCases }
        let matches = BrowserSettingsSection.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(value) ||
                $0.searchTerms.localizedCaseInsensitiveContains(value)
        }
        return matches
    }

    private var restorePreviousSessionBinding: Binding<Bool> {
        Binding(
            get: { preferences.restorePreviousSession },
            set: { preferences.setRestorePreviousSession($0) }
        )
    }

    private var automaticTabSleepingBinding: Binding<Bool> {
        Binding(
            get: { preferences.automaticTabSleeping },
            set: { preferences.setAutomaticTabSleeping($0) }
        )
    }

    private var tabSleepDelayBinding: Binding<Int> {
        Binding(
            get: { preferences.tabSleepDelayMinutes },
            set: { preferences.setTabSleepDelayMinutes($0) }
        )
    }

    private var httpsUpgradeBinding: Binding<Bool> {
        Binding(
            get: { preferences.httpsUpgradeEnabled },
            set: { preferences.setHTTPSUpgradeEnabled($0) }
        )
    }

    private var contentBlockingBinding: Binding<Bool> {
        Binding(
            get: { preferences.contentBlockingEnabled },
            set: { preferences.setContentBlockingEnabled($0) }
        )
    }

    private var blockThirdPartyCookiesBinding: Binding<Bool> {
        Binding(
            get: { preferences.blockThirdPartyCookies },
            set: { preferences.setBlockThirdPartyCookies($0) }
        )
    }

    private var appearanceBinding: Binding<BrowserAppearance> {
        Binding(
            get: { preferences.appearance },
            set: { preferences.setAppearance($0) }
        )
    }

    private var defaultSidebarCollapsedBinding: Binding<Bool> {
        Binding(
            get: { preferences.defaultSidebarCollapsed },
            set: {
                preferences.setDefaultSidebarCollapsed($0)
                store.isSidebarCollapsed = $0
            }
        )
    }

    private var showPerformanceMetricsBinding: Binding<Bool> {
        Binding(
            get: { preferences.showPerformanceMetrics },
            set: { preferences.setShowPerformanceMetrics($0) }
        )
    }

    private func sleepDelayLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }

    private func resetPreferences() {
        preferences.resetToDefaults()
        store.isSidebarCollapsed = preferences.defaultSidebarCollapsed
    }

    private func settingsPage<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
        }
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择下载文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK {
            store.setDownloadDirectory(panel.url)
        }
    }
}

private struct SearchEnginePicker: View {
    @ObservedObject var preferences: BrowserPreferences

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SearchEngine.allCases.enumerated()), id: \.element.id) { index, engine in
                Button {
                    preferences.setSearchEngine(engine)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: engine.symbolName)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(engine == preferences.searchEngine ? Color.accentColor : .secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(engine.displayName)
                                .font(.headline)
                            Text(engine.shortDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if engine == preferences.searchEngine {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("当前默认搜索引擎")
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 14)
                    .padding(.horizontal, 18)
                }
                .buttonStyle(.plain)

                if index < SearchEngine.allCases.count - 1 {
                    Divider().padding(.leading, 62)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let detail: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 7)
    }
}
