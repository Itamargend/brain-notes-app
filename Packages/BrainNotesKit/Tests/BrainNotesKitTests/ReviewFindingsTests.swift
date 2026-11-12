import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// Each test here reproduces a bug an independent review found by tracing the engine.
/// Every one of them lost text or left sync stuck before its fix.
@Suite struct DraftAgainstAnotherWriterTests {
    private func draftAndRemote() async throws -> (Harness, String) {
        let h = try Harness()
        await h.sync()
        let path = try h.store.createNote(folder: nil, text: "Groceries\nmine v1\n")
        await h.engine.noteSaved()
        await h.fake.commitRemote([(path, "Groceries\nTHEIRS\n")])
        await h.engine.sync(.poll)  // inside the idle wait: pulls, does not push
        #expect(h.store.journal.file(path)?.blobSha != nil)
        return (h, path)
    }

    @Test func aSecondSaveDoesNotOverwriteTheOtherNote() async throws {
        let (h, path) = try await draftAndRemote()
        try h.store.save(path: path, text: "Groceries\nmine v2\n")
        h.clock.advance(120)
        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.text(path) == "Groceries\nTHEIRS\n", "GitHub's note stays")
        let copy = try #require(h.attention().first?.copyPath)
        #expect(ConflictCopy(text: await h.fake.text(copy)!)?.mine == "Groceries\nmine v2\n", "mine goes to a copy")
        #expect(h.attention().first?.detail == "both-created")
    }

    @Test func deletingTheDraftLeavesTheOtherNoteAlone() async throws {
        let (h, path) = try await draftAndRemote()
        let before = await h.fake.landed.count
        try h.store.delete(path: path)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text(path) == "Groceries\nTHEIRS\n")
        #expect(await h.fake.has("_trash/" + path) == false)
        #expect(await h.fake.landed.count == before, "nothing to commit")
        #expect(h.local(path) == "Groceries\nTHEIRS\n", "the device goes back to GitHub's note")
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func aDraftMadeBeforeFirstSyncWithTheSamePathMakesACopy() async throws {
        let h = try Harness()
        let path = try h.store.createNote(folder: nil, text: "quick\nmine\n")
        #expect(path == "_inbox/quick.md", "GitHub already has this path; the device doesn't know yet")
        try h.store.save(path: path, text: "quick\nmine again\n")
        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.text(path) == "quick thought\n")
        let copy = try #require(h.attention().first?.copyPath)
        #expect(ConflictCopy(text: await h.fake.text(copy)!)?.mine == "quick\nmine again\n")
        #expect(h.local(path) == "quick thought\n")
    }
}

@Suite struct CaseOnlyChangeTests {
    private let mine = "base\nmy unsynced line\n"

