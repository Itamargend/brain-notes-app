import BrainMerge
import Foundation
import GRDB
import os

enum Log {
    /// Paths, titles and text always use `privacy: .private`. No print statements anywhere in this package.
    static let store = Logger(subsystem: "com.itamargendelman.brainnotes", category: "store")
    static let sync = Logger(subsystem: "com.itamargendelman.brainnotes", category: "sync")
}

/// The device's copy of one repo: note files, journal and index, and the local operations on them.
/// A save is a local atomic write plus one journal transaction; a commit happens later, in the engine.
public final class NoteStore: @unchecked Sendable {
    public let root: URL
    public let files: FileStore
    public let journal: Journal
    public let index: SearchIndex
    let now: @Sendable () -> Date
    let newId: @Sendable () -> String

    /// Layout under `root` (`Brain/<repoId>`): `files/`, `journal.sqlite`, `index/index.sqlite`.
    public init(root: URL, deviceLabel: String = "device",
                now: @escaping @Sendable () -> Date = { Date() },
                newId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) throws {
        self.root = root
        self.now = now
        self.newId = newId
        files = FileStore(root: root)
        try files.prepare()
        journal = try Journal(path: root.appendingPathComponent("journal.sqlite").path)
        let indexDir = root.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        FileStore.protectAndExclude(indexDir)
        index = try SearchIndex(path: indexDir.appendingPathComponent("index.sqlite").path)
        if journal.meta(Journal.Key.device) == nil {
            try journal.setMeta(Journal.Key.device, deviceLabel + "-" + String(newId().prefix(6)))
        }
    }

    public var device: String { journal.meta(Journal.Key.device) ?? "device" }

    // MARK: read

    /// The current text of a note: the file, or the outbox copy if the file is gone (restored from a backup).
    public func read(_ path: String) throws -> String? {
        if let text = try files.readText(path) { return text }
        return journal.outbox().first { sameBytes($0.path, path) }?.content
    }

    public func status(of path: String) -> NoteSyncStatus { journal.status(of: path) }

    // MARK: save

    /// Saves a note: atomic file write and journal update in one transaction.
    ///
    /// `editingFrom` is the text this edit started from. It matters when a sync moved the note while the
    /// editor still held older text: that older text is then the merge base, so the sync's changes merge
    /// with the edit instead of being overwritten by it. Returns the note's path, which can change for a
    /// note that was never pushed when its first line changes.
    @discardableResult
    public func save(path: String, text: String, editingFrom: String? = nil) throws -> String {
        try save(path: path, text: text, editingFrom: editingFrom, updateIndex: true)
    }

    /// The text is safe when the journal transaction commits; the index update comes after it.
    func save(path: String, text: String, editingFrom: String?, updateIndex: Bool) throws -> String {
        let time = now()
        var finalPath = path
        var extraCopy: String?
        let changed: Bool = try journal.queue.write { db in
            var row = try Journal.file(db, path) ?? FileRow(path: path, blobSha: nil)
            let op = try Journal.op(db, path: path)
            if let c = op?.content, sameBytes(c, text) { return false }
            let disk = try files.readText(path)
            if op == nil, let disk, sameBytes(disk, text) { return false }

            if !row.dirty {
                row.dirty = true
                row.baseText = editingFrom ?? disk
            } else if let editingFrom, let disk, !sameBytes(editingFrom, disk) {
                // The note moved under an editor while it was dirty, for instance from a second window.
                // The other text must not vanish: keep it as a copy next to this save.
                extraCopy = disk
            }

            let kind: OpKind
            switch op?.kind {
            case .create?: kind = row.blobSha == nil ? .create : .edit
            case .edit?: kind = .edit
            case .delete?, nil: kind = row.blobSha == nil ? .create : .edit
            }
            let opTime = isoTime(time)
            try Journal.upsertOp(db, path: path, kind: kind, content: text, newId: newId(), time: opTime)

            // A note that was never pushed follows its first line; nothing on GitHub links to it yet.
            if kind == .create, op?.inFlight != true, row.blobSha == nil, op != nil {
                let folder = SearchIndex.folder(of: path)
                let wanted = try Self.notePath(db, folder: folder, text: text, excluding: path)
                if !sameBytes(wanted, path) {
                    try Journal.removeFile(db, path)
                    try db.execute(sql: "UPDATE outbox SET path = ? WHERE path = ?", arguments: [wanted, path])
                    try db.execute(sql: "UPDATE attention SET path = ? WHERE path = ?", arguments: [wanted, path])
                    try files.remove(path)
                    row.path = wanted
                    finalPath = wanted
                }
            }

            row.modified = time
            try files.write(row.path, text)
            let st = files.stat(row.path)
            row.diskSize = st?.size
            row.diskMtime = st?.mtime
            try Journal.putFile(db, row)
            return true
        }
        guard changed else { return finalPath }
        if !sameBytes(finalPath, path) { try? index.remove(path: path) }
        if updateIndex { reindex(finalPath, text: text, modified: time) }
        if let extraCopy {
            _ = try? createCopy(of: path, text: extraCopy)
        }
        return finalPath
    }

