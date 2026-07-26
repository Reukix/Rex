#import "RexChromiumRuntime.h"

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <crt_externs.h>

#include <atomic>
#include <algorithm>
#include <cstdio>
#include <cctype>
#include <climits>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_audio_handler.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_navigation_entry.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_ssl_info.h"
#include "include/cef_ssl_status.h"
#include "include/cef_task_manager.h"
#include "include/cef_version.h"
#include "include/cef_x509_certificate.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "RexMessagePumpPolicy.h"
#include "Privacy/RexThoriumFlags.h"
// Privacy engine types kept for shield UI policy storage only; request blocking is disabled.
#include "Privacy/RexPrivacyEngine.h"

#if !defined(ARCH_CPU_ARM64)
#error "Rex Chromium bridge supports Apple Silicon only."
#endif

namespace {

NSString *RexNSString(const CefString &value) {
  return [[NSString alloc] initWithUTF8String:value.ToString().c_str()] ?: @"";
}

NSArray<NSString *> *RexNSStringArray(const std::vector<CefString> &values) {
  NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:values.size()];
  for (const CefString &value : values) [result addObject:RexNSString(value)];
  return result;
}

NSData *RexData(CefRefPtr<CefBinaryValue> value) {
  if (!value || value->GetSize() == 0) return nil;
  const size_t size = value->GetSize();
  NSMutableData *data = [NSMutableData dataWithLength:size];
  if (value->GetData(data.mutableBytes, size, 0) != size) return nil;
  return [data copy];
}

NSString *RexHexString(CefRefPtr<CefBinaryValue> value) {
  NSData *data = RexData(value);
  if (!data.length) return @"";
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
  for (NSUInteger index = 0; index < data.length; ++index) {
    [result appendFormat:@"%02X", bytes[index]];
  }
  return result;
}

NSNumber *RexUnixSeconds(CefBaseTime value) {
  if (value.val <= 0) return nil;
  constexpr double kWindowsToUnixSeconds = 11644473600.0;
  return @((static_cast<double>(value.val) / 1000000.0) - kWindowsToUnixSeconds);
}

NSDictionary<NSString *, id> *RexPrincipalPayload(
    CefRefPtr<CefX509CertPrincipal> principal) {
  if (!principal) return @{};
  std::vector<CefString> organizations;
  std::vector<CefString> organizationalUnits;
  principal->GetOrganizationNames(organizations);
  principal->GetOrganizationUnitNames(organizationalUnits);
  return @{
    @"displayName": RexNSString(principal->GetDisplayName()),
    @"commonName": RexNSString(principal->GetCommonName()),
    @"localityName": RexNSString(principal->GetLocalityName()),
    @"stateOrProvinceName": RexNSString(principal->GetStateOrProvinceName()),
    @"countryName": RexNSString(principal->GetCountryName()),
    @"organizationNames": RexNSStringArray(organizations),
    @"organizationalUnitNames": RexNSStringArray(organizationalUnits)
  };
}

NSDictionary<NSString *, id> *RexCertificatePayload(
    CefRefPtr<CefX509Certificate> certificate) {
  if (!certificate) return @{};
  NSMutableDictionary<NSString *, id> *payload = [@{
    @"subject": RexPrincipalPayload(certificate->GetSubject()),
    @"issuer": RexPrincipalPayload(certificate->GetIssuer()),
    @"serialNumberHex": RexHexString(certificate->GetSerialNumber())
  } mutableCopy];

  if (NSNumber *validFrom = RexUnixSeconds(certificate->GetValidStart())) {
    payload[@"validFrom"] = validFrom;
  }
  if (NSNumber *validTo = RexUnixSeconds(certificate->GetValidExpiry())) {
    payload[@"validTo"] = validTo;
  }
  if (NSData *leafDER = RexData(certificate->GetDEREncoded())) {
    payload[@"leafDER"] = leafDER;
  }

  CefX509Certificate::IssuerChainBinaryList issuerChain;
  certificate->GetDEREncodedIssuerChain(issuerChain);
  NSMutableArray<NSData *> *issuerDERChain = [NSMutableArray arrayWithCapacity:issuerChain.size()];
  for (const CefRefPtr<CefBinaryValue> &entry : issuerChain) {
    if (NSData *data = RexData(entry)) [issuerDERChain addObject:data];
  }
  payload[@"issuerDERChain"] = issuerDERChain;
  return payload;
}

NSString *RexTLSVersionName(cef_ssl_version_t version) {
  switch (version) {
    case SSL_CONNECTION_VERSION_SSL2: return @"ssl2";
    case SSL_CONNECTION_VERSION_SSL3: return @"ssl3";
    case SSL_CONNECTION_VERSION_TLS1: return @"tls1";
    case SSL_CONNECTION_VERSION_TLS1_1: return @"tls1_1";
    case SSL_CONNECTION_VERSION_TLS1_2: return @"tls1_2";
    case SSL_CONNECTION_VERSION_TLS1_3: return @"tls1_3";
    case SSL_CONNECTION_VERSION_QUIC: return @"quic";
    case SSL_CONNECTION_VERSION_UNKNOWN:
    case SSL_CONNECTION_VERSION_NUM_VALUES:
      return @"unknown";
  }
}

NSString *RexUniqueDownloadPath(NSURL *directoryURL, NSString *suggestedName) {
  NSString *filename = suggestedName.lastPathComponent;
  if (!filename.length || [filename isEqualToString:@"."] ||
      [filename isEqualToString:@".."]) {
    filename = @"下载文件";
  }
  NSURL *candidate = [directoryURL URLByAppendingPathComponent:filename isDirectory:NO];
  NSFileManager *manager = NSFileManager.defaultManager;
  if (![manager fileExistsAtPath:candidate.path]) return candidate.path;

  NSString *extension = filename.pathExtension;
  NSString *stem = filename.stringByDeletingPathExtension;
  for (NSInteger suffix = 1; suffix <= 999; ++suffix) {
    NSString *numberedName = extension.length
        ? [NSString stringWithFormat:@"%@ (%ld).%@", stem, (long)suffix, extension]
        : [NSString stringWithFormat:@"%@ (%ld)", stem, (long)suffix];
    candidate = [directoryURL URLByAppendingPathComponent:numberedName isDirectory:NO];
    if (![manager fileExistsAtPath:candidate.path]) return candidate.path;
  }
  return [directoryURL URLByAppendingPathComponent:
      [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, filename]].path;
}

NSString *RexOriginForURL(const CefString &value) {
  NSString *rawValue = RexNSString(value);
  NSURLComponents *components = [NSURLComponents componentsWithString:rawValue];
  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host.lowercaseString;
  if (!scheme.length || !host.length) return rawValue;
  NSString *port = components.port ? [NSString stringWithFormat:@":%@", components.port] : @"";
  return [NSString stringWithFormat:@"%@://%@%@", scheme, host, port];
}

NSArray<NSString *> *RexMediaPermissionKinds(uint32_t permissions) {
  NSMutableArray<NSString *> *kinds = [NSMutableArray array];
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) [kinds addObject:@"microphone"];
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) [kinds addObject:@"camera"];
  if (permissions & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE |
                     CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
    [kinds addObject:@"screenCapture"];
  }
  return kinds;
}

NSArray<NSString *> *RexPermissionKinds(uint32_t permissions) {
  NSMutableArray<NSString *> *kinds = [NSMutableArray array];
  if (permissions & (CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM |
                     CEF_PERMISSION_TYPE_CAMERA_STREAM)) [kinds addObject:@"camera"];
  if (permissions & CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL) [kinds addObject:@"screenCapture"];
  if (permissions & CEF_PERMISSION_TYPE_CLIPBOARD) [kinds addObject:@"clipboard"];
  if (permissions & CEF_PERMISSION_TYPE_GEOLOCATION) [kinds addObject:@"location"];
  if (permissions & CEF_PERMISSION_TYPE_MIC_STREAM) [kinds addObject:@"microphone"];
  if (permissions & CEF_PERMISSION_TYPE_MIDI_SYSEX) [kinds addObject:@"midi"];
  if (permissions & CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS) [kinds addObject:@"automaticDownloads"];
  if (permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) [kinds addObject:@"notifications"];
  if (permissions & CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS) [kinds addObject:@"fileAccess"];
  return kinds;
}

std::string RexUTF8(NSString *value) {
  return value.UTF8String ? std::string(value.UTF8String) : std::string();
}

std::string RexDownloadKey(NSString *tabID, uint32_t downloadID) {
  return RexUTF8(tabID) + ":" + std::to_string(downloadID);
}

std::string RexLowerASCII(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
    return static_cast<char>(std::tolower(character));
  });
  return value;
}

std::string RexHostForURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return {};
  return RexLowerASCII(CefString(&parts.host).ToString());
}

bool RexHostMatches(const std::string &host, const std::string &domain) {
  if (host == domain) return true;
  return host.size() > domain.size() &&
      host.compare(host.size() - domain.size(), domain.size(), domain) == 0 &&
      host[host.size() - domain.size() - 1] == '.';
}

std::string RexRegistrableDomain(const std::string &host) {
  if (host.empty() || host == "localhost" || host.find(':') != std::string::npos) return host;
  const size_t lastDot = host.rfind('.');
  if (lastDot == std::string::npos) return host;
  const size_t secondLastDot = host.rfind('.', lastDot - 1);
  if (secondLastDot == std::string::npos) return host;

  const std::string suffix = host.substr(secondLastDot + 1);
  static const std::set<std::string> commonTwoLevelSuffixes = {
    "ac.uk", "co.jp", "co.uk", "com.au", "com.br", "com.cn", "com.sg",
    "gov.uk", "net.au", "org.au", "org.uk"
  };
  if (!commonTwoLevelSuffixes.contains(suffix)) return suffix;
  const size_t thirdLastDot = host.rfind('.', secondLastDot - 1);
  return thirdLastDot == std::string::npos ? host : host.substr(thirdLastDot + 1);
}

bool RexIsThirdPartyCookieRequest(CefRefPtr<CefRequest> request) {
  if (!request) return false;
  const std::string requestHost = RexHostForURL(request->GetURL());
  const std::string firstPartyHost = RexHostForURL(request->GetFirstPartyForCookies());
  if (requestHost.empty() || firstPartyHost.empty()) return false;
  return RexRegistrableDomain(requestHost) != RexRegistrableDomain(firstPartyHost);
}

NSDictionary<NSString *, id> *RexEvent(NSString *kind,
                                        NSString *tabID,
                                        NSDictionary<NSString *, id> *fields = @{}) {
  NSMutableDictionary<NSString *, id> *event = [fields mutableCopy];
  event[@"kind"] = kind;
  event[@"tabID"] = tabID;
  return event;
}

NSString *RexMainFrameURL(CefRefPtr<CefBrowser> browser) {
  CefRefPtr<CefFrame> frame = browser ? browser->GetMainFrame() : nullptr;
  return frame ? RexNSString(frame->GetURL()) : @"";
}

NSDictionary<NSString *, id> *RexPendingSecurityPayload(
    CefRefPtr<CefBrowser> browser,
    uint64_t navigationGeneration) {
  return @{
    @"url": RexMainFrameURL(browser),
    @"navigationGeneration": @(navigationGeneration),
    @"isPending": @YES,
    @"isSecureConnection": @NO,
    @"hasCertificateError": @NO,
    @"certificateStatus": @0,
    @"tlsVersion": @"unknown",
    @"contentStatus": @0
  };
}

NSDictionary<NSString *, id> *RexSecurityPayload(
    CefRefPtr<CefBrowser> browser,
    uint64_t navigationGeneration) {
  CefRefPtr<CefNavigationEntry> entry = browser && browser->GetHost()
      ? browser->GetHost()->GetVisibleNavigationEntry()
      : nullptr;
  CefRefPtr<CefSSLStatus> sslStatus = entry ? entry->GetSSLStatus() : nullptr;
  const cef_cert_status_t certificateStatus = sslStatus
      ? sslStatus->GetCertStatus()
      : CERT_STATUS_NONE;
  const cef_ssl_version_t sslVersion = sslStatus
      ? sslStatus->GetSSLVersion()
      : SSL_CONNECTION_VERSION_UNKNOWN;
  const cef_ssl_content_status_t contentStatus = sslStatus
      ? sslStatus->GetContentStatus()
      : SSL_CONTENT_NORMAL_CONTENT;

  NSMutableDictionary<NSString *, id> *payload = [@{
    @"url": entry ? RexNSString(entry->GetURL()) : RexMainFrameURL(browser),
    @"navigationGeneration": @(navigationGeneration),
    @"isPending": @NO,
    @"isSecureConnection": @(sslStatus && sslStatus->IsSecureConnection()),
    @"hasCertificateError": @(CefIsCertStatusError(certificateStatus)),
    @"certificateStatus": @((uint32_t)certificateStatus),
    @"tlsVersion": RexTLSVersionName(sslVersion),
    @"contentStatus": @((uint32_t)contentStatus)
  } mutableCopy];
  if (sslStatus) {
    CefRefPtr<CefX509Certificate> certificate = sslStatus->GetX509Certificate();
    if (certificate) payload[@"certificate"] = RexCertificatePayload(certificate);
  }
  return payload;
}

constexpr char kRexCookieControlsModePreference[] =
    "profile.cookie_controls_mode";
constexpr int kRexCookieControlsOff = 0;
constexpr int kRexCookieControlsBlockThirdParty = 1;
NSString *const kRexBlockThirdPartyCookiesDefaultsKey =
    @"Rex.blockThirdPartyCookies";

bool RexInitialBlockThirdPartyCookiesPreference() {
  id storedValue = [NSUserDefaults.standardUserDefaults
      objectForKey:kRexBlockThirdPartyCookiesDefaultsKey];
  return [storedValue isKindOfClass:NSNumber.class]
      ? [static_cast<NSNumber *>(storedValue) boolValue]
      : true;
}

