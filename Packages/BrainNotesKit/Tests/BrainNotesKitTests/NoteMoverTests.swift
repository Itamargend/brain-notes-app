import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// The fake GitHub, with every tree write the mover sends kept for the tests to read.
actor RecordingClient: GitHubClient {
    let inner: FakeGitHub
    private(set) var treeWrites: [[TreeWrite]] = []

    init(_ inner: FakeGitHub) { self.inner = inner }

    func getRef(etag: String?) async throws -> RefResult { try await inner.getRef(etag: etag) }
    func getCommit(_ sha: String) async throws -> CommitInfo { try await inner.getCommit(sha) }
    func compare(base: String, head: String) async throws -> Comparison { try await inner.compare(base: base, head: head) }
    func tree(_ sha: String) async throws -> [TreeEntry] { try await inner.tree(sha) }
    func blob(_ sha: String) async throws -> Data { try await inner.blob(sha) }
    func tarball(_ sha: String) async throws -> Data { try await inner.tarball(sha) }
    func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String {
        treeWrites.append(writes)
        return try await inner.createTree(baseTree: baseTree, writes: writes)
    }
    func createCommit(_ commit: NewCommit) async throws -> String { try await inner.createCommit(commit) }
    func updateRef(to sha: String) async throws { try await inner.updateRef(to: sha) }
    func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] {
        try await inner.lastCommitDates(head: head, paths: paths)
    }
}

/// Moves against the fake GitHub, through the same calls a push makes.
@Suite struct NoteMoverTests {
    private func setUp(_ files: [(path: String, text: String)] = Harness.seed) async throws -> (Harness, NoteMover, RecordingClient, MemoryPinsStore) {
        let h = try Harness(files: files)
        await h.sync()
        let client = RecordingClient(h.fake)
        let pins = MemoryPinsStore()
        return (h, NoteMover(store: h.store, client: client, pins: pins), client, pins)
    }

    private func landedCommit(_ r: MoveResult) -> String? {
        if case let .landed(commit) = r.outcome { return commit }
        return nil
    }

    // MARK: notes

