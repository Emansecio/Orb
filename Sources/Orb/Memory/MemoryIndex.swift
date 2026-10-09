import Foundation
import SQLite3

/// The derived search index of one Orb's memory (`index.sqlite` next to the pages). Everything in it can be
/// rebuilt from the markdown files, except the access counters that make used memories age slower.
/// Not thread-safe: owned by one `MemoryBank` actor (the Claude Code helper process opens its own, and WAL
/// mode lets both read and write the same file).
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
    static let schemaVersion = 1

    /// Why an index could not be opened: another process holds it (try again later, never delete it), the file is
    /// damaged (rebuild it from the pages), or it is not there to open at all (folder missing, no permission).
    enum Failure: Error { case busy, corrupt, unavailable }

    /// Whether the file is a usable index.
    enum Health { case ok, corrupt, busy }

    init(url: URL, busyTimeout: Int32 = 3000) throws {
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK else { throw Self.failure(code) } // `deinit` closes the handle
        sqlite3_busy_timeout(db, busyTimeout)
        // Opening an index that is already right writes nothing: a write here would wait for whoever holds the index
        // (the app rebuilding it, the Claude Code helper) and fail with it busy.
        let version = rows("PRAGMA user_version").first?.int(0) ?? 0
        if version != 0, version != Self.schemaVersion {
            sqlite3_exec(db, "DROP TABLE IF EXISTS pages_fts; DROP TABLE IF EXISTS pages; DROP TABLE IF EXISTS meta;", nil, nil, nil)
        }
        var schema = "PRAGMA synchronous = NORMAL;\n"
        if rows("PRAGMA journal_mode").first?.text(0).lowercased() != "wal" { schema += "PRAGMA journal_mode = WAL;\n" }
        if version != Self.schemaVersion { schema += "PRAGMA user_version = \(Self.schemaVersion);\n" }
        schema += """
        CREATE TABLE IF NOT EXISTS pages (
            id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
            body TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, compacted INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0, access_count INTEGER NOT NULL DEFAULT 0, last_access REAL,
            salience REAL NOT NULL DEFAULT 1);
        CREATE INDEX IF NOT EXISTS pages_kind ON pages(kind, updated);
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
        let result = sqlite3_exec(db, schema, nil, nil, nil)
        guard result == SQLITE_OK else { throw Self.failure(result) }
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

    deinit { sqlite3_close(db) }

    @discardableResult
    func run(_ sql: String, _ arguments: [Value] = []) -> Bool {
        guard let statement = prepare(sql, arguments) else { return false }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        return code == SQLITE_DONE || code == SQLITE_ROW
    }

    func rows(_ sql: String, _ arguments: [Value] = []) -> [Row] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
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
        if began { run("COMMIT") }
    }

    private func prepare(_ sql: String, _ arguments: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
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
        return statement
    }
}
