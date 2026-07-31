import AppKit
import Combine
import SwiftUI

enum BrowserLibrarySection: String, CaseIterable, Identifiable {
    case history = "历史"
    case bookmarks = "收藏"
    case downloads = "下载"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .bookmarks: "star.fill"
        case .downloads: "arrow.down.circle"
        }
    }
}

private final class BrowserLibraryViewModel: ObservableObject {
    @Published var query = ""
}

struct BrowserLibraryView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserLibraryViewModel()
    @State private var pendingBrowsingDataRange: BrowsingDataTimeRange?
    @State private var isConfirmingDownloadRecordClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("资料库", selection: $store.librarySelection) {
                    ForEach(BrowserLibrarySection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbolName)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                if store.librarySelection == .history {
                    Menu {
                        ForEach(BrowsingDataTimeRange.allCases, id: \.self) { range in
                            Button(range.displayName, role: range == .allTime ? .destructive : nil) {
                                pendingBrowsingDataRange = range
                            }
                        }
                    } label: {
                        Label("删除浏览数据", systemImage: "trash")
                    }
                    .disabled(store.history.isEmpty)
                    .help("按时间范围删除浏览历史")
                } else if store.librarySelection == .downloads {
                    Menu {
                        Button("选择下载文件夹…", action: chooseDownloadDirectory)
                        if !store.usesDefaultDownloadDirectory {
                            Button("恢复默认位置") {
                                store.setDownloadDirectory(nil)
                            }
                        }
                    } label: {
                        Label(store.currentDownloadDirectoryName, systemImage: "folder")
                            .lineLimit(1)
                    }
                    .help("当前工作空间的下载位置")

                    Button {
                        isConfirmingDownloadRecordClear = true
                    } label: {
                        Label("清空记录", systemImage: "trash")
                    }
                    .disabled(!store.hasClearableDownloadRecords)
                    .help("清空所有非活动下载记录")
                }

                Spacer(minLength: 20)

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索\(store.librarySelection.rawValue)", text: $model.query)
                        .textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 250, height: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)

            Divider()

            Group {
                switch store.librarySelection {
                case .history: historyList
                case .bookmarks: bookmarkList
                case .downloads: downloadList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 860,
            maxWidth: .infinity,
            minHeight: 520,
            maxHeight: .infinity,
            alignment: .top
        )
        .confirmationDialog(
            pendingBrowsingDataRange.map { "删除\($0.displayName)的浏览历史？" } ?? "删除浏览历史？",
            isPresented: Binding(
                get: { pendingBrowsingDataRange != nil },
                set: { isPresented in
                    if !isPresented { pendingBrowsingDataRange = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pendingBrowsingDataRange {
                Button("永久删除", role: .destructive) {
                    store.removeHistory(in: pendingBrowsingDataRange)
                    self.pendingBrowsingDataRange = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingBrowsingDataRange = nil
            }
        } message: {
            Text("此操作无法撤销。收藏和下载记录不会受到影响。")
        }
        .confirmationDialog(
            "清空所有下载记录？",
            isPresented: $isConfirmingDownloadRecordClear,
            titleVisibility: .visible
        ) {
            Button("清空记录", role: .destructive) {
                store.clearDownloadRecords()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除 Rex 中的记录，不会删除已下载文件。Chromium 当前仍在处理的任务会保留。")
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let entries = store.history.filter { matches($0.title, $0.url.absoluteString) }
        if entries.isEmpty {
            ContentUnavailableView("没有历史记录", systemImage: "clock.arrow.circlepath")
        } else {
            List(entries) { entry in
                LibraryLinkRow(title: entry.title, url: entry.url, date: entry.visitedAt) {
                    store.openLibraryEntry(url: entry.url)
                } trailing: {
                    Button { store.removeHistory(entry) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除历史记录")
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        let entries = store.bookmarks.filter { matches($0.title, $0.url.absoluteString) }
        if entries.isEmpty {
            ContentUnavailableView("没有收藏页面", systemImage: "star")
        } else {
            List(entries) { bookmark in
                LibraryLinkRow(title: bookmark.title, url: bookmark.url, date: bookmark.updatedAt) {
                    store.openLibraryEntry(url: bookmark.url)
                } trailing: {
                    Button { store.removeBookmark(bookmark) } label: {
                        Image(systemName: "star.slash")
                    }
                    .buttonStyle(.borderless)
                    .help("取消收藏")
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var downloadList: some View {
        let entries = store.downloads.filter { matches($0.suggestedFilename, $0.sourceURL.absoluteString) }
        if entries.isEmpty {
            ContentUnavailableView("没有下载记录", systemImage: "arrow.down.circle")
        } else {
            List(entries) { download in
                DownloadRow(download: download)
            }
            .listStyle(.inset)
        }
    }

    private func matches(_ values: String...) -> Bool {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(trimmed) }
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

struct BrowserDownloadsPanel: View {
    @EnvironmentObject private var store: BrowserStore
    let onShowAll: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    static let preferredSize = CGSize(width: 440, height: 420)

    var body: some View {
        LiquidGlassPanel(cornerRadius: 12, showsShadow: false) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("下载")
                        .font(.system(size: 14, weight: .semibold))

                    if activeDownloadCount > 0 {
                        Text("\(activeDownloadCount) 项进行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button("显示全部", action: onShowAll)
                        .buttonStyle(.borderless)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("关闭下载面板")
                }
                .padding(.horizontal, 14)
                .frame(height: 50)

                Divider()

                if recentDownloads.isEmpty {
                    ContentUnavailableView("没有下载记录", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(recentDownloads) { download in
                                DownloadRow(download: download)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 5)
                                if download.id != recentDownloads.last?.id {
                                    Divider()
                                        .padding(.leading, 50)
                                }
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(store.currentDownloadDirectoryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("下载设置")
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
        }
    }

    private var recentDownloads: [BrowserDownloadTask] {
        Array(store.downloads.prefix(5))
    }

    private var activeDownloadCount: Int {
        store.downloads.count(where: { store.isDownloadActive($0) })
    }
}

private extension BrowsingDataTimeRange {
    var displayName: String {
        switch self {
        case .lastHour: "过去1小时"
        case .last24Hours: "过去24小时"
        case .last7Days: "过去7天"
        case .allTime: "所有时间"
        }
    }
}

private struct LibraryLinkRow<Trailing: View>: View {
    let title: String
    let url: URL
    let date: Date
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
        .frame(minHeight: 46)
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var store: BrowserStore
    let download: BrowserDownloadTask

    var body: some View {
        let canCancel = store.canCancelDownload(download)
        let isActive = store.isDownloadActive(download)
        let isRetrying = store.isDownloadRetrying(download)
        HStack(spacing: 12) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(download.suggestedFilename)
                        .lineLimit(1)
                    Spacer()
                    Text(stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if canCancel {
                    if let progress = download.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                if canCancel {
                    Button {
                        store.cancelDownload(download)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("取消下载")
                } else if download.canRetry && !isRetrying {
                    Button {
                        store.retryDownload(download)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重试下载")
                }
                if download.canOpen {
                    Button {
                        store.openDownloadedFile(download)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("打开文件")
                    Button {
                        store.revealDownloadedFile(download)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中显示")
                }
                if !isActive {
                    Button(role: .destructive) {
                        store.removeDownload(download)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("删除下载记录")
                }
            }
            .buttonStyle(.borderless)
        }
        .frame(minHeight: 50)
    }

    private var sizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)
        guard let expected = download.expectedBytes, expected > 0 else { return received }
        return "\(received) / \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
    }

    private var detailText: String {
        if let errorDescription = download.errorDescription {
            return "\(sizeText) · \(errorDescription)"
        }
        if let destinationURL = download.destinationURL, download.state == .completed {
            return "\(sizeText) · \(destinationURL.deletingLastPathComponent().path)"
        }
        return sizeText
    }

    private var stateText: String {
        if store.isDownloadRetrying(download) { return "正在重试" }
        switch download.state {
        case .pending: return "等待中"
        case .downloading: return "下载中"
        case .scanning: return "检查中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .unknown: return "状态未知"
        }
    }

    private var stateSymbol: String {
        switch download.state {
        case .pending, .downloading: "arrow.down.circle"
        case .scanning: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var stateColor: Color {
        switch download.state {
        case .completed: .green
        case .failed: .red
        case .unknown: .secondary
        default: .accentColor
        }
    }
}