    /// The disk here is case-insensitive, so "Notes.md" and "notes.md" are one file.
    @Test func aRenameOfADirtyNoteDoesNotTouchItsFile() async throws {
        let h = try Harness(files: [("Notes.md", "base\n"), ("other.md", "x\n")])
        await h.sync()
        try h.store.save(path: "Notes.md", text: mine)
        await h.engine.noteSaved()
        await h.fake.commitRemote([("Notes.md", nil), ("notes.md", "base\n")])
        await h.engine.sync(.poll)
        #expect(h.local("Notes.md") == mine, "the pull must not write over the unsynced text")
        #expect(try h.store.read("Notes.md") == mine)
        #expect(h.store.journal.file("notes.md")?.local == false)

        // The push follows the rename and lands; afterwards the device holds the new spelling.
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("notes.md") == mine)
        #expect(await h.fake.has("Notes.md") == false)
        #expect(h.local("notes.md") == mine)
        #expect(h.store.journal.file("notes.md")?.local == true)
        #expect(h.store.journal.file("Notes.md") == nil)
        #expect(h.attention().isEmpty)
    }

    @Test func aRenameInTheSameSyncAsThePushLeavesTheNoteOnDisk() async throws {
        let h = try Harness(files: [("Notes.md", "base\n")])
        await h.sync()
        try h.store.save(path: "Notes.md", text: mine)
        await h.fake.commitRemote([("Notes.md", nil), ("notes.md", "base\n")])
        #expect(await h.sync() == .idle)
        #expect(h.local("notes.md") == mine)
        #expect(await h.fake.text("notes.md") == mine)
    }

    @Test func aRemoveAndAddWithOtherTextKeepsMineAsACopyAndGetsTheNewNote() async throws {
        let h = try Harness(files: [("Notes.md", "base\n")])
        await h.sync()
        try h.store.save(path: "Notes.md", text: mine)
        await h.engine.noteSaved()
        await h.fake.commitRemote([("Notes.md", nil), ("notes.md", "entirely other text\n")])
        await h.engine.sync(.poll)
        #expect(h.local("Notes.md") == mine)
        h.clock.advance(120)
        await h.sync()
        let everything = await h.fake.files().map(\.text).joined()
        #expect(everything.contains("my unsynced line"), "mine is in a copy")
        #expect(await h.fake.text("notes.md") == "entirely other text\n")
        await h.sync()
        #expect(h.local("notes.md") == "entirely other text\n", "held back until the name was free")
        #expect(h.store.journal.file("notes.md")?.local == true)
    }

    @Test func aDraftBeforeFirstSyncKeepsItsFileNextToATwinOnGitHub() async throws {
        let h = try Harness(files: [("_inbox/ideas.md", "github's ideas\n")])
        try h.store.save(path: "_inbox/Ideas.md", text: "my ideas\n")
        await h.sync()
        #expect(h.local("_inbox/Ideas.md") == "my ideas\n")
        #expect(await h.fake.text("_inbox/ideas.md") == "github's ideas\n")
        #expect(h.store.journal.file("_inbox/ideas.md")?.local == false)
        // A relaunch must not read my file as an edit of GitHub's note.
        try h.relaunch()
        let r = try h.store.reconcile()
        #expect(r.edited.isEmpty)
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text("_inbox/ideas.md") == "github's ideas\n", "never replaced")
        #expect(h.local("_inbox/Ideas.md") == "my ideas\n", "mine waits in the outbox")
        #expect(h.store.journal.outboxCount() == 1)
    }

    /// Removing a held-back twin must not delete the file of the note it clashes with.
    @Test func removingAHeldBackTwinKeepsTheOtherFile() async throws {
        let h = try Harness(files: [("Notes.md", "the one stored here\n"), ("notes.md", "the twin\n")])
        await h.sync()
        let stored = try #require(h.store.journal.allFiles().first(where: \.local)?.path)
        let twin = try #require(h.store.journal.allFiles().first { !$0.local }?.path)
        await h.fake.commitRemote([(twin, nil)])
        await h.sync()
        #expect(h.local(stored) != nil, "the stored note keeps its file")
        #expect(h.store.journal.file(twin) == nil)
    }

    /// The other direction: the stored note goes away, and its held-back twin gets the file.
    @Test func removingTheStoredNotePromotesItsTwin() async throws {
        let h = try Harness(files: [("Notes.md", "first\n"), ("notes.md", "second\n")])
        await h.sync()
        let stored = try #require(h.store.journal.allFiles().first(where: \.local)?.path)
        let twin = try #require(h.store.journal.allFiles().first { !$0.local }?.path)
        let twinText = try #require(await h.fake.text(twin))
        await h.fake.commitRemote([(stored, nil)])
        await h.sync()
        #expect(h.local(twin) == twinText)
        #expect(h.store.journal.file(twin)?.local == true)
        #expect(h.attention().isEmpty)
        #expect(await h.store.index.search(String(twinText.dropLast())).map(\.path) == [twin])
    }
}

@Suite struct PendingPushInFlightTests {
    /// A commit of unknown fate: the ref update's answer was lost, and verifying failed too.
    private func pendingCreate() async throws -> (Harness, String) {
        let h = try Harness()
        await h.sync()
        let path = try h.store.createNote(folder: nil, text: "Meet\n")
        await h.fake.inject(.updateRef, .lostResponse)
        await h.fake.beforeNextUpdateRef { f in await f.inject(.getRef, .error(.timedOut)) }
        _ = await h.sync()
        #expect(h.store.journal.pendingPush() != nil)
        return (h, path)
    }