bool RexApplyThirdPartyCookiePreference(
    CefRefPtr<CefRequestContext> context,
    bool block,
    const std::string &scope) {
  CEF_REQUIRE_UI_THREAD();
  if (!context) {
    NSLog(@"[Rex] Cookie preference unsupported for %s: request context is null",
          scope.c_str());
    return false;
  }

  const CefString preferenceName(kRexCookieControlsModePreference);
  CefRefPtr<CefValue> currentValue = context->GetPreference(preferenceName);
  if (!currentValue) {
    NSLog(@"[Rex] Cookie preference unsupported for %s: %s",
          scope.c_str(), kRexCookieControlsModePreference);
    return false;
  }
  if (currentValue->GetType() != VTYPE_INT) {
    NSLog(@"[Rex] Cookie preference has wrong type for %s: %s type=%d",
          scope.c_str(), kRexCookieControlsModePreference,
          static_cast<int>(currentValue->GetType()));
    return false;
  }
  if (!context->CanSetPreference(preferenceName)) {
    NSLog(@"[Rex] Cookie preference is not writable for %s: %s",
          scope.c_str(), kRexCookieControlsModePreference);
    return false;
  }

  const int desiredValue = block
      ? kRexCookieControlsBlockThirdParty
      : kRexCookieControlsOff;
  if (currentValue->GetInt() == desiredValue) return true;

  CefRefPtr<CefValue> value = CefValue::Create();
  if (!value || !value->SetInt(desiredValue)) {
    NSLog(@"[Rex] Failed to prepare Cookie preference for %s: %s=%d",
          scope.c_str(), kRexCookieControlsModePreference, desiredValue);
    return false;
  }

  CefString error;
  if (!context->SetPreference(preferenceName, value, error)) {
    const std::string errorText = error.ToString();
    NSLog(@"[Rex] Failed to set Cookie preference for %s: %s=%d error=%s",
          scope.c_str(), kRexCookieControlsModePreference, desiredValue,
          errorText.empty() ? "unknown" : errorText.c_str());
    return false;
  }

  NSLog(@"[Rex] Applied Cookie preference for %s: %s=%d",
        scope.c_str(), kRexCookieControlsModePreference, desiredValue);
  return true;
}

class RexRequestContextHandler final : public CefRequestContextHandler {
 public:
  RexRequestContextHandler(
      std::shared_ptr<std::atomic_bool> block_third_party_cookies,
      std::string scope)
      : block_third_party_cookies_(std::move(block_third_party_cookies)),
        scope_(std::move(scope)) {}

  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context) override {
    RexApplyThirdPartyCookiePreference(
        request_context,
        block_third_party_cookies_->load(std::memory_order_relaxed), scope_);
  }

 private:
  std::shared_ptr<std::atomic_bool> block_third_party_cookies_;
  const std::string scope_;
  IMPLEMENT_REFCOUNTING(RexRequestContextHandler);
};

class RexCEFApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit RexCEFApp(
      std::shared_ptr<std::atomic_bool> block_third_party_cookies)
      : block_third_party_cookies_(std::move(block_third_party_cookies)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnContextInitialized() override {
    RexApplyThirdPartyCookiePreference(
        CefRequestContext::GetGlobalContext(),
        block_third_party_cookies_->load(std::memory_order_relaxed), "global");
  }

  void OnBeforeCommandLineProcessing(
      const CefString &process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!command_line) return;
    // Empty process_type is the browser process.
    if (process_type.empty()) {
      rex::thorium::ApplyBrowserProcessFlags(command_line);
    } else {
      rex::thorium::ApplyChildProcessFlags(command_line);
    }
  }

  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override {
    rex::thorium::ApplyChildProcessFlags(command_line);
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    CefRefPtr<RexCEFApp> retained_self(this);
    dispatch_async(dispatch_get_main_queue(), ^{
      retained_self->HandleScheduleMessagePumpWork(delay_ms);
    });
  }

  void StartMessagePump() {
    dispatch_assert_queue(dispatch_get_main_queue());
    accepting_work_ = true;
    // Prime CEF synchronously. Waiting for the host run loop here can deadlock
    // startup because CEF needs an initial turn before it can schedule more.
    HandleScheduleMessagePumpWork(0);
  }

  void StopMessagePump() {
    dispatch_assert_queue(dispatch_get_main_queue());
    accepting_work_ = false;
    ++timer_generation_;
    [pump_timer_ invalidate];
    pump_timer_ = nil;
  }

 private:
  void HandleScheduleMessagePumpWork(int64_t delay_ms) {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (!accepting_work_) return;

    const auto decision = rex::message_pump::SelectSchedule(
        delay_ms, pump_timer_ != nil);
    if (decision.action ==
        rex::message_pump::ScheduleAction::KeepPendingTimer) {
      return;
    }

    ++timer_generation_;
    [pump_timer_ invalidate];
    pump_timer_ = nil;

    if (decision.action ==
        rex::message_pump::ScheduleAction::RunImmediately) {
      DoMessageLoopWork();
      return;
    }

    const uint64_t generation = timer_generation_;
    const NSTimeInterval delay_seconds =
        static_cast<NSTimeInterval>(decision.delay_ms) / 1000.0;
    CefRefPtr<RexCEFApp> retained_self(this);
    pump_timer_ = [NSTimer timerWithTimeInterval:delay_seconds
                                         repeats:NO
                                           block:^(NSTimer *timer) {
      [timer invalidate];
      if (!retained_self->accepting_work_ ||
          generation != retained_self->timer_generation_) {
        return;
      }
      retained_self->pump_timer_ = nil;
      retained_self->DoMessageLoopWork();
    }];
    NSRunLoop *main_run_loop = NSRunLoop.mainRunLoop;
    [main_run_loop addTimer:pump_timer_ forMode:NSRunLoopCommonModes];
    [main_run_loop addTimer:pump_timer_ forMode:NSEventTrackingRunLoopMode];
  }

  void DoMessageLoopWork() {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (!accepting_work_) return;
    if (message_loop_work_active_) {
      reentrancy_detected_ = true;
      return;
    }

    reentrancy_detected_ = false;
    message_loop_work_active_ = true;
    CefDoMessageLoopWork();
    message_loop_work_active_ = false;

    if (reentrancy_detected_) {
      OnScheduleMessagePumpWork(0);
    } else if (pump_timer_ == nil) {
      // CEF normally supplies the next deadline. This one-shot watchdog also
      // guarantees progress if startup or a platform run-loop edge drops it.
      OnScheduleMessagePumpWork(
          rex::message_pump::kFallbackDelayMarker);
    }
  }

  bool accepting_work_ = false;
  bool message_loop_work_active_ = false;
  bool reentrancy_detected_ = false;
  uint64_t timer_generation_ = 0;
  NSTimer *__strong pump_timer_ = nil;
  std::shared_ptr<std::atomic_bool> block_third_party_cookies_;
  IMPLEMENT_REFCOUNTING(RexCEFApp);
};

}  // namespace

namespace {

const void *kRexHandlingSendEventKey = &kRexHandlingSendEventKey;
using RexSendEventImplementation = void (*)(id, SEL, NSEvent *);
RexSendEventImplementation gOriginalSendEvent = nullptr;

BOOL RexIsHandlingSendEvent(id application, SEL command) {
  NSNumber *value = objc_getAssociatedObject(application, kRexHandlingSendEventKey);
  return value.boolValue;
}

void RexSetHandlingSendEvent(id application, SEL command, BOOL handling) {
  objc_setAssociatedObject(application, kRexHandlingSendEventKey, @(handling),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void RexSendEvent(id application, SEL command, NSEvent *event) {
  const NSEventModifierFlags modifiers =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  const NSEventModifierFlags commandModifiers =
      modifiers & ~NSEventModifierFlagFunction;
  if (event.type == NSEventTypeKeyDown && event.keyCode == 12 &&
      commandModifiers == NSEventModifierFlagCommand) {
    // Chromium's native responder can consume Command-Q before AppKit checks
    // the application menu. Enter Cocoa's normal two-phase termination path
    // here, outside CefScopedSendingEvent.
    [(NSApplication *)application terminate:nil];
    return;
  }
  if (event.type == NSEventTypeKeyDown && event.keyCode == 111 && commandModifiers == 0 &&
      [RexChromiumRuntime.shared handleDeveloperToolsShortcutForWindow:event.window]) {
    return;
  }
  CefScopedSendingEvent sendingEventScoper;
  if (gOriginalSendEvent) {
    gOriginalSendEvent(application, command, event);
  }
}

void RexInstallCEFApplicationHooks() {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSApplication *application = NSApplication.sharedApplication;
    Class applicationClass = object_getClass(application);
    class_addMethod(applicationClass, @selector(isHandlingSendEvent),
                    reinterpret_cast<IMP>(RexIsHandlingSendEvent), "B@:");
    class_addMethod(applicationClass, @selector(setHandlingSendEvent:),
                    reinterpret_cast<IMP>(RexSetHandlingSendEvent), "v@:B");

    Method sendEventMethod = class_getInstanceMethod(applicationClass, @selector(sendEvent:));
    if (!sendEventMethod) return;
    gOriginalSendEvent = reinterpret_cast<RexSendEventImplementation>(
        method_getImplementation(sendEventMethod));
    class_replaceMethod(applicationClass, @selector(sendEvent:),
                        reinterpret_cast<IMP>(RexSendEvent),
                        method_getTypeEncoding(sendEventMethod));
  });
}

}  // namespace

@class RexChromiumRuntime;

namespace {

enum class RexDevToolsFrontendAction {
  Console,
  Inspect,
};

class RexBrowserClient final : public CefClient,
                               public CefAudioHandler,
                               public CefCookieAccessFilter,
                               public CefContextMenuHandler,
                               public CefDisplayHandler,
                               public CefDownloadHandler,
                               public CefLoadHandler,
                               public CefLifeSpanHandler,
                               public CefPermissionHandler,
                               public CefRequestHandler,
                               public CefResourceRequestHandler {
 public:
  RexBrowserClient(__weak RexChromiumRuntime *runtime, NSString *tabID)
      : runtime_(runtime), tab_id_([tabID copy]) {}

  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString &request_initiator,
      bool &disable_default_handling) override {
    return this;
  }
  CefRefPtr<CefCookieAccessFilter> GetCookieAccessFilter(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) override {
    return this;
  }

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override;
  bool CanSendCookie(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     CefRefPtr<CefRequest> request,
                     const CefCookie &cookie) override;
  bool CanSaveCookie(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     CefRefPtr<CefRequest> request,
                     CefRefPtr<CefResponse> response,
                     const CefCookie &cookie) override;

  void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser,
                             CefWindowInfo &window_info,
                             CefRefPtr<CefClient> &client,
                             CefBrowserSettings &settings,
                             CefRefPtr<CefDictionaryValue> &extra_info,
                             bool *use_default_window) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString &target_url,
                     const CefString &target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures &popup_features,
                     CefWindowInfo &window_info,
                     CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      cef_permission_request_result_t result) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString &request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;
  bool RunContextMenu(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override;
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override;

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;
  void OnFaviconURLChange(
      CefRefPtr<CefBrowser> browser,
      const std::vector<CefString> &icon_urls) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                               double progress) override;
  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                           bool has_video_access,
                           bool has_audio_access) override;

  void OnAudioStreamStarted(CefRefPtr<CefBrowser> browser,
                            const CefAudioParameters &params,
                            int channels) override;
  void OnAudioStreamPacket(CefRefPtr<CefBrowser> browser,
                           const float **data,
                           int frames,
                           int64_t pts) override;
  void OnAudioStreamStopped(CefRefPtr<CefBrowser> browser) override;
  void OnAudioStreamError(CefRefPtr<CefBrowser> browser,
                          const CefString &message) override;

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool is_loading,
                            bool can_go_back,
                            bool can_go_forward) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString &suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode error_code,
                   const CefString &error_text,
                   const CefString &failed_url) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString &error_string) override;

 private:
  void Emit(NSString *kind, NSDictionary<NSString *, id> *fields = @{});
  void EmitBlockedResource(NSString *category, const std::string &host);
  void EmitMediaAccess(bool has_video_access, bool has_audio_access);
  void EmitSecuritySnapshot(CefRefPtr<CefBrowser> browser);

  __weak RexChromiumRuntime *runtime_;
  NSString *tab_id_;
  uint64_t navigation_generation_ = 0;
  bool has_video_access_ = false;
  bool has_audio_access_ = false;
  IMPLEMENT_REFCOUNTING(RexBrowserClient);
};

class RexDevToolsClient final : public CefClient,
                                public CefLifeSpanHandler,
                                public CefLoadHandler {
 public:
  RexDevToolsClient(__weak RexChromiumRuntime *runtime,
                    NSString *tabID,
                    bool tracks_opening = false)
      : runtime_(runtime),
        tab_id_([tabID copy]),
        tracks_opening_(tracks_opening) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int http_status_code) override;

 private:
  ~RexDevToolsClient() override;

  __weak RexChromiumRuntime *runtime_;
  NSString *tab_id_;
  const bool tracks_opening_;
  bool browser_created_ = false;
  IMPLEMENT_REFCOUNTING(RexDevToolsClient);
};

}  // namespace

@interface RexChromiumRuntime ()
- (rex::privacy::ProtectionPolicy)privacyPolicyForTabID:(NSString *)tabID
                                               browser:(CefRefPtr<CefBrowser>)browser;
- (void)createBrowserInView:(RexChromiumBrowserView *)view
                       tabID:(NSString *)tabID
                  initialURL:(NSString *)initialURL
                   profileID:(NSString *)profileID
             privateBrowsing:(BOOL)privateBrowsing;
- (void)registerBrowser:(CefRefPtr<CefBrowser>)browser tabID:(NSString *)tabID;
- (void)forceBrowserRepaintForTabID:(NSString *)tabID;
- (void)registerDeveloperToolsBrowser:(CefRefPtr<CefBrowser>)browser
                                tabID:(NSString *)tabID;
- (void)syncNativeBrowserView:(NSView *)nativeView
                   toHostView:(NSView *)hostView
                      browser:(CefRefPtr<CefBrowser>)browser;
- (void)syncNativeBrowserView:(NSView *)nativeView
                   toHostView:(NSView *)hostView
                      browser:(CefRefPtr<CefBrowser>)browser
                  popupWindow:(nullable NSWindow *)popupWindow;
- (void)parkDeveloperToolsPopupWindow:(nullable NSWindow *)popupWindow
                             hostView:(nullable NSView *)hostView;
- (void)developerToolsPopupDidBecomeKey:(NSNotification *)notification;
- (void)developerToolsFrontendWillLoad:(CefRefPtr<CefBrowser>)browser
                                 tabID:(NSString *)tabID;
- (void)developerToolsFrontendDidLoad:(CefRefPtr<CefBrowser>)browser
                                tabID:(NSString *)tabID;
- (void)queueDeveloperToolsFrontendAction:(RexDevToolsFrontendAction)action
                                    tabID:(NSString *)tabID;
- (void)applyPendingDeveloperToolsFrontendActionForTabID:(NSString *)tabID
                                                  browser:(CefRefPtr<CefBrowser>)browser;
- (void)developerToolsViewDidMoveToWindowForTabID:(NSString *)tabID;
- (void)developerToolsCreationAbortedForTabID:(NSString *)tabID;
- (void)developerToolsBrowser:(CefRefPtr<CefBrowser>)browser
        didCloseForTabID:(NSString *)tabID;
- (void)browserDidCloseForTabID:(NSString *)tabID;
- (void)finishTerminationIfReady;
- (void)emitEvent:(NSDictionary<NSString *, id> *)event;
- (void)registerMediaPermissionRequestID:(NSString *)requestID
                                    tabID:(NSString *)tabID
                     requestedPermissions:(uint32_t)requestedPermissions
                                 callback:(CefRefPtr<CefMediaAccessCallback>)callback;
