import Foundation

enum TabLifecycle: String, Codable, Sendable, CaseIterable {
    case active, background, splitActive, sleeping, frozen, archived, crashed
}

/// v0.8.0 起 Rex 仅支持左右分屏。枚举保留 vertical 仅为解码旧会话数据；
/// 恢复时统一强制为 horizontal。
enum SplitOrientation: String, Codable, Sendable, CaseIterable {
    case horizontal
    case vertical

    var displayName: String {
        self == .horizontal ? "左右分屏" : "上下分屏"
    }
}

enum SplitPane: String, Codable, Sendable, CaseIterable {
    case primary, secondary
}

/// A single source of truth for the two pane frames and their divider.
struct SplitLayoutGeometry: Equatable, Sendable {
    let size: CGSize
    let ratio: Double
    let dividerWidth: CGFloat

    init(size: CGSize, ratio: Double, dividerWidth: CGFloat) {
        self.size = size
        self.ratio = min(max(ratio, 0.25), 0.75)
        self.dividerWidth = max(0, dividerWidth)
    }

    var isValid: Bool {
        size.width.isFinite && size.height.isFinite &&
            size.width > 0 && size.height > 0
    }

    var dividerCenterX: CGFloat {
        guard isValid else { return 0 }
        return size.width * CGFloat(ratio)
    }

    var dividerFrame: CGRect {
        guard isValid else { return .zero }
        let halfWidth = min(dividerWidth, size.width) / 2
        let minX = max(0, dividerCenterX - halfWidth)
        let maxX = min(size.width, dividerCenterX + halfWidth)
        return CGRect(x: minX, y: 0, width: max(0, maxX - minX), height: size.height)
    }

    func paneFrame(for pane: SplitPane) -> CGRect {
        guard isValid else { return .zero }
        switch pane {
        case .primary:
            return CGRect(x: 0, y: 0, width: dividerFrame.minX, height: size.height)
        case .secondary:
            return CGRect(
                x: dividerFrame.maxX,
                y: 0,
                width: max(0, size.width - dividerFrame.maxX),
                height: size.height
            )
        }
    }
}

enum PrivacyLevel: String, Codable, Sendable, CaseIterable {
    case standard, strict, custom

    var displayName: String {
        switch self {
        case .standard: "标准"
        case .strict: "严格"
        case .custom: "自定义"
        }
    }
}

enum PermissionDecision: String, Codable, Sendable, CaseIterable {
    case ask, allowOnce, allowAlways, blockAlways, revokeOnTabClose

    static let permissionCenterCases: [Self] = [.ask, .allowAlways, .blockAlways]

    var isPersistent: Bool {
        self == .allowAlways || self == .blockAlways
    }

    var displayName: String {
        switch self {
        case .ask: "每次询问"
        case .allowOnce: "仅本次允许"
        case .allowAlways: "始终允许"
        case .blockAlways: "始终阻止"
        case .revokeOnTabClose: "关闭标签页时撤销"
        }
    }
}

enum WebsitePermissionKind: String, Codable, Sendable, CaseIterable {
    case camera, microphone, screenCapture, location, notifications, clipboard
    case fileAccess, automaticDownloads, popups, autoplay, bluetooth, usb, midi

    var displayName: String {
        switch self {
        case .camera: "摄像头"
        case .microphone: "麦克风"
        case .screenCapture: "屏幕共享"
        case .location: "位置信息"
        case .notifications: "通知"
        case .clipboard: "剪贴板"
        case .fileAccess: "文件访问"
        case .automaticDownloads: "自动下载"
        case .popups: "弹出式窗口"
        case .autoplay: "自动播放"
        case .bluetooth: "蓝牙"
        case .usb: "USB 设备"
        case .midi: "MIDI 设备"
        }
    }

    var symbolName: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screenCapture: "rectangle.on.rectangle"
        case .location: "location.fill"
        case .notifications: "bell.fill"
        case .clipboard: "clipboard.fill"
        case .fileAccess: "folder.fill"
        case .automaticDownloads: "arrow.down.circle.fill"
        case .popups: "macwindow.on.rectangle"
        case .autoplay: "play.circle.fill"
        case .bluetooth: "wave.3.right"
        case .usb: "cable.connector"
        case .midi: "pianokeys"
        }
    }
}

struct PrivacyState: Codable, Hashable, Sendable {
    var isEnabled = true
    var level: PrivacyLevel = .standard
    var blockedCount = 0
    var fingerprintProtectionEnabled = true
    var httpsUpgradeEnabled = true
    var httpsUpgradeCount = 0
    var cleanedParameterCount = 0
    var resources: [BlockedResource] = []