    @Test func aNoteWithACommitOfUnknownFateKeepsItsName() async throws {
        let (h, path) = try await pendingCreate()
        #expect(h.store.status(of: path) == .syncing)
        #expect(try h.store.save(path: path, text: "Meeting with Noa\n") == path, "it may already be on GitHub under this name")
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text(path) == "Meeting with Noa\n")
        #expect(await h.fake.files().filter { $0.path.hasPrefix("_inbox/Meet") }.count == 1)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.status(of: path) == .synced)
    }

    @Test func theFlagSurvivesARelaunchUntilTheCommitIsSettled() async throws {
        let (h, path) = try await pendingCreate()
        try h.relaunch()
        #expect(h.store.status(of: path) == .syncing)
        #expect(try h.store.save(path: path, text: "Meeting with Noa\n") == path)
        #expect(await h.sync() == .idle)
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.store.journal.outbox().allSatisfy { !$0.inFlight })
    }

    @Test func deletingANoteWithACommitOfUnknownFateDeletesItOnGitHubToo() async throws {
        let (h, path) = try await pendingCreate()
        try h.store.delete(path: path)
        h.clock.advance(120)
        await h.sync()
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.has(path) == false, "it landed, then the delete followed it")
        #expect(await h.fake.has("_trash/" + path))
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.local(path) == nil)
    }

    @Test func aPendingPushThatNeverLandedClearsTheFlag() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .error(.timedOut))
        await h.fake.inject(.compare, .error(.timedOut))
        _ = await h.sync()
        #expect(h.store.status(of: "todo.md") == .syncing)
        await h.fake.commitRemote([("people/noa.md", "# Noa\nbot\n")])
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
        #expect(h.store.status(of: "todo.md") == .synced)
    }
}

/// Runs the real timer: typing while the timer's own run is pushing must not cancel that push.
@Suite struct TimerTests {
    final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var cancelled: Bool?
        var engine: SyncEngine?
    }

    struct ProbingClient: GitHubClient {
        let fake: FakeGitHub
        let probe: Probe
        func updateRef(to sha: String) async throws {
            // Typing resumes while the request is on its way.
            if let engine = probe.lock.withLock({ probe.engine }) { await engine.noteSaved() }
            try await Task.sleep(for: .milliseconds(20))
            probe.lock.withLock { probe.cancelled = Task.isCancelled }
            try await fake.updateRef(to: sha)
        }
        func getRef(etag: String?) async throws -> RefResult { try await fake.getRef(etag: etag) }
        func getCommit(_ sha: String) async throws -> CommitInfo { try await fake.getCommit(sha) }
        func compare(base: String, head: String) async throws -> Comparison { try await fake.compare(base: base, head: head) }
        func tree(_ sha: String) async throws -> [TreeEntry] { try await fake.tree(sha) }
        func blob(_ sha: String) async throws -> Data { try await fake.blob(sha) }
        func tarball(_ sha: String) async throws -> Data { try await fake.tarball(sha) }
        func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String { try await fake.createTree(baseTree: baseTree, writes: writes) }
        func createCommit(_ commit: NewCommit) async throws -> String { try await fake.createCommit(commit) }
        func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] { try await fake.lastCommitDates(head: head, paths: paths) }
    }

    @Test func aSaveDuringTheTimersPushDoesNotCancelIt() async throws {
        let fake = FakeGitHub(files: Harness.seed)
        let probe = Probe()
        let h = try Harness(fake: fake, client: ProbingClient(fake: fake, probe: probe))
        await h.sync()
        probe.lock.withLock { probe.engine = h.engine }
        await h.engine.start()
        try h.store.save(path: "todo.md", text: "# Todo\nfrom the timer\n")
        await h.engine.noteSaved()
        for _ in 0..<400 where probe.lock.withLock({ probe.cancelled }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await h.engine.stop()
        #expect(probe.lock.withLock { probe.cancelled } == false)
    }
}

@Suite struct NameTooLongTests {
    private var longName: String { "folder/" + String(repeating: "x", count: 300) + ".md" }

