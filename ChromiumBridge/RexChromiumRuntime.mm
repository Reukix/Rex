#import "RexChromiumRuntime.h"

#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cctype>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <iterator>
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
#include "include/cef_command_handler.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_navigation_entry.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_preference.h"
#include "include/cef_request_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_ssl_info.h"
#include "include/cef_ssl_status.h"
#include "include/cef_task_manager.h"
#include "include/cef_version.h"
#include "include/cef_x509_certificate.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "RexExtensionReconcilePolicy.h"
#include "RexMessagePumpPolicy.h"
#include "RexNavigationPolicy.h"
#include "Privacy/RexThoriumFlags.h"
// Privacy engine types kept for shield UI policy storage only; request blocking is disabled.
#include "Privacy/RexPrivacyEngine.h"

#if !defined(ARCH_CPU_ARM64)
#error "Rex Chromium bridge supports Apple Silicon only."
#endif

NSErrorDomain const RexChromiumErrorDomain = @"com.rex.browser.chromium";
NSInteger const RexChromiumNormalExitProcessNotifiedCode =
    CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED;

BOOL RexChromiumErrorIsNormalEarlyExit(NSError *error) {
  return [error.domain isEqualToString:RexChromiumErrorDomain] &&
         error.code == RexChromiumNormalExitProcessNotifiedCode;
}

static void RexShutdownCEFAtProcessExit() {
  @autoreleasepool {
    [RexChromiumRuntime.shared shutdownAfterApplicationTermination];
  }
}

BOOL RexOrderAuxiliaryWindowFrontSafely(NSWindow *window) {
  if (!window) return NO;
  @try {
    // Keep the browser window key while revealing auxiliary UI. On macOS 27,
    // moving key status during this order operation can make ViewBridge notify
    // a CEF NSRemoteView in an invalid intermediate window state.
    [window orderFront:nil];
    return YES;
  } @catch (NSException *exception) {
    NSLog(@"[Rex] refused auxiliary window after AppKit exception %@: %@",
          exception.name, exception.reason ?: @"unknown reason");
    @try {
      [window orderOut:nil];
    } @catch (__unused NSException *cleanupException) {
    }
    return NO;
  }
}

typedef void (^RexDevToolsPipeCompletion)(
    NSDictionary<NSString *, id> *_Nullable result,
    NSError *_Nullable error);
typedef void (^RexExtensionQueryCompletion)(
    NSArray<NSDictionary<NSString *, id> *> *_Nullable extensions,
    NSError *_Nullable error);
typedef void (^RexExtensionOperationsCompletion)(NSError *_Nullable error);

@interface RexDevToolsPipeWriteRequest : NSObject

@property(nonatomic, copy) NSNumber *messageID;
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSData *payload;
@property(nonatomic) NSUInteger offset;

@end

@interface RexDevToolsPipeController : NSObject {
 @private
  BOOL _prepared;
  BOOL _reading;
  BOOL _stopped;
  BOOL _writeSourceSuspended;
  int _requestWriteFD;
  int _responseReadFD;
  BOOL _ownsChromiumFDs;
  uint64_t _nextMessageID;
  dispatch_queue_t _queue;
  dispatch_source_t _readSource;
  dispatch_source_t _writeSource;
  NSMutableData *_readBuffer;
  NSMutableDictionary<NSNumber *, RexDevToolsPipeCompletion> *_pending;
  NSMutableArray<RexDevToolsPipeWriteRequest *> *_outboundWrites;
}

@property(nonatomic, readonly, getter=isPrepared) BOOL prepared;

- (BOOL)prepareWithError:(NSError **)error;
- (void)startReading;
- (void)executeMethod:(NSString *)method
               params:(NSDictionary<NSString *, id> *)params
           completion:(RexDevToolsPipeCompletion)completion;
- (void)shutdown;
- (void)releaseChromiumDescriptors;

@end

@interface RexExtensionSyncRequest : NSObject

@property(nonatomic, copy) NSArray<NSString *> *managedPaths;
@property(nonatomic, copy) NSArray<NSString *> *desiredPaths;
@property(nonatomic, copy) NSArray<NSString *> *removedPaths;
@property(nonatomic, copy) NSArray<NSString *> *previousManagedPaths;
@property(nonatomic, copy) NSArray<NSString *> *previousPaths;
@property(nonatomic, copy) NSArray<NSString *> *fingerprintUpdatedPaths;
@property(nonatomic, copy) NSArray<NSString *> *updatedPaths;
@property(nonatomic, copy) NSArray<NSString *> *forcedReloadPaths;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *>
        *expectedManifestMetadataByPath;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSString *> *expectedFingerprintsByPath;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *expectedExtensionIDsByPath;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSString *> *previousExtensionIDsByPath;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger chromeWindowHostEpoch;
@property(nonatomic) BOOL startup;
@property(nonatomic) BOOL attemptedMutation;
@property(nonatomic, copy, nullable)
    RexChromiumExtensionRuntimeCompletion completion;

@end

@interface RexChromiumRuntime (ExtensionRuntimePrivate)

- (void)chromiumContextInitialized;
- (void)managedExtensionOperationDidFinishWithToken:(uint64_t)token
                                        errorMessage:(nullable NSString *)message;
- (void)managedExtensionConfigurationOperationDidFinishWithToken:
            (uint64_t)token
                                                      payload:
                                                          (nullable NSString *)payload
                                                 errorMessage:
                                                     (nullable NSString *)message;

@end

typedef NS_ENUM(NSInteger, RexDeveloperToolsEditingCommand) {
  RexDeveloperToolsEditingCommandNone,
  RexDeveloperToolsEditingCommandUndo,
  RexDeveloperToolsEditingCommandRedo,
  RexDeveloperToolsEditingCommandCut,
  RexDeveloperToolsEditingCommandCopy,
  RexDeveloperToolsEditingCommandPaste,
  RexDeveloperToolsEditingCommandPasteAndMatchStyle,
  RexDeveloperToolsEditingCommandDelete,
  RexDeveloperToolsEditingCommandSelectAll,
};

@interface RexChromiumRuntime (DeveloperToolsEditingPrivate)

- (BOOL)handleDeveloperToolsEditingShortcutForEvent:(NSEvent *)event;
- (BOOL)executeDeveloperToolsEditingCommand:
            (RexDeveloperToolsEditingCommand)command
                                      tabID:(NSString *)tabID;

@end

