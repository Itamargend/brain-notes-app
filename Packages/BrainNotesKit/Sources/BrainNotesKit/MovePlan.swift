import BrainMerge
import Foundation

/// What a move did.
public struct MoveResult: Sendable, Equatable {
    public struct Move: Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public enum Outcome: Sendable, Equatable {
        /// On GitHub and on this device.
        case landed(commit: String)
        /// Sent, but GitHub's answer was lost. The engine's next run checks the ref and finishes it; until then the
        /// device shows the old paths.
        case unconfirmed(commit: String)
        /// Nothing to commit: a folder that exists only on this device, or one that is already on GitHub.
        case noCommit
    }

    /// Every file that moved, old path to new.
    public var files: [Move]
    /// The folder itself, for a folder move.
    public var folder: Move?
    /// Files the move added: a folder's placeholder.
    public var added: [String]
    public var outcome: Outcome

    public init(files: [Move] = [], folder: Move? = nil, added: [String] = [], outcome: Outcome) {
        self.files = files; self.folder = folder; self.added = added; self.outcome = outcome
    }
}

/// Why a move was refused. Nothing has changed, here or on GitHub, when one of these is thrown.
public enum MoveProblem: Error, Equatable, Sendable {
    case notFound(String)
    /// The path rules refuse this destination (or this source, for `_inbox`): `private`, `_capture`, a hidden
    /// `_` folder, a dot or empty segment, a folder name ending in `.md`, or a path too long for the disk.
    case notAllowed(String)
    /// The note or folder is already in that folder.
    case alreadyThere
    /// A folder into itself or one of its own subfolders.
    case intoItself
    /// Notes with changes that are not on GitHub yet. Sync first.
    case unsynced([String])
    /// Files in the folder this app does not sync (images, dot files, `private/`, a case twin of the folder).
    /// Moving only the notes would split the folder on GitHub.
    case leftBehind([String])
    /// The bytes on GitHub are not exact UTF-8, so the same blob can't be written at the new path.
    case notText(String)
    /// No first sync yet.
    case notSyncedYet
    /// GitHub has changes this device has not pulled. Sync first.
    case behind
    /// A push is still waiting to be confirmed. The next sync settles it.
    case pushPending
    /// Someone else pushed while the move was being made. Sync, then try again.
    case remoteChanged
}

/// The file that keeps an otherwise empty folder on GitHub. Git has no empty folders, and the sync rules take only
/// `.md` files with no dot segment, so a `.gitkeep` could never leave the device. `_folder.md` passes the rules,
/// and its `_` marks it as the app's own file, as `_inbox` and `_trash` are.
public enum FolderPlaceholder {
    public static let fileName = "_folder.md"

    /// What the file says, for someone who finds it on GitHub.
    public static let text = "This file keeps an empty folder on GitHub. Brain Notes made it. It can be deleted once the folder has notes.\n"

    public static func path(in folder: String) -> String { folder + "/" + fileName }

    public static func isPlaceholder(_ path: String) -> Bool {
        sameBytes(MovePaths.lastSegment(path), fileName)
    }

    /// Splits listed paths into notes and the folders a placeholder keeps. For the home screen:
    /// `FolderNode.tree(paths: notes, emptyFolders: localEmpty + folders)`.
    public static func listing(_ paths: [String]) -> (notes: [String], folders: [String]) {
        var notes: [String] = []
        var folders: [String] = []
        for p in paths {
            if isPlaceholder(p) {
                let folder = MovePaths.parent(p)
                if !folder.isEmpty { folders.append(folder) }
            } else {
                notes.append(p)
            }
        }
        return (notes, folders)
    }
}

/// Path pieces by bytes. `/` is one ASCII byte, so splitting there never cuts a character in two.
enum MovePaths {
    static func lastSegment(_ p: String) -> String {
        guard let i = p.utf8.lastIndex(of: 0x2F) else { return p }
        return String(decoding: p.utf8[p.utf8.index(after: i)...], as: UTF8.self)
    }