    init(
        isEnabled: Bool = true,
        level: PrivacyLevel = .standard,
        blockedCount: Int = 0,
        fingerprintProtectionEnabled: Bool = true,
        httpsUpgradeEnabled: Bool = true,
        httpsUpgradeCount: Int = 0,
        cleanedParameterCount: Int = 0,
        resources: [BlockedResource] = []
    ) {
        self.isEnabled = isEnabled
        self.level = level
        self.blockedCount = max(0, blockedCount)
        self.fingerprintProtectionEnabled = fingerprintProtectionEnabled
        self.httpsUpgradeEnabled = httpsUpgradeEnabled
        self.httpsUpgradeCount = max(0, httpsUpgradeCount)
        self.cleanedParameterCount = max(0, cleanedParameterCount)
        self.resources = resources
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, level, blockedCount, fingerprintProtectionEnabled, httpsUpgradeEnabled
        case httpsUpgradeCount, cleanedParameterCount, resources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            level: try container.decodeIfPresent(PrivacyLevel.self, forKey: .level) ?? .standard,
            blockedCount: try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0,
            fingerprintProtectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .fingerprintProtectionEnabled) ?? true,
            httpsUpgradeEnabled: try container.decodeIfPresent(Bool.self, forKey: .httpsUpgradeEnabled) ?? true,
            httpsUpgradeCount: try container.decodeIfPresent(Int.self, forKey: .httpsUpgradeCount) ?? 0,
            cleanedParameterCount: try container.decodeIfPresent(Int.self, forKey: .cleanedParameterCount) ?? 0,
            resources: try container.decodeIfPresent([BlockedResource].self, forKey: .resources) ?? []
        )
    }
}

/// Safari-style website privacy exception: the user chooses protection once
/// for a host and every tab for that host receives the same policy.
struct SitePrivacyPolicy: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let profileID: UUID
    var host: String
    var protectionEnabled: Bool
    var level: PrivacyLevel
    var fingerprintProtectionEnabled: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        host: String,
        protectionEnabled: Bool = true,
        level: PrivacyLevel = .standard,
        fingerprintProtectionEnabled: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.host = host.lowercased()
        self.protectionEnabled = protectionEnabled
        self.level = level
        self.fingerprintProtectionEnabled = fingerprintProtectionEnabled
        self.updatedAt = updatedAt
    }
}

struct BrowserTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var url: URL?
    var title: String
    var faviconURL: URL?
    var spaceID: UUID
    var groupID: UUID?
    var isPinned: Bool
    var isFavorite: Bool
    var isArchived: Bool
    var isSleeping: Bool
    var isPlayingAudio: Bool
    var isMuted: Bool
    var isLoading: Bool
    var loadingProgress: Double
    var privacyState: PrivacyState
    var splitSessionID: UUID?
    var lifecycle: TabLifecycle
    var lastAccessedAt: Date

    init(
        id: UUID = UUID(),
        url: URL?,
        title: String,
        spaceID: UUID,
        groupID: UUID? = nil,
        isPinned: Bool = false,
        isFavorite: Bool = false,
        isPlayingAudio: Bool = false,
        blockedCount: Int = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = nil
        self.spaceID = spaceID
        self.groupID = groupID
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.isArchived = false
        self.isSleeping = false
        self.isPlayingAudio = isPlayingAudio
        self.isMuted = false
        self.isLoading = false
        self.loadingProgress = 1
        self.privacyState = PrivacyState(blockedCount: blockedCount)
        self.splitSessionID = nil
        self.lifecycle = .background
        self.lastAccessedAt = .now
    }
}

struct BrowserSpace: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var symbolName: String
    var tintHex: String
    var privacyLevel: PrivacyLevel
    var downloadDirectoryBookmark: Data?
}

struct TabGroup: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var spaceID: UUID
    var name: String
    var symbolName: String
    var isCollapsed: Bool
    var tabIDs: [UUID]
}

struct NavigationState: Codable, Hashable, Sendable {
    var url: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var loadingProgress = 0.0
    var zoomLevel = 1.0
    var isSecure = true
    /// Chromium's monotonically increasing identity for a main-frame navigation.
    /// Optional so session snapshots written before this field remain decodable.
    var navigationGeneration: UInt64?
}

