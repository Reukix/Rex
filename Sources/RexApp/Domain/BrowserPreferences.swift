import Combine
import Foundation

enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case google
    case bing
    case duckDuckGo
    case brave
    case ecosia

    static let defaultsKey = "Rex.defaultSearchEngine"
    static let defaultValue: SearchEngine = .duckDuckGo

    var id: Self { self }

    var displayName: String {
        switch self {
        case .google: "Google"
        case .bing: "Microsoft Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        }
    }

    var shortDescription: String {
        switch self {
        case .google: "覆盖面广，适合通用网页搜索"
        case .bing: "Microsoft 提供的综合搜索服务"
        case .duckDuckGo: "默认减少搜索画像与跨站追踪"
        case .brave: "使用独立索引并强调隐私保护"
        case .ecosia: "将广告收益用于气候行动"
        }
    }

    var symbolName: String {
        switch self {
        case .google: "g.circle.fill"
        case .bing: "b.circle.fill"
        case .duckDuckGo: "shield.lefthalf.filled"
        case .brave: "shield.fill"
        case .ecosia: "leaf.fill"
        }
    }

    var homeURL: URL {
        switch self {
        case .google: URL(string: "https://www.google.com/")!
        case .bing: URL(string: "https://www.bing.com/")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .brave: URL(string: "https://search.brave.com/")!
        case .ecosia: URL(string: "https://www.ecosia.org/")!
        }
    }

    func searchURL(for query: String) -> URL? {
        let baseURL: String
        switch self {
        case .google: baseURL = "https://www.google.com/search"
        case .bing: baseURL = "https://www.bing.com/search"
        case .duckDuckGo: baseURL = "https://duckduckgo.com/"
        case .brave: baseURL = "https://search.brave.com/search"
        case .ecosia: baseURL = "https://www.ecosia.org/search"
        }
        var components = URLComponents(string: baseURL)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

enum BrowserAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultValue: BrowserAppearance = .system

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

@MainActor
final class BrowserPreferences: ObservableObject {
    static let shared = BrowserPreferences()

    @Published private(set) var searchEngine: SearchEngine
    @Published private(set) var appearance: BrowserAppearance
    @Published private(set) var restorePreviousSession: Bool
    @Published private(set) var defaultSidebarCollapsed: Bool
    @Published private(set) var showPerformanceMetrics: Bool
    @Published private(set) var automaticTabSleeping: Bool
    @Published private(set) var tabSleepDelayMinutes: Int
    @Published private(set) var blockThirdPartyCookies: Bool
    @Published private(set) var httpsUpgradeEnabled: Bool
    @Published private(set) var contentBlockingEnabled: Bool

    private let defaults: UserDefaults

    private enum Key {
        static let appearance = "Rex.appearance"
        static let restorePreviousSession = "Rex.restorePreviousSession"
        static let defaultSidebarCollapsed = "Rex.defaultSidebarCollapsed"
        static let showPerformanceMetrics = "Rex.showPerformanceMetrics"
        static let automaticTabSleeping = "Rex.automaticTabSleeping"
        static let tabSleepDelayMinutes = "Rex.tabSleepDelayMinutes"
        static let blockThirdPartyCookies = "Rex.blockThirdPartyCookies"
        static let httpsUpgradeEnabled = "Rex.httpsUpgradeEnabled"
        static let contentBlockingEnabled = "Rex.contentBlockingEnabled"

        static let all = [
            SearchEngine.defaultsKey,
            appearance,
            restorePreviousSession,
            defaultSidebarCollapsed,
            showPerformanceMetrics,
            automaticTabSleeping,
            tabSleepDelayMinutes,
            blockThirdPartyCookies,
            httpsUpgradeEnabled,
            contentBlockingEnabled
        ]
    }

    static let defaultRestorePreviousSession = true
    static let defaultSidebarCollapsedValue = false
    static let defaultShowPerformanceMetrics = true
    static let defaultAutomaticTabSleeping = true
    static let defaultTabSleepDelayMinutes = 30
    static let defaultBlockThirdPartyCookies = true
    static let defaultHTTPSUpgradeEnabled = true
    static let defaultContentBlockingEnabled = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searchEngine = defaults.string(forKey: SearchEngine.defaultsKey)
            .flatMap(SearchEngine.init(rawValue:))
            ?? .defaultValue
        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(BrowserAppearance.init(rawValue:))
            ?? .defaultValue
        restorePreviousSession = Self.bool(
            forKey: Key.restorePreviousSession,
            defaults: defaults,
            fallback: Self.defaultRestorePreviousSession
        )
        defaultSidebarCollapsed = Self.bool(
            forKey: Key.defaultSidebarCollapsed,
            defaults: defaults,
            fallback: Self.defaultSidebarCollapsedValue
        )
        showPerformanceMetrics = Self.bool(
            forKey: Key.showPerformanceMetrics,
            defaults: defaults,
            fallback: Self.defaultShowPerformanceMetrics
        )
        automaticTabSleeping = Self.bool(
            forKey: Key.automaticTabSleeping,
            defaults: defaults,
            fallback: Self.defaultAutomaticTabSleeping
        )
        tabSleepDelayMinutes = Self.clampedSleepDelay(
            defaults.object(forKey: Key.tabSleepDelayMinutes) as? Int
                ?? Self.defaultTabSleepDelayMinutes
        )
        blockThirdPartyCookies = Self.bool(
            forKey: Key.blockThirdPartyCookies,
            defaults: defaults,
            fallback: Self.defaultBlockThirdPartyCookies
        )
        httpsUpgradeEnabled = Self.bool(
            forKey: Key.httpsUpgradeEnabled,
            defaults: defaults,
            fallback: Self.defaultHTTPSUpgradeEnabled
        )
        contentBlockingEnabled = Self.bool(
            forKey: Key.contentBlockingEnabled,
            defaults: defaults,
            fallback: Self.defaultContentBlockingEnabled
        )
    }

    func setSearchEngine(_ searchEngine: SearchEngine) {
        guard self.searchEngine != searchEngine else { return }
        self.searchEngine = searchEngine
        defaults.set(searchEngine.rawValue, forKey: SearchEngine.defaultsKey)
    }

    func setAppearance(_ appearance: BrowserAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: Key.appearance)
    }

    func setRestorePreviousSession(_ enabled: Bool) {
        guard restorePreviousSession != enabled else { return }
        restorePreviousSession = enabled
        defaults.set(enabled, forKey: Key.restorePreviousSession)
    }

    func setDefaultSidebarCollapsed(_ collapsed: Bool) {
        guard defaultSidebarCollapsed != collapsed else { return }
        defaultSidebarCollapsed = collapsed
        defaults.set(collapsed, forKey: Key.defaultSidebarCollapsed)
    }

    func setShowPerformanceMetrics(_ visible: Bool) {
        guard showPerformanceMetrics != visible else { return }
        showPerformanceMetrics = visible
        defaults.set(visible, forKey: Key.showPerformanceMetrics)
    }

    func setAutomaticTabSleeping(_ enabled: Bool) {
        guard automaticTabSleeping != enabled else { return }
        automaticTabSleeping = enabled
        defaults.set(enabled, forKey: Key.automaticTabSleeping)
    }

    func setTabSleepDelayMinutes(_ minutes: Int) {
        let value = Self.clampedSleepDelay(minutes)
        guard tabSleepDelayMinutes != value else { return }
        tabSleepDelayMinutes = value
        defaults.set(value, forKey: Key.tabSleepDelayMinutes)
    }

    func setBlockThirdPartyCookies(_ enabled: Bool) {
        guard blockThirdPartyCookies != enabled else { return }
        blockThirdPartyCookies = enabled
        defaults.set(enabled, forKey: Key.blockThirdPartyCookies)
    }

    func setHTTPSUpgradeEnabled(_ enabled: Bool) {
        guard httpsUpgradeEnabled != enabled else { return }
        httpsUpgradeEnabled = enabled
        defaults.set(enabled, forKey: Key.httpsUpgradeEnabled)
    }

    func setContentBlockingEnabled(_ enabled: Bool) {
        guard contentBlockingEnabled != enabled else { return }
        contentBlockingEnabled = enabled
        defaults.set(enabled, forKey: Key.contentBlockingEnabled)
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }

        searchEngine = .defaultValue
        appearance = .defaultValue
        restorePreviousSession = Self.defaultRestorePreviousSession
        defaultSidebarCollapsed = Self.defaultSidebarCollapsedValue
        showPerformanceMetrics = Self.defaultShowPerformanceMetrics
        automaticTabSleeping = Self.defaultAutomaticTabSleeping
        tabSleepDelayMinutes = Self.defaultTabSleepDelayMinutes
        blockThirdPartyCookies = Self.defaultBlockThirdPartyCookies
        httpsUpgradeEnabled = Self.defaultHTTPSUpgradeEnabled
        contentBlockingEnabled = Self.defaultContentBlockingEnabled
    }

    private static func bool(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Bool
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func clampedSleepDelay(_ minutes: Int) -> Int {
        min(max(minutes, 1), 24 * 60)
    }
}


enum BrowserStartPage {
    static let url = URL(string: "about:rex-newtab")!
    static let title = "新标签页"

    static func matches(_ url: URL?) -> Bool {
        guard let url else { return true }
        switch url.absoluteString.lowercased() {
        case "about:rex-newtab", "about:newtab", "about:blank":
            return true
        default:
            return false
        }
    }
}