    @Test func firstSyncGoesOnWithoutIt() async throws {
        let h = try Harness(files: [(longName, "cannot be stored here\n"), ("ok.md", "fine\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "unstorable")
        #expect(h.local("ok.md") == "fine\n")
        #expect(h.store.journal.file(longName)?.local == false)
        #expect(h.store.journal.baseCommit == (await h.fake.head))
    }

    @Test func aPullGoesOnWithoutIt() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.commitRemote([(longName, "cannot be stored here\n"), ("notes/beta.md", "# Beta\nnew\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.local("notes/beta.md") == "# Beta\nnew\n")
        #expect(h.store.journal.baseCommit == (await h.fake.head))
        // The next run is not stuck, and does not keep trying to download it.
        let blobs = await h.fake.count(.blob)
        await h.sync()
        #expect(await h.fake.count(.blob) == blobs)
    }

    /// A long path: the commit is on main, so the device must carry on. Its conflict copy used to be named after the
    /// whole path, too long for the disk, and stayed on GitHub only; its name is cut to fit now (audit F-5).
    @Test func aConflictCopyWithALongNameDoesNotStopSync() async throws {
        let deep = String(repeating: "folder-name/", count: 25) + "note.md"
        let h = try Harness(files: [(deep, "base line\n"), ("other.md", "x\n")])
        await h.sync()
        try h.store.save(path: deep, text: "mine\n")
        await h.fake.commitRemote([(deep, "theirs\n")])
        let state = await h.sync()
        #expect(state == .needsAttention(1), "the conflict, and nothing else: the copy is on this device too")
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.local(deep) == "theirs\n")
        #expect(await h.fake.files().contains { $0.text.hasSuffix("mine\n") && $0.path.hasPrefix("_inbox/conflict-") })
        let copy = try #require(h.attention().first?.copyPath)
        #expect(ConflictCopy(text: try #require(h.local(copy)))?.mine == "mine\n")
        // Sync still works for everything else.
        h.clock.advance(120)
        try h.store.save(path: "other.md", text: "y\n")
        await h.sync()
        #expect(await h.fake.text("other.md") == "y\n")
    }
}

/// The second pass of the same review, after the first round of fixes.
@Suite struct SecondPassFindingsTests {
    /// The held-back spelling sorts first. It must not count as owning the name when GitHub edits it.
    @Test func aRemoteEditOfAHeldBackTwinLeavesTheStoredFileAlone() async throws {
        let h = try Harness(files: [("a.md", "the stored note\n"), ("other.md", "x\n")])
        await h.sync()
        await h.fake.commitRemote([("A.md", "the twin\n")])
        await h.sync()
        #expect(h.store.journal.file("A.md")?.local == false)
        await h.fake.commitRemote([("A.md", "the twin, edited\n")])
        await h.sync()
        #expect(h.local("a.md") == "the stored note\n", "the twin's text must not land on this file")
        #expect(h.store.journal.file("A.md")?.local == false)
        try h.relaunch()
        #expect(try h.store.reconcile().edited.isEmpty)
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text("a.md") == "the stored note\n", "and a relaunch pushes nothing over it")
        #expect(await h.fake.text("A.md") == "the twin, edited\n")
    }

    /// The same, with unsynced typing on the stored note.
    @Test func aRemoteEditOfAHeldBackTwinLeavesUnsyncedTypingAlone() async throws {
        let h = try Harness(files: [("a.md", "base\n")])
        await h.sync()
        await h.fake.commitRemote([("A.md", "the twin\n")])
        await h.sync()
        try h.store.save(path: "a.md", text: "base\ntyped\n")
        await h.engine.noteSaved()
        await h.fake.commitRemote([("A.md", "the twin, edited\n")])
        await h.engine.sync(.poll)
        #expect(h.local("a.md") == "base\ntyped\n")
    }

    @Test func restoreLeavesANoteThatCameBackAlone() async throws {
        let h = try Harness()
        await h.sync()
        let mine = "# Noa\nDesigner\nmine\n"
        try h.store.save(path: "people/noa.md", text: mine)
        await h.fake.commitRemote([("people/noa.md", nil)])
        await h.sync()
        let item = h.attention()[0]
        await h.fake.commitRemote([("people/noa.md", "# Noa\nwritten again by someone else\n")])
        h.clock.advance(120)
        await h.sync()
        try h.store.resolve(item, .restore)
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text("people/noa.md") == "# Noa\nwritten again by someone else\n", "not overwritten")
        #expect(ConflictCopy(text: await h.fake.text(item.copyPath!)!)?.mine == mine, "and mine stays in the copy")
    }

    @Test func restoreLeavesTypingInANewNoteAtThatPathAlone() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "people/noa.md", text: "# Noa\nDesigner\nmine\n")
        await h.fake.commitRemote([("people/noa.md", nil)])
        await h.sync()
        let item = h.attention()[0]
        try h.store.save(path: "people/noa.md", text: "# Noa\ntyped again\n")
        try h.store.resolve(item, .restore)
        #expect(h.local("people/noa.md") == "# Noa\ntyped again\n")
        #expect(h.local(item.copyPath!) != nil, "the copy stays too")
    }

