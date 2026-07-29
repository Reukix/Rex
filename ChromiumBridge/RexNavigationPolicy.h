#pragma once

#include <string_view>

namespace rex::navigation {

constexpr char ASCIILower(char value) {
  return value >= 'A' && value <= 'Z'
      ? static_cast<char>(value + ('a' - 'A'))
      : value;
}

constexpr bool HasASCIIScheme(std::string_view url,
                              std::string_view expected_scheme) {
  const std::size_t separator = url.find(':');
  if (separator != expected_scheme.size()) return false;
  for (std::size_t index = 0; index < separator; ++index) {
    if (ASCIILower(url[index]) != ASCIILower(expected_scheme[index])) {
      return false;
    }
  }
  return true;
}

// RexBrowserClient owns user-visible web content. Chromium WebUI is reserved
// for clients created explicitly for hidden, privileged runtime operations.
constexpr bool ShouldBlockVisibleBrowserNavigation(std::string_view url) {
  return HasASCIIScheme(url, "chrome");
}

// A fresh main-frame request owns a new navigation generation. Redirect hops
// stay in the generation of the request that initiated the chain.
constexpr bool ShouldStartNavigationGeneration(bool navigation_blocked,
                                               bool is_redirect) {
  return !navigation_blocked && !is_redirect;
}

// Restored web pages are parked on about:blank until Chromium has reconciled
// the persistent extension set. The placeholder remains an implementation
// detail after the barrier is released and until the real address commits.
constexpr bool ShouldHideStartupPlaceholder(bool awaits_real_address,
                                            std::string_view url) {
  return awaits_real_address && url == "about:blank";
}

}  // namespace rex::navigation
