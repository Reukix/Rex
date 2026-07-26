import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserExtensionsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case discover
        case installed

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .discover: "发现"
            case .installed: "已导入"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var extensionsStore = BrowserExtensionsStore.shared
    @State private var selectedSection: Section = .discover
    @State private var selectedFilter: BrowserExtensionCatalogFilter = .recommended
    @State private var searchText = ""
    @State private var presentedError: String?
    @State private var isImporting = false
    @State private var selectedCatalogItem: BrowserExtensionCatalogItem?
    @State private var pendingRemoval: BrowserExtensionPackage?
    @State private var shouldImportAfterClosingDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browserControls
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("扩展操作未完成", isPresented: Binding(
            get: { presentedError != nil },
            set: {
                if !$0 {
                    presentedError = nil
                    extensionsStore.clearLastError()
                }
            }
        )) {
            Button("好") {
                presentedError = nil
                extensionsStore.clearLastError()
            }
        } message: {
            Text(presentedError ?? "")
        }
        .confirmationDialog(
            "移除 \(pendingRemoval?.name ?? "扩展")？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                guard let package = pendingRemoval else { return }
                if !extensionsStore.remove(package.id) {
                    presentedError = extensionsStore.lastError ?? "无法移除扩展。"
                }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Rex 管理目录中的扩展文件（若存在）将一并删除。")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                install(from: url)
            case .failure(let error):
                presentedError = error.localizedDescription
            }
        }
        .sheet(item: $selectedCatalogItem, onDismiss: {
            guard shouldImportAfterClosingDetails else { return }
            shouldImportAfterClosingDetails = false
            isImporting = true
        }) { item in
            BrowserExtensionCatalogDetailView(
                item: item,
                onImportLocal: {
                    shouldImportAfterClosingDetails = true
                    selectedCatalogItem = nil
                }
            )
        }
        .onAppear {
            if let error = extensionsStore.lastError { presentedError = error }
        }
        .onChange(of: extensionsStore.lastError) { _, error in
            if let error { presentedError = error }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Rex 扩展")
                    .font(.system(size: 16, weight: .semibold))
                Text("精选目录链接至 Chrome Web Store，本地扩展由 Rex 独立管理")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                isImporting = true
            } label: {
                Label("导入本地扩展", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var browserControls: some View {
        HStack(spacing: 12) {
            Picker("扩展页面", selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    Text(section.displayName).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    selectedSection == .discover ? "搜索 Rex 目录" : "搜索已导入扩展",
                    text: $searchText
                )
                .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            if selectedSection == .discover {
                Picker("分类", selection: $selectedFilter) {
                    ForEach(BrowserExtensionCatalogFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            } else {
                Button {
                    extensionsStore.openPackagesDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("打开 Rex 扩展目录")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .discover:
            discoverContent
        case .installed:
            installedContent
        }
    }

    private var discoverContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                compatibilityNotice

                HStack {
                    Text(discoverTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("由 Rex 选择 · 来源为 Chrome Web Store")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if filteredCatalogItems.isEmpty {
                    ContentUnavailableView(
                        "Rex 目录中没有匹配项",
                        systemImage: "magnifyingglass",
                        description: Text("可以前往 Chrome Web Store 查看官方搜索结果。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(filteredCatalogItems) { item in
                            catalogCard(item)
                        }
                    }
                }

                officialSearchAction
            }
            .padding(18)
        }
    }

    private var installedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                compatibilityNotice

                HStack {
                    Text("本地扩展")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(extensionsStore.extensions.count) 个包")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if filteredInstalledExtensions.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "尚未导入扩展" : "没有匹配的本地扩展",
                        systemImage: "puzzlepiece.extension",
                        description: Text(searchText.isEmpty
                            ? "请选择包含 manifest.json 的扩展源码文件夹。"
                            : "尝试其他名称、版本或权限关键词。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)

                    if searchText.isEmpty {
                        Button {
                            isImporting = true
                        } label: {
                            Label("导入本地扩展", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(filteredInstalledExtensions) { package in
                        installedExtensionRow(package)
                    }
                }
            }
            .padding(18)
        }
    }

    private var compatibilityNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("当前运行边界")
                    .font(.system(size: 12, weight: .semibold))
                Text("Chrome Web Store 的“添加至 Chrome”不会安装到 Rex。CEF 150 没有公共扩展加载 API；本地导入可校验、保存、定位和移除包，但不会执行扩展代码。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func catalogCard(_ item: BrowserExtensionCatalogItem) -> some View {
        Button {
            selectedCatalogItem = item
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: item.category.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(item.category.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                Text(item.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)

                Label(BrowserExtensionCatalog.sourceName, systemImage: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看官方商店链接和兼容说明")
    }

    private func installedExtensionRow(_ package: BrowserExtensionPackage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BrowserExtensionPackageIcon(package: package)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(package.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("v\(package.version)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(package.manifestLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    statusChip(package.runtimeStatus)
                    Spacer(minLength: 0)
                }

                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(package.permissionSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if [.invalidManifest, .missingFiles].contains(package.runtimeStatus),
                   let detail = package.statusDetail {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Label("仅保存包，不执行扩展代码", systemImage: "archivebox")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let homepageURL = package.homepageURL {
                        Button {
                            NSWorkspace.shared.open(homepageURL)
                        } label: {
                            Image(systemName: "house")
                        }
                        .buttonStyle(.bordered)
                        .help("打开开发者主页")
                    }

                    Spacer(minLength: 8)

                    Button {
                        extensionsStore.revealInFinder(package.id)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("在 Finder 中显示")

                    Button(role: .destructive) {
                        pendingRemoval = package
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("移除扩展")
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
        }
    }

    private func statusChip(_ status: BrowserExtensionPackage.RuntimeStatus) -> some View {
        Text(status.displayName)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(statusColor(status).opacity(0.12), in: Capsule())
            .foregroundStyle(statusColor(status))
    }

    private func statusColor(_ status: BrowserExtensionPackage.RuntimeStatus) -> Color {
        switch status {
        case .ready: .green
        case .pendingRuntime: .blue
        case .disabled: .secondary
        case .invalidManifest, .missingFiles: .orange
        }
    }

    private var filteredCatalogItems: [BrowserExtensionCatalogItem] {
        BrowserExtensionCatalog.filteredItems(query: searchText, filter: selectedFilter)
    }

    private var filteredInstalledExtensions: [BrowserExtensionPackage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return extensionsStore.extensions }
        return extensionsStore.extensions.filter { package in
            package.name.localizedCaseInsensitiveContains(query)
                || package.version.localizedCaseInsensitiveContains(query)
                || package.permissions.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var discoverTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "目录结果"
        }
        return selectedFilter == .recommended ? "Rex 推荐" : selectedFilter.displayName
    }

    @ViewBuilder
    private var officialSearchAction: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, let url = BrowserExtensionCatalog.chromeWebStoreSearchURL(query: query) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("查看完整官方目录")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Chrome Web Store 将在默认浏览器中打开，安装不会进入 Rex。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("在官方商店搜索", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func install(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            _ = try extensionsStore.installUnpacked(from: url)
            selectedSection = .installed
            searchText = ""
        } catch {
            presentedError = error.localizedDescription
        }
    }
}

private struct BrowserExtensionCatalogDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: BrowserExtensionCatalogItem
    let onImportLocal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.category.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                    Text(item.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            Text(item.summary)
                .font(.body)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("官方来源：\(BrowserExtensionCatalog.sourceName)", systemImage: "checkmark.seal")
                    .font(.callout.weight(.semibold))
                Text("官方页面将在默认浏览器中打开。页面上的“添加至 Chrome”只会安装到 Google Chrome，不会安装到 Rex。Rex 不抓取或重新分发商店安装包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Rex 本地导入", systemImage: "folder.badge.plus")
                    .font(.callout.weight(.semibold))
                Text("如果开发者另行提供包含 manifest.json 的源码文件夹，可以导入并管理该文件夹。当前 CEF 运行时不会执行其中的扩展代码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    NSWorkspace.shared.open(item.officialURL)
                } label: {
                    Label("打开 Chrome Web Store", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onImportLocal()
                } label: {
                    Label("导入本地文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 380)
    }
}

private struct BrowserExtensionPackageIcon: View {
    let package: BrowserExtensionPackage

    var body: some View {
        Group {
            if let iconURL = package.iconURL, let image = NSImage(contentsOf: iconURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
