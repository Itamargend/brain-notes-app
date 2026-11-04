#if canImport(Foundation)
import Foundation

/// Pinned notes on this device. Pins are never synced: they are not in the repo, the engine never sees them,
/// and another device has its own. Paths are compared by their exact bytes, as everywhere in this package.
///
/// A store has to give two things: the list, and a way to change it in one step. Everything else (pin,
/// follow a move, drop on delete, sort) is in the extension below and works the same for every store.
public protocol PinsStore: AnyObject, Sendable {
    /// Pinned note paths, oldest pin first.
    func paths() -> [String]
    /// Read, change and write the list with no other change in between.
    func update(_ change: (inout [String]) -> Void) throws
}

extension PinsStore {
    public func isPinned(_ path: String) -> Bool {
        paths().contains { sameBytes($0, path) }
    }

    public func pin(_ path: String) throws {
        try update { list in
            if !list.contains(where: { sameBytes($0, path) }) { list.append(path) }
        }
    }

    public func unpin(_ path: String) throws {
        try update { list in list.removeAll { sameBytes($0, path) } }
    }

    public func setPinned(_ path: String, _ pinned: Bool) throws {
        if pinned { try pin(path) } else { try unpin(path) }
    }

    /// A note moved: its pin goes with it, in the same place in the list.
    public func noteMoved(from: String, to: String) throws {
        try notesMoved([MoveResult.Move(from: from, to: to)])
    }

    /// Several notes moved at once, as in a folder move.
    public func notesMoved(_ moves: [MoveResult.Move]) throws {
        guard !moves.isEmpty else { return }
        var map: [PathKey: String] = [:]
        for m in moves { map[PathKey(m.from)] = m.to }
        try update { list in
            var seen = Set<PathKey>()
            var out: [String] = []
            for p in list {
                let now = map[PathKey(p)] ?? p
                if seen.insert(PathKey(now)).inserted { out.append(now) }
            }
            list = out
        }
    }

    /// The note was deleted: its pin goes too.
    public func noteDeleted(_ path: String) throws {
        try unpin(path)
    }

    /// Drop every pin whose note is gone. For a launch, or after a sync removed notes.
    public func dropMissing(where exists: (String) -> Bool) throws {
        let gone = paths().filter { !exists($0) }
        guard !gone.isEmpty else { return }
        let keys = Set(gone.map(PathKey.init))
        try update { list in list.removeAll { keys.contains(PathKey($0)) } }
    }

    /// Keep pins in line with what a sync did. Feed it every engine event, in order.
    ///
    /// A note GitHub renamed keeps its pin (`.noteMoved`). A note deleted elsewhere loses it, but only once the run
    /// is over (a snapshot that is not busy): the engine reports a rename's old path in `.notesChanged` before
    /// `.noteMoved`, and dropping pins there would lose the pin of every renamed note. `exists` is usually
    /// `{ store.journal.file($0) != nil }`.
    public func apply(_ event: SyncEvent, exists: (String) -> Bool) throws {
        switch event {
        case let .noteMoved(from, to):
            try noteMoved(from: from, to: to)
        case .notesChanged:
            break
        case let .snapshot(snapshot):
            if !snapshot.state.isBusy { try dropMissing(where: exists) }
        }
    }

    /// Pinned items first, then the rest. Stable: each group keeps the order it came in, so a list sorted by
    /// date stays sorted by date within the pinned group and below it.
    public func pinnedFirst<T>(_ items: [T], path: (T) -> String) -> [T] {
        let pinned = Set(paths().map(PathKey.init))
        guard !pinned.isEmpty else { return items }
        var top: [T] = []
        var rest: [T] = []
        for item in items {
            if pinned.contains(PathKey(path(item))) { top.append(item) } else { rest.append(item) }
        }
        return top + rest
    }
}

/// Pins in memory only. For tests and previews.
public final class MemoryPinsStore: PinsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String]

    public init(_ paths: [String] = []) { list = paths }

    public func paths() -> [String] { lock.withLock { list } }

    public func update(_ change: (inout [String]) -> Void) throws {
        lock.withLock { change(&list) }
    }
}

/// Pins in a small JSON file. `FilePinsStore(store:)` keeps it next to the journal, outside `files/`, so it is
/// never synced and sign-out's wipe removes it with everything else of that repo.
public final class FilePinsStore: PinsStore, @unchecked Sendable {
    public static let fileName = "pins.json"

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public convenience init(store: NoteStore) {
        self.init(url: store.root.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    public func paths() -> [String] { lock.withLock { load() } }

    public func update(_ change: (inout [String]) -> Void) throws {
        try lock.withLock {
            var list = load()
            let before = list
            change(&list)
            guard list.count != before.count || !zip(list, before).allSatisfy({ sameBytes($0, $1) }) else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: url, options: .atomic)
        }
    }

    /// A missing or unreadable file is no pins. Pins are a convenience: a bad file must never stop the app.
    private func load() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

extension NoteStore {
    /// Delete a note, and its pin with it.
    public func delete(path: String, pins: PinsStore) throws {
        try delete(path: path)
        try pins.noteDeleted(path)
    }
}
#endif
