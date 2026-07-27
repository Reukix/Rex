#if REX_CEF
import AppKit
import Foundation
import SwiftUI

@MainActor
final class ChromiumBrowserEngine: BrowserEngine {
    private let runtime: RexChromiumRuntime
    private var continuations: [UUID: AsyncStream<BrowserEvent>.Continuation] = [:]
    private var navigationStates: [UUID: NavigationState] = [:]
    private var downloadIDs: [String: UUID] = [:]
    private var activeDownloads: [UUID: (tabID: UUID, cefID: Int)] = [:]
    private var pendingRetryIDs: [String: [UUID]] = [:]

    init(runtime: RexChromiumRuntime = .shared) {
        self.runtime = runtime
        runtime.eventHandler = { [weak self] payload in
            Task { @MainActor in self?.receive(payload) }
        }
    }

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }

    func eventStream() async -> AsyncStream<BrowserEvent> {
        let subscriptionID = UUID()
        let pair = AsyncStream<BrowserEvent>.makeStream()
        continuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: subscriptionID) }
        }
        return pair.stream
    }

    func execute(_ command: BrowserCommand) async throws {
        switch command {
        case let .createPage(tabID, profile):
            // The stable NSView host creates the CEF browser when attached.
            runtime.configureTabID(
                tabID.uuidString,
                profileID: profile.id.uuidString,
                privateBrowsing: profile.isPrivate
            )
        case let .destroyPage(tabID):
            runtime.closeTabID(tabID.uuidString)
        case let .loadURL(tabID, url):
            guard let runtimeURL = Self.runtimeURL(for: url) else {
                throw BrowserEngineError.unsupportedScheme
            }
            runtime.loadURLString(runtimeURL.absoluteString, tabID: tabID.uuidString)
        case let .goBack(tabID):
            runtime.goBack(forTabID: tabID.uuidString)
        case let .goForward(tabID):
            runtime.goForward(forTabID: tabID.uuidString)
        case let .reload(tabID):
            runtime.reloadTabID(tabID.uuidString)
        case let .reloadIgnoringCache(tabID):
            runtime.reloadIgnoringCache(forTabID: tabID.uuidString)
        case let .stop(tabID):
            runtime.stopTabID(tabID.uuidString)
        case let .setZoom(tabID, level):
            guard 0.25...5 ~= level else { throw BrowserEngineError.invalidPayload }
            let chromiumLevel = log(level) / log(1.2)
            runtime.setZoomLevel(chromiumLevel, tabID: tabID.uuidString)
            mutateNavigation(tabID) { $0.zoomLevel = level }
        case let .printPage(tabID):
            runtime.printTabID(tabID.uuidString)
        case let .setAudioMuted(tabID, muted):
            runtime.setAudioMuted(muted, tabID: tabID.uuidString)
        case let .setPrivacyPolicy(tabID, enabled, level, fingerprintProtection, blockThirdPartyCookies):
            let mode: String
            switch level {
            case .standard: mode = "standard"
            case .strict: mode = "strict"
            case .custom: mode = "aggressive"
            }
            runtime.setPrivacyPolicyForTabID(
                tabID.uuidString,
                enabled: enabled,
                mode: mode,
                fingerprintProtection: fingerprintProtection,
                blockThirdPartyCookies: blockThirdPartyCookies
            )
        case let .setContentBlocking(enabled):
            runtime.setContentBlockingEnabled(enabled)
        case let .reloadExtensionRules(paths, forceReloadPaths):
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                runtime.reloadExtensionRules(
                    fromPaths: paths,
                    forceReloadPaths: forceReloadPaths
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        case let .find(tabID, query, forward, findNext):
            guard query.utf8.count <= 4_096 else { throw BrowserEngineError.invalidPayload }
            runtime.findText(
                query,
                forward: forward,
                findNext: findNext,
                tabID: tabID.uuidString
            )
        case let .stopFinding(tabID):
            runtime.stopFinding(forTabID: tabID.uuidString)
        case let .openDeveloperTools(tabID):
            runtime.showDeveloperTools(forTabID: tabID.uuidString)
        case let .openDeveloperToolsConsole(tabID):
            runtime.showDeveloperToolsConsole(forTabID: tabID.uuidString)
        case let .openDeveloperToolsInspect(tabID):
            runtime.showDeveloperToolsInspect(forTabID: tabID.uuidString)
        case let .respondToPermission(requestID, decision):
            runtime.respond(toPermissionRequestID: requestID.uuidString, decision: decision.rawValue)
        case let .cancelDownload(downloadID):
            guard let activeDownload = activeDownloads[downloadID] else { return }
            runtime.cancelDownloadID(activeDownload.cefID, tabID: activeDownload.tabID.uuidString)
        case let .retryDownload(downloadID, tabID, url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw BrowserEngineError.unsupportedScheme
            }
            let retryKey = downloadRetryKey(tabID: tabID, url: url)
            pendingRetryIDs[retryKey, default: []].append(downloadID)
            runtime.startDownloadURLString(url.absoluteString, tabID: tabID.uuidString)
        case let .setDownloadDirectory(tabID, directoryURL):
            guard directoryURL == nil || directoryURL?.isFileURL == true else {
                throw BrowserEngineError.invalidPayload
            }
            runtime.configureDownloadDirectoryURL(directoryURL, tabID: tabID.uuidString)
        case let .recoverCrashedPage(tabID):
            runtime.reloadTabID(tabID.uuidString)
        case let .setPagePriority(tabID, isFocused):
            runtime.setFocused(isFocused, tabID: tabID.uuidString)
        case let .setPageSuspended(tabID, isSuspended):
            runtime.setPageSuspended(isSuspended, tabID: tabID.uuidString)
        }
    }

    private func receive(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String else { return }
        if kind == "extensionRuntimeChanged" || kind == "extensionRuntimeError" {
            // The correlated command completion is the sole runtime-state writer.
            return
        }

        guard let tabString = payload["tabID"] as? String else { return }
        guard let tabID = UUID(uuidString: tabString) else {
            receiveExtensionSurfaceEvent(
                kind: kind,
                runtimeTabID: tabString,
                payload: payload
            )
            return
        }

        switch kind {
        case "created":
            emit(.pageCreated(tabID: tabID))
        case "address":
            mutateNavigation(tabID) { state in
                if let value = payload["url"] as? String {
                    state.url = Self.userVisibleURL(from: value)
                }
            }
        case "loading":
            mutateNavigation(tabID) { state in
                state.isLoading = payload["isLoading"] as? Bool ?? false
                state.canGoBack = payload["canGoBack"] as? Bool ?? false
                state.canGoForward = payload["canGoForward"] as? Bool ?? false
                if !state.isLoading { state.loadingProgress = 1 }
            }
        case "progress":
            mutateNavigation(tabID) { state in
                state.loadingProgress = payload["progress"] as? Double ?? 0
            }
        case "siteSecurity":
            guard let info = SiteSecurityPayloadDecoder.decode(payload) else { return }
            var visibleInfo = info
            visibleInfo.url = info.url.flatMap(Self.userVisibleURL(from:))
            emit(.siteSecurityChanged(tabID: tabID, info: visibleInfo))
        case "title":
            emit(.titleChanged(
                tabID: tabID,
                title: RexExtensionResourceURL.userVisibleString(
                    from: payload["title"] as? String ?? ""
                )
            ))
        case "favicon":
            let rawURL = payload["url"] as? String
            let url = rawURL.flatMap(Self.userVisibleURL(from:))
            let imageData = (payload["imageData"] as? Data)
                ?? (payload["imageData"] as? NSData).map { Data(referencing: $0) }
            emit(.faviconChanged(tabID: tabID, url: url, imageData: imageData))
        case "audio":
            emit(.audioStateChanged(tabID: tabID, isPlaying: payload["isPlaying"] as? Bool ?? false))
        case "mediaAccess":
            emit(.mediaAccessChanged(tabID: tabID, isActive: payload["isActive"] as? Bool ?? false))
        case "popup":
            guard let rawURL = payload["url"] as? String,
                  let url = Self.userVisibleURL(from: rawURL),
                  Self.isAllowedUserVisibleNavigation(url) else { return }
            emit(.popupRequested(
                tabID: tabID,
                url: url,
                foreground: (payload["foreground"] as? Bool) ?? true
            ))
        case "splitLink":
            guard let rawURL = payload["url"] as? String,
                  let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            emit(.splitLinkRequested(tabID: tabID, url: url))
        case "contextSearch":
            let text = (payload["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            emit(.contextSearchRequested(tabID: tabID, text: text))
        case "developerToolsRequested":
            emit(.developerToolsRequested(
                tabID: tabID,
                inspectX: (payload["inspectX"] as? NSNumber)?.intValue ?? -1,
                inspectY: (payload["inspectY"] as? NSNumber)?.intValue ?? -1
            ))
        case "download":
            guard let source = payload["url"] as? String,
                  let rawSourceURL = URL(string: source),
                  let sourceURL = RexExtensionResourceURL.userVisibleURL(
                      from: rawSourceURL
                  ),
                  let cefID = (payload["downloadID"] as? NSNumber)?.intValue else { return }
            let key = "\(tabID.uuidString):\(cefID)"
            let retryKey = downloadRetryKey(tabID: tabID, url: sourceURL)
            let pendingRetryID = pendingRetryIDs[retryKey]?.first
            let downloadID = downloadIDs[key] ?? pendingRetryID ?? UUID()
            downloadIDs[key] = downloadID
            activeDownloads[downloadID] = (tabID, cefID)
            if pendingRetryID != nil {
                pendingRetryIDs[retryKey]?.removeFirst()
                if pendingRetryIDs[retryKey]?.isEmpty == true {
                    pendingRetryIDs.removeValue(forKey: retryKey)
                }
            }
            let rawState = payload["state"] as? String ?? "pending"
            let state = BrowserDownloadTask.State(rawValue: rawState) ?? .pending
            let expected = (payload["expectedBytes"] as? NSNumber)?.int64Value
            let received = (payload["receivedBytes"] as? NSNumber)?.int64Value ?? 0
            let createdAt = (payload["createdAt"] as? NSNumber)?.doubleValue
            let fullPath = payload["fullPath"] as? String
            let destinationURL = fullPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            let interruptReason = (payload["interruptReason"] as? NSNumber)?.intValue ?? 0
            let task = BrowserDownloadTask(
                id: downloadID,
                sourceURL: sourceURL,
                suggestedFilename: payload["filename"] as? String ?? sourceURL.lastPathComponent,
                receivedBytes: received,
                expectedBytes: expected.map { $0 < 0 ? nil : $0 } ?? nil,
                state: state,
                createdAt: Date(timeIntervalSince1970: createdAt ?? Date.now.timeIntervalSince1970),
                destinationURL: destinationURL,
                errorDescription: state == .failed && interruptReason != 0
                    ? "下载中断（代码 \(interruptReason)）"
                    : nil
            )
            emit(.downloadUpdated(tabID: tabID, download: task))
            if [.completed, .failed, .cancelled].contains(state) {
                downloadIDs.removeValue(forKey: key)
                activeDownloads.removeValue(forKey: downloadID)
            }
        case "crashed":
            emit(.pageCrashed(tabID: tabID, reason: payload["message"] as? String ?? "Renderer terminated"))
        case "blockedResource":
            guard let categoryValue = payload["category"] as? String,
                  let category = BlockedResource.Category(rawValue: categoryValue),
                  let host = payload["host"] as? String,
                  !host.isEmpty else { return }
            let count = max(1, (payload["count"] as? NSNumber)?.intValue ?? 1)
            emit(.resourceBlocked(
                tabID: tabID,
                resource: BlockedResource(
                    id: UUID(),
                    category: category,
                    host: host,
                    count: count,
                    timestamp: .now
                )
            ))
        case "permissionRequest":
            guard let requestValue = payload["requestID"] as? String,
                  let requestID = UUID(uuidString: requestValue),
                  let rawKinds = payload["kinds"] as? [String] else { return }
            let kinds = rawKinds.compactMap(WebsitePermissionKind.init(rawValue:))
            guard !kinds.isEmpty else { return }
            emit(.permissionRequested(
                tabID: tabID,
                request: WebsitePermissionRequest(
                    id: requestID,
                    topLevelOrigin: RexExtensionResourceURL.userVisibleOrigin(
                        from: payload["topLevelOrigin"] as? String ?? ""
                    ),
                    requestingOrigin: RexExtensionResourceURL.userVisibleOrigin(
                        from: payload["requestingOrigin"] as? String ?? ""
                    ),
                    kinds: Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue },
                    requestedAt: .now
                )
            ))
        case "permissionDismissed":
            guard let requestValue = payload["requestID"] as? String,
                  let requestID = UUID(uuidString: requestValue) else { return }
            emit(.permissionRequestDismissed(tabID: tabID, requestID: requestID))
        case "closed":
            navigationStates.removeValue(forKey: tabID)
            emit(.pageClosed(tabID: tabID))
        case "loadError":
            let message = RexExtensionResourceURL.userVisibleString(
                from: payload["message"] as? String ?? "Navigation failed"
            )
            emit(.navigationFailed(
                tabID: tabID,
                url: (payload["url"] as? String).flatMap(Self.userVisibleURL(from:)),
                errorCode: (payload["code"] as? NSNumber)?.intValue,
                reason: message
            ))
        case "error":
            emit(.pageCrashed(
                tabID: tabID,
                reason: payload["message"] as? String ?? "Chromium page creation failed"
            ))
        default:
            break
        }
    }

    private func receiveExtensionSurfaceEvent(
        kind: String,
        runtimeTabID: String,
        payload: [String: Any]
    ) {
        guard kind == "popup",
              let sourceTabID = ChromiumExtensionPageSurface.sourceTabID(
                  fromRuntimeTabID: runtimeTabID
              ),
              let rawURL = payload["url"] as? String,
              let url = Self.userVisibleURL(from: rawURL),
              Self.isAllowedUserVisibleNavigation(url) else {
            return
        }
        emit(.popupRequested(
            tabID: sourceTabID,
            url: url,
            foreground: (payload["foreground"] as? Bool) ?? true
        ))
    }

    private func mutateNavigation(_ tabID: UUID, mutation: (inout NavigationState) -> Void) {
        var state = navigationStates[tabID] ?? NavigationState()
        mutation(&state)
        navigationStates[tabID] = state
        emit(.navigationChanged(tabID: tabID, state: state))
    }

    private func downloadRetryKey(tabID: UUID, url: URL) -> String {
        "\(tabID.uuidString):\(url.absoluteString)"
    }

    private func emit(_ event: BrowserEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private static func runtimeURL(for url: URL) -> URL? {
        if let extensionURL = RexExtensionResourceURL(rexURL: url) {
            return extensionURL.chromiumURL
        }
        guard ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }

    private static func userVisibleURL(from value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return RexExtensionResourceURL.userVisibleURL(from: url)
    }

    private static func userVisibleURL(from url: URL) -> URL? {
        userVisibleURL(from: url.absoluteString)
    }

    private static func isAllowedUserVisibleNavigation(_ url: URL) -> Bool {
        if RexExtensionResourceURL(rexURL: url) != nil {
            return true
        }
        return ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "")
    }
}

struct ChromiumBrowserSurface: NSViewRepresentable {
    let tab: BrowserTab
    let profile: BrowserProfile

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RexChromiumBrowserView {
        let initialURL = Self.runtimeURLString(for: tab.url)
        context.coordinator.lastURL = initialURL
        context.coordinator.lastMuted = tab.isMuted
        RexChromiumRuntime.shared.setAudioMuted(tab.isMuted, tabID: tab.id.uuidString)
        return RexChromiumRuntime.shared.browserView(
            forTabID: tab.id.uuidString,
            initialURL: initialURL,
            profileID: profile.id.uuidString,
            privateBrowsing: profile.isPrivate
        )
    }

    func updateNSView(_ nsView: RexChromiumBrowserView, context: Context) {
        nsView.isHidden = tab.lifecycle == .sleeping || tab.lifecycle == .archived
        if context.coordinator.lastMuted != tab.isMuted {
            context.coordinator.lastMuted = tab.isMuted
            RexChromiumRuntime.shared.setAudioMuted(tab.isMuted, tabID: tab.id.uuidString)
        }
        let nextURL = Self.runtimeURLString(for: tab.url)
        guard context.coordinator.lastURL != nextURL else { return }
        context.coordinator.lastURL = nextURL
        RexChromiumRuntime.shared.loadURLString(
            nextURL,
            tabID: tab.id.uuidString
        )
    }

    final class Coordinator {
        var lastURL: String?
        var lastMuted: Bool?
    }

    private static func runtimeURLString(for url: URL?) -> String {
        guard !BrowserStartPage.matches(url), let url else { return "about:blank" }
        return RexExtensionResourceURL(rexURL: url)?.chromiumURL.absoluteString
            ?? url.absoluteString
    }
}

/// Hosts an extension-owned page without registering it as a Rex browser tab.
/// Its runtime identifier carries only the source web-tab UUID so safe popup
/// requests can be mapped back into Rex's tab model.
struct ChromiumExtensionPageSurface: NSViewRepresentable {
    @EnvironmentObject private var store: BrowserStore
    let package: BrowserExtensionPackage
    let relativePath: String
    let surfaceID: String
    let onClose: () -> Void
    let onPreferredContentSizeChange: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RexChromiumBrowserView {
        context.coordinator.prepareRuntimeTabID(
            sourceTabID: store.sourceWebTab(forExtensionPackageID: package.id)?.id,
            surfaceID: surfaceID
        )
        let urlString = Self.chromiumPageURL(
            runtimeID: package.runtimeID,
            relativePath: relativePath
        )?.absoluteString ?? "about:blank"
        context.coordinator.lastURL = urlString
        let view = RexChromiumRuntime.shared.browserView(
            forTabID: context.coordinator.runtimeTabID,
            initialURL: urlString,
            profileID: store.profile.id.uuidString,
            privateBrowsing: store.profile.isPrivate
        )
        view.browserDidCloseHandler = onClose
        view.preferredSizeDidChangeHandler = onPreferredContentSizeChange
        return view
    }

    func updateNSView(_ nsView: RexChromiumBrowserView, context: Context) {
        nsView.browserDidCloseHandler = onClose
        nsView.preferredSizeDidChangeHandler = onPreferredContentSizeChange
        let urlString = Self.chromiumPageURL(
            runtimeID: package.runtimeID,
            relativePath: relativePath
        )?.absoluteString ?? "about:blank"
        guard context.coordinator.lastURL != urlString else { return }
        context.coordinator.lastURL = urlString
        RexChromiumRuntime.shared.loadURLString(
            urlString,
            tabID: context.coordinator.runtimeTabID
        )
    }

    static func dismantleNSView(
        _ nsView: RexChromiumBrowserView,
        coordinator: Coordinator
    ) {
        nsView.browserDidCloseHandler = nil
        nsView.preferredSizeDidChangeHandler = nil
        RexChromiumRuntime.shared.closeTabID(coordinator.runtimeTabID)
    }

    static func pageURL(runtimeID: String?, relativePath: String?) -> URL? {
        guard let runtimeID, let relativePath else { return nil }
        return RexExtensionResourceURL(
            runtimeID: runtimeID,
            relativePath: relativePath
        )?.rexURL
    }

    private static func chromiumPageURL(
        runtimeID: String?,
        relativePath: String?
    ) -> URL? {
        guard let runtimeID, let relativePath else { return nil }
        return RexExtensionResourceURL(
            runtimeID: runtimeID,
            relativePath: relativePath
        )?.chromiumURL
    }

    static func sourceTabID(fromRuntimeTabID runtimeTabID: String) -> UUID? {
        RexExtensionSurfaceRuntimeID(rawValue: runtimeTabID)?.sourceTabID
    }

    final class Coordinator {
        private(set) var runtimeTabID = ""
        var lastURL: String?

        func prepareRuntimeTabID(sourceTabID: UUID?, surfaceID: String) {
            guard runtimeTabID.isEmpty else { return }
            runtimeTabID = RexExtensionSurfaceRuntimeID(
                sourceTabID: sourceTabID,
                surfaceID: surfaceID
            ).rawValue
        }
    }
}

struct ChromiumDeveloperToolsSurface: NSViewRepresentable {
    let tabID: UUID
    let inspectX: Int?
    let inspectY: Int?
    let requestID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RexChromiumDevToolsView {
        RexChromiumRuntime.shared.developerToolsView(forTabID: tabID.uuidString)
    }

    func updateNSView(_ nsView: RexChromiumDevToolsView, context: Context) {
        guard context.coordinator.lastRequestID != requestID else { return }
        showDeveloperTools(context: context)
    }

    private func showDeveloperTools(context: Context) {
        context.coordinator.lastRequestID = requestID
        RexChromiumRuntime.shared.showDeveloperTools(
            forTabID: tabID.uuidString,
            inspectX: inspectX ?? -1,
            inspectY: inspectY ?? -1
        )
    }

    final class Coordinator {
        var lastRequestID: Int?
    }
}

@MainActor
final class RexAppDelegate: NSObject, NSApplicationDelegate {
    private var initializationError: Error?
    private var shouldTerminateAfterNormalEarlyExit = false
    private var isPreparingTermination = false
    private var isTerminationReady = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        installApplicationIcon()

        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let cacheRoot = support.appending(path: "Rex/Chromium", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            try RexChromiumRuntime.shared.start(
                withCacheRoot: cacheRoot,
                locale: "zh-CN",
                extensionPaths: BrowserExtensionsStore.shared.startupExtensionPaths
            )
            // Initial content-blocking state; window stores re-push on toggle changes.
            RexChromiumRuntime.shared.setContentBlockingEnabled(
                BrowserPreferences.shared.contentBlockingEnabled
            )
        } catch {
            if RexChromiumErrorIsNormalEarlyExit(error as NSError) {
                shouldTerminateAfterNormalEarlyExit = true
                NSLog("[Rex] Existing process handled launch; exiting relaunch process.")
                NSApplication.shared.terminate(nil)
            } else {
                initializationError = error
            }
        }
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        icon.isTemplate = false
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateAfterNormalEarlyExit {
            NSApplication.shared.terminate(nil)
            return
        }
        guard let initializationError else { return }
        let alert = NSAlert(error: initializationError)
        alert.informativeText += "\n请确认 CEF framework 和 Helper 已正确嵌入应用包。"
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RexApplicationLifecycle.beginTermination()
        if isTerminationReady { return .terminateNow }
        guard RexChromiumRuntime.shared.isReady else { return .terminateNow }
        guard !isPreparingTermination else { return .terminateCancel }
        isPreparingTermination = true
        RexChromiumRuntime.shared.prepare(forApplicationTermination: {
            MainActor.assumeIsolated {
                self.isTerminationReady = true
                sender.terminate(nil)
            }
        })
        // Let the current Cocoa event and CefScopedSendingEvent unwind. The
        // completion initiates a second termination after CEF is fully closed.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        RexApplicationLifecycle.beginTermination()
        RexChromiumRuntime.shared.shutdownAfterApplicationTermination()
    }
}
#endif