    /// New note: named from its first line, in `folder` or `_inbox`, clear of any clash on this device.
    public func createNote(folder: String?, text: String) throws -> String {
        let dest = folder ?? PathPolicy.inboxFolder
        let path = try journal.queue.read { db in try Self.notePath(db, folder: dest, text: text, excluding: nil) }
        return try save(path: path, text: text)
    }

    /// Folder plus a file name from the first line, respelled to existing folders and free of clashes.
    static func notePath(_ db: Database, folder: String, text: String, excluding: String?) throws -> String {
        let name = PathPolicy.fileName(fromFirstLine: NoteText.firstLine(of: text))
        var all = try String.fetchAll(db, sql: "SELECT path FROM files")
        if let excluding { all.removeAll { sameBytes($0, excluding) } }
        let tree = PathIndex(all)
        let wanted = tree.respell(nfc((folder.isEmpty ? "" : folder + "/") + name + ".md"))
        var path = freePath(wanted, tree)
        if checkPath(path) != nil || tree.clash(path, strict: true) != nil {
            path = freePath(tree.respell(PathPolicy.inboxFolder + "/Untitled.md"), tree)
        }
        return path
    }

    /// Keep a text as a new note in `_inbox`, with the conflict header, so it cannot be lost.
    func createCopy(of original: String, text: String) throws -> String {
        let stamp = try copyStamp(isoTime(now()))
        let slug = dropMd(nfc(original)).replacingOccurrences(of: "/", with: "-")
        let header = copyHeader(original, device: device, time: isoTime(now()))
        let path = try journal.queue.read { db -> String in
            let tree = PathIndex(try String.fetchAll(db, sql: "SELECT path FROM files"))
            return freePath(tree.respell("\(PathPolicy.inboxFolder)/conflict-\(slug)-\(stamp).md"), tree)
        }
        return try save(path: path, text: header + text)
    }

    private func dropMd(_ s: String) -> String { s.lowercased().hasSuffix(".md") ? String(s.dropLast(3)) : s }

    // MARK: delete

    /// Delete: the file goes now, the note moves to `_trash` on GitHub in the next commit.
    /// A note that never reached GitHub is simply gone: it has no history to keep.
    public func delete(path: String) throws {
        let time = now()
        try journal.queue.write { db in
            var row = try Journal.file(db, path) ?? FileRow(path: path, blobSha: nil)
            let op = try Journal.op(db, path: path)
            if row.blobSha == nil, let op, op.kind == .create, !op.inFlight {
                try Journal.removeOp(db, seq: op.seq)
                try Journal.removeFile(db, path)
                try Journal.resolvePushProblems(db, path: path)
            } else {
                if !row.dirty {
                    row.dirty = true
                    row.baseText = try files.readText(path)
                }
                try Journal.upsertOp(db, path: path, kind: .delete, content: nil, newId: newId(), time: isoTime(time))
                row.diskSize = nil
                row.diskMtime = nil
                row.modified = time
                try Journal.putFile(db, row)
            }
            try files.remove(path)
        }
        try? index.remove(path: path)
    }

    // MARK: index

