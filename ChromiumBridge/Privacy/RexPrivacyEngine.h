#pragma once

#include <string>
#include <vector>

#include "include/cef_request.h"

// Privacy policy surface used by Rex on the CEF/Chromium binary.
// Ad/tracker blocking uses curated third-party host catalogs (v0.8.0; the
// v0.7.0 EasyList engine was removed), gated by the per-tab shield policy and
// the global content-blocking preference.
// Thorium performance flags live in RexThoriumFlags.
namespace rex::privacy {

// Configures the pinned Mozilla Public Suffix List used for site ownership.
// Rules include ICANN/private domains plus wildcard and exception entries.
bool ConfigurePublicSuffixList(const std::string &contents);
std::string RegistrableDomainForHost(const std::string &host);

// Configures the signed/bundled Rex privacy catalog selected for this launch.
// Parsing builds a complete snapshot and swaps it atomically after validation.
bool ConfigurePrivacyCatalog(const std::string &contents);

enum class BlockCategory {
  None,
  Advertisement,
  Tracker,
  Fingerprinting,
  SuspiciousScript,
  Malware,
};

// Mirrors Swift PrivacyLevel + shield toggle. Standard is Brave-like default.
enum class ProtectionMode {
  Off = 0,
  Standard = 1,
  Strict = 2,
  Aggressive = 3,
};

struct BlockDecision {
  BlockCategory category = BlockCategory::None;
  std::string host;
  std::string rule;
};

struct ProtectionPolicy {
  ProtectionMode mode = ProtectionMode::Standard;
  bool enabled = true;
  bool fingerprintProtection = true;
  bool blockThirdPartyCookies = true;
  // Optional first-party / document host for third-party classification.
  std::string firstPartyHost;
};

// Global content-blocking toggle bound to the Settings switch. Thread-safe;
// read on the CEF IO thread for every subresource request.
void SetContentBlockingEnabled(bool enabled);
bool ContentBlockingEnabled();

// Classify a network request. Main-frame navigations are never blocked here.
BlockDecision ClassifyRequest(CefRefPtr<CefRequest> request);
BlockDecision ClassifyRequest(CefRefPtr<CefRequest> request,
                              const ProtectionPolicy &policy);

// Whether third-party cookies should be blocked for this request under policy.
bool ShouldBlockThirdPartyCookie(CefRefPtr<CefRequest> request,
                                 const ProtectionPolicy &policy);

// Human-readable category token shared with Swift/ObjC event payloads.
const char *CategoryToken(BlockCategory category);
const char *ModeToken(ProtectionMode mode);
ProtectionMode ModeFromToken(const std::string &token);

// Expanded host catalog size for diagnostics and release notes.
size_t AdvertisingDomainCount();
size_t TrackingDomainCount();
size_t FingerprintingDomainCount();
size_t SocialDomainCount();

}  // namespace rex::privacy
