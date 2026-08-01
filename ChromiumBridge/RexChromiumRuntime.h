#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RexChromiumEventHandler)(NSDictionary<NSString *, id> *event);
typedef void (^RexChromiumBrowserDidCloseHandler)(void);
typedef void (^RexChromiumBrowserPreferredSizeHandler)(NSSize size);
/// `result` is nonnull only after Chromium's browser-level Extensions domain
/// confirms the requested set. It contains `generation`, `loadedPaths`, and
/// `loadedExtensionIDs`.
typedef void (^RexChromiumExtensionRuntimeCompletion)(
    NSDictionary<NSString *, id> *_Nullable result,
    NSError *_Nullable error);
/// Returns Chromium's authoritative configuration for one installed
/// extension. Optional capabilities are represented by the corresponding
/// `*Available` fields in `configuration`.
typedef void (^RexChromiumExtensionConfigurationCompletion)(
    NSDictionary<NSString *, id> *_Nullable configuration,
    NSError *_Nullable error);

/// Errors produced while loading or initializing the embedded Chromium runtime.
FOUNDATION_EXPORT NSErrorDomain const RexChromiumErrorDomain;

/// CEF's process-singleton relaunch result. This is a successful handoff to an
/// existing Rex process, not an initialization failure.
FOUNDATION_EXPORT NSInteger const RexChromiumNormalExitProcessNotifiedCode;

/// Returns YES only for CEF's normal process-singleton early-exit result.
FOUNDATION_EXPORT BOOL RexChromiumErrorIsNormalEarlyExit(NSError *error);

/// Installs the AppKit run/termination hooks required by CEF on macOS. Call
/// before SwiftUI enters NSApplicationMain so the main event loop can return
/// and CEF can shut down before process exit.
FOUNDATION_EXPORT void RexInstallCEFApplicationLifecycleHooks(void);

/// Orders an auxiliary AppKit window without taking key status. CEF embeds
/// remote views whose macOS window-ordering callbacks can raise Objective-C
/// exceptions; those must not escape into Swift's event dispatch path.
FOUNDATION_EXPORT BOOL RexOrderAuxiliaryWindowFrontSafely(NSWindow *window);

/// Stable AppKit host for one CEF browser instance. SwiftUI may resize or move
/// this view but must not recreate it for ordinary state changes.
@interface RexChromiumBrowserView : NSView

@property(nonatomic, readonly, copy) NSString *tabID;
@property(nonatomic, readonly, copy) NSString *profileID;
@property(nonatomic, readonly, getter=isPrivateBrowsing) BOOL privateBrowsing;
@property(nonatomic, copy, nullable) RexChromiumBrowserDidCloseHandler
    browserDidCloseHandler;
/// Set only by extension popup surfaces. Chromium reports the popup document's
/// preferred size using the same 25...800 by 25...600 DIP bounds as Chrome.
@property(nonatomic, copy, nullable) RexChromiumBrowserPreferredSizeHandler
    preferredSizeDidChangeHandler;

- (instancetype)initWithTabID:(NSString *)tabID
                    initialURL:(NSString *)initialURL
                     profileID:(NSString *)profileID
               privateBrowsing:(BOOL)privateBrowsing NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

/// Stable AppKit host for Chromium's own DevTools browser. The surrounding
/// SwiftUI panel provides the docked chrome while CEF renders the tool content.
@interface RexChromiumDevToolsView : NSView

@property(nonatomic, readonly, copy) NSString *tabID;

- (instancetype)initWithTabID:(NSString *)tabID NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

/// Process-wide CEF lifecycle and command facade. All public methods marshal to
/// the main thread because CEF's browser UI thread is the macOS main thread.
@interface RexChromiumRuntime : NSObject

@property(class, nonatomic, readonly) RexChromiumRuntime *shared;
@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, readonly, getter=isFinalizingShutdown) BOOL finalizingShutdown;
@property(nonatomic, copy, nullable) RexChromiumEventHandler eventHandler;
@property(nonatomic, readonly, copy) NSString *cefVersion;
@property(nonatomic, readonly, copy) NSString *chromiumVersion;

/// Snapshot of the Chromium task associated with each live tab. Must be called
/// on the main thread because CefTaskManager is restricted to CEF's UI thread.
- (void)beginTabTaskMetricsMonitoring;
- (void)endTabTaskMetricsMonitoring;
- (NSArray<NSDictionary<NSString *, id> *> *)tabTaskMetricsSnapshot;

- (BOOL)startWithCacheRoot:(NSURL *)cacheRoot
                    locale:(NSString *)locale
       publicSuffixListURL:(NSURL *)publicSuffixListURL
         privacyCatalogURL:(NSURL *)privacyCatalogURL
     managedExtensionPaths:(NSArray<NSString *> *)managedExtensionPaths
     enabledExtensionPaths:(NSArray<NSString *> *)enabledExtensionPaths
                     error:(NSError **)error;
- (void)prepareForApplicationTermination:(void (^)(void))completion;
- (void)shutdownAfterApplicationTermination;

- (RexChromiumBrowserView *)browserViewForTabID:(NSString *)tabID
                                      initialURL:(NSString *)initialURL
                                       profileID:(NSString *)profileID
                                 privateBrowsing:(BOOL)privateBrowsing;
