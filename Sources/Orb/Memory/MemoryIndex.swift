import Foundation
import SQLite3

/// The derived search index of one Orb's memory (`index.sqlite` next to the pages). Everything in it can be
/// rebuilt from the markdown files, except the access counters that make used memories age slower.
/// Not thread-safe: owned by one `MemoryBank` actor (WAL mode lets another process read and write the same file).
final class MemoryIndex {
    enum Value {
        case text(String), real(Double), int(Int), null
    }

    struct Row {
        fileprivate let values: [Value]
        func text(_ column: Int) -> String {
            if case .text(let value) = values[column] { value } else { "" }
        }
        func double(_ column: Int) -> Double? {
            switch values[column] {
            case .real(let value): value
            case .int(let value): Double(value)
            default: nil
            }
        }
        func int(_ column: Int) -> Int {
            switch values[column] {
            case .int(let value): value
            case .real(let value): Int(value)
            default: 0
            }
        }
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Bumped when the schema changes; an index from another version is simply rebuilt from the pages.
    static let schemaVersion = 2

    /// Why an index could not be opened: another process holds it (try again later, never delete it), the file is
    /// damaged (rebuild it from the pages), or it is not there to open at all (folder missing, no permission).
    /// Prepared statement cache (safe without a lock because `MemoryIndex` is owned exclusively by one `MemoryBank` actor).
    private var statements: [String: OpaquePointer] = [:]

    enum Failure: Error { case busy, corrupt, unavailable }

    /// Whether the file is a usable index.
    enum Health { case ok, corrupt, busy }

    init(url: URL, busyTimeout: Int32 = 3000) throws {
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK else { throw Self.failure(code) } // `deinit` closes the handle
        sqlite3_busy_timeout(db, busyTimeout)
        // Opening an index that is already right writes nothing: a write here would wait for whoever holds the index
        // (another process rebuilding it) and fail with it busy.
        let version = rows("PRAGMA user_version").first?.int(0) ?? 0
        if version != 0, version != 1, version != Self.schemaVersion {
            sqlite3_exec(db, "DROP TABLE IF EXISTS pages_fts; DROP TABLE IF EXISTS pages; DROP TABLE IF EXISTS meta;", nil, nil, nil)
        }
        // Session pragmas: WAL checkpoint ceiling + tighter 512 KB page cache + in-memory temp B-trees + 4 MB mmap.
        var schema = "PRAGMA synchronous = NORMAL;\nPRAGMA cache_size = -512;\nPRAGMA journal_size_limit = 1048576;\nPRAGMA temp_store = MEMORY;\nPRAGMA mmap_size = 4194304;\n"
        if version != 1, version != Self.schemaVersion {
            if rows("PRAGMA journal_mode").first?.text(0).lowercased() != "wal" { schema += "PRAGMA journal_mode = WAL;\n" }
            schema += "PRAGMA user_version = \(Self.schemaVersion);\n"
            schema += """
            CREATE TABLE IF NOT EXISTS pages (
                id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                body TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, compacted INTEGER NOT NULL DEFAULT 0,
                mtime REAL NOT NULL DEFAULT 0, access_count INTEGER NOT NULL DEFAULT 0, last_access REAL,
                salience REAL NOT NULL DEFAULT 1, origin TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS pages_kind ON pages(kind, updated);
            CREATE INDEX IF NOT EXISTS pages_kind_access ON pages(kind, access_count DESC, path);
            CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(title, body, content='pages', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS pages_ai AFTER INSERT ON pages BEGIN
                INSERT INTO pages_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
            CREATE TRIGGER IF NOT EXISTS pages_ad AFTER DELETE ON pages BEGIN
                INSERT INTO pages_fts(pages_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END;
            CREATE TRIGGER IF NOT EXISTS pages_au AFTER UPDATE OF title, body ON pages BEGIN
                INSERT INTO pages_fts(pages_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
                INSERT INTO pages_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """
        }
        let result = sqlite3_exec(db, schema, nil, nil, nil)
        guard result == SQLITE_OK else { throw Self.failure(result) }
        // One-time non-destructive upgrade from v1 -> v2 (preserves `access_count` and `last_access`); v2 skips these checks.
        if version == 1 {
            let columns = Set(rows("PRAGMA table_info(pages)").map { $0.text(1) })
            if !columns.contains("origin") {
                _ = sqlite3_exec(db, "ALTER TABLE pages ADD COLUMN origin TEXT NOT NULL DEFAULT '';", nil, nil, nil)
            }
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS pages_kind_access ON pages(kind, access_count DESC, path); PRAGMA user_version = \(Self.schemaVersion);", nil, nil, nil)
        }
    }