    func reindex(_ path: String, text: String, modified: Date?) {
        guard PathPolicy.isVisible(path) else { return }
        do {
            try index.upsert(path: path, text: text, modified: modified)
        } catch {
            // Derived data, and unwritable while locked: the next launch repairs it.
            Log.store.error("index update failed")
        }
    }

    /// Bring the index in line with the files for these paths.
    func reindex(_ paths: [String]) {
        for p in paths {
            guard PathPolicy.isVisible(p) else { continue }
            let text = try? files.readText(p)
            if let text {
                reindex(p, text: text, modified: journal.file(p)?.modified)
            } else {
                try? index.remove(path: p)
            }
        }
    }

    /// Full rebuild from the files, in batches, so lists fill while it runs.
    public func rebuildIndex(progress: (@Sendable (Int, Int) -> Void)? = nil) throws {
        let rows = journal.allFiles().filter { $0.local && PathPolicy.isVisible($0.path) }
        try index.clear()
        var done = 0
        var batch: [(path: String, text: String, modified: Date?)] = []
        func flush() throws {
            try index.add(batch)
            done += batch.count
            batch.removeAll(keepingCapacity: true)
            progress?(done, rows.count)
        }
        for row in rows {
            // Unreadable notes (not UTF-8) stay out of the index; a locked device throws out of the rebuild.
            do {
                if let text = try files.readText(row.path) { batch.append((row.path, text, row.modified)) }
            } catch FileStoreError.notText {
                continue
            }
            if batch.count >= 100 { try flush() }
        }
        try flush()
        if let base = journal.baseCommit { try index.setStamp(base) }
    }

    func markIndexCurrent() {
        if let base = journal.baseCommit { try? index.setStamp(base) }
    }

    /// Dates for the note list: only dates change, so no text is read.
    func applyDates(_ dates: [PathDate]) throws {
        try journal.queue.write { db in
            for d in dates {
                try db.execute(sql: "UPDATE files SET modified = ? WHERE path = ?", arguments: [d.date.timeIntervalSince1970, d.path])
            }
        }
        try index.setModified(dates.map { ($0.path, $0.date) })
    }

    // MARK: launch repair

    public struct ReconcileResult: Sendable, Equatable {
        /// Files whose hash differed from the journal: recorded as local edits, never overwritten.
        public var edited: [String] = []
        /// Files that should exist but do not: the engine downloads them again. Never treated as deletes.
        public var missing: [String] = []
    }

    /// Runs after launch, off the main thread. Compares every file with the journal by size and date,
    /// hashing only on a difference. A file that differs from the journal is a local edit (a kill between
    /// file write and commit, or a restore), not something to overwrite. A read error (device locked)
    /// stops the pass without changing anything.
    @discardableResult
    public func reconcile() throws -> ReconcileResult {
        var result = ReconcileResult()
        let rows = journal.allFiles().filter(\.local)
        let ops = journal.outbox()
        var opsByPath: [PathKey: OutboxOp] = [:]
        for op in ops { opsByPath[PathKey(op.path)] = op }
        let time = now()
        for row in rows {
            let st = files.stat(row.path)
            if let op = opsByPath[PathKey(row.path)] {
                switch (op.kind, st) {
                case (.delete, _):
                    continue
                case (_, nil):
                    // Files are not in a backup, the outbox is: the unsynced text comes back from it.
                    if let c = op.content { try writeBack(row, text: c) }
                case let (_, st?):
                    if st.size == row.diskSize, st.mtime == row.diskMtime { continue }
                    guard let text = try files.readText(row.path) else { continue }
                    if let c = op.content, sameBytes(c, text) {
                        try writeBack(row, text: nil)
                    } else {
                        try save(path: row.path, text: text)
                        result.edited.append(row.path)
                    }
                }
                continue
            }
            guard let st else {
                if row.blobSha != nil { result.missing.append(row.path) }
                continue
            }
            if st.size == row.diskSize, st.mtime == row.diskMtime { continue }
            guard let data = try files.readData(row.path) else { continue }
            if row.blobSha == GitBlob.sha(data) {
                try writeBack(row, text: nil)
                continue
            }
            guard let text = decodeNote(data) else { continue }
            // A clean note that differs: a local edit whose merge base the engine fetches from GitHub.
            try journal.queue.write { db in
                var r = row
                r.dirty = true
                r.baseText = nil
                r.modified = time
                r.diskSize = st.size
                r.diskMtime = st.mtime
                try Journal.putFile(db, r)
                try Journal.upsertOp(db, path: row.path, kind: row.blobSha == nil ? .create : .edit, content: text, newId: newId(), time: isoTime(time))
            }
            reindex(row.path, text: text, modified: time)
            result.edited.append(row.path)
        }
        // A kill between the journal commit and the index update loses at most the outbox's notes.
        reindex(journal.outbox().filter { $0.kind != .delete }.map(\.path))
        return result
    }

