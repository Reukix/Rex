import Foundation

enum BrowserExtensionCatalogCategory: String, CaseIterable, Identifiable, Sendable {
    case privacy
    case productivity
    case accessibility
    case developerTools

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .privacy: "隐私与安全"
        case .productivity: "效率工具"
        case .accessibility: "阅读与辅助"
        case .developerTools: "开发者工具"
        }
    }

    var symbolName: String {
        switch self {
        case .privacy: "lock.shield"
        case .productivity: "bolt"
        case .accessibility: "textformat.size"
        case .developerTools: "hammer"
        }
    }
}

enum BrowserExtensionCatalogFilter: String, CaseIterable, Identifiable, Sendable {
    case recommended
    case all
    case privacy
    case productivity
    case accessibility
    case developerTools

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recommended: "推荐"
        case .all: "全部"
        case .privacy: "隐私"
        case .productivity: "效率"
        case .accessibility: "阅读"
        case .developerTools: "开发"
        }
    }

    var category: BrowserExtensionCatalogCategory? {
        switch self {
        case .recommended, .all: nil
        case .privacy: .privacy
        case .productivity: .productivity
        case .accessibility: .accessibility
        case .developerTools: .developerTools
        }
    }
}

struct BrowserExtensionCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let category: BrowserExtensionCatalogCategory
    let isRecommended: Bool

    var officialURL: URL {
        BrowserExtensionCatalog.chromeWebStoreDetailURL(extensionID: id)
    }
}

enum BrowserExtensionCatalog {
    static let sourceName = "Chrome Web Store"
    static let sourceHost = "chromewebstore.google.com"

    // Names and identifiers point to public Chrome Web Store listings. Summaries
    // are Rex-authored descriptions; no store assets or listing copy are bundled.
    static let items: [BrowserExtensionCatalogItem] = [
        BrowserExtensionCatalogItem(
            id: "ddkjiahejlhfcafbddmgiahcphecmpfh",
            name: "uBlock Origin Lite",
            summary: "基于 Manifest V3 的内容过滤工具，适合希望减少页面干扰的用户。",
            category: .privacy,
            isRecommended: true
        ),
        BrowserExtensionCatalogItem(
            id: "nngceckbapebfimnlniiiahkandclblb",
            name: "Bitwarden Password Manager",
            summary: "跨设备密码库与表单填充工具。",
            category: .productivity,
            isRecommended: true
        ),
        BrowserExtensionCatalogItem(
            id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
            name: "1Password",
            summary: "面向个人与团队的密码、通行密钥和身份信息管理工具。",
            category: .productivity,
            isRecommended: false
        ),
        BrowserExtensionCatalogItem(
            id: "eimadpbcbfnmbkopoojfekhnkhdbieeh",
            name: "Dark Reader",
            summary: "为网页提供可调节的深色阅读外观。",
            category: .accessibility,
            isRecommended: true
        ),
        BrowserExtensionCatalogItem(
            id: "aapbdbdomjkkjkaonfhkkikfgjllcleb",
            name: "Google Translate",
            summary: "快速翻译选中文本或当前页面内容。",
            category: .accessibility,
            isRecommended: false
        ),
        BrowserExtensionCatalogItem(
            id: "fmkadmapgofadopljbjfkapdkoienihi",
            name: "React Developer Tools",
            summary: "检查 React 组件树、属性和性能信息。",
            category: .developerTools,
            isRecommended: true
        )
    ]

    static func filteredItems(
        query: String,
        filter: BrowserExtensionCatalogFilter
    ) -> [BrowserExtensionCatalogItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .recommended:
                matchesFilter = item.isRecommended
            case .all:
                matchesFilter = true
            default:
                matchesFilter = item.category == filter.category
            }
            guard matchesFilter else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(trimmedQuery)
                || item.summary.localizedCaseInsensitiveContains(trimmedQuery)
                || item.category.displayName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    static func chromeWebStoreDetailURL(extensionID: String) -> URL {
        precondition(isValidChromeExtensionID(extensionID))
        return URL(string: "https://\(sourceHost)/detail/\(extensionID)")!
    }

    static func chromeWebStoreSearchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(string: "https://\(sourceHost)/") }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://\(sourceHost)/search/\(encoded)")
    }

    static func extensionID(fromWebStoreInput input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidChromeExtensionID(trimmed) {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == sourceHost,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url.pathComponents
            .reversed()
            .first(where: isValidChromeExtensionID)
    }

    static func isValidChromeExtensionID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { "a"..."p" ~= $0 }
    }
}
