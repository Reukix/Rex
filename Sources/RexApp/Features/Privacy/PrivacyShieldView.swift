import Combine
import SwiftUI

struct PrivacyShieldView: View {
    @EnvironmentObject private var store: BrowserStore
    @EnvironmentObject private var preferences: BrowserPreferences
    let report: PrivacyReport

    private var tab: BrowserTab? { store.currentTab }
    private var protectionEnabled: Bool { tab?.privacyState.isEnabled ?? true }
    private var level: PrivacyLevel { tab?.privacyState.level ?? .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill((protectionEnabled ? Color.green : Color.orange).opacity(0.16))
                    Image(systemName: protectionEnabled ? "shield.checkered" : "shield.slash")
                        .foregroundStyle(protectionEnabled ? .green : .orange)
                        .font(.title2)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(protectionEnabled ? "保护已开启" : "保护已暂停")
                        .font(.headline)
                    Text(report.siteHost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { protectionEnabled },
                        set: { store.setPrivacyProtectionEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("当前网站保护")
            }

            Text("本页已阻止 \(report.totalBlocked) 项")
                .font(.title3.bold())

            VStack(spacing: 10) {
                metric("广告", value: report.adsBlocked, symbol: "rectangle.slash")
                metric("跨站追踪器", value: report.trackersBlocked, symbol: "scope")
                metric("第三方 Cookie", value: report.thirdPartyCookiesBlocked, symbol: "circle.hexagongrid")
                metric("可疑脚本", value: report.suspiciousScriptsBlocked, symbol: "chevron.left.forwardslash.chevron.right")
                metric("HTTPS 升级", value: report.httpsUpgrades, symbol: "lock.fill")
                metric("清理追踪参数", value: report.cleanedParameters, symbol: "link.badge.plus")
            }

            if !report.resources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近拦截")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(report.resources.prefix(5)) { resource in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: resource.category))
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 14)
                            Text(resource.host)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("×\(resource.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("保护级别")
                Spacer()
                Picker(
                    "保护级别",
                    selection: Binding(
                        get: { level },
                        set: { store.setPrivacyLevel($0) }
                    )
                ) {
                    ForEach(PrivacyLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                .disabled(!protectionEnabled)
            }

            Button {
                store.isPrivacyPresented = false
                DispatchQueue.main.async { store.isPermissionCenterPresented = true }
            } label: {
                HStack {
                    Label("网站权限", systemImage: "hand.raised.fill")
                    Spacer()
                    Text(store.currentSitePermissions.isEmpty ? "每次询问" : "\(store.currentSitePermissions.count) 项")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Text(
                preferences.contentBlockingEnabled
                    ? "广告与追踪拦截使用内置域名目录，仅针对已知服务的第三方请求；可在「设置 › 隐私与安全」中关闭。"
                    : "内容拦截已在设置中关闭，当前仅保留 Cookie 限制、HTTPS 升级与站点权限防护。"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.body.monospacedDigit().weight(.semibold))
        }
    }

    private func icon(for category: BlockedResource.Category) -> String {
        switch category {
        case .advertisement: return "rectangle.slash"
        case .tracker: return "scope"
        case .thirdPartyCookie: return "circle.hexagongrid"
        case .fingerprinting: return "hand.raised"
        case .suspiciousScript: return "chevron.left.forwardslash.chevron.right"
        case .trackingParameter: return "link.badge.plus"
        case .insecureRequest: return "lock.open"
        case .redirect: return "arrow.triangle.branch"
        }
    }
}