namespace {

std::atomic<uint64_t> gRexNavigationGeneration{0};

constexpr NSUInteger kRexMaximumExtensionConfigurationJSONBytes =
    256 * 1024;
constexpr size_t kRexMaximumEncodedExtensionConfigurationBytes =
    1024 * 1024;
constexpr NSUInteger kRexMaximumExtensionConfigurationHosts = 4096;
constexpr NSUInteger kRexMaximumExtensionConfigurationHostBytes = 8192;
constexpr NSUInteger kRexMaximumExtensionConfigurationErrorBytes = 4096;
constexpr char kRexManagedExtensionResultPrefix[] =
    "__REX_MANAGED_EXTENSION_RESULT__:";
constexpr char kRexManagedExtensionConfigurationResultPrefix[] =
    "__REX_MANAGED_EXTENSION_CONFIGURATION_RESULT__:";
NSString *const kRexInternalDownloadUIExtensionName =
    @"RexDownloadUIController";

NSString *RexNSString(const CefString &value) {
  return [[NSString alloc] initWithUTF8String:value.ToString().c_str()] ?: @"";
}

bool RexCanForwardPopupURL(NSString *value) {
  if (!value.length) return false;
  NSURLComponents *components =
      [NSURLComponents componentsWithString:value];
  NSString *scheme = components.scheme.lowercaseString;
  if (!scheme.length || components.user.length || components.password.length) {
    return false;
  }
  return [scheme isEqualToString:@"http"] ||
         [scheme isEqualToString:@"https"] ||
         [scheme isEqualToString:@"about"] ||
         [scheme isEqualToString:@"chrome-extension"];
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

NSString *RexJavaScriptStringLiteral(NSString *value) {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value ?: @""
                                                 options:NSJSONWritingFragmentsAllowed
                                                   error:&error];
  if (!data || error) return @"\"\"";
  return [[NSString alloc] initWithData:data
                               encoding:NSUTF8StringEncoding] ?: @"\"\"";
}

NSError *RexExtensionRuntimeError(
    NSInteger code,
    NSString *description,
    NSDictionary<NSString *, id> *details = @{}) {
  NSMutableDictionary<NSString *, id> *userInfo = [details mutableCopy];
  userInfo[NSLocalizedDescriptionKey] = description;
  return [NSError errorWithDomain:RexChromiumErrorDomain
                             code:code
                         userInfo:userInfo];
}

bool RexIsValidChromiumExtensionID(NSString *value) {
  if (![value isKindOfClass:NSString.class] || value.length != 32) return false;
  for (NSUInteger index = 0; index < value.length; ++index) {
    const unichar character = [value characterAtIndex:index];
    if (character < 'a' || character > 'p') return false;
  }
  return true;
}

bool RexIsJSONBoolean(id value) {
  return value &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

bool RexIsValidExtensionHostAccess(NSString *value) {
  return [value isEqualToString:@"ON_CLICK"] ||
         [value isEqualToString:@"ON_SPECIFIC_SITES"] ||
         [value isEqualToString:@"ON_ALL_SITES"];
}

bool RexIsBoundedExtensionConfigurationHost(NSString *value) {
  return [value isKindOfClass:NSString.class] && value.length > 0 &&
      [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <=
          kRexMaximumExtensionConfigurationHostBytes &&
      [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location == NSNotFound;
}

NSString *_Nullable RexJavaScriptJSONObjectLiteral(
    NSDictionary<NSString *, id> *value) {
  if (![NSJSONSerialization isValidJSONObject:value]) return nil;
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                 options:0
                                                   error:&error];
  if (!data || error || data.length > 4096) return nil;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSDictionary<NSString *, id> *_Nullable
RexValidatedExtensionConfigurationResult(
    id value,
    NSString *expected_extension_id,
    NSError **validation_error) {
  if (![value isKindOfClass:NSDictionary.class]) {
    if (validation_error) {
      *validation_error = RexExtensionRuntimeError(
          54, @"Chromium 返回了无效的扩展配置对象");
    }
    return nil;
  }

  NSDictionary<NSString *, id> *raw =
      static_cast<NSDictionary<NSString *, id> *>(value);
  NSString *extensionID = [raw[@"extensionID"] isKindOfClass:NSString.class]
      ? raw[@"extensionID"]
      : nil;
  NSArray<NSString *> *requiredBooleanKeys = @[
    @"isEnabled", @"userMayModify",
    @"userScriptsAvailable", @"userScriptsAllowed",
    @"fileAccessAvailable", @"fileAccessAllowed",
    @"incognitoAccessAvailable", @"incognitoAccessAllowed"
  ];
  NSMutableArray<NSString *> *invalidFields = [NSMutableArray array];
  if (!RexIsValidChromiumExtensionID(extensionID) ||
      ![extensionID isEqualToString:expected_extension_id]) {
    [invalidFields addObject:@"extensionID"];
  }
  for (NSString *key in requiredBooleanKeys) {
    if (!RexIsJSONBoolean(raw[key])) [invalidFields addObject:key];
  }

  const BOOL hasHostAccess = raw[@"hostAccess"] != nil ||
      raw[@"hasAllHosts"] != nil || raw[@"hosts"] != nil;
  NSMutableArray<NSDictionary<NSString *, id> *> *normalizedHosts = nil;
  NSString *hostAccess = nil;
  NSNumber *hasAllHosts = nil;
  if (hasHostAccess) {
    hostAccess = [raw[@"hostAccess"] isKindOfClass:NSString.class]
        ? raw[@"hostAccess"]
        : nil;
    hasAllHosts = RexIsJSONBoolean(raw[@"hasAllHosts"])
        ? raw[@"hasAllHosts"]
        : nil;
    NSArray *hosts = [raw[@"hosts"] isKindOfClass:NSArray.class]
        ? raw[@"hosts"]
        : nil;
    if (!RexIsValidExtensionHostAccess(hostAccess)) {
      [invalidFields addObject:@"hostAccess"];
    }
    if (!hasAllHosts) [invalidFields addObject:@"hasAllHosts"];
    if (!hosts || hosts.count > kRexMaximumExtensionConfigurationHosts) {
      [invalidFields addObject:@"hosts"];
    } else {
      normalizedHosts = [NSMutableArray arrayWithCapacity:hosts.count];
      NSMutableSet<NSString *> *seenHosts = [NSMutableSet set];
      for (id candidate in hosts) {
        if (![candidate isKindOfClass:NSDictionary.class]) {
          [invalidFields addObject:@"hosts"];
          break;
        }
        NSDictionary *hostValue = static_cast<NSDictionary *>(candidate);
        NSString *host = [hostValue[@"host"] isKindOfClass:NSString.class]
            ? hostValue[@"host"]
            : nil;
        NSNumber *granted = RexIsJSONBoolean(hostValue[@"granted"])
            ? hostValue[@"granted"]
            : nil;
        if (!RexIsBoundedExtensionConfigurationHost(host) || !granted ||
            [seenHosts containsObject:host]) {
          [invalidFields addObject:@"hosts"];
          break;
        }
        [seenHosts addObject:host];
        [normalizedHosts addObject:@{@"host": host, @"granted": granted}];
      }
    }
  }

  if (invalidFields.count) {
    if (validation_error) {
      *validation_error = RexExtensionRuntimeError(
          54,
          @"Chromium 返回的扩展配置字段无效",
          @{@"invalidFields": [[NSOrderedSet orderedSetWithArray:invalidFields]
                                    array]});
    }
    return nil;
  }

  NSMutableDictionary<NSString *, id> *result = [@{
    @"extensionID": extensionID,
    @"isEnabled": raw[@"isEnabled"],
    @"userMayModify": raw[@"userMayModify"],
    @"userScriptsAvailable": raw[@"userScriptsAvailable"],
    @"userScriptsAllowed": raw[@"userScriptsAllowed"],
    @"fileAccessAvailable": raw[@"fileAccessAvailable"],
    @"fileAccessAllowed": raw[@"fileAccessAllowed"],
    @"incognitoAccessAvailable": raw[@"incognitoAccessAvailable"],
    @"incognitoAccessAllowed": raw[@"incognitoAccessAllowed"]
  } mutableCopy];
  if (hasHostAccess) {
    result[@"hostAccess"] = hostAccess;
    result[@"hasAllHosts"] = hasAllHosts;
    result[@"hosts"] = [normalizedHosts copy];
  }
  return [result copy];
}

NSDictionary<NSString *, id> *_Nullable
RexExtensionConfigurationFromPayload(
    NSString *payload,
    NSString *expected_extension_id,
    NSError **result_error) {
  NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
  if (!data.length ||
      data.length > kRexMaximumExtensionConfigurationJSONBytes) {
    if (result_error) {
      *result_error = RexExtensionRuntimeError(
          54, @"Chromium 返回的扩展配置数据大小无效");
    }
    return nil;
  }

  NSError *jsonError = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:&jsonError];
  if (jsonError || ![object isKindOfClass:NSDictionary.class]) {
    if (result_error) {
      *result_error = RexExtensionRuntimeError(
          54, @"Chromium 返回的扩展配置 JSON 无效");
    }
    return nil;
  }
  NSDictionary<NSString *, id> *envelope =
      static_cast<NSDictionary<NSString *, id> *>(object);
  if (!RexIsJSONBoolean(envelope[@"ok"])) {
    if (result_error) {
      *result_error = RexExtensionRuntimeError(
          54, @"Chromium 返回的扩展配置结果缺少状态");
    }
    return nil;
  }
  if (![envelope[@"ok"] boolValue]) {
    NSString *nativeError =
        [envelope[@"error"] isKindOfClass:NSString.class]
            ? envelope[@"error"]
            : @"unknown error";
    if ([nativeError lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
        kRexMaximumExtensionConfigurationErrorBytes) {
      nativeError = @"Chromium extension configuration error was too large";
    }
    if (result_error) {
      *result_error = RexExtensionRuntimeError(
          56,
          @"Chromium 扩展配置操作失败",
          @{@"nativeError": nativeError});
    }
    return nil;
  }
  return RexValidatedExtensionConfigurationResult(
      envelope[@"result"], expected_extension_id, result_error);
}

NSString *_Nullable RexExtensionConfigurationOperationScript(
    NSString *extension_id,
    NSDictionary<NSString *, id> *_Nullable update,
    NSString *_Nullable site_permission_host,
    NSNumber *_Nullable site_permission_granted,
    uint64_t token) {
  NSString *extensionIDLiteral = RexJavaScriptStringLiteral(extension_id);
  NSString *updateStatement = @"";
  if (update) {
    NSString *updateLiteral = RexJavaScriptJSONObjectLiteral(update);
    if (!updateLiteral.length) return nil;
    updateStatement = [NSString stringWithFormat:
        @"if (typeof chrome.developerPrivate.updateExtensionConfiguration "
         "!== 'function') { throw new Error('chrome.developerPrivate "
         "updateExtensionConfiguration unavailable'); } "
         "await chrome.developerPrivate.updateExtensionConfiguration(%@); ",
        updateLiteral];
  }
  NSString *sitePermissionStatement = @"";
  if (site_permission_host && site_permission_granted) {
    NSString *hostLiteral = RexJavaScriptStringLiteral(site_permission_host);
    NSString *method = site_permission_granted.boolValue
        ? @"addHostPermission"
        : @"removeHostPermission";
    sitePermissionStatement = [NSString stringWithFormat:
        @"if (typeof chrome.developerPrivate.%@ !== 'function') { "
         "throw new Error('chrome.developerPrivate %@ unavailable'); } "
         "await chrome.developerPrivate.%@(%@, %@); ",
        method, method, method, extensionIDLiteral, hostLiteral];
  }

  return [NSString stringWithFormat:
      @"(() => { "
       "let completed = false; "
       "const prefix = "
       "'__REX_MANAGED_EXTENSION_CONFIGURATION_RESULT__:%llu:'; "
       "const report = (envelope) => { "
       "if (completed) return; "
       "let json = JSON.stringify(envelope); "
       "if (json.length > %lu) { "
       "json = JSON.stringify({ok: false, error: "
       "'extension configuration result exceeds limit'}); "
       "} "
       "completed = true; "
       "console.info(prefix + encodeURIComponent(json)); "
       "}; "
       "const fail = (error) => { "
       "let message = error && typeof error.message === 'string' "
       "? error.message : String(error || 'unknown error'); "
       "if (message.length > %lu) message = message.slice(0, %lu); "
       "report({ok: false, error: message}); "
       "}; "
       "const access = (info, key, prefixName, result) => { "
       "const value = info[key]; "
       "if (!value || typeof value.isEnabled !== 'boolean' || "
       "typeof value.isActive !== 'boolean') { "
       "throw new Error('invalid ' + key + ' access modifier'); "
       "} "
       "result[prefixName + 'Available'] = value.isEnabled; "
       "result[prefixName + 'Allowed'] = value.isActive; "
       "}; "
       "const normalize = (info, expectedID) => { "
       "if (!info || typeof info !== 'object' || info.id !== expectedID) { "
       "throw new Error('invalid extension configuration identity'); "
       "} "
       "if (!['ENABLED', 'DISABLED', 'TERMINATED', 'BLOCKLISTED']"
       ".includes(info.state) || typeof info.userMayModify !== 'boolean') { "
       "throw new Error('invalid extension configuration state'); "
       "} "
       "const result = {extensionID: info.id, "
       "isEnabled: info.state === 'ENABLED', "
       "userMayModify: info.userMayModify}; "
       "access(info, 'userScriptsAccess', 'userScripts', result); "
       "access(info, 'fileAccess', 'fileAccess', result); "
       "access(info, 'incognitoAccess', 'incognitoAccess', result); "
       "const runtimePermissions = info.permissions && "
       "info.permissions.runtimeHostPermissions; "
       "if (runtimePermissions !== undefined && runtimePermissions !== null) { "
       "if (!['ON_CLICK', 'ON_SPECIFIC_SITES', 'ON_ALL_SITES']"
       ".includes(runtimePermissions.hostAccess) || "
       "typeof runtimePermissions.hasAllHosts !== 'boolean' || "
       "!Array.isArray(runtimePermissions.hosts) || "
       "runtimePermissions.hosts.length > %lu) { "
       "throw new Error('invalid runtime host permissions'); "
       "} "
       "const hosts = runtimePermissions.hosts.map((entry) => { "
       "if (!entry || typeof entry.host !== 'string' || !entry.host.length || "
       "entry.host.length > %lu || typeof entry.granted !== 'boolean') { "
       "throw new Error('invalid runtime host permission entry'); "
       "} "
       "return {host: entry.host, granted: entry.granted}; "
       "}); "
       "hosts.sort((left, right) => left.host < right.host ? -1 : "
       "left.host > right.host ? 1 : 0); "
       "result.hostAccess = runtimePermissions.hostAccess; "
       "result.hasAllHosts = runtimePermissions.hasAllHosts; "
       "result.hosts = hosts; "
       "} "
       "return result; "
       "}; "
       "(async () => { "
       "if (!globalThis.chrome || !chrome.developerPrivate || "
       "typeof chrome.developerPrivate.getExtensionInfo !== 'function') { "
       "throw new Error('chrome.developerPrivate getExtensionInfo unavailable'); "
       "} "
       "const extensionID = %@; "
       "%@%@"
       "const info = await chrome.developerPrivate.getExtensionInfo(extensionID); "
       "report({ok: true, result: normalize(info, extensionID)}); "
       "})().catch(fail); "
       "})();",
      static_cast<unsigned long long>(token),
      static_cast<unsigned long>(kRexMaximumExtensionConfigurationJSONBytes),
      static_cast<unsigned long>(kRexMaximumExtensionConfigurationErrorBytes),
      static_cast<unsigned long>(kRexMaximumExtensionConfigurationErrorBytes),
      static_cast<unsigned long>(kRexMaximumExtensionConfigurationHosts),
      static_cast<unsigned long>(kRexMaximumExtensionConfigurationHostBytes),
      extensionIDLiteral, updateStatement, sitePermissionStatement];
}


NSDictionary<NSString *, NSString *> *RexExtensionManifestMetadata(
    NSString *path);

enum class RexExtensionPathValidationPurpose {
  kManagedPackage,
  kRemoval
};

constexpr bool RexExtensionPathRequiresManifest(
    RexExtensionPathValidationPurpose purpose) {
  return purpose == RexExtensionPathValidationPurpose::kManagedPackage;
}

static_assert(RexExtensionPathRequiresManifest(
    RexExtensionPathValidationPurpose::kManagedPackage));
static_assert(!RexExtensionPathRequiresManifest(
    RexExtensionPathValidationPurpose::kRemoval));

NSArray<NSString *> *_Nullable RexValidatedExtensionPathsForPurpose(
    NSArray<NSString *> *extension_paths,
    RexExtensionPathValidationPurpose purpose,
    NSError **validation_error) {
  NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
  NSMutableArray<NSString *> *rejected = [NSMutableArray array];
  for (id candidate in extension_paths) {
    if (![candidate isKindOfClass:NSString.class]) {
      [rejected addObject:@"<non-string>"];
      continue;
    }
    NSString *path = static_cast<NSString *>(candidate);
    if (!path.length || !path.isAbsolutePath) {
      [rejected addObject:path.length ? path : @"<empty>"];
      continue;
    }
    NSString *resolved = path.stringByStandardizingPath
                             .stringByResolvingSymlinksInPath
                             .stringByStandardizingPath;
    BOOL is_directory = NO;
    NSString *manifest =
        [resolved stringByAppendingPathComponent:@"manifest.json"];
    const bool requiresManifest = RexExtensionPathRequiresManifest(purpose);
    if (!resolved.length || !resolved.isAbsolutePath ||
        [resolved containsString:@","] ||
        (requiresManifest &&
         (![NSFileManager.defaultManager fileExistsAtPath:resolved
                                               isDirectory:&is_directory] ||
          !is_directory ||
          ![NSFileManager.defaultManager isReadableFileAtPath:manifest] ||
          !RexExtensionManifestMetadata(resolved)[@"version"].length))) {
      [rejected addObject:path];
      continue;
    }
    [paths addObject:resolved];
  }
  if (rejected.count) {
    if (validation_error) {
      *validation_error = RexExtensionRuntimeError(
          33,
          RexExtensionPathRequiresManifest(purpose)
              ? @"扩展同步请求包含无效或已移除的包路径"
              : @"扩展删除请求包含无效路径",
          @{@"rejectedPaths": [rejected copy]});
    }
    return nil;
  }
  return [[paths array] sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *_Nullable RexValidatedExtensionPaths(
    NSArray<NSString *> *extension_paths,
    NSError **validation_error) {
  return RexValidatedExtensionPathsForPurpose(
      extension_paths,
      RexExtensionPathValidationPurpose::kManagedPackage,
      validation_error);
}

NSString *_Nullable RexInternalDownloadUIExtensionPath(
    NSError **validation_error) {
  NSURL *resourceURL = [[NSBundle mainBundle]
      URLForResource:kRexInternalDownloadUIExtensionName
       withExtension:nil
        subdirectory:@"InternalExtensions"];
  NSString *path = resourceURL.path.stringByStandardizingPath
                         .stringByResolvingSymlinksInPath
                         .stringByStandardizingPath;
  NSArray<NSString *> *validated = path.length
      ? RexValidatedExtensionPaths(@[path], validation_error)
      : nil;
  if (!validated.count) {
    if (validation_error && !*validation_error) {
      *validation_error = RexExtensionRuntimeError(
          34, @"Rex 内部 Chromium 下载 UI 控制扩展缺失");
    }
    return nil;
  }
  return validated.firstObject;
}

NSArray<NSString *> *RexPathsIncludingInternalDownloadUIExtension(
    NSArray<NSString *> *paths,
    NSString *internal_path) {
  NSMutableOrderedSet<NSString *> *result =
      [NSMutableOrderedSet orderedSetWithArray:paths ?: @[]];
  if (internal_path.length) [result addObject:internal_path];
  return [[result array] sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *_Nullable RexValidatedRemovedExtensionPaths(
    NSArray<NSString *> *extension_paths,
    NSError **validation_error) {
  return RexValidatedExtensionPathsForPurpose(
      extension_paths,
      RexExtensionPathValidationPurpose::kRemoval,
      validation_error);
}

NSString *RexExtensionPathFingerprint(NSString *path) {
  struct stat directory_stat = {};
  struct stat manifest_stat = {};
  const std::string directory_path = RexUTF8(path);
  const std::string manifest_path =
      directory_path + "/manifest.json";
  if (stat(directory_path.c_str(), &directory_stat) != 0 ||
      stat(manifest_path.c_str(), &manifest_stat) != 0) {
    return @"";
  }
  return [NSString
      stringWithFormat:@"%llu:%llu:%lld:%lld:%ld|%llu:%llu:%lld:%lld:%ld",
                       static_cast<unsigned long long>(directory_stat.st_dev),
                       static_cast<unsigned long long>(directory_stat.st_ino),
                       static_cast<long long>(directory_stat.st_size),
                       static_cast<long long>(directory_stat.st_mtimespec.tv_sec),
                       directory_stat.st_mtimespec.tv_nsec,
                       static_cast<unsigned long long>(manifest_stat.st_dev),
                       static_cast<unsigned long long>(manifest_stat.st_ino),
                       static_cast<long long>(manifest_stat.st_size),
                       static_cast<long long>(manifest_stat.st_mtimespec.tv_sec),
                       manifest_stat.st_mtimespec.tv_nsec];
}

NSString *RexExtensionIDFromManifestKey(NSString *encoded_key) {
  if (!encoded_key.length) return @"";
  NSData *key = [[NSData alloc]
      initWithBase64EncodedString:encoded_key
                         options:NSDataBase64DecodingIgnoreUnknownCharacters];
  if (!key.length || key.length > UINT_MAX) return @"";
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(key.bytes, static_cast<CC_LONG>(key.length), digest);
  char identifier[33] = {};
  for (NSUInteger index = 0; index < 16; ++index) {
    identifier[index * 2] = static_cast<char>('a' + (digest[index] >> 4));
    identifier[index * 2 + 1] =
        static_cast<char>('a' + (digest[index] & 0x0f));
  }
  return [[NSString alloc] initWithBytes:identifier
                                 length:32
                               encoding:NSASCIIStringEncoding] ?: @"";
}

NSDictionary<NSString *, NSString *> *RexExtensionManifestMetadata(
    NSString *path) {
  NSString *manifestPath =
      [path stringByAppendingPathComponent:@"manifest.json"];
  NSError *readError = nil;
  NSData *data = [NSData dataWithContentsOfFile:manifestPath
                                       options:NSDataReadingMappedIfSafe
                                         error:&readError];
  if (!data.length || data.length > 4 * 1024 * 1024) return @{};
  id decoded = [NSJSONSerialization JSONObjectWithData:data
                                               options:0
                                                 error:nil];
  if (![decoded isKindOfClass:NSDictionary.class]) return @{};
  NSDictionary<NSString *, id> *manifest =
      static_cast<NSDictionary<NSString *, id> *>(decoded);
  NSString *version = [manifest[@"version"] isKindOfClass:NSString.class]
      ? manifest[@"version"]
      : nil;
  if (!version.length) return @{};

  NSMutableDictionary<NSString *, NSString *> *metadata =
      [@{@"version": version} mutableCopy];
  NSString *encodedKey = [manifest[@"key"] isKindOfClass:NSString.class]
      ? manifest[@"key"]
      : nil;
  NSString *identifier = RexExtensionIDFromManifestKey(encodedKey);
  if (identifier.length) metadata[@"id"] = identifier;
  return [metadata copy];
}

NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *
RexExtensionManifestMetadataByPath(NSArray<NSString *> *paths) {
  NSMutableDictionary<
      NSString *,
      NSDictionary<NSString *, NSString *> *> *metadata =
      [NSMutableDictionary dictionaryWithCapacity:paths.count];
  for (NSString *path in paths) {
    metadata[path] = RexExtensionManifestMetadata(path);
  }
  return [metadata copy];
}

NSArray<NSString *> *RexUpdatedExtensionPaths(
    NSArray<NSString *> *desired_paths,
    NSDictionary<NSString *, NSString *> *known_fingerprints,
    NSDictionary<NSString *, NSString *> *current_fingerprints,
    BOOL detect_updates) {
  if (!detect_updates) return @[];
  NSMutableArray<NSString *> *updated = [NSMutableArray array];
  for (NSString *path in desired_paths) {
    NSString *known = known_fingerprints[path];
    NSString *current = current_fingerprints[path];
    if (known.length && current.length && ![known isEqualToString:current]) {
      [updated addObject:path];
    }
  }
  return [updated copy];
}

NSDictionary<NSString *, NSString *> *RexExtensionPathFingerprintsByPath(
    NSArray<NSString *> *paths) {
  NSMutableDictionary<NSString *, NSString *> *fingerprints =
      [NSMutableDictionary dictionaryWithCapacity:paths.count];
  for (NSString *path in paths) {
    NSString *fingerprint = RexExtensionPathFingerprint(path);
    if (fingerprint.length) fingerprints[path] = fingerprint;
  }
  return [fingerprints copy];
}

bool RexURLWaitsForExtensionRuntime(NSString *value) {
  NSString *scheme =
      [NSURLComponents componentsWithString:value].scheme.lowercaseString;
  return [scheme isEqualToString:@"http"] ||
         [scheme isEqualToString:@"https"] ||
         [scheme isEqualToString:@"chrome-extension"];
}

bool RexIsChromeExtensionsURL(NSString *value) {
  NSURLComponents *components =
      [NSURLComponents componentsWithString:value];
  return [components.scheme.lowercaseString isEqualToString:@"chrome"] &&
         [components.host.lowercaseString isEqualToString:@"extensions"] &&
         components.user.length == 0 && components.password.length == 0 &&
         components.port == nil;
}

bool RexIsHTTPOrHTTPSURL(NSString *value) {
  NSString *scheme =
      [NSURLComponents componentsWithString:value].scheme.lowercaseString;
  return [scheme isEqualToString:@"http"] ||
         [scheme isEqualToString:@"https"];
}

bool RexShouldUseEmbeddedChromeRuntime(NSString *value,
                                       BOOL private_browsing) {
  return RexIsChromeExtensionsURL(value) ||
         (!private_browsing && RexIsHTTPOrHTTPSURL(value));
}

constexpr bool RexShouldAcceptManagedExtensionFolderDialog(
    bool operation_pending,
    bool script_dispatched,
    bool folder_dialog_consumed,
    int browser_id,
    int extension_host_browser_id,
    cef_file_dialog_mode_t mode) {
  return operation_pending && script_dispatched &&
      !folder_dialog_consumed && browser_id != 0 &&
      browser_id == extension_host_browser_id &&
      (mode == FILE_DIALOG_OPEN_FOLDER || mode == FILE_DIALOG_OPEN);
}

static_assert(RexShouldAcceptManagedExtensionFolderDialog(
    true, true, false, 7, 7, FILE_DIALOG_OPEN_FOLDER));
static_assert(!RexShouldAcceptManagedExtensionFolderDialog(
    true, true, false, 7, 8, FILE_DIALOG_OPEN_FOLDER));
static_assert(!RexShouldAcceptManagedExtensionFolderDialog(
    true, false, false, 7, 7, FILE_DIALOG_OPEN_FOLDER));
// CEF may map Chromium's SELECT_EXISTING_FOLDER to FILE_DIALOG_OPEN. Accept
// that compatibility mode only inside the token-bound hidden host operation.
static_assert(RexShouldAcceptManagedExtensionFolderDialog(
    true, true, false, 7, 7, FILE_DIALOG_OPEN));
static_assert(!RexShouldAcceptManagedExtensionFolderDialog(
    true, true, false, 7, 7, FILE_DIALOG_OPEN_MULTIPLE));

constexpr bool RexShouldReleaseExtensionStartupBarrier(
    bool barrier_active,
    size_t queued_sync_count) {
  return barrier_active && queued_sync_count == 0;
}

static_assert(RexShouldReleaseExtensionStartupBarrier(true, 0));
static_assert(!RexShouldReleaseExtensionStartupBarrier(true, 1));
static_assert(!RexShouldReleaseExtensionStartupBarrier(false, 0));

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
RexLiveExtensionsByPath(
    NSArray<NSDictionary<NSString *, id> *> *extensions) {
  NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *result =
      [NSMutableDictionary dictionaryWithCapacity:extensions.count];
  for (NSDictionary<NSString *, id> *extension in extensions) {
    NSString *path = [extension[@"path"] isKindOfClass:NSString.class]
        ? extension[@"path"]
        : nil;
    if (!path.length) continue;
    result[path] = extension;
  }
  return result;
}

NSArray<NSString *> *RexLiveExtensionPaths(
    NSArray<NSDictionary<NSString *, id> *> *extensions) {
  NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
  for (NSDictionary<NSString *, id> *extension in extensions) {
    NSString *path = [extension[@"path"] isKindOfClass:NSString.class]
        ? extension[@"path"]
        : nil;
    if (path.length && [extension[@"enabled"] boolValue]) [paths addObject:path];
  }
  return [[paths array] sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *RexLiveExtensionIDs(
    NSArray<NSDictionary<NSString *, id> *> *extensions) {
  NSMutableOrderedSet<NSString *> *identifiers =
      [NSMutableOrderedSet orderedSet];
  for (NSDictionary<NSString *, id> *extension in extensions) {
    NSString *identifier = [extension[@"id"] isKindOfClass:NSString.class]
        ? extension[@"id"]
        : nil;
    if (identifier.length && [extension[@"enabled"] boolValue]) {
      [identifiers addObject:identifier];
    }
  }
  return [[identifiers array] sortedArrayUsingSelector:@selector(compare:)];
}

NSError *RexVerifyManagedExtensionSet(
    NSArray<NSString *> *managed_paths,
    NSArray<NSString *> *enabled_paths,
    NSSet<NSString *> *removed_paths,
    NSArray<NSDictionary<NSString *, id> *> *extensions,
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *>
        *manifest_metadata_by_path,
    NSDictionary<NSString *, NSString *> *expected_ids_by_path,
    NSUInteger generation) {
  NSDictionary<NSString *, NSDictionary<NSString *, id> *> *by_path =
      RexLiveExtensionsByPath(extensions);
  NSSet<NSString *> *managed = [NSSet setWithArray:managed_paths];
  NSSet<NSString *> *enabled = [NSSet setWithArray:enabled_paths];
  NSMutableArray<NSString *> *missing = [NSMutableArray array];
  NSMutableArray<NSString *> *disabled = [NSMutableArray array];
  NSMutableArray<NSString *> *unexpectedlyEnabled = [NSMutableArray array];
  NSMutableArray<NSString *> *notRemoved = [NSMutableArray array];
  NSMutableArray<NSString *> *invalidManifests = [NSMutableArray array];
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *idMismatches =
      [NSMutableArray array];
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *versionMismatches =
      [NSMutableArray array];
  for (NSString *path in managed_paths) {
    NSDictionary<NSString *, id> *extension = by_path[path];
    if (!extension) {
      [missing addObject:path];
      continue;
    }
    const BOOL shouldBeEnabled = [enabled containsObject:path];
    const BOOL isEnabled = [extension[@"enabled"] boolValue];
    if (shouldBeEnabled && !isEnabled) {
      [disabled addObject:path];
    } else if (!shouldBeEnabled && isEnabled) {
      [unexpectedlyEnabled addObject:path];
    }

    NSDictionary<NSString *, NSString *> *manifestMetadata =
        manifest_metadata_by_path[path];
    NSString *expectedVersion = manifestMetadata[@"version"];
    if (!expectedVersion.length) {
      [invalidManifests addObject:path];
    } else if (shouldBeEnabled) {
      NSString *actualVersion = extension[@"version"];
      if (![actualVersion isEqualToString:expectedVersion]) {
        [versionMismatches addObject:@{
          @"path": path,
          @"expected": expectedVersion,
          @"actual": actualVersion ?: @""
        }];
      }
    }

    NSString *expectedID =
        manifestMetadata[@"id"] ?: expected_ids_by_path[path];
    NSString *actualID = extension[@"id"];
    if (!actualID.length ||
        (expectedID.length && ![actualID isEqualToString:expectedID])) {
      [idMismatches addObject:@{
        @"path": path,
        @"expected": expectedID ?: @"",
        @"actual": actualID ?: @""
      }];
    }
  }

  for (NSString *path in removed_paths) {
    if (by_path[path]) [notRemoved addObject:path];
  }

  NSMutableDictionary<NSString *, NSNumber *> *pathCounts =
      [NSMutableDictionary dictionary];
  for (NSDictionary<NSString *, id> *extension in extensions) {
    NSString *path = extension[@"path"];
    if (!path.length || ![managed containsObject:path]) continue;
    pathCounts[path] = @([pathCounts[path] unsignedIntegerValue] + 1);
  }
  NSMutableArray<NSString *> *duplicatePaths = [NSMutableArray array];
  for (NSString *path in pathCounts) {
    if (pathCounts[path].unsignedIntegerValue > 1) {
      [duplicatePaths addObject:path];
    }
  }
  [notRemoved sortUsingSelector:@selector(compare:)];
  [duplicatePaths sortUsingSelector:@selector(compare:)];

  if (!missing.count && !disabled.count && !unexpectedlyEnabled.count &&
      !notRemoved.count && !invalidManifests.count && !idMismatches.count &&
      !versionMismatches.count && !duplicatePaths.count) {
    return nil;
  }
  return RexExtensionRuntimeError(
      40,
      @"Chromium 扩展运行时与请求的扩展身份集合不一致",
      @{
        @"generation": @(generation),
        @"missingPaths": missing,
        @"disabledPaths": disabled,
        @"unexpectedlyEnabledPaths": unexpectedlyEnabled,
        @"notRemovedPaths": notRemoved,
        @"invalidManifestPaths": invalidManifests,
        @"idMismatches": idMismatches,
        @"versionMismatches": versionMismatches,
        @"duplicatePaths": duplicatePaths,
        @"loadedPaths": RexLiveExtensionPaths(extensions)
      });
}

NSArray<NSDictionary<NSString *, id> *> *RexExtensionReconcileOperations(
    NSArray<NSDictionary<NSString *, id> *> *extensions,
    NSArray<NSString *> *managed_paths,
    NSArray<NSString *> *enabled_paths,
    NSSet<NSString *> *removed_paths,
    NSSet<NSString *> *updated_paths,
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *>
        *manifest_metadata_by_path) {
  NSDictionary<NSString *, NSDictionary<NSString *, id> *> *by_path =
      RexLiveExtensionsByPath(extensions);
  NSSet<NSString *> *managed = [NSSet setWithArray:managed_paths];
  NSSet<NSString *> *enabled = [NSSet setWithArray:enabled_paths];
  BOOL (^hasIdentityMismatch)(
      NSString *, NSDictionary<NSString *, id> *) =
      ^BOOL(NSString *path, NSDictionary<NSString *, id> *extension) {
    NSString *expectedID = manifest_metadata_by_path[path][@"id"];
    return expectedID.length &&
        ![extension[@"id"] isEqualToString:expectedID];
  };
  BOOL (^requiresReload)(
      NSString *, NSDictionary<NSString *, id> *) =
      ^BOOL(NSString *path, NSDictionary<NSString *, id> *extension) {
    NSString *expectedVersion =
        manifest_metadata_by_path[path][@"version"];
    return [updated_paths containsObject:path] ||
        (expectedVersion.length &&
         ![extension[@"version"] isEqualToString:expectedVersion]);
  };

  NSMutableArray<NSDictionary<NSString *, id> *> *uninstalls =
      [NSMutableArray array];
  for (NSDictionary<NSString *, id> *extension in extensions) {
    NSString *path = [extension[@"path"] isKindOfClass:NSString.class]
        ? extension[@"path"]
        : nil;
    NSString *identifier = [extension[@"id"] isKindOfClass:NSString.class]
        ? extension[@"id"]
        : nil;
    if (!path.length || !identifier.length) continue;
    if ([removed_paths containsObject:path] ||
        ([managed containsObject:path] &&
         hasIdentityMismatch(path, extension))) {
      [uninstalls addObject:@{
        @"type": @"uninstall",
        @"id": identifier,
        @"path": path
      }];
    }
  }

  NSMutableArray<NSDictionary<NSString *, id> *> *mutations =
      [NSMutableArray array];
  for (NSString *path in managed_paths) {
    NSDictionary<NSString *, id> *extension = by_path[path];
    if (!extension || hasIdentityMismatch(path, extension)) {
      [mutations addObject:@{@"type": @"load", @"path": path}];
      if (![enabled containsObject:path]) {
        [mutations addObject:@{@"type": @"disable", @"path": path}];
      }
      continue;
    }
    NSString *identifier = extension[@"id"];
    const BOOL shouldBeEnabled = [enabled containsObject:path];
    const BOOL isEnabled = [extension[@"enabled"] boolValue];
    if (shouldBeEnabled && !isEnabled) {
      [mutations addObject:@{
        @"type": @"enable",
        @"id": identifier,
        @"path": path
      }];
    } else if (!shouldBeEnabled && isEnabled) {
      [mutations addObject:@{
        @"type": @"disable",
        @"id": identifier,
        @"path": path
      }];
    }
    if (rex::extensions::ShouldReloadAfterEnableOrUpdate(
            shouldBeEnabled,
            isEnabled,
            requiresReload(path, extension))) {
      [mutations addObject:@{
        @"type": @"reload",
        @"id": identifier,
        @"path": path
      }];
    }
  }
  [uninstalls addObjectsFromArray:mutations];
  return uninstalls;
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

std::string RexChromiumVersionString() {
  return std::to_string(CHROME_VERSION_MAJOR) + "." +
      std::to_string(CHROME_VERSION_MINOR) + "." +
      std::to_string(CHROME_VERSION_BUILD) + "." +
      std::to_string(CHROME_VERSION_PATCH);
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
constexpr char kRexDownloadBubblePartialViewPreference[] =
    "download_bubble.partial_view_enabled";
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

bool RexDisableChromeDownloadBubble(CefRefPtr<CefRequestContext> context,
                                    const std::string &scope) {
  CEF_REQUIRE_UI_THREAD();
  const CefString preferenceName(kRexDownloadBubblePartialViewPreference);
  if (!context || !context->HasPreference(preferenceName)) {
    NSLog(@"[Rex] Chromium download bubble preference is unavailable for %s: %s",
          scope.c_str(), kRexDownloadBubblePartialViewPreference);
    return false;
  }

  CefRefPtr<CefValue> currentValue = context->GetPreference(preferenceName);
  if (!currentValue || currentValue->GetType() != VTYPE_BOOL) {
    NSLog(@"[Rex] Chromium download bubble preference has an unexpected type for %s: %s",
          scope.c_str(), kRexDownloadBubblePartialViewPreference);
    return false;
  }
  if (!currentValue->GetBool()) return true;
  if (!context->CanSetPreference(preferenceName)) {
    NSLog(@"[Rex] Chromium download bubble preference is not writable for %s: %s",
          scope.c_str(), kRexDownloadBubblePartialViewPreference);
    return false;
  }

  CefRefPtr<CefValue> disabled = CefValue::Create();
  if (!disabled || !disabled->SetBool(false)) return false;
  CefString error;
  if (!context->SetPreference(preferenceName, disabled, error)) {
    const std::string errorText = error.ToString();
    NSLog(@"[Rex] Failed to disable Chromium download bubble for %s: %s",
          scope.c_str(), errorText.empty() ? "unknown" : errorText.c_str());
    return false;
  }
  NSLog(@"[Rex] Chromium download completion bubble disabled for %s.",
        scope.c_str());
  return true;
}

bool RexIsChromeDownloadToolbarButton(
    cef_chrome_toolbar_button_type_t button_type) {
#if CEF_API_ADDED(13600)
  return button_type == CEF_CTBT_DOWNLOAD_DEPRECATED;
#else
  return button_type == CEF_CTBT_DOWNLOAD;
#endif
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
    RexDisableChromeDownloadBubble(request_context, scope_);
    RexApplyThirdPartyCookiePreference(
        request_context,
        block_third_party_cookies_->load(std::memory_order_relaxed), scope_);
  }

 private:
  std::shared_ptr<std::atomic_bool> block_third_party_cookies_;
  const std::string scope_;
  IMPLEMENT_REFCOUNTING(RexRequestContextHandler);
};

class RexExtensionChromeBrowserViewDelegate final
    : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  IMPLEMENT_REFCOUNTING(RexExtensionChromeBrowserViewDelegate);
};

class RexExtensionChromeWindowDelegate final : public CefWindowDelegate {
 public:
  explicit RexExtensionChromeWindowDelegate(
      CefRefPtr<CefBrowserView> browser_view,
      CefSize initial_size,
      bool initially_hidden = true)
      : browser_view_(browser_view),
        initial_size_(initial_size),
        initially_hidden_(initially_hidden) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->SetToFillLayout();
    window->AddChildView(browser_view_);
    if (!initially_hidden_) window->Show();
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    browser_view_ = nullptr;
  }

  bool CanClose(CefRefPtr<CefWindow> window) override {
    CefRefPtr<CefBrowser> browser =
        browser_view_ ? browser_view_->GetBrowser() : nullptr;
    return !browser || browser->GetHost()->TryCloseBrowser();
  }

  CefSize GetPreferredSize(CefRefPtr<CefView> view) override {
    return initial_size_;
  }

  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) override {
    return initially_hidden_ ? CEF_SHOW_STATE_HIDDEN : CEF_SHOW_STATE_NORMAL;
  }

  bool IsFrameless(CefRefPtr<CefWindow> window) override { return true; }

  bool CanResize(CefRefPtr<CefWindow> window) override { return false; }

  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  CefRefPtr<CefBrowserView> browser_view_;
  const CefSize initial_size_;
  const bool initially_hidden_;
  IMPLEMENT_REFCOUNTING(RexExtensionChromeWindowDelegate);
};

enum class RexManagedExtensionOperationKind {
  kNone,
  kRuntimeMutation,
  kConfiguration,
};

class RexDefaultChromeClient final : public CefClient,
                                     public CefCommandHandler,
                                     public CefDialogHandler,
                                     public CefDisplayHandler,
                                     public CefLifeSpanHandler,
                                     public CefLoadHandler,
                                     public CefRequestHandler {
 public:
  explicit RexDefaultChromeClient(__weak RexChromiumRuntime *runtime)
      : runtime_(runtime) {}

  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  bool IsChromeToolbarButtonVisible(
      cef_chrome_toolbar_button_type_t button_type) override {
    return !RexIsChromeDownloadToolbarButton(button_type);
  }
  bool OnFileDialog(
      CefRefPtr<CefBrowser> browser,
      FileDialogMode mode,
      const CefString &title,
      const CefString &default_file_path,
      const std::vector<CefString> &accept_filters,
      const std::vector<CefString> &accept_extensions,
      const std::vector<CefString> &accept_descriptions,
      CefRefPtr<CefFileDialogCallback> callback) override;
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString &message,
                        const CefString &source,
                        int line) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int http_status_code) override;

  bool CreateExtensionWindowHost();
  bool BeginManagedExtensionOperation(uint64_t token,
                                      std::string script,
                                      std::string folder_path);
  bool BeginManagedExtensionConfigurationOperation(uint64_t token,
                                                   std::string script);
  void CancelManagedExtensionOperation(uint64_t token);
  void ForwardBlankBrowserIfStillPending(int browser_id);
  void CloseAllBrowsers();
  size_t BrowserCount() const { return browsers_.size(); }

 private:
  bool BeginManagedExtensionOperationWithKind(
      uint64_t token,
      std::string script,
      std::string folder_path,
      RexManagedExtensionOperationKind kind);
  void DispatchManagedExtensionOperationIfReady();
  void CompleteManagedExtensionOperation(const std::string &encoded_error);
  void CompleteManagedExtensionConfigurationOperation(
      const std::string &encoded_payload,
      const std::string &transport_error = std::string());

  __weak RexChromiumRuntime *runtime_;
  std::map<int, CefRefPtr<CefBrowser>> browsers_;
  std::set<int> forwarding_browser_ids_;
  std::set<int> pending_blank_browser_ids_;
  CefRefPtr<CefBrowserView> extension_window_host_view_;
  int extension_window_host_browser_id_ = 0;
  uint64_t managed_extension_operation_token_ = 0;
  std::string managed_extension_operation_script_;
  std::string managed_extension_folder_path_;
  bool extension_window_host_page_ready_ = false;
  bool managed_extension_script_dispatched_ = false;
  bool managed_extension_folder_dialog_consumed_ = false;
  RexManagedExtensionOperationKind managed_extension_operation_kind_ =
      RexManagedExtensionOperationKind::kNone;
  IMPLEMENT_REFCOUNTING(RexDefaultChromeClient);
};

class RexCEFApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit RexCEFApp(
      std::shared_ptr<std::atomic_bool> block_third_party_cookies,
      std::vector<std::string> extension_paths,
      CefRefPtr<RexDefaultChromeClient> default_client,
      __weak RexChromiumRuntime *runtime,
      bool extension_pipe_enabled)
      : block_third_party_cookies_(std::move(block_third_party_cookies)),
        extension_paths_(std::move(extension_paths)),
        default_client_(default_client),
        runtime_(runtime),
        extension_pipe_enabled_(extension_pipe_enabled) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnContextInitialized() override {
    RexDisableChromeDownloadBubble(CefRequestContext::GetGlobalContext(), "global");
    RexApplyThirdPartyCookiePreference(
        CefRequestContext::GetGlobalContext(),
        block_third_party_cookies_->load(std::memory_order_relaxed), "global");
    NSLog(@"[Rex] Chromium context initialized with %lu extension package(s)",
          static_cast<unsigned long>(extension_paths_.size()));
    if (!extension_paths_.empty() && default_client_) {
      default_client_->CreateExtensionWindowHost();
    }
    RexChromiumRuntime *runtime = runtime_;
    if (runtime) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [runtime chromiumContextInitialized];
      });
    }
  }

  void OnBeforeCommandLineProcessing(
      const CefString &process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!command_line) return;
    // Empty process_type is the browser process.
    if (process_type.empty()) {
      rex::thorium::ApplyBrowserProcessFlags(command_line);

      command_line->RemoveSwitch("remote-debugging-port");
      command_line->RemoveSwitch("remote-debugging-address");
      // DEBUG: temporarily enable remote debugging port
      if (!command_line->HasSwitch("remote-debugging-port")) {
        command_line->AppendSwitchWithValue("remote-debugging-port", "9223");
      }
      command_line->RemoveSwitch("remote-debugging-pipe");
      command_line->RemoveSwitch("disable-extensions");
      command_line->RemoveSwitch("disable-extensions-except");
      // Persisted unpacked extensions must be restored by the Chromium profile.
      // Re-applying --load-extension turns every Rex launch into another
      // command-line installation and repeats runtime.onInstalled/onboarding.
      // The startup reconciliation below loads only genuinely missing paths.
      command_line->RemoveSwitch("load-extension");
      if (extension_pipe_enabled_) {
        command_line->AppendSwitch("remote-debugging-pipe");
      }
    } else {
      command_line->RemoveSwitch("remote-debugging-pipe");
      rex::thorium::ApplyChildProcessFlags(command_line);
    }
  }

  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override {
    if (command_line) command_line->RemoveSwitch("remote-debugging-pipe");
    rex::thorium::ApplyChildProcessFlags(command_line);
  }

  CefRefPtr<CefClient> GetDefaultClient() override {
    return default_client_;
  }

  void CloseDefaultBrowsers() {
    if (default_client_) default_client_->CloseAllBrowsers();
  }

  bool EnsureExtensionWindowHost() {
    return default_client_ && default_client_->CreateExtensionWindowHost();
  }

  bool BeginManagedExtensionOperation(uint64_t token,
                                      std::string script,
                                      std::string folder_path) {
    return default_client_ && default_client_->BeginManagedExtensionOperation(
        token, std::move(script), std::move(folder_path));
  }

  bool BeginManagedExtensionConfigurationOperation(uint64_t token,
                                                   std::string script) {
    return default_client_ &&
        default_client_->BeginManagedExtensionConfigurationOperation(
            token, std::move(script));
  }

  void CancelManagedExtensionOperation(uint64_t token) {
    if (default_client_) {
      default_client_->CancelManagedExtensionOperation(token);
    }
  }

  size_t DefaultBrowserCount() const {
    return default_client_ ? default_client_->BrowserCount() : 0;
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

  void DrainMessagePumpForShutdown() {
    dispatch_assert_queue(dispatch_get_main_queue());
    StopMessagePump();

    // Match CEF's macOS external-pump shutdown sequence. Browser teardown can
    // enqueue final UI work after the last OnBeforeClose callback; CefShutdown
    // may otherwise wait forever for work that the stopped host pump never runs.
    for (int iteration = 0; iteration < 10; ++iteration) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
      CefDoMessageLoopWork();
      [NSThread sleepForTimeInterval:0.05];
    }
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
  const std::vector<std::string> extension_paths_;
  CefRefPtr<RexDefaultChromeClient> default_client_;
  __weak RexChromiumRuntime *runtime_;
  const bool extension_pipe_enabled_;
  IMPLEMENT_REFCOUNTING(RexCEFApp);
};

}  // namespace

@implementation RexDevToolsPipeWriteRequest
@end

@implementation RexExtensionSyncRequest
@end

@interface RexDevToolsPipeController ()
- (void)readAvailableResponses;
- (void)consumeResponseFrame:(NSData *)frame;
- (void)drainPendingWrites;
- (void)armWriteSource;
- (void)failAllPendingWithError:(NSError *)error;
- (void)stopOnQueueWithError:(NSError *)error;
@end

@implementation RexDevToolsPipeController

static void *kRexDevToolsPipeQueueKey = &kRexDevToolsPipeQueueKey;

- (instancetype)init {
  self = [super init];
  if (self) {
    _requestWriteFD = -1;
    _responseReadFD = -1;
    _nextMessageID = 1;
    _queue = dispatch_queue_create(
        "com.rex.browser.extension-devtools-pipe",
        DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(
        _queue,
        kRexDevToolsPipeQueueKey,
        (__bridge void *)self,
        nullptr);
    _readBuffer = [[NSMutableData alloc] init];
    _pending = [[NSMutableDictionary alloc] init];
    _outboundWrites = [[NSMutableArray alloc] init];
  }
  return self;
}

- (BOOL)isPrepared {
  if (dispatch_get_specific(kRexDevToolsPipeQueueKey) ==
      (__bridge void *)self) {
    return _prepared;
  }
  __block BOOL prepared = NO;
  dispatch_sync(_queue, ^{
    prepared = self->_prepared;
  });
  return prepared;
}

- (BOOL)prepareWithError:(NSError **)error {
  NSAssert(NSThread.isMainThread,
           @"The DevTools pipe must be prepared before CEF initialization");
  if (_prepared) return YES;

  errno = 0;
  const BOOL descriptor3Occupied =
      fcntl(3, F_GETFD) != -1 || errno != EBADF;
  errno = 0;
  const BOOL descriptor4Occupied =
      fcntl(4, F_GETFD) != -1 || errno != EBADF;
  if (descriptor3Occupied || descriptor4Occupied) {
    if (error) {
      *error = RexExtensionRuntimeError(
          20,
          @"无法安全建立 Chromium 扩展控制管道：文件描述符 3/4 已被占用");
    }
    return NO;
  }

  // Reserve Chromium's fixed pipe descriptors before creating socket pairs so
  // no endpoint is accidentally allocated as fd 3 or fd 4 and then clobbered.
  const int descriptor3 = open("/dev/null", O_RDWR | O_CLOEXEC);
  const int descriptor4 = open("/dev/null", O_RDWR | O_CLOEXEC);
  if (descriptor3 != 3 || descriptor4 != 4) {
    if (descriptor3 >= 0) close(descriptor3);
    if (descriptor4 >= 0) close(descriptor4);
    if (error) {
      *error = RexExtensionRuntimeError(
          21, @"无法保留 Chromium 扩展控制管道的文件描述符");
    }
    return NO;
  }

  int requestPair[2] = {-1, -1};
  int responsePair[2] = {-1, -1};
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, requestPair) != 0 ||
      socketpair(AF_UNIX, SOCK_STREAM, 0, responsePair) != 0) {
    const int savedErrno = errno;
    for (int descriptor : requestPair) {
      if (descriptor >= 0) close(descriptor);
    }
    for (int descriptor : responsePair) {
      if (descriptor >= 0) close(descriptor);
    }
    close(3);
    close(4);
    if (error) {
      *error = RexExtensionRuntimeError(
          22,
          [NSString stringWithFormat:
              @"无法建立 Chromium 扩展控制管道：%s",
              strerror(savedErrno)]);
    }
    return NO;
  }