    /// The folder a path is in, "" for the top level.
    static func parent(_ p: String) -> String {
        guard let i = p.utf8.lastIndex(of: 0x2F) else { return "" }
        return String(decoding: p.utf8[..<i], as: UTF8.self)
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    static func hasPrefix(_ p: String, _ prefix: String) -> Bool {
        p.utf8.starts(with: prefix.utf8)
    }

    /// `p` with `old` (a folder) at its start replaced by `new`.
    static func rebase(_ p: String, from old: String, to new: String) -> String {
        new + String(decoding: p.utf8.dropFirst(old.utf8.count), as: UTF8.self)
    }

    /// The same folder or inside it, in any case or NFC/NFD spelling.
    static func isSameOrInside(_ p: String, _ folder: String) -> Bool {
        let a = foldKey(p), b = foldKey(folder)
        return sameBytes(a, b) || hasPrefix(a, b + "/")
    }

    /// "a/name.md" -> "a/name 2.md"; a folder "a/Name" -> "a/Name 2". The extension keeps its own case.
    static func numbered(_ p: String, _ n: Int, isNote: Bool) -> String {
        guard isNote else { return p + " \(n)" }
        let bytes = Array(p.utf8)
        return String(decoding: bytes.dropLast(3), as: UTF8.self) + " \(n)" + String(decoding: bytes.suffix(3), as: UTF8.self)
    }
}

/// What a move is planned from: GitHub's tree at the head this device is on, plus this device's own state.
struct MoveTree {
    var entries: [TreeEntry]
    var rows: [FileRow]
    var opPaths: [String]
    var emptyFolders: [String]

    func entry(_ path: String) -> TreeEntry? { entries.first { sameBytes($0.path, path) } }

    /// Every name in use, by clash key: GitHub's whole tree (not only notes), this device's notes, and its empty
    /// folders (indexed through a child no real path can have).
    ///
    /// Only files: GitHub's recursive tree also lists every folder, and a folder taken as a file would clash with
    /// every path inside it. The folders are in the index anyway, through their files.
    func index() -> PathIndex {
        let folders = folderPaths()
        return PathIndex(entries.filter { $0.isFile || !folders.contains(PathKey($0.path)) }.map(\.path) + rows.map(\.path) + opPaths
            + emptyFolders.map { $0 + "/\u{0}" })
    }

    /// Every folder that has an entry under it, by exact bytes.
    func folderPaths() -> Set<PathKey> {
        Set(entries.map { PathKey(MovePaths.parent($0.path)) })
    }

