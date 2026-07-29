#pragma once

namespace rex::extensions {

// Enabling a persistent unpacked extension must reread its package from disk.
// This covers disabled updates whose JS/CSS changed without a version bump,
// including changes made before a Rex restart.
constexpr bool ShouldReloadAfterEnableOrUpdate(bool should_be_enabled,
                                               bool is_enabled,
                                               bool package_changed) {
  return should_be_enabled && (!is_enabled || package_changed);
}

// Registry fields cannot prove that a same-version reload actually executed.
// Commit package replacements only when the native mutation and authoritative
// registry verification succeeded, and the package still matches the
// fingerprint snapshot consumed by this transaction.
constexpr bool CanCommitReconcile(bool operation_succeeded,
                                  bool registry_verified,
                                  bool package_snapshot_stable) {
  return operation_succeeded && registry_verified && package_snapshot_stable;
}

// Configuration writes can use either updateExtensionConfiguration or the
// dedicated host-permission API. Both leave an unknown state after timeout.
constexpr bool IsExtensionConfigurationMutation(
    bool has_configuration_update,
    bool has_site_permission_update) {
  return has_configuration_update || has_site_permission_update;
}

}  // namespace rex::extensions