  BOOL closeOnExecConfigured = YES;
  for (int descriptor : requestPair) {
    closeOnExecConfigured &=
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0;
  }
  for (int descriptor : responsePair) {
    closeOnExecConfigured &=
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0;
  }
  if (!closeOnExecConfigured) {
    const int savedErrno = errno;
    for (int descriptor : requestPair) close(descriptor);
    for (int descriptor : responsePair) close(descriptor);
    close(3);
    close(4);
    if (error) {
      *error = RexExtensionRuntimeError(
          23,
          [NSString stringWithFormat:
              @"无法保护 Chromium 扩展控制管道描述符：%s",
              strerror(savedErrno)]);
    }
    return NO;
  }

  const BOOL mapped =
      dup2(requestPair[1], 3) == 3 && dup2(responsePair[1], 4) == 4;
  if (!mapped) {
    const int savedErrno = errno;
    for (int descriptor : requestPair) close(descriptor);
    for (int descriptor : responsePair) close(descriptor);
    close(3);
    close(4);
    if (error) {
      *error = RexExtensionRuntimeError(
          23,
          [NSString stringWithFormat:
              @"无法映射 Chromium 扩展控制管道：%s",
              strerror(savedErrno)]);
    }
    return NO;
  }

  if (fcntl(3, F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(4, F_SETFD, FD_CLOEXEC) != 0) {
    const int savedErrno = errno;
    for (int descriptor : requestPair) close(descriptor);
    for (int descriptor : responsePair) close(descriptor);
    close(3);
    close(4);
    if (error) {
      *error = RexExtensionRuntimeError(
          23,
          [NSString stringWithFormat:
              @"无法保护 Chromium 扩展控制管道固定描述符：%s",
              strerror(savedErrno)]);
    }
    return NO;
  }
  _requestWriteFD = requestPair[0];
  _responseReadFD = responsePair[0];
  close(requestPair[1]);
  close(responsePair[1]);

  const int writeFlags = fcntl(_requestWriteFD, F_GETFL, 0);
  const int readFlags = fcntl(_responseReadFD, F_GETFL, 0);
  if (writeFlags < 0 || readFlags < 0 ||
      fcntl(_requestWriteFD, F_SETFL, writeFlags | O_NONBLOCK) != 0 ||
      fcntl(_responseReadFD, F_SETFL, readFlags | O_NONBLOCK) != 0) {
    const int savedErrno = errno;
    close(_requestWriteFD);
    close(_responseReadFD);
    close(3);
    close(4);
    _requestWriteFD = -1;
    _responseReadFD = -1;
    if (error) {
      *error = RexExtensionRuntimeError(
          24,
          [NSString stringWithFormat:
              @"无法将 Chromium 扩展控制管道设为非阻塞模式：%s",
              strerror(savedErrno)]);
    }
    return NO;
  }
  int noSigPipe = 1;
  if (setsockopt(_requestWriteFD, SOL_SOCKET, SO_NOSIGPIPE,
                 &noSigPipe, sizeof(noSigPipe)) != 0 ||
      setsockopt(4, SOL_SOCKET, SO_NOSIGPIPE,
                 &noSigPipe, sizeof(noSigPipe)) != 0) {
    const int savedErrno = errno;
    close(_requestWriteFD);
    close(_responseReadFD);
    close(3);
    close(4);
    _requestWriteFD = -1;
    _responseReadFD = -1;
    if (error) {
      *error = RexExtensionRuntimeError(
          24,
          [NSString stringWithFormat:
              @"无法禁用 Chromium 扩展控制管道 SIGPIPE：%s",
              strerror(savedErrno)]);
    }
    return NO;
  }

  _ownsChromiumFDs = YES;
  _prepared = YES;
  return YES;
}

- (void)startReading {
  NSAssert(NSThread.isMainThread,
           @"The DevTools pipe reader must start on the main thread");
  if (!_prepared || _reading || _stopped ||
      _responseReadFD < 0 || _requestWriteFD < 0) {
    return;
  }
  _reading = YES;

  const int requestWriteFD = _requestWriteFD;
  _writeSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_WRITE,
      static_cast<uintptr_t>(requestWriteFD),
      0,
      _queue);
  _writeSourceSuspended = YES;
  __weak RexDevToolsPipeController *weakSelf = self;
  dispatch_source_set_event_handler(_writeSource, ^{
    [weakSelf drainPendingWrites];
  });
  dispatch_source_set_cancel_handler(_writeSource, ^{
    close(requestWriteFD);
  });

  const int responseReadFD = _responseReadFD;
  _readSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_READ,
      static_cast<uintptr_t>(responseReadFD),
      0,
      _queue);
  dispatch_source_set_event_handler(_readSource, ^{
    [weakSelf readAvailableResponses];
  });
  dispatch_source_set_cancel_handler(_readSource, ^{
    close(responseReadFD);
  });
  dispatch_resume(_readSource);
}

- (void)executeMethod:(NSString *)method
               params:(NSDictionary<NSString *, id> *)params
           completion:(RexDevToolsPipeCompletion)completion {
  NSString *methodCopy = [method copy];
  NSDictionary<NSString *, id> *paramsCopy = [params copy] ?: @{};
  RexDevToolsPipeCompletion completionCopy = [completion copy];
  dispatch_async(_queue, ^{
    if (!self->_prepared || self->_stopped ||
        self->_requestWriteFD < 0) {
      NSError *pipeError = RexExtensionRuntimeError(
          24, @"Chromium 扩展控制管道不可用");
      dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(nil, pipeError);
      });
      return;
    }

    const uint64_t messageID = self->_nextMessageID++;
    NSNumber *key = @(messageID);
    self->_pending[key] = completionCopy;
    NSDictionary<NSString *, id> *message = @{
      @"id": key,
      @"method": methodCopy,
      @"params": paramsCopy
    };
    NSError *serializationError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message
                                                   options:0
                                                     error:&serializationError];
    if (!json) {
      [self->_pending removeObjectForKey:key];
      NSError *resultError = RexExtensionRuntimeError(
          25,
          @"无法编码 Chromium 扩展控制命令",
          serializationError
              ? @{NSUnderlyingErrorKey: serializationError}
              : @{});
      dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(nil, resultError);
      });
      return;
    }

    NSMutableData *framed = [json mutableCopy];
    const uint8_t terminator = 0;
    [framed appendBytes:&terminator length:1];
    RexDevToolsPipeWriteRequest *writeRequest =
        [[RexDevToolsPipeWriteRequest alloc] init];
    writeRequest.messageID = key;
    writeRequest.method = methodCopy;
    writeRequest.payload = framed;
    [self->_outboundWrites addObject:writeRequest];
    [self drainPendingWrites];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
        self->_queue, ^{
          RexDevToolsPipeCompletion pending = self->_pending[key];
          if (!pending) return;
          const BOOL mutationMayCompleteLate =
              [methodCopy isEqualToString:@"Extensions.loadUnpacked"] ||
              [methodCopy isEqualToString:@"Extensions.uninstall"];
          NSError *timeoutError = RexExtensionRuntimeError(
              27,
              mutationMayCompleteLate
                  ? [NSString stringWithFormat:
                      @"Chromium 扩展变更命令超时，运行时状态未知，请重新启动 Rex：%@",
                      methodCopy]
                  : [NSString stringWithFormat:
                      @"Chromium 扩展控制命令超时：%@",
                      methodCopy],
              mutationMayCompleteLate
                  ? @{@"requiresRestart": @YES,
                      @"runtimeState": @"unknown",
                      @"method": methodCopy}
                  : @{@"method": methodCopy});
          const BOOL writeIncomplete =
              [self->_outboundWrites indexOfObjectPassingTest:^BOOL(
                  RexDevToolsPipeWriteRequest *request,
                  NSUInteger index,
                  BOOL *stop) {
                return [request.messageID isEqualToNumber:key];
              }] != NSNotFound;
          if (writeIncomplete || mutationMayCompleteLate) {
            // A partially written NUL-delimited frame cannot be discarded
            // without corrupting the stream. A fully written mutation also
            // cannot be cancelled and may complete after its timeout, so poison
            // the channel instead of attempting a false rollback/commit.
            [self stopOnQueueWithError:timeoutError];
            return;
          }
          [self->_pending removeObjectForKey:key];
          dispatch_async(dispatch_get_main_queue(), ^{
            pending(nil, timeoutError);
          });
        });
  });
}

- (void)drainPendingWrites {
  while (_outboundWrites.count && !_stopped && _requestWriteFD >= 0) {
    RexDevToolsPipeWriteRequest *request = _outboundWrites.firstObject;
    const uint8_t *bytes =
        static_cast<const uint8_t *>(request.payload.bytes);
    while (request.offset < request.payload.length) {
      const ssize_t count = write(
          _requestWriteFD,
          bytes + request.offset,
          request.payload.length - request.offset);
      if (count > 0) {
        request.offset += static_cast<NSUInteger>(count);
        continue;
      }
      if (count < 0 && errno == EINTR) continue;
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        [self armWriteSource];
        return;
      }

      const int savedErrno = count == 0 ? EPIPE : errno;
      [self stopOnQueueWithError:RexExtensionRuntimeError(
          26,
          [NSString stringWithFormat:
              @"无法写入 Chromium 扩展控制管道：%s",
              strerror(savedErrno)])];
      return;
    }
    [_outboundWrites removeObjectAtIndex:0];
  }

  if (!_outboundWrites.count && _writeSource &&
      !_writeSourceSuspended) {
    _writeSourceSuspended = YES;
    dispatch_suspend(_writeSource);
  }
}

- (void)armWriteSource {
  if (!_writeSource || !_writeSourceSuspended ||
      _stopped || _requestWriteFD < 0) {
    return;
  }
  _writeSourceSuspended = NO;
  dispatch_resume(_writeSource);
}

- (void)readAvailableResponses {
  if (_responseReadFD < 0 || _stopped) return;
  uint8_t bytes[64 * 1024];
  while (true) {
    const ssize_t count = read(_responseReadFD, bytes, sizeof(bytes));
    if (count > 0) {
      [_readBuffer appendBytes:bytes length:static_cast<NSUInteger>(count)];
      if (_readBuffer.length > 8 * 1024 * 1024) {
        [self stopOnQueueWithError:RexExtensionRuntimeError(
            28, @"Chromium 扩展控制响应超过安全大小限制")];
        return;
      }

      const uint8_t delimiter = 0;
      NSData *delimiterData = [NSData dataWithBytes:&delimiter length:1];
      while (true) {
        NSRange range = [_readBuffer rangeOfData:delimiterData
                                        options:0
                                          range:NSMakeRange(
                                              0, _readBuffer.length)];
        if (range.location == NSNotFound) break;
        NSData *frame = [_readBuffer subdataWithRange:
            NSMakeRange(0, range.location)];
        [_readBuffer replaceBytesInRange:
            NSMakeRange(0, NSMaxRange(range))
                                withBytes:nullptr
                                   length:0];
        if (frame.length) [self consumeResponseFrame:frame];
      }
      continue;
    }
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    const int savedErrno = errno;
    NSString *description = count == 0
        ? @"Chromium 扩展控制管道已到达 EOF"
        : [NSString stringWithFormat:
            @"Chromium 扩展控制管道读取失败：%s",
            strerror(savedErrno)];
    [self stopOnQueueWithError:RexExtensionRuntimeError(29, description)];
    return;
  }
}

- (void)consumeResponseFrame:(NSData *)frame {
  NSError *parseError = nil;
  id decoded = [NSJSONSerialization JSONObjectWithData:frame
                                               options:0
                                                 error:&parseError];
  if (![decoded isKindOfClass:NSDictionary.class]) {
    NSLog(@"[Rex] ignored malformed extension DevTools response: %@",
          parseError.localizedDescription ?: @"not a dictionary");
    return;
  }
  NSDictionary<NSString *, id> *message =
      static_cast<NSDictionary<NSString *, id> *>(decoded);
  NSNumber *messageID = [message[@"id"] isKindOfClass:NSNumber.class]
      ? message[@"id"]
      : nil;
  if (!messageID) return;
  RexDevToolsPipeCompletion completion = _pending[messageID];
  if (!completion) return;
  [_pending removeObjectForKey:messageID];

  NSDictionary<NSString *, id> *errorPayload =
      [message[@"error"] isKindOfClass:NSDictionary.class]
          ? message[@"error"]
          : nil;
  if (errorPayload) {
    NSString *errorMessage =
        [errorPayload[@"message"] isKindOfClass:NSString.class]
            ? errorPayload[@"message"]
            : @"Chromium 扩展控制命令失败";
    NSError *error = RexExtensionRuntimeError(
        30, errorMessage, @{@"devToolsError": errorPayload});
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil, error);
    });
    return;
  }

  NSDictionary<NSString *, id> *result =
      [message[@"result"] isKindOfClass:NSDictionary.class]
          ? message[@"result"]
          : @{};
  dispatch_async(dispatch_get_main_queue(), ^{
    completion(result, nil);
  });
}

- (void)failAllPendingWithError:(NSError *)error {
  NSDictionary<NSNumber *, RexDevToolsPipeCompletion> *pending =
      [_pending copy];
  [_pending removeAllObjects];
  for (RexDevToolsPipeCompletion completion in pending.allValues) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil, error);
    });
  }
}

- (void)stopOnQueueWithError:(NSError *)error {
  if (_stopped) return;
  _stopped = YES;
  _prepared = NO;
  _reading = NO;
  [_outboundWrites removeAllObjects];
  [_readBuffer setLength:0];

  if (_writeSource) {
    if (_writeSourceSuspended) {
      _writeSourceSuspended = NO;
      dispatch_resume(_writeSource);
    }
    dispatch_source_cancel(_writeSource);
    _writeSource = nil;
    _requestWriteFD = -1;
  } else if (_requestWriteFD >= 0) {
    close(_requestWriteFD);
    _requestWriteFD = -1;
  }
  if (_readSource) {
    dispatch_source_cancel(_readSource);
    _readSource = nil;
    _responseReadFD = -1;
  } else if (_responseReadFD >= 0) {
    close(_responseReadFD);
    _responseReadFD = -1;
  }
  if (_ownsChromiumFDs) {
    // Chromium's DevToolsPipeHandler keeps the numeric descriptors and may
    // asynchronously call shutdown after Rex observes an error. Disconnect
    // now, but keep 3/4 occupied until CefShutdown has fully returned.
    shutdown(3, SHUT_RDWR);
    shutdown(4, SHUT_RDWR);
  }
  [self failAllPendingWithError:error];
}

- (void)shutdown {
  if (!_queue) return;
  dispatch_block_t stop = ^{
    [self stopOnQueueWithError:RexExtensionRuntimeError(
        31, @"Chromium 扩展控制管道已关闭")];
  };
  if (dispatch_get_specific(kRexDevToolsPipeQueueKey) ==
      (__bridge void *)self) {
    stop();
  } else {
    dispatch_sync(_queue, stop);
  }
}

- (void)releaseChromiumDescriptors {
  if (!_queue) return;
  dispatch_block_t release = ^{
    if (!self->_ownsChromiumFDs) return;
    close(3);
    close(4);
    self->_ownsChromiumFDs = NO;
  };
  if (dispatch_get_specific(kRexDevToolsPipeQueueKey) ==
      (__bridge void *)self) {
    release();
  } else {
    dispatch_sync(_queue, release);
  }
}

- (void)dealloc {
  [self shutdown];
}

@end

namespace {

const void *kRexHandlingSendEventKey = &kRexHandlingSendEventKey;
using RexSendEventImplementation = void (*)(id, SEL, NSEvent *);
using RexRunImplementation = void (*)(id, SEL);
using RexTerminateImplementation = void (*)(id, SEL, id);
RexSendEventImplementation gOriginalSendEvent = nullptr;
RexRunImplementation gOriginalRun = nullptr;
RexTerminateImplementation gOriginalTerminate = nullptr;

constexpr RexDeveloperToolsEditingCommand
RexDeveloperToolsEditingCommandForKeyCode(
    unsigned short key_code,
    NSEventModifierFlags modifiers) {
  constexpr NSEventModifierFlags command = NSEventModifierFlagCommand;
  constexpr NSEventModifierFlags shiftCommand =
      NSEventModifierFlagShift | NSEventModifierFlagCommand;
  constexpr NSEventModifierFlags optionShiftCommand =
      NSEventModifierFlagOption | shiftCommand;
  if (key_code == 6 && modifiers == command) {
    return RexDeveloperToolsEditingCommandUndo;
  }
  if (key_code == 6 && modifiers == shiftCommand) {
    return RexDeveloperToolsEditingCommandRedo;
  }
  if (key_code == 7 && modifiers == command) {
    return RexDeveloperToolsEditingCommandCut;
  }
  if (key_code == 8 && modifiers == command) {
    return RexDeveloperToolsEditingCommandCopy;
  }
  if (key_code == 9 && modifiers == command) {
    return RexDeveloperToolsEditingCommandPaste;
  }
  if (key_code == 9 &&
      (modifiers == shiftCommand || modifiers == optionShiftCommand)) {
    return RexDeveloperToolsEditingCommandPasteAndMatchStyle;
  }
  if (key_code == 0 && modifiers == command) {
    return RexDeveloperToolsEditingCommandSelectAll;
  }
  return RexDeveloperToolsEditingCommandNone;
}

static_assert(RexDeveloperToolsEditingCommandForKeyCode(
                  8, NSEventModifierFlagCommand) ==
              RexDeveloperToolsEditingCommandCopy);
static_assert(RexDeveloperToolsEditingCommandForKeyCode(
                  9, NSEventModifierFlagCommand) ==
              RexDeveloperToolsEditingCommandPaste);
static_assert(RexDeveloperToolsEditingCommandForKeyCode(
                  6, NSEventModifierFlagCommand | NSEventModifierFlagShift) ==
              RexDeveloperToolsEditingCommandRedo);
static_assert(RexDeveloperToolsEditingCommandForKeyCode(
                  8, NSEventModifierFlagCommand | NSEventModifierFlagShift) ==
              RexDeveloperToolsEditingCommandNone);

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
  if (event.type == NSEventTypeKeyDown &&
      [RexChromiumRuntime.shared
          handleDeveloperToolsEditingShortcutForEvent:event]) {
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

void RexRun(id application, SEL command) {
  if (gOriginalRun) {
    gOriginalRun(application, command);
  }

  // Chromium's macOS shutdown contract requires CefShutdown only after the
  // main NSApplication event loop has returned. SwiftUI's App.main() exits the
  // process immediately after -run returns, so perform the final shutdown in
  // this hook before control returns to NSApplicationMain.
  [RexChromiumRuntime.shared shutdownAfterApplicationTermination];
}

void RexTerminate(id application, SEL command, id sender) {
  id delegate = [(NSApplication *)application delegate];
  SEL terminationSelector = NSSelectorFromString(@"rexTryToTerminateApplication:");
  if (delegate && [delegate respondsToSelector:terminationSelector]) {
    using RexTerminationDelegateImplementation = void (*)(id, SEL, NSApplication *);
    auto implementation = reinterpret_cast<RexTerminationDelegateImplementation>(
        [delegate methodForSelector:terminationSelector]);
    implementation(delegate, terminationSelector, (NSApplication *)application);
    return;
  }

  if (gOriginalTerminate) {
    gOriginalTerminate(application, command, sender);
  }
}

}  // namespace

void RexInstallCEFApplicationLifecycleHooks(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class applicationClass = NSApplication.class;

    // CEF explicitly does not support AppKit's standard delayed termination
    // transaction on macOS. Redirect ordinary -terminate: sources to the Rex
    // delegate, which closes browsers and stops the main event loop.
    Method terminateMethod =
        class_getInstanceMethod(applicationClass, @selector(terminate:));
    if (terminateMethod) {
      gOriginalTerminate = reinterpret_cast<RexTerminateImplementation>(
          method_getImplementation(terminateMethod));
      class_replaceMethod(applicationClass, @selector(terminate:),
                          reinterpret_cast<IMP>(RexTerminate),
                          method_getTypeEncoding(terminateMethod));
    }

    Method runMethod = class_getInstanceMethod(applicationClass, @selector(run));
    if (runMethod) {
      gOriginalRun = reinterpret_cast<RexRunImplementation>(
          method_getImplementation(runMethod));
      class_replaceMethod(applicationClass, @selector(run),
                          reinterpret_cast<IMP>(RexRun),
                          method_getTypeEncoding(runMethod));
    }
  });
}

namespace {

void RexInstallCEFApplicationHooks() {
  RexInstallCEFApplicationLifecycleHooks();
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
                               public CefCommandHandler,
                               public CefCookieAccessFilter,
                               public CefContextMenuHandler,
                               public CefDialogHandler,
                               public CefDisplayHandler,
                               public CefDownloadHandler,
                               public CefJSDialogHandler,
                               public CefLoadHandler,
                               public CefLifeSpanHandler,
                               public CefPermissionHandler,
                               public CefRequestHandler,
                               public CefResourceRequestHandler {
 public:
  RexBrowserClient(__weak RexChromiumRuntime *runtime,
                   NSString *tabID)
      : runtime_(runtime),
        tab_id_([tabID copy]) {}

  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  bool IsChromeToolbarButtonVisible(
      cef_chrome_toolbar_button_type_t button_type) override {
    return !RexIsChromeDownloadToolbarButton(button_type);
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
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

  bool OnFileDialog(
      CefRefPtr<CefBrowser> browser,
      FileDialogMode mode,
      const CefString &title,
      const CefString &default_file_path,
      const std::vector<CefString> &accept_filters,
      const std::vector<CefString> &accept_extensions,
      const std::vector<CefString> &accept_descriptions,
      CefRefPtr<CefFileDialogCallback> callback) override;
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString &origin_url,
                  JSDialogType dialog_type,
                  const CefString &message_text,
                  const CefString &default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool &suppress_message) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString &message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;
  bool OnAutoResize(CefRefPtr<CefBrowser> browser,
                    const CefSize &new_size) override;
  void OnFaviconURLChange(
      CefRefPtr<CefBrowser> browser,
      const std::vector<CefString> &icon_urls) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                               double progress) override;
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                              bool fullscreen) override;
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
  bool IsPrimaryBrowser(CefRefPtr<CefBrowser> browser) const {
    return browser && primary_browser_identifier_ > 0 &&
           browser->GetIdentifier() == primary_browser_identifier_;
  }
  void Emit(NSString *kind, NSDictionary<NSString *, id> *fields = @{});
  void EmitBlockedResource(NSString *category, const std::string &host);
  void EmitMediaAccess(bool has_video_access, bool has_audio_access);
  void EmitSecuritySnapshot(CefRefPtr<CefBrowser> browser);
  void CancelFileDialog();
  void CancelJSDialog();

  __weak RexChromiumRuntime *runtime_;
  NSString *tab_id_;
  int primary_browser_identifier_ = 0;
  uint64_t navigation_generation_ = 0;
  int pending_auto_resize_width_ = 0;
  int pending_auto_resize_height_ = 0;
  bool has_video_access_ = false;
  bool has_audio_access_ = false;
  __strong NSSavePanel *active_file_panel_ = nil;
  CefRefPtr<CefFileDialogCallback> pending_file_dialog_callback_;
  __strong NSAlert *active_js_alert_ = nil;
  CefRefPtr<CefJSDialogCallback> pending_js_dialog_callback_;
  IMPLEMENT_REFCOUNTING(RexBrowserClient);
};

class RexDevToolsClient final : public CefClient,
                                public CefContextMenuHandler,
                                public CefLifeSpanHandler,
                                public CefLoadHandler {
 public:
  RexDevToolsClient(__weak RexChromiumRuntime *runtime,
                    NSString *tabID,
                    bool tracks_opening = false)
      : runtime_(runtime),
        tab_id_([tabID copy]),
        tracks_opening_(tracks_opening) {}

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;
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
- (void)registerBrowser:(CefRefPtr<CefBrowser>)browser
                  tabID:(NSString *)tabID
        deferPendingURL:(BOOL)deferPendingURL;
- (nullable NSString *)consumePendingURLForTabID:(NSString *)tabID
                                      fallbackURL:(NSString *)fallbackURL;
- (void)browser:(CefRefPtr<CefBrowser>)browser
    preferredContentSizeDidChange:(NSSize)size
                            tabID:(NSString *)tabID;
- (nullable NSDictionary<NSString *, id> *)
    extensionActionContextForSurfaceTabID:(NSString *)tabID;
- (BOOL)shouldHideStartupPlaceholderForTabID:(NSString *)tabID
                                   currentURL:(NSString *)currentURL;
- (void)didCommitStartupAddressForTabID:(NSString *)tabID
                              currentURL:(NSString *)currentURL;
- (void)registerAuxiliaryChromeBrowser:(CefRefPtr<CefBrowser>)browser
                           sourceTabID:(NSString *)sourceTabID;
- (void)auxiliaryChromeBrowserDidClose:(CefRefPtr<CefBrowser>)browser;
- (void)handleDefaultChromeBrowser:(CefRefPtr<CefBrowser>)browser
                         targetURL:(nullable NSString *)targetURL;
- (void)parkDefaultChromeBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)registerExtensionChromeWindowHost:(CefRefPtr<CefBrowser>)browser;
- (void)extensionChromeWindowHostDidClose;
- (void)defaultChromeBrowserDidClose;
- (void)registerChromePopupBrowser:(CefRefPtr<CefBrowser>)browser
                        sourceTabID:(NSString *)sourceTabID;
- (void)chromePopupBrowserDidClose:(CefRefPtr<CefBrowser>)browser;
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
- (void)syncEmbeddedChromeWindow:(nullable NSWindow *)chromeWindow
                       toHostView:(NSView *)hostView
                          browser:(CefRefPtr<CefBrowser>)browser;
- (void)embeddedChromeWindowDidBecomeKey:(NSNotification *)notification;
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
- (void)browser:(CefRefPtr<CefBrowser>)browser
        didCloseForTabID:(NSString *)tabID;
- (nullable NSWindow *)hostWindowForTabID:(NSString *)tabID;
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
- (void)cancelAllDownloadsForTermination;
- (void)releaseProfileForTabID:(NSString *)tabID;
- (nullable NSURL *)downloadDirectoryForTabID:(NSString *)tabID;
- (void)registerDownloadCallback:(CefRefPtr<CefDownloadItemCallback>)callback
                      downloadID:(uint32_t)downloadID
                           tabID:(NSString *)tabID;
- (void)removeDownloadCallbackID:(uint32_t)downloadID tabID:(NSString *)tabID;
- (void)removeDownloadCallbacksForTabID:(NSString *)tabID;
- (void)enqueueExtensionSyncManagedPaths:(NSArray<NSString *> *)managedPaths
                            enabledPaths:(NSArray<NSString *> *)enabledPaths
                            removedPaths:(NSArray<NSString *> *)removedPaths
                        forceReloadPaths:(NSArray<NSString *> *)forceReloadPaths
                                 startup:(BOOL)startup
                              completion:
                                  (nullable RexChromiumExtensionRuntimeCompletion)
                                      completion;
- (void)startNextExtensionSyncIfNeeded;
- (void)queryLiveExtensions:(RexExtensionQueryCompletion)completion;
- (void)performExtensionOperations:
            (NSArray<NSDictionary<NSString *, id> *> *)operations
                                index:(NSUInteger)index
           loadedExtensionIDsByPath:
               (NSMutableDictionary<NSString *, NSString *> *)loadedIDsByPath
                           completion:
                               (RexExtensionOperationsCompletion)completion;
- (void)performNativeExtensionOperation:
            (NSDictionary<NSString *, id> *)operation
                              completion:
                                  (RexExtensionOperationsCompletion)completion;
- (void)performExtensionConfigurationOperationForExtensionID:
            (NSString *)extensionID
                                                       update:
                                                           (nullable NSDictionary<NSString *, id> *)update
                                           sitePermissionHost:
                                               (nullable NSString *)sitePermissionHost
                                        sitePermissionGranted:
                                            (nullable NSNumber *)sitePermissionGranted
                                                   completion:
                                                       (RexChromiumExtensionConfigurationCompletion)
                                                           completion;
- (void)finishExtensionSyncRequest:(RexExtensionSyncRequest *)request
                         extensions:
                             (NSArray<NSDictionary<NSString *, id> *> *)extensions;
- (void)failExtensionSyncRequest:(RexExtensionSyncRequest *)request
                           error:(NSError *)error
              attemptedMutation:(BOOL)attemptedMutation;
- (void)releaseExtensionStartupNavigationBarrier;
- (void)reloadWebPagesAfterExtensionChange;
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
  } else {
    [RexChromiumRuntime.shared setFocused:NO tabID:self.tabID];
  }
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [RexChromiumRuntime.shared notifyHostViewDidLayout:self tabID:self.tabID];
}

