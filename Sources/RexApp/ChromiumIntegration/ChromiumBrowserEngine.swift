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
            guard ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
                throw BrowserEngineError.unsupportedScheme
            }
            runtime.loadURLString(url.absoluteString, tabID: tabID.uuidString)
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

        guard let tabString = payload["tabID"] as? String,
              let tabID = UUID(uuidString: tabString) else { return }

        switch kind {
        case "created":
            emit(.pageCreated(tabID: tabID))
        case "address":
            mutateNavigation(tabID) { state in
                if let value = payload["url"] as? String { state.url = URL(string: value) }
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
            emit(.siteSecurityChanged(tabID: tabID, info: info))
        case "title":
            emit(.titleChanged(tabID: tabID, title: payload["title"] as? String ?? ""))
        case "favicon":
            let rawURL = payload["url"] as? String
            let url = rawURL.flatMap(URL.init(string:))
            let imageData = (payload["imageData"] as? Data)
                ?? (payload["imageData"] as? NSData).map { Data(referencing: $0) }
            emit(.faviconChanged(tabID: tabID, url: url, imageData: imageData))
        case "audio":
            emit(.audioStateChanged(tabID: tabID, isPlaying: payload["isPlaying"] as? Bool ?? false))
        case "mediaAccess":
            emit(.mediaAccessChanged(tabID: tabID, isActive: payload["isActive"] as? Bool ?? false))
        case "popup":
            guard let rawURL = payload["url"] as? String,
                  let url = URL(string: rawURL),
                  ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { return }
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
                  let sourceURL = URL(string: source),
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
                    id: UUID(), category: category, host: host, count: count, timestamp: .now
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
                    topLevelOrigin: payload["topLevelOrigin"] as? String ?? "",
                    requestingOrigin: payload["requestingOrigin"] as? String ?? "",
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
            let message = payload["message"] as? String ?? "Navigation failed"
            emit(.navigationFailed(
                tabID: tabID,
                url: (payload["url"] as? String).flatMap(URL.init(string:)),
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
}

struct ChromiumBrowserSurface: NSViewRepresentable {
    let tab: BrowserTab
    let profile: BrowserProfile

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RexChromiumBrowserView {
        let initialURL = BrowserStartPage.matches(tab.url)
            ? "about:blank"
            : (tab.url?.absoluteString ?? "about:blank")
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
        let nextURL = BrowserStartPage.matches(tab.url)
            ? "about:blank"
            : (tab.url?.absoluteString ?? "about:blank")
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
            try RexChromiumRuntime.shared.start(withCacheRoot: cacheRoot, locale: "zh-CN")
            // Initial content-blocking state; window stores re-push on toggle changes.
            RexChromiumRuntime.shared.setContentBlockingEnabled(
                BrowserPreferences.shared.contentBlockingEnabled
            )
        } catch {
            initializationError = error
        }
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        icon.isTemplate = false
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let initializationError else { return }
        let alert = NSAlert(error: initializationError)
        alert.informativeText += "\n请确认 CEF framework 和 Helper 已正确嵌入应用包。"
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        RexChromiumRuntime.shared.shutdownAfterApplicationTermination()
    }
}
#endif
