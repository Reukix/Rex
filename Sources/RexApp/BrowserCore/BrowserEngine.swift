import Foundation

struct PrivacyURLPolicyResult: Equatable, Sendable {
    let url: URL
    let didUpgradeHTTPS: Bool
    let removedParameterCount: Int

    var didChange: Bool {
        didUpgradeHTTPS || removedParameterCount > 0
    }
}

enum PrivacyURLPolicy {
    private static let trackingParameters: Set<String> = [
        "_hsenc", "_hsmi", "dclid", "fbclid", "gclid", "igshid", "mc_cid", "mc_eid",
        "msclkid", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "twclid", "utm_campaign",
        "utm_content", "utm_id", "utm_medium", "utm_source", "utm_term", "vero_id", "wickedid", "yclid"
    ]

    static func apply(
        to url: URL,
        isEnabled: Bool = true,
        upgradeHTTPS: Bool = true
    ) -> PrivacyURLPolicyResult {
        guard isEnabled, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return PrivacyURLPolicyResult(url: url, didUpgradeHTTPS: false, removedParameterCount: 0)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let didUpgradeHTTPS = upgradeHTTPS && scheme == "http" && shouldUpgrade(host: components?.host)
        if didUpgradeHTTPS { components?.scheme = "https" }

        var removedParameterCount = 0
        if let queryItems = components?.queryItems {
            let retainedItems = queryItems.filter { item in
                let name = item.name.lowercased()
                let shouldRemove = trackingParameters.contains(name)
                if shouldRemove { removedParameterCount += 1 }
                return !shouldRemove
            }
            components?.queryItems = retainedItems.isEmpty ? nil : retainedItems
        }

        let sanitizedURL = components?.url ?? url
        return PrivacyURLPolicyResult(
            url: sanitizedURL,
            didUpgradeHTTPS: didUpgradeHTTPS,
            removedParameterCount: removedParameterCount
        )
    }

    private static func shouldUpgrade(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return false
        }
        if host.contains(":") { return false } // IPv6 literal.
        if host.split(separator: ".").count == 4,
           host.split(separator: ".").allSatisfy({ Int($0) != nil }) {
            return false
        }
        return true
    }
}

enum BrowserCommand: Sendable, Equatable {
    case createPage(tabID: UUID, profile: BrowserProfile)
    case destroyPage(tabID: UUID)
    case loadURL(tabID: UUID, url: URL)
    case goBack(tabID: UUID)
    case goForward(tabID: UUID)
    case reload(tabID: UUID)
    case reloadIgnoringCache(tabID: UUID)
    case stop(tabID: UUID)
    case setZoom(tabID: UUID, level: Double)
    case printPage(tabID: UUID)
    case setAudioMuted(tabID: UUID, muted: Bool)
    /// Push Brave-style shield policy into the CEF privacy engine.
    case setPrivacyPolicy(
        tabID: UUID,
        enabled: Bool,
        level: PrivacyLevel,
        fingerprintProtection: Bool,
        blockThirdPartyCookies: Bool
    )
    /// Engine-global ad/tracker content blocking (bound to the Settings toggle).
    case setContentBlocking(enabled: Bool)
    /// Reconcile Chromium's live extensions without conflating disable and removal.
    /// `enabledPaths` and `forceReloadPaths` must be subsets of `managedPaths`;
    /// only `removedPaths` authorizes an uninstall.
    case reloadExtensionRules(
        managedPaths: [String],
        enabledPaths: [String],
        removedPaths: [String],
        forceReloadPaths: [String]
    )
    case find(tabID: UUID, query: String, forward: Bool, findNext: Bool)
    case stopFinding(tabID: UUID)
    case openDeveloperTools(tabID: UUID)
    case openDeveloperToolsConsole(tabID: UUID)
    case openDeveloperToolsInspect(tabID: UUID)
    case respondToPermission(requestID: UUID, decision: PermissionDecision)
    case cancelDownload(downloadID: UUID)
    case retryDownload(downloadID: UUID, tabID: UUID, url: URL)
    case setDownloadDirectory(tabID: UUID, directoryURL: URL?)
    case recoverCrashedPage(tabID: UUID)
    case exitFullscreen(tabID: UUID)
    case setPagePriority(tabID: UUID, isFocused: Bool)
    case setPageSuspended(tabID: UUID, isSuspended: Bool)
}

enum BrowserEvent: Sendable, Equatable {
    case pageCreated(tabID: UUID)
    case pageFocused(tabID: UUID)
    case navigationChanged(tabID: UUID, state: NavigationState)
    case titleChanged(tabID: UUID, title: String)
    case faviconChanged(tabID: UUID, url: URL?, imageData: Data?)
    case audioStateChanged(tabID: UUID, isPlaying: Bool)
    case mediaAccessChanged(tabID: UUID, isActive: Bool)
    case popupRequested(tabID: UUID, url: URL, foreground: Bool)
    case splitLinkRequested(tabID: UUID, url: URL)
    case contextSearchRequested(tabID: UUID, text: String)
    case developerToolsRequested(tabID: UUID, inspectX: Int, inspectY: Int)
    case siteSecurityChanged(tabID: UUID, info: SiteSecurityInfo)
    case privacyStateChanged(tabID: UUID, state: PrivacyState)
    case resourceBlocked(tabID: UUID, resource: BlockedResource)
    case permissionRequested(tabID: UUID, request: WebsitePermissionRequest)
    case permissionRequestDismissed(tabID: UUID, requestID: UUID)
    case downloadUpdated(tabID: UUID, download: BrowserDownloadTask)
    case navigationFailed(tabID: UUID, url: URL?, errorCode: Int?, reason: String)
    case pageCrashed(tabID: UUID, reason: String)
    case pageFullscreenChanged(tabID: UUID, isFullscreen: Bool)
    case pageClosed(tabID: UUID)
}

