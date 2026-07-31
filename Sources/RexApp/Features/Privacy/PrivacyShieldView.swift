import Combine
import SwiftUI

struct PrivacyShieldView: View {
    @EnvironmentObject private var store: BrowserStore
    @EnvironmentObject private var preferences: BrowserPreferences
    let report: PrivacyReport

    private var tab: BrowserTab? { store.currentTab }
    private var sitePolicy: SitePrivacyPolicy? { store.sitePrivacyPolicy(for: tab) }
    private var protectionEnabled: Bool {
        sitePolicy?.protectionEnabled ?? tab?.privacyState.isEnabled ?? true
    }
    private var level: PrivacyLevel {
        sitePolicy?.level ?? tab?.privacyState.level ?? .standard
    }

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
                .accessibilityLabel("此网站的隐私保护")
            }

            Text("此标签会话已阻止 \(report.totalBlocked) 项")
                .font(.title3.bold())

            VStack(spacing: 10) {
                metric("广告", value: report.adsBlocked, symbol: "rectangle.slash")
                metric("跨站追踪器", value: report.trackersBlocked, symbol: "scope")
                metric("已知指纹服务", value: report.fingerprintingBlocked, symbol: "hand.raised")
                metric("可疑脚本", value: report.suspiciousScriptsBlocked, symbol: "chevron.left.forwardslash.chevron.right")
                metric("HTTPS 升级", value: report.httpsUpgrades, symbol: "lock.fill")
                metric("清理追踪参数", value: report.cleanedParameters, symbol: "link.badge.plus")
                HStack {
                    Image(systemName: "circle.hexagongrid")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    Text("第三方 Cookie")
                    Spacer()
                    Text(preferences.blockThirdPartyCookies ? "应用级限制" : "允许")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
                    ? "保护策略按公共后缀站点保存并同步到同站标签；统计在当前标签的整个会话内累计。第三方 Cookie 是应用级共享设置，不随网站开关改变。"
                    : "内容拦截已在设置中关闭。统计仍按当前标签会话保留；第三方 Cookie 是应用级共享设置，不随网站开关改变。"
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