    /// Notes under `folder` (or the note itself) whose changes are not all on GitHub.
    func unsynced(_ paths: [String]) -> [String] {
        let rowByPath = Dictionary(rows.map { (PathKey($0.path), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for p in paths {
            let row = rowByPath[PathKey(p)]
            let sha = entry(p)?.sha
            if row == nil || row?.dirty == true || row?.renameTo != nil || row?.blobSha != sha || opPaths.contains(where: { sameBytes($0, p) }) {
                out.append(p)
            }
        }
        return out
    }
}

/// One planned move: files with their blob shas, and the empty folders that go with them on disk.
struct MovePlan: Equatable {
    struct Item: Equatable {
        var from: String
        var to: String
        var sha: String
    }

    var items: [Item]
    var folder: MoveResult.Move?
    var emptyFolders: [MoveResult.Move]
}

/// The pure part of a move: checks and names, no I/O. The mover gives it the tree and turns its plan into tree writes.
enum MovePlanner {
    /// A note into a folder ("" for the top level). The name stays; a taken name gets a number.
    static func note(_ path: String, into folder: String, _ t: MoveTree) throws -> MovePlan {
        guard let entry = t.entry(path) else {
            if t.opPaths.contains(where: { sameBytes($0, path) }) { throw MoveProblem.unsynced([path]) }
            throw MoveProblem.notFound(path)
        }
        guard entry.isFile else { throw MoveProblem.leftBehind([path]) }
        let unsynced = t.unsynced([path])
        if !unsynced.isEmpty { throw MoveProblem.unsynced(unsynced) }
        let dest = try destination(folder)
        let index = t.index()
        let wanted = index.respell(MovePaths.join(dest, MovePaths.lastSegment(path)))
        if sameBytes(foldKey(MovePaths.parent(wanted)), foldKey(MovePaths.parent(path))) { throw MoveProblem.alreadyThere }
        let to = try free(wanted, index, isNote: true)
        return MovePlan(items: [.init(from: path, to: to, sha: entry.sha)], folder: nil, emptyFolders: [])
    }

    /// A whole folder into another ("" for the top level), with everything in it. A taken name gets a number.
    static func folder(_ folder: String, into parent: String, _ t: MoveTree) throws -> MovePlan {
        guard !folder.isEmpty else { throw MoveProblem.notAllowed(folder) }
        if PathPolicy.isInbox(folder) { throw MoveProblem.notAllowed(folder) }
        guard PathPolicy.isVisible(folder + "/x.md") else { throw MoveProblem.notAllowed(folder) }
        let dest = try destination(parent)
        if !dest.isEmpty, MovePaths.isSameOrInside(dest, folder) { throw MoveProblem.intoItself }
        if sameBytes(foldKey(MovePaths.parent(folder)), foldKey(dest)) { throw MoveProblem.alreadyThere }

        let prefix = folder + "/"
        let folded = foldKey(folder) + "/"
        // GitHub's recursive tree lists every subfolder as an entry that is not a file. A subfolder moves with
        // its files; only a non-file with nothing under it (a submodule or symlink) is left behind.
        let folders = t.folderPaths()
        var inside: [TreeEntry] = []
        var left: [String] = []
        for e in t.entries {
            if MovePaths.hasPrefix(e.path, prefix) {
                if !e.isFile, folders.contains(PathKey(e.path)) { continue }
                if e.isFile, PathPolicy.isSyncable(e.path) { inside.append(e) } else { left.append(e.path) }
            } else if MovePaths.hasPrefix(foldKey(e.path), folded) {
                // The same folder in another spelling: one folder on this device, two on GitHub.
                left.append(e.path)
            }
        }
        if !left.isEmpty { throw MoveProblem.leftBehind(left.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }) }

        // Notes made here and never pushed, and notes with changes: neither can move until they are on GitHub.
        var unsynced = t.unsynced(inside.map(\.path))
        for p in t.opPaths + t.rows.filter({ $0.blobSha == nil }).map(\.path)
        where MovePaths.hasPrefix(p, prefix) && !unsynced.contains(where: { sameBytes($0, p) }) {
            unsynced.append(p)
        }
        if !unsynced.isEmpty { throw MoveProblem.unsynced(unsynced.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }) }

        let empties = t.emptyFolders.filter { sameBytes($0, folder) || MovePaths.hasPrefix($0, prefix) }
        if inside.isEmpty && empties.isEmpty { throw MoveProblem.notFound(folder) }

        let index = t.index()
        let wanted = index.respell(MovePaths.join(dest, MovePaths.lastSegment(folder)))
        let target = try free(wanted, index, isNote: false)
        var items: [MovePlan.Item] = []
        for e in inside {
            let to = MovePaths.rebase(e.path, from: folder, to: target)
            guard checkPath(to) == nil, FileStore.nameFits(to) else { throw MoveProblem.notAllowed(to) }
            items.append(.init(from: e.path, to: to, sha: e.sha))
        }
        let moved = empties.map { MoveResult.Move(from: $0, to: MovePaths.rebase($0, from: folder, to: target)) }
        return MovePlan(items: items, folder: .init(from: folder, to: target), emptyFolders: moved)
    }

    /// Where a folder's placeholder goes, or nil when the folder already has a file on GitHub.
    static func placeholder(for folder: String, _ t: MoveTree) throws -> String? {
        guard !folder.isEmpty, PathPolicy.canHoldNotes(folder: folder) else { throw MoveProblem.notAllowed(folder) }
        let folded = foldKey(folder) + "/"
        if t.entries.contains(where: { MovePaths.hasPrefix(foldKey($0.path), folded) }) { return nil }
        let path = FolderPlaceholder.path(in: folder)
        guard checkPath(path) == nil, FileStore.nameFits(path) else { throw MoveProblem.notAllowed(path) }
        return path
    }

    /// A destination folder as given: "" for the top level, or a folder the rules let hold notes. Made NFC.
    static func destination(_ folder: String) throws -> String {
        if folder.isEmpty { return "" }
        let f = nfc(folder)
        guard PathPolicy.canHoldNotes(folder: f) else { throw MoveProblem.notAllowed(folder) }
        return f
    }

    /// `wanted`, or `name 2`, `name 3`, ... until the name is free by clash key. Never a taken name.
    static func free(_ wanted: String, _ index: PathIndex, isNote: Bool) throws -> String {
        for n in 1...999 {
            let p = n == 1 ? wanted : MovePaths.numbered(wanted, n, isNote: isNote)
            if isNote {
                guard checkPath(p) == nil, FileStore.nameFits(p) else { throw MoveProblem.notAllowed(p) }
            } else {
                guard PathPolicy.canHoldNotes(folder: p) else { throw MoveProblem.notAllowed(p) }
            }
            if index.takenByAny(p) { continue }
            if index.clash(isNote ? p : p + "/x.md", strict: true) != nil { continue }
            return p
        }
        throw MoveProblem.notAllowed(wanted)
    }
}
