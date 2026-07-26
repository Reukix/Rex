import Combine
import SwiftUI

private final class ReleaseNotesViewModel: ObservableObject {
    @Published var selectedSection = "current"
    @Published var searchText = ""
}

struct ReleaseNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ReleaseNotesViewModel()

    private let features: FeatureCatalog?
    private let releases: ReleaseCatalog?
    private let loadError: String?

    init() {
        do {
            let loaded = try ReleaseNotesService.load()
            features = loaded.0
            releases = loaded.1
            loadError = nil
        } catch {
            features = nil
            releases = nil
            loadError = error.localizedDescription
        }
    }

    var body: some View {
        ZStack {
            RexWindowBackground()
                .ignoresSafeArea()

            HStack(spacing: 12) {
                LiquidGlassPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("版本与功能", systemImage: "shippingbox.fill")
                            .font(.headline)
                            .padding(12)

                        releaseNavButton("当前版本", symbol: "sparkles", id: "current")
                        releaseNavButton("完整功能", symbol: "list.bullet.rectangle", id: "features")
                        releaseNavButton("已知问题", symbol: "exclamationmark.triangle", id: "issues")

                        Divider().padding(.vertical, 4)

                        Text("历史版本")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                        ForEach(releases?.releases ?? []) { release in
                            releaseNavButton("v\(release.version)", symbol: "clock.arrow.circlepath", id: release.version)
                        }
                        Spacer()
                    }
                }
                .frame(width: 190)

                LiquidGlassPanel {
                    Group {
                        if let loadError {
                            ContentUnavailableView("无法读取版本数据", systemImage: "exclamationmark.triangle", description: Text(loadError))
                        } else if model.selectedSection == "features" {
                            featureList
                        } else if model.selectedSection == "issues" {
                            issueList
                        } else {
                            releaseDetail(version: model.selectedSection == "current" ? releases?.releases.first?.version : model.selectedSection)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func releaseNavButton(_ title: String, symbol: String, id: String) -> some View {
        Button { model.selectedSection = id } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: model.selectedSection == id ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
        }
        .buttonStyle(LiquidGlassButtonStyle(isSelected: model.selectedSection == id))
        .padding(.horizontal, 7)
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("完整功能列表").font(.title2.bold())
                    Text("数据版本 v\(features?.lastUpdatedVersion ?? "—")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索功能", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(features?.categories ?? []) { category in
                        let matches = category.features.filter {
                            model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText)
                        }
                        if !matches.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.name)
                                    .font(.headline)
                                ForEach(matches) { feature in
                                    featureRow(feature)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func featureRow(_ feature: FeatureRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: feature.status.symbol)
                    .foregroundStyle(statusColor(feature.status))
                Text(feature.name).fontWeight(.semibold)
                Spacer()
                Text(feature.status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(feature.status).opacity(0.14), in: Capsule())
            }
            Text(feature.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                capability("键盘", enabled: feature.supportsKeyboard)
                capability("分屏", enabled: feature.supportsSplitView)
                capability("隐私窗口", enabled: feature.supportsPrivateWindow)
                Spacer()
                Text("v\(feature.introducedIn)").font(.caption2).foregroundStyle(.tertiary)
            }
            if !feature.limitations.isEmpty {
                Label(feature.limitations.joined(separator: "；"), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func capability(_ name: String, enabled: Bool) -> some View {
        Label(name, systemImage: enabled ? "checkmark" : "minus")
            .font(.caption2)
            .foregroundStyle(enabled ? .secondary : .tertiary)
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("已知问题").font(.title2.bold())
            ForEach(releases?.releases.first?.knownIssues ?? [], id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private func releaseDetail(version: String?) -> some View {
        if let release = releases?.releases.first(where: { $0.version == version }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Rex v\(release.version)").font(.largeTitle.bold())
                            Text("构建 \(release.build) · \(release.channel.capitalized) · \(release.date)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("当前版本")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    Text(release.summary).font(.title3)
                    releaseSection("新增", symbol: "plus.circle.fill", items: release.added)
                    releaseSection("正在开发", symbol: "hammer.fill", items: release.inProgress)
                    releaseSection("已知问题", symbol: "exclamationmark.triangle.fill", items: release.knownIssues)
                    Divider()
                    Text("Chromium：尚未集成 · macOS 14+")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        } else {
            ContentUnavailableView("没有版本数据", systemImage: "shippingbox")
        }
    }

    @ViewBuilder
    private func releaseSection(_ title: String, symbol: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.headline)
                ForEach(items, id: \.self) { item in
                    Text("• \(item)").foregroundStyle(.secondary)
                }
            }
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
}
