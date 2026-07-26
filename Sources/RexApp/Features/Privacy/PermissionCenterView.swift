import SwiftUI

struct PermissionCenterView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    private var groupedPermissions: [(origin: String, items: [WebsitePermission])] {
        let grouped = Dictionary(grouping: store.permissions) { $0.topLevelOrigin }
        return grouped
            .map { (origin: $0.key, items: $0.value.sorted { $0.kind.displayName < $1.kind.displayName }) }
            .sorted { $0.origin.localizedCaseInsensitiveCompare($1.origin) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("网站权限")
                        .font(.headline)
                    Text(store.profile.isPrivate
                         ? "隐私窗口中的决定仅在当前会话有效"
                         : "管理已保存的决定和当前标签页的临时授权")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            if store.permissions.isEmpty {
                ContentUnavailableView(
                    "还没有保存的网站权限",
                    systemImage: "hand.raised",
                    description: Text("当网站请求摄像头、麦克风或位置等权限时，决定会出现在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedPermissions, id: \.origin) { group in
                        Section(group.origin) {
                            ForEach(group.items) { permission in
                                HStack(spacing: 12) {
                                    Image(systemName: permission.kind.symbolName)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(permission.kind.displayName)
                                            .font(.body.weight(.medium))
                                        Text(permission.requestingOrigin)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if permission.decision.isPersistent {
                                        Picker(
                                            "决定",
                                            selection: Binding(
                                                get: { permission.decision },
                                                set: { store.updatePermission(permission, decision: $0) }
                                            )
                                        ) {
                                            ForEach(PermissionDecision.permissionCenterCases, id: \.self) { decision in
                                                Text(decision.displayName).tag(decision)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: 128)
                                    } else {
                                        Text(permission.decision.displayName)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 128, alignment: .trailing)
                                    }

                                    Button(role: .destructive) {
                                        store.revokePermission(permission)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("删除权限")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
