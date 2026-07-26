#include "RexPrivacyEngine.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <set>
#include <string>
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

std::string RegistrableDomain(const std::string &host) {
  if (host.empty() || host == "localhost" || host.find(':') != std::string::npos) return host;
  const size_t lastDot = host.rfind('.');
  if (lastDot == std::string::npos) return host;
  const size_t secondLastDot = host.rfind('.', lastDot - 1);
  if (secondLastDot == std::string::npos) return host;

  const std::string suffix = host.substr(secondLastDot + 1);
  static const std::set<std::string> commonTwoLevelSuffixes = {
      "ac.uk", "co.jp", "co.uk", "com.au", "com.br", "com.cn", "com.sg",
      "gov.uk", "net.au", "org.au", "org.uk"};
  if (!commonTwoLevelSuffixes.contains(suffix)) return suffix;
  const size_t thirdLastDot = host.rfind('.', secondLastDot - 1);
  if (thirdLastDot == std::string::npos) return host;
  return host.substr(thirdLastDot + 1);
}

bool IsThirdPartyHost(const std::string &requestHost, const std::string &firstPartyHost) {
  if (requestHost.empty() || firstPartyHost.empty()) return false;
  return RegistrableDomain(requestHost) != RegistrableDomain(firstPartyHost);
}

// Curated advertising host catalog.
const std::vector<const char *> &AdvertisingDomains() {
  static const std::vector<const char *> domains = {
      "2mdn.net",
      "aax.amazon-adsystem.com",
      "ad.doubleclick.net",
      "adform.net",
      "admob.com",
      "adnxs.com",
      "ads.linkedin.com",
      "ads.pubmatic.com",
      "ads.twitter.com",
      "ads.yahoo.com",
      "adservice.google.com",
      "adsrvr.org",
      "advertising.com",
      "amazon-adsystem.com",
      "an.facebook.com",
      "app-measurement.com",
      "bidswitch.net",
      "casalemedia.com",
      "contextweb.com",
      "creative.ak.fbcdn.net",
      "criteo.com",
      "criteo.net",
      "doubleclick.net",
      "exoclick.com",
      "googleadservices.com",
      "googlesyndication.com",
      "googletagservices.com",
      "ib.adnxs.com",
      "media.net",
      "moatads.com",
      "openx.net",
      "outbrain.com",
      "pagead2.googlesyndication.com",
      "partner.googleadservices.com",
      "pubmatic.com",
      "rubiconproject.com",
      "securepubads.g.doubleclick.net",
      "smartadserver.com",
      "s0.2mdn.net",
      "static.ads-twitter.com",
      "taboola.com",
      "teads.tv",
      "tpc.googlesyndication.com",
      "yieldmo.com",
      "z.moatads.com",
  };
  return domains;
}

const std::vector<const char *> &TrackingDomains() {
  static const std::vector<const char *> domains = {
      "amplitude.com",
      "analytics.google.com",
      "analytics.twitter.com",
      "api.segment.io",
      "bat.bing.com",
      "cdn.segment.com",
      "clarity.ms",
      "connect.facebook.net",
      "facebook.net",
      "fullstory.com",
      "google-analytics.com",
      "googletagmanager.com",
      "heap-api.com",
      "heapanalytics.com",
      "hotjar.com",
      "hs-analytics.net",
      "insight.adsrvr.org",
      "log.byteoversea.com",
      "metrics.icloud.com",
      "mixpanel.com",
      "mouseflow.com",
      "newrelic.com",
      "nr-data.net",
      "optimizely.com",
      "pixel.facebook.com",
      "px.ads.linkedin.com",
      "quantserve.com",
      "scorecardresearch.com",
      "segment.com",
      "segment.io",
      "sentry.io",
      "snap.licdn.com",
      "static.hotjar.com",
      "static.ads-twitter.com",
      "stats.g.doubleclick.net",
      "t.co",
      "tiktok.com/i18n/pixel",
      "tr.snapchat.com",
      "www.google-analytics.com",
      "www.googletagmanager.com",
      "www.facebook.com/tr",
  };
  return domains;
}

const std::vector<const char *> &FingerprintingDomains() {
  static const std::vector<const char *> domains = {
      "api.fpjs.io",
      "cdn.fpjs.io",
      "device-api.fpjs.io",
      "fingerprint.com",
      "fingerprintjs.com",
      "fpcdn.io",
      "fpjs.io",
      "metrics.icloud.com",
      "clientservices.googleapis.com",
      "deviceid.adobe.com",
  };
  return domains;
}

// Social widgets / share buttons often used as trackers (strict+).
const std::vector<const char *> &SocialDomains() {
  static const std::vector<const char *> domains = {
      "connect.facebook.net",
      "platform.twitter.com",
      "platform.linkedin.com",
      "platform.instagram.com",
      "widgets.pinterest.com",
      "apis.google.com/js/platform.js",
      "s7.addthis.com",
      "w.sharethis.com",
  };
  return domains;
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
                        const std::vector<const char *> &catalog,
                        std::string *matched_rule) {
  for (const char *domain : catalog) {
    const std::string entry(domain);
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

  std::string rule;
  if (third_party || aggressive) {
    if (MatchDomainCatalog(host, path, AdvertisingDomains(), &rule)) {
      return {BlockCategory::Advertisement, host, rule};
    }
    if (MatchDomainCatalog(host, path, TrackingDomains(), &rule)) {
      return {BlockCategory::Tracker, host, rule};
    }
  }
  if (third_party && policy.fingerprintProtection &&
      MatchDomainCatalog(host, path, FingerprintingDomains(), &rule)) {
    return {BlockCategory::Fingerprinting, host, rule};
  }
  if (third_party && strict_or_more &&
      MatchDomainCatalog(host, path, SocialDomains(), &rule)) {
    return {BlockCategory::Tracker, host, rule};
  }
  if (aggressive && third_party &&
      PathContainsAny(path, SuspiciousPathFragments())) {
    return {BlockCategory::SuspiciousScript, host, "aggressive-path-heuristic"};
  }
  return {};
}

}  // namespace

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

size_t AdvertisingDomainCount() { return AdvertisingDomains().size(); }
size_t TrackingDomainCount() { return TrackingDomains().size(); }
size_t FingerprintingDomainCount() { return FingerprintingDomains().size(); }
size_t SocialDomainCount() { return SocialDomains().size(); }

}  // namespace rex::privacy
