import Foundation
import SQLite3

// Local persistence (SQLite): events by id, the outbox, and a key-value table (decrypted messages,
// read marks, caches). Everything the app shows comes from here, so it opens offline and the
// outbox survives restarts. Signed-out = the file is deleted.

public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw BelfryError.invalid("cannot open the local database")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, kind INTEGER, created_at INTEGER, json TEXT NOT NULL)")
        try exec("CREATE INDEX IF NOT EXISTS events_kind ON events(kind, created_at)")
        try exec("CREATE TABLE IF NOT EXISTS outbox (local_id TEXT PRIMARY KEY, created_at INTEGER, json TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    /// An in-memory database (tests, demo).
    public static func memory() throws -> Database { try Database(path: ":memory:") }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw BelfryError.invalid("database: " + String(cString: sqlite3_errmsg(db)))
        }
    }

    private func run(_ sql: String, _ binds: [Any?], _ row: ((OpaquePointer) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, Database.transient)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row?(stmt!) }
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    // ---- events ---------------------------------------------------------------------------------

    /// Stores the events it does not have yet; returns those that were new.
    @discardableResult
    public func add(_ events: [NostrEvent]) -> [NostrEvent] {
        var fresh = [NostrEvent]()
        lock.lock()
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO events (id, kind, created_at, json) VALUES (?, ?, ?, ?)", -1, &stmt, nil)
        for e in events {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, e.id, -1, Database.transient)
            sqlite3_bind_int64(stmt, 2, Int64(e.kind))
            sqlite3_bind_int64(stmt, 3, Int64(e.createdAt))
            sqlite3_bind_text(stmt, 4, e.json, -1, Database.transient)
            if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 { fresh.append(e) }
        }
        sqlite3_finalize(stmt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        lock.unlock()
        return fresh
    }

    public func allEvents() -> [NostrEvent] {
        var out = [NostrEvent]()
        run("SELECT json FROM events", []) { s in if let e = NostrEvent.from(json: Database.text(s, 0)) { out.append(e) } }
        return out
    }

    public func latestCreatedAt(kinds: [Int]) -> Int {
        guard !kinds.isEmpty else { return 0 }
        var v = 0
        run("SELECT MAX(created_at) FROM events WHERE kind IN (\(kinds.map(String.init).joined(separator: ",")))", []) { s in
            v = Int(sqlite3_column_int64(s, 0))
        }
        return v
    }

    // ---- outbox ---------------------------------------------------------------------------------

    public func putOutbox(_ item: OutboxItem) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        run("INSERT OR REPLACE INTO outbox (local_id, created_at, json) VALUES (?, ?, ?)", [item.localId, item.createdAt, String(decoding: data, as: UTF8.self)])
    }

    public func dropOutbox(_ localId: String) { run("DELETE FROM outbox WHERE local_id = ?", [localId]) }

    public func outbox() -> [OutboxItem] {
        var out = [OutboxItem]()
        run("SELECT json FROM outbox ORDER BY created_at", []) { s in
            if let item = try? JSONDecoder().decode(OutboxItem.self, from: Data(Database.text(s, 0).utf8)) { out.append(item) }
        }
        return out
    }

    // ---- key-value --------------------------------------------------------------------------------

    public func set<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [key, String(decoding: data, as: UTF8.self)])
    }

    public func get<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        var text: String?
        run("SELECT value FROM kv WHERE key = ?", [key]) { s in text = Database.text(s, 0) }
        guard let text else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public func remove(_ key: String) { run("DELETE FROM kv WHERE key = ?", [key]) }
}