- (void)setHidden:(BOOL)hidden {
  if (self.hidden == hidden) return;
  [super setHidden:hidden];
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

- (void)undo:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandUndo
                                      tabID:self.tabID];
}

- (void)redo:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandRedo
                                      tabID:self.tabID];
}

- (void)cut:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandCut
                                      tabID:self.tabID];
}

- (void)copy:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandCopy
                                      tabID:self.tabID];
}

- (void)paste:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandPaste
                                      tabID:self.tabID];
}

- (void)pasteAsPlainText:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:
          RexDeveloperToolsEditingCommandPasteAndMatchStyle
                                      tabID:self.tabID];
}

- (void)delete:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandDelete
                                      tabID:self.tabID];
}

- (void)selectAll:(id)sender {
  [RexChromiumRuntime.shared
      executeDeveloperToolsEditingCommand:RexDeveloperToolsEditingCommandSelectAll
                                      tabID:self.tabID];
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
  BOOL _finalizingShutdown;
  BOOL _layoutSyncSuspended;
  BOOL _chromiumContextReady;
  BOOL _extensionChromeWindowHostReady;
  BOOL _extensionStartupBarrierActive;
  BOOL _extensionSyncActive;
  BOOL _extensionPageReloadPending;
  NSUInteger _extensionRuntimeGeneration;
  NSUInteger _extensionChromeWindowHostEpoch;
  uint64_t _nativeExtensionOperationToken;
  std::unique_ptr<CefScopedLibraryLoader> _libraryLoader;
  CefRefPtr<RexCEFApp> _application;
  CefRefPtr<CefTaskManager> _taskManager;
  RexDevToolsPipeController *_extensionPipe;
  NSArray<NSString *> *_managedExtensionPaths;
  NSArray<NSString *> *_enabledExtensionPaths;
  NSMutableDictionary<NSString *, NSString *> *_extensionPathFingerprints;
  NSMutableArray<RexExtensionSyncRequest *> *_extensionSyncQueue;
  RexExtensionSyncRequest *_activeExtensionSyncRequest;
  RexExtensionOperationsCompletion _nativeExtensionOperationCompletion;
  RexChromiumExtensionConfigurationCompletion
      _extensionConfigurationCompletion;
  NSString *_extensionConfigurationExpectedID;
  BOOL _extensionConfigurationMutation;
  std::shared_ptr<std::atomic_bool> _blockThirdPartyCookiesPreference;
  std::map<std::string, CefRefPtr<CefBrowser>> _browsers;
  std::map<std::string, CefRefPtr<CefBrowserView>> _embeddedChromeBrowserViews;
  std::map<int, CefRefPtr<CefBrowser>> _auxiliaryChromeBrowsers;
  std::map<int, CefRefPtr<CefBrowser>> _chromePopupBrowsers;
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
  std::set<std::string> _embeddedChromeTabs;
  std::set<std::string> _browserReplacementTabs;
  std::set<std::string> _startupPlaceholderTabs;
  std::set<std::string> _suspendedTabs;
  std::set<std::string> _needsExtensionReloadTabs;
  NSMutableDictionary<NSString *, NSString *> *_pendingURLs;
  NSMutableDictionary<NSString *, RexChromiumBrowserView *> *_views;
  NSMutableDictionary<NSString *, RexChromiumDevToolsView *> *_developerToolsViews;
  NSMutableDictionary<NSNumber *, NSWindow *> *_chromePopupWindowsByBrowserID;
  NSMutableDictionary<NSNumber *, NSWindow *> *_embeddedChromeWindowsByBrowserID;
  NSMutableDictionary<NSNumber *, NSView *> *_embeddedChromeNativeViewsByBrowserID;
  NSMutableDictionary<NSNumber *, NSWindow *> *_developerToolsPopupWindowsByBrowserID;
  NSMutableDictionary<NSString *, NSString *> *_tabProfileIDs;
  NSMutableDictionary<NSString *, NSNumber *> *_privateTabs;
  NSMutableDictionary<NSString *, NSNumber *> *_mutedTabs;
  NSString *_focusedTabID;
  NSString *_lastFocusedTabID;
  NSString *_internalDownloadUIExtensionPath;
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
    _managedExtensionPaths = @[];
    _enabledExtensionPaths = @[];
    _internalDownloadUIExtensionPath = nil;
    _extensionPathFingerprints = [[NSMutableDictionary alloc] init];
    _extensionSyncQueue = [[NSMutableArray alloc] init];
    _blockThirdPartyCookiesPreference = std::make_shared<std::atomic_bool>(
        RexInitialBlockThirdPartyCookiesPreference());
    _pendingURLs = [[NSMutableDictionary alloc] init];
    _views = [[NSMutableDictionary alloc] init];
    _developerToolsViews = [[NSMutableDictionary alloc] init];
    _chromePopupWindowsByBrowserID = [[NSMutableDictionary alloc] init];
    _embeddedChromeWindowsByBrowserID = [[NSMutableDictionary alloc] init];
    _embeddedChromeNativeViewsByBrowserID = [[NSMutableDictionary alloc] init];
    _developerToolsPopupWindowsByBrowserID = [[NSMutableDictionary alloc] init];
    _tabProfileIDs = [[NSMutableDictionary alloc] init];
    _privateTabs = [[NSMutableDictionary alloc] init];
    _mutedTabs = [[NSMutableDictionary alloc] init];
    _privacyPolicies = [[NSMutableDictionary alloc] init];
    _downloadDirectories = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (BOOL)isReady { return _ready; }
- (BOOL)isFinalizingShutdown { return _finalizingShutdown; }
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
       publicSuffixListURL:(NSURL *)publicSuffixListURL
         privacyCatalogURL:(NSURL *)privacyCatalogURL
     managedExtensionPaths:(NSArray<NSString *> *)managedExtensionPaths
     enabledExtensionPaths:(NSArray<NSString *> *)enabledExtensionPaths
                     error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"CEF must initialize on the main thread");
  if (_ready) return YES;

  RexInstallCEFApplicationHooks();

  NSError *pathValidationError = nil;
  NSString *internalDownloadUIExtensionPath =
      RexInternalDownloadUIExtensionPath(&pathValidationError);
  NSArray<NSString *> *requiredManagedPaths =
      internalDownloadUIExtensionPath
          ? RexPathsIncludingInternalDownloadUIExtension(
                managedExtensionPaths, internalDownloadUIExtensionPath)
          : nil;
  NSArray<NSString *> *requiredEnabledPaths =
      internalDownloadUIExtensionPath
          ? RexPathsIncludingInternalDownloadUIExtension(
                enabledExtensionPaths, internalDownloadUIExtensionPath)
          : nil;
  NSArray<NSString *> *validatedManagedPaths =
      requiredManagedPaths
          ? RexValidatedExtensionPaths(requiredManagedPaths,
                                       &pathValidationError)
          : nil;
  NSArray<NSString *> *validatedEnabledPaths = validatedManagedPaths
      ? RexValidatedExtensionPaths(requiredEnabledPaths, &pathValidationError)
      : nil;
  NSString *internalDownloadUIExtensionID = internalDownloadUIExtensionPath
      ? RexExtensionManifestMetadata(internalDownloadUIExtensionPath)[@"id"]
      : nil;
  if (validatedManagedPaths && validatedEnabledPaths &&
      !internalDownloadUIExtensionID.length) {
    pathValidationError = RexExtensionRuntimeError(
        34, @"Rex 内部 Chromium 下载 UI 控制扩展身份无效");
    validatedManagedPaths = nil;
    validatedEnabledPaths = nil;
  }
  if (validatedManagedPaths && validatedEnabledPaths) {
    NSSet<NSString *> *managedSet =
        [NSSet setWithArray:validatedManagedPaths];
    for (NSString *path in validatedEnabledPaths) {
      if (![managedSet containsObject:path]) {
        pathValidationError = RexExtensionRuntimeError(
            33,
            @"启动时启用的扩展路径不在 Rex 管理集合中",
            @{@"rejectedPaths": @[path]});
        validatedEnabledPaths = nil;
        break;
      }
    }
  }
  if (!validatedManagedPaths || !validatedEnabledPaths) {
    if (error) *error = pathValidationError;
    return NO;
  }

  NSString *rootPath =
      cacheRoot.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString *profilePath = [rootPath stringByAppendingPathComponent:@"Default"];
  NSError *profileDirectoryError = nil;
  if (![NSFileManager.defaultManager
          createDirectoryAtPath:profilePath
    withIntermediateDirectories:YES
                     attributes:nil
                          error:&profileDirectoryError]) {
    if (error) {
      *error = [NSError errorWithDomain:RexChromiumErrorDomain
                                   code:2
                               userInfo:@{
                                 NSLocalizedDescriptionKey:
                                     @"无法创建 Chromium 用户资料目录",
                                 NSUnderlyingErrorKey: profileDirectoryError
                               }];
    }
    return NO;
  }

  _internalDownloadUIExtensionPath =
      [internalDownloadUIExtensionPath copy];
  _managedExtensionPaths = [validatedManagedPaths copy];
  _enabledExtensionPaths = [validatedEnabledPaths copy];
  // Reconcile even an empty desired set before restored HTTP(S) documents can
  // navigate, so persisted unpacked extensions never inject into a first load.
  _extensionStartupBarrierActive = YES;

  // Chromium hard-codes descriptors 3/4 for --remote-debugging-pipe. Reserve
  // them before loading the CEF framework, whose initializers may open files.
  _extensionPipe = [[RexDevToolsPipeController alloc] init];
  NSError *extensionPipeError = nil;
  if (![_extensionPipe prepareWithError:&extensionPipeError]) {
    NSError *startupError = extensionPipeError ?: RexExtensionRuntimeError(
        32, @"无法初始化 Chromium 扩展控制管道");
    NSLog(@"[Rex] extension runtime initialization failed closed: %@",
          startupError.localizedDescription);
    if (error) *error = startupError;
    [_extensionPipe shutdown];
    [_extensionPipe releaseChromiumDescriptors];
    _extensionPipe = nil;
    _extensionStartupBarrierActive = NO;
    return NO;
  }
  [_extensionPipe startReading];

  _libraryLoader = std::make_unique<CefScopedLibraryLoader>();
  if (!_libraryLoader->LoadInMain()) {
    if (error) {
      *error = [NSError errorWithDomain:RexChromiumErrorDomain
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey:
                                            @"无法从 Rex.app/Contents/Frameworks 加载 CEF"}];
    }
    [_extensionPipe shutdown];
    [_extensionPipe releaseChromiumDescriptors];
    _extensionPipe = nil;
    _extensionStartupBarrierActive = NO;
    _libraryLoader.reset();
    return NO;
  }

  NSData *publicSuffixData = publicSuffixListURL.isFileURL
      ? [NSData dataWithContentsOfURL:publicSuffixListURL]
      : nil;
  NSData *privacyCatalogData = privacyCatalogURL.isFileURL
      ? [NSData dataWithContentsOfURL:privacyCatalogURL]
      : nil;
  std::string publicSuffixContents;
  if (publicSuffixData.length > 0) {
    publicSuffixContents.assign(
        static_cast<const char *>(publicSuffixData.bytes),
        publicSuffixData.length);
  }
  std::string privacyCatalogContents;
  if (privacyCatalogData.length > 0) {
    privacyCatalogContents.assign(
        static_cast<const char *>(privacyCatalogData.bytes),
        privacyCatalogData.length);
  }
  if (publicSuffixContents.empty() || privacyCatalogContents.empty()) {
    if (error) {
      *error = [NSError errorWithDomain:RexChromiumErrorDomain
                                   code:3
                               userInfo:@{NSLocalizedDescriptionKey:
                                  @"Rex 隐私安全资源缺失或无效"}];
    }
    [_extensionPipe shutdown];
    [_extensionPipe releaseChromiumDescriptors];
    _extensionPipe = nil;
    _extensionStartupBarrierActive = NO;
    _libraryLoader.reset();
    return NO;
  }

  int argc = *_NSGetArgc();
  char **argv = *_NSGetArgv();
  std::vector<char *> cefArgv(argv, argv + argc);
  CefMainArgs mainArgs(static_cast<int>(cefArgv.size()), cefArgv.data());
  CefSettings settings;
  settings.external_message_pump = true;
  settings.no_sandbox = false;
  settings.persist_session_cookies = true;
  settings.log_severity = LOGSEVERITY_WARNING;
  settings.background_color = CefColorSetARGB(255, 245, 245, 247);

  CefString(&settings.root_cache_path) = RexUTF8(rootPath);
  CefString(&settings.cache_path) = RexUTF8(profilePath);
  CefString(&settings.locale) = RexUTF8(locale.length ? locale : @"zh-CN");
  const BOOL extensionPipeEnabled = YES;

  std::vector<std::string> chromiumExtensionPaths;
  chromiumExtensionPaths.reserve(validatedManagedPaths.count);
  for (NSString *path in validatedManagedPaths) {
    chromiumExtensionPaths.push_back(RexUTF8(path));
  }

  CefRefPtr<RexDefaultChromeClient> defaultChromeClient =
      new RexDefaultChromeClient(self);
  _application = new RexCEFApp(_blockThirdPartyCookiesPreference,
                               std::move(chromiumExtensionPaths),
                               defaultChromeClient,
                               self,
                               extensionPipeEnabled);
  // Reserve generation 1 before CefInitialize can post OnContextInitialized.
  // Any hot request queued as startup returns is therefore ordered after this
  // exact-set reconciliation, and commit events stay generation-monotonic.
  [self enqueueExtensionSyncManagedPaths:validatedManagedPaths
                            enabledPaths:validatedEnabledPaths
                            removedPaths:@[]
                        forceReloadPaths:@[]
                                 startup:YES
                              completion:nil];
  if (!CefInitialize(mainArgs, settings, _application, nullptr)) {
    const int exitCode = CefGetExitCode();
    if (error) {
      NSString *description =
          exitCode == CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED
              ? @"现有 Rex 进程已处理本次启动请求"
              : [NSString stringWithFormat:@"CEF 初始化失败（%d）", exitCode];
      *error = [NSError errorWithDomain:RexChromiumErrorDomain
                                   code:exitCode
                               userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    _application = nullptr;
    [_extensionPipe shutdown];
    [_extensionPipe releaseChromiumDescriptors];
    _extensionPipe = nil;
    [_extensionSyncQueue removeAllObjects];
    _activeExtensionSyncRequest = nil;
    _extensionSyncActive = NO;
    _extensionStartupBarrierActive = NO;
    _libraryLoader.reset();
    return NO;
  }

  // PSL normalization uses Chromium's URL parser for IDN handling, which is
  // only valid after CefInitialize. Configure it before the first pump turn so
  // no browser request can observe an uninitialized site-ownership catalog.
  if (!rex::privacy::ConfigurePublicSuffixList(publicSuffixContents) ||
      !rex::privacy::ConfigurePrivacyCatalog(privacyCatalogContents)) {
    if (error) {
      *error = [NSError errorWithDomain:RexChromiumErrorDomain
                                   code:3
                               userInfo:@{NSLocalizedDescriptionKey:
                                  @"Rex 隐私安全资源缺失或无效"}];
    }
    [_extensionPipe shutdown];
    CefShutdown();
    [_extensionPipe releaseChromiumDescriptors];
    _extensionPipe = nil;
    [_extensionSyncQueue removeAllObjects];
    _activeExtensionSyncRequest = nil;
    _extensionSyncActive = NO;
    _extensionStartupBarrierActive = NO;
    _application = nullptr;
    _libraryLoader.reset();
    return NO;
  }

  _ready = YES;
  static dispatch_once_t shutdownRegistration;
  dispatch_once(&shutdownRegistration, ^{
    std::atexit(RexShutdownCEFAtProcessExit);
  });
  NSLog(@"[Rex] performance layer=%s · content filter=host-catalogs (toggleable)",
        rex::thorium::ProfileName());
  NSLog(@"[Rex] Chromium extension runtime: %lu enabled package(s)",
        (unsigned long)validatedEnabledPaths.count);
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
        self->_pendingTabs.contains(key) || self->_views[tabID] != view ||
        !view.window || !view.superview) {
      return;
    }
    self->_pendingTabs.insert(key);

    CefWindowInfo windowInfo;
    const NSRect bounds = view.bounds;
    windowInfo.SetAsChild((__bridge CefWindowHandle)view,
                          CefRect(0, 0, std::max(1, (int)bounds.size.width),
                                  std::max(1, (int)bounds.size.height)));
    CefBrowserSettings browserSettings;
    browserSettings.background_color = CefColorSetARGB(255, 255, 255, 255);
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
    NSString *effectiveInitialURL = self->_pendingURLs[tabID] ?:
        (initialURL.length ? [initialURL copy] : @"about:blank");
    const BOOL useEmbeddedChromeRuntime =
        RexShouldUseEmbeddedChromeRuntime(effectiveInitialURL,
                                          privateBrowsing);
    if (self->_extensionStartupBarrierActive &&
        RexURLWaitsForExtensionRuntime(effectiveInitialURL)) {
      self->_pendingURLs[tabID] = effectiveInitialURL;
      self->_startupPlaceholderTabs.insert(key);
      effectiveInitialURL = @"about:blank";
    }
    CefRefPtr<RexBrowserClient> client =
        new RexBrowserClient(self, tabID);
    const std::string url = RexUTF8(effectiveInitialURL);
    CefRefPtr<CefDictionaryValue> extraInfo;
    NSDictionary<NSString *, id> *extensionActionContext =
        [self extensionActionContextForSurfaceTabID:tabID];
    if (extensionActionContext) {
      extraInfo = CefDictionaryValue::Create();
      extraInfo->SetInt(
          "rexExtensionActionTabID",
          [static_cast<NSNumber *>(extensionActionContext[@"tabID"])
              intValue]);
    }
    if (useEmbeddedChromeRuntime) {
      const CefSize initialSize(
          std::max(1, static_cast<int>(bounds.size.width)),
          std::max(1, static_cast<int>(bounds.size.height)));
      CefRefPtr<CefBrowserView> browserView =
          CefBrowserView::CreateBrowserView(
              client, url, browserSettings, extraInfo, requestContext,
              new RexExtensionChromeBrowserViewDelegate());
      if (!browserView) {
        self->_pendingTabs.erase(key);
        self->_startupPlaceholderTabs.erase(key);
        [self emitEvent:RexEvent(
            @"error", tabID,
            @{ @"message": @"CEF Chrome 页面实例创建失败" })];
        return;
      }
      self->_embeddedChromeTabs.insert(key);
      self->_embeddedChromeBrowserViews[key] = browserView;
      CefRefPtr<CefWindow> window = CefWindow::CreateTopLevelWindow(
          new RexExtensionChromeWindowDelegate(browserView, initialSize,
                                                false));
      if (!window) {
        self->_embeddedChromeBrowserViews.erase(key);
        self->_embeddedChromeTabs.erase(key);
        self->_pendingTabs.erase(key);
        self->_startupPlaceholderTabs.erase(key);
        [self emitEvent:RexEvent(
            @"error", tabID,
            @{ @"message": @"CEF Chrome 页面窗口创建失败" })];
      }
      return;
    }
    CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
        windowInfo, client, url, browserSettings, extraInfo, requestContext);
    if (!browser) {
      self->_pendingTabs.erase(key);
      self->_startupPlaceholderTabs.erase(key);
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

- (void)handleDefaultChromeBrowser:(CefRefPtr<CefBrowser>)browser
                         targetURL:(nullable NSString *)targetURL {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;

  [self parkDefaultChromeBrowser:browser];

  NSString *sourceTabID = nil;
  if (_focusedTabID.length && ![_privateTabs[_focusedTabID] boolValue]) {
    sourceTabID = [_focusedTabID copy];
  } else if (_lastFocusedTabID.length &&
             ![_privateTabs[_lastFocusedTabID] boolValue]) {
    sourceTabID = [_lastFocusedTabID copy];
  } else {
    for (const auto &entry : _browsers) {
      NSString *candidate =
          [[NSString alloc] initWithUTF8String:entry.first.c_str()] ?: @"";
      if (candidate.length && ![_privateTabs[candidate] boolValue]) {
        sourceTabID = candidate;
        break;
      }
    }
  }
  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  NSString *capturedURL = targetURL.length
      ? [targetURL copy]
      : frame ? RexNSString(frame->GetURL()) : @"";

  // Chrome UI operations such as chrome.tabs.create do not pass an originating
  // CefClient. Capture a regular Rex source synchronously so a later focus
  // change (especially into a private tab) cannot change attribution.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    if (sourceTabID.length && RexCanForwardPopupURL(capturedURL)) {
      [self emitEvent:RexEvent(@"popup", sourceTabID, @{
        @"url": capturedURL,
        @"foreground": @YES,
        @"userGesture": @YES
      })];
    }
    NSLog(@"[Rex] closed unmanaged Chrome UI browser=%d runtime style=%d url=%@",
          browser->GetIdentifier(),
          static_cast<int>(browser->GetHost()->GetRuntimeStyle()), capturedURL);
    browser->GetHost()->CloseBrowser(true);
  });
}

- (void)parkDefaultChromeBrowser:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;

  NSView *nativeView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  NSWindow *nativeWindow = nativeView.window;
  if (nativeWindow) {
    nativeWindow.alphaValue = 0.01;
    nativeWindow.ignoresMouseEvents = YES;
    nativeWindow.hasShadow = NO;
    nativeWindow.excludedFromWindowsMenu = YES;
    [nativeWindow orderOut:nil];
  }
}

- (void)registerExtensionChromeWindowHost:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;
  NSView *nativeView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  NSWindow *nativeWindow = nativeView.window;
  if (nativeWindow) {
    nativeWindow.alphaValue = 0.01;
    nativeWindow.ignoresMouseEvents = YES;
    nativeWindow.hasShadow = NO;
    nativeWindow.excludedFromWindowsMenu = YES;
    [nativeWindow orderOut:nil];
  }
  _extensionChromeWindowHostReady = YES;
  NSLog(@"[Rex] Chromium extension window context ready browser=%d",
        browser->GetIdentifier());
  [self startNextExtensionSyncIfNeeded];
}

- (void)extensionChromeWindowHostDidClose {
  CEF_REQUIRE_UI_THREAD();
  _extensionChromeWindowHostReady = NO;
  ++_extensionChromeWindowHostEpoch;
  const BOOL hostRequired =
      _managedExtensionPaths.count > 0 ||
      _activeExtensionSyncRequest.managedPaths.count > 0 ||
      _extensionSyncQueue.firstObject.managedPaths.count > 0;
  if (!_shuttingDown && hostRequired && _application) {
    _application->EnsureExtensionWindowHost();
  }
  [self startNextExtensionSyncIfNeeded];
  [self finishTerminationIfReady];
}

- (void)defaultChromeBrowserDidClose {
  CEF_REQUIRE_UI_THREAD();
  [self finishTerminationIfReady];
}

- (void)registerChromePopupBrowser:(CefRefPtr<CefBrowser>)browser
                        sourceTabID:(NSString *)sourceTabID {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;
  const int browserID = browser->GetIdentifier();
  _chromePopupBrowsers[browserID] = browser;

  NSView *nativeView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  NSWindow *popupWindow = nativeView.window;
  if (popupWindow) {
    popupWindow.alphaValue = 0.01;
    popupWindow.ignoresMouseEvents = YES;
    popupWindow.hasShadow = NO;
    popupWindow.excludedFromWindowsMenu = YES;
    _chromePopupWindowsByBrowserID[@(browserID)] = popupWindow;
  }
  NSLog(@"[Rex] extension popup browser=%d runtime style=%d source=%@",
        browserID,
        static_cast<int>(browser->GetHost()->GetRuntimeStyle()),
        sourceTabID);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    CefRefPtr<CefFrame> frame = browser->GetMainFrame();
    NSString *url = frame ? RexNSString(frame->GetURL()) : @"";
    if (!self->_shuttingDown && sourceTabID.length &&
        RexCanForwardPopupURL(url)) {
      [self emitEvent:RexEvent(@"popup", sourceTabID, @{
        @"url": url,
        @"foreground": @YES,
        @"userGesture": @YES
      })];
    }
    browser->GetHost()->CloseBrowser(true);
  });
}

- (void)registerAuxiliaryChromeBrowser:(CefRefPtr<CefBrowser>)browser
                           sourceTabID:(NSString *)sourceTabID {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;
  const int browserID = browser->GetIdentifier();
  _auxiliaryChromeBrowsers[browserID] = browser;
  NSView *nativeView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  NSWindow *nativeWindow = nativeView.window;
  if (nativeWindow) {
    nativeWindow.alphaValue = 0.01;
    nativeWindow.ignoresMouseEvents = YES;
    nativeWindow.hasShadow = NO;
    nativeWindow.excludedFromWindowsMenu = YES;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    CefRefPtr<CefFrame> frame = browser->GetMainFrame();
    NSString *url = frame ? RexNSString(frame->GetURL()) : @"";
    if (!self->_shuttingDown && sourceTabID.length &&
        RexCanForwardPopupURL(url)) {
      [self emitEvent:RexEvent(@"popup", sourceTabID, @{
        @"url": url,
        @"foreground": @YES,
        @"userGesture": @YES
      })];
    }
    NSLog(@"[Rex] closed auxiliary Chrome tab browser=%d source=%@ url=%@",
          browserID, sourceTabID, url);
    browser->GetHost()->CloseBrowser(true);
  });
}

- (void)auxiliaryChromeBrowserDidClose:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  _auxiliaryChromeBrowsers.erase(browser->GetIdentifier());
  [self finishTerminationIfReady];
}

- (void)chromePopupBrowserDidClose:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  const int browserID = browser->GetIdentifier();
  _chromePopupBrowsers.erase(browserID);
  NSNumber *key = @(browserID);
  NSWindow *popupWindow = _chromePopupWindowsByBrowserID[key];
  [popupWindow orderOut:nil];
  [_chromePopupWindowsByBrowserID removeObjectForKey:key];
  [self finishTerminationIfReady];
}

- (void)embeddedChromeWindowDidBecomeKey:(NSNotification *)notification {
  NSWindow *chromeWindow = (NSWindow *)notification.object;
  if (!chromeWindow || _shuttingDown) return;

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_shuttingDown) return;
    NSNumber *browserID = nil;
    for (NSNumber *candidate in self->_embeddedChromeWindowsByBrowserID) {
      if (self->_embeddedChromeWindowsByBrowserID[candidate] == chromeWindow) {
        browserID = candidate;
        break;
      }
    }
    if (!browserID) return;

    CefRefPtr<CefBrowser> browser;
    NSString *tabID = nil;
    for (const auto &entry : self->_browsers) {
      if (entry.second && entry.second->GetIdentifier() == browserID.intValue) {
        browser = entry.second;
        tabID = [[NSString alloc] initWithUTF8String:entry.first.c_str()];
        break;
      }
    }
    RexChromiumBrowserView *hostView = tabID ? self->_views[tabID] : nil;
    if (!browser || !browser->IsValid() || !hostView.window) return;
    self->_focusedTabID = [tabID copy];
    self->_lastFocusedTabID = [tabID copy];
    // Transfer key window status back to Rex's parent window so screenshot
    // tools and window managers see the full Rex chrome. Chromium still
    // receives keyboard focus via SetFocus.
    NSWindow *parentWindow = hostView.window;
    if (parentWindow && parentWindow != chromeWindow &&
        ![parentWindow isKeyWindow]) {
      [parentWindow makeKeyAndOrderFront:nil];
    }
    browser->GetHost()->SetFocus(true);
    [self emitEvent:RexEvent(@"focused", tabID)];
  });
}