    /// Typing during a push that follows a case-only rename: the commit writes the new spelling, which is
    /// the same file on this disk, and that write must not replace what was typed.
    @Test func typingDuringACaseRenamePushSurvivesARelaunch() async throws {
        let h = try Harness(files: [("Notes.md", "base\n")])
        await h.sync()
        try h.store.save(path: "Notes.md", text: "base\npushed\n")
        await h.engine.noteSaved()
        await h.fake.commitRemote([("Notes.md", nil), ("notes.md", "base\n")])
        await h.engine.sync(.poll)
        let store = h.store
        await h.fake.beforeNextUpdateRef { _ in _ = try? store.save(path: "Notes.md", text: "base\npushed\ntyped during\n") }
        h.clock.advance(120)
        await h.sync()
        #expect(h.local("Notes.md") == "base\npushed\ntyped during\n", "the commit's write waits")
        try h.relaunch()
        #expect(try h.store.reconcile().edited.isEmpty)
        #expect(h.store.journal.outbox().first?.content == "base\npushed\ntyped during\n")
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text("notes.md") == "base\npushed\ntyped during\n")
        #expect(await h.fake.has("Notes.md") == false)
        #expect(h.local("notes.md") == "base\npushed\ntyped during\n")
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.attention().isEmpty)
    }

    /// An editor still holding the old spelling after a case-only rename: its save belongs to the note.
    @Test func aSaveOnTheOldSpellingMergesIntoTheNote() async throws {
        let original = "# Title\n\n## A\none\n\n## B\ntwo\n"
        let h = try Harness(files: [("Notes.md", original)])
        await h.sync()
        await h.fake.commitRemote([("Notes.md", nil), ("notes.md", original.replacingOccurrences(of: "two", with: "two bot"))])
        await h.sync()
        #expect(h.store.journal.file("Notes.md") == nil)
        let saved = try h.store.save(path: "Notes.md", text: original.replacingOccurrences(of: "one", with: "one typed"), editingFrom: original)
        #expect(saved == "notes.md")
        #expect(h.store.journal.file("Notes.md") == nil, "no second row for one file")
        h.clock.advance(120)
        await h.sync()
        let remote = await h.fake.text("notes.md")!
        #expect(remote.contains("one typed") && remote.contains("two bot"), "merged, nothing replaced")
        #expect(await h.fake.has("Notes.md") == false)
    }

    /// Copies this device makes itself must fit on the disk, however long the note's path is.
    @Test func copiesOfALongPathFitOnTheDisk() async throws {
        let deep = String(repeating: "folder-name/", count: 25) + "note.md"
        let h = try Harness(files: [(deep, "base\n")])
        await h.sync()
        // A second window's text, kept as a copy.
        try h.store.save(path: deep, text: "base\nfirst window\n", editingFrom: "base\n")
        try h.store.save(path: deep, text: "base\nsecond window\n", editingFrom: "base\n")
        // Unsynced text of a deleted note, kept in _trash.
        try h.store.delete(path: deep)
        h.clock.advance(120)
        await h.sync()
        let all = await h.fake.files().map(\.text).joined()
        #expect(all.contains("first window"))
        #expect(all.contains("second window"))
    }

    /// A power loss after the journal commit: the file went back to older text. The op holds the newer one.
    @Test func aFileOlderThanTheJournalDoesNotBeatTheOp() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nolder\n")
        try h.store.save(path: "todo.md", text: "# Todo\nnewest\n")
        let url = try h.store.files.url(for: "todo.md")
        try Data("# Todo\nolder\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        try h.relaunch()
        #expect(try h.store.reconcile().edited.isEmpty)
        #expect(h.store.journal.outbox().first?.content == "# Todo\nnewest\n")
        #expect(h.local("todo.md") == "# Todo\nnewest\n")
    }

    /// A ref that refuses every time: after the retries, it waits instead of spending write calls on each poll.
    @Test func aRefThatAlwaysRefusesWaitsBeforeTryingAgain() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        for _ in 0..<4 { await h.fake.inject(.updateRef, .error(.unprocessable("Reference update failed"))) }
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "push-failed")
        let tries = await h.fake.count(.updateRef)
        #expect(tries == 4)
        for _ in 0..<3 {
            h.clock.advance(61)
            await h.engine.sync(.poll)
        }
        #expect(await h.fake.count(.updateRef) == tries, "no write calls for a while")
        h.clock.advance(200)
        await h.engine.sync(.poll)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n", "and it does try again")
        #expect(h.attention().isEmpty)
    }

    /// A draft deleted while its commit was in flight, the commit loses a race, and someone else now has that path.
    @Test func aDraftDeletedInFlightLeavesTheOtherNoteAlone() async throws {
        let h = try Harness()
        await h.sync()
        let path = try h.store.createNote(folder: nil, text: "Draft\nmine\n")
        let store = h.store
        await h.fake.beforeNextUpdateRef { f in
            try? store.delete(path: path)
            await f.commitRemote([(path, "Draft\nTHEIRS\n")])
        }
        await h.sync()
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text(path) == "Draft\nTHEIRS\n", "not mine to delete")
        #expect(await h.fake.has("_trash/" + path) == false)
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func noGhostEntryAfterACaseOnlyRename() async throws {
        let h = try Harness(files: [("Notes.md", "# Notes\nbody\n")])
        await h.sync()
        await h.fake.commitRemote([("Notes.md", nil), ("notes.md", "# Notes\nbody\n")])
        await h.sync()
        #expect(await h.store.index.allPaths() == ["notes.md"])
    }

    @Test func removingAHeldBackRowClosesItsItem() async throws {
        let h = try Harness(files: [("a.md", "stored\n")])
        await h.sync()
        await h.fake.commitRemote([("A.md", "twin\n")])
        await h.sync()
        #expect(h.attention().count == 1)
        await h.fake.commitRemote([("A.md", nil)])
        #expect(await h.sync() == .idle)
        #expect(h.attention().isEmpty)
        #expect(await h.store.index.allPaths() == ["a.md"], "and no ghost either")
    }

    /// A conflict copy this device can't hold: every choice must work, and the copy stays on GitHub.
    @Test func aCopyThisDeviceCannotHoldCanStillBeResolved() async throws {
        for choice in [AttentionChoice.keepBoth, .useMine, .useTheirs] {
            let deep = String(repeating: "folder-name/", count: 25) + "note.md"
            let h = try Harness(files: [(deep, "base\n")])
            await h.sync()
            try h.store.save(path: deep, text: "mine\n")
            await h.fake.commitRemote([(deep, "theirs\n")])
            await h.sync()
            let item = try #require(h.attention().first { $0.reason == "conflict-copy" })
            #expect(h.store.texts(for: item).theirs == "theirs\n")
            try h.store.resolve(item, choice)
            h.clock.advance(120)
            await h.sync()
            #expect(await h.fake.files().contains { $0.text.hasSuffix("mine\n") }, "\(choice): mine is still on GitHub")
            #expect(h.store.journal.outboxCount() == 0, "\(choice)")
        }
    }

    @Test func aFreshSyncFinishesOnAVeryLongPath() async throws {
        let deep = String(repeating: "folder-name/", count: 25) + "note.md"
        let h = try Harness(files: [(deep, "base\n")])
        await h.sync()
        try h.store.save(path: deep, text: "mine, unsynced\n")
        await h.fake.forcePushForTest(files: [(deep, "rewritten\n")])
        #expect(await h.sync() == .needsAttention(1))
        await h.engine.freshSync()
        #expect(h.store.journal.baseCommit == (await h.fake.head))
        #expect(await h.fake.files().contains { $0.text.contains("mine, unsynced") })
    }
}