enum BrowserEngineError: LocalizedError, Sendable {
    case unsupportedScheme
    case unknownTab
    case invalidPayload
    case chromiumUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: "不支持或不安全的 URL 协议"
        case .unknownTab: "页面实例不存在"
        case .invalidPayload: "浏览器命令参数无效"
        case .chromiumUnavailable: "Chromium 运行时尚未安装"
        }
    }
}

protocol BrowserEngine: Sendable {
    func execute(_ command: BrowserCommand) async throws
    func eventStream() async -> AsyncStream<BrowserEvent>
    func extensionRuntimeConfiguration(
        extensionID: String
    ) async throws -> BrowserExtensionRuntimeConfiguration
    func updateExtensionRuntimeConfiguration(
        extensionID: String,
        update: BrowserExtensionRuntimeConfigurationUpdate
    ) async throws -> BrowserExtensionRuntimeConfiguration
}

extension BrowserEngine {
    func extensionRuntimeConfiguration(
        extensionID: String
    ) async throws -> BrowserExtensionRuntimeConfiguration {
        throw BrowserEngineError.chromiumUnavailable
    }

    func updateExtensionRuntimeConfiguration(
        extensionID: String,
        update: BrowserExtensionRuntimeConfigurationUpdate
    ) async throws -> BrowserExtensionRuntimeConfiguration {
        throw BrowserEngineError.chromiumUnavailable
    }
}

@MainActor
enum BrowserEngineFactory {
    private static let sharedEngine: any BrowserEngine = {
#if REX_CEF
        ChromiumBrowserEngine()
#else
        PrototypeBrowserEngine()
#endif
    }()

    static func makeDefault() -> any BrowserEngine {
        sharedEngine
    }
}

/// Product-development engine used before the CEF adapter lands. It validates the
/// public contract but does not claim to render with Chromium.
actor PrototypeBrowserEngine: BrowserEngine {
    private var knownTabs = Set<UUID>()
    private var continuations: [UUID: AsyncStream<BrowserEvent>.Continuation] = [:]

    func eventStream() -> AsyncStream<BrowserEvent> {
        let subscriptionID = UUID()
        let pair = AsyncStream<BrowserEvent>.makeStream()
        continuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(subscriptionID) }
        }
        return pair.stream
    }

    func execute(_ command: BrowserCommand) throws {
        switch command {
        case let .createPage(tabID, _):
            knownTabs.insert(tabID)
            emit(.pageCreated(tabID: tabID))
        case let .destroyPage(tabID):
            guard knownTabs.remove(tabID) != nil else { throw BrowserEngineError.unknownTab }
            emit(.pageClosed(tabID: tabID))
        case let .loadURL(tabID, url):
            try requireKnown(tabID)
            let isExtensionResource = RexExtensionResourceURL(rexURL: url) != nil
            guard RexExtensionsPage.matches(url) || isExtensionResource
                    || ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "")
            else {
                throw BrowserEngineError.unsupportedScheme
            }
        case let .setZoom(tabID, level):
            try requireKnown(tabID)
            guard 0.25...5 ~= level else { throw BrowserEngineError.invalidPayload }
        case let .printPage(tabID), let .setAudioMuted(tabID, _):
            try requireKnown(tabID)
        case let .setPrivacyPolicy(tabID, _, _, _, _):
            try requireKnown(tabID)
        case .setContentBlocking:
            break
        case .reloadExtensionRules:
            break
        case let .find(tabID, query, _, _):
            try requireKnown(tabID)
            guard query.utf8.count <= 4_096 else { throw BrowserEngineError.invalidPayload }
        case let .goBack(tabID), let .goForward(tabID), let .reload(tabID),
             let .reloadIgnoringCache(tabID), let .stop(tabID),
             let .stopFinding(tabID),
             let .openDeveloperTools(tabID), let .openDeveloperToolsConsole(tabID),
             let .openDeveloperToolsInspect(tabID), let .recoverCrashedPage(tabID),
             let .exitFullscreen(tabID),
             let .setPagePriority(tabID, _), let .setPageSuspended(tabID, _):
            try requireKnown(tabID)
        case .respondToPermission:
            break
        case .cancelDownload:
            break
        case let .retryDownload(_, tabID, url):
            try requireKnown(tabID)
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw BrowserEngineError.unsupportedScheme
            }
        case let .setDownloadDirectory(tabID, directoryURL):
            try requireKnown(tabID)
            guard directoryURL == nil || directoryURL?.isFileURL == true else {
                throw BrowserEngineError.invalidPayload
            }
        }
    }

    private func requireKnown(_ tabID: UUID) throws {
        guard knownTabs.contains(tabID) else { throw BrowserEngineError.unknownTab }
    }

    private func emit(_ event: BrowserEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
