#include "RexNavigationPolicy.h"

#include <array>
#include <iostream>
#include <string_view>

namespace {

struct NavigationCase {
  std::string_view url;
  bool should_block;
};

constexpr std::array kCases{
    NavigationCase{"chrome://extensions/", true},
    NavigationCase{"chrome://extensions/?id=abcdefghijklmnop", true},
    NavigationCase{"chrome://settings/", true},
    NavigationCase{"CHROME://VERSION/", true},
    NavigationCase{"chrome:extensions", true},
    NavigationCase{"chrome-extension://abcdefghijklmnop/options.html", false},
    NavigationCase{"rex://extensions", false},
    NavigationCase{"https://example.com/chrome://extensions", false},
    NavigationCase{"about:blank", false},
    NavigationCase{"", false},
};

static_assert([] {
  for (const auto &test_case : kCases) {
    if (rex::navigation::ShouldBlockVisibleBrowserNavigation(test_case.url) !=
        test_case.should_block) {
      return false;
    }
  }
  return true;
}());

static_assert(
    rex::navigation::ShouldStartNavigationGeneration(false, false));
static_assert(
    !rex::navigation::ShouldStartNavigationGeneration(true, false));
static_assert(
    !rex::navigation::ShouldStartNavigationGeneration(false, true));

struct StartupPlaceholderCase {
  bool awaits_real_address;
  std::string_view url;
  bool should_hide;
};

constexpr std::array kStartupPlaceholderCases{
    // The first case represents a released startup barrier whose delayed
    // about:blank callback is still waiting behind the real navigation.
    StartupPlaceholderCase{true, "about:blank", true},
    StartupPlaceholderCase{false, "about:blank", false},
    StartupPlaceholderCase{true, "https://example.com", false},
    StartupPlaceholderCase{true, "", false},
};

static_assert([] {
  for (const auto &test_case : kStartupPlaceholderCases) {
    if (rex::navigation::ShouldHideStartupPlaceholder(
            test_case.awaits_real_address,
            test_case.url) != test_case.should_hide) {
      return false;
    }
  }
  return true;
}());

}  // namespace

int main() {
  for (const auto &test_case : kCases) {
    const bool actual =
        rex::navigation::ShouldBlockVisibleBrowserNavigation(test_case.url);
    if (actual == test_case.should_block) continue;
    std::cerr << "Unexpected visible navigation policy for " << test_case.url
              << '\n';
    return 1;
  }
  if (!rex::navigation::ShouldStartNavigationGeneration(false, false) ||
      rex::navigation::ShouldStartNavigationGeneration(true, false) ||
      rex::navigation::ShouldStartNavigationGeneration(false, true)) {
    std::cerr << "Unexpected navigation generation policy\n";
    return 1;
  }
  for (const auto &test_case : kStartupPlaceholderCases) {
    const bool actual = rex::navigation::ShouldHideStartupPlaceholder(
        test_case.awaits_real_address,
        test_case.url);
    if (actual == test_case.should_hide) continue;
    std::cerr << "Unexpected startup placeholder policy for "
              << test_case.url << '\n';
    return 1;
  }
  return 0;
}