- (void)developerToolsPopupDidBecomeKey:(NSNotification *)notification {
  NSWindow *popupWindow = (NSWindow *)notification.object;
  if (!popupWindow || _shuttingDown) return;

  // Some frontend actions (notably completing element inspection) reposition
  // the Chrome host. Let activation unwind, then realign it with Rex's dock.
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
    [self syncEmbeddedChromeWindow:popupWindow
                       toHostView:hostView
                          browser:browser];
    [hostView.window makeMainWindow];
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
  [parentView.window makeMainWindow];
  [popupWindow makeKeyAndOrderFront:nil];
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
    [host.window makeMainWindow];
    [retainedPopup makeKeyAndOrderFront:nil];
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
  // Chrome may reposition its DevTools window after OnAfterCreated. Align the
  // retained native window again once the frontend is ready.
  NSWindow *popupWindow =
      _developerToolsPopupWindowsByBrowserID[@(browser->GetIdentifier())];
  RexChromiumDevToolsView *hostView = _developerToolsViews[tabID];
  [self syncEmbeddedChromeWindow:popupWindow
                     toHostView:hostView
                        browser:browser];
  if (hostView.window) {
    [hostView.window makeMainWindow];
    [popupWindow makeKeyAndOrderFront:nil];
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
  NSWindow *popupWindow = _developerToolsPopupWindowsByBrowserID[browserID];
  if (popupWindow) {
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:NSWindowDidBecomeKeyNotification
                object:popupWindow];
    NSWindow *parentWindow = popupWindow.parentWindow;
    if (parentWindow) [parentWindow removeChildWindow:popupWindow];
    [popupWindow orderOut:nil];
  }
  [_developerToolsPopupWindowsByBrowserID removeObjectForKey:browserID];

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
  if (!_shuttingDown) return;
  const size_t defaultBrowserCount =
      _application ? _application->DefaultBrowserCount() : 0;
  NSLog(@"[Rex] Chromium termination state: tabs=%lu, pending=%lu, auxiliary=%lu, popups=%lu, devtools=%lu, openingDevtools=%lu, defaults=%lu",
        static_cast<unsigned long>(_browsers.size()),
        static_cast<unsigned long>(_pendingTabs.size()),
        static_cast<unsigned long>(_auxiliaryChromeBrowsers.size()),
        static_cast<unsigned long>(_chromePopupBrowsers.size()),
        static_cast<unsigned long>(_developerToolsBrowsers.size()),
        static_cast<unsigned long>(_developerToolsOpeningTabs.size()),
        static_cast<unsigned long>(defaultBrowserCount));
  if (_browsers.empty() && _auxiliaryChromeBrowsers.empty() &&
      _pendingTabs.empty() && _chromePopupBrowsers.empty() &&
      _developerToolsBrowsers.empty() && _developerToolsOpeningTabs.empty() &&
      defaultBrowserCount == 0) {
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

- (void)registerBrowser:(CefRefPtr<CefBrowser>)browser
                  tabID:(NSString *)tabID
        deferPendingURL:(BOOL)deferPendingURL {
  const std::string key = RexUTF8(tabID);
  _pendingTabs.erase(key);
  RexChromiumBrowserView *parentView = _views[tabID];
  if (!parentView || _shuttingDown) {
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  _browsers[key] = browser;

  const bool embeddedChrome =
      _embeddedChromeTabs.contains(key) &&
      browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME;
  NSNumber *browserID = @(browser->GetIdentifier());
  NSView *nativeView =
      (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  NSWindow *chromeWindow = embeddedChrome ? nativeView.window : nil;
  if (embeddedChrome && nativeView) {
    _embeddedChromeNativeViewsByBrowserID[browserID] = nativeView;
    if (chromeWindow && chromeWindow != parentView.window) {
      _embeddedChromeWindowsByBrowserID[browserID] = chromeWindow;
      [NSNotificationCenter.defaultCenter
          addObserver:self
             selector:@selector(embeddedChromeWindowDidBecomeKey:)
                 name:NSWindowDidBecomeKeyNotification
               object:chromeWindow];
    }
  }
  if (nativeView) {
    // Layout the host before attaching so the child gets its final frame on the
    // first pass instead of briefly painting at the representable's zero size.
    [parentView setNeedsLayout:YES];
    [parentView layoutSubtreeIfNeeded];
    [self syncNativeBrowserView:nativeView
                     toHostView:parentView
                        browser:browser
                    popupWindow:chromeWindow];

    // SwiftUI often finalizes the NSViewRepresentable frame one runloop later.
    // A deferred sync prevents the first paint from locking onto a zero-size host.
    NSString *tabCopy = [tabID copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      RexChromiumBrowserView *host = self->_views[tabCopy];
      CefRefPtr<CefBrowser> live = [self browserForTabID:tabCopy];
      if (!host || !live || !live->IsSame(browser)) return;
      [host setNeedsLayout:YES];
      [host layoutSubtreeIfNeeded];
      NSView *attached =
          (__bridge NSView *)live->GetHost()->GetWindowHandle();
      [self syncNativeBrowserView:attached
                       toHostView:host
                          browser:live
                      popupWindow:self->_embeddedChromeWindowsByBrowserID[
                          @(live->GetIdentifier())]];
    });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [self forceBrowserRepaintForTabID:tabCopy];
        });
    if (embeddedChrome) {
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            RexChromiumBrowserView *host = self->_views[tabCopy];
            CefRefPtr<CefBrowser> live = [self browserForTabID:tabCopy];
            if (!host || !live || !live->IsValid() ||
                !live->IsSame(browser)) {
              return;
            }
            NSWindow *retainedWindow =
                self->_embeddedChromeWindowsByBrowserID[
                    @(live->GetIdentifier())];
            NSView *attached =
                (__bridge NSView *)live->GetHost()->GetWindowHandle();
            [self syncNativeBrowserView:attached
                             toHostView:host
                                browser:live
                            popupWindow:retainedWindow];
            if ([self->_focusedTabID isEqualToString:tabCopy]) {
              live->GetHost()->SetFocus(true);
            }
          });
    }
  }

  [self emitEvent:RexEvent(@"created", tabID)];
  NSNumber *muted = _mutedTabs[tabID];
  if (muted) browser->GetHost()->SetAudioMuted(muted.boolValue);
  // A restored URL can arrive before BrowserView creation finishes. Apply the
  // newest request after the CEF frame has been attached.
  NSString *pendingURL = _pendingURLs[tabID];
  if (pendingURL && !_extensionStartupBarrierActive && !deferPendingURL) {
    if (RexShouldUseEmbeddedChromeRuntime(
            pendingURL, [_privateTabs[tabID] boolValue]) &&
        browser->GetHost()->GetRuntimeStyle() != CEF_RUNTIME_STYLE_CHROME) {
      _browserReplacementTabs.insert(key);
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
    const std::string requestedURL = RexUTF8(pendingURL);
    if (mainFrame && mainFrame->GetURL().ToString() != requestedURL) {
      mainFrame->LoadURL(requestedURL);
    }
    [_pendingURLs removeObjectForKey:tabID];
  }
  if (_shuttingDown) browser->GetHost()->CloseBrowser(true);
}

- (nullable NSString *)consumePendingURLForTabID:(NSString *)tabID
                                      fallbackURL:(NSString *)fallbackURL {
  NSString *pendingURL = [_pendingURLs[tabID] copy] ?: [fallbackURL copy];
  [_pendingURLs removeObjectForKey:tabID];
  return pendingURL;
}

- (void)browser:(CefRefPtr<CefBrowser>)browser
    preferredContentSizeDidChange:(NSSize)size
                            tabID:(NSString *)tabID {
  const std::string key = RexUTF8(tabID);
  auto browserIterator = _browsers.find(key);
  if (browserIterator == _browsers.end() ||
      !browserIterator->second->IsSame(browser)) {
    return;
  }
  RexChromiumBrowserView *view = _views[tabID];
  RexChromiumBrowserPreferredSizeHandler handler =
      view.preferredSizeDidChangeHandler;
  if (handler) handler(size);
}

- (nullable NSDictionary<NSString *, id> *)
    extensionActionContextForSurfaceTabID:(NSString *)tabID {
  CEF_REQUIRE_UI_THREAD();
  NSArray<NSString *> *components = [tabID componentsSeparatedByString:@":"];
  NSUUID *sourceTabUUID = components.count == 4 &&
                                 ![components[1] isEqualToString:@"none"]
      ? [[NSUUID alloc] initWithUUIDString:components[1]]
      : nil;
  if (components.count != 4 ||
      ![components[0] isEqualToString:@"rex-extension-surface"] ||
      sourceTabUUID == nil) {
    return nil;
  }

  NSString *sourceTabID = sourceTabUUID.UUIDString;
  if ([_privateTabs[sourceTabID] boolValue]) return nil;
  CefRefPtr<CefBrowser> sourceBrowser = [self browserForTabID:sourceTabID];
  const int sourceBrowserID =
      sourceBrowser ? sourceBrowser->GetIdentifier() : 0;
  CefRefPtr<CefFrame> sourceFrame =
      sourceBrowser ? sourceBrowser->GetMainFrame() : nullptr;
  if (sourceBrowserID <= 0 || !sourceFrame || !sourceFrame->IsValid()) {
    return nil;
  }

  NSString *sourceURL = RexNSString(sourceFrame->GetURL());
  NSURLComponents *url = [NSURLComponents componentsWithString:sourceURL];
  NSString *scheme = url.scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] &&
      ![scheme isEqualToString:@"https"]) {
    return nil;
  }
  return @{
    @"tabID": @(sourceBrowserID)
  };
}

- (BOOL)shouldHideStartupPlaceholderForTabID:(NSString *)tabID
                                   currentURL:(NSString *)currentURL {
  const std::string key = RexUTF8(tabID);
  const bool awaitsRealAddress = _startupPlaceholderTabs.contains(key);
  return rex::navigation::ShouldHideStartupPlaceholder(
      awaitsRealAddress, RexUTF8(currentURL));
}

- (void)didCommitStartupAddressForTabID:(NSString *)tabID
                              currentURL:(NSString *)currentURL {
  const std::string url = RexUTF8(currentURL);
  if (!url.empty() && url != "about:blank") {
    const std::string key = RexUTF8(tabID);
    _startupPlaceholderTabs.erase(key);
  }
}

- (void)browser:(CefRefPtr<CefBrowser>)browser
        didCloseForTabID:(NSString *)tabID {
  [self cancelPermissionRequestsForTabID:tabID];
  [self removeDownloadCallbacksForTabID:tabID];
  const std::string key = RexUTF8(tabID);
  RexChromiumBrowserView *closedView = _views[tabID];
  const bool replacingBrowser =
      !_shuttingDown && closedView &&
      _browserReplacementTabs.erase(key) > 0;
  RexChromiumBrowserDidCloseHandler closeHandler =
      closedView.browserDidCloseHandler;
  if (!replacingBrowser) closedView.browserDidCloseHandler = nil;
  auto browserIterator = _browsers.find(key);
  if (browserIterator != _browsers.end() &&
      browserIterator->second->IsSame(browser)) {
    _browsers.erase(browserIterator);
  }
  NSNumber *browserID = @(browser->GetIdentifier());
  NSWindow *embeddedWindow = _embeddedChromeWindowsByBrowserID[browserID];
  if (embeddedWindow) {
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:NSWindowDidBecomeKeyNotification
                object:embeddedWindow];
    NSWindow *parentWindow = embeddedWindow.parentWindow;
    if (parentWindow) [parentWindow removeChildWindow:embeddedWindow];
    [embeddedWindow orderOut:nil];
  }
  [_embeddedChromeWindowsByBrowserID removeObjectForKey:browserID];
  [_embeddedChromeNativeViewsByBrowserID removeObjectForKey:browserID];
  _embeddedChromeBrowserViews.erase(key);
  _embeddedChromeTabs.erase(key);
  _developerToolsDesiredTabs.erase(key);
  _pendingDeveloperToolsRequests.erase(key);
  _pendingDeveloperToolsFrontendActions.erase(key);
  _developerToolsFrontendReadyBrowserIDs.erase(key);
  if (_developerToolsBrowsers.contains(key) ||
      _developerToolsOpeningTabs.contains(key)) {
    _developerToolsClosingTabs.insert(key);
  }
  _pendingTabs.erase(key);
  if (replacingBrowser) {
    NSString *replacementURL = [_pendingURLs[tabID] copy] ?: @"about:blank";
    NSString *profileID = [_tabProfileIDs[tabID] copy] ?: @"";
    const BOOL privateBrowsing = [_privateTabs[tabID] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
      RexChromiumBrowserView *view = self->_views[tabID];
      if (!view || !view.window || !view.superview || self->_shuttingDown) {
        [self closeTabID:tabID];
        return;
      }
      NSString *latestURL = self->_pendingURLs[tabID] ?: replacementURL;
      [self createBrowserInView:view
                         tabID:tabID
                    initialURL:latestURL
                     profileID:profileID
               privateBrowsing:privateBrowsing];
    });
    [self finishTerminationIfReady];
    return;
  }
  _browserReplacementTabs.erase(key);
  _startupPlaceholderTabs.erase(key);
  _suspendedTabs.erase(key);
  _needsExtensionReloadTabs.erase(key);
  [_pendingURLs removeObjectForKey:tabID];
  [_views removeObjectForKey:tabID];
  [_developerToolsViews removeObjectForKey:tabID];
  [_mutedTabs removeObjectForKey:tabID];
  @synchronized (_privacyPolicies) {
    [_privacyPolicies removeObjectForKey:tabID];
  }
  [_downloadDirectories removeObjectForKey:tabID];
  if ([_focusedTabID isEqualToString:tabID]) _focusedTabID = nil;
  [self releaseProfileForTabID:tabID];
  [self emitEvent:RexEvent(@"closed", tabID)];
  if (closeHandler) closeHandler();
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

