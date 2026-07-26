import Combine
import Foundation

struct NewTabFavoriteSite: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var title: String
    var createdAt: Date
    var order: Int

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        createdAt: Date = .now,
        order: Int = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.order = order
    }
}

struct NewTabFavoriteDraft: Equatable, Sendable {
    let title: String
    let url: URL

    init?(title: String, urlText: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let normalizedURL = Self.normalizedURL(from: urlText) else {
            return nil
        }
        self.title = trimmedTitle
        url = normalizedURL
    }

    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hasExplicitScheme = trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        let candidate = hasExplicitScheme ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let rawScheme = components.scheme,
              let rawHost = components.host else {
            return nil
        }

        let scheme = rawScheme.lowercased()
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["http", "https"].contains(scheme),
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }

    static func normalizedURL(_ url: URL) -> URL? {
        normalizedURL(from: url.absoluteString)
    }
}

/// New-tab-page-only favorites. Independent from library bookmarks.
@MainActor
final class NewTabFavoritesStore: ObservableObject {
    static let shared = NewTabFavoritesStore()

    @Published private(set) var favorites: [NewTabFavoriteSite]

    private let fileManager: FileManager
    private let catalogURL: URL

    init(fileManager: FileManager = .default, catalogURL: URL? = nil) {
        self.fileManager = fileManager
        let resolvedCatalogURL: URL
        if let catalogURL {
            resolvedCatalogURL = catalogURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            resolvedCatalogURL = support
                .appendingPathComponent("Rex", isDirectory: true)
                .appendingPathComponent("newtab-favorites.json", isDirectory: false)
        }
        self.catalogURL = resolvedCatalogURL
        let root = resolvedCatalogURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        favorites = Self.load(from: resolvedCatalogURL, fileManager: fileManager)
    }

    func load() -> [NewTabFavoriteSite] {
        favorites
    }

    @discardableResult
    func add(_ favorite: NewTabFavoriteSite) throws -> Bool {
        let normalizedURL = NewTabFavoriteDraft.normalizedURL(favorite.url) ?? favorite.url
        guard !favorites.contains(where: {
            (NewTabFavoriteDraft.normalizedURL($0.url) ?? $0.url) == normalizedURL
        }) else {
            return false
        }

        var normalizedFavorite = favorite
        normalizedFavorite.url = normalizedURL
        try commit([normalizedFavorite] + favorites)
        return true
    }

    func remove(id: UUID) throws {
        try commit(favorites.filter { $0.id != id })
    }

    func remove(url: URL) throws {
        let normalizedURL = NewTabFavoriteDraft.normalizedURL(url) ?? url
        try commit(favorites.filter {
            (NewTabFavoriteDraft.normalizedURL($0.url) ?? $0.url) != normalizedURL
        })
    }

    private static func load(from catalogURL: URL, fileManager: FileManager) -> [NewTabFavoriteSite] {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: catalogURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([NewTabFavoriteSite].self, from: data)
            return decoded.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.createdAt > $1.createdAt
            }
        } catch {
            return []
        }
    }

    private func commit(_ candidates: [NewTabFavoriteSite]) throws {
        var ordered = candidates
        for index in ordered.indices {
            ordered[index].order = index
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ordered)
        try data.write(to: catalogURL, options: .atomic)
        favorites = ordered
    }
}
