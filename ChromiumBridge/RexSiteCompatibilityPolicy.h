#pragma once

#include <string_view>

namespace rex::site_compatibility {

constexpr char ASCIILower(char value) {
  return value >= 'A' && value <= 'Z'
      ? static_cast<char>(value + ('a' - 'A'))
      : value;
}

constexpr bool ASCIIEqual(std::string_view lhs, std::string_view rhs) {
  if (lhs.size() != rhs.size()) return false;
  for (std::size_t index = 0; index < lhs.size(); ++index) {
    if (ASCIILower(lhs[index]) != ASCIILower(rhs[index])) return false;
  }
  return true;
}

constexpr std::string_view HTTPHost(std::string_view url) {
  const std::size_t schemeSeparator = url.find("://");
  if (schemeSeparator == std::string_view::npos) return {};
  const std::string_view scheme = url.substr(0, schemeSeparator);
  if (!ASCIIEqual(scheme, "http") && !ASCIIEqual(scheme, "https")) return {};

  const std::size_t authorityStart = schemeSeparator + 3;
  const std::size_t authorityEnd = url.find_first_of("/?#", authorityStart);
  std::string_view authority = url.substr(
      authorityStart,
      authorityEnd == std::string_view::npos
          ? std::string_view::npos
          : authorityEnd - authorityStart);
  const std::size_t userInfoEnd = authority.rfind('@');
  if (userInfoEnd != std::string_view::npos) {
    authority.remove_prefix(userInfoEnd + 1);
  }
  if (authority.empty() || authority.front() == '[') return {};
  const std::size_t portSeparator = authority.find(':');
  std::string_view host = authority.substr(0, portSeparator);
  while (!host.empty() && host.back() == '.') host.remove_suffix(1);
  return host;
}

constexpr bool HostMatches(std::string_view host, std::string_view domain) {
  if (ASCIIEqual(host, domain)) return true;
  if (host.size() <= domain.size() ||
      host[host.size() - domain.size() - 1] != '.') {
    return false;
  }
  return ASCIIEqual(host.substr(host.size() - domain.size()), domain);
}

// Some sites reject CEF's Chromium-only brand list even when the engine is
// current. Keep the Chrome compatibility identity narrowly scoped to the
// affected first-party domain instead of changing Rex's global identity.
constexpr bool ShouldUseChromeCompatibilityIdentity(std::string_view url) {
  return HostMatches(HTTPHost(url), "douyin.com");
}

}  // namespace rex::site_compatibility
