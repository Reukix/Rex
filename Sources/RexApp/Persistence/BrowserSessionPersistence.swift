import Foundation

struct BrowserSessionSnapshot: Codable, Sendable, Equatable {
    static let schemaVersion = 3

    var schemaVersion: Int
    var windowID: UUID
    var spaces: [BrowserSpace]
    var groups: [TabGroup]
    var tabs: [BrowserTab]
    var currentSpaceID: UUID
    var selectedTabID: UUID
    var splitSession: SplitViewSession?
    var splitPaneStates: [SplitPaneState]
    var splitSessionsBySpace: [SplitViewSession]
    var savedSplitCompositions: [SavedSplitComposition]
    var savedAt: Date

    init(
        schemaVersion: Int,
        windowID: UUID = UUID(),
        spaces: [BrowserSpace],
        groups: [TabGroup] = [],
        tabs: [BrowserTab],
        currentSpaceID: UUID,
        selectedTabID: UUID,
        splitSession: SplitViewSession?,
        splitPaneStates: [SplitPaneState] = [],
        splitSessionsBySpace: [SplitViewSession] = [],
        savedSplitCompositions: [SavedSplitComposition] = [],
        savedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.windowID = windowID
        self.spaces = spaces
        self.groups = groups
        self.tabs = tabs
        self.currentSpaceID = currentSpaceID
        self.selectedTabID = selectedTabID
        self.splitSession = splitSession
        self.splitPaneStates = splitPaneStates
        self.splitSessionsBySpace = splitSessionsBySpace
        self.savedSplitCompositions = savedSplitCompositions
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, windowID, spaces, groups, tabs, currentSpaceID, selectedTabID
        case splitSession, splitPaneStates, splitSessionsBySpace, savedSplitCompositions, savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        windowID = try container.decodeIfPresent(UUID.self, forKey: .windowID) ?? UUID()
        spaces = try container.decode([BrowserSpace].self, forKey: .spaces)
        groups = try container.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
        tabs = try container.decode([BrowserTab].self, forKey: .tabs)
        currentSpaceID = try container.decode(UUID.self, forKey: .currentSpaceID)
        selectedTabID = try container.decode(UUID.self, forKey: .selectedTabID)
        splitSession = try container.decodeIfPresent(SplitViewSession.self, forKey: .splitSession)
        splitPaneStates = try container.decodeIfPresent([SplitPaneState].self, forKey: .splitPaneStates) ?? []
        splitSessionsBySpace = try container.decodeIfPresent([SplitViewSession].self, forKey: .splitSessionsBySpace) ?? []
        savedSplitCompositions = try container.decodeIfPresent([SavedSplitComposition].self, forKey: .savedSplitCompositions) ?? []
        savedAt = try container.decode(Date.self, forKey: .savedAt)
    }

    func validate() throws {
        guard schemaVersion <= Self.schemaVersion else {
            throw SessionPersistenceError.unsupportedSchema(schemaVersion)
        }
        guard let currentSpace = spaces.first(where: { $0.id == currentSpaceID }),
              tabs.contains(where: { $0.id == selectedTabID && $0.spaceID == currentSpace.id }) else {
            throw SessionPersistenceError.invalidSelection
        }
        if let splitSession {
            guard splitSession.spaceID == currentSpaceID,
                  splitSession.primaryTabID != splitSession.secondaryTabID,
                  tabs.contains(where: { $0.id == splitSession.primaryTabID && $0.spaceID == currentSpaceID && !$0.isArchived }),
                  tabs.contains(where: { $0.id == splitSession.secondaryTabID && $0.spaceID == currentSpaceID && !$0.isArchived }) else {
                throw SessionPersistenceError.invalidSplit
            }
            let paneIDs = Set(splitPaneStates.map(\.tabID))
            guard splitPaneStates.isEmpty || paneIDs == Set([splitSession.primaryTabID, splitSession.secondaryTabID]) else {
                throw SessionPersistenceError.invalidSplit
            }
        } else if !splitPaneStates.isEmpty {
            throw SessionPersistenceError.invalidSplit
        }
        guard splitSessionsBySpace.allSatisfy({ session in
            spaces.contains { $0.id == session.spaceID } &&
            tabs.contains { $0.id == session.primaryTabID && $0.spaceID == session.spaceID } &&
            tabs.contains { $0.id == session.secondaryTabID && $0.spaceID == session.spaceID } &&
            session.primaryTabID != session.secondaryTabID
        }) else {
            throw SessionPersistenceError.invalidSplit
        }
        guard savedSplitCompositions.allSatisfy({ composition in
            spaces.contains { $0.id == composition.spaceID } &&
            tabs.contains { $0.id == composition.primaryTabID && $0.spaceID == composition.spaceID } &&
            tabs.contains { $0.id == composition.secondaryTabID && $0.spaceID == composition.spaceID } &&
            composition.primaryTabID != composition.secondaryTabID
        }) else {
            throw SessionPersistenceError.invalidSplit
        }
    }
}

enum SessionPersistenceError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidSelection
    case invalidSplit

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "不支持的会话数据版本：\(version)"
        case .invalidSelection: "会话中的当前空间或标签不存在"
        case .invalidSplit: "会话中的分屏组合或页面状态无效"
        }
    }
}

actor BrowserSessionPersistence {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appending(path: "Rex/Session/session-v1.json")
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> BrowserSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let snapshot = try decoder.decode(BrowserSessionSnapshot.self, from: Data(contentsOf: fileURL))
        try snapshot.validate()
        return snapshot
    }

    func save(_ snapshot: BrowserSessionSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
#if os(macOS)
        // NSFileProtection is a mobile-platform policy. Combining it with an
        // atomic write can prevent Foundation from creating its temp file on macOS.
        let writingOptions: Data.WritingOptions = [.atomic]
#else
        let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
#endif
        try data.write(to: fileURL, options: writingOptions)
    }
}
