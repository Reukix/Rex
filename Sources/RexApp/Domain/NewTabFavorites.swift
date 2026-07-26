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

/// New-tab-page-only favorites. Independent from library bookmarks.
@MainActor
final class NewTabFavoritesStore {
    static let shared = NewTabFavoritesStore()

    private let fileManager: FileManager
    private let catalogURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("Rex", isDirectory: true)
        catalogURL = root.appendingPathComponent("newtab-favorites.json", isDirectory: false)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func load() -> [NewTabFavoriteSite] {
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

    func save(_ favorites: [NewTabFavoriteSite]) {
        do {
            var ordered = favorites
            for index in ordered.indices {
                ordered[index].order = index
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ordered)
            try data.write(to: catalogURL, options: .atomic)
        } catch {
            // Best-effort persistence; UI still keeps the in-memory list.
        }
    }
}