- (void)registerPermissionPromptID:(uint64_t)promptID
                          requestID:(NSString *)requestID
                              tabID:(NSString *)tabID
               requestedPermissions:(uint32_t)requestedPermissions
                           callback:(CefRefPtr<CefPermissionPromptCallback>)callback;
- (void)dismissPermissionPromptID:(uint64_t)promptID;
- (void)cancelPermissionRequestsForTabID:(NSString *)tabID;
- (void)releaseProfileForTabID:(NSString *)tabID;
- (nullable NSURL *)downloadDirectoryForTabID:(NSString *)tabID;
- (void)registerDownloadCallback:(CefRefPtr<CefDownloadItemCallback>)callback
                      downloadID:(uint32_t)downloadID
                           tabID:(NSString *)tabID;
- (void)removeDownloadCallbackID:(uint32_t)downloadID tabID:(NSString *)tabID;
- (void)removeDownloadCallbacksForTabID:(NSString *)tabID;
@end

class RexFaviconDownloadCallback final : public CefDownloadImageCallback {
 public:
  RexFaviconDownloadCallback(__weak RexChromiumRuntime *runtime,
                             NSString *tabID)
      : runtime_(runtime), tab_id_([tabID copy]) {}

  void OnDownloadImageFinished(const CefString &image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    RexChromiumRuntime *runtime = runtime_;
    if (!runtime) return;
    NSString *url = RexNSString(image_url);
    NSMutableDictionary<NSString *, id> *fields = [@{ @"url": url } mutableCopy];
    if (http_status_code >= 200 && http_status_code < 400 && image) {
      int pixelWidth = 0;
      int pixelHeight = 0;
      CefRefPtr<CefBinaryValue> png = image->GetAsPNG(
          1.0f, true, pixelWidth, pixelHeight);
      const size_t size = png ? png->GetSize() : 0;
      if (png && size > 0 && size <= 256 * 1024) {
        NSMutableData *data = [NSMutableData dataWithLength:size];
        if (png->GetData(data.mutableBytes, size, 0) == size) {
          fields[@"imageData"] = data;
        }
      }
    }
    [runtime emitEvent:RexEvent(@"favicon", tab_id_, fields)];
  }

 private:
  __weak RexChromiumRuntime *runtime_;
  NSString *tab_id_;
  IMPLEMENT_REFCOUNTING(RexFaviconDownloadCallback);
};

@implementation RexChromiumBrowserView

@synthesize tabID = _tabID;
@synthesize profileID = _profileID;
@synthesize privateBrowsing = _privateBrowsing;

- (instancetype)initWithTabID:(NSString *)tabID
                    initialURL:(NSString *)initialURL
                     profileID:(NSString *)profileID
               privateBrowsing:(BOOL)privateBrowsing {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _tabID = [tabID copy];
    _profileID = [profileID copy];
    _privateBrowsing = privateBrowsing;
    objc_setAssociatedObject(self, @selector(initWithTabID:initialURL:),
                             [initialURL copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    // Keep the browser host non-layer-backed. A CALayer-backed host under
    // SwiftUI can blank large CEF compositor tiles on macOS arm64.
    self.wantsLayer = NO;
    self.autoresizesSubviews = YES;
  }
  return self;
}

- (void)layout {
  [super layout];
  for (NSView *subview in self.subviews) {
    if (!NSEqualRects(subview.frame, self.bounds)) {
      subview.frame = self.bounds;
    }
    subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  [RexChromiumRuntime.shared notifyHostViewDidLayout:self tabID:self.tabID];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    NSString *initialURL = objc_getAssociatedObject(self, @selector(initWithTabID:initialURL:)) ?: @"about:blank";
    [RexChromiumRuntime.shared createBrowserInView:self
                                             tabID:self.tabID
                                        initialURL:initialURL
                                         profileID:self.profileID
                                   privateBrowsing:self.isPrivateBrowsing];
    [RexChromiumRuntime.shared setFocused:YES tabID:self.tabID];
  }
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [RexChromiumRuntime.shared notifyHostViewDidLayout:self tabID:self.tabID];
}

- (void)dealloc {
}

@end

@implementation RexChromiumDevToolsView

@synthesize tabID = _tabID;

- (instancetype)initWithTabID:(NSString *)tabID {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _tabID = [tabID copy];
    // Match the page host: CEF owns the native compositor surface, while
    // SwiftUI paints the glass background and rounded-corner overlay.
    self.wantsLayer = NO;
    self.autoresizesSubviews = YES;
    // Avoid NSViewFrameDidChangeNotification feedback loops with CEF resize.
    self.postsFrameChangedNotifications = NO;
  }
  return self;
}

- (void)layout {
  [super layout];
  for (NSView *subview in self.subviews) {
    // Keep CEF child views pinned with autoresizing during drag; avoid
    // repeated frame reassignment unless they are not yet sized.
    if (!NSEqualRects(subview.frame, self.bounds)) {
      subview.frame = self.bounds;
    }
    subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  [RexChromiumRuntime.shared notifyDeveloperToolsHostDidLayoutForTabID:self.tabID];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    [RexChromiumRuntime.shared developerToolsViewDidMoveToWindowForTabID:self.tabID];
    [RexChromiumRuntime.shared notifyDeveloperToolsHostDidLayoutForTabID:self.tabID];
  }
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [RexChromiumRuntime.shared notifyDeveloperToolsHostDidLayoutForTabID:self.tabID];
}

- (void)dealloc {
}

@end

struct RexPendingPermission {
  std::string tab_id;
  uint32_t requested_permissions = 0;
  uint64_t prompt_id = 0;
  CefRefPtr<CefMediaAccessCallback> media_callback;
  CefRefPtr<CefPermissionPromptCallback> prompt_callback;
};

@implementation RexChromiumRuntime {
  BOOL _ready;
  BOOL _shuttingDown;
  BOOL _layoutSyncSuspended;
  std::unique_ptr<CefScopedLibraryLoader> _libraryLoader;
  CefRefPtr<RexCEFApp> _application;
  CefRefPtr<CefTaskManager> _taskManager;
  std::shared_ptr<std::atomic_bool> _blockThirdPartyCookiesPreference;
  std::map<std::string, CefRefPtr<CefBrowser>> _browsers;
  std::map<std::string, CefRefPtr<CefBrowser>> _developerToolsBrowsers;
  std::map<std::string, int> _developerToolsFrontendReadyBrowserIDs;
  std::set<std::string> _developerToolsDesiredTabs;
  std::set<std::string> _developerToolsOpeningTabs;
  std::set<std::string> _developerToolsClosingTabs;
  std::map<std::string, std::pair<NSInteger, NSInteger>>
      _pendingDeveloperToolsRequests;
  std::map<std::string, RexDevToolsFrontendAction>
      _pendingDeveloperToolsFrontendActions;
  std::set<std::string> _pendingTabs;
  NSMutableDictionary<NSString *, NSString *> *_pendingURLs;
  NSMutableDictionary<NSString *, RexChromiumBrowserView *> *_views;
  NSMutableDictionary<NSString *, RexChromiumDevToolsView *> *_developerToolsViews;
  NSMutableDictionary<NSNumber *, NSWindow *> *_developerToolsPopupWindowsByBrowserID;
  NSMutableDictionary<NSNumber *, NSView *> *_developerToolsNativeViewsByBrowserID;
  NSMutableDictionary<NSString *, NSString *> *_tabProfileIDs;
  NSMutableDictionary<NSString *, NSNumber *> *_privateTabs;
  NSMutableDictionary<NSString *, NSNumber *> *_mutedTabs;
  // Per-tab Brave-style shield policy (enabled/mode/fingerprint/cookies).
  NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *_privacyPolicies;
  NSMutableDictionary<NSString *, NSURL *> *_downloadDirectories;
  std::map<std::string, CefRefPtr<CefRequestContext>> _requestContexts;
  std::map<std::string, CefRefPtr<CefDownloadItemCallback>> _downloadCallbacks;
  std::map<std::string, RexPendingPermission> _pendingPermissions;
  std::map<uint64_t, std::string> _permissionRequestIDsByPrompt;
  void (^_terminationCompletion)(void);
}

+ (RexChromiumRuntime *)shared {
  static RexChromiumRuntime *runtime;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ runtime = [[RexChromiumRuntime alloc] init]; });
  return runtime;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _layoutSyncSuspended = NO;
    _blockThirdPartyCookiesPreference = std::make_shared<std::atomic_bool>(
        RexInitialBlockThirdPartyCookiesPreference());
    _pendingURLs = [[NSMutableDictionary alloc] init];
    _views = [[NSMutableDictionary alloc] init];
    _developerToolsViews = [[NSMutableDictionary alloc] init];
    _developerToolsPopupWindowsByBrowserID = [[NSMutableDictionary alloc] init];
    _developerToolsNativeViewsByBrowserID = [[NSMutableDictionary alloc] init];
    _tabProfileIDs = [[NSMutableDictionary alloc] init];
    _privateTabs = [[NSMutableDictionary alloc] init];
    _mutedTabs = [[NSMutableDictionary alloc] init];
    _privacyPolicies = [[NSMutableDictionary alloc] init];
    _downloadDirectories = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (BOOL)isReady { return _ready; }
- (NSString *)cefVersion { return @CEF_VERSION; }
- (NSString *)chromiumVersion {
  return [NSString stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR,
          CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
}

- (void)beginTabTaskMetricsMonitoring {
  NSAssert(NSThread.isMainThread,
           @"CEF task metrics must be managed on the main thread");
  if (_ready && !_shuttingDown && !_taskManager) {
    _taskManager = CefTaskManager::GetTaskManager();
  }
}

- (void)endTabTaskMetricsMonitoring {
  NSAssert(NSThread.isMainThread,
           @"CEF task metrics must be managed on the main thread");
  _taskManager = nullptr;
}

- (NSArray<NSDictionary<NSString *, id> *> *)tabTaskMetricsSnapshot {
  NSAssert(NSThread.isMainThread,
           @"CEF task metrics must be collected on the main thread");
  if (!_ready || _shuttingDown) return @[];

  if (!_taskManager) [self beginTabTaskMetricsMonitoring];
  if (!_taskManager) return @[];

  NSMutableArray<NSDictionary<NSString *, id> *> *snapshot =
      [NSMutableArray arrayWithCapacity:_browsers.size()];
  for (const auto &entry : _browsers) {
    CefRefPtr<CefBrowser> browser = entry.second;
    if (!browser || !browser->IsValid()) continue;

    const int browserID = browser->GetIdentifier();
    const int64_t taskID = _taskManager->GetTaskIdForBrowserId(browserID);
    if (taskID < 0) continue;

    CefTaskInfo info;
    if (!_taskManager->GetTaskInfo(taskID, info)) continue;

    NSString *tabID = [[NSString alloc] initWithUTF8String:entry.first.c_str()] ?: @"";
    CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
    NSMutableDictionary<NSString *, id> *metrics = [@{
      @"tabID": tabID,
      @"browserID": @(browserID),
      @"taskID": @(taskID),
      @"taskTitle": RexNSString(CefString(&info.title)),
      @"url": mainFrame ? RexNSString(mainFrame->GetURL()) : @"",
      @"cpuPercent": @(info.cpu_usage),
      @"memoryBytes": info.memory > 0 ? @(info.memory) : NSNull.null
    } mutableCopy];
    [snapshot addObject:metrics];
  }
  return [snapshot copy];
}

- (BOOL)startWithCacheRoot:(NSURL *)cacheRoot
                    locale:(NSString *)locale
                     error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"CEF must initialize on the main thread");
  if (_ready) return YES;

  RexInstallCEFApplicationHooks();

  _libraryLoader = std::make_unique<CefScopedLibraryLoader>();
  if (!_libraryLoader->LoadInMain()) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.rex.browser.chromium"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey:
                                            @"无法从 Rex.app/Contents/Frameworks 加载 CEF"}];
    }
    _libraryLoader.reset();
    return NO;
  }

  int argc = *_NSGetArgc();
  char **argv = *_NSGetArgv();
  std::vector<char *> cefArgv(argv, argv + argc);
  static char noProxySwitch[] = "--no-proxy-server";
  if (std::find_if(cefArgv.begin(), cefArgv.end(), [](char *argument) {
        return argument && std::string(argument) == "--no-proxy-server";
      }) == cefArgv.end()) {
    cefArgv.push_back(noProxySwitch);
  }
  CefMainArgs mainArgs(static_cast<int>(cefArgv.size()), cefArgv.data());
  CefSettings settings;
  settings.external_message_pump = true;
  settings.no_sandbox = false;
  settings.persist_session_cookies = true;
  settings.log_severity = LOGSEVERITY_WARNING;
  settings.background_color = CefColorSetARGB(255, 245, 245, 247);

  NSString *rootPath = cacheRoot.path;
  NSString *profilePath = [rootPath stringByAppendingPathComponent:@"Default"];
  CefString(&settings.root_cache_path) = RexUTF8(rootPath);
  CefString(&settings.cache_path) = RexUTF8(profilePath);
  CefString(&settings.locale) = RexUTF8(locale.length ? locale : @"zh-CN");
  CefString(&settings.user_agent_product) = "Rex/0.8.1";

  _application = new RexCEFApp(_blockThirdPartyCookiesPreference);
  if (!CefInitialize(mainArgs, settings, _application, nullptr)) {
    const int exitCode = CefGetExitCode();
    if (error) {
      *error = [NSError errorWithDomain:@"com.rex.browser.chromium"
                                   code:exitCode
                               userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"CEF 初始化失败（%d）", exitCode]}];
    }
    _application = nullptr;
    _libraryLoader.reset();
    return NO;
  }

  _ready = YES;
  NSLog(@"[Rex] performance layer=%s · content filter=host-catalogs (toggleable)",
        rex::thorium::ProfileName());
  _application->StartMessagePump();
  [self emitEvent:@{ @"kind": @"runtimeReady",
                     @"tabID": @"",
                     @"cefVersion": self.cefVersion,
                     @"chromiumVersion": self.chromiumVersion }];
  return YES;
}