    private static func failure(_ code: Int32) -> Failure {
        switch code & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED: .busy
        case SQLITE_CORRUPT, SQLITE_NOTADB: .corrupt
        default: .unavailable
        }
    }

    /// Whether the file is a usable index (a corrupt one is deleted and rebuilt by the bank; one that is only locked
    /// by another process is neither).
    var health: Health {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return Self.failure(sqlite3_errcode(db)) == .busy ? .busy : .corrupt
        }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return String(cString: sqlite3_column_text(statement, 0)) == "ok" ? .ok : .corrupt
        case let code: return Self.failure(code) == .busy ? .busy : .corrupt
        }
    }

    /// Runs `PRAGMA quick_check` at most once every 7 days on healthy openings to avoid scanning every B-tree on every app launch.
    func healthIfDue(now: Date = .now) -> Health {
        let last = rows("SELECT value FROM meta WHERE key = 'last_quick_check'").first.flatMap { Double($0.text(0)) }
        if let last, now.timeIntervalSince1970 - last < 7 * 86_400 { return .ok }
        let checked = health
        if checked == .ok {
            _ = run("INSERT INTO meta(key, value) VALUES ('last_quick_check', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(String(now.timeIntervalSince1970))])
        }
        return checked
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        sqlite3_close(db)
    }

    func shrinkMemory() {
        _ = run("PRAGMA shrink_memory")
    }

    @discardableResult
    func run(_ sql: String, _ arguments: [Value] = []) -> Bool {
        guard let (statement, cached) = prepare(sql, arguments) else { return false }
        defer {
            if cached {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                sqlite3_finalize(statement)
            }
        }
        let code = sqlite3_step(statement)
        return code == SQLITE_DONE || code == SQLITE_ROW
    }

    func rows(_ sql: String, _ arguments: [Value] = []) -> [Row] {
        guard let (statement, cached) = prepare(sql, arguments) else { return [] }
        defer {
            if cached {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                sqlite3_finalize(statement)
            }
        }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Row(values: (0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                default: .null
                }
            }))
        }
        return rows
    }

    /// Runs `work` in one write transaction; if the database stays locked, the statements still run one by one.
    func transaction(_ work: () -> Void) {
        let began = run("BEGIN IMMEDIATE")
        work()
        // A commit that fails (a full disk) must not leave the connection inside the transaction for good: the files are
        // the truth, and the next reconcile writes it again.
        if began, !run("COMMIT") { run("ROLLBACK") }
    }

    private func prepare(_ sql: String, _ arguments: [Value]) -> (OpaquePointer, cached: Bool)? {
        let statement: OpaquePointer
        let cached: Bool
        if let existing = statements[sql] {
            statement = existing
            cached = true
        } else {
            var created: OpaquePointer?
            let flags: UInt32 = statements.count < 64 ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
            guard sqlite3_prepare_v3(db, sql, -1, flags, &created, nil) == SQLITE_OK,
                  let created else {
                sqlite3_finalize(created)
                return nil
            }
            if statements.count < 64 {
                statements[sql] = created
                cached = true
            } else {
                cached = false
            }
            statement = created
        }
        for (offset, argument) in arguments.enumerated() {
            let position = Int32(offset + 1)
            switch argument {
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case .real(let value): sqlite3_bind_double(statement, position, value)
            case .int(let value): sqlite3_bind_int64(statement, position, Int64(value))
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return (statement, cached)
    }
}