    @Test func aNoteMovesInOneCommitWithTheSameBlob() async throws {
        let (h, mover, client, _) = try await setUp()
        let parent = await h.fake.head
        let history = await h.fake.history().count
        let sha = try #require(h.store.journal.file("notes/beta.md")?.blobSha)

        let result = try await mover.moveNote("notes/beta.md", toFolder: "people")
        #expect(result.files == [.init(from: "notes/beta.md", to: "people/beta.md")])
        let commit = try #require(landedCommit(result))
        #expect(await h.fake.head == commit)
        #expect(await h.fake.history().count == history + 1, "one commit")
        #expect(await client.treeWrites == [[TreeWrite(path: "notes/beta.md", change: .delete),
                                            TreeWrite(path: "people/beta.md", change: .content("# Beta\nbody\n"))]])
        let compare = try await h.fake.compare(base: parent, head: commit)
        #expect(compare.files == [ChangedFile(path: "people/beta.md", status: .renamed, previousPath: "notes/beta.md", sha: sha)])

        let message = try #require(await h.fake.commitInfo(commit)?.message)
        #expect(message.hasPrefix("notes: move notes/beta.md -> people/beta.md\n\nBrain-Notes-Device: test-"))
        #expect(message.contains("\nBrain-Notes-Op: "))

        // The device is at the commit, with the file and its row moved and nothing waiting.
        #expect(h.local("people/beta.md") == "# Beta\nbody\n")
        #expect(h.local("notes/beta.md") == nil)
        #expect(h.store.journal.file("notes/beta.md") == nil)
        #expect(h.store.journal.file("people/beta.md")?.blobSha == sha)
        #expect(h.store.status(of: "people/beta.md") == .synced)
        #expect(h.store.journal.baseCommit == commit)
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.store.journal.outbox().isEmpty)

        // The engine finds nothing to do afterwards.
        await h.sync()
        #expect(await h.fake.history().count == history + 1)
        #expect(await h.fake.refUpdateAttempts == [commit])
    }

    @Test func anotherDeviceSeesTheRename() async throws {
        let (h, mover, _, _) = try await setUp()
        let other = try h.secondDevice()
        await other.sync()
        try await mover.moveNote("notes/alpha.md", toFolder: "")
        await other.sync()
        #expect(other.local("alpha.md") == h.local("alpha.md"))
        #expect(other.local("notes/alpha.md") == nil)
        #expect(other.store.status(of: "alpha.md") == .synced)
    }

    @Test func aTakenNameGetsANumberAndIsNeverOverwritten() async throws {
        let (h, mover, _, _) = try await setUp(Harness.seed + [("people/beta.md", "# Other beta\n"), ("people/beta 2.md", "# Beta two\n")])
        let result = try await mover.moveNote("notes/beta.md", toFolder: "people")
        #expect(result.files.map(\.to) == ["people/beta 3.md"])
        #expect(await h.fake.text("people/beta.md") == "# Other beta\n")
        #expect(await h.fake.text("people/beta 2.md") == "# Beta two\n")
        #expect(await h.fake.text("people/beta 3.md") == "# Beta\nbody\n")
        #expect(h.local("people/beta.md") == "# Other beta\n")
    }

    /// `BETA.md` and `beta.md` are one file on an iPhone's disk, so the name is taken.
    @Test func aNameTakenInAnotherCaseCounts() async throws {
        let (h, mover, _, _) = try await setUp(Harness.seed + [("people/BETA.md", "# Upper\n")])
        let result = try await mover.moveNote("notes/beta.md", toFolder: "PEOPLE")
        #expect(result.files.map(\.to) == ["people/beta 2.md"], "the folder keeps GitHub's spelling")
        #expect(await h.fake.text("people/BETA.md") == "# Upper\n")
    }

    @Test func hebrewNamesMoveAndCount() async throws {
        let (h, mover, _, _) = try await setUp(Harness.seed + [("רעיונות/רעיון.md", "# קיים\n")])
        let result = try await mover.moveNote("עברית/רעיון.md", toFolder: "רעיונות")
        #expect(result.files.map(\.to) == ["רעיונות/רעיון 2.md"])
        #expect(h.local("רעיונות/רעיון 2.md") == "# רעיון\nטקסט בעברית\n")
        #expect(h.local("רעיונות/רעיון.md") == "# קיים\n")
        #expect(h.local("עברית/רעיון.md") == nil)
        #expect(!h.store.files.exists("עברית"), "the folder it left is empty, so it goes, as on GitHub")
    }

    @Test func intoASubfolderThatIsNotThereYet() async throws {
        let (h, mover, _, _) = try await setUp()
        let result = try await mover.moveNote("todo.md", toFolder: "projects/2026")
        #expect(result.files.map(\.to) == ["projects/2026/todo.md"])
        #expect(await h.fake.text("projects/2026/todo.md") == "# Todo\n- one\n- two\n")
        #expect(h.local("projects/2026/todo.md") == "# Todo\n- one\n- two\n")
    }

    @Test func outOfTheTrashAndIntoTheInbox() async throws {
        let (h, mover, _, _) = try await setUp()
        try await mover.moveNote("_trash/old.md", toFolder: "notes")
        try await mover.moveNote("todo.md", toFolder: PathPolicy.inboxFolder)
        #expect(h.local("notes/old.md") == "old\n")
        #expect(h.local("_inbox/todo.md") == "# Todo\n- one\n- two\n")
    }

    @Test func refusalsChangeNothing() async throws {
        let (h, mover, client, _) = try await setUp()
        await #expect(throws: MoveProblem.alreadyThere) { try await mover.moveNote("notes/beta.md", toFolder: "notes") }
        await #expect(throws: MoveProblem.alreadyThere) { try await mover.moveNote("notes/beta.md", toFolder: "NOTES") }
        await #expect(throws: MoveProblem.notFound("nope.md")) { try await mover.moveNote("nope.md", toFolder: "notes") }
        for dest in ["private", "_capture", "_trash", ".git", "x.md", "a//b", "../up"] {
            await #expect(throws: MoveProblem.notAllowed(dest), "\(dest)") { try await mover.moveNote("todo.md", toFolder: dest) }
        }
        await #expect(throws: MoveProblem.leftBehind(["assets/photo.png"])) { try await mover.moveFolder("assets", into: "notes") }
        await #expect(throws: MoveProblem.notAllowed("_inbox")) { try await mover.moveFolder("_inbox", into: "notes") }
        await #expect(throws: MoveProblem.intoItself) { try await mover.moveFolder("notes", into: "notes/deeper") }
        await #expect(throws: MoveProblem.alreadyThere) { try await mover.moveFolder("notes", into: "") }
        #expect(await client.treeWrites.isEmpty)
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
        #expect(h.local("todo.md") == "# Todo\n- one\n- two\n")
    }

    @Test func unsyncedNotesWaitForASync() async throws {
        let (h, mover, client, _) = try await setUp()
        try h.store.save(path: "notes/beta.md", text: "# Beta\nchanged\n")
        let fresh = try h.store.createNote(folder: "notes", text: "# Fresh\n")
        await #expect(throws: MoveProblem.unsynced(["notes/beta.md"])) { try await mover.moveNote("notes/beta.md", toFolder: "people") }
        await #expect(throws: MoveProblem.unsynced([fresh])) { try await mover.moveNote(fresh, toFolder: "people") }
        await #expect(throws: MoveProblem.unsynced([fresh, "notes/beta.md"])) { try await mover.moveFolder("notes", into: "people") }
        #expect(await client.treeWrites.isEmpty)

        await h.sync()
        let result = try await mover.moveNote("notes/beta.md", toFolder: "people")
        #expect(result.files.map(\.to) == ["people/beta.md"])
        #expect(await h.fake.text("people/beta.md") == "# Beta\nchanged\n")
    }

    @Test func aDeviceBehindGitHubSyncsFirst() async throws {
        let (h, mover, client, _) = try await setUp()
        await h.fake.commitRemote([("from-the-web.md", "# Web\n")])
        await #expect(throws: MoveProblem.behind) { try await mover.moveNote("todo.md", toFolder: "notes") }
        #expect(await client.treeWrites.isEmpty)
        await h.sync()
        try await mover.moveNote("todo.md", toFolder: "notes")
        #expect(h.local("notes/todo.md") != nil)
    }

    @Test func nothingBeforeTheFirstSyncOrWhileAPushIsOpen() async throws {
        let h = try Harness()
        let mover = NoteMover(store: h.store, client: h.fake)
        await #expect(throws: MoveProblem.notSyncedYet) { try await mover.moveNote("todo.md", toFolder: "notes") }
        await h.sync()
        try h.store.journal.setPendingPush(PendingPush(commit: "c", parent: "p", planJSON: Data()))
        await #expect(throws: MoveProblem.pushPending) { try await mover.moveNote("todo.md", toFolder: "notes") }
    }

    // MARK: races and lost answers

    @Test func aPushThatWinsTheRaceStopsTheMoveCleanly() async throws {
        let (h, mover, _, pins) = try await setUp()
        try pins.pin("notes/beta.md")
        await h.fake.beforeNextUpdateRef { fake in await fake.commitRemote([("other.md", "# Other\n")]) }
        await #expect(throws: MoveProblem.remoteChanged) { try await mover.moveNote("notes/beta.md", toFolder: "people") }
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
        #expect(await !h.fake.has("people/beta.md"))
        #expect(pins.paths() == ["notes/beta.md"])

        await h.sync()
        try await mover.moveNote("notes/beta.md", toFolder: "people")
        #expect(h.local("people/beta.md") == "# Beta\nbody\n")
        #expect(h.local("other.md") == "# Other\n")
        #expect(pins.paths() == ["people/beta.md"])
    }

    /// The engine is not stopped by a move. If a push of its own gets in while the move waits on GitHub, the move
    /// loses the race, and the engine's landing record (what its next run verifies) must still be there after it.
    @Test func aLosingMoveLeavesTheEnginesRecordAlone() async throws {
        let (h, mover, _, _) = try await setUp()
        let store = h.store
        let theirs = PendingPush(commit: "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0", parent: "p", planJSON: Data())
        await h.fake.beforeNextUpdateRef { fake in
            await fake.commitRemote([("other.md", "# Other\n")])
            try? store.journal.setPendingPush(theirs)
        }
        await #expect(throws: MoveProblem.remoteChanged) { try await mover.moveNote("notes/beta.md", toFolder: "people") }
        #expect(h.store.journal.pendingPush()?.commit == theirs.commit, "not the mover's to clear")
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
    }

    @Test func aLostAnswerIsCheckedAndLands() async throws {
        let (h, mover, _, _) = try await setUp()
        await h.fake.inject(.updateRef, .lostResponse)
        let result = try await mover.moveNote("notes/beta.md", toFolder: "people")
        let commit = try #require(landedCommit(result))
        #expect(await h.fake.head == commit)
        #expect(h.local("people/beta.md") == "# Beta\nbody\n")
        #expect(h.store.journal.pendingPush() == nil)
    }

    /// The answer is lost and the check fails too, then the app is killed: the engine's own landing finishes it.
    @Test func anUnconfirmedMoveIsFinishedByTheEngine() async throws {
        let (h, mover, _, _) = try await setUp()
        let history = await h.fake.history().count
        await h.fake.inject(.updateRef, .lostResponse)
        await h.fake.beforeNextUpdateRef { fake in await fake.inject(.getRef, .error(.timedOut)) }
        let result = try await mover.moveNote("notes/beta.md", toFolder: "people")
        guard case let .unconfirmed(commit) = result.outcome else {
            Issue.record("expected unconfirmed, got \(result.outcome)")
            return
        }
        #expect(await h.fake.head == commit, "it did land on GitHub")
        #expect(h.store.journal.pendingPush()?.commit == commit)
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n", "the device has not caught up yet")

        try h.relaunch()
        await h.sync()
        #expect(h.local("people/beta.md") == "# Beta\nbody\n")
        #expect(h.local("notes/beta.md") == nil)
        #expect(h.store.journal.file("notes/beta.md") == nil)
        #expect(h.store.status(of: "people/beta.md") == .synced)
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.store.journal.baseCommit == commit)
        #expect(await h.fake.history().count == history + 1, "no second commit")
    }

    @Test func aRefusedTokenLeavesNoRecord() async throws {
        let (h, mover, _, _) = try await setUp()
        await h.fake.inject(.updateRef, .error(.unauthorized))
        await #expect(throws: GitHubError.unauthorized) { try await mover.moveNote("notes/beta.md", toFolder: "people") }
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
    }

    // MARK: folders

    @Test func aWholeFolderMovesInOneCommit() async throws {
        let extra: [(path: String, text: String)] = [("notes/deep/inner.md", "# Inner\n"), ("notes/_drafts/d.md", "draft\n")]
        let (h, mover, client, pins) = try await setUp(Harness.seed + extra)
        try h.store.createFolder(named: "Later", in: "notes")
        try pins.pin("notes/beta.md")
        try pins.pin("todo.md")
        let parent = await h.fake.head
        let history = await h.fake.history().count

        let result = try await mover.moveFolder("notes", into: "people")
        #expect(result.folder == .init(from: "notes", to: "people/notes"))
        #expect(Set(result.files.map(\.to)) == ["people/notes/alpha.md", "people/notes/beta.md",
                                                "people/notes/deep/inner.md", "people/notes/_drafts/d.md"])
        let commit = try #require(landedCommit(result))
        #expect(await h.fake.history().count == history + 1)
        #expect(await client.treeWrites.count == 1)
        let message = try #require(await h.fake.commitInfo(commit)?.message)
        #expect(message.hasPrefix("notes: move folder notes -> people/notes (4 files)\n"))
        let compare = try await h.fake.compare(base: parent, head: commit)
        #expect(compare.files.allSatisfy { $0.status == .renamed }, "every file is the same blob at a new path")
        #expect(compare.files.count == 4)

        #expect(h.local("people/notes/deep/inner.md") == "# Inner\n")
        #expect(h.local("people/notes/_drafts/d.md") == "draft\n")
        #expect(h.store.files.emptyFolders() == ["people/notes/Later"], "the empty folder came along")
        #expect(!h.store.files.exists("notes"), "nothing is left at the old place")
        #expect(pins.paths() == ["people/notes/beta.md", "todo.md"])
        #expect(h.store.journal.allFiles().allSatisfy { !MovePaths.hasPrefix($0.path, "notes/") })
    }

    @Test func aTakenFolderNameGetsANumber() async throws {
        // `Notes 2` is a plain file, not a note: every name on GitHub counts, in any case.
        let (h, mover, _, _) = try await setUp(Harness.seed + [("archive/notes/x.md", "# X\n"), ("archive/Notes 2", "plain\n")])
        let result = try await mover.moveFolder("notes", into: "archive")
        #expect(result.folder?.to == "archive/notes 3", "a folder and a file with that name both count")
        #expect(await h.fake.text("archive/notes/x.md") == "# X\n")
        #expect(await h.fake.text("archive/notes 3/beta.md") == "# Beta\nbody\n")
    }

    @Test func aHebrewFolderMovesToTheTopAndBack() async throws {
        let (h, mover, _, _) = try await setUp()
        let first = try await mover.moveFolder("עברית", into: "people")
        #expect(first.folder?.to == "people/עברית")
        let back = try await mover.moveFolder("people/עברית", into: "")
        #expect(back.folder?.to == "עברית")
        #expect(h.local("עברית/רעיון.md") == "# רעיון\nטקסט בעברית\n")
        #expect(await h.fake.history().suffix(2).allSatisfy { $0.hasPrefix("notes: move folder ") })
    }

    @Test func aFolderOnlyOnThisDeviceMovesWithoutACall() async throws {
        let (h, mover, client, _) = try await setUp()
        try h.store.createFolder(named: "Empty", in: "")
        try h.store.createFolder(named: "Inner", in: "Empty")
        let refs = await h.fake.count(.getRef)
        let result = try await mover.moveFolder("Empty", into: "notes")
        #expect(result.outcome == .noCommit)
        #expect(result.folder?.to == "notes/Empty")
        #expect(h.store.files.emptyFolders() == ["notes/Empty/Inner"])
        #expect(await h.fake.count(.getRef) == refs)
        #expect(await client.treeWrites.isEmpty)
    }

    // MARK: new folders

    @Test func aNewFolderReachesGitHubWithItsPlaceholder() async throws {
        let (h, mover, _, _) = try await setUp()
        let other = try h.secondDevice()
        await other.sync()

        let result = try await mover.createFolder(named: "Ideas", in: "notes")
        #expect(result.added == ["notes/Ideas/_folder.md"])
        #expect(result.folder?.to == "notes/Ideas")
        #expect(landedCommit(result) != nil)
        #expect(await h.fake.text("notes/Ideas/_folder.md") == FolderPlaceholder.text)
        #expect(h.local("notes/Ideas/_folder.md") == FolderPlaceholder.text)
        #expect(h.store.status(of: "notes/Ideas/_folder.md") == .synced)
        #expect(await h.fake.history().last?.hasPrefix("notes: add folder notes/Ideas\n") == true)

        // On the other device the folder shows, with no note in it.
        await other.sync()
        let visible = other.store.journal.allFiles().map(\.path).filter(PathPolicy.isVisible)
        let (notes, folders) = FolderPlaceholder.listing(visible)
        let tree = FolderNode.tree(paths: notes, emptyFolders: other.store.files.emptyFolders() + folders)
        let notesNode = try #require(tree.first { $0.path == "notes" })
        #expect(notesNode.children.map(\.path) == ["notes/Ideas"])
        #expect(notesNode.children[0].totalCount == 0)

        // A note moved in later sits next to the placeholder; the placeholder stays put.
        try await mover.moveNote("todo.md", toFolder: "notes/Ideas")
        #expect(await h.fake.has("notes/Ideas/_folder.md"))
        #expect(await h.fake.text("notes/Ideas/todo.md") == "# Todo\n- one\n- two\n")
    }

    @Test func aHebrewFolderAtTheTop() async throws {
        let (h, mover, _, _) = try await setUp()
        let result = try await mover.createFolder(named: "רעיונות חדשים", in: "")
        #expect(result.added == ["רעיונות חדשים/_folder.md"])
        #expect(await h.fake.has("רעיונות חדשים/_folder.md"))
    }

    @Test func aNewFolderIsAllOrNothing() async throws {
        let (h, mover, client, _) = try await setUp()
        await h.fake.inject(.getRef, .error(.offline))
        await #expect(throws: GitHubError.offline) { try await mover.createFolder(named: "Ideas", in: "notes") }
        #expect(h.store.files.emptyFolders().isEmpty, "the folder made for it is gone again")
        #expect(await client.treeWrites.isEmpty)

        #expect(throws: NoteStore.FolderProblem.notAllowed) { _ = try h.store.createFolder(named: "private", in: "") }
        await #expect(throws: NoteStore.FolderProblem.notAllowed) { try await mover.createFolder(named: "private", in: "") }
        await #expect(throws: NoteStore.FolderProblem.alreadyExists) { try await mover.createFolder(named: "NOTES", in: "") }
        await #expect(throws: NoteStore.FolderProblem.noName) { try await mover.createFolder(named: "  ", in: "") }
        #expect(await client.treeWrites.isEmpty)
    }

    @Test func aFolderMadeOfflineCanBeKeptLater() async throws {
        let (h, mover, _, _) = try await setUp()
        let folder = try h.store.createFolder(named: "Later", in: "")
        let result = try await mover.keepFolderOnGitHub(folder)
        #expect(result.added == ["Later/_folder.md"])
        #expect(await h.fake.has("Later/_folder.md"))
        #expect(try await mover.keepFolderOnGitHub("notes").outcome == .noCommit, "a folder with notes needs nothing")
        await #expect(throws: MoveProblem.notFound("nowhere")) { try await mover.keepFolderOnGitHub("nowhere") }
    }
}