struct SplitViewSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var primaryTabID: UUID
    var secondaryTabID: UUID
    var orientation: SplitOrientation
    var ratio: Double
    var focusedPane: SplitPane
    var spaceID: UUID
    var createdAt: Date
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        primaryTabID: UUID,
        secondaryTabID: UUID,
        orientation: SplitOrientation = .horizontal,
        ratio: Double = 0.56,
        focusedPane: SplitPane = .primary,
        spaceID: UUID,
        createdAt: Date = .now,
        lastOpenedAt: Date = .now
    ) {
        self.id = id
        self.primaryTabID = primaryTabID
        self.secondaryTabID = secondaryTabID
        self.orientation = orientation
        self.ratio = min(max(ratio, 0.25), 0.75)
        self.focusedPane = focusedPane
        self.spaceID = spaceID
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

struct SavedSplitComposition: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var spaceID: UUID
    var primaryTabID: UUID
    var secondaryTabID: UUID
    var orientation: SplitOrientation
    var ratio: Double
    var focusedPane: SplitPane
    var createdAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        spaceID: UUID,
        primaryTabID: UUID,
        secondaryTabID: UUID,
        orientation: SplitOrientation,
        ratio: Double,
        focusedPane: SplitPane,
        createdAt: Date = .now,
        lastUsedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.spaceID = spaceID
        self.primaryTabID = primaryTabID
        self.secondaryTabID = secondaryTabID
        self.orientation = orientation
        self.ratio = min(max(ratio, 0.25), 0.75)
        self.focusedPane = focusedPane
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

struct SplitPaneState: Codable, Hashable, Sendable {
    var pane: SplitPane
    var tabID: UUID
    var navigation: NavigationState
    var scrollPosition: Double
    var isMuted: Bool
}

struct BlockedResource: Identifiable, Codable, Hashable, Sendable {
    enum Category: String, Codable, Sendable {
        case advertisement, tracker, thirdPartyCookie, fingerprinting, suspiciousScript
        case trackingParameter, insecureRequest, redirect
    }

    let id: UUID
    var category: Category
    var host: String
    var count: Int
    var timestamp: Date
}

struct PrivacyReport: Codable, Hashable, Sendable {
    var siteHost: String
    var adsBlocked: Int
    var trackersBlocked: Int
    var thirdPartyCookiesBlocked: Int
    var httpsUpgrades: Int
    var cleanedParameters: Int
    var suspiciousScriptsBlocked: Int
    var resources: [BlockedResource]

    var totalBlocked: Int {
        adsBlocked + trackersBlocked + thirdPartyCookiesBlocked + suspiciousScriptsBlocked
    }
}

struct WebsitePermission: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var profileID: UUID
    var topLevelOrigin: String
    var requestingOrigin: String
    var kind: WebsitePermissionKind
    var decision: PermissionDecision
    var tabID: UUID?
    var expiresAt: Date?
    var updatedAt: Date
}

struct WebsitePermissionRequest: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var topLevelOrigin: String
    var requestingOrigin: String
    var kinds: [WebsitePermissionKind]
    var requestedAt: Date
}

struct WebsitePermissionPrompt: Identifiable, Hashable, Sendable {
    var tabID: UUID
    var request: WebsitePermissionRequest

    var id: UUID { request.id }
}

struct BrowserProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var isPrivate: Bool
    var storageContainerID: String
    var createdAt: Date

    static let standard = BrowserProfile(
        id: UUID(uuidString: "B4B2C77B-71E8-47A4-A87C-6D3C3222BE2C")!,
        name: "默认",
        isPrivate: false,
        storageContainerID: "Default",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    static func privateWindow(id: UUID = UUID()) -> BrowserProfile {
        BrowserProfile(
            id: id,
            name: "隐私",
            isPrivate: true,
            storageContainerID: "Private-\(id.uuidString)",
            createdAt: .now
        )
    }
}

struct ArchivedTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var originalTabID: UUID
    var url: URL
    var title: String
    var spaceID: UUID
    var groupID: UUID?
    var lastAccessedAt: Date
    var scrollPosition: Double
    var zoomLevel: Double
}

struct BrowserDownloadTask: Identifiable, Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case pending, downloading, scanning, completed, failed, cancelled
    }

    let id: UUID
    var sourceURL: URL
    var suggestedFilename: String
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var state: State
    var createdAt: Date
    var destinationURL: URL? = nil
    var errorDescription: String? = nil

    var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }

    var canCancel: Bool {
        state == .pending || state == .downloading || state == .scanning
    }

    var canRetry: Bool {
        state == .failed || state == .cancelled
    }

    var canOpen: Bool {
        state == .completed && destinationURL != nil
    }
}

struct BrowserHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var title: String
    var visitedAt: Date
    var tabID: UUID?
    var spaceID: UUID?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        visitedAt: Date = .now,
        tabID: UUID? = nil,
        spaceID: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.tabID = tabID
        self.spaceID = spaceID
    }
}

struct BrowserBookmark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var folderName: String?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        folderName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.folderName = folderName
    }
}

struct BrowserWindowSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var lastOpenedAt: Date

    init(id: UUID, lastOpenedAt: Date = .now) {
        self.id = id
        self.lastOpenedAt = lastOpenedAt
    }
}