- (void)cancelAllDownloadsForTermination {
  std::vector<CefRefPtr<CefDownloadItemCallback>> callbacks;
  callbacks.reserve(self->_downloadCallbacks.size());
  for (auto &entry : self->_downloadCallbacks) {
    if (entry.second) callbacks.push_back(std::move(entry.second));
  }
  self->_downloadCallbacks.clear();
  for (const auto &callback : callbacks) callback->Cancel();
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

- (nullable NSWindow *)hostWindowForTabID:(NSString *)tabID {
  NSAssert(NSThread.isMainThread, @"CEF dialogs are main-thread only");
  return _views[tabID].window;
}

- (CefRefPtr<CefBrowser>)developerToolsBrowserForTabID:(NSString *)tabID {
  auto iterator = _developerToolsBrowsers.find(RexUTF8(tabID));
  return iterator == _developerToolsBrowsers.end() ? nullptr : iterator->second;
}

- (void)syncNativeBrowserView:(NSView *)nativeView
                   toHostView:(NSView *)hostView
                      browser:(CefRefPtr<CefBrowser>)browser {
  NSWindow *popupWindow = browser
      ? _embeddedChromeWindowsByBrowserID[@(browser->GetIdentifier())]
      : nil;
  [self syncNativeBrowserView:nativeView
                   toHostView:hostView
                      browser:browser
                  popupWindow:popupWindow];
}

- (void)syncEmbeddedChromeWindow:(nullable NSWindow *)chromeWindow
                       toHostView:(NSView *)hostView
                          browser:(CefRefPtr<CefBrowser>)browser {
  if (!chromeWindow || !hostView || !browser) return;

  NSWindow *hostWindow = hostView.window;
  const NSRect rawBounds = hostView.bounds;
  const BOOL canPresent =
      hostWindow && hostView.superview && !hostView.isHiddenOrHasHiddenAncestor &&
      !NSIsEmptyRect(rawBounds) && rawBounds.size.width >= 1 &&
      rawBounds.size.height >= 1;
  if (!canPresent) {
    NSWindow *parentWindow = chromeWindow.parentWindow;
    if (parentWindow) [parentWindow removeChildWindow:chromeWindow];
    [chromeWindow orderOut:nil];
    return;
  }

  const NSRect hostRectInWindow = [hostView convertRect:rawBounds toView:nil];
  const NSRect rawScreenFrame =
      [hostWindow convertRectToScreen:hostRectInWindow];
  const NSRect screenFrame = NSMakeRect(
      floor(rawScreenFrame.origin.x), floor(rawScreenFrame.origin.y),
      floor(rawScreenFrame.size.width), floor(rawScreenFrame.size.height));
  if (screenFrame.size.width < 1 || screenFrame.size.height < 1) return;

  chromeWindow.alphaValue = 1;
  chromeWindow.ignoresMouseEvents = NO;
  chromeWindow.hasShadow = NO;
  chromeWindow.styleMask = NSWindowStyleMaskBorderless;
  chromeWindow.excludedFromWindowsMenu = YES;
  chromeWindow.accessibilityHidden = NO;
  chromeWindow.collectionBehavior |=
      NSWindowCollectionBehaviorTransient |
      NSWindowCollectionBehaviorIgnoresCycle |
      NSWindowCollectionBehaviorFullScreenAuxiliary;

  const BOOL frameChanged = !NSEqualRects(chromeWindow.frame, screenFrame);
  const BOOL parentChanged = chromeWindow.parentWindow != hostWindow;
  @try {
    if (parentChanged) {
      NSWindow *previousParent = chromeWindow.parentWindow;
      if (previousParent) [previousParent removeChildWindow:chromeWindow];
    }
    if (frameChanged) [chromeWindow setFrame:screenFrame display:YES];
    if (parentChanged) {
      [hostWindow addChildWindow:chromeWindow ordered:NSWindowAbove];
    } else if (!chromeWindow.isVisible) {
      [chromeWindow orderWindow:NSWindowAbove
                     relativeTo:hostWindow.windowNumber];
    }
  } @catch (NSException *exception) {
    NSLog(@"[Rex] failed to align embedded Chrome window %@: %@",
          exception.name, exception.reason ?: @"unknown reason");
    [chromeWindow orderOut:nil];
    return;
  }

  CefRefPtr<CefBrowserView> browserView =
      CefBrowserView::GetForBrowser(browser);
  if (browserView) {
    const int width = std::max(1, static_cast<int>(screenFrame.size.width));
    const int height = std::max(1, static_cast<int>(screenFrame.size.height));
    browserView->SetBounds(CefRect(0, 0, width, height));
    CefRefPtr<CefWindow> window = browserView->GetWindow();
    if (window) window->Layout();
  }
}

- (void)syncNativeBrowserView:(NSView *)nativeView
                   toHostView:(NSView *)hostView
                      browser:(CefRefPtr<CefBrowser>)browser
                  popupWindow:(nullable NSWindow *)popupWindow {
  if (!nativeView || !hostView || !browser) return;

  NSNumber *browserID = @(browser->GetIdentifier());
  if ([hostView isKindOfClass:RexChromiumDevToolsView.class] && popupWindow &&
      popupWindow != hostView.window &&
      browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
    // Keep Chrome-style DevTools in its native AppKit window. Reparenting the
    // WebContents view into the Rex window leaves both the original Chrome
    // window and the Rex responder path participating in key dispatch on CEF
    // 151, which duplicates each text-input event.
    [self syncEmbeddedChromeWindow:popupWindow
                       toHostView:hostView
                          browser:browser];
    return;
  }

  NSWindow *embeddedWindow =
      _embeddedChromeWindowsByBrowserID[browserID];
  if (![hostView isKindOfClass:RexChromiumDevToolsView.class] &&
      embeddedWindow &&
      browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
    [self syncEmbeddedChromeWindow:embeddedWindow
                         toHostView:hostView
                            browser:browser];
    return;
  }

  // Replace the temporary window's content view before moving Chromium's view
  // so AppKit does not retain ownership from the temporary host.
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
    NSView *nativeView =
        (__bridge NSView *)browser->GetHost()->GetWindowHandle();
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
      NSView *nativeView =
          (__bridge NSView *)browser->GetHost()->GetWindowHandle();
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
    NSView *nativeView =
        (__bridge NSView *)browser->GetHost()->GetWindowHandle();
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
    const std::string key = RexUTF8(tabID);
    self->_browserReplacementTabs.erase(key);
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (browser) browser->GetHost()->CloseBrowser(true);
    else {
      [self cancelPermissionRequestsForTabID:tabID];
      self->_pendingTabs.erase(key);
      self->_startupPlaceholderTabs.erase(key);
      self->_suspendedTabs.erase(key);
      self->_needsExtensionReloadTabs.erase(key);
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
    const std::string key = RexUTF8(tabID);
    if (self->_extensionStartupBarrierActive &&
        RexURLWaitsForExtensionRuntime(urlString)) {
      self->_pendingURLs[tabID] = [urlString copy];
      self->_startupPlaceholderTabs.insert(key);
      return;
    }
    if (!RexURLWaitsForExtensionRuntime(urlString)) {
      // A non-gated navigation supersedes any older gated destination. Do not
      // let barrier release resurrect a stale restored URL.
      [self->_pendingURLs removeObjectForKey:tabID];
      self->_startupPlaceholderTabs.erase(key);
    }
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (browser) {
      if (self->_browserReplacementTabs.contains(key)) {
        self->_pendingURLs[tabID] = [urlString copy];
        return;
      }
      if (RexShouldUseEmbeddedChromeRuntime(
              urlString, [self->_privateTabs[tabID] boolValue]) &&
          browser->GetHost()->GetRuntimeStyle() !=
              CEF_RUNTIME_STYLE_CHROME) {
        self->_pendingURLs[tabID] = [urlString copy];
        self->_browserReplacementTabs.insert(key);
        browser->GetHost()->CloseBrowser(true);
        return;
      }
      CefRefPtr<CefFrame> frame = browser->GetMainFrame();
      const std::string requestedURL = RexUTF8(urlString);
      if (frame && frame->GetURL().ToString() == requestedURL) {
        browser->Reload();
        return;
      }
      if (frame) frame->LoadURL(RexUTF8(urlString));
    } else if (self->_tabProfileIDs[tabID]) {
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
- (void)exitFullscreenForTabID:(NSString *)tabID {
  [self onMain:^{
    CefRefPtr<CefBrowser> b = [self browserForTabID:tabID];
    if (b && b->GetHost()->IsFullscreen()) {
      b->GetHost()->ExitFullscreen(true);
    }
  }];
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

- (void)chromiumContextInitialized {
  NSAssert(NSThread.isMainThread,
           @"Chromium extension startup sync is main-thread serialized");
  if (_chromiumContextReady || _shuttingDown) return;
  _chromiumContextReady = YES;
  [self startNextExtensionSyncIfNeeded];
}

- (void)reloadExtensionRulesFromManagedPaths:
            (NSArray<NSString *> *)managedPaths
                                  enabledPaths:
                                      (NSArray<NSString *> *)enabledPaths
                                  removedPaths:
                                      (NSArray<NSString *> *)removedPaths
                              forceReloadPaths:
                                  (NSArray<NSString *> *)forceReloadPaths
                                    completion:
                                        (nullable RexChromiumExtensionRuntimeCompletion)
                                            completion {
  NSError *validationError = nil;
  NSString *internalDownloadUIExtensionPath =
      [_internalDownloadUIExtensionPath copy];
  if (!internalDownloadUIExtensionPath.length) {
    internalDownloadUIExtensionPath =
        RexInternalDownloadUIExtensionPath(&validationError);
  }
  NSArray<NSString *> *requiredManagedPaths =
      internalDownloadUIExtensionPath
          ? RexPathsIncludingInternalDownloadUIExtension(
                managedPaths, internalDownloadUIExtensionPath)
          : nil;
  NSArray<NSString *> *requiredEnabledPaths =
      internalDownloadUIExtensionPath
          ? RexPathsIncludingInternalDownloadUIExtension(
                enabledPaths, internalDownloadUIExtensionPath)
          : nil;
  NSArray<NSString *> *validatedManagedPaths =
      requiredManagedPaths
          ? RexValidatedExtensionPaths(requiredManagedPaths, &validationError)
          : nil;
  NSArray<NSString *> *validatedEnabledPaths = validatedManagedPaths
      ? RexValidatedExtensionPaths(requiredEnabledPaths, &validationError)
      : nil;
  NSArray<NSString *> *validatedRemovedPaths = validatedEnabledPaths
      ? RexValidatedRemovedExtensionPaths(removedPaths, &validationError)
      : nil;
  if (validatedRemovedPaths && internalDownloadUIExtensionPath.length) {
    NSMutableArray<NSString *> *userRemovedPaths =
        [validatedRemovedPaths mutableCopy];
    [userRemovedPaths removeObject:internalDownloadUIExtensionPath];
    validatedRemovedPaths = [userRemovedPaths copy];
  }
  NSArray<NSString *> *validatedForcedReloadPaths = validatedRemovedPaths
      ? RexValidatedExtensionPaths(forceReloadPaths, &validationError)
      : nil;
  if (validatedManagedPaths && validatedEnabledPaths &&
      validatedRemovedPaths && validatedForcedReloadPaths) {
    NSSet<NSString *> *managedSet =
        [NSSet setWithArray:validatedManagedPaths];
    NSSet<NSString *> *enabledSet =
        [NSSet setWithArray:validatedEnabledPaths];
    for (NSString *path in validatedEnabledPaths) {
      if (![managedSet containsObject:path]) {
        validationError = RexExtensionRuntimeError(
            33,
            @"启用的扩展路径不在 Rex 管理集合中",
            @{@"rejectedPaths": @[path]});
        validatedEnabledPaths = nil;
        break;
      }
    }
    for (NSString *path in validatedForcedReloadPaths) {
      if (![enabledSet containsObject:path]) {
        validationError = RexExtensionRuntimeError(
            33,
            @"强制重载路径不在启用的扩展集合中",
            @{@"rejectedPaths": @[path]});
        validatedForcedReloadPaths = nil;
        break;
      }
    }
    for (NSString *path in validatedRemovedPaths) {
      if ([managedSet containsObject:path]) {
        validationError = RexExtensionRuntimeError(
            33,
            @"同一个扩展路径不能同时标记为管理和删除",
            @{@"rejectedPaths": @[path]});
        validatedRemovedPaths = nil;
        break;
      }
    }
  }
  if (!validatedManagedPaths || !validatedEnabledPaths ||
      !validatedRemovedPaths || !validatedForcedReloadPaths) {
    [self onMain:^{
      NSLog(@"[Rex] rejected extension runtime request: %@",
            validationError.localizedDescription);
      [self emitEvent:RexEvent(
          @"extensionRuntimeError",
          @"",
          @{
            @"generation": @(self->_extensionRuntimeGeneration),
            @"loadedPaths": self->_enabledExtensionPaths ?: @[],
            @"message": validationError.localizedDescription
          })];
      if (completion) completion(nil, validationError);
    }];
    return;
  }
  [self onMain:^{
    [self enqueueExtensionSyncManagedPaths:validatedManagedPaths
                              enabledPaths:validatedEnabledPaths
                              removedPaths:validatedRemovedPaths
                          forceReloadPaths:validatedForcedReloadPaths
                                   startup:NO
                                completion:completion];
  }];
}

- (void)readExtensionConfigurationForExtensionID:(NSString *)extensionID
                                        completion:
                                            (nullable RexChromiumExtensionConfigurationCompletion)
                                                completion {
  NSString *identifier = [extensionID copy];
  RexChromiumExtensionConfigurationCompletion callback = [completion copy];
  [self onMain:^{
    if (!RexIsValidChromiumExtensionID(identifier)) {
      if (callback) {
        callback(nil, RexExtensionRuntimeError(
            52, @"Chromium 扩展标识无效"));
      }
      return;
    }
    [self performExtensionConfigurationOperationForExtensionID:identifier
                                                         update:nil
                                             sitePermissionHost:nil
                                          sitePermissionGranted:nil
                                                     completion:
        ^(NSDictionary<NSString *, id> *configuration, NSError *error) {
      if (callback) callback(configuration, error);
    }];
  }];
}

- (void)updateExtensionConfigurationForExtensionID:(NSString *)extensionID
                                         hostAccess:(nullable NSString *)hostAccess
                                  userScriptsAccess:(nullable NSNumber *)userScriptsAccess
                                          fileAccess:(nullable NSNumber *)fileAccess
                                     incognitoAccess:(nullable NSNumber *)incognitoAccess
                                  sitePermissionHost:(nullable NSString *)sitePermissionHost
                               sitePermissionGranted:(nullable NSNumber *)sitePermissionGranted
                                          completion:
                                              (nullable RexChromiumExtensionConfigurationCompletion)
                                                  completion {
  NSString *identifier = [extensionID copy];
  NSString *hostAccessValue = [hostAccess copy];
  NSNumber *userScriptsValue = [userScriptsAccess copy];
  NSNumber *fileAccessValue = [fileAccess copy];
  NSNumber *incognitoAccessValue = [incognitoAccess copy];
  NSString *sitePermissionHostValue = [sitePermissionHost copy];
  NSNumber *sitePermissionGrantedValue = [sitePermissionGranted copy];
  RexChromiumExtensionConfigurationCompletion callback = [completion copy];
  [self onMain:^{
    NSMutableArray<NSString *> *invalidFields = [NSMutableArray array];
    if (!RexIsValidChromiumExtensionID(identifier)) {
      [invalidFields addObject:@"extensionID"];
    }
    if (hostAccessValue &&
        !RexIsValidExtensionHostAccess(hostAccessValue)) {
      [invalidFields addObject:@"hostAccess"];
    }
    if (userScriptsValue && !RexIsJSONBoolean(userScriptsValue)) {
      [invalidFields addObject:@"userScriptsAccess"];
    }
    if (fileAccessValue && !RexIsJSONBoolean(fileAccessValue)) {
      [invalidFields addObject:@"fileAccess"];
    }
    if (incognitoAccessValue && !RexIsJSONBoolean(incognitoAccessValue)) {
      [invalidFields addObject:@"incognitoAccess"];
    }
    const BOOL hasSitePermissionHost = sitePermissionHostValue != nil;
    const BOOL hasSitePermissionGranted = sitePermissionGrantedValue != nil;
    if (hasSitePermissionHost != hasSitePermissionGranted ||
        (sitePermissionHostValue &&
         !RexIsBoundedExtensionConfigurationHost(sitePermissionHostValue)) ||
        (sitePermissionGrantedValue &&
         !RexIsJSONBoolean(sitePermissionGrantedValue))) {
      [invalidFields addObject:@"sitePermission"];
    }
    if (!hostAccessValue && !userScriptsValue && !fileAccessValue &&
        !incognitoAccessValue && !sitePermissionHostValue) {
      [invalidFields addObject:@"update"];
    }
    if (invalidFields.count) {
      if (callback) {
        callback(nil, RexExtensionRuntimeError(
            52,
            @"Chromium 扩展配置更新参数无效",
            @{@"invalidFields": [invalidFields copy]}));
      }
      return;
    }

    NSMutableDictionary<NSString *, id> *update = nil;
    if (hostAccessValue || userScriptsValue || fileAccessValue ||
        incognitoAccessValue) {
      update = [@{@"extensionId": identifier} mutableCopy];
      if (hostAccessValue) update[@"hostAccess"] = hostAccessValue;
      if (userScriptsValue) update[@"userScriptsAccess"] = userScriptsValue;
      if (fileAccessValue) update[@"fileAccess"] = fileAccessValue;
      if (incognitoAccessValue) {
        update[@"incognitoAccess"] = incognitoAccessValue;
      }
    }
    if (update && !RexJavaScriptJSONObjectLiteral(update).length) {
      if (callback) {
        callback(nil, RexExtensionRuntimeError(
            52, @"Chromium 扩展配置更新数据无效"));
      }
      return;
    }
    [self performExtensionConfigurationOperationForExtensionID:identifier
                                                         update:[update copy]
                                             sitePermissionHost:sitePermissionHostValue
                                          sitePermissionGranted:sitePermissionGrantedValue
                                                     completion:
        ^(NSDictionary<NSString *, id> *configuration, NSError *error) {
      if (callback) callback(configuration, error);
    }];
  }];
}

- (void)enqueueExtensionSyncManagedPaths:(NSArray<NSString *> *)managedPaths
                            enabledPaths:(NSArray<NSString *> *)enabledPaths
                            removedPaths:(NSArray<NSString *> *)removedPaths
                        forceReloadPaths:(NSArray<NSString *> *)forceReloadPaths
                                 startup:(BOOL)startup
                              completion:
                                  (nullable RexChromiumExtensionRuntimeCompletion)
                                      completion {
  NSAssert(NSThread.isMainThread,
           @"Chromium extension transactions are main-thread serialized");
  RexExtensionSyncRequest *request = [[RexExtensionSyncRequest alloc] init];
  request.managedPaths = [managedPaths copy];
  request.desiredPaths = [enabledPaths copy];
  request.removedPaths = [removedPaths copy];
  request.previousManagedPaths = @[];
  request.previousPaths = @[];
  request.fingerprintUpdatedPaths = @[];
  request.updatedPaths = @[];
  request.forcedReloadPaths = [forceReloadPaths copy];
  request.expectedManifestMetadataByPath = @{};
  request.expectedFingerprintsByPath = @{};
  request.expectedExtensionIDsByPath = [[NSMutableDictionary alloc] init];
  request.previousExtensionIDsByPath = @{};
  request.generation = ++_extensionRuntimeGeneration;
  request.startup = startup;
  request.completion = [completion copy];
  [_extensionSyncQueue addObject:request];
  [self startNextExtensionSyncIfNeeded];
}

- (void)startNextExtensionSyncIfNeeded {
  NSAssert(NSThread.isMainThread,
           @"Chromium extension transactions are main-thread serialized");
  if (_extensionSyncActive || _extensionConfigurationCompletion ||
      _extensionConfigurationMutation ||
      !_chromiumContextReady ||
      !_extensionSyncQueue.count) {
    return;
  }

  RexExtensionSyncRequest *request = _extensionSyncQueue.firstObject;
  if (!_shuttingDown && request.managedPaths.count > 0 &&
      !_extensionChromeWindowHostReady) {
    // loadUnpacked may synchronously dispatch runtime.onInstalled. Wait until a
    // real Chrome-style host exists so chrome.tabs APIs have a window context.
    if (_application && _application->EnsureExtensionWindowHost()) {
      __weak RexChromiumRuntime *weakSelf = self;
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
          dispatch_get_main_queue(), ^{
        RexChromiumRuntime *runtime = weakSelf;
        if (!runtime || runtime->_shuttingDown ||
            runtime->_extensionSyncActive ||
            runtime->_extensionChromeWindowHostReady ||
            runtime->_extensionSyncQueue.firstObject != request) {
          return;
        }
        [runtime->_extensionSyncQueue removeObjectAtIndex:0];
        request.previousManagedPaths =
            [runtime->_managedExtensionPaths copy];
        request.previousPaths = [runtime->_enabledExtensionPaths copy];
        request.expectedManifestMetadataByPath =
            RexExtensionManifestMetadataByPath(request.managedPaths);
        runtime->_extensionSyncActive = YES;
        runtime->_activeExtensionSyncRequest = request;
        [runtime failExtensionSyncRequest:request
                                    error:RexExtensionRuntimeError(
                                        48,
                                        @"等待 Chromium 扩展窗口上下文超时")
                       attemptedMutation:NO];
      });
      return;
    }

    [_extensionSyncQueue removeObjectAtIndex:0];
    request.previousManagedPaths = [_managedExtensionPaths copy];
    request.previousPaths = [_enabledExtensionPaths copy];
    request.expectedManifestMetadataByPath =
        RexExtensionManifestMetadataByPath(request.managedPaths);
    _extensionSyncActive = YES;
    _activeExtensionSyncRequest = request;
    [self failExtensionSyncRequest:request
                            error:RexExtensionRuntimeError(
                                46,
                                @"无法创建 Chromium 扩展窗口上下文")
               attemptedMutation:NO];
    return;
  }

  [_extensionSyncQueue removeObjectAtIndex:0];
  request.previousManagedPaths = [_managedExtensionPaths copy];
  request.previousPaths = [_enabledExtensionPaths copy];
  request.expectedFingerprintsByPath =
      RexExtensionPathFingerprintsByPath(request.managedPaths);
  request.fingerprintUpdatedPaths = RexUpdatedExtensionPaths(
      request.managedPaths,
      _extensionPathFingerprints,
      request.expectedFingerprintsByPath,
      !request.startup);
  NSMutableOrderedSet<NSString *> *updatedPaths =
      [NSMutableOrderedSet
          orderedSetWithArray:request.fingerprintUpdatedPaths];
  [updatedPaths addObjectsFromArray:request.forcedReloadPaths];
  request.updatedPaths =
      [[updatedPaths array] sortedArrayUsingSelector:@selector(compare:)];
  request.expectedManifestMetadataByPath =
      RexExtensionManifestMetadataByPath(request.managedPaths);
  _extensionSyncActive = YES;
  _activeExtensionSyncRequest = request;
  request.chromeWindowHostEpoch = _extensionChromeWindowHostEpoch;

  if (_shuttingDown || !_extensionPipe.isPrepared) {
    [self failExtensionSyncRequest:request
                            error:RexExtensionRuntimeError(
                                41,
                                @"Chromium 扩展热运行时不可用")
               attemptedMutation:NO];
    return;
  }

  [self queryLiveExtensions:^(
      NSArray<NSDictionary<NSString *, id> *> *extensions,
      NSError *queryError) {
    if (queryError) {
      [self failExtensionSyncRequest:request
                              error:queryError
                 attemptedMutation:NO];
      return;
    }

    NSSet<NSString *> *managed =
        [NSSet setWithArray:request.managedPaths];
    NSSet<NSString *> *previous =
        [NSSet setWithArray:request.previousManagedPaths];
    NSMutableDictionary<NSString *, NSString *> *previousIDs =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *extension in extensions) {
      NSString *path = extension[@"path"];
      NSString *identifier = extension[@"id"];
      if ([managed containsObject:path] && identifier.length) {
        request.expectedExtensionIDsByPath[path] = identifier;
      }
      if ([previous containsObject:path] && identifier.length) {
        previousIDs[path] = identifier;
      }
    }
    request.previousExtensionIDsByPath = [previousIDs copy];

    NSMutableArray<NSDictionary<NSString *, id> *> *operations =
        [RexExtensionReconcileOperations(
            extensions,
            request.managedPaths,
            request.desiredPaths,
            [NSSet setWithArray:request.removedPaths],
            [NSSet setWithArray:request.updatedPaths],
            request.expectedManifestMetadataByPath) mutableCopy];
    if (request.startup && self->_internalDownloadUIExtensionPath.length) {
      NSString *internalExtensionID =
          request.expectedManifestMetadataByPath[
              self->_internalDownloadUIExtensionPath][@"id"];
      if (!internalExtensionID.length) {
        [self failExtensionSyncRequest:request
                                error:RexExtensionRuntimeError(
                                    34,
                                    @"Rex 内部 Chromium 下载 UI 控制扩展身份无效")
                   attemptedMutation:operations.count > 0];
        return;
      }
      [operations addObject:@{
        @"type": @"configureIncognito",
        @"id": internalExtensionID,
        @"path": self->_internalDownloadUIExtensionPath
      }];
    }
    request.attemptedMutation = operations.count > 0;
    [self performExtensionOperations:operations
                               index:0
            loadedExtensionIDsByPath:
                request.expectedExtensionIDsByPath
                          completion:^(NSError *operationError) {
      [self queryLiveExtensions:^(
          NSArray<NSDictionary<NSString *, id> *> *finalExtensions,
          NSError *finalQueryError) {
        NSError *verificationError = finalQueryError;
        if (!verificationError) {
          verificationError = RexVerifyManagedExtensionSet(
              request.managedPaths,
              request.desiredPaths,
              [NSSet setWithArray:request.removedPaths],
              finalExtensions,
              request.expectedManifestMetadataByPath,
              request.expectedExtensionIDsByPath,
              request.generation);
        }
        if (!verificationError && request.managedPaths.count > 0 &&
            (!self->_extensionChromeWindowHostReady ||
             request.chromeWindowHostEpoch !=
                 self->_extensionChromeWindowHostEpoch)) {
          verificationError = RexExtensionRuntimeError(
              47,
              @"Chromium 扩展窗口上下文在事务期间失效",
              @{@"generation": @(request.generation)});
        }
        NSDictionary<NSString *, NSString *> *currentFingerprints =
            RexExtensionPathFingerprintsByPath(request.managedPaths);
        const BOOL packageSnapshotStable =
            [currentFingerprints
                isEqualToDictionary:request.expectedFingerprintsByPath];
        if (!verificationError && !packageSnapshotStable) {
          verificationError = RexExtensionRuntimeError(
              58,
              @"扩展包在 Chromium 事务期间再次发生变化",
              @{@"generation": @(request.generation)});
        }
        if (rex::extensions::CanCommitReconcile(
                operationError == nil,
                verificationError == nil,
                packageSnapshotStable)) {
          [self finishExtensionSyncRequest:request
                                extensions:finalExtensions];
          return;
        }
        [self failExtensionSyncRequest:request
                                error:operationError ?: verificationError
                   attemptedMutation:request.attemptedMutation];
      }];
    }];
  }];
}

- (void)queryLiveExtensions:(RexExtensionQueryCompletion)completion {
  [_extensionPipe executeMethod:@"Extensions.getExtensions"
                         params:@{}
                     completion:^(
      NSDictionary<NSString *, id> *result,
      NSError *error) {
    if (error) {
      completion(nil, error);
      return;
    }
    id rawExtensions = result[@"extensions"];
    if (![rawExtensions isKindOfClass:NSArray.class]) {
      completion(nil, RexExtensionRuntimeError(
          42, @"Chromium 返回了无效的扩展列表"));
      return;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *extensions =
        [NSMutableArray array];
    for (id value in static_cast<NSArray *>(rawExtensions)) {
      if (![value isKindOfClass:NSDictionary.class]) continue;
      NSDictionary<NSString *, id> *raw =
          static_cast<NSDictionary<NSString *, id> *>(value);
      NSString *identifier = [raw[@"id"] isKindOfClass:NSString.class]
          ? raw[@"id"]
          : nil;
      NSString *path = [raw[@"path"] isKindOfClass:NSString.class]
          ? raw[@"path"]
          : nil;
      NSNumber *enabled = [raw[@"enabled"] isKindOfClass:NSNumber.class]
          ? raw[@"enabled"]
          : nil;
      if (!identifier.length || !path.length || !enabled) continue;
      NSString *resolvedPath =
          path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
      [extensions addObject:@{
        @"id": identifier,
        @"path": resolvedPath,
        @"enabled": enabled,
        @"name": [raw[@"name"] isKindOfClass:NSString.class]
            ? raw[@"name"]
            : @"",
        @"version": [raw[@"version"] isKindOfClass:NSString.class]
            ? raw[@"version"]
            : @""
      }];
    }
    completion([extensions copy], nil);
  }];
}

- (void)performExtensionOperations:
            (NSArray<NSDictionary<NSString *, id> *> *)operations
                                index:(NSUInteger)index
           loadedExtensionIDsByPath:
               (NSMutableDictionary<NSString *, NSString *> *)loadedIDsByPath
                           completion:
                               (RexExtensionOperationsCompletion)completion {
  if (index >= operations.count) {
    completion(nil);
    return;
  }
  NSDictionary<NSString *, id> *operation = operations[index];
  NSString *type = operation[@"type"];
  if ([type isEqualToString:@"uninstall"]) {
    [_extensionPipe executeMethod:@"Extensions.uninstall"
                           params:@{@"id": operation[@"id"] ?: @""}
                       completion:^(
        NSDictionary<NSString *, id> *result,
        NSError *error) {
      if (error) {
        completion(error);
        return;
      }
      [self performExtensionOperations:operations
                                 index:index + 1
              loadedExtensionIDsByPath:loadedIDsByPath
                            completion:completion];
    }];
    return;
  }

  if (![type isEqualToString:@"load"] &&
      ![type isEqualToString:@"reload"] &&
      ![type isEqualToString:@"enable"] &&
      ![type isEqualToString:@"disable"] &&
      ![type isEqualToString:@"configureIncognito"]) {
    completion(RexExtensionRuntimeError(
        43, @"扩展事务包含未知操作"));
    return;
  }

  NSMutableDictionary<NSString *, id> *resolvedOperation =
      [operation mutableCopy];
  NSString *path = resolvedOperation[@"path"];
  if (![type isEqualToString:@"load"] &&
      ![resolvedOperation[@"id"] isKindOfClass:NSString.class] &&
      path.length) {
    NSString *loadedIdentifier = loadedIDsByPath[path];
    if (loadedIdentifier.length) resolvedOperation[@"id"] = loadedIdentifier;
  }

  [self performNativeExtensionOperation:[resolvedOperation copy]
                              completion:^(NSError *error) {
    if (error) {
      completion(error);
      return;
    }
    if (![type isEqualToString:@"load"]) {
      [self performExtensionOperations:operations
                                 index:index + 1
              loadedExtensionIDsByPath:loadedIDsByPath
                            completion:completion];
      return;
    }

    [self queryLiveExtensions:^(
        NSArray<NSDictionary<NSString *, id> *> *extensions,
        NSError *queryError) {
      if (queryError) {
        completion(queryError);
        return;
      }
      NSString *identifier = nil;
      for (NSDictionary<NSString *, id> *extension in extensions) {
        if ([extension[@"path"] isEqualToString:path]) {
          identifier = extension[@"id"];
          break;
        }
      }
      if (!identifier.length || !path.length) {
        completion(RexExtensionRuntimeError(
            44, @"Chromium 原生安装完成后未返回扩展标识"));
        return;
      }
      loadedIDsByPath[path] = identifier;
      [self performExtensionOperations:operations
                                 index:index + 1
              loadedExtensionIDsByPath:loadedIDsByPath
                            completion:completion];
    }];
  }];
}

- (void)performExtensionConfigurationOperationForExtensionID:
            (NSString *)extensionID
                                                       update:
                                                           (nullable NSDictionary<NSString *, id> *)update
                                           sitePermissionHost:
                                               (nullable NSString *)sitePermissionHost
                                        sitePermissionGranted:
                                            (nullable NSNumber *)sitePermissionGranted
                                                   completion:
                                                       (RexChromiumExtensionConfigurationCompletion)
                                                           completion {
  NSAssert(NSThread.isMainThread,
           @"Extension configuration operations are main-thread serialized");
  if (_shuttingDown || !_ready || !_chromiumContextReady || !_application ||
      !_extensionChromeWindowHostReady) {
    completion(nil, RexExtensionRuntimeError(
        53, @"Chromium 原生扩展配置管理器不可用"));
    return;
  }
  if (_extensionSyncActive || _extensionSyncQueue.count ||
      _nativeExtensionOperationCompletion ||
      _extensionConfigurationCompletion || _extensionConfigurationMutation) {
    completion(nil, RexExtensionRuntimeError(
        53, @"Chromium 原生扩展管理器正忙"));
    return;
  }

  const uint64_t token = ++_nativeExtensionOperationToken;
  NSString *script = RexExtensionConfigurationOperationScript(
      extensionID, update, sitePermissionHost, sitePermissionGranted, token);
  if (!script.length) {
    completion(nil, RexExtensionRuntimeError(
        52, @"无法生成 Chromium 扩展配置操作"));
    return;
  }

  const BOOL isMutation =
      rex::extensions::IsExtensionConfigurationMutation(
          update != nil, sitePermissionHost != nil);
  _extensionConfigurationCompletion = [completion copy];
  _extensionConfigurationExpectedID = [extensionID copy];
  _extensionConfigurationMutation = isMutation;
  if (!_application->BeginManagedExtensionConfigurationOperation(
          token, RexUTF8(script))) {
    RexChromiumExtensionConfigurationCompletion pending =
        _extensionConfigurationCompletion;
    _extensionConfigurationCompletion = nil;
    _extensionConfigurationExpectedID = nil;
    _extensionConfigurationMutation = NO;
    pending(nil, RexExtensionRuntimeError(
        53, @"无法启动 Chromium 原生扩展配置操作"));
    return;
  }

  __weak RexChromiumRuntime *weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
    RexChromiumRuntime *runtime = weakSelf;
    if (!runtime || token != runtime->_nativeExtensionOperationToken ||
        !runtime->_extensionConfigurationCompletion) {
      return;
    }

    RexChromiumExtensionConfigurationCompletion pending =
        runtime->_extensionConfigurationCompletion;
    runtime->_extensionConfigurationCompletion = nil;
    runtime->_extensionConfigurationExpectedID = nil;
    runtime->_extensionConfigurationMutation = isMutation;
    if (!isMutation) {
      // A timed-out read has no side effects and can be cancelled safely. A
      // late console result is tied to the old token and will be ignored.
      if (runtime->_application) {
        runtime->_application->CancelManagedExtensionOperation(token);
      }
      ++runtime->_nativeExtensionOperationToken;
    }
    pending(nil, RexExtensionRuntimeError(
        55,
        isMutation
            ? @"Chromium 扩展配置更新超时，状态未知，请重新启动 Rex"
            : @"读取 Chromium 扩展配置超时",
        @{
          @"operation": isMutation ? @"updateConfiguration"
                                    : @"readConfiguration",
          @"requiresRestart": @(isMutation),
          @"runtimeState": isMutation ? @"unknown" : @"unchanged"
        }));
    if (!isMutation && !runtime->_shuttingDown) {
      [runtime startNextExtensionSyncIfNeeded];
    }
  });
}

- (void)performNativeExtensionOperation:
            (NSDictionary<NSString *, id> *)operation
                              completion:
                                  (RexExtensionOperationsCompletion)completion {
  NSAssert(NSThread.isMainThread,
           @"Native extension operations are main-thread serialized");
  if (_nativeExtensionOperationCompletion ||
      _extensionConfigurationCompletion || _extensionConfigurationMutation ||
      !_application ||
      !_extensionChromeWindowHostReady) {
    completion(RexExtensionRuntimeError(
        49, @"Chromium 原生扩展管理器正忙或不可用"));
    return;
  }

  NSString *type = operation[@"type"];
  NSString *identifier = operation[@"id"];
  NSString *path = operation[@"path"];
  NSString *invocation = nil;
  if ([type isEqualToString:@"load"] && path.length) {
    invocation =
        @"if (!globalThis.chrome || !chrome.developerPrivate || "
         "typeof chrome.developerPrivate.loadUnpacked !== 'function' || "
         "typeof chrome.developerPrivate.updateProfileConfiguration !== "
         "'function') { "
         "finish({error: 'chrome.developerPrivate load API unavailable'}); "
         "return; } "
         "chrome.developerPrivate.updateProfileConfiguration("
         "{inDeveloperMode: true}, () => { "
         "if (chrome.runtime && chrome.runtime.lastError) { finish(); return; } "
         "chrome.developerPrivate.loadUnpacked("
         "{failQuietly: true, populateError: true}, finish); "
         "});";
  } else if ([type isEqualToString:@"reload"] && identifier.length) {
    invocation = [NSString stringWithFormat:
        @"if (!globalThis.chrome || !chrome.developerPrivate || "
         "typeof chrome.developerPrivate.reload !== 'function') { "
         "finish({error: 'chrome.developerPrivate.reload unavailable'}); "
         "return; } "
         "chrome.developerPrivate.reload(%@, "
         "{failQuietly: true, populateErrorForUnpacked: true}, finish);",
        RexJavaScriptStringLiteral(identifier)];
  } else if ([type isEqualToString:@"enable"] && identifier.length) {
    invocation = [NSString stringWithFormat:
        @"if (!globalThis.chrome || !chrome.management || "
         "typeof chrome.management.setEnabled !== 'function') { "
         "finish({error: 'chrome.management.setEnabled unavailable'}); "
         "return; } "
         "chrome.management.setEnabled(%@, true, () => finish());",
        RexJavaScriptStringLiteral(identifier)];
  } else if ([type isEqualToString:@"disable"] && identifier.length) {
    invocation = [NSString stringWithFormat:
        @"if (!globalThis.chrome || !chrome.management || "
         "typeof chrome.management.setEnabled !== 'function') { "
         "finish({error: 'chrome.management.setEnabled unavailable'}); "
         "return; } "
         "chrome.management.setEnabled(%@, false, () => finish());",
        RexJavaScriptStringLiteral(identifier)];
  } else if ([type isEqualToString:@"configureIncognito"] &&
             identifier.length) {
    invocation = [NSString stringWithFormat:
        @"if (!globalThis.chrome || !chrome.developerPrivate || "
         "typeof chrome.developerPrivate.updateExtensionConfiguration !== "
         "'function' || typeof chrome.developerPrivate.getExtensionInfo !== "
         "'function') { "
         "finish({error: 'Chromium extension configuration API unavailable'}); "
         "return; } "
         "(async () => { "
         "await chrome.developerPrivate.updateExtensionConfiguration({"
         "extensionId: %@, incognitoAccess: true}); "
         "const info = await chrome.developerPrivate.getExtensionInfo(%@); "
         "if (!info || info.id !== %@ || !info.incognitoAccess || "
         "!info.incognitoAccess.isActive) { "
         "throw new Error('Chromium internal download extension is not enabled "
         "in private windows'); } "
         "finish(); "
         "})().catch(finish);",
        RexJavaScriptStringLiteral(identifier),
        RexJavaScriptStringLiteral(identifier),
        RexJavaScriptStringLiteral(identifier)];
  }
  if (!invocation.length) {
    completion(RexExtensionRuntimeError(
        43, @"原生扩展事务包含无效操作参数"));
    return;
  }

  const uint64_t token = ++_nativeExtensionOperationToken;
  NSString *script = [NSString stringWithFormat:
      @"(() => { "
       "let completed = false; "
       "const finish = (error) => { "
       "if (completed) return; completed = true; "
       "const runtimeError = globalThis.chrome && chrome.runtime && "
       "chrome.runtime.lastError; "
       "let message = ''; "
       "if (runtimeError && runtimeError.message) message = runtimeError.message; "
       "else if (error && typeof error.error === 'string') message = error.error; "
       "else if (error && error.message) message = String(error.message); "
       "else if (error) message = String(error); "
       "console.info('__REX_MANAGED_EXTENSION_RESULT__:%llu:' + "
       "encodeURIComponent(message)); "
       "}; "
       "try { %@ } catch (error) { finish(error); } "
       "})();",
      static_cast<unsigned long long>(token), invocation];

  _nativeExtensionOperationCompletion = [completion copy];
  if (!_application->BeginManagedExtensionOperation(
          token, RexUTF8(script),
          [type isEqualToString:@"load"] ? RexUTF8(path) : std::string())) {
    RexExtensionOperationsCompletion pending =
        _nativeExtensionOperationCompletion;
    _nativeExtensionOperationCompletion = nil;
    pending(RexExtensionRuntimeError(
        49, @"无法启动 Chromium 原生扩展操作"));
    return;
  }

  __weak RexChromiumRuntime *weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
    RexChromiumRuntime *runtime = weakSelf;
    if (!runtime || token != runtime->_nativeExtensionOperationToken ||
        !runtime->_nativeExtensionOperationCompletion) {
      return;
    }
    // developerPrivate.loadUnpacked/reload cannot be cancelled once Chromium
    // has accepted the call. Keep the hidden host token occupied so a late
    // completion cannot overlap another native mutation, and poison the CDP
    // reconciliation channel rather than attempting rollback from unknown
    // profile state. CEF shutdown remains responsible for closing the host.
    [runtime->_extensionPipe shutdown];
    RexExtensionOperationsCompletion pending =
        runtime->_nativeExtensionOperationCompletion;
    runtime->_nativeExtensionOperationCompletion = nil;
    pending(RexExtensionRuntimeError(
        50,
        @"Chromium 原生扩展操作超时，运行时状态未知，请重新启动 Rex",
        @{
          @"operation": type ?: @"unknown",
          @"requiresRestart": @YES,
          @"runtimeState": @"unknown"
        }));
  });
}

- (void)managedExtensionOperationDidFinishWithToken:(uint64_t)token
                                        errorMessage:(nullable NSString *)message {
  NSAssert(NSThread.isMainThread,
           @"Native extension results are delivered on the CEF UI thread");
  if (token != _nativeExtensionOperationToken ||
      !_nativeExtensionOperationCompletion) {
    return;
  }
  RexExtensionOperationsCompletion completion =
      _nativeExtensionOperationCompletion;
  _nativeExtensionOperationCompletion = nil;
  if (message.length) {
    completion(RexExtensionRuntimeError(
        51, @"Chromium 原生扩展操作失败", @{@"nativeError": message}));
  } else {
    completion(nil);
  }
}

- (void)managedExtensionConfigurationOperationDidFinishWithToken:
            (uint64_t)token
                                                      payload:
                                                          (nullable NSString *)payload
                                                 errorMessage:
                                                     (nullable NSString *)message {
  NSAssert(NSThread.isMainThread,
           @"Extension configuration results use the CEF UI thread");
  if (token != _nativeExtensionOperationToken) return;

  RexChromiumExtensionConfigurationCompletion completion =
      _extensionConfigurationCompletion;
  NSString *expectedID = [_extensionConfigurationExpectedID copy];
  const BOOL wasMutation = _extensionConfigurationMutation;
  _extensionConfigurationCompletion = nil;
  _extensionConfigurationExpectedID = nil;
  _extensionConfigurationMutation = NO;
  if (!completion) {
    // An update may complete after its timeout. The hidden host has now
    // released the token, so a queued managed-extension sync may continue.
    if (!_shuttingDown) [self startNextExtensionSyncIfNeeded];
    return;
  }

  NSDictionary<NSString *, id> *configuration = nil;
  NSError *resultError = nil;
  if (message.length) {
    resultError = RexExtensionRuntimeError(
        56,
        @"Chromium 扩展配置结果传输失败",
        @{@"nativeError": message});
  } else {
    configuration = RexExtensionConfigurationFromPayload(
        payload ?: @"", expectedID ?: @"", &resultError);
  }
  if (wasMutation && configuration && !resultError) {
    [self reloadWebPagesAfterExtensionChange];
  }
  completion(configuration, resultError);
  if (!_shuttingDown) [self startNextExtensionSyncIfNeeded];
}

- (void)finishExtensionSyncRequest:(RexExtensionSyncRequest *)request
                         extensions:
                             (NSArray<NSDictionary<NSString *, id> *> *)extensions {
  _managedExtensionPaths = [request.managedPaths copy];
  _enabledExtensionPaths = [request.desiredPaths copy];
  [_extensionPathFingerprints removeAllObjects];
  [_extensionPathFingerprints
      addEntriesFromDictionary:request.expectedFingerprintsByPath];

  NSDictionary<NSString *, id> *result = @{
    @"generation": @(request.generation),
    @"loadedPaths": RexLiveExtensionPaths(extensions),
    @"loadedExtensionIDs": RexLiveExtensionIDs(extensions)
  };
  NSLog(@"[Rex] extension runtime generation %lu committed "
         "(%lu managed, %lu enabled)",
        (unsigned long)request.generation,
        (unsigned long)request.managedPaths.count,
        (unsigned long)request.desiredPaths.count);
  if (request.attemptedMutation) {
    _extensionPageReloadPending = YES;
  }
  [self emitEvent:RexEvent(@"extensionRuntimeChanged", @"", result)];

  if (request.completion) request.completion(result, nil);
  _activeExtensionSyncRequest = nil;
  _extensionSyncActive = NO;
  if (RexShouldReleaseExtensionStartupBarrier(
          _extensionStartupBarrierActive,
          _extensionSyncQueue.count)) {
    [self releaseExtensionStartupNavigationBarrier];
    _extensionPageReloadPending = NO;
  } else if (!_extensionStartupBarrierActive &&
             !_extensionSyncQueue.count &&
             _extensionPageReloadPending) {
    _extensionPageReloadPending = NO;
    [self reloadWebPagesAfterExtensionChange];
  }
  [self startNextExtensionSyncIfNeeded];
}

