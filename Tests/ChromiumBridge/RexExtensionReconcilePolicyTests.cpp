#include "RexExtensionReconcilePolicy.h"

#include <array>
#include <iostream>

namespace {

struct ReconcileCase {
  bool should_be_enabled;
  bool is_enabled;
  bool package_changed;
  bool should_reload;
};

constexpr std::array kCases{
    ReconcileCase{true, false, false, true},
    ReconcileCase{true, false, true, true},
    ReconcileCase{true, true, true, true},
    ReconcileCase{true, true, false, false},
    ReconcileCase{false, true, true, false},
    ReconcileCase{false, false, true, false},
};

static_assert([] {
  for (const auto &test_case : kCases) {
    if (rex::extensions::ShouldReloadAfterEnableOrUpdate(
            test_case.should_be_enabled,
            test_case.is_enabled,
            test_case.package_changed) != test_case.should_reload) {
      return false;
    }
  }
  return true;
}());

static_assert(rex::extensions::CanCommitReconcile(true, true, true));
static_assert(!rex::extensions::CanCommitReconcile(false, true, true));
static_assert(!rex::extensions::CanCommitReconcile(true, false, true));
static_assert(!rex::extensions::CanCommitReconcile(true, true, false));
static_assert(!rex::extensions::CanCommitReconcile(false, false, false));
static_assert(!rex::extensions::IsExtensionConfigurationMutation(false, false));
static_assert(rex::extensions::IsExtensionConfigurationMutation(true, false));
static_assert(rex::extensions::IsExtensionConfigurationMutation(false, true));
static_assert(rex::extensions::IsExtensionConfigurationMutation(true, true));

}  // namespace

int main() {
  for (const auto &test_case : kCases) {
    const bool actual = rex::extensions::ShouldReloadAfterEnableOrUpdate(
        test_case.should_be_enabled,
        test_case.is_enabled,
        test_case.package_changed);
    if (actual == test_case.should_reload) continue;
    std::cerr << "Unexpected extension reconcile reload decision\n";
    return 1;
  }
  if (!rex::extensions::CanCommitReconcile(true, true, true) ||
      rex::extensions::CanCommitReconcile(false, true, true) ||
      rex::extensions::CanCommitReconcile(true, false, true) ||
      rex::extensions::CanCommitReconcile(true, true, false) ||
      rex::extensions::CanCommitReconcile(false, false, false)) {
    std::cerr << "Unexpected extension reconcile commit decision\n";
    return 1;
  }
  if (rex::extensions::IsExtensionConfigurationMutation(false, false) ||
      !rex::extensions::IsExtensionConfigurationMutation(true, false) ||
      !rex::extensions::IsExtensionConfigurationMutation(false, true) ||
      !rex::extensions::IsExtensionConfigurationMutation(true, true)) {
    std::cerr << "Unexpected extension configuration mutation decision\n";
    return 1;
  }
  return 0;
}
