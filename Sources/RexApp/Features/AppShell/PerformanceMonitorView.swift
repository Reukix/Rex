import SwiftUI

struct PerformanceMonitorView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var metrics = ProcessMetricsMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            summary
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 16)

            pagesSection
        }
        .frame(width: 760, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { metrics.start() }
        .onDisappear { metrics.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("性能监测")
                    .font(.title2.weight(.semibold))
                Text(refreshLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭性能监测")
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var refreshLabel: String {
        guard let date = metrics.lastUpdatedAt else { return "等待首次采样" }
        return "更新于 \(date.formatted(date: .omitted, time: .standard))"
    }

    private var summary: some View {
        HStack(spacing: 10) {
            PerformanceSummaryItem(
                symbol: "memorychip",
                title: "Rex 总内存",
                value: metrics.memoryLabel,
                tint: .blue
            )
            PerformanceSummaryItem(
                symbol: "cpu",
                title: "Rex 总 CPU",
                value: metrics.cpuLabel,
                tint: .green
            )
            PerformanceSummaryItem(
                symbol: "rectangle.stack",
                title: "标签页",
                value: "\(store.tabs.count)",
                tint: .orange
            )
        }
    }

    private var pagesSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("网页")
                    .font(.headline)

                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("网页行来自 Chromium 主任务快照；共享 renderer 的重复值不能相加")
                    .accessibilityLabel("网页指标说明：共享 renderer 的重复值不能相加")

                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 42)

            if !metrics.hasSampled || !metrics.hasPageMetricsSampled {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取网页性能")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else if store.tabs.isEmpty {
                ContentUnavailableView(
                    "暂无可监测网页",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("打开网页后会在这里显示资源占用。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("网页")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("内存")
                    .frame(width: 92, alignment: .trailing)
                Text("CPU")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 30)
            .frame(height: 24)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.tabs) { tab in
                        PerformancePageRow(
                            tab: tab,
                            metric: metrics.pageMetricsByTabID[tab.id]
                        )
                        .padding(.horizontal, 12)
                        .background(
                            Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct PerformanceSummaryItem: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

private struct PerformancePageRow: View {
    let tab: BrowserTab
    let metric: PageProcessMetric?

    var body: some View {
        HStack(spacing: 12) {
            TabFavicon(tab: tab)
                .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tab.title.isEmpty ? "未命名网页" : tab.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    PageStateBadge(lifecycle: tab.lifecycle)
                }

                Text(pageLocation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(memoryLabel)
                .frame(width: 92, alignment: .trailing)

            Text(cpuLabel)
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .frame(height: 54)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var pageLocation: String {
        if let host = tab.url?.host, !host.isEmpty { return host }
        if let url = tab.url?.absoluteString, !url.isEmpty { return url }
        return "本地页面"
    }

    private var memoryLabel: String {
        guard let bytes = metric?.memoryBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private var cpuLabel: String {
        guard let percent = metric?.cpuPercent, percent.isFinite else { return "—" }
        return String(format: "%.1f%%", max(0, percent))
    }

    private var accessibilitySummary: String {
        "\(tab.title)，\(tab.lifecycle.performanceDisplayName)，内存 \(memoryLabel)，CPU \(cpuLabel)"
    }
}

private struct PageStateBadge: View {
    let lifecycle: TabLifecycle

    var body: some View {
        Text(lifecycle.performanceDisplayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(lifecycle.performanceTint)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(
                lifecycle.performanceTint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }
}

private extension TabLifecycle {
    var performanceDisplayName: String {
        switch self {
        case .active: "当前"
        case .background: "后台"
        case .splitActive: "分屏"
        case .sleeping: "休眠"
        case .frozen: "冻结"
        case .archived: "归档"
        case .crashed: "崩溃"
        }
    }

    var performanceTint: Color {
        switch self {
        case .active, .splitActive: .green
        case .background: .blue
        case .sleeping, .frozen, .archived: .secondary
        case .crashed: .red
        }
    }
}
