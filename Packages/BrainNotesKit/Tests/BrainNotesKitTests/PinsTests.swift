import Foundation
import Testing
@testable import BrainNotesKit

/// Pins: per device, never synced, follow a note when it moves, go when it is deleted, sort to the top.
@Suite struct PinsTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bn-pins-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pins.json")
    }

    /// The same checks for every store, so none of them behaves differently.
    private func stores() -> [(String, PinsStore, () -> Void)] {
        let file = tempFile()
        return [
            ("memory", MemoryPinsStore(), {}),
            ("file", FilePinsStore(url: file), { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }),
        ]
    }

    @Test func pinUnpinAndNoDuplicates() throws {
        for (name, pins, cleanup) in stores() {
            defer { cleanup() }
            try pins.pin("notes/a.md")
            try pins.pin("notes/b.md")
            try pins.pin("notes/a.md")
            #expect(pins.paths() == ["notes/a.md", "notes/b.md"], "\(name)")
            #expect(pins.isPinned("notes/a.md"), "\(name)")
            try pins.unpin("notes/a.md")
            #expect(pins.paths() == ["notes/b.md"], "\(name)")
            #expect(!pins.isPinned("notes/a.md"), "\(name)")
            try pins.setPinned("notes/c.md", true)
            try pins.setPinned("notes/b.md", false)
            #expect(pins.paths() == ["notes/c.md"], "\(name)")
        }
    }

    /// NFC and NFD spellings are two files on GitHub, so they are two pins.
    @Test func pathsCompareByTheirBytes() throws {
        for (name, pins, cleanup) in stores() {
            defer { cleanup() }
            try pins.pin("Caf\u{E9}.md")
            #expect(!pins.isPinned("Cafe\u{301}.md"), "\(name)")
            try pins.unpin("Cafe\u{301}.md")
            #expect(pins.paths().count == 1, "\(name)")
        }
    }

    @Test func aPinFollowsItsNoteInItsPlace() throws {
        for (name, pins, cleanup) in stores() {
            defer { cleanup() }
            for p in ["a.md", "notes/b.md", "c.md"] { try pins.pin(p) }
            try pins.noteMoved(from: "notes/b.md", to: "archive/b 2.md")
            #expect(pins.paths() == ["a.md", "archive/b 2.md", "c.md"], "\(name)")
            try pins.notesMoved([.init(from: "a.md", to: "x/a.md"), .init(from: "unpinned.md", to: "x/unpinned.md")])
            #expect(pins.paths() == ["x/a.md", "archive/b 2.md", "c.md"], "\(name)")
        }
    }

    /// Two pins that end up on one path (a move onto a pinned note can't happen, but a bad call must not double it).
    @Test func movesNeverMakeTwoPinsForOnePath() throws {
        let pins = MemoryPinsStore(["a.md", "b.md"])
        try pins.notesMoved([.init(from: "a.md", to: "b.md")])
        #expect(pins.paths() == ["b.md"])
    }

    @Test func hebrewPathsPinAndMove() throws {
        for (name, pins, cleanup) in stores() {
            defer { cleanup() }
            try pins.pin("עברית/רעיון.md")
            try pins.noteMoved(from: "עברית/רעיון.md", to: "רעיונות/רעיון 2.md")
            #expect(pins.paths() == ["רעיונות/רעיון 2.md"], "\(name)")
        }
    }

    @Test func aDeletedNoteLosesItsPin() throws {
        for (name, pins, cleanup) in stores() {
            defer { cleanup() }
            try pins.pin("a.md")
            try pins.pin("b.md")
            try pins.noteDeleted("a.md")
            #expect(pins.paths() == ["b.md"], "\(name)")
            try pins.dropMissing { $0 == "nothing" }
            #expect(pins.paths().isEmpty, "\(name)")
        }
    }

    /// The engine's order for a rename: the old path in `.notesChanged` first, then `.noteMoved`, then the run's
    /// resting snapshot. The pin must survive that order.
    @Test func syncEventsMoveAndDropPinsInTheEnginesOrder() throws {
        let pins = MemoryPinsStore(["notes/beta.md", "todo.md", "keep.md"])
        var here: Set<String> = ["archive/beta.md", "keep.md"]
        let exists: (String) -> Bool = { here.contains($0) }
        var busy = SyncSnapshot()
        busy.state = .applying
        try pins.apply(.notesChanged(["notes/beta.md", "archive/beta.md", "todo.md"]), exists: exists)
        #expect(pins.paths() == ["notes/beta.md", "todo.md", "keep.md"], "nothing goes before the run is over")
        try pins.apply(.noteMoved(from: "notes/beta.md", to: "archive/beta.md"), exists: exists)
        try pins.apply(.snapshot(busy), exists: exists)
        #expect(pins.paths() == ["archive/beta.md", "todo.md", "keep.md"])
        try pins.apply(.snapshot(SyncSnapshot()), exists: exists)
        #expect(pins.paths() == ["archive/beta.md", "keep.md"], "deleted elsewhere: the pin goes when the run ends")
        here.insert("todo.md")
        #expect(pins.paths().count == 2, "a note that comes back is not pinned again")
    }

    @Test func pinnedSortFirstAndKeepTheirOrder() throws {
        let pins = MemoryPinsStore(["c.md", "a.md"])
        let list = ["a.md", "b.md", "c.md", "d.md"]
        #expect(pins.pinnedFirst(list, path: { $0 }) == ["a.md", "c.md", "b.md", "d.md"])
        struct Row { var path: String; var title: String }
        let rows = [Row(path: "x.md", title: "X"), Row(path: "a.md", title: "A")]
        #expect(pins.pinnedFirst(rows, path: \.path).map(\.title) == ["A", "X"])
        #expect(MemoryPinsStore().pinnedFirst(list, path: { $0 }) == list)
    }

    @Test func theFileStoreKeepsPinsAcrossLaunches() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FilePinsStore(url: url).pin("notes/a.md")
        #expect(FilePinsStore(url: url).paths() == ["notes/a.md"])
    }

    @Test func aDamagedPinsFileIsNoPins() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let pins = FilePinsStore(url: url)
        #expect(pins.paths().isEmpty)
        try pins.pin("a.md")
        #expect(FilePinsStore(url: url).paths() == ["a.md"])
    }

    /// Next to the journal, never under `files/`: nothing there is ever pushed, and a wipe takes it.
    @Test func pinsLiveOutsideTheSyncedFilesAndGoWithAWipe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bn-pins-store-\(UUID().uuidString)", isDirectory: true)
        let store = try NoteStore(root: root)
        let pins = FilePinsStore(store: store)
        try pins.pin("a.md")
        #expect(!pins.url.path.hasPrefix(store.files.filesRoot.path))
        #expect(FileManager.default.fileExists(atPath: pins.url.path))
        try store.wipe()
        #expect(!FileManager.default.fileExists(atPath: pins.url.path))
    }

    @Test func deletingThroughTheStoreUnpins() async throws {
        let h = try Harness()
        await h.sync()
        let pins = MemoryPinsStore(["todo.md", "README.md"])
        try h.store.delete(path: "todo.md", pins: pins)
        #expect(pins.paths() == ["README.md"])
        #expect(h.local("todo.md") == nil)
    }

    /// A rename made on another device reaches this one as an engine event, and the pin follows it.
    @Test func aRenameFromGitHubMovesThePin() async throws {
        let h = try Harness()
        await h.sync()
        // A new engine, so the stream holds only the next run's events, not the first sync's.
        try h.relaunch()
        let pins = MemoryPinsStore(["notes/beta.md"])
        let text = try #require(await h.fake.text("notes/beta.md"))
        await h.fake.commitRemote([("notes/beta.md", nil), ("archive/beta.md", text)], message: "web: move")
        await h.sync()
        await h.engine.finishEvents()
        for await e in h.engine.events {
            try pins.apply(e, exists: { h.store.journal.file($0) != nil })
        }
        #expect(pins.paths() == ["archive/beta.md"])
    }
}
