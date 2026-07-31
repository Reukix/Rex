#include "RexPrivacyEngine.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "include/cef_parser.h"

namespace rex::privacy {
namespace {

std::string LowerASCII(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string TrimASCII(std::string value) {
  while (!value.empty() && std::isspace(static_cast<unsigned char>(value.front()))) {
    value.erase(value.begin());
  }
  while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
  }
  return value;
}

std::string NormalizeHost(std::string host) {
  host = LowerASCII(TrimASCII(std::move(host)));
  while (!host.empty() && host.back() == '.') host.pop_back();
  if (host.empty() || host.find(':') != std::string::npos) return host;
  CefURLParts parts;
  if (CefParseURL("https://" + host, parts)) {
    const std::string normalized =
        LowerASCII(CefString(&parts.host).ToString());
    if (!normalized.empty()) return normalized;
  }
  return host;
}

bool IsIPv4Address(const std::string &host) {
  int component_count = 0;
  size_t start = 0;
  while (start <= host.size()) {
    const size_t end = host.find('.', start);
    const std::string component = host.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    if (component.empty() || component.size() > 3 ||
        !std::all_of(component.begin(), component.end(), ::isdigit)) {
      return false;
    }
    const int value = std::stoi(component);
    if (value > 255 || (component.size() > 1 && component.front() == '0')) {
      return false;
    }
    ++component_count;
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return component_count == 4;
}

struct PublicSuffixRules {
  std::unordered_set<std::string> exact;
  std::unordered_set<std::string> wildcard;
  std::unordered_set<std::string> exception;
};

std::mutex g_public_suffix_mutex;
std::shared_ptr<const PublicSuffixRules> g_public_suffix_rules;

std::vector<std::string> SplitLabels(const std::string &host) {
  std::vector<std::string> labels;
  size_t start = 0;
  while (start <= host.size()) {
    const size_t end = host.find('.', start);
    labels.push_back(host.substr(
        start, end == std::string::npos ? std::string::npos : end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return labels;
}

std::string JoinLabels(const std::vector<std::string> &labels, size_t start) {
  std::string result;
  for (size_t index = start; index < labels.size(); ++index) {
    if (!result.empty()) result.push_back('.');
    result.append(labels[index]);
  }
  return result;
}

std::string HostForURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return {};
  return LowerASCII(CefString(&parts.host).ToString());
}

std::string PathForURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return {};
  return LowerASCII(CefString(&parts.path).ToString());
}

std::string QueryForURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return {};
  return LowerASCII(CefString(&parts.query).ToString());
}

bool HostMatches(const std::string &host, const std::string &domain) {
  if (host.empty() || domain.empty()) return false;
  if (host == domain) return true;
  return host.size() > domain.size() &&
         host.compare(host.size() - domain.size(), domain.size(), domain) == 0 &&
         host[host.size() - domain.size() - 1] == '.';
}

bool PathContainsAny(const std::string &path, const std::vector<const char *> &needles) {
  for (const char *needle : needles) {
    if (path.find(needle) != std::string::npos) return true;
  }
  return false;
}

// Brave-style first-party safe path: do not block main document loads.
bool IsMainFrame(CefRefPtr<CefRequest> request) {
  return request && request->GetResourceType() == RT_MAIN_FRAME;
}

bool IsThirdPartyHost(const std::string &requestHost, const std::string &firstPartyHost) {
  if (requestHost.empty() || firstPartyHost.empty()) return false;
  return RegistrableDomainForHost(requestHost) !=
      RegistrableDomainForHost(firstPartyHost);
}

struct PrivacyCatalog {
  std::string version;
  std::vector<std::string> advertising;
  std::vector<std::string> tracking;
  std::vector<std::string> fingerprinting;
  std::vector<std::string> social;
};

std::mutex g_privacy_catalog_mutex;
std::shared_ptr<const PrivacyCatalog> g_privacy_catalog;

std::shared_ptr<const PrivacyCatalog> CurrentPrivacyCatalog() {
  std::lock_guard lock(g_privacy_catalog_mutex);
  return g_privacy_catalog;
}

bool IsValidCatalogEntry(const std::string &entry) {
  if (entry.empty() || entry.size() > 512 || entry != LowerASCII(entry) ||
      entry.find(':') != std::string::npos ||
      entry.find('\\') != std::string::npos ||
      entry.find("..") != std::string::npos ||
      TrimASCII(entry) != entry) {
    return false;
  }
  const size_t slash = entry.find('/');
  const std::string host = entry.substr(0, slash);
  if (host.empty() || NormalizeHost(host) != host) return false;
  if (slash != std::string::npos) {
    const std::string path = entry.substr(slash);
    if (path.size() < 2 || path.find("//") != std::string::npos) return false;
  }
  return true;
}

bool ParseCatalogEntries(CefRefPtr<CefDictionaryValue> dictionary,
                         const char *key,
                         std::vector<std::string> *entries) {
  if (!dictionary || !entries || dictionary->GetType(key) != VTYPE_LIST) {
    return false;
  }
  CefRefPtr<CefListValue> values = dictionary->GetList(key);
  if (!values || values->GetSize() == 0 || values->GetSize() > 100000) {
    return false;
  }
  std::unordered_set<std::string> unique;
  entries->reserve(values->GetSize());
  for (size_t index = 0; index < values->GetSize(); ++index) {
    if (values->GetType(index) != VTYPE_STRING) return false;
    std::string entry = CefString(values->GetString(index)).ToString();
    if (!IsValidCatalogEntry(entry) || !unique.insert(entry).second) {
      return false;
    }
    entries->push_back(std::move(entry));
  }
  return true;
}

const std::vector<const char *> &SuspiciousPathFragments() {
  static const std::vector<const char *> fragments = {
      "/ads?",
      "/ads/",
      "/ad.js",
      "/adserv",
      "/advert",
      "/banner",
      "/pagead",
      "/pixel",
      "/track",
      "/tracker",
      "/collect?",
      "/beacon",
      "/analytics",
      "/gtag/js",
      "/gtm.js",
      "/fbevents",
      "/bat.js",
      "/hotjar",
      "/fingerprint",
      "/fp.js",
      "/adsbygoogle",
      "/doubleclick",
      "/prebid",
      "/pb.js",
  };
  return fragments;
}

bool MatchDomainCatalog(const std::string &host,
                        const std::string &path,
                        const std::vector<std::string> &catalog,
                        std::string *matched_rule) {
  for (const std::string &entry : catalog) {
    const auto slash = entry.find('/');
    if (slash == std::string::npos) {
      if (HostMatches(host, entry)) {
        if (matched_rule) *matched_rule = entry;
        return true;
      }
    } else {
      const std::string entry_host = entry.substr(0, slash);
      const std::string entry_path = entry.substr(slash);
      if (HostMatches(host, entry_host) && path.find(entry_path) != std::string::npos) {
        if (matched_rule) *matched_rule = entry;
        return true;
      }
    }
  }
  return false;
}

std::atomic_bool g_content_blocking_enabled{true};

// Curated-catalog classification (v0.8.0). Design constraints from the two
// removed predecessors: the build-605 blocker overblocked via broad path
// heuristics, so standard/strict modes match exact third-party host catalogs
// only — no path heuristics, and first-party requests always pass. Only the
// opt-in aggressive mode widens matching.
BlockDecision ClassifyWithPolicy(CefRefPtr<CefRequest> request,
                                 const ProtectionPolicy &policy) {
  if (!request) return {};
  if (!ContentBlockingEnabled()) return {};
  if (!policy.enabled || policy.mode == ProtectionMode::Off) return {};
  if (IsMainFrame(request)) return {};

  const std::string host = HostForURL(request->GetURL());
  if (host.empty()) return {};
  const std::string path = PathForURL(request->GetURL());

  std::string first_party = HostForURL(request->GetFirstPartyForCookies());
  if (first_party.empty()) first_party = policy.firstPartyHost;
  // Unknown first party counts as first-party so nothing is blocked without
  // evidence of a cross-site request.
  const bool third_party = IsThirdPartyHost(host, first_party);
  const bool aggressive = policy.mode == ProtectionMode::Aggressive;
  const bool strict_or_more = aggressive || policy.mode == ProtectionMode::Strict;
  const std::shared_ptr<const PrivacyCatalog> catalog = CurrentPrivacyCatalog();
  if (!catalog) return {};

  std::string rule;
  if (third_party || aggressive) {
    if (MatchDomainCatalog(host, path, catalog->advertising, &rule)) {
      return {BlockCategory::Advertisement, host, rule};
    }
    if (MatchDomainCatalog(host, path, catalog->tracking, &rule)) {
      return {BlockCategory::Tracker, host, rule};
    }
  }
  if (third_party && policy.fingerprintProtection &&
      MatchDomainCatalog(host, path, catalog->fingerprinting, &rule)) {
    return {BlockCategory::Fingerprinting, host, rule};
  }
  if (third_party && strict_or_more &&
      MatchDomainCatalog(host, path, catalog->social, &rule)) {
    return {BlockCategory::Tracker, host, rule};
  }
  if (aggressive && third_party &&
      PathContainsAny(path, SuspiciousPathFragments())) {
    return {BlockCategory::SuspiciousScript, host, "aggressive-path-heuristic"};
  }
  return {};
}

}  // namespace

bool ConfigurePublicSuffixList(const std::string &contents) {
  auto rules = std::make_shared<PublicSuffixRules>();
  std::istringstream input(contents);
  std::string line;
  while (std::getline(input, line)) {
    line = TrimASCII(std::move(line));
    if (line.empty() || line.rfind("//", 0) == 0) continue;
    if (line.front() == '!') {
      const std::string rule = NormalizeHost(line.substr(1));
      if (!rule.empty()) rules->exception.insert(rule);
    } else if (line.rfind("*.", 0) == 0) {
      const std::string rule = NormalizeHost(line.substr(2));
      if (!rule.empty()) rules->wildcard.insert(rule);
    } else {
      const std::string rule = NormalizeHost(line);
      if (!rule.empty()) rules->exact.insert(rule);
    }
  }
  if (rules->exact.empty()) return false;
  std::lock_guard lock(g_public_suffix_mutex);
  g_public_suffix_rules = std::move(rules);
  return true;
}

bool ConfigurePrivacyCatalog(const std::string &contents) {
  CefRefPtr<CefValue> root = CefParseJSON(contents, JSON_PARSER_RFC);
  if (!root || root->GetType() != VTYPE_DICTIONARY) return false;
  CefRefPtr<CefDictionaryValue> dictionary = root->GetDictionary();
  if (!dictionary || dictionary->GetInt("schemaVersion") != 1 ||
      dictionary->GetType("catalogVersion") != VTYPE_STRING) {
    return false;
  }
  auto catalog = std::make_shared<PrivacyCatalog>();
  catalog->version = CefString(dictionary->GetString("catalogVersion")).ToString();
  if (catalog->version.empty() ||
      !ParseCatalogEntries(dictionary, "advertising", &catalog->advertising) ||
      !ParseCatalogEntries(dictionary, "tracking", &catalog->tracking) ||
      !ParseCatalogEntries(dictionary, "fingerprinting", &catalog->fingerprinting) ||
      !ParseCatalogEntries(dictionary, "social", &catalog->social)) {
    return false;
  }
  std::lock_guard lock(g_privacy_catalog_mutex);
  g_privacy_catalog = std::move(catalog);
  return true;
}

std::string RegistrableDomainForHost(const std::string &raw_host) {
  const std::string host = NormalizeHost(raw_host);
  if (host.empty() || host == "localhost" ||
      host.find(':') != std::string::npos || IsIPv4Address(host)) {
    return host;
  }
  const std::vector<std::string> labels = SplitLabels(host);
  if (labels.size() < 2) return host;

  std::shared_ptr<const PublicSuffixRules> rules;
  {
    std::lock_guard lock(g_public_suffix_mutex);
    rules = g_public_suffix_rules;
  }
  if (!rules) return host;

  size_t public_suffix_labels = 1;
  for (size_t index = 0; index < labels.size(); ++index) {
    const std::string suffix = JoinLabels(labels, index);
    if (rules->exception.contains(suffix)) {
      public_suffix_labels = std::max<size_t>(1, labels.size() - index - 1);
      break;
    }
    if (rules->exact.contains(suffix)) {
      public_suffix_labels =
          std::max(public_suffix_labels, labels.size() - index);
    }
    if (index > 0 && rules->wildcard.contains(suffix)) {
      public_suffix_labels =
          std::max(public_suffix_labels, labels.size() - index + 1);
    }
  }
  if (labels.size() <= public_suffix_labels) return host;
  return JoinLabels(labels, labels.size() - public_suffix_labels - 1);
}

void SetContentBlockingEnabled(bool enabled) {
  g_content_blocking_enabled.store(enabled, std::memory_order_relaxed);
}

bool ContentBlockingEnabled() {
  return g_content_blocking_enabled.load(std::memory_order_relaxed);
}

BlockDecision ClassifyRequest(CefRefPtr<CefRequest> request) {
  ProtectionPolicy policy;
  return ClassifyWithPolicy(request, policy);
}

BlockDecision ClassifyRequest(CefRefPtr<CefRequest> request,
                              const ProtectionPolicy &policy) {
  return ClassifyWithPolicy(request, policy);
}

bool ShouldBlockThirdPartyCookie(CefRefPtr<CefRequest> request,
                                 const ProtectionPolicy &policy) {
  if (!request || !policy.blockThirdPartyCookies) return false;
  const std::string request_host = HostForURL(request->GetURL());
  std::string first_party_host = HostForURL(request->GetFirstPartyForCookies());
  if (first_party_host.empty()) {
    first_party_host = policy.firstPartyHost;
  }
  return IsThirdPartyHost(request_host, first_party_host);
}

const char *CategoryToken(BlockCategory category) {
  switch (category) {
    case BlockCategory::Advertisement:
      return "advertisement";
    case BlockCategory::Tracker:
      return "tracker";
    case BlockCategory::Fingerprinting:
      return "fingerprinting";
    case BlockCategory::SuspiciousScript:
      return "suspiciousScript";
    case BlockCategory::Malware:
      return "malware";
    case BlockCategory::None:
      return "none";
  }
  return "none";
}

const char *ModeToken(ProtectionMode mode) {
  switch (mode) {
    case ProtectionMode::Off:
      return "off";
    case ProtectionMode::Standard:
      return "standard";
    case ProtectionMode::Strict:
      return "strict";
    case ProtectionMode::Aggressive:
      return "aggressive";
  }
  return "standard";
}

ProtectionMode ModeFromToken(const std::string &token) {
  const std::string value = LowerASCII(token);
  if (value == "off" || value == "disabled") return ProtectionMode::Off;
  if (value == "strict") return ProtectionMode::Strict;
  if (value == "aggressive" || value == "custom") return ProtectionMode::Aggressive;
  return ProtectionMode::Standard;
}

size_t AdvertisingDomainCount() {
  const auto catalog = CurrentPrivacyCatalog();
  return catalog ? catalog->advertising.size() : 0;
}
size_t TrackingDomainCount() {
  const auto catalog = CurrentPrivacyCatalog();
  return catalog ? catalog->tracking.size() : 0;
}
size_t FingerprintingDomainCount() {
  const auto catalog = CurrentPrivacyCatalog();
  return catalog ? catalog->fingerprinting.size() : 0;
}
size_t SocialDomainCount() {
  const auto catalog = CurrentPrivacyCatalog();
  return catalog ? catalog->social.size() : 0;
}

}  // namespace rex::privacy