@Suite struct SchedulerLoopTests {
    /// Each of these left the timer waking every second.
    @Test func afterABackoffThenSignOutTheTimerIsCalm() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.inject(.getRef, .error(.server(500)))
        _ = await h.sync()
        h.clock.advance(5)
        await h.fake.inject(.getRef, .error(.unauthorized))
        #expect(await h.sync(.foreground) == .signedOut)
        h.clock.advance(3600)
        #expect(await h.engine.delayUntilNextWake == 60)
    }

    @Test func afterABackoffThenAccessLostTheTimerIsCalm() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.inject(.getRef, .error(.server(500)))
        _ = await h.sync()
        h.clock.advance(5)
        await h.fake.inject(.getRef, .error(.repoAccessLost))
        #expect(await h.sync(.foreground) == .accessLost)
        h.clock.advance(100)
        #expect(await h.engine.delayUntilNextWake == 60)
    }

    @Test func editsWhileOfflineDoNotWakeTheTimer() async throws {
        let h = try Harness()
        await h.sync()
        await h.engine.setOnline(false)
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        await h.engine.noteSaved()
        h.clock.advance(100)
        #expect(await h.engine.delayUntilNextWake == 60)
    }

    @Test func aFailedRunWaitsForTheBackoffNotTheFlushTimer() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        await h.engine.noteSaved()
        h.clock.advance(100)
        await h.fake.inject(.getRef, .error(.offline))  // the network says online, the request says otherwise
        #expect(await h.sync(.poll) == .offline)
        #expect(await h.engine.delayUntilNextWake == 60)
    }

    @Test func onlyParkedOpsLeftDoNotWakeTheTimer() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        await h.fake.inject(.createTree, .error(.unprocessable("no")))
        await h.sync()
        #expect(h.store.journal.outbox()[0].parked)
        h.clock.advance(100)
        await h.engine.noteSaved()  // for example a draft deleted elsewhere
        h.clock.advance(100)
        #expect(await h.engine.delayUntilNextWake == 60)
    }
}