- (void)createBrowserInView:(RexChromiumBrowserView *)view
                       tabID:(NSString *)tabID
                  initialURL:(NSString *)initialURL
                   profileID:(NSString *)profileID
             privateBrowsing:(BOOL)privateBrowsing {
  dispatch_async(dispatch_get_main_queue(), ^{
    const std::string key = RexUTF8(tabID);
    if (!self->_ready || self->_shuttingDown || self->_browsers.contains(key) ||
        self->_pendingTabs.contains(key)) return;
    self->_pendingTabs.insert(key);

    CefWindowInfo windowInfo;
    const NSRect bounds = view.bounds;
    windowInfo.SetAsChild((__bridge CefWindowHandle)view,
                          CefRect(0, 0, std::max(1, (int)bounds.size.width),
                                  std::max(1, (int)bounds.size.height)));
    CefBrowserSettings browserSettings;
    browserSettings.background_color = CefColorSetARGB(255, 255, 255, 255);
    CefRefPtr<RexBrowserClient> client = new RexBrowserClient(self, tabID);
    CefRefPtr<CefRequestContext> requestContext = CefRequestContext::GetGlobalContext();
    if (privateBrowsing) {
      const std::string profileKey = RexUTF8(profileID);
      auto context = self->_requestContexts.find(profileKey);
      if (context == self->_requestContexts.end()) {
        CefRequestContextSettings contextSettings;
        contextSettings.persist_session_cookies = false;
        CefRefPtr<CefRequestContextHandler> contextHandler =
            new RexRequestContextHandler(
                self->_blockThirdPartyCookiesPreference,
                "private:" + profileKey);
        requestContext = CefRequestContext::CreateContext(contextSettings,
                                                          contextHandler);
        self->_requestContexts[profileKey] = requestContext;
      } else {
        requestContext = context->second;
      }
    }
    const std::string url = initialURL.length ? RexUTF8(initialURL) : "about:blank";
    CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
        windowInfo, client, url, browserSettings, nullptr, requestContext);
    if (!browser) {
      self->_pendingTabs.erase(key);
      [self emitEvent:RexEvent(@"error", tabID,
                               @{ @"message": @"CEF 页面实例创建失败" })];
    }
  });
}

- (RexChromiumBrowserView *)browserViewForTabID:(NSString *)tabID
                                      initialURL:(NSString *)initialURL
                                       profileID:(NSString *)profileID
                                 privateBrowsing:(BOOL)privateBrowsing {
  NSAssert(NSThread.isMainThread, @"CEF browser views are main-thread only");
  [self configureTabID:tabID profileID:profileID privateBrowsing:privateBrowsing];
  RexChromiumBrowserView *view = _views[tabID];
  if (!view) {
    view = [[RexChromiumBrowserView alloc] initWithTabID:tabID
                                             initialURL:initialURL
                                              profileID:profileID
                                        privateBrowsing:privateBrowsing];
    _views[tabID] = view;
  }
  return view;
}

- (RexChromiumDevToolsView *)developerToolsViewForTabID:(NSString *)tabID {
  NSAssert(NSThread.isMainThread, @"CEF developer tools views are main-thread only");
  RexChromiumDevToolsView *view = _developerToolsViews[tabID];
  if (!view) {
    view = [[RexChromiumDevToolsView alloc] initWithTabID:tabID];
    _developerToolsViews[tabID] = view;
  }
  return view;
}

- (void)parkDeveloperToolsPopupWindow:(nullable NSWindow *)popupWindow
                             hostView:(nullable NSView *)hostView {
  if (!popupWindow || popupWindow == hostView.window) return;
  const NSRect hostBounds = hostView ? hostView.bounds : NSZeroRect;
  const CGFloat width = std::max<CGFloat>(1, NSWidth(hostBounds));
  const CGFloat height = std::max<CGFloat>(1, NSHeight(hostBounds));
  NSPoint parkedOrigin = NSScreen.mainScreen.visibleFrame.origin;
  NSWindow *hostWindow = hostView.window;
  if (hostWindow) {
    const NSRect hostRectInWindow =
        [hostView convertRect:hostBounds toView:nil];
    parkedOrigin = [hostWindow convertRectToScreen:hostRectInWindow].origin;
  }
  const NSRect parkedFrame = NSMakeRect(
      floor(parkedOrigin.x), floor(parkedOrigin.y), width, height);
  popupWindow.styleMask = NSWindowStyleMaskBorderless;
  popupWindow.alphaValue = 0.01;
  popupWindow.ignoresMouseEvents = YES;
  popupWindow.hasShadow = NO;
  popupWindow.excludedFromWindowsMenu = YES;
  if (!NSEqualRects(popupWindow.frame, parkedFrame)) {
    [popupWindow setFrame:parkedFrame display:NO];
  }
  // The Chrome runtime uses this top-level window's visibility to decide
  // whether WebContentsViewCocoa accepts input. Keep it technically visible
  // directly behind Rex, where it cannot flash or introduce invalid off-screen
  // geometry for ScreenCaptureKit and accessibility clients.
  if (hostWindow) {
    [popupWindow orderWindow:NSWindowBelow relativeTo:hostWindow.windowNumber];
  } else if (!popupWindow.isVisible) {
    [popupWindow orderFront:nil];
  }
}

- (void)developerToolsPopupDidBecomeKey:(NSNotification *)notification {
  NSWindow *popupWindow = (NSWindow *)notification.object;
  if (!popupWindow || _shuttingDown) return;

  // Some frontend actions (notably completing element inspection) ask the
  // original Chrome host to become key again. Let that activation unwind, then
  // restore the embedded Rex window before AppKit exposes the empty placeholder.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_shuttingDown) return;
    NSNumber *browserID = nil;
    for (NSNumber *candidate in self->_developerToolsPopupWindowsByBrowserID) {
      if (self->_developerToolsPopupWindowsByBrowserID[candidate] == popupWindow) {
        browserID = candidate;
        break;
      }
    }
    if (!browserID) return;

    CefRefPtr<CefBrowser> browser;
    NSString *tabID = nil;
    for (const auto &entry : self->_developerToolsBrowsers) {
      if (entry.second && entry.second->GetIdentifier() == browserID.intValue) {
        browser = entry.second;
        tabID = [[NSString alloc] initWithUTF8String:entry.first.c_str()];
        break;
      }
    }
    RexChromiumDevToolsView *hostView = tabID
        ? self->_developerToolsViews[tabID]
        : nil;
    if (!browser || !browser->IsValid() || !hostView.window) return;
    [self parkDeveloperToolsPopupWindow:popupWindow hostView:hostView];
    [hostView.window makeKeyAndOrderFront:nil];
    browser->GetHost()->SetFocus(true);
  });
}

- (void)registerDeveloperToolsBrowser:(CefRefPtr<CefBrowser>)browser
                                tabID:(NSString *)tabID {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;

  const std::string key = RexUTF8(tabID);
  NSNumber *browserID = @(browser->GetIdentifier());
  _developerToolsOpeningTabs.erase(key);
  _developerToolsFrontendReadyBrowserIDs.erase(key);
  _developerToolsBrowsers[key] = browser;

  RexChromiumDevToolsView *parentView = _developerToolsViews[tabID];
  NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  NSWindow *popupWindow = nativeView.window;
  if (popupWindow && popupWindow != parentView.window) {
    _developerToolsPopupWindowsByBrowserID[browserID] = popupWindow;
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(developerToolsPopupDidBecomeKey:)
               name:NSWindowDidBecomeKeyNotification
             object:popupWindow];
    [self parkDeveloperToolsPopupWindow:popupWindow hostView:parentView];
  }
  if (_shuttingDown || !_developerToolsDesiredTabs.contains(key) ||
      _developerToolsClosingTabs.contains(key) || !parentView ||
      !parentView.window || !parentView.superview || !nativeView) {
    _developerToolsClosingTabs.insert(key);
    browser->GetHost()->CloseBrowser(true);
    return;
  }

  [self syncNativeBrowserView:nativeView
                   toHostView:parentView
                      browser:browser
                  popupWindow:popupWindow];
  [self parkDeveloperToolsPopupWindow:popupWindow hostView:parentView];
  [parentView.window makeKeyAndOrderFront:nil];
  browser->GetHost()->SetFocus(true);
  [parentView setNeedsLayout:YES];
  [parentView layoutSubtreeIfNeeded];

  auto pending = _pendingDeveloperToolsRequests.find(key);
  if (pending != _pendingDeveloperToolsRequests.end()) {
    const NSInteger inspectX = pending->second.first;
    const NSInteger inspectY = pending->second.second;
    _pendingDeveloperToolsRequests.erase(pending);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_developerToolsDesiredTabs.contains(key)) return;
      [self showDeveloperToolsForTabID:tabID inspectX:inspectX inspectY:inspectY];
    });
  }

  NSString *tabCopy = [tabID copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    CefRefPtr<CefBrowser> live = [self developerToolsBrowserForTabID:tabCopy];
    RexChromiumDevToolsView *host = self->_developerToolsViews[tabCopy];
    if (!live || !live->IsValid() || !live->IsSame(browser) || !host ||
        !host.window || !host.superview) {
      return;
    }
    NSView *attached = (__bridge NSView *)live->GetHost()->GetWindowHandle();
    NSWindow *retainedPopup =
        self->_developerToolsPopupWindowsByBrowserID[@(live->GetIdentifier())];
    [self syncNativeBrowserView:attached
                     toHostView:host
                        browser:live
                    popupWindow:retainedPopup];
    [self parkDeveloperToolsPopupWindow:retainedPopup hostView:host];
    [host.window makeKeyAndOrderFront:nil];
    live->GetHost()->SetFocus(true);
    if (!live->IsLoading()) {
      [self developerToolsFrontendDidLoad:live tabID:tabCopy];
    }
  });
}

- (void)developerToolsFrontendDidLoad:(CefRefPtr<CefBrowser>)browser
                                tabID:(NSString *)tabID {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  const std::string key = RexUTF8(tabID);
  CefRefPtr<CefBrowser> current = [self developerToolsBrowserForTabID:tabID];
  if (!current || !current->IsSame(browser) ||
      _developerToolsClosingTabs.contains(key)) {
    return;
  }
  _developerToolsFrontendReadyBrowserIDs[key] = browser->GetIdentifier();
  // Chrome may reposition its temporary native DevTools window after
  // OnAfterCreated. Park it again once the frontend is ready and keep keyboard
  // focus on the embedded host.
  NSWindow *popupWindow =
      _developerToolsPopupWindowsByBrowserID[@(browser->GetIdentifier())];
  RexChromiumDevToolsView *hostView = _developerToolsViews[tabID];
  [self parkDeveloperToolsPopupWindow:popupWindow hostView:hostView];
  if (hostView.window) {
    [hostView.window makeKeyAndOrderFront:nil];
    browser->GetHost()->SetFocus(true);
  }
  [self applyPendingDeveloperToolsFrontendActionForTabID:tabID browser:browser];
}

- (void)developerToolsFrontendWillLoad:(CefRefPtr<CefBrowser>)browser
                                 tabID:(NSString *)tabID {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  const std::string key = RexUTF8(tabID);
  CefRefPtr<CefBrowser> current = [self developerToolsBrowserForTabID:tabID];
  if (!current || !current->IsSame(browser)) return;
  auto ready = _developerToolsFrontendReadyBrowserIDs.find(key);
  if (ready != _developerToolsFrontendReadyBrowserIDs.end() &&
      ready->second == browser->GetIdentifier()) {
    _developerToolsFrontendReadyBrowserIDs.erase(ready);
  }
}

- (void)applyPendingDeveloperToolsFrontendActionForTabID:(NSString *)tabID
                                                  browser:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || _shuttingDown) return;

  const std::string key = RexUTF8(tabID);
  if (!_developerToolsDesiredTabs.contains(key) ||
      _developerToolsClosingTabs.contains(key)) {
    return;
  }
  auto pending = _pendingDeveloperToolsFrontendActions.find(key);
  if (pending == _pendingDeveloperToolsFrontendActions.end()) return;
  CefRefPtr<CefBrowser> current = [self developerToolsBrowserForTabID:tabID];
  if (!current || !current->IsSame(browser)) return;
  auto ready = _developerToolsFrontendReadyBrowserIDs.find(key);
  if (ready == _developerToolsFrontendReadyBrowserIDs.end() ||
      ready->second != browser->GetIdentifier()) {
    return;
  }

  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  if (!frame) return;
  const bool inspect = pending->second == RexDevToolsFrontendAction::Inspect;
  std::string script =
      "(() => { let remaining = 100; const activate = () => { "
      "const api = globalThis.DevToolsAPI || globalThis.InspectorFrontendAPI; ";
  if (inspect) {
    script +=
        "if (api && typeof api.enterInspectElementMode === 'function') { "
        "if (typeof api.showPanel === 'function') api.showPanel('elements'); "
        "api.enterInspectElementMode(); return; } ";
  } else {
    script +=
        "if (api && typeof api.showPanel === 'function') { "
        "api.showPanel('console'); return; } ";
  }
  script +=
      "if (--remaining > 0) globalThis.setTimeout(activate, 50); "
      "}; activate(); })();";
  frame->ExecuteJavaScript(script, frame->GetURL(), 0);
  browser->GetHost()->SetFocus(true);
  _pendingDeveloperToolsFrontendActions.erase(pending);
}

- (void)queueDeveloperToolsFrontendAction:(RexDevToolsFrontendAction)action
                                    tabID:(NSString *)tabID {
  [self onMain:^{
    if (self->_shuttingDown || ![self browserForTabID:tabID]) return;
    const std::string key = RexUTF8(tabID);
    self->_pendingDeveloperToolsFrontendActions[key] = action;

    [self showDeveloperToolsForTabID:tabID];
    CefRefPtr<CefBrowser> tools = [self developerToolsBrowserForTabID:tabID];
    if (tools) {
      [self applyPendingDeveloperToolsFrontendActionForTabID:tabID browser:tools];
    }
  }];
}

- (void)developerToolsViewDidMoveToWindowForTabID:(NSString *)tabID {
  [self onMain:^{
    const std::string key = RexUTF8(tabID);
    if (self->_shuttingDown || !self->_developerToolsDesiredTabs.contains(key) ||
        self->_developerToolsOpeningTabs.contains(key) ||
        self->_developerToolsClosingTabs.contains(key)) {
      return;
    }
    auto pending = self->_pendingDeveloperToolsRequests.find(key);
    const NSInteger inspectX = pending == self->_pendingDeveloperToolsRequests.end()
        ? -1 : pending->second.first;
    const NSInteger inspectY = pending == self->_pendingDeveloperToolsRequests.end()
        ? -1 : pending->second.second;
    [self showDeveloperToolsForTabID:tabID inspectX:inspectX inspectY:inspectY];
  }];
}

