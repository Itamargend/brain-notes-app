import BrainMerge
import Foundation
import GRDB
#if canImport(os)
import os
#endif

enum Log {
    /// Paths, titles and text always use `privacy: .private`. No print statements anywhere in this package.
    #if canImport(os)
    static let store = Logger(subsystem: "com.itamargendelman.brainnotes", category: "store")
    static let sync = Logger(subsystem: "com.itamargendelman.brainnotes", category: "sync")
    #else
    static let store = QuietLog()
    static let sync = QuietLog()
    #endif
}

#if !canImport(os)
/// Where there is no unified logging (Linux), messages are dropped: the package never prints. Same call shape as
/// `Logger`, `privacy:` included, so the call sites need no guards.
struct QuietLog: Sendable {
    enum Privacy { case auto, `public`, `private` }

    struct Message: ExpressibleByStringInterpolation {
        struct StringInterpolation: StringInterpolationProtocol {
            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ literal: String) {}
            mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: Privacy = .auto) {}
        }
        init(stringLiteral value: String) {}
        init(stringInterpolation: StringInterpolation) {}
    }

    func error(_ message: Message) {}
    func notice(_ message: Message) {}
}
#endif

/// The device's copy of one repo: note files, journal and index, and the local operations on them.
/// A save is a local atomic write plus one journal transaction; a commit happens later, in the engine.
public final class NoteStore: @unchecked Sendable {
    public let root: URL
    public let files: FileStore
    public let journal: Journal
    public let index: SearchIndex
    let now: @Sendable () -> Date
    let newId: @Sendable () -> String