@Suite struct SmallerFindingsTests {
    /// A kill between first sync's folder swap and its journal commit: the file there is GitHub's.
    @Test func launchRepairDoesNotTakeSwappedInTextForMyEdit() async throws {
        let h = try Harness()
        try h.store.save(path: "todo.md", text: "# Todo\nmine, before first sync\n")
        try h.store.journal.setMeta(Journal.Key.swapping, "1")
        try h.store.files.write("todo.md", "# Todo\n- one\n- two\n")
        try h.relaunch()
        let r = try h.store.reconcile()
        #expect(r.edited.isEmpty)
        #expect(h.store.journal.outbox()[0].content == "# Todo\nmine, before first sync\n")
        #expect(h.local("todo.md") == "# Todo\nmine, before first sync\n")
        await h.sync()
        #expect(h.store.journal.meta(Journal.Key.swapping) == nil)
        #expect(await h.fake.text("todo.md") == "# Todo\n- one\n- two\n")
        let copy = try #require(h.attention().first?.copyPath)
        #expect(ConflictCopy(text: await h.fake.text(copy)!)?.mine == "# Todo\nmine, before first sync\n")
    }

    /// The note is deleted from the list while an editor holding older text stays open, then that editor saves.
    @Test func anEditorSavingOverADeleteMergesFromWhatItStartedWith() async throws {
        let h = try Harness()
        await h.sync()
        let old = h.local("notes/alpha.md")!
        await h.fake.commitRemote([("notes/alpha.md", old.replacingOccurrences(of: "line four", with: "line four bot"))])
        await h.sync()
        try h.store.delete(path: "notes/alpha.md")
        try h.store.save(path: "notes/alpha.md", text: old.replacingOccurrences(of: "line one", with: "line one typed"), editingFrom: old)
        h.clock.advance(120)
        await h.sync()
        let remote = await h.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one typed"))
        #expect(remote.contains("line four bot"), "the bot's line survives")
    }