- (void)developerToolsCreationAbortedForTabID:(NSString *)tabID {
  NSAssert(NSThread.isMainThread, @"CEF developer tools state is main-thread only");
  const std::string key = RexUTF8(tabID);
  if (!_developerToolsOpeningTabs.contains(key)) return;

  const bool hostInitiatedClose = _developerToolsClosingTabs.contains(key);
  const bool reopenRequested =
      hostInitiatedClose && _developerToolsDesiredTabs.contains(key);
  _developerToolsOpeningTabs.erase(key);
  _developerToolsClosingTabs.erase(key);
  _developerToolsFrontendReadyBrowserIDs.erase(key);

  if (_shuttingDown) {
    _developerToolsDesiredTabs.erase(key);
    _pendingDeveloperToolsRequests.erase(key);
    _pendingDeveloperToolsFrontendActions.erase(key);
    [self finishTerminationIfReady];
    return;
  }

  if (!hostInitiatedClose && _developerToolsDesiredTabs.contains(key)) {
    _developerToolsDesiredTabs.erase(key);
    _pendingDeveloperToolsRequests.erase(key);
    _pendingDeveloperToolsFrontendActions.erase(key);
    [self emitEvent:RexEvent(@"developerToolsRequested", tabID,
                             @{ @"inspectX": @(-1), @"inspectY": @(-1) })];
  } else if (reopenRequested) {
    auto pending = _pendingDeveloperToolsRequests.find(key);
    const NSInteger inspectX = pending == _pendingDeveloperToolsRequests.end()
        ? -1 : pending->second.first;
    const NSInteger inspectY = pending == _pendingDeveloperToolsRequests.end()
        ? -1 : pending->second.second;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_developerToolsDesiredTabs.contains(key)) return;
      [self showDeveloperToolsForTabID:tabID
                              inspectX:inspectX
                              inspectY:inspectY];
    });
  } else {
    _pendingDeveloperToolsRequests.erase(key);
  }
}

- (void)developerToolsBrowser:(CefRefPtr<CefBrowser>)browser
        didCloseForTabID:(NSString *)tabID {
  CEF_REQUIRE_UI_THREAD();
  const std::string key = RexUTF8(tabID);
  const bool hostInitiatedClose = _developerToolsClosingTabs.contains(key);
  const bool reopenRequested =
      hostInitiatedClose && _developerToolsDesiredTabs.contains(key);
  auto browserIterator = _developerToolsBrowsers.find(key);
  const bool ownsCurrentState = browserIterator == _developerToolsBrowsers.end() ||
      browserIterator->second->IsSame(browser);
  auto readyIterator = _developerToolsFrontendReadyBrowserIDs.find(key);
  if (readyIterator != _developerToolsFrontendReadyBrowserIDs.end() &&
      readyIterator->second == browser->GetIdentifier()) {
    _developerToolsFrontendReadyBrowserIDs.erase(readyIterator);
  }
  NSNumber *browserID = @(browser->GetIdentifier());
  NSView *nativeView = _developerToolsNativeViewsByBrowserID[browserID] ?:
      (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  [nativeView removeFromSuperview];
  NSWindow *popupWindow = _developerToolsPopupWindowsByBrowserID[browserID];
  if (popupWindow) {
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:NSWindowDidBecomeKeyNotification
                object:popupWindow];
    [popupWindow orderOut:nil];
  }
  [_developerToolsPopupWindowsByBrowserID removeObjectForKey:browserID];
  [_developerToolsNativeViewsByBrowserID removeObjectForKey:browserID];

  if (ownsCurrentState) {
    if (browserIterator != _developerToolsBrowsers.end()) {
      _developerToolsBrowsers.erase(browserIterator);
    }
    _developerToolsOpeningTabs.erase(key);
    _developerToolsClosingTabs.erase(key);
  }

  if (ownsCurrentState && !_shuttingDown && !hostInitiatedClose &&
      _developerToolsDesiredTabs.contains(key)) {
    _developerToolsDesiredTabs.erase(key);
    _pendingDeveloperToolsRequests.erase(key);
    _pendingDeveloperToolsFrontendActions.erase(key);
    [self emitEvent:RexEvent(@"developerToolsRequested", tabID,
                             @{ @"inspectX": @(-1), @"inspectY": @(-1) })];
  } else if (ownsCurrentState && !_shuttingDown && reopenRequested) {
    auto pending = _pendingDeveloperToolsRequests.find(key);
    const NSInteger inspectX = pending == _pendingDeveloperToolsRequests.end()
        ? -1 : pending->second.first;
    const NSInteger inspectY = pending == _pendingDeveloperToolsRequests.end()
        ? -1 : pending->second.second;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_developerToolsDesiredTabs.contains(key)) return;
      [self showDeveloperToolsForTabID:tabID
                              inspectX:inspectX
                              inspectY:inspectY];
    });
  }
  [self finishTerminationIfReady];
}

- (void)finishTerminationIfReady {
  if (_shuttingDown && _browsers.empty() && _pendingTabs.empty() &&
      _developerToolsBrowsers.empty() && _developerToolsOpeningTabs.empty()) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishTermination]; });
  }
}

- (void)configureTabID:(NSString *)tabID
              profileID:(NSString *)profileID
        privateBrowsing:(BOOL)privateBrowsing {
  [self onMain:^{
    self->_tabProfileIDs[tabID] = [profileID copy];
    self->_privateTabs[tabID] = @(privateBrowsing);
  }];
}

- (void)registerBrowser:(CefRefPtr<CefBrowser>)browser tabID:(NSString *)tabID {
  _pendingTabs.erase(RexUTF8(tabID));
  _browsers[RexUTF8(tabID)] = browser;
  NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  RexChromiumBrowserView *parentView = _views[tabID];
  if (nativeView && parentView) {
    // Layout the host before attaching so the child gets its final frame on the
    // first pass instead of briefly painting at the representable's zero size.
    if (parentView.window) {
      [parentView setNeedsLayout:YES];
      [parentView layoutSubtreeIfNeeded];
    }
    [self syncNativeBrowserView:nativeView
                     toHostView:parentView
                        browser:browser];

    // SwiftUI often finalizes the NSViewRepresentable frame one runloop later.
    // A deferred sync prevents the first paint from locking onto a zero-size host.
    NSString *tabCopy = [tabID copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      RexChromiumBrowserView *host = self->_views[tabCopy];
      CefRefPtr<CefBrowser> live = [self browserForTabID:tabCopy];
      if (!host || !live || !live->IsSame(browser)) return;
      [host setNeedsLayout:YES];
      [host layoutSubtreeIfNeeded];
      NSView *attached = (__bridge NSView *)live->GetHost()->GetWindowHandle();
      [self syncNativeBrowserView:attached
                       toHostView:host
                          browser:live];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [self forceBrowserRepaintForTabID:tabCopy];
    });
  }
  [self emitEvent:RexEvent(@"created", tabID)];
  NSNumber *muted = _mutedTabs[tabID];
  if (muted) browser->GetHost()->SetAudioMuted(muted.boolValue);
  // A restored URL can arrive before CreateBrowserSync finishes. Apply the
  // newest request after the CEF frame has been attached.
  NSString *pendingURL = _pendingURLs[tabID];
  if (pendingURL) {
    browser->GetMainFrame()->LoadURL(RexUTF8(pendingURL));
    [_pendingURLs removeObjectForKey:tabID];
  }
  if (_shuttingDown) browser->GetHost()->CloseBrowser(true);
}

- (void)browserDidCloseForTabID:(NSString *)tabID {
  [self cancelPermissionRequestsForTabID:tabID];
  [self removeDownloadCallbacksForTabID:tabID];
  const std::string key = RexUTF8(tabID);
  _browsers.erase(key);
  _developerToolsDesiredTabs.erase(key);
  _pendingDeveloperToolsRequests.erase(key);
  _pendingDeveloperToolsFrontendActions.erase(key);
  _developerToolsFrontendReadyBrowserIDs.erase(key);
  if (_developerToolsBrowsers.contains(key) ||
      _developerToolsOpeningTabs.contains(key)) {
    _developerToolsClosingTabs.insert(key);
  }
  _pendingTabs.erase(key);
  [_pendingURLs removeObjectForKey:tabID];
  [_views removeObjectForKey:tabID];
  [_developerToolsViews removeObjectForKey:tabID];
  [_mutedTabs removeObjectForKey:tabID];
  @synchronized (_privacyPolicies) {
    [_privacyPolicies removeObjectForKey:tabID];
  }
  [_downloadDirectories removeObjectForKey:tabID];
  [self releaseProfileForTabID:tabID];
  [self emitEvent:RexEvent(@"closed", tabID)];
  [self finishTerminationIfReady];
}

- (void)registerMediaPermissionRequestID:(NSString *)requestID
                                    tabID:(NSString *)tabID
                     requestedPermissions:(uint32_t)requestedPermissions
                                 callback:(CefRefPtr<CefMediaAccessCallback>)callback {
  RexPendingPermission pending;
  pending.tab_id = RexUTF8(tabID);
  pending.requested_permissions = requestedPermissions;
  pending.media_callback = callback;
  _pendingPermissions[RexUTF8(requestID)] = pending;
}

- (void)registerPermissionPromptID:(uint64_t)promptID
                          requestID:(NSString *)requestID
                              tabID:(NSString *)tabID
               requestedPermissions:(uint32_t)requestedPermissions
                           callback:(CefRefPtr<CefPermissionPromptCallback>)callback {
  RexPendingPermission pending;
  pending.tab_id = RexUTF8(tabID);
  pending.requested_permissions = requestedPermissions;
  pending.prompt_id = promptID;
  pending.prompt_callback = callback;
  const std::string requestKey = RexUTF8(requestID);
  _pendingPermissions[requestKey] = pending;
  _permissionRequestIDsByPrompt[promptID] = requestKey;
}

- (void)respondToPermissionRequestID:(NSString *)requestID
                            decision:(NSString *)decision {
  [self onMain:^{
    const std::string requestKey = RexUTF8(requestID);
    auto iterator = self->_pendingPermissions.find(requestKey);
    if (iterator == self->_pendingPermissions.end()) return;
    RexPendingPermission pending = iterator->second;
    self->_pendingPermissions.erase(iterator);
    if (pending.prompt_id) self->_permissionRequestIDsByPrompt.erase(pending.prompt_id);

    const BOOL allowed = [decision isEqualToString:@"allowOnce"] ||
        [decision isEqualToString:@"allowAlways"] ||
        [decision isEqualToString:@"revokeOnTabClose"];
    if (pending.media_callback) {
      if (allowed) pending.media_callback->Continue(pending.requested_permissions);
      else pending.media_callback->Cancel();
    } else if (pending.prompt_callback) {
      cef_permission_request_result_t result = CEF_PERMISSION_RESULT_DISMISS;
      if (allowed) result = CEF_PERMISSION_RESULT_ACCEPT;
      else if ([decision isEqualToString:@"blockAlways"]) result = CEF_PERMISSION_RESULT_DENY;
      pending.prompt_callback->Continue(result);
    }
  }];
}

- (void)dismissPermissionPromptID:(uint64_t)promptID {
  auto promptIterator = _permissionRequestIDsByPrompt.find(promptID);
  if (promptIterator == _permissionRequestIDsByPrompt.end()) return;
  const std::string requestKey = promptIterator->second;
  _permissionRequestIDsByPrompt.erase(promptIterator);
  auto requestIterator = _pendingPermissions.find(requestKey);
  if (requestIterator == _pendingPermissions.end()) return;
  NSString *tabID = [[NSString alloc] initWithUTF8String:requestIterator->second.tab_id.c_str()] ?: @"";
  NSString *requestID = [[NSString alloc] initWithUTF8String:requestKey.c_str()] ?: @"";
  _pendingPermissions.erase(requestIterator);
  [self emitEvent:RexEvent(@"permissionDismissed", tabID, @{ @"requestID": requestID })];
}

- (void)cancelPermissionRequestsForTabID:(NSString *)tabID {
  const std::string tabKey = RexUTF8(tabID);
  std::vector<std::string> requestIDs;
  for (const auto &entry : _pendingPermissions) {
    if (entry.second.tab_id == tabKey) requestIDs.push_back(entry.first);
  }
  for (const std::string &requestID : requestIDs) {
    NSString *value = [[NSString alloc] initWithUTF8String:requestID.c_str()] ?: @"";
    [self respondToPermissionRequestID:value decision:@"ask"];
  }
}

- (nullable NSURL *)downloadDirectoryForTabID:(NSString *)tabID {
  return _downloadDirectories[tabID];
}

- (void)registerDownloadCallback:(CefRefPtr<CefDownloadItemCallback>)callback
                      downloadID:(uint32_t)downloadID
                           tabID:(NSString *)tabID {
  if (callback) _downloadCallbacks[RexDownloadKey(tabID, downloadID)] = callback;
}

- (void)removeDownloadCallbackID:(uint32_t)downloadID tabID:(NSString *)tabID {
  _downloadCallbacks.erase(RexDownloadKey(tabID, downloadID));
}

- (void)removeDownloadCallbacksForTabID:(NSString *)tabID {
  const std::string prefix = RexUTF8(tabID) + ":";
  for (auto iterator = _downloadCallbacks.begin(); iterator != _downloadCallbacks.end();) {
    if (iterator->first.rfind(prefix, 0) == 0) iterator = _downloadCallbacks.erase(iterator);
    else ++iterator;
  }
}

- (void)releaseProfileForTabID:(NSString *)tabID {
  NSString *profileID = _tabProfileIDs[tabID];
  BOOL wasPrivate = [_privateTabs[tabID] boolValue];
  [_tabProfileIDs removeObjectForKey:tabID];
  [_privateTabs removeObjectForKey:tabID];
  if (!wasPrivate || !profileID.length) return;
  if ([[_tabProfileIDs allValues] containsObject:profileID]) return;
  _requestContexts.erase(RexUTF8(profileID));
}

- (void)emitEvent:(NSDictionary<NSString *, id> *)event {
  NSDictionary<NSString *, id> *eventCopy = [event copy];
  [self onMain:^{
    RexChromiumEventHandler handler = self.eventHandler;
    if (handler) handler(eventCopy);
  }];
}

- (CefRefPtr<CefBrowser>)browserForTabID:(NSString *)tabID {
  auto iterator = _browsers.find(RexUTF8(tabID));
  return iterator == _browsers.end() ? nullptr : iterator->second;
}

- (CefRefPtr<CefBrowser>)developerToolsBrowserForTabID:(NSString *)tabID {
  auto iterator = _developerToolsBrowsers.find(RexUTF8(tabID));
  return iterator == _developerToolsBrowsers.end() ? nullptr : iterator->second;
}

- (void)syncNativeBrowserView:(NSView *)nativeView
                   toHostView:(NSView *)hostView
                      browser:(CefRefPtr<CefBrowser>)browser {
  [self syncNativeBrowserView:nativeView
                   toHostView:hostView
                      browser:browser
                  popupWindow:nil];
}