- (RexChromiumDevToolsView *)developerToolsViewForTabID:(NSString *)tabID;

- (void)configureTabID:(NSString *)tabID
              profileID:(NSString *)profileID
        privateBrowsing:(BOOL)privateBrowsing;
- (void)respondToPermissionRequestID:(NSString *)requestID
                            decision:(NSString *)decision;
- (void)configureDownloadDirectoryURL:(nullable NSURL *)directoryURL
                                tabID:(NSString *)tabID;
- (void)cancelDownloadID:(NSInteger)downloadID tabID:(NSString *)tabID;
- (void)startDownloadURLString:(NSString *)urlString tabID:(NSString *)tabID;

- (void)closeTabID:(NSString *)tabID;
- (void)loadURLString:(NSString *)urlString tabID:(NSString *)tabID;
- (void)goBackForTabID:(NSString *)tabID;
- (void)goForwardForTabID:(NSString *)tabID;
- (void)reloadTabID:(NSString *)tabID;
- (void)reloadIgnoringCacheForTabID:(NSString *)tabID;
- (void)stopTabID:(NSString *)tabID;
- (void)exitFullscreenForTabID:(NSString *)tabID;
- (void)printTabID:(NSString *)tabID;
- (void)setAudioMuted:(BOOL)muted tabID:(NSString *)tabID;
/// Per-tab shield policy. Gates catalog-based blocking per tab together with
/// the global -setContentBlockingEnabled: preference.
/// mode: off | standard | strict | aggressive
- (void)setPrivacyPolicyForTabID:(NSString *)tabID
                         enabled:(BOOL)enabled
                            mode:(NSString *)mode
         fingerprintProtection:(BOOL)fingerprintProtection
         blockThirdPartyCookies:(BOOL)blockThirdPartyCookies;
/// Global content-blocking toggle for the curated ad/tracker host catalogs.
/// Takes effect immediately for subsequent requests; no restart needed.
- (void)setContentBlockingEnabled:(BOOL)enabled;
/// Reconciles Chromium's live unpacked extensions while preserving disabled
/// packages in the profile. Only `removedPaths` authorizes an uninstall;
/// `enabledPaths` and `forceReloadPaths` must be subsets of `managedPaths`.
/// Completion is delivered on the main thread after final registry validation.
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
                                            completion;
/// Reads one extension through the hidden chrome://extensions management
/// context. The completion is delivered on the main thread.
- (void)readExtensionConfigurationForExtensionID:(NSString *)extensionID
                                        completion:
                                            (nullable RexChromiumExtensionConfigurationCompletion)
                                                completion;
/// Applies only the nonnull fields, then reads the extension back from
/// Chromium and returns that authoritative state. `hostAccess`, when present,
/// must be ON_CLICK, ON_SPECIFIC_SITES, or ON_ALL_SITES. A nonnull
/// `sitePermissionHost` must be paired with `sitePermissionGranted` and is
/// applied through developerPrivate.addHostPermission/removeHostPermission.
- (void)updateExtensionConfigurationForExtensionID:(NSString *)extensionID
                                         hostAccess:(nullable NSString *)hostAccess
                                  userScriptsAccess:(nullable NSNumber *)userScriptsAccess
                                          fileAccess:(nullable NSNumber *)fileAccess
                                     incognitoAccess:(nullable NSNumber *)incognitoAccess
                                  sitePermissionHost:(nullable NSString *)sitePermissionHost
                               sitePermissionGranted:(nullable NSNumber *)sitePermissionGranted
                                          completion:
                                              (nullable RexChromiumExtensionConfigurationCompletion)
                                                  completion;
- (void)setZoomLevel:(double)zoomLevel tabID:(NSString *)tabID;
- (void)findText:(NSString *)text
         forward:(BOOL)forward
        findNext:(BOOL)findNext
           tabID:(NSString *)tabID;
- (void)stopFindingForTabID:(NSString *)tabID;
- (void)showDeveloperToolsForTabID:(NSString *)tabID;
- (void)showDeveloperToolsConsoleForTabID:(NSString *)tabID;
- (void)showDeveloperToolsInspectForTabID:(NSString *)tabID;
- (void)showDeveloperToolsForTabID:(NSString *)tabID
                          inspectX:(NSInteger)inspectX
                          inspectY:(NSInteger)inspectY;
- (void)closeDeveloperToolsForTabID:(NSString *)tabID;
- (BOOL)handleDeveloperToolsShortcutForWindow:(nullable NSWindow *)window;
- (void)setFocused:(BOOL)focused tabID:(NSString *)tabID;
- (void)setPageSuspended:(BOOL)suspended tabID:(NSString *)tabID;
- (void)notifyHostViewDidLayout:(NSView *)hostView tabID:(NSString *)tabID;
- (void)notifyDeveloperToolsHostDidLayoutForTabID:(NSString *)tabID;
/// While YES, layout notifications defer nonessential host synchronization.
- (void)setLayoutSyncSuspended:(BOOL)suspended;
/// Force one final native-view layout sync for all open content and DevTools browsers.
- (void)flushLayoutSync;

@end

NS_ASSUME_NONNULL_END