    @Test func aPathThatComesBackIsNoLongerTreatedAsRenamed() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        try h.store.save(path: "notes/alpha.md", text: alpha + "mine\n")
        await h.engine.noteSaved()
        await h.fake.commitRemote([("notes/alpha.md", nil), ("archive/alpha.md", alpha)])
        await h.engine.sync(.poll)
        #expect(h.store.journal.file("notes/alpha.md")?.renameTo == "archive/alpha.md")
        await h.fake.commitRemote([("notes/alpha.md", alpha)])
        await h.engine.sync(.poll)
        #expect(h.store.journal.file("notes/alpha.md")?.renameTo == nil)
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.text("notes/alpha.md") == alpha + "mine\n")
        #expect(await h.fake.text("archive/alpha.md") == alpha)
        #expect(h.local("notes/alpha.md") == alpha + "mine\n")
        #expect(h.local("archive/alpha.md") == alpha)
    }

    @Test func deletingAnEditedNoteKeepsTheUnsyncedTextInTrash() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "people/noa.md", text: "# Noa\nDesigner\ntyped but never pushed\n")
        try h.store.delete(path: "people/noa.md")
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.has("people/noa.md") == false)
        #expect(await h.fake.text("_trash/people/noa.md") == "# Noa\nDesigner\n", "GitHub's version, as always")
        let all = await h.fake.files()
        #expect(all.contains { $0.path.hasPrefix("_trash/unsynced-people-noa-") && $0.text.contains("typed but never pushed") })
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.index.count() == 6, "neither shows in lists")
    }

    @Test func aRefreshWaitsWhileTheKeychainIsLocked() async throws {
        final class Lockable: TokenStore, @unchecked Sendable {
            let lock = NSLock()
            var locked = false
            var pair: TokenPair?
            init(_ pair: TokenPair) { self.pair = pair }
            func load() throws -> TokenPair? {
                try lock.withLock {
                    if locked { throw TokenStoreError.unavailable }
                    return pair
                }
            }
            func save(_ pair: TokenPair) throws {
                try lock.withLock {
                    if locked { throw TokenStoreError.unavailable }
                    self.pair = pair
                }
            }
            func clear() {}
        }
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        let store = Lockable(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let manager = TokenManager(clientId: "c", transport: http, store: store)
        #expect(try await manager.accessToken() == "ghu_start")
        store.lock.withLock { store.locked = true }
        await #expect(throws: TokenStoreError.unavailable) { try await manager.refresh(failed: "ghu_start") }
        #expect(await manager.refreshCount == 0, "the old pair is not spent")
        store.lock.withLock { store.locked = false }
        #expect(try await manager.refresh(failed: "ghu_start") == "ghu_1")
        #expect(store.lock.withLock { store.pair?.refresh } == "ghr_1")
    }

    @Test func aPairThatCouldNotBeStoredIsKeptAndStoredLater() async throws {
        final class FailsOnce: TokenStore, @unchecked Sendable {
            let lock = NSLock()
            var failSaves = 1
            var pair: TokenPair?
            init(_ pair: TokenPair) { self.pair = pair }
            func load() throws -> TokenPair? { lock.withLock { pair } }
            func save(_ pair: TokenPair) throws {
                try lock.withLock {
                    if failSaves > 0 {
                        failSaves -= 1
                        throw TokenStoreError.failed(-1)
                    }
                    self.pair = pair
                }
            }
            func clear() {}
        }
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        let store = FailsOnce(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let manager = TokenManager(clientId: "c", transport: http, store: store)
        #expect(try await manager.refresh(failed: "ghu_start") == "ghu_1")
        #expect(store.lock.withLock { store.pair?.refresh } == "ghr_start", "the save failed")
        #expect(try await manager.accessToken() == "ghu_1", "memory holds the new pair")
        #expect(store.lock.withLock { store.pair?.refresh } == "ghr_1", "and the next use stores it")
    }
}