- (void)syncNativeBrowserView:(NSView *)nativeView
                   toHostView:(NSView *)hostView
                      browser:(CefRefPtr<CefBrowser>)browser
                  popupWindow:(nullable NSWindow *)popupWindow {
  if (!nativeView || !hostView || !browser) return;

  if ([hostView isKindOfClass:RexChromiumDevToolsView.class]) {
    NSNumber *browserID = @(browser->GetIdentifier());
    NSView *attachedView = _developerToolsNativeViewsByBrowserID[browserID];
    if (attachedView) {
      // Once the Chrome window content is detached, GetWindowHandle() points
      // at our replacement contentView. Keep using the original Chromium root
      // for this browser generation instead of reparenting its placeholder.
      nativeView = attachedView;
    } else {
      _developerToolsNativeViewsByBrowserID[browserID] = nativeView;
    }
  }

  // Chrome-style DevTools must first be created in a top-level window on macOS.
  // Replace that window's content view before moving Chromium's view so AppKit
  // does not retain title-bar coordinates or ownership from the temporary host.
  if (popupWindow && popupWindow != hostView.window &&
      popupWindow.contentView == nativeView) {
    popupWindow.contentView = [[NSView alloc] initWithFrame:nativeView.bounds];
  }

  const BOOL needsReparent = nativeView.superview != hostView;
  if (needsReparent) {
    [nativeView removeFromSuperview];
    [hostView addSubview:nativeView positioned:NSWindowBelow relativeTo:nil];
  }

  // Always reparent even when the host is still zero-sized. SwiftUI often creates
  // the representable before the first non-empty layout pass; returning early here
  // used to leave CEF's native view outside the host and blank forever.
  const NSRect rawBounds = hostView.bounds;
  const BOOL hasValidBounds =
      !NSIsEmptyRect(rawBounds) && rawBounds.size.width >= 1 && rawBounds.size.height >= 1;
  hostView.wantsLayer = NO;
  nativeView.wantsLayer = NO;
  nativeView.hidden = NO;
  nativeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (!hasValidBounds) {
    return;
  }

  // Quantize to whole points so sub-pixel SwiftUI layout noise does not thrash CEF.
  const NSRect bounds = NSMakeRect(
      floor(rawBounds.origin.x),
      floor(rawBounds.origin.y),
      floor(rawBounds.size.width),
      floor(rawBounds.size.height));
  if (bounds.size.width < 1 || bounds.size.height < 1) return;

  const BOOL sizeChanged = !NSEqualSizes(nativeView.frame.size, bounds.size);
  const BOOL originChanged = !NSEqualPoints(nativeView.frame.origin, bounds.origin);
  const BOOL boundsOriginChanged = !NSEqualPoints(nativeView.bounds.origin, NSZeroPoint);
  if (sizeChanged || originChanged) {
    nativeView.frame = bounds;
  }
  if (boundsOriginChanged ||
      !NSEqualSizes(nativeView.bounds.size, bounds.size)) {
    nativeView.bounds = NSMakeRect(0, 0, bounds.size.width, bounds.size.height);
  }

  if (popupWindow && popupWindow != hostView.window) {
    [self parkDeveloperToolsPopupWindow:popupWindow hostView:hostView];
  }

  // NotifyMoveOrResizeStarted is only implemented by CEF on Windows/Linux.
  // On macOS, AppKit propagates windowed-view geometry changes; only an
  // actual reparent needs an explicit screen-info refresh.
  if (needsReparent) browser->GetHost()->NotifyScreenInfoChanged();
}

- (void)notifyHostViewDidLayout:(NSView *)hostView tabID:(NSString *)tabID {
  if (!hostView || tabID.length == 0) return;
  [self onMain:^{
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (!browser) return;
    NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [self syncNativeBrowserView:nativeView
                     toHostView:hostView
                        browser:browser];
  }];
}

- (void)notifyDeveloperToolsHostDidLayoutForTabID:(NSString *)tabID {
  if (tabID.length == 0) return;
  [self onMain:^{
    RexChromiumDevToolsView *hostView = self->_developerToolsViews[tabID];
    CefRefPtr<CefBrowser> browser = [self developerToolsBrowserForTabID:tabID];
    if (!hostView) return;
    if (!browser) {
      const std::string key = RexUTF8(tabID);
      const NSRect bounds = hostView.bounds;
      if (!self->_shuttingDown && self->_developerToolsDesiredTabs.contains(key) &&
          !self->_developerToolsOpeningTabs.contains(key) &&
          !self->_developerToolsClosingTabs.contains(key) && hostView.window &&
          hostView.superview && !NSIsEmptyRect(bounds) &&
          bounds.size.width >= 1 && bounds.size.height >= 1) {
        auto pending = self->_pendingDeveloperToolsRequests.find(key);
        const NSInteger inspectX = pending == self->_pendingDeveloperToolsRequests.end()
            ? -1 : pending->second.first;
        const NSInteger inspectY = pending == self->_pendingDeveloperToolsRequests.end()
            ? -1 : pending->second.second;
        [self showDeveloperToolsForTabID:tabID inspectX:inspectX inspectY:inspectY];
      }
      return;
    }
    NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [self syncNativeBrowserView:nativeView
                     toHostView:hostView
                        browser:browser
                    popupWindow:self->_developerToolsPopupWindowsByBrowserID[
                        @(browser->GetIdentifier())]];
  }];
}

- (void)setLayoutSyncSuspended:(BOOL)suspended {
  [self onMain:^{
    self->_layoutSyncSuspended = suspended;
  }];
}

- (void)flushLayoutSync {
  [self onMain:^{
    const BOOL wasSuspended = self->_layoutSyncSuspended;
    self->_layoutSyncSuspended = NO;
    for (NSString *tabID in self->_views) {
      RexChromiumBrowserView *hostView = self->_views[tabID];
      CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
      if (!hostView || !browser) continue;
      NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
      [self syncNativeBrowserView:nativeView
                       toHostView:hostView
                          browser:browser];
      if (browser) {
        browser->GetHost()->NotifyScreenInfoChanged();
      }
    }
    for (NSString *tabID in self->_developerToolsViews) {
      RexChromiumDevToolsView *hostView = self->_developerToolsViews[tabID];
      CefRefPtr<CefBrowser> browser = [self developerToolsBrowserForTabID:tabID];
      if (!hostView || !browser) continue;
      NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
      [self syncNativeBrowserView:nativeView
                       toHostView:hostView
                          browser:browser
                      popupWindow:self->_developerToolsPopupWindowsByBrowserID[
                          @(browser->GetIdentifier())]];
      if (browser) {
        browser->GetHost()->NotifyScreenInfoChanged();
      }
    }
    self->_layoutSyncSuspended = wasSuspended;
  }];
}

- (void)forceBrowserRepaintForTabID:(NSString *)tabID {
  if (tabID.length == 0) return;
  [self onMain:^{
    RexChromiumBrowserView *hostView = self->_views[tabID];
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (!hostView || !browser) return;
    [hostView setNeedsLayout:YES];
    [hostView layoutSubtreeIfNeeded];
    NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [self syncNativeBrowserView:nativeView
                     toHostView:hostView
                        browser:browser];
    browser->GetHost()->NotifyScreenInfoChanged();
  }];
}

- (void)onMain:(dispatch_block_t)block {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

- (void)closeTabID:(NSString *)tabID {
  [self onMain:^{
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (browser) browser->GetHost()->CloseBrowser(true);
    else {
      [self cancelPermissionRequestsForTabID:tabID];
      self->_pendingTabs.erase(RexUTF8(tabID));
      [self->_pendingURLs removeObjectForKey:tabID];
      [self->_views removeObjectForKey:tabID];
      [self->_mutedTabs removeObjectForKey:tabID];
      @synchronized (self->_privacyPolicies) {
        [self->_privacyPolicies removeObjectForKey:tabID];
      }
      [self->_downloadDirectories removeObjectForKey:tabID];
      [self removeDownloadCallbacksForTabID:tabID];
      [self releaseProfileForTabID:tabID];
    }
  }];
}

- (void)configureDownloadDirectoryURL:(nullable NSURL *)directoryURL
                                tabID:(NSString *)tabID {
  [self onMain:^{
    if (directoryURL) self->_downloadDirectories[tabID] = directoryURL;
    else [self->_downloadDirectories removeObjectForKey:tabID];
  }];
}

- (void)cancelDownloadID:(NSInteger)downloadID tabID:(NSString *)tabID {
  [self onMain:^{
    const std::string key = RexDownloadKey(tabID, static_cast<uint32_t>(downloadID));
    auto iterator = self->_downloadCallbacks.find(key);
    if (iterator != self->_downloadCallbacks.end() && iterator->second) {
      iterator->second->Cancel();
    }
  }];
}

- (void)startDownloadURLString:(NSString *)urlString tabID:(NSString *)tabID {
  [self onMain:^{
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (browser) browser->GetHost()->StartDownload(RexUTF8(urlString));
  }];
}

- (void)loadURLString:(NSString *)urlString tabID:(NSString *)tabID {
  [self onMain:^{
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (browser) {
      CefRefPtr<CefFrame> frame = browser->GetMainFrame();
      const std::string requestedURL = RexUTF8(urlString);
      if (frame && frame->GetURL().ToString() == requestedURL) return;
      if (frame) frame->LoadURL(RexUTF8(urlString));
    } else if (self->_views[tabID]) {
      // Do not drop navigation while the view is waiting to attach to a window.
      self->_pendingURLs[tabID] = [urlString copy];
    }
  }];
}

- (void)goBackForTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b && b->CanGoBack()) b->GoBack(); }];
}
- (void)goForwardForTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b && b->CanGoForward()) b->GoForward(); }];
}
- (void)reloadTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->Reload(); }];
}
- (void)reloadIgnoringCacheForTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->ReloadIgnoreCache(); }];
}
- (void)stopTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->StopLoad(); }];
}
- (void)printTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->GetHost()->Print(); }];
}
- (void)setAudioMuted:(BOOL)muted tabID:(NSString *)tabID {
  [self onMain:^{
    self->_mutedTabs[tabID] = @(muted);
    CefRefPtr<CefBrowser> b = [self browserForTabID:tabID];
    if (b) b->GetHost()->SetAudioMuted(muted);
  }];
}

- (void)setPrivacyPolicyForTabID:(NSString *)tabID
                         enabled:(BOOL)enabled
                            mode:(NSString *)mode
         fingerprintProtection:(BOOL)fingerprintProtection
         blockThirdPartyCookies:(BOOL)blockThirdPartyCookies {
  NSString *modeValue = mode.length ? mode : @"standard";
  [self onMain:^{
    @synchronized (self->_privacyPolicies) {
      self->_privacyPolicies[tabID] = @{
        @"enabled": @(enabled),
        @"mode": modeValue,
        @"fingerprintProtection": @(fingerprintProtection),
        @"blockThirdPartyCookies": @(blockThirdPartyCookies)
      };
    }

    const bool shouldBlockThirdPartyCookies = blockThirdPartyCookies;
    self->_blockThirdPartyCookiesPreference->store(
        shouldBlockThirdPartyCookies, std::memory_order_relaxed);
    if (!self->_ready || self->_shuttingDown) return;

    RexApplyThirdPartyCookiePreference(
        CefRequestContext::GetGlobalContext(), shouldBlockThirdPartyCookies,
        "global");
    for (const auto &[profileKey, requestContext] : self->_requestContexts) {
      RexApplyThirdPartyCookiePreference(
          requestContext, shouldBlockThirdPartyCookies,
          "private:" + profileKey);
    }
  }];
}

- (void)setContentBlockingEnabled:(BOOL)enabled {
  rex::privacy::SetContentBlockingEnabled(enabled);
  NSLog(@"[Rex] content blocking (host catalogs) %@",
        enabled ? @"enabled" : @"disabled");
}

- (rex::privacy::ProtectionPolicy)privacyPolicyForTabID:(NSString *)tabID
                                               browser:(CefRefPtr<CefBrowser>)browser {
  rex::privacy::ProtectionPolicy policy;
  NSDictionary<NSString *, id> *stored = nil;
  @synchronized (_privacyPolicies) {
    stored = [_privacyPolicies[tabID] copy];
  }
  if (stored) {
    policy.enabled = [stored[@"enabled"] boolValue];
    NSString *mode = stored[@"mode"] ?: @"standard";
    policy.mode = rex::privacy::ModeFromToken(RexUTF8(mode));
    policy.fingerprintProtection = [stored[@"fingerprintProtection"] boolValue];
    policy.blockThirdPartyCookies = [stored[@"blockThirdPartyCookies"] boolValue];
  }
  if (browser) {
    CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
    if (mainFrame) {
      policy.firstPartyHost = RexHostForURL(mainFrame->GetURL());
    }
  }
  return policy;
}

- (void)setZoomLevel:(double)zoomLevel tabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->GetHost()->SetZoomLevel(zoomLevel); }];
}
- (void)findText:(NSString *)text
         forward:(BOOL)forward
        findNext:(BOOL)findNext
           tabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->GetHost()->Find(RexUTF8(text), forward, false, findNext); }];
}
- (void)stopFindingForTabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->GetHost()->StopFinding(true); }];
}
- (void)showDeveloperToolsForTabID:(NSString *)tabID {
  [self showDeveloperToolsForTabID:tabID inspectX:-1 inspectY:-1];
}

- (void)showDeveloperToolsConsoleForTabID:(NSString *)tabID {
  [self queueDeveloperToolsFrontendAction:RexDevToolsFrontendAction::Console
                                    tabID:tabID];
}

- (void)showDeveloperToolsInspectForTabID:(NSString *)tabID {
  [self queueDeveloperToolsFrontendAction:RexDevToolsFrontendAction::Inspect
                                    tabID:tabID];
}

