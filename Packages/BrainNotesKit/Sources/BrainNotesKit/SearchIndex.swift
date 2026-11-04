import Foundation
import GRDB

public struct IndexedNote: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var folder: String
    public var modified: Date?
    public var snippet: String
    public var isConflictCopy: Bool
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    /// Title and snippet carry `\u{E000}` before and `\u{E001}` after each match.
    public var title: String
    public var snippet: String
    public static let open: Character = "\u{E000}"
    public static let close: Character = "\u{E001}"
}

/// `index.sqlite`: derived list + FTS5 index. Delete and rebuild from the files on any problem.
public final class SearchIndex: @unchecked Sendable {
    public let queue: DatabaseQueue
    /// True when the database had to be recreated; the caller rebuilds from the files.
    public let wasReset: Bool

    public init(path: String?) throws {
        (queue, wasReset) = try Self.open(path)
    }

    private static func open(_ path: String?) throws -> (DatabaseQueue, Bool) {
        var config = Configuration()
        config.label = "index"
        do {
            let q = try path.map { try DatabaseQueue(path: $0, configuration: config) } ?? DatabaseQueue(configuration: config)
            try migrate(q)
            return (q, false)
        } catch {
            // Open or schema failure: delete and start again (derived data).
            if let path { for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
            let q = try path.map { try DatabaseQueue(path: $0, configuration: config) } ?? DatabaseQueue(configuration: config)
            try migrate(q)
            return (q, true)
        }
    }

    private static func migrate(_ q: DatabaseQueue) throws {
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS notes(
                  path TEXT PRIMARY KEY, title TEXT NOT NULL, folder TEXT NOT NULL,
                  modified REAL, snippet TEXT NOT NULL DEFAULT '', is_conflict INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS notes_folder ON notes(folder);
                CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                  path UNINDEXED, title, body, stems, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
                """)
        }
    }

    // MARK: derive

    public static func folder(of path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        return String(path[path.startIndex..<slash])
    }

    // MARK: write

    public func upsert(path: String, text: String, modified: Date?) throws {
        try queue.write { db in try Self.upsert(db, path: path, text: text, modified: modified) }
    }

    static func upsert(_ db: Database, path: String, text: String, modified: Date?) throws {
        let title = NoteText.title(of: text, path: path)
        let (_, body) = NoteText.split(text)
        try db.execute(sql: """
            INSERT INTO notes(path, title, folder, modified, snippet, is_conflict) VALUES(?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET title=excluded.title, folder=excluded.folder, modified=excluded.modified,
              snippet=excluded.snippet, is_conflict=excluded.is_conflict
            """, arguments: [path, title, folder(of: path), modified?.timeIntervalSince1970,
                             NoteText.snippet(of: text, title: title), NoteText.isConflictCopy(text)])
        try db.execute(sql: "DELETE FROM fts WHERE path = ?", arguments: [path])
        let foldedTitle = NoteText.foldForSearch(title), foldedBody = NoteText.foldForSearch(body)
        try db.execute(sql: "INSERT INTO fts(path, title, body, stems) VALUES(?,?,?,?)",
                       arguments: [path, foldedTitle, foldedBody, NoteText.hebrewStems(foldedTitle + "\n" + foldedBody)])
    }

    public func remove(path: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM fts WHERE path = ?", arguments: [path])
        }
    }

    public func setModified(_ dates: [(path: String, date: Date)]) throws {
        try queue.write { db in
            for d in dates {
                try db.execute(sql: "UPDATE notes SET modified = ? WHERE path = ?", arguments: [d.date.timeIntervalSince1970, d.path])
            }
        }
    }

    public func clear() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM notes")
            try db.execute(sql: "DELETE FROM fts")
        }
    }

    /// Add a batch in one transaction. A rebuild is `clear` followed by batches, so lists fill as it runs.
    public func add(_ items: [(path: String, text: String, modified: Date?)]) throws {
        try queue.write { db in
            for i in items { try Self.upsert(db, path: i.path, text: i.text, modified: i.modified) }
        }
    }

    public func stamp() -> String? {
        try? queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'stamp'") }
    }

    public func setStamp(_ stamp: String) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('stamp', ?)", arguments: [stamp])
        }
    }

    // MARK: read

    /// Newest first when dates are known; notes without a date sort by title after them.
    public func notes(inFolder folder: String? = nil) async -> [IndexedNote] {
        (try? await queue.read { db in try Self.fetchNotes(db, folder: folder) }) ?? []
    }

    public func notesSync(inFolder folder: String? = nil) -> [IndexedNote] {
        (try? queue.read { db in try Self.fetchNotes(db, folder: folder) }) ?? []
    }

    private static func fetchNotes(_ db: Database, folder: String?) throws -> [IndexedNote] {
        let order = "ORDER BY modified IS NULL, modified DESC, title COLLATE NOCASE"
        let rows: [Row]
        if let folder {
            rows = try Row.fetchAll(db, sql: "SELECT * FROM notes WHERE folder = ? \(order)", arguments: [folder])
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT * FROM notes \(order)")
        }
        return rows.map(Self.note)
    }

    public func note(path: String) -> IndexedNote? {
        try? queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE path = ?", arguments: [path]).map(Self.note) }
    }

    public func allPaths() async -> [String] {
        (try? await queue.read { db in try String.fetchAll(db, sql: "SELECT path FROM notes") }) ?? []
    }

    private static func note(_ r: Row) -> IndexedNote {
        IndexedNote(path: r["path"], title: r["title"], folder: r["folder"],
                    modified: (r["modified"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    snippet: r["snippet"], isConflictCopy: r["is_conflict"])
    }

    public func count() -> Int {
        (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") }) ?? 0
    }

    /// FTS5 query: each word as a quoted prefix, all required. Returns nil when nothing searchable was typed.
    static func matchExpression(_ query: String) -> String? {
        let tokens = NoteText.foldForSearch(query)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Prefix-matching full text search over title + body, Hebrew and English.
    public func search(_ query: String, limit: Int = 50) async -> [SearchHit] {
        guard let match = Self.matchExpression(query) else { return [] }
        return (try? await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT path, highlight(fts, 1, char(57344), char(57345)) AS t,
                       snippet(fts, 2, char(57344), char(57345), '…', 16) AS s
                FROM fts WHERE fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [match, limit]).map { r in
                SearchHit(path: r["path"], title: r["t"], snippet: (r["s"] as String).replacingOccurrences(of: "\n", with: " "))
            }
        }) ?? []
    }

    public func close() throws { try queue.close() }
}