- (void)failExtensionSyncRequest:(RexExtensionSyncRequest *)request
                           error:(NSError *)error
              attemptedMutation:(BOOL)attemptedMutation {
  if (attemptedMutation) {
    // A compensating generation may be a no-op after this rollback. Preserve
    // the refresh obligation, but never reload against an unverified failure.
    _extensionPageReloadPending = YES;
  }
  void (^completeFailure)(
      NSArray<NSDictionary<NSString *, id> *> *_Nullable,
      NSError *_Nullable) =
      ^(NSArray<NSDictionary<NSString *, id> *> *extensions,
        NSError *rollbackError) {
    NSArray<NSString *> *loadedPaths =
        extensions ? RexLiveExtensionPaths(extensions) : @[];
    NSMutableDictionary<NSString *, id> *details =
        [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    details[@"generation"] = @(request.generation);
    details[@"loadedPaths"] = loadedPaths;
    details[@"loadedPathsKnown"] = @(extensions != nil);
    if (rollbackError) {
      details[@"rollbackError"] = rollbackError.localizedDescription;
    }
    NSError *reportedError = RexExtensionRuntimeError(
        error.code ?: 45,
        error.localizedDescription ?: @"Chromium 扩展事务失败",
        details);
    NSLog(@"[Rex] extension runtime generation %lu failed: %@",
          (unsigned long)request.generation,
          reportedError.localizedDescription);
    [self emitEvent:RexEvent(
        @"extensionRuntimeError",
        @"",
        @{
          @"generation": @(request.generation),
          @"loadedPaths": loadedPaths,
          @"loadedPathsKnown": @(extensions != nil),
          @"message": reportedError.localizedDescription
        })];
    // Never reload on a failed generation. The live set may be missing or
    // unverified; a successful compensating generation performs the one reload.
    if (request.completion) request.completion(nil, reportedError);
    self->_activeExtensionSyncRequest = nil;
    self->_extensionSyncActive = NO;
    // Extension reconciliation failures are already surfaced to Swift. Do not
    // leave every restored and newly submitted web navigation parked on
    // about:blank forever when no compensating transaction remains.
    if (RexShouldReleaseExtensionStartupBarrier(
            self->_extensionStartupBarrierActive,
            self->_extensionSyncQueue.count)) {
      NSLog(@"[Rex] releasing extension startup navigation barrier after "
             "failed generation %lu",
            (unsigned long)request.generation);
      [self releaseExtensionStartupNavigationBarrier];
      self->_extensionPageReloadPending = NO;
    }
    [self startNextExtensionSyncIfNeeded];
  };

  if (!_extensionPipe.isPrepared) {
    completeFailure(nil, error);
    return;
  }

  if (request.startup || !attemptedMutation) {
    [self queryLiveExtensions:^(
        NSArray<NSDictionary<NSString *, id> *> *extensions,
        NSError *queryError) {
      completeFailure(extensions, queryError);
    }];
    return;
  }

  NSMutableArray<NSString *> *rollbackManagedPaths =
      [request.previousManagedPaths mutableCopy];
  NSMutableArray<NSString *> *rollbackEnabledPaths =
      [request.previousPaths mutableCopy];
  // The old files for a package replacement live in Swift's transaction backup.
  // Remove those unverified live instances; Swift restores their directories
  // and submits a compensating sync before deleting the backups. An explicitly
  // forced reload has no file swap, so its current path remains eligible for
  // this best-effort runtime rollback.
  NSMutableArray<NSString *> *replacementPaths =
      [request.fingerprintUpdatedPaths mutableCopy];
  [rollbackManagedPaths removeObjectsInArray:replacementPaths];
  [rollbackEnabledPaths removeObjectsInArray:replacementPaths];
  NSMutableOrderedSet<NSString *> *rollbackRemovedPaths =
      [NSMutableOrderedSet orderedSetWithArray:request.managedPaths];
  [rollbackRemovedPaths removeObjectsInArray:request.previousManagedPaths];
  [rollbackRemovedPaths addObjectsFromArray:replacementPaths];
  [rollbackRemovedPaths removeObjectsInArray:rollbackManagedPaths];
  NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *>
      *rollbackMetadata =
      RexExtensionManifestMetadataByPath(rollbackManagedPaths);
  NSMutableDictionary<NSString *, NSString *> *rollbackIDs =
      [NSMutableDictionary dictionary];
  for (NSString *path in rollbackManagedPaths) {
    NSString *identifier = request.previousExtensionIDsByPath[path];
    if (identifier.length) rollbackIDs[path] = identifier;
  }

  [self queryLiveExtensions:^(
      NSArray<NSDictionary<NSString *, id> *> *extensions,
      NSError *queryError) {
    if (queryError) {
      completeFailure(nil, queryError);
      return;
    }
    NSArray<NSDictionary<NSString *, id> *> *rollbackOperations =
        RexExtensionReconcileOperations(
            extensions,
            rollbackManagedPaths,
            rollbackEnabledPaths,
            [NSSet setWithArray:rollbackRemovedPaths.array],
            [NSSet set],
            rollbackMetadata);
    [self performExtensionOperations:rollbackOperations
                               index:0
            loadedExtensionIDsByPath:rollbackIDs
                          completion:^(NSError *operationError) {
      [self queryLiveExtensions:^(
          NSArray<NSDictionary<NSString *, id> *> *rolledBackExtensions,
          NSError *finalQueryError) {
        NSError *verificationError = finalQueryError;
        if (!verificationError) {
          verificationError = RexVerifyManagedExtensionSet(
              rollbackManagedPaths,
              rollbackEnabledPaths,
              [NSSet setWithArray:rollbackRemovedPaths.array],
              rolledBackExtensions,
              rollbackMetadata,
              rollbackIDs,
              request.generation);
        }
        NSError *rollbackError = operationError ?: verificationError;
        completeFailure(rolledBackExtensions, rollbackError);
      }];
    }];
  }];
}

- (void)releaseExtensionStartupNavigationBarrier {
  if (!_extensionStartupBarrierActive) return;
  _extensionStartupBarrierActive = NO;
  NSDictionary<NSString *, NSString *> *pending = [_pendingURLs copy];
  for (NSString *tabID in pending) {
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    CefRefPtr<CefFrame> frame = browser ? browser->GetMainFrame() : nullptr;
    if (!frame) continue;
    NSString *url = pending[tabID];
    if (RexShouldUseEmbeddedChromeRuntime(
            url, [_privateTabs[tabID] boolValue]) &&
        browser->GetHost()->GetRuntimeStyle() != CEF_RUNTIME_STYLE_CHROME) {
      _browserReplacementTabs.insert(RexUTF8(tabID));
      browser->GetHost()->CloseBrowser(true);
      continue;
    }
    const std::string requestedURL = RexUTF8(url);
    if (frame->GetURL().ToString() != requestedURL) {
      frame->LoadURL(requestedURL);
    }
    [_pendingURLs removeObjectForKey:tabID];
  }
}

- (void)reloadWebPagesAfterExtensionChange {
  for (const auto &entry : _browsers) {
    const std::string &key = entry.first;
    NSString *tabID =
        [[NSString alloc] initWithUTF8String:key.c_str()] ?: @"";
    if ([_privateTabs[tabID] boolValue]) {
      _needsExtensionReloadTabs.erase(key);
      continue;
    }
    CefRefPtr<CefBrowser> browser = entry.second;
    CefRefPtr<CefFrame> frame =
        browser && browser->IsValid() ? browser->GetMainFrame() : nullptr;
    if (!frame) continue;
    NSString *scheme =
        [NSURLComponents componentsWithString:RexNSString(frame->GetURL())]
            .scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] ||
        [scheme isEqualToString:@"https"]) {
      if (_suspendedTabs.contains(key)) {
        _needsExtensionReloadTabs.insert(key);
      } else {
        _needsExtensionReloadTabs.erase(key);
        browser->Reload();
      }
    }
  }
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
      NSWindow *toolsWindow = self->_developerToolsPopupWindowsByBrowserID[
          @(existingTools->GetIdentifier())];
      [self syncNativeBrowserView:nativeView
                       toHostView:view
                          browser:existingTools
                      popupWindow:toolsWindow];
      if (inspectX >= 0 && inspectY >= 0) {
        CefWindowInfo windowInfo;
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
        const int x = static_cast<int>(inspectX);
        const int y = static_cast<int>(inspectY);
        const CefPoint point = x == 0 && y == 0 ? CefPoint(1, 0) : CefPoint(x, y);
        b->GetHost()->ShowDevTools(
            windowInfo, nullptr, CefBrowserSettings(), point);
      }
      [view.window makeMainWindow];
      [toolsWindow makeKeyAndOrderFront:nil];
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
    // Chrome-style DevTools must be created visible on macOS. Start with a
    // valid one-pixel window; registration turns it into Rex's borderless
    // child window and aligns it with the docked DevTools host.
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
    [view.window makeMainWindow];
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
- (BOOL)executeDeveloperToolsEditingCommand:
            (RexDeveloperToolsEditingCommand)command
                                      tabID:(NSString *)tabID {
  CEF_REQUIRE_UI_THREAD();
  if (!tabID.length || command == RexDeveloperToolsEditingCommandNone) {
    return NO;
  }
  CefRefPtr<CefBrowser> browser = [self developerToolsBrowserForTabID:tabID];
  if (!browser || !browser->IsValid()) return NO;
  CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
  if (!frame || !frame->IsValid()) frame = browser->GetMainFrame();
  if (!frame || !frame->IsValid()) return NO;

  switch (command) {
    case RexDeveloperToolsEditingCommandUndo:
      frame->Undo();
      break;
    case RexDeveloperToolsEditingCommandRedo:
      frame->Redo();
      break;
    case RexDeveloperToolsEditingCommandCut:
      frame->Cut();
      break;
    case RexDeveloperToolsEditingCommandCopy:
      frame->Copy();
      break;
    case RexDeveloperToolsEditingCommandPaste:
      frame->Paste();
      break;
    case RexDeveloperToolsEditingCommandPasteAndMatchStyle:
      frame->PasteAndMatchStyle();
      break;
    case RexDeveloperToolsEditingCommandDelete:
      frame->Delete();
      break;
    case RexDeveloperToolsEditingCommandSelectAll:
      frame->SelectAll();
      break;
    case RexDeveloperToolsEditingCommandNone:
      return NO;
  }
  return YES;
}

- (BOOL)handleDeveloperToolsEditingShortcutForEvent:(NSEvent *)event {
  if (!event.window || event.type != NSEventTypeKeyDown) return NO;
  const NSEventModifierFlags modifiers =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
      ~NSEventModifierFlagFunction;
  const RexDeveloperToolsEditingCommand command =
      RexDeveloperToolsEditingCommandForKeyCode(event.keyCode, modifiers);
  if (command == RexDeveloperToolsEditingCommandNone) return NO;

  NSResponder *responder = event.window.firstResponder;
  RexChromiumDevToolsView *hostView = nil;
  while (responder) {
    if ([responder isKindOfClass:RexChromiumDevToolsView.class]) {
      hostView = (RexChromiumDevToolsView *)responder;
      break;
    }
    if ([responder isKindOfClass:NSView.class] &&
        ((NSView *)responder).superview) {
      responder = ((NSView *)responder).superview;
    } else {
      responder = responder.nextResponder;
    }
  }
  if (!hostView) {
    NSNumber *browserID = nil;
    for (NSNumber *candidate in _developerToolsPopupWindowsByBrowserID) {
      if (_developerToolsPopupWindowsByBrowserID[candidate] == event.window) {
        browserID = candidate;
        break;
      }
    }
    if (browserID) {
      for (const auto &entry : _developerToolsBrowsers) {
        if (entry.second &&
            entry.second->GetIdentifier() == browserID.intValue) {
          NSString *tabID =
              [[NSString alloc] initWithUTF8String:entry.first.c_str()];
          hostView = _developerToolsViews[tabID];
          break;
        }
      }
    }
  }
  if (!hostView || !hostView.window || hostView.hidden || !hostView.superview) {
    return NO;
  }
  return [self executeDeveloperToolsEditingCommand:command
                                              tabID:hostView.tabID];
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
  [self onMain:^{
    if (focused) {
      self->_focusedTabID = [tabID copy];
      self->_lastFocusedTabID = [tabID copy];
    } else if ([self->_focusedTabID isEqualToString:tabID]) {
      self->_focusedTabID = nil;
    }
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    if (!browser) return;
    NSWindow *embeddedWindow = self->_embeddedChromeWindowsByBrowserID[
        @(browser->GetIdentifier())];
    RexChromiumBrowserView *hostView = self->_views[tabID];
    if (embeddedWindow && hostView) {
      [self syncEmbeddedChromeWindow:embeddedWindow
                           toHostView:hostView
                              browser:browser];
    }
    browser->GetHost()->SetFocus(focused);
  }];
}

- (void)setPageSuspended:(BOOL)suspended tabID:(NSString *)tabID {
  [self onMain:^{
    const std::string key = RexUTF8(tabID);
    if (suspended) {
      self->_suspendedTabs.insert(key);
    } else {
      self->_suspendedTabs.erase(key);
    }
    CefRefPtr<CefBrowser> browser = [self browserForTabID:tabID];
    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    if (!host) return;
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("state", suspended ? "frozen" : "active");
    if (host->ExecuteDevToolsMethod(
            0, "Page.setWebLifecycleState", params) == 0) {
      NSLog(@"[Rex] Unable to set page lifecycle state for %@", tabID);
    }
    if (!suspended &&
        self->_needsExtensionReloadTabs.erase(key) > 0 &&
        ![self->_privateTabs[tabID] boolValue]) {
      CefRefPtr<CefFrame> frame = browser->GetMainFrame();
      NSString *scheme = frame
          ? [NSURLComponents componentsWithString:RexNSString(frame->GetURL())]
                .scheme.lowercaseString
          : nil;
      if ([scheme isEqualToString:@"http"] ||
          [scheme isEqualToString:@"https"]) {
        browser->Reload();
      }
    }
  }];
}

- (void)prepareForApplicationTermination:(void (^)(void))completion {
  [self onMain:^{
    if (!self->_ready) { completion(); return; }
    self->_shuttingDown = YES;
    self->_terminationCompletion = [completion copy];
    NSLog(@"[Rex] Preparing Chromium for application termination.");
    [self cancelAllDownloadsForTermination];
    // Closing Rex's DevTools pipe peer posts DevToolsPipeHandler::Shutdown to
    // Chromium's UI thread. Do this while the external message pump and AppKit
    // run loop are still active so its read/write threads retire before the
    // final synchronous CefShutdown join.
    [self->_extensionPipe shutdown];
    // CloseBrowser cannot be initiated while CefScopedSendingEvent is active.
    // The delegate first cancels Cocoa's current quit event; this block then
    // runs after sendEvent has unwound.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_nativeExtensionOperationCompletion ||
          self->_extensionConfigurationCompletion ||
          self->_extensionConfigurationMutation) {
        if (self->_application) {
          self->_application->CancelManagedExtensionOperation(
              self->_nativeExtensionOperationToken);
        }
        self->_nativeExtensionOperationCompletion = nil;
        self->_extensionConfigurationCompletion = nil;
        self->_extensionConfigurationExpectedID = nil;
        self->_extensionConfigurationMutation = NO;
        ++self->_nativeExtensionOperationToken;
      }
      if (self->_application) {
        self->_application->CloseDefaultBrowsers();
      }
      std::vector<CefRefPtr<CefBrowser>> chromePopups;
      chromePopups.reserve(self->_chromePopupBrowsers.size());
      for (const auto &entry : self->_chromePopupBrowsers) {
        chromePopups.push_back(entry.second);
      }
      for (const auto &browser : chromePopups) {
        if (browser && browser->IsValid()) {
          browser->GetHost()->CloseBrowser(true);
        }
      }
      for (const auto &entry : self->_browsers) {
        if (entry.second && entry.second->IsValid()) {
          entry.second->GetHost()->CloseBrowser(true);
        }
      }
      for (const auto &entry : self->_auxiliaryChromeBrowsers) {
        if (entry.second && entry.second->IsValid()) {
          entry.second->GetHost()->CloseBrowser(true);
        }
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
  NSLog(@"[Rex] Chromium termination preparation completed.");
  [_views removeAllObjects];
  [_developerToolsViews removeAllObjects];
  for (NSWindow *popupWindow in _chromePopupWindowsByBrowserID.allValues) {
    [popupWindow orderOut:nil];
  }
  [_chromePopupWindowsByBrowserID removeAllObjects];
  for (NSWindow *chromeWindow in _embeddedChromeWindowsByBrowserID.allValues) {
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:NSWindowDidBecomeKeyNotification
                object:chromeWindow];
    [chromeWindow orderOut:nil];
  }
  [_embeddedChromeWindowsByBrowserID removeAllObjects];
  [_embeddedChromeNativeViewsByBrowserID removeAllObjects];
  for (NSWindow *popupWindow in _developerToolsPopupWindowsByBrowserID.allValues) {
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:NSWindowDidBecomeKeyNotification
                object:popupWindow];
    NSWindow *parentWindow = popupWindow.parentWindow;
    if (parentWindow) [parentWindow removeChildWindow:popupWindow];
    [popupWindow orderOut:nil];
  }
  [_developerToolsPopupWindowsByBrowserID removeAllObjects];
  [_tabProfileIDs removeAllObjects];
  [_privateTabs removeAllObjects];
  [_mutedTabs removeAllObjects];
  _focusedTabID = nil;
  _lastFocusedTabID = nil;
  @synchronized (_privacyPolicies) {
    [_privacyPolicies removeAllObjects];
  }
  [_downloadDirectories removeAllObjects];
  _browsers.clear();
  _embeddedChromeBrowserViews.clear();
  _auxiliaryChromeBrowsers.clear();
  _chromePopupBrowsers.clear();
  _pendingTabs.clear();
  _embeddedChromeTabs.clear();
  _browserReplacementTabs.clear();
  _startupPlaceholderTabs.clear();
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
  NSLog(@"[Rex] Final CEF shutdown requested (ready=%@).",
        _ready ? @"true" : @"false");
  if (!_ready || _finalizingShutdown) return;
  _finalizingShutdown = YES;
  NSLog(@"[Rex] Shutting down CEF after all Chromium browsers closed.");
  _taskManager = nullptr;
  // Termination preparation disconnects the DevTools pipe while the normal
  // external pump is active. Keep this idempotent call as an atexit fallback,
  // and keep fd 3/4 reserved until shutdown returns to prevent reuse.
  [_extensionPipe shutdown];
  _application->DrainMessagePumpForShutdown();
  CefShutdown();
  [_extensionPipe releaseChromiumDescriptors];
  _extensionPipe = nil;
  [_extensionSyncQueue removeAllObjects];
  _activeExtensionSyncRequest = nil;
  _nativeExtensionOperationCompletion = nil;
  _extensionConfigurationCompletion = nil;
  _extensionConfigurationExpectedID = nil;
  _extensionConfigurationMutation = NO;
  _extensionSyncActive = NO;
  _extensionPageReloadPending = NO;
  _extensionChromeWindowHostReady = NO;
  _extensionStartupBarrierActive = NO;
  _chromiumContextReady = NO;
  _application = nullptr;
  _libraryLoader.reset();
  _ready = NO;
  _finalizingShutdown = NO;
  NSLog(@"[Rex] CEF shutdown completed.");
}

@end

namespace {

bool RexDefaultChromeClient::BeginManagedExtensionOperation(
    uint64_t token,
    std::string script,
    std::string folder_path) {
  return BeginManagedExtensionOperationWithKind(
      token, std::move(script), std::move(folder_path),
      RexManagedExtensionOperationKind::kRuntimeMutation);
}

bool RexDefaultChromeClient::BeginManagedExtensionConfigurationOperation(
    uint64_t token,
    std::string script) {
  return BeginManagedExtensionOperationWithKind(
      token, std::move(script), std::string(),
      RexManagedExtensionOperationKind::kConfiguration);
}

bool RexDefaultChromeClient::BeginManagedExtensionOperationWithKind(
    uint64_t token,
    std::string script,
    std::string folder_path,
    RexManagedExtensionOperationKind kind) {
  CEF_REQUIRE_UI_THREAD();
  if (!token || script.empty() || managed_extension_operation_token_ ||
      !extension_window_host_browser_id_ ||
      kind == RexManagedExtensionOperationKind::kNone) {
    return false;
  }
  auto browserIterator = browsers_.find(extension_window_host_browser_id_);
  if (browserIterator == browsers_.end() || !browserIterator->second ||
      !browserIterator->second->IsValid()) {
    return false;
  }

  managed_extension_operation_token_ = token;
  managed_extension_operation_script_ = std::move(script);
  managed_extension_folder_path_ = std::move(folder_path);
  managed_extension_operation_kind_ = kind;
  managed_extension_script_dispatched_ = false;
  managed_extension_folder_dialog_consumed_ = false;
  DispatchManagedExtensionOperationIfReady();
  if (!managed_extension_script_dispatched_) {
    CefRefPtr<CefFrame> frame = browserIterator->second->GetMainFrame();
    if (!frame) {
      CancelManagedExtensionOperation(token);
      return false;
    }
    frame->LoadURL("chrome://extensions/");
  }
  return true;
}

void RexDefaultChromeClient::CancelManagedExtensionOperation(uint64_t token) {
  CEF_REQUIRE_UI_THREAD();
  if (!token || token != managed_extension_operation_token_) return;
  managed_extension_operation_token_ = 0;
  managed_extension_operation_script_.clear();
  managed_extension_folder_path_.clear();
  managed_extension_script_dispatched_ = false;
  managed_extension_folder_dialog_consumed_ = false;
  managed_extension_operation_kind_ =
      RexManagedExtensionOperationKind::kNone;
}

void RexDefaultChromeClient::DispatchManagedExtensionOperationIfReady() {
  CEF_REQUIRE_UI_THREAD();
  if (!extension_window_host_page_ready_ ||
      managed_extension_script_dispatched_ ||
      !managed_extension_operation_token_ ||
      managed_extension_operation_script_.empty()) {
    return;
  }
  auto browserIterator = browsers_.find(extension_window_host_browser_id_);
  CefRefPtr<CefBrowser> browser =
      browserIterator != browsers_.end() ? browserIterator->second : nullptr;
  CefRefPtr<CefFrame> frame =
      browser && browser->IsValid() ? browser->GetMainFrame() : nullptr;
  if (!frame || !RexIsChromeExtensionsURL(RexNSString(frame->GetURL()))) {
    return;
  }
  managed_extension_script_dispatched_ = true;
  frame->ExecuteJavaScript(managed_extension_operation_script_,
                           frame->GetURL(), 0);
}

void RexDefaultChromeClient::CompleteManagedExtensionOperation(
    const std::string &encoded_error) {
  CEF_REQUIRE_UI_THREAD();
  const uint64_t token = managed_extension_operation_token_;
  if (!token || managed_extension_operation_kind_ !=
                    RexManagedExtensionOperationKind::kRuntimeMutation) {
    return;
  }
  CancelManagedExtensionOperation(token);

  NSString *encoded = [[NSString alloc]
      initWithBytes:encoded_error.data()
             length:encoded_error.size()
           encoding:NSUTF8StringEncoding] ?: @"";
  NSString *decoded = encoded.stringByRemovingPercentEncoding ?: encoded;
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) {
    [runtime managedExtensionOperationDidFinishWithToken:token
                                             errorMessage:
                                                 decoded.length ? decoded : nil];
  }
}

void RexDefaultChromeClient::CompleteManagedExtensionConfigurationOperation(
    const std::string &encoded_payload,
    const std::string &transport_error) {
  CEF_REQUIRE_UI_THREAD();
  const uint64_t token = managed_extension_operation_token_;
  if (!token || managed_extension_operation_kind_ !=
                    RexManagedExtensionOperationKind::kConfiguration) {
    return;
  }
  CancelManagedExtensionOperation(token);

  NSString *payload = nil;
  NSString *errorMessage = nil;
  if (!transport_error.empty()) {
    errorMessage = [[NSString alloc]
        initWithBytes:transport_error.data()
               length:transport_error.size()
             encoding:NSUTF8StringEncoding] ?: @"invalid transport error";
  } else if (encoded_payload.size() >
             kRexMaximumEncodedExtensionConfigurationBytes) {
    errorMessage = @"encoded extension configuration result exceeds limit";
  } else {
    NSString *encoded = [[NSString alloc]
        initWithBytes:encoded_payload.data()
               length:encoded_payload.size()
             encoding:NSUTF8StringEncoding];
    if (!encoded) {
      errorMessage = @"extension configuration result is not valid UTF-8";
    } else {
      payload = encoded.stringByRemovingPercentEncoding;
      if (!payload) {
        errorMessage = @"extension configuration result has invalid escaping";
      } else if ([payload lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
                 kRexMaximumExtensionConfigurationJSONBytes) {
        payload = nil;
        errorMessage = @"extension configuration result exceeds limit";
      }
    }
  }

  RexChromiumRuntime *runtime = runtime_;
  if (runtime) {
    [runtime managedExtensionConfigurationOperationDidFinishWithToken:token
                                                               payload:payload
                                                          errorMessage:errorMessage];
  }
}

bool RexDefaultChromeClient::OnFileDialog(
    CefRefPtr<CefBrowser> browser,
    FileDialogMode mode,
    const CefString &title,
    const CefString &default_file_path,
    const std::vector<CefString> &accept_filters,
    const std::vector<CefString> &accept_extensions,
    const std::vector<CefString> &accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !callback ||
      browser->GetIdentifier() != extension_window_host_browser_id_ ||
      (mode != FILE_DIALOG_OPEN_FOLDER && mode != FILE_DIALOG_OPEN)) {
    return false;
  }

  NSString *folder = [[NSString alloc]
      initWithBytes:managed_extension_folder_path_.data()
             length:managed_extension_folder_path_.size()
           encoding:NSUTF8StringEncoding] ?: @"";
  NSError *validationError = nil;
  NSArray<NSString *> *validated = folder.length
      ? RexValidatedExtensionPaths(@[folder], &validationError)
      : nil;
  const bool validFolder = validated.count == 1 &&
      [validated.firstObject isEqualToString:folder];
  if (!validFolder ||
      !RexShouldAcceptManagedExtensionFolderDialog(
          managed_extension_operation_token_ != 0,
          managed_extension_script_dispatched_,
          managed_extension_folder_dialog_consumed_,
          browser->GetIdentifier(), extension_window_host_browser_id_, mode)) {
    // A timed-out or superseded hidden-host chooser must not fall through to
    // a user-visible dialog. Choosers from normal Rex tabs use other clients.
    callback->Cancel();
    return true;
  }

  managed_extension_folder_dialog_consumed_ = true;
  callback->Continue({CefString(managed_extension_folder_path_)});
  return true;
}

bool RexDefaultChromeClient::OnConsoleMessage(
    CefRefPtr<CefBrowser> browser,
    cef_log_severity_t level,
    const CefString &message,
    const CefString &source,
    int line) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || browser->GetIdentifier() != extension_window_host_browser_id_ ||
      !managed_extension_operation_token_) {
    return false;
  }
  const std::string value = message.ToString();
  if (managed_extension_operation_kind_ ==
      RexManagedExtensionOperationKind::kRuntimeMutation) {
    const std::string expected =
        std::string(kRexManagedExtensionResultPrefix) +
        std::to_string(managed_extension_operation_token_) + ":";
    if (!value.starts_with(expected)) return false;
    CompleteManagedExtensionOperation(value.substr(expected.size()));
    return true;
  }
  if (managed_extension_operation_kind_ ==
      RexManagedExtensionOperationKind::kConfiguration) {
    const std::string expected =
        std::string(kRexManagedExtensionConfigurationResultPrefix) +
        std::to_string(managed_extension_operation_token_) + ":";
    if (!value.starts_with(expected)) return false;
    const size_t payloadSize = value.size() - expected.size();
    if (payloadSize > kRexMaximumEncodedExtensionConfigurationBytes) {
      CompleteManagedExtensionConfigurationOperation(
          std::string(), "encoded extension configuration result exceeds limit");
    } else {
      CompleteManagedExtensionConfigurationOperation(
          value.substr(expected.size()));
    }
    return true;
  }
  return false;
}

bool RexDefaultChromeClient::CreateExtensionWindowHost() {
  CEF_REQUIRE_UI_THREAD();
  if (extension_window_host_view_ ||
      extension_window_host_browser_id_ != 0) {
    return true;
  }
  CefBrowserSettings browserSettings;
  browserSettings.background_color = CefColorSetARGB(255, 245, 245, 247);
  CefRefPtr<CefBrowserView> browserView =
      CefBrowserView::CreateBrowserView(
          this,
          "about:blank",
          browserSettings,
          nullptr,
          CefRequestContext::GetGlobalContext(),
          new RexExtensionChromeBrowserViewDelegate());
  if (!browserView) {
    NSLog(@"[Rex] Chromium extension window context creation failed");
    return false;
  }
  extension_window_host_view_ = browserView;
  CefRefPtr<CefWindow> window = CefWindow::CreateTopLevelWindow(
      new RexExtensionChromeWindowDelegate(browserView, CefSize(800, 600)));
  if (!window) {
    extension_window_host_view_ = nullptr;
    NSLog(@"[Rex] Chromium extension host window creation failed");
    return false;
  }
  NSLog(@"[Rex] Chromium extension window context creation started");
  return true;
}

