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
                        if store.currentDownloadDirectoryURL != nil {
                            Button("恢复为每次询问") {
                                store.setDownloadDirectory(nil)
                            }
                        }
                    } label: {
                        Label(store.currentDownloadDirectoryName, systemImage: "folder")
                            .lineLimit(1)
                    }
                    .help("当前工作空间的下载位置")
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
                if download.canCancel {
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
                if download.canCancel {
                    Button {
                        store.cancelDownload(download)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("取消下载")
                } else if download.canRetry {
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
                if !download.canCancel {
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
        switch download.state {
        case .pending: "等待中"
        case .downloading: "下载中"
        case .scanning: "检查中"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private var stateSymbol: String {
        switch download.state {
        case .pending, .downloading: "arrow.down.circle"
        case .scanning: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var stateColor: Color {
        switch download.state {
        case .completed: .green
        case .failed: .red
        default: .accentColor
        }
    }
}