- (void)showDeveloperToolsForTabID:(NSString *)tabID
                          inspectX:(NSInteger)inspectX
                          inspectY:(NSInteger)inspectY {
  [self onMain:^{
    const std::string key = RexUTF8(tabID);
    if (self->_shuttingDown) return;
    CefRefPtr<CefBrowser> b = [self browserForTabID:tabID];
    if (!b || !b->IsValid()) return;
    self->_developerToolsDesiredTabs.insert(key);
    if (self->_developerToolsClosingTabs.contains(key)) {
      self->_pendingDeveloperToolsRequests[key] = {inspectX, inspectY};
      return;
    }
    RexChromiumDevToolsView *view = self->_developerToolsViews[tabID];
    const NSRect bounds = view ? view.bounds : NSZeroRect;
    if (!view || !view.window || !view.superview || NSIsEmptyRect(bounds) ||
        bounds.size.width < 1 || bounds.size.height < 1) {
      self->_pendingDeveloperToolsRequests[key] = {inspectX, inspectY};
      return;
    }

    CefRefPtr<CefBrowser> existingTools = [self developerToolsBrowserForTabID:tabID];
    if (existingTools) {
      self->_pendingDeveloperToolsRequests.erase(key);
      NSView *nativeView = (__bridge NSView *)existingTools->GetHost()->GetWindowHandle();
      [self syncNativeBrowserView:nativeView
                       toHostView:view
                          browser:existingTools
                      popupWindow:self->_developerToolsPopupWindowsByBrowserID[
                          @(existingTools->GetIdentifier())]];
      if (inspectX >= 0 && inspectY >= 0) {
        CefWindowInfo windowInfo;
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
        const int x = static_cast<int>(inspectX);
        const int y = static_cast<int>(inspectY);
        const CefPoint point = x == 0 && y == 0 ? CefPoint(1, 0) : CefPoint(x, y);
        b->GetHost()->ShowDevTools(
            windowInfo, nullptr, CefBrowserSettings(), point);
      }
      [view.window makeKeyAndOrderFront:nil];
      existingTools->GetHost()->SetFocus(true);
      return;
    }

    if (self->_developerToolsOpeningTabs.contains(key)) {
      self->_pendingDeveloperToolsRequests[key] = {inspectX, inspectY};
      return;
    }
    self->_developerToolsOpeningTabs.insert(key);
    self->_pendingDeveloperToolsRequests.erase(key);

    CefWindowInfo windowInfo;
    // Chrome-style DevTools must be created visible on macOS or Chromium keeps
    // its internal WebContentsViewCocoa hidden after we reparent the window.
    // Start with a valid one-pixel on-screen window; OnAfterCreated immediately
    // makes it transparent, and registration parks it behind the Rex window.
    windowInfo.bounds = CefRect(0, 0, 1, 1);
    windowInfo.hidden = false;
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    CefBrowserSettings settings;
    CefPoint point;
    if (inspectX >= 0 && inspectY >= 0) {
      const int x = static_cast<int>(inspectX);
      const int y = static_cast<int>(inspectY);
      point = x == 0 && y == 0 ? CefPoint(1, 0) : CefPoint(x, y);
    }
    b->GetHost()->ShowDevTools(windowInfo, nullptr, settings, point);
    [view.window makeKeyAndOrderFront:nil];
  }];
}
- (void)closeDeveloperToolsForTabID:(NSString *)tabID {
  [self onMain:^{
    CefRefPtr<CefBrowser> b = [self browserForTabID:tabID];
    const std::string key = RexUTF8(tabID);
    self->_developerToolsDesiredTabs.erase(key);
    self->_pendingDeveloperToolsRequests.erase(key);
    self->_pendingDeveloperToolsFrontendActions.erase(key);
    if (b && b->GetHost()->HasDevTools()) {
      self->_developerToolsClosingTabs.insert(key);
      b->GetHost()->CloseDevTools();
    } else if (CefRefPtr<CefBrowser> tools =
                   [self developerToolsBrowserForTabID:tabID]) {
      self->_developerToolsClosingTabs.insert(key);
      tools->GetHost()->CloseBrowser(true);
    } else if (self->_developerToolsOpeningTabs.contains(key)) {
      self->_developerToolsClosingTabs.insert(key);
    } else {
      self->_developerToolsClosingTabs.erase(key);
      self->_developerToolsOpeningTabs.erase(key);
    }
    [self->_developerToolsViews removeObjectForKey:tabID];
  }];
}
- (BOOL)handleDeveloperToolsShortcutForWindow:(nullable NSWindow *)window {
  if (!window) return NO;

  NSString *tabID = nil;
  NSResponder *responder = window.firstResponder;
  while ([responder isKindOfClass:NSView.class]) {
    if ([responder isKindOfClass:RexChromiumBrowserView.class]) {
      tabID = ((RexChromiumBrowserView *)responder).tabID;
      break;
    }
    responder = ((NSView *)responder).superview;
  }

  if (!tabID) {
    for (NSString *candidateID in _views) {
      RexChromiumBrowserView *view = _views[candidateID];
      if (view.window == window && !view.hidden && view.superview) {
        tabID = candidateID;
        break;
      }
    }
  }
  if (!tabID) return NO;

  NSString *requestedTabID = [tabID copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self emitEvent:RexEvent(@"developerToolsRequested", requestedTabID,
                             @{ @"inspectX": @(-1), @"inspectY": @(-1) })];
  });
  return YES;
}
- (void)setFocused:(BOOL)focused tabID:(NSString *)tabID {
  [self onMain:^{ CefRefPtr<CefBrowser> b = [self browserForTabID:tabID]; if (b) b->GetHost()->SetFocus(focused); }];
}

- (void)setPageSuspended:(BOOL)suspended tabID:(NSString *)tabID {
  [self onMain:^{
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    if (!host) return;
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("state", suspended ? "frozen" : "active");
    if (host->ExecuteDevToolsMethod(
            0, "Page.setWebLifecycleState", params) == 0) {
      NSLog(@"[Rex] Unable to set page lifecycle state for %@", tabID);
    }
  }];
}

- (void)prepareForApplicationTermination:(void (^)(void))completion {
  [self onMain:^{
    if (!self->_ready) { completion(); return; }
    self->_shuttingDown = YES;
    self->_terminationCompletion = [completion copy];
    // CloseBrowser cannot be initiated while CefScopedSendingEvent is active.
    // The delegate first cancels Cocoa's current quit event; this block then
    // runs after sendEvent has unwound.
    dispatch_async(dispatch_get_main_queue(), ^{
      for (const auto &entry : self->_browsers) {
        entry.second->GetHost()->CloseBrowser(true);
      }
      for (const auto &entry : self->_developerToolsBrowsers) {
        self->_developerToolsClosingTabs.insert(entry.first);
        entry.second->GetHost()->CloseBrowser(true);
      }
      [self finishTerminationIfReady];
    });
  }];
}

- (void)finishTermination {
  if (!_ready) return;
  [_views removeAllObjects];
  [_developerToolsViews removeAllObjects];
  for (NSWindow *popupWindow in _developerToolsPopupWindowsByBrowserID.allValues) {
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:NSWindowDidBecomeKeyNotification
                object:popupWindow];
    [popupWindow orderOut:nil];
  }
  [_developerToolsPopupWindowsByBrowserID removeAllObjects];
  [_developerToolsNativeViewsByBrowserID removeAllObjects];
  [_tabProfileIDs removeAllObjects];
  [_privateTabs removeAllObjects];
  [_mutedTabs removeAllObjects];
  @synchronized (_privacyPolicies) {
    [_privacyPolicies removeAllObjects];
  }
  [_downloadDirectories removeAllObjects];
  _requestContexts.clear();
  _developerToolsBrowsers.clear();
  _developerToolsFrontendReadyBrowserIDs.clear();
  _developerToolsDesiredTabs.clear();
  _developerToolsOpeningTabs.clear();
  _developerToolsClosingTabs.clear();
  _pendingDeveloperToolsRequests.clear();
  _pendingDeveloperToolsFrontendActions.clear();
  _downloadCallbacks.clear();
  _pendingPermissions.clear();
  _permissionRequestIDsByPrompt.clear();
  void (^completion)(void) = _terminationCompletion;
  _terminationCompletion = nil;
  if (completion) completion();
}

- (void)shutdownAfterApplicationTermination {
  NSAssert(NSThread.isMainThread, @"CEF must shut down on the main thread");
  if (!_ready) return;
  _application->StopMessagePump();
  _taskManager = nullptr;
  CefShutdown();
  _application = nullptr;
  _libraryLoader.reset();
  _ready = NO;
}

@end

namespace {

void RexBrowserClient::Emit(NSString *kind, NSDictionary<NSString *, id> *fields) {
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime emitEvent:RexEvent(kind, tab_id_, fields)];
}

void RexBrowserClient::EmitSecuritySnapshot(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  Emit(@"siteSecurity", RexSecurityPayload(browser, navigation_generation_));
}

void RexBrowserClient::EmitBlockedResource(NSString *category,
                                           const std::string &host) {
  NSString *hostValue = [[NSString alloc] initWithUTF8String:host.c_str()] ?: @"";
  Emit(@"blockedResource", @{
    @"category": category,
    @"host": hostValue,
    @"count": @1
  });
}

namespace {

enum RexContextMenuCommand {
  kRexOpenLinkNewTab = MENU_ID_USER_FIRST,
  kRexOpenLinkSplit,
  kRexCopyLink,
  kRexSaveLink,
  kRexOpenMediaNewTab,
  kRexCopyMediaURL,
  kRexSaveMedia,
  kRexSearchSelection,
  kRexCopyPageURL,
  kRexSavePage,
  kRexInspectElement,
};

void RexCopyTextToPasteboard(const CefString &value) {
  NSString *text = RexNSString(value);
  if (!text.length) return;
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:text forType:NSPasteboardTypeString];
}

void RexAddEditingItems(CefRefPtr<CefContextMenuParams> params,
                        CefRefPtr<CefMenuModel> model) {
  const int flags = params->GetEditStateFlags();
  std::vector<CefString> suggestions;
  if (params->GetDictionarySuggestions(suggestions)) {
    const size_t count = std::min<size_t>(suggestions.size(), 5);
    for (size_t index = 0; index < count; ++index) {
      model->AddItem(MENU_ID_SPELLCHECK_SUGGESTION_0 + static_cast<int>(index),
                     suggestions[index]);
    }
    if (count > 0) model->AddSeparator();
  }
  model->AddItem(MENU_ID_UNDO, CefString(u"撤销"));
  model->SetEnabled(MENU_ID_UNDO, flags & CM_EDITFLAG_CAN_UNDO);
  model->AddItem(MENU_ID_REDO, CefString(u"重做"));
  model->SetEnabled(MENU_ID_REDO, flags & CM_EDITFLAG_CAN_REDO);
  model->AddSeparator();
  model->AddItem(MENU_ID_CUT, CefString(u"剪切"));
  model->SetEnabled(MENU_ID_CUT, flags & CM_EDITFLAG_CAN_CUT);
  model->AddItem(MENU_ID_COPY, CefString(u"复制"));
  model->SetEnabled(MENU_ID_COPY, flags & CM_EDITFLAG_CAN_COPY);
  model->AddItem(MENU_ID_PASTE, CefString(u"粘贴"));
  model->SetEnabled(MENU_ID_PASTE, flags & CM_EDITFLAG_CAN_PASTE);
  model->AddItem(MENU_ID_PASTE_MATCH_STYLE, CefString(u"粘贴并匹配样式"));
  model->SetEnabled(MENU_ID_PASTE_MATCH_STYLE, flags & CM_EDITFLAG_CAN_PASTE);
  model->AddItem(MENU_ID_DELETE, CefString(u"删除"));
  model->SetEnabled(MENU_ID_DELETE, flags & CM_EDITFLAG_CAN_DELETE);
  model->AddSeparator();
  model->AddItem(MENU_ID_SELECT_ALL, CefString(u"全选"));
  model->SetEnabled(MENU_ID_SELECT_ALL, flags & CM_EDITFLAG_CAN_SELECT_ALL);
}

}  // namespace

void RexBrowserClient::OnBeforeContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
  CEF_REQUIRE_UI_THREAD();
  model->Clear();
  const int type = params->GetTypeFlags();

  if (type & CM_TYPEFLAG_EDITABLE) {
    RexAddEditingItems(params, model);
    return;
  }

  if (type & CM_TYPEFLAG_LINK) {
    model->AddItem(kRexOpenLinkNewTab, CefString(u"在新标签页中打开链接"));
    model->AddItem(kRexOpenLinkSplit, CefString(u"在 Rex 分屏中打开链接"));
    model->AddSeparator();
    model->AddItem(kRexCopyLink, CefString(u"复制链接地址"));
    model->AddItem(kRexSaveLink, CefString(u"链接另存为…"));
    model->AddSeparator();
  }

  if (type & CM_TYPEFLAG_MEDIA) {
    model->AddItem(kRexOpenMediaNewTab, CefString(u"在新标签页中打开媒体"));
    model->AddItem(kRexSaveMedia, CefString(u"媒体另存为…"));
    model->AddItem(kRexCopyMediaURL, CefString(u"复制媒体地址"));
    model->AddSeparator();
  }

  if (type & CM_TYPEFLAG_SELECTION) {
    model->AddItem(MENU_ID_COPY, CefString(u"复制"));
    model->AddItem(kRexSearchSelection, CefString(u"使用默认搜索引擎搜索所选文本"));
    model->AddSeparator();
  }

  model->AddItem(MENU_ID_BACK, CefString(u"返回"));
  model->SetEnabled(MENU_ID_BACK, browser->CanGoBack());
  model->AddItem(MENU_ID_FORWARD, CefString(u"前进"));
  model->SetEnabled(MENU_ID_FORWARD, browser->CanGoForward());
  model->AddItem(MENU_ID_RELOAD, CefString(u"重新加载"));
  model->AddSeparator();
  model->AddItem(kRexSavePage, CefString(u"保存页面…"));
  model->AddItem(MENU_ID_PRINT, CefString(u"打印…"));
  model->AddItem(kRexCopyPageURL, CefString(u"复制页面地址"));
  model->AddSeparator();
  model->AddItem(kRexInspectElement, CefString(u"检查"));
}

bool RexBrowserClient::RunContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model,
    CefRefPtr<CefRunContextMenuCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  // Returning false delegates display and command dispatch to Chromium. CEF's
  // native implementation owns the menu model and callback for their full
  // lifetime, which also preserves the platform shortcuts and submenus.
  return false;
}

bool RexBrowserClient::OnContextMenuCommand(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    int command_id,
    EventFlags event_flags) {
  CEF_REQUIRE_UI_THREAD();
  switch (command_id) {
    case kRexOpenLinkNewTab:
      Emit(@"popup", @{
        @"url": RexNSString(params->GetLinkUrl()),
        @"foreground": @YES
      });
      return true;
    case kRexOpenLinkSplit:
      Emit(@"splitLink", @{@"url": RexNSString(params->GetLinkUrl())});
      return true;
    case kRexCopyLink:
      RexCopyTextToPasteboard(params->GetUnfilteredLinkUrl());
      return true;
    case kRexSaveLink:
      browser->GetHost()->StartDownload(params->GetLinkUrl());
      return true;
    case kRexOpenMediaNewTab:
      Emit(@"popup", @{
        @"url": RexNSString(params->GetSourceUrl()),
        @"foreground": @YES
      });
      return true;
    case kRexCopyMediaURL:
      RexCopyTextToPasteboard(params->GetSourceUrl());
      return true;
    case kRexSaveMedia:
      browser->GetHost()->StartDownload(params->GetSourceUrl());
      return true;
    case kRexSearchSelection:
      Emit(@"contextSearch", @{@"text": RexNSString(params->GetSelectionText())});
      return true;
    case kRexCopyPageURL:
      RexCopyTextToPasteboard(params->GetPageUrl());
      return true;
    case kRexSavePage:
      browser->GetHost()->StartDownload(params->GetPageUrl());
      return true;
    case kRexInspectElement: {
      Emit(@"developerToolsRequested", @{
        @"inspectX": @(params->GetXCoord()),
        @"inspectY": @(params->GetYCoord())
      });
      return true;
    }
    default:
      return false;
  }
}