void RexDefaultChromeClient::OnAfterCreated(
    CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;
  const int browserID = browser->GetIdentifier();
  browsers_[browserID] = browser;
  RexChromiumRuntime *runtime = runtime_;
  CefRefPtr<CefBrowserView> browserView =
      CefBrowserView::GetForBrowser(browser);
  if (extension_window_host_view_ && browserView &&
      extension_window_host_view_->IsSame(browserView)) {
    extension_window_host_browser_id_ = browserID;
    if (runtime) {
      [runtime registerExtensionChromeWindowHost:browser];
    } else {
      browser->GetHost()->CloseBrowser(true);
    }
    return;
  }
  if (runtime) {
    [runtime parkDefaultChromeBrowser:browser];
    pending_blank_browser_ids_.insert(browserID);
  } else {
    browser->GetHost()->CloseBrowser(true);
  }
}

void RexDefaultChromeClient::ForwardBlankBrowserIfStillPending(
    int browser_id) {
  CEF_REQUIRE_UI_THREAD();
  if (!pending_blank_browser_ids_.contains(browser_id) ||
      forwarding_browser_ids_.contains(browser_id) ||
      browser_id == extension_window_host_browser_id_) {
    return;
  }
  auto iterator = browsers_.find(browser_id);
  if (iterator == browsers_.end() || !iterator->second ||
      !iterator->second->IsValid()) {
    pending_blank_browser_ids_.erase(browser_id);
    return;
  }

  CefRefPtr<CefBrowser> browser = iterator->second;
  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  NSString *url = frame ? RexNSString(frame->GetURL()) : @"";
  if (![url isEqualToString:@"about:blank"]) return;
  pending_blank_browser_ids_.erase(browser_id);
  forwarding_browser_ids_.insert(browser_id);
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) {
    [runtime handleDefaultChromeBrowser:browser targetURL:url];
  } else {
    browser->GetHost()->CloseBrowser(true);
  }
}

bool RexDefaultChromeClient::OnBeforeBrowse(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    bool user_gesture,
    bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid() || !frame || !frame->IsMain() ||
      !request) {
    return false;
  }
  const int browserID = browser->GetIdentifier();
  if (browserID == extension_window_host_browser_id_ ||
      forwarding_browser_ids_.contains(browserID)) {
    return false;
  }
  NSString *url = RexNSString(request->GetURL());
  if (!url.length || [url isEqualToString:@"about:blank"] ||
      !RexCanForwardPopupURL(url)) {
    return false;
  }

  // Cancel before Chromium starts the temporary Chrome WebContents request.
  // Rex will create the single user-visible tab from the forwarded URL.
  pending_blank_browser_ids_.erase(browserID);
  forwarding_browser_ids_.insert(browserID);
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) {
    [runtime handleDefaultChromeBrowser:browser targetURL:url];
  } else {
    browser->GetHost()->CloseBrowser(true);
  }
  return true;
}

void RexDefaultChromeClient::OnLoadStart(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    TransitionType transition_type) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid() || !frame || !frame->IsMain()) return;
  const int browserID = browser->GetIdentifier();
  if (browserID == extension_window_host_browser_id_) {
    extension_window_host_page_ready_ = false;
    return;
  }
  if (forwarding_browser_ids_.contains(browserID)) {
    return;
  }
  const std::string url = frame->GetURL();
  if (url.empty() || url == "about:blank") return;
  pending_blank_browser_ids_.erase(browserID);
  forwarding_browser_ids_.insert(browserID);
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) {
    [runtime handleDefaultChromeBrowser:browser
                              targetURL:RexNSString(frame->GetURL())];
  } else {
    browser->GetHost()->CloseBrowser(true);
  }
}

void RexDefaultChromeClient::OnLoadEnd(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int http_status_code) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid() || !frame || !frame->IsMain()) return;
  const int browserID = browser->GetIdentifier();
  if (browserID == extension_window_host_browser_id_) {
    extension_window_host_page_ready_ =
        RexIsChromeExtensionsURL(RexNSString(frame->GetURL()));
    DispatchManagedExtensionOperationIfReady();
    return;
  }
  if (forwarding_browser_ids_.contains(browserID) ||
      frame->GetURL().ToString() != "about:blank") {
    return;
  }
  // OnAfterCreated is too early: tabs.create({url}) may still be waiting for a
  // later navigation callback. A committed blank main document is the first
  // deterministic signal that the extension explicitly requested a blank tab.
  ForwardBlankBrowserIfStillPending(browserID);
}

void RexDefaultChromeClient::OnBeforeClose(
    CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  bool wasExtensionWindowHost = false;
  if (browser) {
    const int browserID = browser->GetIdentifier();
    browsers_.erase(browserID);
    forwarding_browser_ids_.erase(browserID);
    pending_blank_browser_ids_.erase(browserID);
    if (extension_window_host_browser_id_ == browserID) {
      wasExtensionWindowHost = true;
      if (managed_extension_operation_token_) {
        if (managed_extension_operation_kind_ ==
            RexManagedExtensionOperationKind::kConfiguration) {
          CompleteManagedExtensionConfigurationOperation(
              std::string(), "Chromium extension host closed");
        } else {
          CompleteManagedExtensionOperation(
              "Chromium%20extension%20host%20closed");
        }
      }
      extension_window_host_browser_id_ = 0;
      extension_window_host_view_ = nullptr;
      extension_window_host_page_ready_ = false;
    }
  }
  RexChromiumRuntime *runtime = runtime_;
  if (runtime) {
    if (wasExtensionWindowHost) {
      [runtime extensionChromeWindowHostDidClose];
    } else {
      [runtime defaultChromeBrowserDidClose];
    }
  }
}

void RexDefaultChromeClient::CloseAllBrowsers() {
  CEF_REQUIRE_UI_THREAD();
  std::vector<CefRefPtr<CefBrowser>> browsers;
  browsers.reserve(browsers_.size());
  for (const auto &entry : browsers_) browsers.push_back(entry.second);
  for (const auto &browser : browsers) {
    if (browser && browser->IsValid()) {
      browser->GetHost()->CloseBrowser(true);
    }
  }
}

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
  NSMutableDictionary<NSString *, id> *fields = [@{
    @"category": category,
    @"host": hostValue,
    @"count": @1
  } mutableCopy];
  Emit(@"blockedResource", fields);
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

void RexEnsureDeveloperToolsEditingItems(
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
  if (!params || !model) return;
  const int type = params->GetTypeFlags();
  const bool editable = type & CM_TYPEFLAG_EDITABLE;
  const bool selection = type & CM_TYPEFLAG_SELECTION;
  if (!editable && !selection) return;

  const int flags = params->GetEditStateFlags();
  struct EditingItem {
    int command_id;
    const char16_t *label;
    int required_flag;
  };
  static constexpr EditingItem editableItems[] = {
      {MENU_ID_UNDO, u"撤销", CM_EDITFLAG_CAN_UNDO},
      {MENU_ID_REDO, u"重做", CM_EDITFLAG_CAN_REDO},
      {MENU_ID_CUT, u"剪切", CM_EDITFLAG_CAN_CUT},
      {MENU_ID_COPY, u"复制", CM_EDITFLAG_CAN_COPY},
      {MENU_ID_PASTE, u"粘贴", CM_EDITFLAG_CAN_PASTE},
      {MENU_ID_PASTE_MATCH_STYLE, u"粘贴并匹配样式", CM_EDITFLAG_CAN_PASTE},
      {MENU_ID_DELETE, u"删除", CM_EDITFLAG_CAN_DELETE},
      {MENU_ID_SELECT_ALL, u"全选", CM_EDITFLAG_CAN_SELECT_ALL},
  };
  static constexpr EditingItem selectionItems[] = {
      {MENU_ID_COPY, u"复制", CM_EDITFLAG_CAN_COPY},
      {MENU_ID_SELECT_ALL, u"全选", CM_EDITFLAG_CAN_SELECT_ALL},
  };
  const EditingItem *items = editable ? editableItems : selectionItems;
  const size_t itemCount = editable ? std::size(editableItems)
                                    : std::size(selectionItems);
  bool addedSeparator = false;
  for (size_t index = 0; index < itemCount; ++index) {
    const EditingItem &item = items[index];
    if (model->GetIndexOf(item.command_id) >= 0) continue;
    if (!addedSeparator && model->GetCount() > 0) {
      model->AddSeparator();
      addedSeparator = true;
    }
    model->AddItem(item.command_id, CefString(item.label));
    model->SetEnabled(item.command_id, flags & item.required_flag);
  }
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

bool RexBrowserClient::OnFileDialog(
    CefRefPtr<CefBrowser> browser,
    FileDialogMode mode,
    const CefString &title,
    const CefString &default_file_path,
    const std::vector<CefString> &accept_filters,
    const std::vector<CefString> &accept_extensions,
    const std::vector<CefString> &accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser) || !callback) {
    return false;
  }
  if (mode < FILE_DIALOG_OPEN || mode >= FILE_DIALOG_NUM_VALUES) {
    callback->Cancel();
    return true;
  }
  if (pending_file_dialog_callback_) {
    callback->Cancel();
    return true;
  }

  RexChromiumRuntime *runtime = runtime_;
  NSWindow *window = runtime ? [runtime hostWindowForTabID:tab_id_] : nil;
  if (!window) {
    callback->Cancel();
    return true;
  }

  NSSavePanel *panel = mode == FILE_DIALOG_SAVE
      ? [NSSavePanel savePanel]
      : [NSOpenPanel openPanel];
  panel.title = RexNSString(title).length ? RexNSString(title) : @"选择文件";
  panel.canCreateDirectories = mode == FILE_DIALOG_SAVE;
  panel.treatsFilePackagesAsDirectories = NO;

  if ([panel isKindOfClass:NSOpenPanel.class]) {
    NSOpenPanel *openPanel = (NSOpenPanel *)panel;
    openPanel.allowsMultipleSelection = mode == FILE_DIALOG_OPEN_MULTIPLE;
    openPanel.canChooseDirectories = mode == FILE_DIALOG_OPEN_FOLDER;
    openPanel.canChooseFiles = mode != FILE_DIALOG_OPEN_FOLDER;
    openPanel.resolvesAliases = YES;
  }

  NSMutableOrderedSet<NSString *> *allowedTypes =
      [[NSMutableOrderedSet alloc] init];
  for (const CefString &expanded : accept_extensions) {
    NSArray<NSString *> *parts =
        [RexNSString(expanded) componentsSeparatedByString:@";"];
    for (NSString *part in parts) {
      NSString *value = [part stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet];
      while ([value hasPrefix:@"."]) value = [value substringFromIndex:1];
      if (value.length && ![value isEqualToString:@"*"]) {
        [allowedTypes addObject:value.lowercaseString];
      }
    }
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (allowedTypes.count) panel.allowedFileTypes = allowedTypes.array;
#pragma clang diagnostic pop

  NSString *defaultPath = RexNSString(default_file_path);
  if (defaultPath.length) {
    BOOL isDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:defaultPath
                                           isDirectory:&isDirectory] &&
        isDirectory) {
      panel.directoryURL = [NSURL fileURLWithPath:defaultPath isDirectory:YES];
    } else {
      NSURL *defaultURL = [NSURL fileURLWithPath:defaultPath];
      panel.directoryURL = defaultURL.URLByDeletingLastPathComponent;
      if (mode == FILE_DIALOG_SAVE && defaultURL.lastPathComponent.length) {
        panel.nameFieldStringValue = defaultURL.lastPathComponent;
      }
    }
  }

  active_file_panel_ = panel;
  pending_file_dialog_callback_ = callback;
  CefRefPtr<RexBrowserClient> retained(this);
  [panel beginSheetModalForWindow:window
                completionHandler:^(NSModalResponse response) {
    if (retained->pending_file_dialog_callback_.get() != callback.get()) return;
    CefRefPtr<CefFileDialogCallback> completion =
        retained->pending_file_dialog_callback_;
    retained->pending_file_dialog_callback_ = nullptr;
    retained->active_file_panel_ = nil;
    if (response != NSModalResponseOK) {
      completion->Cancel();
      return;
    }

    NSArray<NSURL *> *urls = [panel isKindOfClass:NSOpenPanel.class]
        ? ((NSOpenPanel *)panel).URLs
        : (panel.URL ? @[panel.URL] : @[]);
    std::vector<CefString> paths;
    paths.reserve(urls.count);
    for (NSURL *url in urls) {
      if (url.isFileURL && url.path.length) {
        paths.emplace_back(RexUTF8(url.path));
      }
    }
    if (paths.empty()) completion->Cancel();
    else completion->Continue(paths);
  }];
  return true;
}

bool RexBrowserClient::OnJSDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString &origin_url,
    JSDialogType dialog_type,
    const CefString &message_text,
    const CefString &default_prompt_text,
    CefRefPtr<CefJSDialogCallback> callback,
    bool &suppress_message) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser) || !callback) {
    return false;
  }
  if (dialog_type < JSDIALOGTYPE_ALERT ||
      dialog_type >= JSDIALOGTYPE_NUM_VALUES) {
    callback->Continue(false, CefString());
    return true;
  }
  if (pending_js_dialog_callback_) {
    suppress_message = true;
    callback->Continue(false, CefString());
    return true;
  }

  RexChromiumRuntime *runtime = runtime_;
  NSWindow *window = runtime ? [runtime hostWindowForTabID:tab_id_] : nil;
  if (!window) {
    callback->Continue(false, CefString());
    return true;
  }

  NSAlert *alert = [[NSAlert alloc] init];
  NSString *origin = RexNSString(CefFormatUrlForSecurityDisplay(origin_url));
  alert.messageText = origin.length ? origin : @"网页消息";
  NSString *message = RexNSString(message_text);
  alert.informativeText = message.length ? message : @"此网页发来一条消息。";
  [alert addButtonWithTitle:@"好"];

  NSTextField *promptField = nil;
  if (dialog_type == JSDIALOGTYPE_CONFIRM ||
      dialog_type == JSDIALOGTYPE_PROMPT) {
    [alert addButtonWithTitle:@"取消"];
  }
  if (dialog_type == JSDIALOGTYPE_PROMPT) {
    promptField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    promptField.stringValue = RexNSString(default_prompt_text);
    promptField.accessibilityLabel = @"网页输入";
    alert.accessoryView = promptField;
  }

  active_js_alert_ = alert;
  pending_js_dialog_callback_ = callback;
  CefRefPtr<RexBrowserClient> retained(this);
  [alert beginSheetModalForWindow:window
               completionHandler:^(NSModalResponse response) {
    if (retained->pending_js_dialog_callback_.get() != callback.get()) return;
    CefRefPtr<CefJSDialogCallback> completion =
        retained->pending_js_dialog_callback_;
    retained->pending_js_dialog_callback_ = nullptr;
    retained->active_js_alert_ = nil;
    const bool accepted = response == NSAlertFirstButtonReturn;
    completion->Continue(
        accepted,
        accepted && promptField
            ? CefString(RexUTF8(promptField.stringValue))
            : CefString());
  }];
  return true;
}

bool RexBrowserClient::OnBeforeUnloadDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString &message_text,
    bool is_reload,
    CefRefPtr<CefJSDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser) || !callback) return false;
  if (pending_js_dialog_callback_) {
    callback->Continue(false, CefString());
    return true;
  }

  RexChromiumRuntime *runtime = runtime_;
  NSWindow *window = runtime ? [runtime hostWindowForTabID:tab_id_] : nil;
  if (!window) {
    callback->Continue(false, CefString());
    return true;
  }

  NSAlert *alert = [[NSAlert alloc] init];
  CefRefPtr<CefFrame> mainFrame = browser ? browser->GetMainFrame() : nullptr;
  NSString *origin = mainFrame
      ? RexNSString(CefFormatUrlForSecurityDisplay(mainFrame->GetURL()))
      : @"";
  alert.messageText = origin.length
      ? origin
      : (is_reload ? @"要重新加载此页面吗？" : @"要离开此页面吗？");
  NSString *message = RexNSString(message_text);
  alert.informativeText = message.length
      ? message
      : @"此页面可能有尚未保存的更改。";
  [alert addButtonWithTitle:is_reload ? @"重新加载" : @"离开"];
  [alert addButtonWithTitle:@"取消"];

  active_js_alert_ = alert;
  pending_js_dialog_callback_ = callback;
  CefRefPtr<RexBrowserClient> retained(this);
  [alert beginSheetModalForWindow:window
               completionHandler:^(NSModalResponse response) {
    if (retained->pending_js_dialog_callback_.get() != callback.get()) return;
    CefRefPtr<CefJSDialogCallback> completion =
        retained->pending_js_dialog_callback_;
    retained->pending_js_dialog_callback_ = nullptr;
    retained->active_js_alert_ = nil;
    completion->Continue(response == NSAlertFirstButtonReturn, CefString());
  }];
  return true;
}

void RexBrowserClient::CancelFileDialog() {
  CEF_REQUIRE_UI_THREAD();
  NSSavePanel *panel = active_file_panel_;
  active_file_panel_ = nil;
  CefRefPtr<CefFileDialogCallback> callback = pending_file_dialog_callback_;
  pending_file_dialog_callback_ = nullptr;
  if (panel.sheetParent) {
    [panel.sheetParent endSheet:panel returnCode:NSModalResponseCancel];
  } else {
    [panel orderOut:nil];
  }
  if (callback) callback->Cancel();
}

void RexBrowserClient::CancelJSDialog() {
  CEF_REQUIRE_UI_THREAD();
  NSAlert *alert = active_js_alert_;
  active_js_alert_ = nil;
  CefRefPtr<CefJSDialogCallback> callback = pending_js_dialog_callback_;
  pending_js_dialog_callback_ = nullptr;
  NSWindow *panel = alert.window;
  if (panel.sheetParent) {
    [panel.sheetParent endSheet:panel returnCode:NSModalResponseCancel];
  } else {
    [panel orderOut:nil];
  }
  if (callback) callback->Continue(false, CefString());
}

void RexBrowserClient::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (IsPrimaryBrowser(browser)) {
    CancelFileDialog();
    CancelJSDialog();
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
      @(rex::privacy::CategoryToken(decision.category)),
      decision.host);
  return RV_CANCEL;
}

bool RexBrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefRequest> request,
                                      bool user_gesture,
                                      bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame || !frame->IsMain() || !request) return false;
  if (IsPrimaryBrowser(browser)) {
    // A new main-frame navigation invalidates any Rex-owned chooser or JS
    // dialog from the previous document before Chromium starts the reset.
    CancelFileDialog();
    CancelJSDialog();
  }

  // User-visible tabs never own Chromium WebUI. The hidden extension
  // management host uses RexDefaultChromeClient and is intentionally outside
  // this policy, while Rex presents its own rex://extensions route.
  const bool shouldBlock =
      rex::navigation::ShouldBlockVisibleBrowserNavigation(
          request->GetURL().ToString());

  // LoadingState is aggregate browser state and may remain true when a new
  // LoadURL replaces an in-flight navigation. Establish identity here so every
  // main-frame navigation gets a fresh generation while redirects stay grouped
  // with the navigation that caused them.
  if (IsPrimaryBrowser(browser) &&
      rex::navigation::ShouldStartNavigationGeneration(
          shouldBlock, is_redirect)) {
    navigation_generation_ =
        gRexNavigationGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
  }
  return shouldBlock;
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
  // CEF creates DevTools with the Chrome runtime. macOS cannot
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
  if (!runtime || !browser || !browser->IsValid()) return;
  if (browser->IsPopup()) {
    [runtime registerChromePopupBrowser:browser sourceTabID:tab_id_];
    return;
  }
  if (primary_browser_identifier_ == 0) {
    primary_browser_identifier_ = browser->GetIdentifier();
    CefRefPtr<RexBrowserClient> retained(this);
    void (^registerAndLoad)(void) = ^{
      if (!browser->IsValid()) return;
      [runtime registerBrowser:browser
                         tabID:retained->tab_id_
               deferPendingURL:NO];
    };
    if (browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
      NSView *nativeView =
          CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      NSWindow *nativeWindow = nativeView.window;
      if (nativeWindow) {
        nativeWindow.alphaValue = 0.01;
        nativeWindow.ignoresMouseEvents = YES;
        nativeWindow.hasShadow = NO;
        nativeWindow.excludedFromWindowsMenu = YES;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        registerAndLoad();
      });
    } else {
      registerAndLoad();
    }
    if ([tab_id_ hasPrefix:@"rex-extension-surface:"]) {
      browser->GetHost()->SetAutoResizeEnabled(
          true, CefSize(25, 25), CefSize(800, 600));
    }
    return;
  }
  if (!IsPrimaryBrowser(browser)) {
    [runtime registerAuxiliaryChromeBrowser:browser sourceTabID:tab_id_];
  }
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
  if (browser &&
      browser->GetHost()->GetRuntimeStyle() != CEF_RUNTIME_STYLE_CHROME) {
    NSView *nativeView =
        (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [nativeView removeFromSuperview];
    return true;
  }
  // Auxiliary Chrome-style windows own their native close lifecycle.
  return false;
}

void RexBrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  RexChromiumRuntime *runtime = runtime_;
  if (IsPrimaryBrowser(browser)) {
    CancelFileDialog();
    CancelJSDialog();
  }
  if (browser && browser->IsPopup()) {
    if (runtime) [runtime chromePopupBrowserDidClose:browser];
    return;
  }
  if (browser && !IsPrimaryBrowser(browser)) {
    if (runtime) [runtime auxiliaryChromeBrowserDidClose:browser];
    return;
  }
  EmitMediaAccess(false, false);
  if (runtime) [runtime browser:browser didCloseForTabID:tab_id_];
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

void RexDevToolsClient::OnBeforeContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
  CEF_REQUIRE_UI_THREAD();
  RexEnsureDeveloperToolsEditingItems(params, model);
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

  // Allow Chromium to finish constructing the Chrome-style window before it is
  // aligned as a borderless child of Rex's DevTools host.
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
  if (!IsPrimaryBrowser(browser)) return;
  if (frame->IsMain()) {
    NSString *currentURL = RexNSString(url);
    RexChromiumRuntime *runtime = runtime_;
    if (runtime &&
        [runtime shouldHideStartupPlaceholderForTabID:tab_id_
                                             currentURL:currentURL]) {
      return;
    }
    [runtime didCommitStartupAddressForTabID:tab_id_
                                  currentURL:currentURL];
    Emit(@"address", @{
      @"url": currentURL,
      @"navigationGeneration": @(navigation_generation_)
    });
    EmitSecuritySnapshot(browser);
  }
}

void RexBrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                     const CefString &title) {
  if (!IsPrimaryBrowser(browser)) return;
  CefRefPtr<CefFrame> frame = browser ? browser->GetMainFrame() : nullptr;
  NSString *currentURL = frame ? RexNSString(frame->GetURL()) : @"";
  RexChromiumRuntime *runtime = runtime_;
  if (runtime &&
      [runtime shouldHideStartupPlaceholderForTabID:tab_id_
                                           currentURL:currentURL]) {
    return;
  }
  Emit(@"title", @{
    @"title": RexNSString(title),
    @"navigationGeneration": @(navigation_generation_)
  });
}

bool RexBrowserClient::OnAutoResize(CefRefPtr<CefBrowser> browser,
                                    const CefSize &new_size) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser) ||
      ![tab_id_ hasPrefix:@"rex-extension-surface:"]) {
    return false;
  }
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime || new_size.width <= 0 || new_size.height <= 0) return false;
  if (browser->IsLoading()) {
    pending_auto_resize_width_ = new_size.width;
    pending_auto_resize_height_ = new_size.height;
    return true;
  }
  pending_auto_resize_width_ = 0;
  pending_auto_resize_height_ = 0;
  [runtime browser:browser
      preferredContentSizeDidChange:NSMakeSize(new_size.width, new_size.height)
                              tabID:tab_id_];
  return true;
}

void RexBrowserClient::OnFaviconURLChange(
    CefRefPtr<CefBrowser> browser,
    const std::vector<CefString> &icon_urls) {
  if (!IsPrimaryBrowser(browser)) return;
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
  if (!IsPrimaryBrowser(browser)) return;
  Emit(@"audio", @{ @"isPlaying": @YES });
}

void RexBrowserClient::OnAudioStreamPacket(CefRefPtr<CefBrowser> browser,
                                           const float **data,
                                           int frames,
                                           int64_t pts) {
}

void RexBrowserClient::OnAudioStreamStopped(CefRefPtr<CefBrowser> browser) {
  if (!IsPrimaryBrowser(browser)) return;
  Emit(@"audio", @{ @"isPlaying": @NO });
}

void RexBrowserClient::OnAudioStreamError(CefRefPtr<CefBrowser> browser,
                                          const CefString &message) {
  if (!IsPrimaryBrowser(browser)) return;
  Emit(@"audio", @{ @"isPlaying": @NO });
}

void RexBrowserClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                               double progress) {
  if (!IsPrimaryBrowser(browser)) return;
  Emit(@"progress", @{
    @"progress": @(progress),
    @"navigationGeneration": @(navigation_generation_)
  });
}

void RexBrowserClient::OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                              bool fullscreen) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser)) return;
  Emit(@"fullscreen", @{ @"isFullscreen": @(fullscreen) });
}

void RexBrowserClient::OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                                           bool has_video_access,
                                           bool has_audio_access) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser)) return;
  EmitMediaAccess(has_video_access, has_audio_access);
}

void RexBrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                            bool is_loading,
                                            bool can_go_back,
                                            bool can_go_forward) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsPrimaryBrowser(browser)) return;
  if (is_loading && navigation_generation_ == 0) {
    navigation_generation_ =
        gRexNavigationGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
  }
  Emit(@"loading", @{ @"isLoading": @(is_loading),
                      @"canGoBack": @(can_go_back),
                      @"canGoForward": @(can_go_forward),
                      @"navigationGeneration": @(navigation_generation_) });
  if (is_loading) {
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
  if (!callback) return false;
  RexChromiumRuntime *runtime = runtime_;
  if (!runtime || !browser || !browser->IsValid()) return false;
  NSURL *directoryURL = [runtime downloadDirectoryForTabID:tab_id_];
  if (!directoryURL.isFileURL) {
    directoryURL = [NSURL fileURLWithPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads/Rex"]
                               isDirectory:YES];
  }
  NSError *directoryError = nil;
  if (![NSFileManager.defaultManager
          createDirectoryAtURL:directoryURL
   withIntermediateDirectories:YES
                    attributes:nil
                         error:&directoryError]) {
    NSLog(@"[Rex] Unable to prepare download directory %@: %@",
          directoryURL.path, directoryError.localizedDescription);
  }
  NSString *filename = RexNSString(suggested_name);
  if (!filename.length && download_item) {
    filename = RexNSString(download_item->GetSuggestedFileName());
  }
  if (!filename.length) filename = @"下载文件";

  NSString *destinationPath = RexUniqueDownloadPath(directoryURL, filename);
  // Chromium owns the request, redirect chain, transfer and file lifecycle.
  // Rex supplies only the destination and maps Chromium progress into its UI.
  callback->Continue(RexUTF8(destinationPath), false);
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
    @"originalURL": RexNSString(download_item->GetOriginalUrl()),
    @"filename": filename,
    @"mimeType": RexNSString(download_item->GetMimeType()),
    @"receivedBytes": @(download_item->GetReceivedBytes()),
    @"expectedBytes": @(download_item->GetTotalBytes()),
    @"percentComplete": @(download_item->GetPercentComplete()),
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
  if (!IsPrimaryBrowser(browser)) return;
  if (!frame || !frame->IsValid()) return;
  if (frame->IsMain()) {
    if ([tab_id_ hasPrefix:@"rex-extension-surface:"] &&
        pending_auto_resize_width_ > 0 &&
        pending_auto_resize_height_ > 0) {
      const NSSize pendingSize =
          NSMakeSize(pending_auto_resize_width_, pending_auto_resize_height_);
      pending_auto_resize_width_ = 0;
      pending_auto_resize_height_ = 0;
      RexChromiumRuntime *runtime = runtime_;
      if (runtime) {
        [runtime browser:browser
            preferredContentSizeDidChange:pendingSize
                                    tabID:tab_id_];
      }
    }
    Emit(@"loadEnd", @{
      @"httpStatusCode": @(httpStatusCode),
      @"navigationGeneration": @(navigation_generation_)
    });
    EmitSecuritySnapshot(browser);

  }
}

void RexBrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   ErrorCode error_code,
                                   const CefString &error_text,
                                   const CefString &failed_url) {
  if (!IsPrimaryBrowser(browser)) return;
  if (!frame->IsMain() || error_code == ERR_ABORTED) return;
  NSLog(@"[Rex] load error tab=%@ browser=%d code=%d url=%@ message=%@",
        tab_id_, browser ? browser->GetIdentifier() : 0,
        static_cast<int>(error_code), RexNSString(failed_url),
        RexNSString(error_text));
  Emit(@"loadError", @{ @"code": @((int)error_code),
                        @"message": RexNSString(error_text),
                        @"url": RexNSString(failed_url),
                        @"navigationGeneration": @(navigation_generation_) });
}

void RexBrowserClient::OnRenderProcessTerminated(
    CefRefPtr<CefBrowser> browser,
    TerminationStatus status,
    int error_code,
    const CefString &error_string) {
  if (!IsPrimaryBrowser(browser)) return;
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
