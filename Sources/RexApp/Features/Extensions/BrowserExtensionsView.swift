import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserExtensionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var extensionsStore = BrowserExtensionsStore.shared
    @State private var installError: String?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("无法安装扩展", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("好") { installError = nil }
        } message: {
            Text(installError ?? "")
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
                installError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("扩展")
                    .font(.system(size: 16, weight: .semibold))
                Text("管理本地 Chrome 风格未打包扩展 · 已安装 \(extensionsStore.extensions.count) 个")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                isImporting = true
            } label: {
                Label("加载未打包扩展", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Button {
                extensionsStore.openPackagesDirectory()
            } label: {
                Label("打开目录", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if extensionsStore.extensions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    runtimeNotice
                    ForEach(extensionsStore.extensions) { package in
                        extensionCard(package)
                    }
                }
                .padding(18)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            runtimeNotice
                .padding(.horizontal, 18)
                .padding(.top, 18)

            Spacer(minLength: 20)

            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text("尚未安装扩展")
                .font(.system(size: 18, weight: .semibold))
            Text("选择包含 manifest.json 的未打包 Chrome 扩展文件夹。Rex 会保存清单与权限信息；完整脚本运行时将在后续 CEF 扩展子集中接入。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button {
                isImporting = true
            } label: {
                Label("加载未打包扩展", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runtimeNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Chrome 扩展兼容说明")
                    .font(.system(size: 12, weight: .semibold))
                Text("当前 CEF 150 最小发行版未暴露完整扩展加载 API。你可以安装并管理本地扩展包；页面脚本注入等运行时能力会在受控扩展子集落地后启用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func extensionCard(_ package: BrowserExtensionPackage) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(package.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("v\(package.version)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    statusChip(package.runtimeStatus)
                    Spacer(minLength: 0)
                }

                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(package.permissionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Toggle("启用", isOn: Binding(
                        get: { package.isEnabled },
                        set: { extensionsStore.setEnabled($0, for: package.id) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text(package.isEnabled ? "已启用" : "已禁用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button("在 Finder 中显示") {
                        extensionsStore.revealInFinder(package.id)
                    }
                    .buttonStyle(.bordered)

                    Button("移除", role: .destructive) {
                        extensionsStore.remove(package.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
        }
    }

    private func statusChip(_ status: BrowserExtensionPackage.RuntimeStatus) -> some View {
        Text(status.displayName)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func install(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            _ = try extensionsStore.installUnpacked(from: url)
        } catch {
            installError = error.localizedDescription
        }
    }
}
