import Foundation
import GRDB

public enum OpKind: String, Sendable, Codable { case edit, create, delete }

public struct OutboxOp: Sendable, Equatable {
    public var seq: Int64
    public var opId: String
    public var opTime: String
    public var kind: OpKind
    public var path: String
    public var contentHash: String?
}

public struct FileRow: Sendable, Equatable {
    public var path: String
    /// Blob sha at the base commit; nil for a note created here and not yet pushed.
    public var blobSha: String?
    public var dirty: Bool
    /// Text at the base commit, kept only while dirty (the merge base).
    public var baseText: String?
    public var modified: Date?
}

public struct AttentionItem: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var path: String
    public var reason: String
    public var copyPath: String?
    public var detail: String?
    public var created: String
    public var resolved: Bool
}

/// `journal.sqlite`: the sync source of truth. One transaction per save. Not rebuildable.
public final class Journal: @unchecked Sendable {
    public let queue: DatabaseQueue

    public init(path: String?) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if let path {
            queue = try DatabaseQueue(path: path, configuration: config)
        } else {
            queue = try DatabaseQueue(configuration: config)
        }
        try migrate()
    }

    private func migrate() throws {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
            try db.create(table: "files") { t in
                t.column("path", .text).primaryKey()
                t.column("blob_sha", .text)
                t.column("dirty", .boolean).notNull().defaults(to: false)
                t.column("base_text", .text)
                t.column("modified", .double)
            }
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("op_id", .text).notNull()
                t.column("op_time", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull()
                t.column("content_hash", .text)
            }
            try db.create(table: "attention") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("copy_path", .text)
                t.column("detail", .text)
                t.column("created", .text).notNull()
                t.column("resolved", .boolean).notNull().defaults(to: false)
            }
        }
        try m.migrate(queue)
    }

    // MARK: meta

    public func meta(_ key: String) -> String? {
        try? queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try queue.write { db in try Self.setMeta(db, key, value) }
    }

    static func setMeta(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public var baseCommit: String? { meta("base_commit") }

    // MARK: rows

    static func fileRow(_ r: Row) -> FileRow {
        FileRow(path: r["path"], blobSha: r["blob_sha"], dirty: r["dirty"], baseText: r["base_text"],
                modified: (r["modified"] as Double?).map { Date(timeIntervalSince1970: $0) })
    }

    public func file(_ path: String) -> FileRow? {
        try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?", arguments: [path]).map(Self.fileRow)
        }
    }

    public func allFiles() -> [FileRow] {
        (try? queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM files ORDER BY path").map(Self.fileRow) }) ?? []
    }

    public func outbox() -> [OutboxOp] {
        (try? queue.read { db in try Self.outbox(db) }) ?? []
    }

    static func outbox(_ db: Database) throws -> [OutboxOp] {
        try Row.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY seq").compactMap { r in
            guard let kind = OpKind(rawValue: r["kind"]) else { return nil }
            return OutboxOp(seq: r["seq"], opId: r["op_id"], opTime: r["op_time"], kind: kind, path: r["path"], contentHash: r["content_hash"])
        }
    }

    public func attention(includeResolved: Bool = false) -> [AttentionItem] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attention \(includeResolved ? "" : "WHERE resolved = 0") ORDER BY id").map { r in
                AttentionItem(id: r["id"], path: r["path"], reason: r["reason"], copyPath: r["copy_path"],
                              detail: r["detail"], created: r["created"], resolved: r["resolved"])
            }
        }) ?? []
    }

    static func addAttention(_ db: Database, path: String, reason: String, copyPath: String? = nil, detail: String? = nil, created: String) throws {
        // One open item per (path, reason, copy).
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attention WHERE path = ? AND reason = ? AND IFNULL(copy_path,'') = ? AND resolved = 0)",
                                       arguments: [path, reason, copyPath ?? ""]) ?? false
        if exists { return }
        try db.execute(sql: "INSERT INTO attention(path, reason, copy_path, detail, created) VALUES(?,?,?,?,?)",
                       arguments: [path, reason, copyPath, detail, created])
    }

    public func resolveAttention(id: Int64) throws {
        try queue.write { db in try db.execute(sql: "UPDATE attention SET resolved = 1 WHERE id = ?", arguments: [id]) }
    }

    public func wipe() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM meta")
            try db.execute(sql: "DELETE FROM files")
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "DELETE FROM attention")
        }
    }
}