CefResourceRequestHandler::ReturnValue RexBrowserClient::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  // Catalog-based network blocking (v0.8.0). Runs on the IO thread: only the
  // @synchronized policy store may be touched, never browser/frame UI-thread
  // state (first-party comes from the request).
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime) return RV_CONTINUE;
  const rex::privacy::ProtectionPolicy policy =
      [runtime privacyPolicyForTabID:tab_id_ browser:nullptr];
  const rex::privacy::BlockDecision decision =
      rex::privacy::ClassifyRequest(request, policy);
  if (decision.category == rex::privacy::BlockCategory::None) {
    return RV_CONTINUE;
  }
  EmitBlockedResource(
      @(rex::privacy::CategoryToken(decision.category)), decision.host);
  return RV_CANCEL;
}

bool RexBrowserClient::CanSendCookie(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request,
                                     const CefCookie &cookie) {
  // Chromium CookieSettings is authoritative for third-party Cookie policy.
  return true;
}

bool RexBrowserClient::CanSaveCookie(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefResponse> response,
                                     const CefCookie &cookie) {
  // Chromium CookieSettings is authoritative for third-party Cookie policy.
  return true;
}

void RexBrowserClient::OnBeforeDevToolsPopup(
    CefRefPtr<CefBrowser> browser,
    CefWindowInfo &window_info,
    CefRefPtr<CefClient> &client,
    CefBrowserSettings &settings,
    CefRefPtr<CefDictionaryValue> &extra_info,
    bool *use_default_window) {
  CEF_REQUIRE_UI_THREAD();
  // CEF 150 always creates DevTools with the Chrome runtime. macOS cannot
  // create a Chrome-style child for an external NSView, so let Chromium create
  // a temporary top-level window and reparent its content view in OnAfterCreated.
  window_info.parent_view = kNullWindowHandle;
  window_info.bounds = CefRect(0, 0, 1, 1);
  window_info.hidden = false;
  window_info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  client = new RexDevToolsClient(runtime_, tab_id_, true);
  if (use_default_window) *use_default_window = true;
}

void RexBrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime registerBrowser:browser tabID:tab_id_];
}

bool RexBrowserClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString &target_url,
    const CefString &target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures &popup_features,
    CefWindowInfo &window_info,
    CefRefPtr<CefClient> &client,
    CefBrowserSettings &settings,
    CefRefPtr<CefDictionaryValue> &extra_info,
    bool *no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  NSString *url = RexNSString(target_url);
  if (url.length) {
    Emit(@"popup", @{
      @"url": url,
      @"foreground": @(target_disposition != CEF_WOD_NEW_BACKGROUND_TAB),
      @"userGesture": @(user_gesture)
    });
  }
  // Rex owns all browser windows and profiles. Prevent CEF from creating an
  // unmanaged native popup; the Swift store maps this request to a Rex tab.
  return true;
}

bool RexBrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  [nativeView removeFromSuperview];
  return true;
}

void RexBrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  EmitMediaAccess(false, false);
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime browserDidCloseForTabID:tab_id_];
}

RexDevToolsClient::~RexDevToolsClient() {
  if (!tracks_opening_ || browser_created_) return;
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime) return;
  NSString *tabID = [tab_id_ copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    [runtime developerToolsCreationAbortedForTabID:tabID];
  });
}

void RexDevToolsClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browser_created_ = true;
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime || !browser || !browser->IsValid()) return;

  NSView *nativeView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  NSWindow *popupWindow = nativeView.window;
  if (popupWindow) {
    popupWindow.alphaValue = 0.01;
    popupWindow.ignoresMouseEvents = YES;
    [popupWindow setFrame:NSMakeRect(0, 0, 1, 1) display:NO];
  }

  // Allow Chromium to finish constructing the Chrome-style window before its
  // content view is detached and moved into SwiftUI's AppKit host.
  NSString *tabID = [tab_id_ copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    [runtime registerDeveloperToolsBrowser:browser tabID:tabID];
  });
}

void RexDevToolsClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime developerToolsBrowser:browser didCloseForTabID:tab_id_];
}

void RexDevToolsClient::OnLoadStart(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    TransitionType /*transition_type*/) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame || !frame->IsMain()) return;
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime developerToolsFrontendWillLoad:browser tabID:tab_id_];
}

void RexDevToolsClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  int /*http_status_code*/) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame || !frame->IsMain()) return;
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime developerToolsFrontendDidLoad:browser tabID:tab_id_];
}

bool RexBrowserClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!callback) return false;
  NSArray<NSString *> *kinds = RexMediaPermissionKinds(requested_permissions);
  if (!kinds.count) {
    callback->Cancel();
    return true;
  }
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime) {
    callback->Cancel();
    return true;
  }
  NSString *requestID = NSUUID.UUID.UUIDString;
  [runtime registerMediaPermissionRequestID:requestID
                                      tabID:tab_id_
                       requestedPermissions:requested_permissions
                                   callback:callback];
  CefRefPtr<CefFrame> mainFrame = browser ? browser->GetMainFrame() : nullptr;
  Emit(@"permissionRequest", @{
    @"requestID": requestID,
    @"topLevelOrigin": mainFrame ? RexOriginForURL(mainFrame->GetURL()) : @"",
    @"requestingOrigin": RexOriginForURL(requesting_origin),
    @"kinds": kinds
  });
  return true;
}

bool RexBrowserClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!callback) return false;
  NSArray<NSString *> *kinds = RexPermissionKinds(requested_permissions);
  if (!kinds.count) {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime) {
    callback->Continue(CEF_PERMISSION_RESULT_DISMISS);
    return true;
  }
  NSString *requestID = NSUUID.UUID.UUIDString;
  [runtime registerPermissionPromptID:prompt_id
                            requestID:requestID
                                tabID:tab_id_
                 requestedPermissions:requested_permissions
                             callback:callback];
  CefRefPtr<CefFrame> mainFrame = browser ? browser->GetMainFrame() : nullptr;
  Emit(@"permissionRequest", @{
    @"requestID": requestID,
    @"topLevelOrigin": mainFrame ? RexOriginForURL(mainFrame->GetURL()) : @"",
    @"requestingOrigin": RexOriginForURL(requesting_origin),
    @"kinds": kinds
  });
  return true;
}

void RexBrowserClient::OnDismissPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    cef_permission_request_result_t result) {
  CEF_REQUIRE_UI_THREAD();
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) [runtime dismissPermissionPromptID:prompt_id];
}

bool RexBrowserClient::OnCertificateError(
    CefRefPtr<CefBrowser> browser,
    cef_errorcode_t cert_error,
    const CefString &request_url,
    CefRefPtr<CefSSLInfo> ssl_info,
    CefRefPtr<CefCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  const cef_cert_status_t certificateStatus = ssl_info
      ? ssl_info->GetCertStatus()
      : CERT_STATUS_NONE;
  NSMutableDictionary<NSString *, id> *payload = [@{
    @"url": RexNSString(request_url),
    @"navigationGeneration": @(navigation_generation_),
    @"isPending": @NO,
    @"isSecureConnection": @NO,
    @"hasCertificateError": @YES,
    @"certificateErrorCode": @((int)cert_error),
    @"certificateStatus": @((uint32_t)certificateStatus),
    @"tlsVersion": @"unknown",
    @"contentStatus": @0
  } mutableCopy];
  if (ssl_info) {
    CefRefPtr<CefX509Certificate> certificate = ssl_info->GetX509Certificate();
    if (certificate) payload[@"certificate"] = RexCertificatePayload(certificate);
  }
  Emit(@"siteSecurity", payload);

  // Preserve Chromium's default rejection behavior. Certificate bypasses must
  // never be inferred from opening the site information UI.
  return false;
}

void RexBrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString &url) {
  if (frame->IsMain()) {
    Emit(@"address", @{ @"url": RexNSString(url) });
    EmitSecuritySnapshot(browser);
  }
}

void RexBrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                     const CefString &title) {
  Emit(@"title", @{ @"title": RexNSString(title) });
}

void RexBrowserClient::OnFaviconURLChange(
    CefRefPtr<CefBrowser> browser,
    const std::vector<CefString> &icon_urls) {
  if (icon_urls.empty()) {
    Emit(@"favicon", @{ @"url": @"" });
    return;
  }
  for (const CefString &icon_url : icon_urls) {
    if (icon_url.empty() || !browser) continue;
    browser->GetHost()->DownloadImage(
        icon_url, true, 32, false,
        new RexFaviconDownloadCallback(runtime_, tab_id_));
    return;
  }
  Emit(@"favicon", @{ @"url": @"" });
}

void RexBrowserClient::OnAudioStreamStarted(
    CefRefPtr<CefBrowser> browser,
    const CefAudioParameters &params,
    int channels) {
  Emit(@"audio", @{ @"isPlaying": @YES });
}

void RexBrowserClient::OnAudioStreamPacket(CefRefPtr<CefBrowser> browser,
                                           const float **data,
                                           int frames,
                                           int64_t pts) {
}

void RexBrowserClient::OnAudioStreamStopped(CefRefPtr<CefBrowser> browser) {
  Emit(@"audio", @{ @"isPlaying": @NO });
}

void RexBrowserClient::OnAudioStreamError(CefRefPtr<CefBrowser> browser,
                                          const CefString &message) {
  Emit(@"audio", @{ @"isPlaying": @NO });
}

void RexBrowserClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                               double progress) {
  Emit(@"progress", @{ @"progress": @(progress) });
}

void RexBrowserClient::OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                                           bool has_video_access,
                                           bool has_audio_access) {
  CEF_REQUIRE_UI_THREAD();
  EmitMediaAccess(has_video_access, has_audio_access);
}

void RexBrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                            bool is_loading,
                                            bool can_go_back,
                                            bool can_go_forward) {
  CEF_REQUIRE_UI_THREAD();
  Emit(@"loading", @{ @"isLoading": @(is_loading),
                      @"canGoBack": @(can_go_back),
                      @"canGoForward": @(can_go_forward) });
  if (is_loading) {
    ++navigation_generation_;
    Emit(@"siteSecurity", RexPendingSecurityPayload(browser, navigation_generation_));
  } else {
    EmitSecuritySnapshot(browser);
  }
  // After the first meaningful paint path finishes, force one host-side repaint.
  // This recovers blank CEF tiles when attach raced a zero-size SwiftUI host.
  if (!is_loading) {
    RexChromiumRuntime *runtime = runtime_;
    NSString *tabID = tab_id_;
    if (runtime && tabID.length) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [runtime forceBrowserRepaintForTabID:tabID];
      });
    }
  }
}

bool RexBrowserClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString &suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!callback) return true;
  RexChromiumRuntime *runtime = runtime_;
  NSURL *directoryURL = [runtime downloadDirectoryForTabID:tab_id_];
  NSNumber *isDirectory = nil;
  NSError *resourceError = nil;
  [directoryURL getResourceValue:&isDirectory
                          forKey:NSURLIsDirectoryKey
                           error:&resourceError];
  if (directoryURL.isFileURL && isDirectory.boolValue && !resourceError) {
    NSString *filename = RexNSString(suggested_name);
    if (!filename.length && download_item) {
      filename = RexNSString(download_item->GetSuggestedFileName());
    }
    callback->Continue(RexUTF8(RexUniqueDownloadPath(directoryURL, filename)), false);
  } else {
    callback->Continue(CefString(), true);
  }
  return true;
}

void RexBrowserClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!download_item || !download_item->IsValid()) return;
  RexChromiumRuntime *runtime = runtime_;
  const uint32_t downloadID = download_item->GetId();
  const BOOL isTerminal = download_item->IsCanceled() ||
      download_item->IsComplete() || download_item->IsInterrupted();
  if (isTerminal) {
    [runtime removeDownloadCallbackID:downloadID tabID:tab_id_];
  } else {
    [runtime registerDownloadCallback:callback downloadID:downloadID tabID:tab_id_];
  }

  NSString *filename = RexNSString(download_item->GetSuggestedFileName());
  if (!filename.length) filename = RexNSString(download_item->GetURL()).lastPathComponent;
  if (!filename.length) filename = @"下载文件";

  NSString *state = @"pending";
  if (download_item->IsCanceled()) {
    state = @"cancelled";
  } else if (download_item->IsComplete()) {
    state = @"completed";
  } else if (download_item->IsInterrupted()) {
    state = @"failed";
  } else if (download_item->IsInProgress()) {
    state = @"downloading";
  }

  const int64_t windowsEpochOffset = 11644473600LL;
  const int64_t startMicros = download_item->GetStartTime().val;
  const double createdAt = startMicros > 0
      ? (static_cast<double>(startMicros) / 1000000.0) - windowsEpochOffset
      : NSDate.date.timeIntervalSince1970;

  Emit(@"download", @{
    @"downloadID": @(downloadID),
    @"url": RexNSString(download_item->GetURL()),
    @"filename": filename,
    @"receivedBytes": @(download_item->GetReceivedBytes()),
    @"expectedBytes": @(download_item->GetTotalBytes()),
    @"state": state,
    @"createdAt": @(createdAt),
    @"fullPath": RexNSString(download_item->GetFullPath()),
    @"interruptReason": @((int)download_item->GetInterruptReason())
  });
}

void RexBrowserClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 int httpStatusCode) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame || !frame->IsValid()) return;
  if (frame->IsMain()) {
    Emit(@"loadEnd", @{ @"httpStatusCode": @(httpStatusCode) });
    EmitSecuritySnapshot(browser);
  }
}

void RexBrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   ErrorCode error_code,
                                   const CefString &error_text,
                                   const CefString &failed_url) {
  if (!frame->IsMain() || error_code == ERR_ABORTED) return;
  Emit(@"loadError", @{ @"code": @((int)error_code),
                        @"message": RexNSString(error_text),
                        @"url": RexNSString(failed_url) });
}

void RexBrowserClient::OnRenderProcessTerminated(
    CefRefPtr<CefBrowser> browser,
    TerminationStatus status,
    int error_code,
    const CefString &error_string) {
  EmitMediaAccess(false, false);
  Emit(@"crashed", @{ @"status": @((int)status),
                      @"code": @(error_code),
                      @"message": RexNSString(error_string) });
}

void RexBrowserClient::EmitMediaAccess(bool has_video_access,
                                       bool has_audio_access) {
  if (has_video_access_ == has_video_access &&
      has_audio_access_ == has_audio_access) {
    return;
  }
  has_video_access_ = has_video_access;
  has_audio_access_ = has_audio_access;
  Emit(@"mediaAccess", @{
    @"isActive": @(has_video_access || has_audio_access),
    @"hasVideoAccess": @(has_video_access),
    @"hasAudioAccess": @(has_audio_access)
  });
}

}  // namespace
