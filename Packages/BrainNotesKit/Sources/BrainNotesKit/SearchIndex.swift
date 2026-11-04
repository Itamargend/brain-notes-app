import Foundation
import GRDB

public struct IndexedNote: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var folder: String
    public var modified: Date?
    public var snippet: String
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var title: String
    /// Snippet with `\u{E000}` before and `\u{E001}` after each match.
    public var snippet: String
    public static let open: Character = "\u{E000}"
    public static let close: Character = "\u{E001}"
}

/// `index.sqlite`: derived list + FTS5 index. Delete and rebuild from the files on any problem.
public final class SearchIndex: @unchecked Sendable {
    public let queue: DatabaseQueue
    private let path: String?

    public init(path: String?) throws {
        self.path = path
        queue = try Self.open(path)
    }

    private static func open(_ path: String?) throws -> DatabaseQueue {
        let q = path.map { try? DatabaseQueue(path: $0) } ?? (try? DatabaseQueue())
        guard let q, (try? Self.migrate(q)) != nil else {
            // Open or schema failure: delete and start again (derived data).
            if let path { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
            let q2 = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
            try migrate(q2)
            return q2
        }
        return q
    }

    private static func migrate(_ q: DatabaseQueue) throws {
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS notes(
                  path TEXT PRIMARY KEY, title TEXT NOT NULL, folder TEXT NOT NULL,
                  modified REAL, snippet TEXT NOT NULL DEFAULT '');
                CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                  path UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2');
                """)
        }
    }

    // MARK: derive

    public static func title(of text: String, path: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { continue }
            if t.hasPrefix("type:") || t.hasPrefix("conflict_of:") || t.hasPrefix("device:") || t.hasPrefix("created:") { continue }
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        let name = (path as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    /// Body text without YAML frontmatter.
    public static func body(of text: String) -> String {
        guard text.hasPrefix("---\n") else { return text }
        let rest = text.dropFirst(4)
        if let r = rest.range(of: "\n---\n") { return String(rest[r.upperBound...]) }
        return text
    }

    static func snippet(of text: String, title: String) -> String {
        var lines: [String] = []
        for line in body(of: text).split(separator: "\n", omittingEmptySubsequences: true) {
            var t = line.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == title { continue }
            lines.append(t)
            if lines.joined(separator: " ").count > 200 { break }
        }
        return String(lines.joined(separator: " ").prefix(240))
    }

    public static func folder(of path: String) -> String {
        let f = (path as NSString).deletingLastPathComponent
        return f
    }

    // MARK: write

    public func upsert(path: String, text: String, modified: Date?) throws {
        try queue.write { db in try Self.upsert(db, path: path, text: text, modified: modified) }
    }

    static func upsert(_ db: Database, path: String, text: String, modified: Date?) throws {
        let title = title(of: text, path: path)
        try db.execute(sql: "INSERT INTO notes(path,title,folder,modified,snippet) VALUES(?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET title=excluded.title, folder=excluded.folder, modified=excluded.modified, snippet=excluded.snippet",
                       arguments: [path, title, folder(of: path), modified?.timeIntervalSince1970, snippet(of: text, title: title)])
        try db.execute(sql: "DELETE FROM fts WHERE path = ?", arguments: [path])
        try db.execute(sql: "INSERT INTO fts(path,title,body) VALUES(?,?,?)", arguments: [path, title, body(of: text)])
    }

    public func remove(path: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM fts WHERE path = ?", arguments: [path])
        }
    }

    /// Replace everything from (path, text, modified) triples.
    public func rebuild(_ items: [(path: String, text: String, modified: Date?)]) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM notes")
            try db.execute(sql: "DELETE FROM fts")
            for i in items { try Self.upsert(db, path: i.path, text: i.text, modified: i.modified) }
        }
    }

    // MARK: read

    public func notes(inFolder folder: String? = nil) -> [IndexedNote] {
        (try? queue.read { db in
            let rows: [Row]
            if let folder {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM notes WHERE folder = ? ORDER BY modified IS NULL, modified DESC, title COLLATE NOCASE", arguments: [folder])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY modified IS NULL, modified DESC, title COLLATE NOCASE")
            }
            return rows.map(Self.note)
        }) ?? []
    }

    public func note(path: String) -> IndexedNote? {
        try? queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE path = ?", arguments: [path]).map(Self.note) }
    }

    private static func note(_ r: Row) -> IndexedNote {
        IndexedNote(path: r["path"], title: r["title"], folder: r["folder"],
                    modified: (r["modified"] as Double?).map { Date(timeIntervalSince1970: $0) }, snippet: r["snippet"])
    }

    public func count() -> Int {
        (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") }) ?? 0
    }

    /// Prefix-matching full text search over title + body.
    public func search(_ query: String, limit: Int = 50) -> [SearchHit] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation && $0 != "'" })
            .map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        return (try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT path, title, snippet(fts, 2, char(57344), char(57345), '…', 14) AS snip
                FROM fts WHERE fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [match, limit]).map { r in
                SearchHit(path: r["path"], title: r["title"], snippet: (r["snip"] as String).replacingOccurrences(of: "\n", with: " "))
            }
        }) ?? []
    }
}
