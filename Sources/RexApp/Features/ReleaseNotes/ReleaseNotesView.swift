import Combine
import SwiftUI

@MainActor
private final class ReleaseNotesViewModel: ObservableObject {
    @Published var selectedSection = "current"
    @Published var searchText = ""
    @Published var selectedFeatureCategory = "all"
    @Published var selectedFeatureStatus: FeatureStatus?
    @Published var expandedFeatureIDs: Set<String> = []
    @Published var selectedReleaseSection = "added"
}

private struct ReleaseContentSection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    let items: [String]
}

private struct FeatureLimitationEntry: Identifiable {
    let categoryName: String
    let feature: FeatureRecord

    var id: String { feature.id }
}

struct ReleaseNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ReleaseNotesViewModel()

    private let features: FeatureCatalog?
    private let releases: ReleaseCatalog?
    private let aboutInformation: RexAboutInformation?
    private let loadError: String?

    init() {
        do {
            let loaded = try ReleaseNotesService.load()
            features = loaded.0
            releases = loaded.1
            aboutInformation = RexAboutInformation.make(
                version: AppVersion.releaseVersion,
                build: AppVersion.buildNumber,
                chromiumVersion: AppVersion.chromiumVersion,
                cefVersion: AppVersion.cefVersion,
                architecture: AppVersion.supportedArchitecture,
                features: loaded.0,
                releases: loaded.1
            )
            loadError = nil
        } catch {
            features = nil
            releases = nil
            aboutInformation = nil
            loadError = error.localizedDescription
        }
    }

    var body: some View {
        ZStack {
            RexWindowBackground()
                .ignoresSafeArea()

            HStack(spacing: 12) {
                navigationSidebar
                    .frame(width: 208)

                LiquidGlassPanel {
                    mainContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(12)
        }
    }

    private var navigationSidebar: some View {
        LiquidGlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                Label("版本与功能", systemImage: "shippingbox.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.top, 15)
                    .padding(.bottom, 7)

                Divider()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)

                releaseNavButton("当前版本", symbol: "sparkles", id: "current")
                releaseNavButton("历史版本", symbol: "clock.arrow.circlepath", id: "history")

                Spacer(minLength: 20)

                if let aboutInformation {
                    Divider()
                        .padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rex v\(aboutInformation.version)")
                            .font(.subheadline.weight(.semibold))
                        Text("构建 \(aboutInformation.build) · \(aboutInformation.channelDisplayName)")
                        Text("\(historicalReleases.count) 个历史版本")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let loadError {
            ContentUnavailableView(
                "无法读取版本数据",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            switch model.selectedSection {
            case "history":
                historyList
            case "current":
                releaseDetail(release: currentRelease, showsHistoryBackButton: false)
            default:
                releaseDetail(
                    release: releases?.releases.first { $0.id == model.selectedSection },
                    showsHistoryBackButton: true
                )
            }
        }
    }

    private func releaseNavButton(_ title: String, symbol: String, id: String) -> some View {
        let isSelected = id == "history" ? isViewingHistory : model.selectedSection == id
        return Button {
            model.selectedSection = id
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .frame(height: 38)
        }
        .buttonStyle(LiquidGlassButtonStyle(isSelected: isSelected))
        .padding(.horizontal, 8)
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            featureHeader
            Divider()

            if matchingFeatureTotal == 0 {
                ContentUnavailableView(
                    "没有匹配的功能",
                    systemImage: "magnifyingglass",
                    description: Text("调整搜索内容、分类或状态后重试")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(features?.categories ?? []) { category in
                            let matches = matchingFeatures(in: category)
                            if !matches.isEmpty {
                                Section {
                                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, feature in
                                        featureRow(feature)
                                        if index < matches.count - 1 {
                                            Divider()
                                                .padding(.leading, 45)
                                        }
                                    }
                                } header: {
                                    HStack(spacing: 8) {
                                        Text(category.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(matches.count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(.regularMaterial)
                                    .overlay(alignment: .bottom) { Divider() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var featureHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    featureTitle
                    Spacer(minLength: 12)
                    featureSearchField
                        .frame(width: 230)
                }

                VStack(alignment: .leading, spacing: 10) {
                    featureTitle
                    featureSearchField
                }
            }

            HStack(spacing: 10) {
                featureCategoryMenu
                featureStatusMenu
                Spacer()
                Text("显示 \(matchingFeatureTotal) / \(allFeatureCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var featureTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("完整功能")
                .font(.title2.bold())
            Text("按分类浏览，展开功能可查看支持范围、版本与限制")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var featureSearchField: some View {
        TextField("搜索名称、说明或设置路径", text: $model.searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("搜索功能")
    }

    private var featureCategoryMenu: some View {
        Menu {
            Button {
                model.selectedFeatureCategory = "all"
            } label: {
                menuSelectionLabel("全部分类", selected: model.selectedFeatureCategory == "all")
            }

            Divider()

            ForEach(features?.categories ?? []) { category in
                Button {
                    model.selectedFeatureCategory = category.id
                } label: {
                    menuSelectionLabel(category.name, selected: model.selectedFeatureCategory == category.id)
                }
            }
        } label: {
            Label(selectedCategoryName, systemImage: "square.grid.2x2")
                .lineLimit(1)
                .frame(maxWidth: 180)
        }
        .controlSize(.small)
        .help("筛选功能分类")
    }

    private var featureStatusMenu: some View {
        Menu {
            Button {
                model.selectedFeatureStatus = nil
            } label: {
                menuSelectionLabel("全部状态", selected: model.selectedFeatureStatus == nil)
            }

            Divider()

            ForEach(FeatureStatus.allCases, id: \.self) { status in
                Button {
                    model.selectedFeatureStatus = status
                } label: {
                    menuSelectionLabel(
                        "\(status.label)（\(featureCount(for: status))）",
                        selected: model.selectedFeatureStatus == status
                    )
                }
                .disabled(featureCount(for: status) == 0)
            }
        } label: {
            Label(model.selectedFeatureStatus?.label ?? "全部状态", systemImage: "line.3.horizontal.decrease.circle")
        }
        .controlSize(.small)
        .help("筛选功能状态")
    }

    private func menuSelectionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func featureRow(_ feature: FeatureRecord) -> some View {
        DisclosureGroup(isExpanded: featureExpansionBinding(for: feature.id)) {
            VStack(alignment: .leading, spacing: 14) {
                Text(feature.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 12) {
                    featureMetadata("引入版本", value: "v\(feature.introducedIn)")
                    featureMetadata("最近更新", value: "v\(feature.updatedIn)")
                    featureMetadata("测试状态", value: testStatusDisplayName(feature.testStatus))
                    featureMetadata("重启要求", value: feature.requiresRestart ? "需要重启" : "无需重启")
                }

                if !feature.settingsPath.isEmpty {
                    Label("设置路径：\(feature.settingsPath)", systemImage: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), alignment: .leading)], alignment: .leading, spacing: 8) {
                    capability("键盘操作", enabled: feature.supportsKeyboard)
                    capability("左右分屏", enabled: feature.supportsSplitView)
                    capability("隐私窗口", enabled: feature.supportsPrivateWindow)
                }

                if !feature.limitations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("当前限制", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(feature.limitations, id: \.self) { limitation in
                            Text(limitation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.leading, 27)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: feature.status.symbol)
                    .foregroundStyle(statusColor(feature.status))
                    .frame(width: 18)
                Text(feature.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(feature.status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(feature.status))
                Text("v\(feature.updatedIn)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private func featureMetadata(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func capability(_ name: String, enabled: Bool) -> some View {
        Label(name, systemImage: enabled ? "checkmark.circle.fill" : "minus.circle")
            .font(.caption)
            .foregroundStyle(enabled ? .secondary : .tertiary)
    }

    private var issueList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已知问题")
                        .font(.title2.bold())
                    Text("汇总当前版本发布记录和各项功能的明确限制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(knownIssueCount) 项")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            if knownIssueCount == 0 {
                ContentUnavailableView("没有已知问题", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let issues = currentRelease?.knownIssues, !issues.isEmpty {
                            issueSectionHeader("当前版本", detail: "v\(currentRelease?.version ?? AppVersion.releaseVersion)")
                            ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                                issueRow(issue, source: "发布记录", symbol: "exclamationmark.triangle.fill", color: .orange)
                                if index < issues.count - 1 { Divider().padding(.leading, 50) }
                            }
                        }

                        if !featureLimitationEntries.isEmpty {
                            issueSectionHeader("功能限制", detail: "\(featureLimitationEntries.count) 项功能")
                            ForEach(Array(featureLimitationEntries.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    model.selectedSection = "features"
                                    model.selectedFeatureCategory = "all"
                                    model.selectedFeatureStatus = nil
                                    model.searchText = entry.feature.name
                                    model.expandedFeatureIDs.insert(entry.feature.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Label(entry.feature.name, systemImage: "exclamationmark.circle")
                                                .font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(entry.categoryName)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        ForEach(entry.feature.limitations, id: \.self) { limitation in
                                            Text(limitation)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)

                                if index < featureLimitationEntries.count - 1 {
                                    Divider().padding(.leading, 50)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func issueSectionHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func issueRow(_ text: String, source: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("历史版本")
                        .font(.title2.bold())
                    Text("从最新到最早浏览 Rex 的发布记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(historicalReleases.count) 个版本")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            if historicalReleases.isEmpty {
                ContentUnavailableView("没有历史版本", systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(historicalReleases.enumerated()), id: \.element.id) { index, release in
                            historyRow(release)
                            if index < historicalReleases.count - 1 {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ release: ReleaseRecord) -> some View {
        Button {
            model.selectedSection = release.id
            model.selectedReleaseSection = releaseSections(for: release).first?.id ?? "added"
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    releaseIdentity(release)
                        .frame(width: 150, alignment: .leading)
                    releaseSummary(release)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        releaseIdentity(release)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    releaseSummary(release)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开此版本的完整发布说明")
    }

    private func releaseIdentity(_ release: ReleaseRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Rex v\(release.version)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(RexAboutInformation.channelDisplayName(release.channel))
                    .foregroundStyle(channelColor(release.channel))
                Text("·")
                Text("构建 \(release.build)")
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func releaseSummary(_ release: ReleaseRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(release.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(release.date) · \(releaseItemCount(release)) 项记录")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func releaseDetail(release: ReleaseRecord?, showsHistoryBackButton: Bool) -> some View {
        if let release {
            let isCurrent = release.version == AppVersion.releaseVersion && release.build == AppVersion.buildNumber
            let sections = releaseSections(for: release)
            let selection = releaseSectionBinding(availableSections: sections)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    if showsHistoryBackButton {
                        Button {
                            model.selectedSection = "history"
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("返回历史版本")
                        .accessibilityLabel("返回历史版本")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 9) {
                            Text("Rex v\(release.version)")
                                .font(.title2.bold())
                            if isCurrent {
                                Text("当前版本")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text("构建 \(release.build) · \(RexAboutInformation.channelDisplayName(release.channel)) 通道 · \(release.date)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("版本摘要")
                                .font(.headline)
                            Text(release.summary)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if isCurrent, let aboutInformation {
                            Divider()
                            runtimeSummary(aboutInformation)
                        }

                        if !sections.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("发布内容")
                                        .font(.headline)
                                    Spacer()
                                    Text("共 \(releaseItemCount(release)) 项")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                releaseSectionPicker(sections: sections, selection: selection)

                                if let selectedSection = selectedReleaseSection(in: sections) {
                                    releaseSectionContent(selectedSection)
                                }
                            }
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
        } else {
            ContentUnavailableView("没有版本数据", systemImage: "shippingbox")
        }
    }

    private func runtimeSummary(_ information: RexAboutInformation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("运行环境")
                    .font(.headline)
                Spacer()
                Text("macOS 14 或更高版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 14) {
                runtimeValue("Chromium", value: information.chromiumVersion ?? "不可用")
                runtimeValue("CEF", value: information.cefVersion)
                runtimeValue("架构", value: information.architecture)
                runtimeValue("功能数据", value: "v\(information.featureCatalogVersion)")
            }
        }
    }

    private func runtimeValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func releaseSectionPicker(
        sections: [ReleaseContentSection],
        selection: Binding<String>
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            Picker("发布内容", selection: selection) {
                ForEach(sections) { section in
                    Text("\(section.title) \(section.items.count)")
                        .tag(section.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("内容类型")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("发布内容", selection: selection) {
                    ForEach(sections) { section in
                        Text("\(section.title)（\(section.items.count)）")
                            .tag(section.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func releaseSectionContent(_ section: ReleaseContentSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(section.title, systemImage: section.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(section.color)
                .padding(.bottom, 8)

            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(section.color.opacity(0.75))
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)

                if index < section.items.count - 1 {
                    Divider().padding(.leading, 15)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func releaseSectionBinding(availableSections: [ReleaseContentSection]) -> Binding<String> {
        Binding(
            get: {
                availableSections.contains { $0.id == model.selectedReleaseSection }
                    ? model.selectedReleaseSection
                    : availableSections.first?.id ?? ""
            },
            set: { model.selectedReleaseSection = $0 }
        )
    }

    private func selectedReleaseSection(in sections: [ReleaseContentSection]) -> ReleaseContentSection? {
        sections.first { $0.id == model.selectedReleaseSection } ?? sections.first
    }

    private func releaseSections(for release: ReleaseRecord) -> [ReleaseContentSection] {
        [
            ReleaseContentSection(id: "added", title: "新增", symbol: "plus.circle.fill", color: .green, items: release.added),
            ReleaseContentSection(id: "improved", title: "改进", symbol: "arrow.up.circle.fill", color: .blue, items: release.improved),
            ReleaseContentSection(id: "fixed", title: "修复", symbol: "wrench.and.screwdriver.fill", color: .teal, items: release.fixed),
            ReleaseContentSection(id: "changed", title: "变更", symbol: "arrow.triangle.2.circlepath", color: .indigo, items: release.changed),
            ReleaseContentSection(id: "removed", title: "移除", symbol: "minus.circle.fill", color: .red, items: release.removed)
        ]
        .filter { !$0.items.isEmpty }
    }

    private func releaseItemCount(_ release: ReleaseRecord) -> Int {
        releaseSections(for: release).reduce(0) { $0 + $1.items.count }
    }

    private func matchingFeatures(in category: FeatureCategory) -> [FeatureRecord] {
        guard model.selectedFeatureCategory == "all" || model.selectedFeatureCategory == category.id else {
            return []
        }

        let normalizedQuery = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return category.features.filter { feature in
            guard model.selectedFeatureStatus == nil || feature.status == model.selectedFeatureStatus else {
                return false
            }
            guard !normalizedQuery.isEmpty else { return true }

            return feature.name.localizedCaseInsensitiveContains(normalizedQuery)
                || feature.description.localizedCaseInsensitiveContains(normalizedQuery)
                || feature.settingsPath.localizedCaseInsensitiveContains(normalizedQuery)
                || feature.limitations.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    private func featureExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedFeatureIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    model.expandedFeatureIDs.insert(id)
                } else {
                    model.expandedFeatureIDs.remove(id)
                }
            }
        )
    }

    private func featureCount(for status: FeatureStatus) -> Int {
        features?.categories.reduce(0) { count, category in
            count + category.features.lazy.filter { $0.status == status }.count
        } ?? 0
    }

    private func testStatusDisplayName(_ status: String) -> String {
        switch status.lowercased() {
        case "passed": "已通过"
        case "partial": "部分通过"
        case "pending": "待验证"
        case "removed": "已移除"
        default: status.isEmpty ? "未记录" : status
        }
    }

    private func statusColor(_ status: FeatureStatus) -> Color {
        switch status {
        case .completed: .green
        case .testing: .cyan
        case .inProgress: .orange
        case .planned: .secondary
        case .paused: .yellow
        case .limited: .orange
        case .removed: .red
        }
    }

    private func channelColor(_ channel: String) -> Color {
        switch channel.lowercased() {
        case "stable", "release": .green
        case "beta": .blue
        case "alpha": .orange
        default: .secondary
        }
    }

    private var selectedCategoryName: String {
        guard model.selectedFeatureCategory != "all" else { return "全部分类" }
        return features?.categories.first { $0.id == model.selectedFeatureCategory }?.name ?? "全部分类"
    }

    private var allFeatureCount: Int {
        features?.categories.reduce(0) { $0 + $1.features.count } ?? 0
    }

    private var matchingFeatureTotal: Int {
        features?.categories.reduce(0) { $0 + matchingFeatures(in: $1).count } ?? 0
    }

    private var featureLimitationEntries: [FeatureLimitationEntry] {
        features?.categories.flatMap { category in
            category.features.compactMap { feature in
                feature.limitations.isEmpty
                    ? nil
                    : FeatureLimitationEntry(categoryName: category.name, feature: feature)
            }
        } ?? []
    }

    private var knownIssueCount: Int {
        (currentRelease?.knownIssues.count ?? 0) + featureLimitationEntries.count
    }

    private var historicalReleases: [ReleaseRecord] {
        releases?.releases.filter {
            !($0.version == AppVersion.releaseVersion && $0.build == AppVersion.buildNumber)
        } ?? []
    }

    private var isViewingHistory: Bool {
        model.selectedSection == "history"
            || (releases?.releases.contains { $0.id == model.selectedSection } ?? false)
    }

    private var currentRelease: ReleaseRecord? {
        releases?.release(version: AppVersion.releaseVersion, build: AppVersion.buildNumber)
            ?? releases?.releases.first
    }
}