    /// Layout under `root` (`Brain/<repoId>`): `files/`, `files.staging/` during first sync, `journal.sqlite` and the
    /// files SQLite makes next to it, `index/index.sqlite`, `pins.json`. Nothing of the repo lives anywhere else.
    ///
    /// The whole of `root` is out of backups, on iOS (iCloud and device backups) and on a Mac (Time Machine), every time
    /// a store opens it, so a folder made by an earlier version gets the flag too. The journal holds unsynced text,
    /// including notes the secret scan kept from GitHub; it must not travel in a backup any more than the notes do. A
    /// restored device signs in and downloads the notes again; text that was not synced when the backup was made is not
    /// in it.
    public init(root: URL, deviceLabel: String = "device",
                now: @escaping @Sendable () -> Date = { Date() },
                newId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) throws {
        self.root = root
        self.now = now
        self.newId = newId
        files = FileStore(root: root)
        try files.prepare()
        FileStore.excludeFromBackup(root)
        #if os(iOS)
        // Complete until the first unlock, not complete: the background flush must still read and write the journal in
        // the seconds after the screen locks. Note files and the index are complete (`protectAndExclude`). Files made
        // here later (SQLite's rollback journal, pins.json) take this folder's class.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
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

    /// The current text of a note: the file, or the outbox copy if the file is gone.
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

    /// Thrown by a `createOnly` save when its path is already a note or a file on this device.
    struct PathTaken: Error, Equatable {}

    /// The text is safe when the journal transaction commits; the index update comes after it.
    ///
    /// `createOnly` is for notes that must be new, such as Add to Brain captures. The path was picked in an
    /// earlier read, so a second capture may have taken it since; a plain save would then treat this text as an
    /// edit of that note and replace its unsynced text. With `createOnly`, the check and the write are one
    /// transaction, and a taken path throws `PathTaken` with nothing written.
    func save(path requested: String, text: String, editingFrom: String?, updateIndex: Bool, createOnly: Bool = false) throws -> String {
        let time = now()
        var finalPath = requested
        var extraCopy: String?
        let changed: Bool = try journal.queue.write { db in
            if createOnly {
                if try Journal.file(db, requested) != nil || Self.fileOwner(db, of: requested) != nil || files.exists(requested) {
                    throw PathTaken()
                }
            }
            // GitHub changed this note's spelling by case alone while an editor held the old one. Here both
            // spellings are one file, so the save belongs to the note that owns it, and merges with it.
            var path = requested
            if try Journal.file(db, path) == nil, let owner = try Self.fileOwner(db, of: path) {
                path = owner
                finalPath = owner
            }
            var row = try Journal.file(db, path) ?? FileRow(path: path, blobSha: nil)
            let op = try Journal.op(db, path: path)
            if let c = op?.content, sameBytes(c, text) { return false }
            let disk = try files.readText(path)
            if op == nil, let disk, sameBytes(disk, text) { return false }

            if !row.dirty {
                row.dirty = true
                row.baseText = editingFrom ?? disk
            } else if op?.kind == .delete {
                // Deleted while an editor stayed open, and now saved from it: the merge base is what that
                // editor started from, not the text at the delete.
                if let editingFrom { row.baseText = editingFrom }
            } else if let editingFrom, let disk, !sameBytes(editingFrom, disk) {
                // The note moved under an editor while it was dirty, for instance from a second window.
                // The other text must not vanish: keep it as a copy next to this save.
                extraCopy = disk
            }

            let kind: OpKind
            switch op?.kind {
            case .create?:
                // A note I created stays a create until it lands, even if GitHub got the same path meanwhile:
                // it has no merge base, so the planner makes a copy instead of overwriting the other note.
                kind = .create
            case .edit?:
                kind = .edit
            case .delete?, nil:
                kind = row.blobSha == nil ? .create : .edit
            }
            let opTime = isoTime(time)
            try Journal.upsertOp(db, path: path, kind: kind, content: text, newId: newId(), time: opTime)

            // A note that was never pushed follows its first line; nothing on GitHub links to it yet.
            if kind == .create, op?.inFlight != true, row.blobSha == nil, op != nil, !FolderPlaceholder.isPlaceholder(path) {
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
        if !sameBytes(finalPath, requested) { try? index.remove(path: requested) }
        if updateIndex { reindex(finalPath, text: text, modified: time) }
        if let extraCopy { _ = try createCopy(of: finalPath, text: extraCopy) }
        return finalPath
    }

    /// The note that holds this path's file on this disk, under another spelling.
    private static func fileOwner(_ db: Database, of path: String) throws -> String? {
        let key = foldKey(path)
        return try String.fetchAll(db, sql: "SELECT path FROM files WHERE local = 1").first { sameBytes(foldKey($0), key) }
    }

    /// New note: named from its first line, in `folder` or `_inbox`, clear of any clash on this device.
    public func createNote(folder: String?, text: String) throws -> String {
        let dest = folder ?? PathPolicy.inboxFolder
        let path = try journal.queue.read { db in try Self.notePath(db, folder: dest, text: text, excluding: nil) }
        return try save(path: path, text: text)
    }

    /// Moves an existing note to `folder` (`""` for the root level) locally in the journal so it works offline, in demo mode,
    /// and with unsynced notes, preserving YAML frontmatter (`pinned: true`) and avoiding filename collisions.
    public func moveNoteLocally(_ path: String, toFolder folder: String) throws -> String {
        let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let currentFolder = SearchIndex.folder(of: path)
        if sameBytes(currentFolder, cleanFolder) { return path }
        if !cleanFolder.isEmpty, !PathPolicy.isInbox(cleanFolder), !PathPolicy.canHoldNotes(folder: cleanFolder) {
            throw FolderProblem.notAllowed
        }
        guard let text = try read(path) else { return path }
        let stem = NoteText.fileStem(path)
        let newPath = try journal.queue.read { db -> String in
            var all = try String.fetchAll(db, sql: "SELECT path FROM files")
            all.removeAll { sameBytes($0, path) }
            let tree = PathIndex(all)
            let safeStem = PathPolicy.fileName(fromFirstLine: stem)
            let wanted = tree.respell(nfc((cleanFolder.isEmpty ? "" : cleanFolder + "/") + safeStem + ".md"))
            var candidate = freePath(wanted, tree)
            if checkPath(candidate) != nil || tree.clash(candidate, strict: true) != nil {
                candidate = try Self.notePath(db, folder: cleanFolder, text: text, excluding: path)
            }
            return candidate
        }
        let savedPath = try save(path: newPath, text: text)
        try delete(path: path)
        return savedPath
    }

    /// Creates a clean unpinned copy of `path` in the same folder (`<stem> copy.md`, `<stem> copy 2.md`, …) and returns its path.
    public func duplicateNote(_ path: String) throws -> String? {
        guard let raw = try read(path) else { return nil }
        let unpinned = NoteText.settingPinned(false, in: raw)
        let clean = ConflictCopy(text: unpinned)?.mine ?? unpinned
        let folder = SearchIndex.folder(of: path)
        let stem = NoteText.fileStem(path)
        let newPath = try journal.queue.read { db -> String in
            let all = try String.fetchAll(db, sql: "SELECT path FROM files")
            let tree = PathIndex(all)
            let safeCopyStem = PathPolicy.fileName(fromFirstLine: stem + " copy")
            let wanted = tree.respell(nfc((folder.isEmpty ? "" : folder + "/") + safeCopyStem + ".md"))
            if let numbered = try? MovePlanner.free(wanted, tree, isNote: true) {
                return numbered
            }
            var fallback = freePath(wanted, tree)
            if checkPath(fallback) != nil || tree.clash(fallback, strict: true) != nil {
                fallback = freePath(tree.respell(PathPolicy.inboxFolder + "/Untitled copy.md"), tree)
            }
            return fallback
        }
        return try save(path: newPath, text: clean)
    }

    /// Moves a folder (notes + empty subfolders) into `parent` (`""` for top level) locally via the journal.
    @discardableResult
    public func moveFolderLocally(_ folder: String, into parent: String) throws -> String {
        let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanParent = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanFolder.isEmpty, !PathPolicy.isInbox(cleanFolder), PathPolicy.isVisible(cleanFolder + "/x.md") else {
            throw FolderProblem.notAllowed
        }
        if !cleanParent.isEmpty, !PathPolicy.canHoldNotes(folder: cleanParent) {
            throw FolderProblem.notAllowed
        }
        if !cleanParent.isEmpty, MovePaths.isSameOrInside(cleanParent, cleanFolder) {
            throw FolderProblem.notAllowed
        }
        if sameBytes(foldKey(MovePaths.parent(cleanFolder)), foldKey(cleanParent)) {
            return cleanFolder
        }
        let empty = files.emptyFolders()
        let allPaths = try journal.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT f.path FROM files f LEFT JOIN outbox o ON o.path = f.path WHERE o.kind IS NULL OR o.kind != ?",
                arguments: [OpKind.delete.rawValue]
            )
        }
        let tree = PathIndex(allPaths + empty.map { $0 + "/\u{0}" })
        let wanted = tree.respell(nfc(MovePaths.join(cleanParent, MovePaths.lastSegment(cleanFolder))))
        guard let target = try? MovePlanner.free(wanted, tree, isNote: false) else {
            throw FolderProblem.notAllowed
        }
        try relocateFolderContentsLocally(from: cleanFolder, to: target, allPaths: allPaths, emptyFolders: empty)
        return target
    }

    /// Renames `folder` inside its current parent directory to `typedName` locally via the journal.
    @discardableResult
    public func renameFolderLocally(_ folder: String, to typedName: String) throws -> String {
        let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanFolder.isEmpty, !PathPolicy.isInbox(cleanFolder), PathPolicy.isVisible(cleanFolder + "/x.md") else {
            throw FolderProblem.notAllowed
        }
        guard let cleanName = PathPolicy.folderName(fromTyped: typedName) else {
            throw FolderProblem.noName
        }
        let parent = MovePaths.parent(cleanFolder)
        let rawTarget = MovePaths.join(parent, cleanName)
        if sameBytes(rawTarget, cleanFolder) { return cleanFolder }
        guard PathPolicy.canHoldNotes(folder: rawTarget) else {
            throw FolderProblem.notAllowed
        }
        let empty = files.emptyFolders()
        let allPaths = try journal.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT f.path FROM files f LEFT JOIN outbox o ON o.path = f.path WHERE o.kind IS NULL OR o.kind != ?",
                arguments: [OpKind.delete.rawValue]
            )
        }
        let tree = PathIndex(allPaths + empty.map { $0 + "/x.md" })
        let wanted = String(decoding: tree.respell(nfc(rawTarget) + "/x.md").utf8.dropLast(5), as: UTF8.self)
        if tree.takenByAny(wanted) || files.exists(wanted) {
            throw FolderProblem.alreadyExists
        }
        if tree.clash(wanted + "/x.md", strict: true) != nil {
            throw FolderProblem.notAllowed
        }
        try relocateFolderContentsLocally(from: cleanFolder, to: wanted, allPaths: allPaths, emptyFolders: empty)
        return wanted
    }

    /// Removes an empty folder (and any `_folder.md` placeholder files inside it) from disk and the journal.
    public func removeEmptyOrPlaceholderFolder(_ folder: String) throws {
        let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanFolder.isEmpty, !PathPolicy.isInbox(cleanFolder) else { return }
        let prefix = cleanFolder + "/"
        let (allPaths, deletingKeys) = try journal.queue.read { db -> ([String], Set<String>) in
            let files = try String.fetchAll(db, sql: "SELECT path FROM files")
            let deletes = try String.fetchAll(db, sql: "SELECT path FROM outbox WHERE kind = ?", arguments: [OpKind.delete.rawValue])
            return (files, Set(deletes.map(foldKey)))
        }
        let inside = allPaths.filter { $0.hasPrefix(prefix) && !deletingKeys.contains(foldKey($0)) }
        // Only auto-delete hidden placeholder files here; visible notes go through `requestDelete` for Undo.
        guard !inside.contains(where: { PathPolicy.isVisible($0) && !FolderPlaceholder.isPlaceholder($0) }) else { return }
        for p in inside {
            try? delete(path: p)
        }
        let dir = try files.url(for: cleanFolder)
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        // Tidy empty parent directories up to `filesRoot`.
        var parentDir = dir.deletingLastPathComponent()
        let rootPath = files.filesRoot.standardizedFileURL.path
        while parentDir.standardizedFileURL.path.count > rootPath.count {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: parentDir.path)) ?? ["x"]
            if items.isEmpty { try? FileManager.default.removeItem(at: parentDir) } else { break }
            parentDir = parentDir.deletingLastPathComponent()
        }
    }

    private func relocateFolderContentsLocally(from source: String, to target: String, allPaths: [String], emptyFolders: [String]) throws {
        let prefix = source + "/"
        let notePaths = allPaths.filter { $0.hasPrefix(prefix) }
        let empties = emptyFolders.filter { sameBytes($0, source) || $0.hasPrefix(prefix) }
        for oldPath in notePaths {
            guard let text = try read(oldPath) else { continue }
            let rebased = MovePaths.rebase(oldPath, from: source, to: target)
            _ = try save(path: rebased, text: text)
            try delete(path: oldPath)
        }
        for empty in empties {
            let rebased = MovePaths.rebase(empty, from: source, to: target)
            try? files.createFolder(rebased)
        }
        if notePaths.isEmpty, empties.isEmpty {
            try files.createFolder(target)
        }
        try removeEmptyOrPlaceholderFolder(source)
    }

    public enum FolderProblem: Error, Equatable, Sendable {
        case noName
        /// A name the sync rules refuse: `private`, a leading dot or `_`, or one ending in `.md`.
        case notAllowed
        case alreadyExists
    }

    /// A new folder inside `parent` (empty for the top level). It is on disk at once and shows in the lists. It reaches
    /// GitHub with its first note: git has no empty folders, and the sync rules take only `.md` files, so a `.gitkeep`
    /// would never leave this device (`checkPath`). Nothing is queued until then.
    @discardableResult
    public func createFolder(named typed: String, in parent: String) throws -> String {
        guard let name = PathPolicy.folderName(fromTyped: typed) else { throw FolderProblem.noName }
        let wanted = parent.isEmpty ? name : parent + "/" + name
        guard PathPolicy.canHoldNotes(folder: wanted) else { throw FolderProblem.notAllowed }
        // Empty folders count too. An iPhone's disk tells `Ideas` from `ideas`, so asking the disk is not enough.
        let empty = files.emptyFolders().map { $0 + "/x.md" }
        let tree = try journal.queue.read { db in
            let active = try String.fetchAll(
                db,
                sql: "SELECT f.path FROM files f LEFT JOIN outbox o ON o.path = f.path WHERE o.kind IS NULL OR o.kind != ?",
                arguments: [OpKind.delete.rawValue]
            )
            return PathIndex(active + empty)
        }
        // The new folder takes the spelling its parents already have on GitHub.
        let path = String(decoding: tree.respell(wanted + "/x.md").utf8.dropLast(5), as: UTF8.self)
        if tree.takenByAny(path) || files.exists(path) { throw FolderProblem.alreadyExists }
        if tree.clash(path + "/x.md", strict: true) != nil { throw FolderProblem.notAllowed }
        try files.createFolder(path)
        return path
    }

    /// Creates a folder on disk and queues `<folder>/_folder.md` so the folder syncs immediately to GitHub
    /// even before any note is added inside it.
    @discardableResult
    public func createSyncedFolder(named typed: String, in parent: String) throws -> String {
        let folder = try createFolder(named: typed, in: parent)
        let placeholder = FolderPlaceholder.path(in: folder)
        if PathPolicy.isSyncable(placeholder), FileStore.nameFits(placeholder), (try? read(placeholder)) == nil {
            _ = try save(path: placeholder, text: FolderPlaceholder.text, editingFrom: nil, updateIndex: false)
        }
        return folder
    }

    /// Queues `<folder>/_folder.md` for any visible local empty folder on disk that has no active tracked file yet
    /// (such as empty folders or subfolders created offline or before Build 14).
    @discardableResult
    public func ensureEmptyFoldersHavePlaceholders() throws -> [String] {
        let empties = files.emptyFolders()
        guard !empties.isEmpty else { return [] }
        let activeKeys = try journal.queue.read { db -> Set<String> in
            let paths = try String.fetchAll(
                db,
                sql: "SELECT f.path FROM files f LEFT JOIN outbox o ON o.path = f.path WHERE o.kind IS NULL OR o.kind != ?",
                arguments: [OpKind.delete.rawValue]
            )
            return Set(paths.map(foldKey))
        }
        var added: [String] = []
        for folder in empties where PathPolicy.canHoldNotes(folder: folder) && !PathPolicy.isInbox(folder) {
            let prefix = foldKey(folder) + "/"
            if activeKeys.contains(where: { $0.hasPrefix(prefix) }) { continue }
            let placeholder = FolderPlaceholder.path(in: folder)
            guard PathPolicy.isSyncable(placeholder), FileStore.nameFits(placeholder) else { continue }
            _ = try save(path: placeholder, text: FolderPlaceholder.text, editingFrom: nil, updateIndex: false)
            added.append(placeholder)
        }
        return added
    }

    /// Folder paths backed by a local `_folder.md` placeholder that is not pending deletion.
    public func activePlaceholderFolders() -> [String] {
        let activePaths = (try? journal.queue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT f.path FROM files f LEFT JOIN outbox o ON o.path = f.path WHERE f.local = 1 AND (o.kind IS NULL OR o.kind != ?)",
                arguments: [OpKind.delete.rawValue]
            )
        }) ?? []
        let visible = activePaths.filter(PathPolicy.isVisible)
        return FolderPlaceholder.listing(visible).folders
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
        let header = copyHeader(original, device: device, time: isoTime(now()))
        let path = try journal.queue.read { db -> String in
            let tree = PathIndex(try String.fetchAll(db, sql: "SELECT path FROM files"))
            return freePath(tree.respell("\(PathPolicy.inboxFolder)/conflict-\(Self.slug(original))-\(stamp).md"), tree)
        }
        return try save(path: path, text: header + text)
    }

    /// A path as part of one file name, its end kept: a copy made here must always fit on the disk. The planner's
    /// conflict copies use the same slug (`copySlug`, merge spec 6.1).
    static func slug(_ path: String) -> String { copySlug(path) }

    // MARK: delete

    /// Delete: the file goes now, the note moves to `_trash` on GitHub in the next commit.
    /// A note that never reached GitHub is simply gone: it has no history to keep. If GitHub got its own
    /// note at that path meanwhile, that one is not mine to delete: the device goes back to it.
    /// Text typed but not yet pushed goes to `_trash` too, next to the version GitHub has.
    public func delete(path: String) throws {
        let time = now()
        // The copy comes first: if it cannot be made, nothing has been deleted yet.
        if let op = journal.outbox().first(where: { sameBytes($0.path, path) }), op.kind == .edit,
           let text = op.content, !sameDoc(text, journal.file(path)?.baseText) {
            try keepInTrash(path, text: text, time: time)
        }
        try journal.queue.write { db in
            var row = try Journal.file(db, path) ?? FileRow(path: path, blobSha: nil)
            let op = try Journal.op(db, path: path)
            if let op, op.kind == .create, !op.inFlight {
                try Journal.removeOp(db, seq: op.seq)
                try Journal.resolvePushProblems(db, path: path)
                if row.blobSha == nil {
                    try Journal.removeFile(db, path)
                } else {
                    row.dirty = false
                    row.baseText = nil
                    row.diskSize = nil
                    row.diskMtime = nil
                    try Journal.putFile(db, row)
                }
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

    private func keepInTrash(_ original: String, text: String, time: Date) throws {
        let stamp = try copyStamp(isoTime(time))
        let path = try journal.queue.read { db -> String in
            let tree = PathIndex(try String.fetchAll(db, sql: "SELECT path FROM files"))
            return freePath(tree.respell("_trash/unsynced-\(Self.slug(original))-\(stamp).md"), tree)
        }
        try save(path: path, text: text)
    }

    // MARK: index

    func reindex(_ path: String, text: String, modified: Date?) {
        guard PathPolicy.isVisible(path), !FolderPlaceholder.isPlaceholder(path) else {
            try? index.remove(path: path)
            return
        }
        do {
            try index.upsert(path: path, text: text, modified: modified, created: files.creationDate(path) ?? modified)
        } catch {
            // Derived data, and unwritable while locked: the next launch repairs it.
            Log.store.error("index update failed")
        }
    }

    /// Bring the index in line with the files for these paths.
    func reindex(_ paths: [String]) {
        for p in paths {
            guard PathPolicy.isVisible(p), !FolderPlaceholder.isPlaceholder(p) else {
                try? index.remove(path: p)
                continue
            }
            // The row decides, not the disk: a removed spelling still opens its twin's file on a
            // case-insensitive disk, and that would leave a ghost entry in the lists.
            if let row = journal.file(p), row.local, let text = (try? files.readText(p)) ?? nil {
                reindex(p, text: text, modified: row.modified)
            } else {
                try? index.remove(path: p)
            }
        }
    }

    /// Full rebuild from the files, in batches, so lists fill while it runs.
    public func rebuildIndex(progress: (@Sendable (Int, Int) -> Void)? = nil) throws {
        try Task.checkCancellation()
        let rows = journal.allFiles().filter {
            $0.local && PathPolicy.isVisible($0.path) && !FolderPlaceholder.isPlaceholder($0.path)
        }
        try index.clear()
        var done = 0
        var batch: [(path: String, text: String, modified: Date?, created: Date?)] = []
        func flush() throws {
            try Task.checkCancellation()
            try index.addWithCreationDates(batch)
            done += batch.count
            batch.removeAll(keepingCapacity: true)
            progress?(done, rows.count)
        }
        for row in rows {
            try Task.checkCancellation()
            // Unreadable notes (not UTF-8) stay out of the index; a locked device throws out of the rebuild.
            do {
                if let text = try files.readText(row.path) {
                    batch.append((row.path, text, row.modified, files.creationDate(row.path) ?? row.modified))
                }
            } catch FileStoreError.notText {
                continue
            }
            if batch.count >= 100 { try flush() }
        }
        try flush()
        try index.setStamp(journal.baseCommit)
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
        try Task.checkCancellation()
        var result = ReconcileResult()
        // A kill between first sync's folder swap and its journal commit: the files are GitHub's and the rows
        // are not, so a difference means nothing yet. Put unsynced text back; first sync runs again.
        if journal.meta(Journal.Key.swapping) == "1" {
            for op in journal.outbox() where op.kind != .delete {
                try Task.checkCancellation()
                if let c = op.content { try files.write(op.path, c) }
            }
            return result
        }
        for snapshot in journal.allFiles() where snapshot.local {
            try Task.checkCancellation()
            if let st = files.stat(snapshot.path), st.size == snapshot.diskSize, st.mtime == snapshot.diskMtime { continue }
            try repair(snapshot.path, into: &result)
        }
        try Task.checkCancellation()
        // A kill between the journal commit and the index update loses at most the outbox's notes.
        reindex(journal.outbox().filter { $0.kind != .delete }.map(\.path))
        return result
    }

    /// One file that looks different from its row. Everything is read again inside the transaction: the
    /// note may have been saved since the pass began, and that save must not be undone.
    private func repair(_ path: String, into result: inout ReconcileResult) throws {
        let time = now()
        var missing = false
        var edited: String?
        try journal.queue.write { db in
            guard var row = try Journal.file(db, path), row.local else { return }
            let op = try Journal.op(db, path: path)
            let st = files.stat(path)
            func recordDisk() throws {
                let now = files.stat(path)
                try db.execute(sql: "UPDATE files SET disk_size = ?, disk_mtime = ? WHERE path = ?", arguments: [now?.size, now?.mtime, path])
            }
            if let op {
                if op.kind == .delete { return }
                guard let st else {
                    // The file is gone and the outbox still has its text: the unsynced text comes back from it.
                    if let c = op.content {
                        try files.write(path, c)
                        try recordDisk()
                    }
                    return
                }
                if st.size == row.diskSize, st.mtime == row.diskMtime { return }
                guard let text = try files.readText(path) else { return }
                if let c = op.content, sameBytes(c, text) { return try recordDisk() }
                // The file is older than the journal says it should be: the disk went back (power loss
                // after the commit). The op holds the newer text.
                if let recorded = row.diskMtime, st.mtime < recorded, let c = op.content {
                    try files.write(path, c)
                    return try recordDisk()
                }
                // Newer than the op: a kill between the file write and the journal commit, or a tamper.
                try Journal.upsertOp(db, path: path, kind: op.kind, content: text, newId: newId(), time: isoTime(time))
                row.modified = time
                row.diskSize = st.size
                row.diskMtime = st.mtime
                try Journal.putFile(db, row)
                edited = text
                return
            }
            guard let st else {
                missing = row.blobSha != nil
                return
            }
            if st.size == row.diskSize, st.mtime == row.diskMtime { return }
            guard let data = try files.readData(path) else { return }
            if row.blobSha == GitBlob.sha(data) { return try recordDisk() }
            guard let text = decodeNote(data) else { return }
            // A clean note that differs: a local edit whose merge base the engine fetches from GitHub.
            row.dirty = true
            row.baseText = nil
            row.modified = time
            row.diskSize = st.size
            row.diskMtime = st.mtime
            try Journal.putFile(db, row)
            try Journal.upsertOp(db, path: path, kind: row.blobSha == nil ? .create : .edit, content: text, newId: newId(), time: isoTime(time))
            edited = text
        }
        if missing { result.missing.append(path) }
        if let edited {
            reindex(path, text: edited, modified: time)
            result.edited.append(path)
        }
    }

    /// Repairs the index when it was reset or fell behind the journal. Off the main thread.
    public func repairIndexIfNeeded() throws {
        if index.wasReset || index.stamp() != journal.baseCommit {
            try rebuildIndex()
        }
    }

    // MARK: wipe

    /// Closes the journal and search-index SQLite connections without removing files from disk.
    public func close() {
        try? journal.close()
        try? index.close()
    }

    /// Sign out and wipe: closes the databases and removes every note, journal and index file of this repo.
    /// A database that will not close does not keep the notes on disk: the files go either way. What counts is
    /// whether they are gone, so only a removal that failed throws.
    public func wipe() throws {
        close()
        try files.wipe()
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
    public init(mine: String?, theirs: String?) {
        self.mine = mine
        self.theirs = theirs
    }
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

    /// A choice that needs the conflict copy found none to work with. Nothing was changed, and the item stays open.
    public enum ResolveProblem: Error, Equatable, Sendable {
        /// The copy is not on this device (deleted, or a name this disk can't hold), or no longer reads as a conflict copy.
        case copyUnavailable
    }

    /// Throws `ResolveProblem.copyUnavailable` for Use mine or Restore when the copy can't be read: closing the item
    /// then would look as if the user's version had been used, while nothing was.
    public func resolve(_ item: AttentionItem, _ choice: AttentionChoice) throws {
        switch choice {
        case .keepBoth:
            break
        case .useMine:
            guard let copyPath = item.copyPath, let copy = try read(copyPath), let parsed = ConflictCopy(text: copy) else {
                throw ResolveProblem.copyUnavailable
            }
            let previous = try read(item.path)
            try save(path: item.path, text: parsed.mine, editingFrom: previous)
            let (header, _) = NoteText.split(copy)
            try save(path: copyPath, text: header + (previous ?? ""))
        case .useTheirs:
            // A copy this device could not hold stays on GitHub, where it does no harm.
            if let copyPath = item.copyPath, journal.file(copyPath)?.local != false { try delete(path: copyPath) }
        case .restore:
            guard let copyPath = item.copyPath, let copy = try read(copyPath), let parsed = ConflictCopy(text: copy) else {
                throw ResolveProblem.copyUnavailable
            }
            // The note came back in the meantime, or was typed again: nothing is overwritten, both stay.
            if try read(item.path) != nil { break }
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
