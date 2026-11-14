import Foundation
import GRDB

public enum OpKind: String, Sendable, Codable { case edit, create, delete }

/// One pending change. There is at most one op per path: repeated saves update the op in place
/// and bump `rev`, so a push in flight can tell whether the note changed under it.
public struct OutboxOp: Sendable, Equatable {
    public var seq: Int64
    public var opId: String
    /// Fixed when the op is created: exact UTC string ending in Z. The commit date, so a retry has the same sha.
    public var opTime: String
    public var kind: OpKind
    public var path: String
    public var contentHash: String?
    /// The text to push (nil for a delete). Lives in the journal so that a push can finish while the
    /// note files are locked, and so that a note file lost before it was pushed can be written again.
    /// Like everything of the repo, the journal is out of backups (`NoteStore.init`).
    public var content: String?
    public var rev: Int
    /// Taken out of pushes until the note is edited again (rejected by GitHub or the planner).
    public var parked: Bool
    public var inFlight: Bool
}

public struct FileRow: Sendable, Equatable {
    public var path: String
    /// Blob sha at the last commit this device knows; nil when the path is not on GitHub.
    public var blobSha: String?
    public var dirty: Bool
    /// The text the current edit started from, kept only while dirty (the merge base).
    public var baseText: String?
    public var modified: Date?
    public var diskSize: Int64?
    public var diskMtime: Double?
    /// False for a path that is on GitHub but not stored here (it clashes with another path on this file system).
    public var local: Bool
    /// GitHub renamed this dirty note to this path.
    public var renameTo: String?

    public init(path: String, blobSha: String?, dirty: Bool = false, baseText: String? = nil, modified: Date? = nil,
                diskSize: Int64? = nil, diskMtime: Double? = nil, local: Bool = true, renameTo: String? = nil) {
        self.path = path; self.blobSha = blobSha; self.dirty = dirty; self.baseText = baseText; self.modified = modified
        self.diskSize = diskSize; self.diskMtime = diskMtime; self.local = local; self.renameTo = renameTo
    }
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

/// The four per-note states the UI shows.
public enum NoteSyncStatus: String, Sendable, Equatable {
    case savedOnDevice, syncing, synced, needsAttention
}

/// A commit that was created and is about to be, or may have been, moved onto main. Written before the
/// ref update, so a lost response or a kill can be resolved by reading the ref.
public struct PendingPush: Sendable, Equatable {
    public var commit: String
    public var parent: String
    public var planJSON: Data
}

/// `journal.sqlite`: the sync source of truth. One transaction per save. Not rebuildable.
/// File protection on iOS: complete until first authentication, so a push can finish after lock.
public final class Journal: @unchecked Sendable {
    public let queue: DatabaseQueue