    /// Record the file's current size and date, writing `text` first when given.
    private func writeBack(_ row: FileRow, text: String?) throws {
        if let text { try files.write(row.path, text) }
        let st = files.stat(row.path)
        try journal.queue.write { db in
            var r = row
            r.diskSize = st?.size
            r.diskMtime = st?.mtime
            try Journal.putFile(db, r)
        }
    }

    /// Repairs the index when it was reset or fell behind the journal. Off the main thread.
    public func repairIndexIfNeeded() throws {
        if index.wasReset || index.stamp() != journal.baseCommit {
            try rebuildIndex()
        }
    }

    // MARK: wipe

    /// Sign out and wipe: closes the databases and removes every note, journal and index file of this repo.
    public func wipe() throws {
        try journal.close()
        try index.close()
        files.wipe()
    }
}

// MARK: - Needs attention

/// What an item offers. Nothing here deletes text without a copy: a conflict copy that is no longer needed
/// moves to `_trash` through the normal delete, and a replaced version stays in the copy.
public enum AttentionChoice: Sendable, Equatable {
    /// Both versions stay where they are.
    case keepBoth
    /// My version goes into the note; the note's previous text takes its place in the copy.
    case useMine
    /// GitHub's version stays in the note; the copy moves to `_trash`.
    case useTheirs
    /// The note was deleted elsewhere: bring it back at its path with my text.
    case restore
    /// My delete was skipped because GitHub changed the note: delete it anyway (moves to `_trash`).
    case deleteAnyway
    /// Try the blocked or rejected change again.
    case retry
}

public struct AttentionTexts: Sendable, Equatable {
    public var mine: String?
    public var theirs: String?
}

extension NoteStore {
    public func openAttention() async -> [AttentionItem] {
        (try? await journal.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attention WHERE resolved = 0 ORDER BY id DESC").map(Journal.attentionRow)
        }) ?? []
    }

    /// Both sides of an item, for the side by side view.
    public func texts(for item: AttentionItem) -> AttentionTexts {
        let current = (try? read(item.path)) ?? nil
        if let copyPath = item.copyPath, let copy = (try? read(copyPath)) ?? nil {
            return AttentionTexts(mine: ConflictCopy(text: copy)?.mine ?? copy, theirs: current)
        }
        return AttentionTexts(mine: journal.outbox().first { sameBytes($0.path, item.path) }?.content, theirs: current)
    }

    public func resolve(_ item: AttentionItem, _ choice: AttentionChoice) throws {
        switch choice {
        case .keepBoth:
            break
        case .useMine:
            guard let copyPath = item.copyPath, let copy = try read(copyPath), let parsed = ConflictCopy(text: copy) else { break }
            let previous = try read(item.path)
            try save(path: item.path, text: parsed.mine, editingFrom: previous)
            let (header, _) = NoteText.split(copy)
            try save(path: copyPath, text: header + (previous ?? ""))
        case .useTheirs:
            if let copyPath = item.copyPath { try delete(path: copyPath) }
        case .restore:
            guard let copyPath = item.copyPath, let copy = try read(copyPath), let parsed = ConflictCopy(text: copy) else { break }
            try save(path: item.path, text: parsed.mine)
            try delete(path: copyPath)
        case .deleteAnyway:
            try delete(path: item.path)
        case .retry:
            try journal.queue.write { db in
                try db.execute(sql: "UPDATE outbox SET parked = 0 WHERE path = ?", arguments: [item.path])
            }
        }
        try journal.resolveAttention(id: item.id)
    }
}
