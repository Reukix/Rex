import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BrowserExtensionsPresentation: Equatable {
    case sheet
    case page
}

struct BrowserExtensionsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case discover
        case installed

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .discover: "发现"
            case .installed: "已安装"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var extensionsStore = BrowserExtensionsStore.shared
    let presentation: BrowserExtensionsPresentation
    let initialRuntimeID: String?
    @State private var selectedSection: Section = .discover
    @State private var selectedFilter: BrowserExtensionCatalogFilter = .recommended
    @State private var searchText = ""
    @State private var webStoreInput = ""
    @State private var presentedError: String?
    @State private var isImporting = false
    @State private var selectedCatalogItem: BrowserExtensionCatalogItem?
    @State private var selectedInstalledPackage: BrowserExtensionPackage?
    @State private var pendingRemoval: BrowserExtensionPackage?
    @State private var shouldImportAfterClosingDetails = false
    @State private var pendingRuntimePackageIDs = Set<String>()

    init(
        presentation: BrowserExtensionsPresentation = .sheet,
        initialRuntimeID: String? = nil
    ) {
        self.presentation = presentation
        self.initialRuntimeID = initialRuntimeID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browserControls
                .disabled(extensionsStore.isRuntimeMutationInProgress)
            Divider()
            content
                .disabled(extensionsStore.isRuntimeMutationInProgress)
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
                pendingRemoval = nil
                Task { @MainActor in
                    pendingRuntimePackageIDs.insert(package.id)
                    defer { pendingRuntimePackageIDs.remove(package.id) }
                    if !(await store.removeExtension(package.id)) {
                        presentedError = extensionsStore.lastError ?? "无法移除扩展。"
                    }
                }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("扩展会立即从 Chromium 卸载，Rex 管理目录中的扩展文件也会一并删除。")
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
                onInstall: {
                    installFromCatalog(item)
                },
                onImportLocal: {
                    shouldImportAfterClosingDetails = true
                    selectedCatalogItem = nil
                }
            )
        }
        .sheet(item: $selectedInstalledPackage, onDismiss: {
            if presentation == .page,
               RexExtensionsPage.detailRuntimeID(from: store.currentTab?.url) != nil {
                store.openExtensionsPage()
            }
        }) { package in
            BrowserExtensionRuntimeDetailView(packageID: package.id)
                .environmentObject(store)
        }
        .onAppear {
            if let error = extensionsStore.lastError { presentedError = error }
            presentInitialRuntimeDetails()
        }
        .onChange(of: initialRuntimeID) { _, _ in presentInitialRuntimeDetails() }
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
                Text("从 Chrome Web Store 直接安全安装，或导入本地扩展")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if presentation == .sheet {
                Button {
                    store.openExtensionsPage()
                    dismiss()
                } label: {
                    Label("在标签页中打开", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
            }

            Button {
                isImporting = true
            } label: {
                Label("导入本地扩展", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            if presentation == .sheet {
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
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

                webStoreDirectInstall
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
                    Text("已安装扩展")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(extensionsStore.extensions.count) 个包")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if filteredInstalledExtensions.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "尚未安装扩展" : "没有匹配的扩展",
                        systemImage: "puzzlepiece.extension",
                        description: Text(searchText.isEmpty
                            ? "可从 Chrome Web Store 安装，或导入包含 manifest.json 的扩展文件夹。"
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
                Text("Chromium 扩展运行时")
                    .font(.system(size: 12, weight: .semibold))
                Text("Rex 会校验并管理扩展包，并与 Chromium 运行时即时同步。后台服务、内容脚本、Chrome API、DNR 与扩展页面均由扩展自身提供；兼容性取决于当前 Chromium 版本。")
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
        VStack(alignment: .leading, spacing: 10) {
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
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看扩展详情和官方商店链接")

            Divider()

            catalogInstallControl(item)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .rexChromeBorder(cornerRadius: 8)
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
                    Toggle(
                        "启用 \(package.name)",
                        isOn: extensionEnabledBinding(for: package)
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(
                        [.invalidManifest, .missingFiles].contains(package.runtimeStatus)
                            || pendingRuntimePackageIDs.contains(package.id)
                    )
                    .help(package.isEnabled ? "立即停用扩展" : "立即启用扩展")
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

                if let limitation = package.appleNativeConnectionLimitation {
                    Label(limitation, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if [.invalidManifest, .missingFiles].contains(package.runtimeStatus),
                   let detail = package.statusDetail {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Label(
                        package.resolvedInstallationSource == .chromeWebStore
                            ? package.runtimeStatus == .invalidManifest
                                ? "Chrome Web Store 安装需要修复"
                                : "Chrome Web Store 已验签安装"
                            : "本地受管扩展包",
                        systemImage: package.resolvedInstallationSource == .chromeWebStore
                            ? package.runtimeStatus == .invalidManifest
                                ? "exclamationmark.triangle"
                                : "checkmark.seal"
                            : "archivebox"
                    )
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

                    if package.resolvedInstallationSource == .chromeWebStore,
                       package.runtimeStatus == .invalidManifest,
                       let storeID = package.storeID,
                       BrowserExtensionCatalog.isValidChromeExtensionID(storeID) {
                        Button {
                            reinstallWebStorePackage(package, extensionID: storeID)
                        } label: {
                            if isInstalling(storeID) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("重新安装", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isInstalling(storeID))
                        .help("重新下载并验证 Chrome Web Store 扩展")
                    }

                    Button {
                        extensionsStore.revealInFinder(package.id)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("在 Finder 中显示")

                    Button {
                        presentDetails(for: package)
                    } label: {
                        Label("详情", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("查看 Chromium 权限与运行状态")

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
        .rexChromeBorder(cornerRadius: 8)
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
    private func catalogInstallControl(_ item: BrowserExtensionCatalogItem) -> some View {
        let state = extensionsStore.catalogInstallState(for: item.id)
        let isInstalled = extensionsStore.extensions.contains { $0.storeID == item.id }

        HStack(spacing: 8) {
            if let state, isActiveInstallPhase(state.phase) {
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 90)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(state.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if isInstalled {
                Label("已安装到 Rex", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            } else if state?.phase == .failed {
                Label("上次安装未完成", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            } else {
                Label(BrowserExtensionCatalog.sourceName, systemImage: "checkmark.seal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                installFromCatalog(item)
            } label: {
                Label(
                    state?.phase == .failed ? "重试" : "直接安装",
                    systemImage: state?.phase == .failed ? "arrow.clockwise" : "square.and.arrow.down"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isInstalled || (state.map { isActiveInstallPhase($0.phase) } ?? false))
        }
    }

    private var webStoreDirectInstall: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("从商店链接安装")
                        .font(.system(size: 12, weight: .semibold))
                    Text("支持 chromewebstore.google.com 详情链接或 32 位扩展 ID")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("粘贴 Chrome Web Store 链接或扩展 ID", text: $webStoreInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        installFromWebStoreInput()
                    }

                Button {
                    installFromWebStoreInput()
                } label: {
                    Label("直接安装", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    parsedWebStoreInputID == nil
                        || parsedWebStoreInputID.map(isInstalling) == true
                )
            }

            if let extensionID = parsedWebStoreInputID,
               let state = extensionsStore.catalogInstallState(for: extensionID) {
                HStack(spacing: 8) {
                    if isActiveInstallPhase(state.phase) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: state.phase == .installed
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.phase == .installed ? .green : .orange)
                    }
                    Text(state.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .rexChromeBorder(cornerRadius: 8, level: .subtle)
    }

    @ViewBuilder
    private var officialSearchAction: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, let url = BrowserExtensionCatalog.chromeWebStoreSearchURL(query: query) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("查看完整官方目录")
                        .font(.system(size: 12, weight: .semibold))
                    Text("在官方目录找到扩展后，可将详情链接粘贴到上方直接安装。")
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

    private var parsedWebStoreInputID: String? {
        BrowserExtensionCatalog.extensionID(fromWebStoreInput: webStoreInput)
    }

    private func extensionEnabledBinding(
        for package: BrowserExtensionPackage
    ) -> Binding<Bool> {
        Binding(
            get: {
                extensionsStore.extensions.first(where: { $0.id == package.id })?.isEnabled
                    ?? package.isEnabled
            },
            set: { enabled in
                Task { @MainActor in
                    pendingRuntimePackageIDs.insert(package.id)
                    defer { pendingRuntimePackageIDs.remove(package.id) }
                    if !(await store.setExtensionEnabled(enabled, id: package.id)) {
                        presentedError = extensionsStore.lastError ?? "无法同步扩展状态。"
                    }
                }
            }
        )
    }

    private func isActiveInstallPhase(_ phase: BrowserExtensionCatalogInstallPhase) -> Bool {
        [.downloading, .verifying, .extracting, .importing].contains(phase)
    }

    private func isInstalling(_ extensionID: String) -> Bool {
        extensionsStore.catalogInstallState(for: extensionID)
            .map { isActiveInstallPhase($0.phase) }
            ?? false
    }

    private func installFromCatalog(_ item: BrowserExtensionCatalogItem) {
        Task { @MainActor in
            do {
                _ = try await store.installExtensionFromCatalog(item)
            } catch is CancellationError {
                return
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    private func installFromWebStoreInput() {
        guard let extensionID = parsedWebStoreInputID else {
            presentedError = ChromeWebStoreInstallError.invalidCatalogItem.localizedDescription
            return
        }
        Task { @MainActor in
            do {
                _ = try await store.installExtensionFromWebStore(
                    extensionID: extensionID
                )
            } catch is CancellationError {
                return
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    private func reinstallWebStorePackage(
        _ package: BrowserExtensionPackage,
        extensionID: String
    ) {
        Task { @MainActor in
            do {
                _ = try await store.installExtensionFromWebStore(
                    extensionID: extensionID,
                    displayName: package.name
                )
            } catch is CancellationError {
                return
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    private func install(from url: URL) {
        Task { @MainActor in
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                _ = try await store.installUnpackedExtension(from: url)
                selectedSection = .installed
                searchText = ""
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    private func presentInitialRuntimeDetails() {
        guard let initialRuntimeID else { return }
        guard let package = extensionsStore.extensions.first(where: {
            $0.runtimeID == initialRuntimeID
        }) else {
            if presentation == .page {
                store.openExtensionsPage()
            }
            return
        }
        guard selectedInstalledPackage?.runtimeID != initialRuntimeID else { return }
        selectedSection = .installed
        selectedInstalledPackage = package
    }

    private func presentDetails(for package: BrowserExtensionPackage) {
        if presentation == .page,
           let runtimeID = package.runtimeID,
           let route = RexExtensionsPage.url(forRuntimeID: runtimeID) {
            store.openExtensionsPage(route)
        }
        selectedInstalledPackage = package
    }
}

private struct BrowserExtensionRuntimeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var extensionsStore = BrowserExtensionsStore.shared
    @State private var siteEditorRequest: BrowserExtensionSiteEditorRequest?

    let packageID: String

    private var package: BrowserExtensionPackage? {
        extensionsStore.extensions.first { $0.id == packageID }
    }

    private var configurationRefreshID: String {
        guard let package else {
            return "missing:\(extensionsStore.runtimeConfigurationRevision)"
        }
        return [
            package.runtimeID ?? package.id,
            String(extensionsStore.runtimeConfigurationRevision)
        ].joined(separator: ":")
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            Group {
                if let package {
                    detailContent(package)
                } else {
                    ContentUnavailableView("扩展已移除", systemImage: "puzzlepiece.extension")
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: configurationRefreshID) {
            guard let package else { return }
            await store.refreshExtensionRuntimeConfiguration(for: package)
        }
        .sheet(item: $siteEditorRequest) { request in
            BrowserExtensionSiteEditorView { host in
                guard let package,
                      let sitePermission = BrowserExtensionSitePermissionUpdate(
                          host: host,
                          isGranted: true
                      ) else { return }
                update(
                    package,
                    BrowserExtensionRuntimeConfigurationUpdate(
                        hostAccess: request.updatesHostAccess ? .onSpecificSites : nil,
                        sitePermission: sitePermission
                    )
                )
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            if let package {
                BrowserExtensionPackageIcon(package: package)
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text("v\(package.version) · \(package.manifestLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func detailContent(_ package: BrowserExtensionPackage) -> some View {
        let configuration = store.extensionRuntimeConfiguration(for: package)
        let isLoading = store.isLoadingExtensionRuntimeConfiguration(for: package)
        let configurationError = store.extensionRuntimeConfigurationError(for: package)

        Form {
            Section("运行") {
                Toggle(
                    "启用扩展",
                    isOn: Binding(
                        get: {
                            configuration?.isEnabled
                                ?? extensionsStore.extensions.first(where: { $0.id == package.id })?.isEnabled
                                ?? package.isEnabled
                        },
                        set: { enabled in
                            Task { @MainActor in
                                if await store.setExtensionEnabled(enabled, id: package.id),
                                   let updatedPackage = extensionsStore.extensions.first(where: {
                                       $0.id == package.id
                                   }) {
                                    await store.refreshExtensionRuntimeConfiguration(for: updatedPackage)
                                }
                            }
                        }
                    )
                )
                .disabled(isLoading || [.invalidManifest, .missingFiles].contains(package.runtimeStatus))

                LabeledContent("Chromium 状态") {
                    Text(
                        configuration.map { $0.isEnabled ? "已启用" : "已停用" }
                            ?? package.runtimeStatus.displayName
                    )
                        .foregroundStyle(.secondary)
                }
            }

            if let configurationError {
                Section("Chromium 权限") {
                    Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button {
                        Task { await store.refreshExtensionRuntimeConfiguration(for: package) }
                    } label: {
                        Label("重新读取", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }

            if let configuration {
                permissionsSection(package, configuration: configuration, isLoading: isLoading)
            } else if isLoading {
                Section("Chromium 权限") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                }
            } else if configurationError == nil {
                Section("Chromium 权限") {
                    ContentUnavailableView(
                        "无法读取扩展状态",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Chromium 扩展管理器暂不可用。")
                    )
                    Button {
                        Task { await store.refreshExtensionRuntimeConfiguration(for: package) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("扩展") {
                if let optionsURL = package.optionsURL {
                    Button {
                        store.openExtensionPage(optionsURL, title: package.name)
                        dismiss()
                    } label: {
                        Label("打开扩展选项", systemImage: "gearshape")
                    }
                }
                Button {
                    extensionsStore.revealInFinder(package.id)
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                if let runtimeID = package.runtimeID {
                    LabeledContent("Chromium ID", value: runtimeID)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionsSection(
        _ package: BrowserExtensionPackage,
        configuration: BrowserExtensionRuntimeConfiguration,
        isLoading: Bool
    ) -> some View {
        Section("网站访问") {
            if let currentAccess = configuration.hostAccess {
                Picker(
                    "运行范围",
                    selection: Binding(
                        get: { currentAccess },
                        set: { access in
                            if access == .onSpecificSites,
                               currentAccess != .onSpecificSites,
                               configuration.hasAllHosts {
                                siteEditorRequest = BrowserExtensionSiteEditorRequest(
                                    updatesHostAccess: true
                                )
                            } else {
                                update(
                                    package,
                                    BrowserExtensionRuntimeConfigurationUpdate(
                                        hostAccess: access
                                    )
                                )
                            }
                        }
                    )
                ) {
                    ForEach(BrowserExtensionHostAccess.allCases, id: \.self) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isLoading || !configuration.userMayModify)
            }

            if configuration.userScriptsAvailable {
                Toggle(
                    "允许运行用户脚本",
                    isOn: Binding(
                        get: { configuration.userScriptsAllowed },
                        set: { allowed in
                            update(
                                package,
                                BrowserExtensionRuntimeConfigurationUpdate(
                                    userScriptsAccess: allowed
                                )
                            )
                        }
                    )
                )
                .disabled(isLoading || !configuration.userMayModify)
            }

            if configuration.fileAccessAvailable {
                Toggle(
                    "允许访问文件网址",
                    isOn: Binding(
                        get: { configuration.fileAccessAllowed },
                        set: { allowed in
                            update(
                                package,
                                BrowserExtensionRuntimeConfigurationUpdate(fileAccess: allowed)
                            )
                        }
                    )
                )
                .disabled(isLoading || !configuration.userMayModify)
            }
        }

        if configuration.hostAccess == .onSpecificSites,
           configuration.hasAllHosts {
            let grantedSites = configuration.sites.filter(\.isGranted)
            Section("指定网站") {
                ForEach(grantedSites.prefix(100)) { site in
                    HStack(spacing: 10) {
                        Text(site.host)
                            .textSelection(.enabled)
                        Spacer(minLength: 12)
                        Button(role: .destructive) {
                            setSitePermission(package, host: site.host, granted: false)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("移除此网站")
                        .accessibilityLabel("移除 \(site.host)")
                        .disabled(isLoading || !configuration.userMayModify)
                    }
                }

                Button {
                    siteEditorRequest = BrowserExtensionSiteEditorRequest(
                        updatesHostAccess: false
                    )
                } label: {
                    Label("添加网站", systemImage: "plus")
                }
                .disabled(isLoading || !configuration.userMayModify)
            }
        } else if !configuration.hasAllHosts,
                  !configuration.sites.isEmpty {
            Section("请求的网站") {
                ForEach(configuration.sites.prefix(100)) { site in
                    Toggle(
                        site.host,
                        isOn: Binding(
                            get: { site.isGranted },
                            set: { granted in
                                setSitePermission(
                                    package,
                                    host: site.host,
                                    granted: granted
                                )
                            }
                        )
                    )
                    .disabled(isLoading || !configuration.userMayModify)
                }
            }
        }

        if let limitation = package.appleNativeConnectionLimitation {
            Section("兼容性") {
                Label(limitation, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func update(
        _ package: BrowserExtensionPackage,
        _ update: BrowserExtensionRuntimeConfigurationUpdate
    ) {
        Task { @MainActor in
            _ = await store.updateExtensionRuntimeConfiguration(
                for: package,
                update: update
            )
        }
    }

    private func setSitePermission(
        _ package: BrowserExtensionPackage,
        host: String,
        granted: Bool
    ) {
        guard let sitePermission = BrowserExtensionSitePermissionUpdate(
            host: host,
            isGranted: granted
        ) else { return }
        update(
            package,
            BrowserExtensionRuntimeConfigurationUpdate(
                sitePermission: sitePermission
            )
        )
    }
}

private struct BrowserExtensionSiteEditorRequest: Identifiable {
    let id = UUID()
    let updatesHostAccess: Bool
}

private struct BrowserExtensionSiteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool
    @State private var input = ""

    let onAdd: (String) -> Void

    private var normalizedHost: String? {
        BrowserExtensionSitePattern.normalizedPermissionPattern(from: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加网站")
                .font(.system(size: 16, weight: .semibold))

            TextField("example.com", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .onSubmit(addSite)

            if !input.isEmpty, normalizedHost == nil {
                Label("网站格式无效", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: addSite) {
                    Label("添加", systemImage: "plus")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedHost == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isInputFocused = true }
    }

    private func addSite() {
        guard let normalizedHost else { return }
        onAdd(normalizedHost)
        dismiss()
    }
}

private struct BrowserExtensionCatalogDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: BrowserExtensionCatalogItem
    let onInstall: () -> Void
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
                Text("Rex 可直接从 Google 官方更新服务下载这个扩展，验证 CRX 身份与签名后保存到受管目录；扩展包不会由 Rex 镜像或重新分发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Rex 兼容方式", systemImage: "info.circle")
                    .font(.callout.weight(.semibold))
                Text("扩展安装或更新完成后会立即同步到 Chromium 运行时。静态 popup、options、后台服务、内容脚本与受支持的 Chrome API 来自扩展本体；Rex 提供安装、启停、列表、小型面板和页面入口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    onInstall()
                    dismiss()
                } label: {
                    Label("直接安装到 Rex", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NSWorkspace.shared.open(item.officialURL)
                } label: {
                    Label("打开 Chrome Web Store", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)

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