    public init(path: String?) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "journal"
        if let path {
            queue = try DatabaseQueue(path: path, configuration: config)
            #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            #endif
        } else {
            queue = try DatabaseQueue(configuration: config)
        }
        try migrate()
        // Nothing is running when the journal opens, so an op is in flight only if a commit of unknown fate
        // waits to be verified: until then the note must not be renamed or forgotten.
        try queue.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM pending_push") == nil {
                try db.execute(sql: "UPDATE outbox SET in_flight = 0 WHERE in_flight = 1")
            }
        }
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
                t.column("disk_size", .integer)
                t.column("disk_mtime", .double)
                t.column("local", .boolean).notNull().defaults(to: true)
                t.column("rename_to", .text)
            }
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("op_id", .text).notNull()
                t.column("op_time", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("content_hash", .text)
                t.column("content", .text)
                t.column("rev", .integer).notNull().defaults(to: 1)
                t.column("parked", .boolean).notNull().defaults(to: false)
                t.column("in_flight", .boolean).notNull().defaults(to: false)
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
            try db.create(table: "pending_push") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("commit_sha", .text).notNull()
                t.column("parent_sha", .text).notNull()
                t.column("plan_json", .blob).notNull()
            }
        }
        try m.migrate(queue)
    }

    /// A synchronous write transaction, usable from async code (where `queue.write` means GRDB's async
    /// overload, whose closure cannot capture local state). Writes are short; a save never waits long.
    func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        try queue.write(body)
    }

    // MARK: meta

    public func meta(_ key: String) -> String? {
        try? queue.read { db in try Self.meta(db, key) }
    }

    static func meta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
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

    public var baseCommit: String? { meta(Key.baseCommit) }
    public var isUserPaused: Bool { meta(Key.userPaused) == "1" }

    enum Key {
        static let baseCommit = "base_commit"
        static let remoteHead = "remote_head"
        static let refEtag = "ref_etag"
        static let lastCommitAt = "last_commit_at"
        static let lastSync = "last_sync"
        static let device = "device"
        static let userPaused = "user_paused"
        static let datesPending = "dates_pending"
        /// First sync swapped the files folder in and has not recorded it yet.
        static let swapping = "swapping"
        /// Set to "1" when first sync verified an empty (0-commit) remote repository; cleared once a commit exists.
        static let emptyRemote = "empty_remote"
    }

    // MARK: files

    static func fileRow(_ r: Row) -> FileRow {
        FileRow(path: r["path"], blobSha: r["blob_sha"], dirty: r["dirty"], baseText: r["base_text"],
                modified: (r["modified"] as Double?).map { Date(timeIntervalSince1970: $0) },
                diskSize: r["disk_size"], diskMtime: r["disk_mtime"], local: r["local"], renameTo: r["rename_to"])
    }

    static func file(_ db: Database, _ path: String) throws -> FileRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?", arguments: [path]).map(fileRow)
    }

    static func putFile(_ db: Database, _ f: FileRow) throws {
        try db.execute(sql: """
            INSERT INTO files(path, blob_sha, dirty, base_text, modified, disk_size, disk_mtime, local, rename_to)
            VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET blob_sha=excluded.blob_sha, dirty=excluded.dirty, base_text=excluded.base_text,
              modified=excluded.modified, disk_size=excluded.disk_size, disk_mtime=excluded.disk_mtime,
              local=excluded.local, rename_to=excluded.rename_to
            """, arguments: [f.path, f.blobSha, f.dirty, f.baseText, f.modified?.timeIntervalSince1970,
                             f.diskSize, f.diskMtime, f.local, f.renameTo])
    }

    static func removeFile(_ db: Database, _ path: String) throws {
        try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
    }

    public func file(_ path: String) -> FileRow? {
        try? queue.read { db in try Self.file(db, path) }
    }

    /// Every row, without the merge-base text of dirty notes when `withBase` is false.
    public func allFiles() -> [FileRow] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM files ORDER BY path").map(Self.fileRow)
        }) ?? []
    }

    // MARK: outbox

    static func opRow(_ r: Row) -> OutboxOp? {
        guard let kind = OpKind(rawValue: r["kind"]) else { return nil }
        return OutboxOp(seq: r["seq"], opId: r["op_id"], opTime: r["op_time"], kind: kind, path: r["path"],
                        contentHash: r["content_hash"], content: r["content"], rev: r["rev"],
                        parked: r["parked"], inFlight: r["in_flight"])
    }

    static func op(_ db: Database, path: String) throws -> OutboxOp? {
        try Row.fetchOne(db, sql: "SELECT * FROM outbox WHERE path = ?", arguments: [path]).flatMap(opRow)
    }

    static func op(_ db: Database, seq: Int64) throws -> OutboxOp? {
        try Row.fetchOne(db, sql: "SELECT * FROM outbox WHERE seq = ?", arguments: [seq]).flatMap(opRow)
    }

    static func outbox(_ db: Database) throws -> [OutboxOp] {
        try Row.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY seq").compactMap(opRow)
    }

    public func outbox() -> [OutboxOp] {
        (try? queue.read { db in try Self.outbox(db) }) ?? []
    }

    public func outboxCount() -> Int {
        (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") }) ?? 0
    }

    /// Ops a push would take: all but the parked ones.
    func pushableCount() -> Int {
        (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE parked = 0") }) ?? 0
    }

    /// When the oldest unsynced op was made, for the 24 h badge.
    public func oldestOpTime() -> Date? {
        let s = try? queue.read { db in try String.fetchOne(db, sql: "SELECT op_time FROM outbox ORDER BY op_time LIMIT 1") }
        return s.flatMap { $0 }.flatMap(parseISOTime)
    }

    /// Add or update the op for a path, all in the caller's transaction.
    static func upsertOp(_ db: Database, path: String, kind: OpKind, content: String?, newId: String, time: String) throws {
        let hash = content.map(contentHash)
        if try op(db, path: path) != nil {
            try db.execute(sql: "UPDATE outbox SET kind = ?, content = ?, content_hash = ?, rev = rev + 1, parked = 0 WHERE path = ?",
                           arguments: [kind.rawValue, content, hash, path])
        } else {
            try db.execute(sql: "INSERT INTO outbox(op_id, op_time, kind, path, content_hash, content) VALUES(?,?,?,?,?,?)",
                           arguments: [newId, time, kind.rawValue, path, hash, content])
        }
    }

    static func removeOp(_ db: Database, seq: Int64) throws {
        try db.execute(sql: "DELETE FROM outbox WHERE seq = ?", arguments: [seq])
    }

    // MARK: attention

    public func attention(includeResolved: Bool = false) -> [AttentionItem] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attention \(includeResolved ? "" : "WHERE resolved = 0") ORDER BY id").map(Self.attentionRow)
        }) ?? []
    }

    static func attentionRow(_ r: Row) -> AttentionItem {
        AttentionItem(id: r["id"], path: r["path"], reason: r["reason"], copyPath: r["copy_path"],
                      detail: r["detail"], created: r["created"], resolved: r["resolved"])
    }

    public func attention(id: Int64) -> AttentionItem? {
        try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM attention WHERE id = ?", arguments: [id]).map(Self.attentionRow)
        }
    }

    public func attentionCount() -> Int {
        (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attention WHERE resolved = 0") }) ?? 0
    }

    public func attention(forPath path: String) -> [AttentionItem] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attention WHERE resolved = 0 AND path = ? ORDER BY id", arguments: [path]).map(Self.attentionRow)
        }) ?? []
    }

    /// One open item per (path, reason, copy).
    static func addAttention(_ db: Database, path: String, reason: String, copyPath: String? = nil, detail: String? = nil, created: String) throws {
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attention WHERE path = ? AND reason = ? AND IFNULL(copy_path,'') = ? AND resolved = 0)",
                                       arguments: [path, reason, copyPath ?? ""]) ?? false
        if exists { return }
        try db.execute(sql: "INSERT INTO attention(path, reason, copy_path, detail, created) VALUES(?,?,?,?,?)",
                       arguments: [path, reason, copyPath, detail, created])
    }

    /// Close the items that describe a problem with pushing or storing this path: they end when the push works, or when
    /// the note reaches this device after all.
    static func resolvePushProblems(_ db: Database, path: String) throws {
        try db.execute(sql: """
            UPDATE attention SET resolved = 1 WHERE resolved = 0 AND path = ?
              AND (reason LIKE 'blocked:%' OR reason IN ('case-clash', 'unstorable', 'too-large', 'push-failed', 'rejected'))
            """, arguments: [path])
    }

    /// Paths that were ever held back for this reason, open or closed: the item stays in the table after the user
    /// closes it.
    func pathsEverHeldBack(for reason: String) -> Set<PathKey> {
        let paths = (try? queue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT path FROM attention WHERE reason = ?", arguments: [reason])
        }) ?? []
        return Set(paths.map(PathKey.init))
    }

    public func resolveAttention(id: Int64) throws {
        try queue.write { db in try db.execute(sql: "UPDATE attention SET resolved = 1 WHERE id = ?", arguments: [id]) }
    }

    // MARK: status

    /// Per-note state, derived from the outbox and the attention list, for every note that is not plain synced.
    public func statuses() -> [PathKey: NoteSyncStatus] {
        (try? queue.read { db in
            var out: [PathKey: NoteSyncStatus] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT path, in_flight FROM outbox") {
                let flying: Bool = r["in_flight"]
                out[PathKey(r["path"])] = flying ? .syncing : .savedOnDevice
            }
            for path in try String.fetchAll(db, sql: "SELECT path FROM attention WHERE resolved = 0") {
                out[PathKey(path)] = .needsAttention
            }
            return out
        }) ?? [:]
    }

    public func status(of path: String) -> NoteSyncStatus {
        statuses()[PathKey(path)] ?? .synced
    }

    // MARK: pending push

    public func pendingPush() -> PendingPush? {
        try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pending_push WHERE id = 1").map {
                PendingPush(commit: $0["commit_sha"], parent: $0["parent_sha"], planJSON: $0["plan_json"])
            }
        }
    }

    func setPendingPush(_ p: PendingPush) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO pending_push(id, commit_sha, parent_sha, plan_json) VALUES(1,?,?,?)",
                           arguments: [p.commit, p.parent, p.planJSON])
        }
    }

    /// The commit will never land: its ops are ordinary outbox ops again.
    func clearPendingPush() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM pending_push")
            try db.execute(sql: "UPDATE outbox SET in_flight = 0 WHERE in_flight = 1")
        }
    }

    public func close() throws { try queue.close() }
}
