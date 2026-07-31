import Foundation
import SQLite3

private final class SQLiteConnection: @unchecked Sendable {
    let rawValue: OpaquePointer

    init(_ rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    deinit {
        sqlite3_close(rawValue)
    }
}

enum BrowserDatabaseError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case invalidRow

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Rex 数据库打开失败：\(message)"
        case let .statementFailed(message): "Rex 数据库操作失败：\(message)"
        case .invalidRow: "Rex 数据库记录格式无效"
        }
    }
}

/// SQLite-backed storage for window sessions and the small browser libraries
/// that need querying independently from the visible tab list.
actor BrowserSQLitePersistence {
    private static let databaseSchemaVersion = 4
    private static let legacyMigrationKey = "legacy_session_v1_migrated"

    private let databaseURL: URL
    private let legacyPersistence: BrowserSessionPersistence?
    private let migrationOwnerID = UUID()
    private var database: SQLiteConnection?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        databaseURL: URL? = nil,
        legacyPersistence: BrowserSessionPersistence? = BrowserSessionPersistence()
    ) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.databaseURL = support.appending(path: "Rex/Browser.sqlite")
        }
        self.legacyPersistence = legacyPersistence
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        // Preserve Date's full Codable precision while accepting payloads from the
        // original ISO 8601 encoder used by early SQLite snapshots.
        encoder.dateEncodingStrategy = .deferredToDate
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let secondsSinceReferenceDate = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: secondsSinceReferenceDate)
            }

            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            let secondsFormatter = ISO8601DateFormatter()
            secondsFormatter.formatOptions = [.withInternetDateTime]
            guard let date = secondsFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "无效的 ISO 8601 日期：\(value)"
                )
            }
            return date
        }
    }

    func load(windowID: UUID) async throws -> BrowserSessionSnapshot? {
        try openIfNeeded()
        let data: Data? = try {
            let statement = try prepare("SELECT snapshot FROM window_sessions WHERE window_id = ? LIMIT 1")
            defer { sqlite3_finalize(statement) }
            try bind(windowID.uuidString, to: statement, at: 1)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let data = blob(from: statement, column: 0) else {
                    throw BrowserDatabaseError.invalidRow
                }
                return data
            case SQLITE_DONE:
                return nil
            default:
                throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
            }
        }()
        if let data {
            let snapshot = try decoder.decode(BrowserSessionSnapshot.self, from: data)
            try snapshot.validate()
            guard snapshot.windowID == windowID else { throw BrowserDatabaseError.invalidRow }
            return snapshot
        }
        return try await migrateLegacySessionIfNeeded(to: windowID)
    }

    func loadAllWindows() throws -> [BrowserWindowSession] {
        try openIfNeeded()
        let statement = try prepare("SELECT window_id, last_opened_at FROM window_sessions ORDER BY last_opened_at DESC")
        defer { sqlite3_finalize(statement) }
        var result: [BrowserWindowSession] = []
        while true {
            let resultCode = sqlite3_step(statement)
            if resultCode == SQLITE_DONE { break }
            guard resultCode == SQLITE_ROW else {
                throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
            }
            guard let rawID = text(from: statement, column: 0),
                  let id = UUID(uuidString: rawID) else { throw BrowserDatabaseError.invalidRow }
            result.append(BrowserWindowSession(id: id, lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))))
        }
        return result
    }

    func save(_ snapshot: BrowserSessionSnapshot) throws {
        try openIfNeeded()
        try snapshot.validate()
        try writeSnapshot(snapshot)
    }

    private func writeSnapshot(_ snapshot: BrowserSessionSnapshot) throws {
        let statement = try prepare("""
            INSERT INTO window_sessions(window_id, last_opened_at, snapshot)
            VALUES(?, ?, ?)
            ON CONFLICT(window_id) DO UPDATE SET
                last_opened_at = excluded.last_opened_at,
                snapshot = excluded.snapshot
            """)
        defer { sqlite3_finalize(statement) }
        try bind(snapshot.windowID.uuidString, to: statement, at: 1)
        try bind(snapshot.savedAt.timeIntervalSince1970, to: statement, at: 2)
        try bind(try encoder.encode(snapshot), to: statement, at: 3)
        try step(statement)
    }

    func deleteWindow(windowID: UUID) throws {
        try openIfNeeded()
        let statement = try prepare("DELETE FROM window_sessions WHERE window_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(windowID.uuidString, to: statement, at: 1)
        try step(statement)
    }

    func history(limit: Int = 200) throws -> [BrowserHistoryEntry] {
        try openIfNeeded()
        let statement = try prepare("SELECT payload FROM history ORDER BY visited_at DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try bind(Int64(max(1, min(limit, 10_000))), to: statement, at: 1)
        return try decodeRows(statement, as: BrowserHistoryEntry.self)
    }

    func addHistory(_ entry: BrowserHistoryEntry) throws {
        try openIfNeeded()
        let statement = try prepare("INSERT OR REPLACE INTO history(entry_id, visited_at, payload) VALUES(?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(entry.id.uuidString, to: statement, at: 1)
        try bind(entry.visitedAt.timeIntervalSince1970, to: statement, at: 2)
        try bind(try encoder.encode(entry), to: statement, at: 3)
        try step(statement)
    }

    func removeHistory(id: UUID) throws {
        try openIfNeeded()
        let statement = try prepare("DELETE FROM history WHERE entry_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        try step(statement)
    }

    func removeHistory(visitedAtOrAfter cutoff: Date?) throws {
        try openIfNeeded()
        guard let cutoff else {
            let statement = try prepare("DELETE FROM history")
            defer { sqlite3_finalize(statement) }
            try step(statement)
            return
        }

        let statement = try prepare("DELETE FROM history WHERE visited_at >= ?")
        defer { sqlite3_finalize(statement) }
        try bind(cutoff.timeIntervalSince1970, to: statement, at: 1)
        try step(statement)
    }

    func bookmarks() throws -> [BrowserBookmark] {
        try openIfNeeded()
        let statement = try prepare("SELECT payload FROM bookmarks ORDER BY updated_at DESC")
        defer { sqlite3_finalize(statement) }
        return try decodeRows(statement, as: BrowserBookmark.self)
    }

    func saveBookmark(_ bookmark: BrowserBookmark) throws {
        try openIfNeeded()
        let statement = try prepare("INSERT OR REPLACE INTO bookmarks(bookmark_id, updated_at, payload) VALUES(?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(bookmark.id.uuidString, to: statement, at: 1)
        try bind(bookmark.updatedAt.timeIntervalSince1970, to: statement, at: 2)
        try bind(try encoder.encode(bookmark), to: statement, at: 3)
        try step(statement)
    }

    func removeBookmark(id: UUID) throws {
        try openIfNeeded()
        let statement = try prepare("DELETE FROM bookmarks WHERE bookmark_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        try step(statement)
    }

    func downloads() throws -> [BrowserDownloadTask] {
        try openIfNeeded()
        let statement = try prepare("SELECT payload FROM downloads ORDER BY created_at DESC")
        defer { sqlite3_finalize(statement) }
        return try decodeRows(statement, as: BrowserDownloadTask.self)
    }

    func saveDownload(_ download: BrowserDownloadTask) throws {
        try openIfNeeded()
        let statement = try prepare("INSERT OR REPLACE INTO downloads(download_id, created_at, payload) VALUES(?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(download.id.uuidString, to: statement, at: 1)
        try bind(download.createdAt.timeIntervalSince1970, to: statement, at: 2)
        try bind(try encoder.encode(download), to: statement, at: 3)
        try step(statement)
    }

    func removeDownload(id: UUID) throws {
        try openIfNeeded()
        let statement = try prepare("DELETE FROM downloads WHERE download_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        try step(statement)
    }

    func removeDownloads(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try openIfNeeded()
        try withTransaction {
            let statement = try prepare("DELETE FROM downloads WHERE download_id = ?")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(id.uuidString, to: statement, at: 1)
                try step(statement)
            }
        }
    }

    func permissions(profileID: UUID) throws -> [WebsitePermission] {
        try openIfNeeded()
        let statement = try prepare("""
            SELECT payload FROM permissions
            WHERE profile_id = ?
            ORDER BY updated_at DESC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(profileID.uuidString, to: statement, at: 1)
        return try decodeRows(statement, as: WebsitePermission.self)
    }

    func savePermission(_ permission: WebsitePermission) throws {
        guard permission.decision.isPersistent else { return }
        try openIfNeeded()
        let statement = try prepare("""
            INSERT INTO permissions(
                permission_id, profile_id, top_level_origin, requesting_origin,
                permission_kind, updated_at, payload
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile_id, top_level_origin, requesting_origin, permission_kind)
            DO UPDATE SET
                permission_id = excluded.permission_id,
                updated_at = excluded.updated_at,
                payload = excluded.payload
            """)
        defer { sqlite3_finalize(statement) }
        try bind(permission.id.uuidString, to: statement, at: 1)
        try bind(permission.profileID.uuidString, to: statement, at: 2)
        try bind(permission.topLevelOrigin, to: statement, at: 3)
        try bind(permission.requestingOrigin, to: statement, at: 4)
        try bind(permission.kind.rawValue, to: statement, at: 5)
        try bind(permission.updatedAt.timeIntervalSince1970, to: statement, at: 6)
        try bind(try encoder.encode(permission), to: statement, at: 7)
        try step(statement)
    }

    func removePermission(id: UUID) throws {
        try openIfNeeded()
        let statement = try prepare("DELETE FROM permissions WHERE permission_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        try step(statement)
    }

    func sitePrivacyPolicies(profileID: UUID) throws -> [SitePrivacyPolicy] {
        try openIfNeeded()
        let statement = try prepare("""
            SELECT payload FROM site_privacy_policies
            WHERE profile_id = ?
            ORDER BY updated_at DESC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(profileID.uuidString, to: statement, at: 1)
        return try decodeRows(statement, as: SitePrivacyPolicy.self)
    }

    func saveSitePrivacyPolicy(_ policy: SitePrivacyPolicy) throws {
        try openIfNeeded()
        let statement = try prepare("""
            INSERT INTO site_privacy_policies(
                policy_id, profile_id, host, updated_at, payload
            ) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(profile_id, host)
            DO UPDATE SET
                policy_id = excluded.policy_id,
                updated_at = excluded.updated_at,
                payload = excluded.payload
            WHERE excluded.updated_at >= site_privacy_policies.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        try bind(policy.id.uuidString, to: statement, at: 1)
        try bind(policy.profileID.uuidString, to: statement, at: 2)
        try bind(policy.host.lowercased(), to: statement, at: 3)
        try bind(policy.updatedAt.timeIntervalSince1970, to: statement, at: 4)
        try bind(try encoder.encode(policy), to: statement, at: 5)
        try step(statement)
    }

    func replaceSitePrivacyPolicies(
        profileID: UUID,
        with policies: [SitePrivacyPolicy]
    ) throws {
        try openIfNeeded()
        try withTransaction {
            let deleteStatement = try prepare(
                "DELETE FROM site_privacy_policies WHERE profile_id = ?"
            )
            defer { sqlite3_finalize(deleteStatement) }
            try bind(profileID.uuidString, to: deleteStatement, at: 1)
            try step(deleteStatement)
            for policy in policies where policy.profileID == profileID {
                try saveSitePrivacyPolicy(policy)
            }
        }
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let opened { sqlite3_close(opened) }
            throw BrowserDatabaseError.openFailed(message)
        }
        database = SQLiteConnection(opened)
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            let existingVersion = try databaseUserVersion()
            guard existingVersion <= Self.databaseSchemaVersion else {
                throw BrowserDatabaseError.statementFailed(
                    "不支持的数据库版本：\(existingVersion)"
                )
            }
            try withTransaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS window_sessions(
                        window_id TEXT PRIMARY KEY,
                        last_opened_at REAL NOT NULL,
                        snapshot BLOB NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS history(
                        entry_id TEXT PRIMARY KEY,
                        visited_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS history_visited_at ON history(visited_at DESC);
                    CREATE TABLE IF NOT EXISTS bookmarks(
                        bookmark_id TEXT PRIMARY KEY,
                        updated_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS downloads(
                        download_id TEXT PRIMARY KEY,
                        created_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS permissions(
                        permission_id TEXT NOT NULL UNIQUE,
                        profile_id TEXT NOT NULL,
                        top_level_origin TEXT NOT NULL,
                        requesting_origin TEXT NOT NULL,
                        permission_kind TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(profile_id, top_level_origin, requesting_origin, permission_kind)
                    );
                    CREATE INDEX IF NOT EXISTS permissions_profile_updated
                        ON permissions(profile_id, updated_at DESC);
                    CREATE TABLE IF NOT EXISTS site_privacy_policies(
                        policy_id TEXT NOT NULL UNIQUE,
                        profile_id TEXT NOT NULL,
                        host TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(profile_id, host)
                    );
                    CREATE INDEX IF NOT EXISTS site_privacy_policies_profile_updated
                        ON site_privacy_policies(profile_id, updated_at DESC);
                    CREATE TABLE IF NOT EXISTS metadata(
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );
                    PRAGMA user_version = \(Self.databaseSchemaVersion);
                    """)
            }
        } catch {
            database = nil
            throw error
        }
    }

    private func migrateLegacySessionIfNeeded(to windowID: UUID) async throws -> BrowserSessionSnapshot? {
        let ownerPrefix = "in_progress:\(migrationOwnerID.uuidString):"
        if let state = try metadataValue(for: Self.legacyMigrationKey) {
            if state == "complete" || state.hasPrefix(ownerPrefix) { return nil }
        }

        try setMetadata("\(ownerPrefix)\(windowID.uuidString)", for: Self.legacyMigrationKey)
        do {
            guard let legacyPersistence,
                  var migrated = try await legacyPersistence.load() else {
                try setMetadata("complete", for: Self.legacyMigrationKey)
                return nil
            }
            migrated.windowID = windowID
            migrated.schemaVersion = BrowserSessionSnapshot.schemaVersion
            try withTransaction {
                try writeSnapshot(migrated)
                try setMetadata("complete", for: Self.legacyMigrationKey)
            }
            return migrated
        } catch {
            try? removeMetadata(for: Self.legacyMigrationKey)
            throw error
        }
    }

    private func databaseUserVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let value = text(from: statement, column: 0) else {
                throw BrowserDatabaseError.invalidRow
            }
            return value
        case SQLITE_DONE:
            return nil
        default:
            throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
        }
    }

    private func setMetadata(_ value: String, for key: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try bind(value, to: statement, at: 2)
        try step(statement)
    }

    private func removeMetadata(for key: String) throws {
        let statement = try prepare("DELETE FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try step(statement)
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database?.rawValue, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteErrorMessage
            sqlite3_free(errorMessage)
            throw BrowserDatabaseError.statementFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database?.rawValue, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BrowserDatabaseError.statementFailed(sqliteErrorMessage) }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw BrowserDatabaseError.statementFailed(sqliteErrorMessage) }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
        }
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
        }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else { throw BrowserDatabaseError.statementFailed(sqliteErrorMessage) }
    }

    private func decodeRows<T: Decodable>(_ statement: OpaquePointer, as type: T.Type) throws -> [T] {
        var result: [T] = []
        while true {
            let resultCode = sqlite3_step(statement)
            if resultCode == SQLITE_DONE { break }
            guard resultCode == SQLITE_ROW else {
                throw BrowserDatabaseError.statementFailed(sqliteErrorMessage)
            }
            guard let data = blob(from: statement, column: 0) else { throw BrowserDatabaseError.invalidRow }
            result.append(try decoder.decode(T.self, from: data))
        }
        return result
    }

    private func text(from statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func blob(from statement: OpaquePointer, column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private var sqliteErrorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0.rawValue)) } ?? "unknown error"
    }

}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
