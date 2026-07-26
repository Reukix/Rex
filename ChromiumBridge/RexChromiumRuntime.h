#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RexChromiumEventHandler)(NSDictionary<NSString *, id> *event);

/// Stable AppKit host for one CEF browser instance. SwiftUI may resize or move
/// this view but must not recreate it for ordinary state changes.
@interface RexChromiumBrowserView : NSView

@property(nonatomic, readonly, copy) NSString *tabID;
@property(nonatomic, readonly, copy) NSString *profileID;
@property(nonatomic, readonly, getter=isPrivateBrowsing) BOOL privateBrowsing;

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
@property(nonatomic, copy, nullable) RexChromiumEventHandler eventHandler;
@property(nonatomic, readonly, copy) NSString *cefVersion;
@property(nonatomic, readonly, copy) NSString *chromiumVersion;

- (BOOL)startWithCacheRoot:(NSURL *)cacheRoot
                    locale:(NSString *)locale
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
