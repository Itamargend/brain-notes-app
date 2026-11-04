import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

@Suite struct FirstSyncTests {
    @Test func downloadsOnlyNotesAndVerifies() async throws {
        let h = try Harness()
        #expect(await h.sync() == .idle)
        #expect(h.store.journal.baseCommit == (await h.fake.head))
        #expect(h.local("notes/alpha.md")?.contains("line one") == true)
        #expect(h.local("עברית/רעיון.md") == "# רעיון\nטקסט בעברית\n")
        #expect(h.local(".obsidian/plugin.md") == nil)
        #expect(h.local("private/secret.md") == nil)
        #expect(h.local("assets/photo.png") == nil)
        #expect(h.local("_trash/old.md") == "old\n")  // kept, but hidden
        #expect(h.store.index.count() == 7)  // no _trash
        #expect(await h.store.index.search("old").isEmpty)
        #expect(await h.fake.count(.blob) == 0)
        #expect(await h.fake.count(.tarball) == 1)
        #expect(!FileManager.default.fileExists(atPath: h.store.files.stagingURL().path))
    }

    @Test func untouchedNotesAreByteForByte() async throws {
        let odd = "line one\r\nno final newline \u{FEFF}"
        let h = try Harness(files: [("a.md", odd), ("bom.md", "\u{FEFF}x\n")])
        await h.sync()
        #expect(sameBytes(h.local("a.md") ?? "", odd))
        #expect(sameBytes(h.local("bom.md") ?? "", "\u{FEFF}x\n"))
        #expect(h.store.journal.file("a.md")?.blobSha == GitBlob.sha(odd))
    }

    @Test func fallsBackToBlobsWhenTheTarballFails() async throws {
        let h = try Harness()
        await h.fake.inject(.tarball, .error(.server(502)))
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
        #expect(await h.fake.count(.blob) > 0)
    }

    @Test func aTamperedTarballFileIsReplacedFromBlobs() async throws {
        let tampering = TamperingClient(FakeGitHub(files: Harness.seed))
        let h = try Harness(fake: tampering.fake, client: tampering)
        #expect(await h.sync() == .idle)
        #expect(h.local("todo.md") == "# Todo\n- one\n- two\n")
        #expect(await h.fake.count(.blob) == 1)
    }

    @Test func anInterruptedFirstSyncLeavesNoTraceAndResumes() async throws {
        let h = try Harness()
        await h.fake.inject(.tarball, .error(.timedOut))
        let state = await h.sync()
        if case .retrying = state {} else { Issue.record("expected retrying, got \(state)") }
        #expect(h.store.journal.baseCommit == nil)
        #expect(h.local("todo.md") == nil)
        try h.relaunch()
        #expect(await h.sync() == .idle)
        #expect(h.local("todo.md") != nil)
    }

    @Test func aNoteComposedBeforeFirstSyncSurvives() async throws {
        let h = try Harness()
        let p = try h.store.createNote(folder: nil, text: "Written early\n")
        #expect(await h.sync() == .idle)
        #expect(h.local(p) == "Written early\n")
        #expect(await h.fake.text(p) == "Written early\n")
    }

    @Test func caseTwinsStayOnGitHubOnly() async throws {
        let h = try Harness(files: [("People/a.md", "first\n"), ("people/b.md", "second\n"), ("Caf\u{E9}.md", "nfc\n"), ("Cafe\u{301}.md", "nfd\n"), ("ok.md", "ok\n")])
        #expect(await h.sync() == .needsAttention(2))
        let twins = h.store.journal.allFiles().filter { !$0.local }
        #expect(twins.count == 2)
        #expect(h.attention().allSatisfy { $0.reason == "case-clash" })
        // Edits still work next to them, and the commit leaves the twins alone.
        try h.store.save(path: "ok.md", text: "ok\nmore\n")
        await h.sync()
        #expect(await h.fake.text("ok.md") == "ok\nmore\n")
        #expect(await h.fake.text("people/b.md") == "second\n")
        #expect(await h.fake.text("Cafe\u{301}.md") == "nfd\n")
    }

    @Test func datesComeFromHistoryAndListsSortByThem() async throws {
        let h = try Harness()
        await h.fake.commitRemote([("notes/beta.md", "# Beta\nnewer\n")], date: Date(timeIntervalSince1970: 1_800_000_000))
        await h.sync()
        let notes = await h.store.index.notes(inFolder: "notes")
        #expect(notes.map(\.title) == ["Beta", "Alpha"])
        #expect(notes[0].modified == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(notes[1].modified != nil)
        #expect(h.store.journal.meta(Journal.Key.datesPending) == nil)
    }

    @Test func dateFailureDoesNotFailTheSync() async throws {
        let h = try Harness()
        await h.fake.inject(.lastCommitDates, .error(.server(500)))
        #expect(await h.sync() == .idle)
        #expect(h.store.journal.meta(Journal.Key.datesPending) == "1")
        await h.sync()
        #expect(h.store.journal.meta(Journal.Key.datesPending) == nil)
    }
}

@Suite struct PullTests {
    @Test func cleanPullUpdatesFilesIndexAndBase() async throws {
        let h = try Harness()
        await h.sync()
        let head = await h.fake.commitRemote([
            ("notes/beta.md", "# Beta\nnew body\n"),
            ("notes/gamma.md", "# Gamma\nadded\n"),
            ("people/noa.md", nil),
            (".obsidian/other.md", "still hidden\n"),
        ])
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nnew body\n")
        #expect(h.local("notes/gamma.md") == "# Gamma\nadded\n")
        #expect(h.local("people/noa.md") == nil)
        #expect(h.local(".obsidian/other.md") == nil)
        #expect(h.store.journal.baseCommit == head)
        #expect(await h.store.index.search("gamma").count == 1)
        #expect(await h.store.index.search("Designer").isEmpty)
        #expect(await h.store.index.search("new body").count == 1)
    }

    @Test func aBlobThatDoesNotMatchItsHashIsRefused() async throws {
        struct Corrupting: GitHubClient {
            let fake: FakeGitHub
            func blob(_ sha: String) async throws -> Data { Data("corrupted in transit".utf8) }
            func getRef(etag: String?) async throws -> RefResult { try await fake.getRef(etag: etag) }
            func getCommit(_ sha: String) async throws -> CommitInfo { try await fake.getCommit(sha) }
            func compare(base: String, head: String) async throws -> Comparison { try await fake.compare(base: base, head: head) }
            func tree(_ sha: String) async throws -> [TreeEntry] { try await fake.tree(sha) }
            func tarball(_ sha: String) async throws -> Data { try await fake.tarball(sha) }
            func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String { try await fake.createTree(baseTree: baseTree, writes: writes) }
            func createCommit(_ commit: NewCommit) async throws -> String { try await fake.createCommit(commit) }
            func updateRef(to sha: String) async throws { try await fake.updateRef(to: sha) }
            func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] { try await fake.lastCommitDates(head: head, paths: paths) }
        }
        let fake = FakeGitHub(files: Harness.seed)
        let h = try Harness(fake: fake, client: Corrupting(fake: fake))
        await h.sync()
        let base = h.store.journal.baseCommit
        await fake.commitRemote([("notes/beta.md", "# Beta\nreal text\n")])
        let state = await h.sync()
        if case .retrying = state {} else { Issue.record("expected retrying, got \(state)") }
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n", "the old text stays")
        #expect(h.store.journal.baseCommit == base)
    }

    @Test func nothingNewCostsOneConditionalRead() async throws {
        let h = try Harness()
        await h.sync()
        let compares = await h.fake.count(.compare), commits = await h.fake.count(.getCommit)
        await h.sync(.poll)
        await h.sync(.poll)
        #expect(await h.fake.count(.compare) == compares)
        #expect(await h.fake.count(.getCommit) == commits)
    }

    @Test func over300FilesUsesATreeDiff() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.setCompareCap(2)
        await h.fake.commitRemote([
            ("a1.md", "1\n"), ("a2.md", "2\n"), ("a3.md", "3\n"), ("notes/beta.md", nil), ("todo.md", "# Todo\nchanged\n"),
        ])
        #expect(await h.sync() == .idle)
        #expect(await h.fake.count(.tree) >= 2)
        #expect(h.local("a3.md") == "3\n")
        #expect(h.local("notes/beta.md") == nil)
        #expect(h.local("todo.md") == "# Todo\nchanged\n")
    }

    @Test func aRepeatedPullIsHarmless() async throws {
        // A kill between applying files and moving the base: the same changes arrive again.
        let h = try Harness()
        await h.sync()
        await h.fake.commitRemote([("notes/beta.md", "# Beta\nv2\n")])
        await h.sync()
        let base = h.store.journal.baseCommit
        try h.store.journal.setMeta(Journal.Key.baseCommit, await h.fake.commitInfo(base!)?.parents.first)
        try h.store.journal.setMeta(Journal.Key.refEtag, nil)
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nv2\n")
        #expect(h.store.journal.baseCommit == base)
    }

    @Test func remoteRenameOfACleanNoteMovesIt() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.commitRemote([("notes/beta.md", nil), ("archive/beta.md", "# Beta\nbody\n")])
        await h.sync()
        #expect(h.local("notes/beta.md") == nil)
        #expect(h.local("archive/beta.md") == "# Beta\nbody\n")
        await h.engine.finishEvents()
        var sawMove = false
        for await e in h.engine.events where e == .noteMoved(from: "notes/beta.md", to: "archive/beta.md") {
            sawMove = true
        }
        #expect(sawMove, "an open editor follows the note")
    }

    @Test func remoteRenameOfADirtyNoteCarriesTheEdit() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "notes/alpha.md", text: "# Alpha\n\n## First\nline one edited\nline two\n\n## Second\nline three\nline four\n")
        await h.fake.commitRemote([("notes/alpha.md", nil), ("archive/alpha.md", await h.fake.text("notes/alpha.md")!)])
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("archive/alpha.md")?.contains("line one edited") == true)
        #expect(await h.fake.has("notes/alpha.md") == false)
        #expect(h.local("notes/alpha.md") == nil)
        #expect(h.local("archive/alpha.md")?.contains("line one edited") == true)
        #expect(h.store.journal.file("notes/alpha.md") == nil)
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func caseClashOnPullIsHeldBack() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.commitRemote([("People/x.md", "twin folder\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.store.journal.file("People/x.md")?.local == false)
        #expect(h.attention()[0].detail == "people/")
    }

    @Test func aFileRemovedWhileADirtyEditWaitsKeepsTheText() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\n- one\n- two\n- three\n")
        await h.engine.noteSaved()
        await h.fake.commitRemote([("todo.md", nil)])
        await h.engine.sync(.poll)  // inside the idle wait: pulls, does not push
        #expect(h.local("todo.md")?.contains("three") == true)
        #expect(h.store.journal.file("todo.md")?.blobSha == nil)
    }
}

@Suite struct PushTests {
    @Test func localEditBecomesOneCommit() async throws {
        let h = try Harness()
        await h.sync()
        let parent = await h.fake.head
        let opTime = isoTime(h.clock.now)
        try h.store.save(path: "todo.md", text: "# Todo\n- one\n- two\n- three\n")
        #expect(h.store.status(of: "todo.md") == .savedOnDevice)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)

        let head = await h.fake.head
        #expect(await h.fake.text("todo.md") == "# Todo\n- one\n- two\n- three\n")
        #expect(h.store.status(of: "todo.md") == .synced)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.journal.baseCommit == head)
        #expect(h.store.journal.file("todo.md")?.dirty == false)
        #expect(h.store.journal.file("todo.md")?.baseText == nil)
        #expect(h.store.journal.file("todo.md")?.blobSha == GitBlob.sha("# Todo\n- one\n- two\n- three\n"))

        let info = try #require(await h.fake.commitInfo(head))
        #expect(info.parents == [parent])
        #expect(info.date == opTime, "the commit date is the op time, fixed when the op was made")
        #expect(info.message.hasPrefix("notes: edit todo.md"))
        let lastLine = info.message.split(separator: "\n").last.map(String.init) ?? ""
        #expect(lastLine.hasPrefix("Brain-Notes-Op: "))
        #expect(info.message.contains("Brain-Notes-Device: test-"))
        #expect(await h.fake.count(.createTree) == 1)
        #expect(await h.fake.count(.createCommit) == 1)
        #expect(await h.fake.count(.updateRef) == 1)
    }

    @Test func manyEditsGoInOneCommit() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        try h.store.save(path: "todo.md", text: "# Todo\nchanged\n")
        try h.store.save(path: "notes/beta.md", text: "# Beta\nchanged\n")
        let p = try h.store.createNote(folder: "people", text: "# Dana\n")
        try h.store.delete(path: "README.md")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.landed.count == before + 1)
        let head = await h.fake.head
        let paths = try await h.fake.changedPaths(in: head)
        #expect(paths.contains("todo.md"))
        #expect(paths.contains("notes/beta.md"))
        #expect(paths.contains(p))
        #expect(paths.contains("README.md"))
        #expect(paths.contains("_trash/README.md"))
        #expect(await h.fake.commitInfo(head)?.message.contains("(+3)") == true)
    }

    @Test func aCreatedNoteLands() async throws {
        let h = try Harness()
        await h.sync()
        let p = try h.store.createNote(folder: nil, text: "# Idea\nsomething\n")
        await h.sync()
        #expect(await h.fake.text(p) == "# Idea\nsomething\n")
        #expect(h.store.status(of: p) == .synced)
        #expect(await h.fake.commitInfo(await h.fake.head)?.message.hasPrefix("notes: add ") == true)
        // Pushed: the name is fixed now.
        #expect(try h.store.save(path: p, text: "# Renamed title\nsomething\n") == p)
    }

    @Test func noOpEditMakesNoCommit() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        let original = h.local("todo.md")!
        try h.store.save(path: "todo.md", text: original + "x\n")
        try h.store.save(path: "todo.md", text: original)
        await h.sync()
        #expect(await h.fake.landed.count == before)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.status(of: "todo.md") == .synced)
    }

    @Test func race422MergesAndRetries() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        try h.store.save(path: "notes/alpha.md", text: alpha.replacingOccurrences(of: "line one", with: "line one mine"))
        let bot = alpha.replacingOccurrences(of: "line four", with: "line four bot")
        await h.fake.beforeNextUpdateRef { fake in
            await fake.commitRemote([("notes/alpha.md", bot)])
        }
        #expect(await h.sync() == .idle)
        let remote = await h.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one mine"))
        #expect(remote.contains("line four bot"))
        #expect(h.local("notes/alpha.md") == remote)
        #expect(await h.fake.count(.updateRef) == 2)
        #expect(h.clock.sleeps.contains { $0 >= 1 && $0 <= 4 }, "retry waits 1 to 4 s")
        #expect(h.attention().isEmpty)
        #expect(await h.fake.commitInfo(await h.fake.head)?.parents.count == 1)
    }

    @Test func threeLostRacesGoToNeedsAttentionAndKeepTheOp() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        for i in 0..<4 {
            await h.fake.beforeNextUpdateRef { fake in
                await fake.commitRemote([("people/noa.md", "# Noa\nrace \(i)\n")])
            }
        }
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "push-failed")
        #expect(h.store.journal.outboxCount() == 1)
        #expect(await h.fake.count(.updateRef) == 4)
        // Next run has no race: the op lands and the item closes.
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
        #expect(h.attention().isEmpty)
    }

    @Test func sameLineClashMakesACopyInTheSameCommit() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        let mine = alpha.replacingOccurrences(of: "line one", with: "line one MINE")
        try h.store.save(path: "notes/alpha.md", text: mine)
        await h.fake.commitRemote([("notes/alpha.md", alpha.replacingOccurrences(of: "line one", with: "line one THEIRS"))])
        let state = await h.sync()
        #expect(state == .needsAttention(1))

        let theirs = await h.fake.text("notes/alpha.md")!
        #expect(theirs.contains("line one THEIRS"))
        #expect(h.local("notes/alpha.md") == theirs)
        let item = h.attention()[0]
        #expect(item.reason == "conflict-copy")
        #expect(item.path == "notes/alpha.md")
        let copyPath = try #require(item.copyPath)
        #expect(copyPath.hasPrefix("_inbox/conflict-notes-alpha-"))
        let copy = try #require(await h.fake.text(copyPath))
        #expect(copy.hasPrefix("---\ntype: conflict\nconflict_of: \"notes/alpha.md\"\ndevice: \"test-"))
        #expect(ConflictCopy(text: copy)?.mine == mine)
        #expect(h.local(copyPath) == copy)
        // The copy landed in one commit, with a trailer.
        let head = await h.fake.head
        #expect(try await h.fake.changedPaths(in: head) == [copyPath])
        #expect(h.store.index.note(path: copyPath)?.isConflictCopy == true)
        #expect(h.store.status(of: "notes/alpha.md") == .needsAttention)
    }

    @Test func cleanSectionsStillMergeBesideAClash() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        let mine = alpha.replacingOccurrences(of: "line one", with: "line one MINE").replacingOccurrences(of: "line four", with: "line four MINE")
        try h.store.save(path: "notes/alpha.md", text: mine)
        await h.fake.commitRemote([("notes/alpha.md", alpha.replacingOccurrences(of: "line one", with: "line one THEIRS"))])
        await h.sync()
        let note = await h.fake.text("notes/alpha.md")!
        #expect(note.contains("line one THEIRS"), "the clashing section keeps GitHub's version")
        #expect(note.contains("line four MINE"), "the clean section merges")
        #expect(h.attention().count == 1)
        #expect(ConflictCopy(text: await h.fake.text(h.attention()[0].copyPath!)!)?.mine == mine)
    }

    @Test func offlineEditsOnTwentyNotesAndABotOnFive() async throws {
        var seed = Harness.seed
        for i in 0..<20 { seed.append(("work/n\(i).md", "# N\(i)\n\n## A\nmine here\n\n## B\ntheirs here\n")) }
        let h = try Harness(files: seed)
        await h.sync()
        await h.engine.setOnline(false)
        for i in 0..<20 {
            try h.store.save(path: "work/n\(i).md", text: "# N\(i)\n\n## A\nmine edited\n\n## B\ntheirs here\n")
        }
        #expect(await h.sync() == .offline)
        #expect(h.store.journal.outboxCount() == 20)
        // The bot edits another section in 3 notes and the same line in 2.
        for i in 0..<3 {
            await h.fake.commitRemote([("work/n\(i).md", "# N\(i)\n\n## A\nmine here\n\n## B\ntheirs edited\n")])
        }
        for i in 3..<5 {
            await h.fake.commitRemote([("work/n\(i).md", "# N\(i)\n\n## A\nbot edited\n\n## B\ntheirs here\n")])
        }
        let before = await h.fake.landed.count
        await h.engine.setOnline(true)
        #expect(await h.engine.snapshot.state == .needsAttention(2))
        #expect(await h.fake.landed.count == before + 1, "one commit for all of it")
        for i in 0..<3 {
            let t = await h.fake.text("work/n\(i).md")!
            #expect(t.contains("mine edited") && t.contains("theirs edited"))
        }
        for i in 3..<5 {
            let t = await h.fake.text("work/n\(i).md")!
            #expect(t.contains("bot edited") && !t.contains("mine edited"))
        }
        for i in 5..<20 { #expect(await h.fake.text("work/n\(i).md")?.contains("mine edited") == true) }
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func textTypedDuringAPushIsKept() async throws {
        let h = try Harness()
        await h.sync()
        let original = h.local("todo.md")!
        let pushed = original + "- pushed\n"
        let typed = pushed + "- typed during the push\n"
        try h.store.save(path: "todo.md", text: pushed)
        let store = h.store
        await h.fake.beforeNextUpdateRef { _ in
            _ = try? store.save(path: "todo.md", text: typed)
        }
        await h.sync()
        #expect(await h.fake.text("todo.md") == pushed)
        #expect(h.local("todo.md") == typed, "the newer text stays on disk")
        #expect(h.store.status(of: "todo.md") == .savedOnDevice)
        let op = try #require(h.store.journal.outbox().first)
        #expect(op.kind == .edit)
        #expect(!op.inFlight)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == typed)
        #expect(h.store.status(of: "todo.md") == .synced)
    }

    @Test func textTypedDuringAMergedPushKeepsTheOtherSidesChange() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        let mine1 = alpha.replacingOccurrences(of: "line one", with: "line one mine")
        let mine2 = mine1.replacingOccurrences(of: "line two", with: "line two typed later")
        try h.store.save(path: "notes/alpha.md", text: mine1)
        await h.fake.commitRemote([("notes/alpha.md", alpha.replacingOccurrences(of: "line four", with: "line four bot"))])
        let store = h.store
        await h.fake.beforeNextUpdateRef { _ in
            _ = try? store.save(path: "notes/alpha.md", text: mine2)
        }
        await h.sync()
        h.clock.advance(120)
        await h.sync()
        let remote = await h.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one mine"))
        #expect(remote.contains("line two typed later"))
        #expect(remote.contains("line four bot"), "the bot's line must survive the second push")
        #expect(h.local("notes/alpha.md") == remote)
    }

    /// The commit leaves GitHub's text in the note (a clash) while I keep typing. What I typed afterwards
    /// must merge onto GitHub's text, not replace it: my text from before the clash is in the copy.
    @Test func textTypedDuringAClashPushDoesNotOverwriteGitHubsVersion() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        let mine = alpha.replacingOccurrences(of: "line one", with: "line one MINE")
        let typed = mine + "typed later\n"
        try h.store.save(path: "notes/alpha.md", text: mine)
        await h.fake.commitRemote([("notes/alpha.md", alpha.replacingOccurrences(of: "line one", with: "line one THEIRS"))])
        let store = h.store
        await h.fake.beforeNextUpdateRef { _ in _ = try? store.save(path: "notes/alpha.md", text: typed) }
        await h.sync()
        #expect(h.local("notes/alpha.md") == typed, "nothing typed is replaced on disk while it waits")
        h.clock.advance(120)
        await h.sync()
        let remote = await h.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one THEIRS"))
        #expect(remote.contains("typed later"))
        #expect(!remote.contains("line one MINE"))
        let copy = try #require(h.attention().first?.copyPath)
        #expect(ConflictCopy(text: await h.fake.text(copy)!)?.mine == mine)
        #expect(h.local("notes/alpha.md") == remote)
    }

    @Test func anEditorHoldingOlderTextMergesInsteadOfOverwriting() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        // The editor opened `alpha`. A clean pull changes the note underneath it.
        await h.fake.commitRemote([("notes/alpha.md", alpha.replacingOccurrences(of: "line four", with: "line four bot"))])
        await h.sync()
        // The editor saves text derived from what it loaded.
        try h.store.save(path: "notes/alpha.md", text: alpha.replacingOccurrences(of: "line one", with: "line one typed"), editingFrom: alpha)
        await h.sync()
        let remote = await h.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one typed"))
        #expect(remote.contains("line four bot"))
        #expect(h.local("notes/alpha.md") == remote)
    }
}

@Suite struct LostResponseTests {
    @Test func lostResponseMakesNoDuplicateCommit() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .lostResponse)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.landed.count == before + 1)
        #expect(await h.fake.count(.updateRef) == 1, "no second ref update: the first one landed")
        #expect(await h.fake.count(.createCommit) == 1)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.store.journal.baseCommit == (await h.fake.head))
    }

    @Test func aRequestThatNeverArrivedIsRetriedWithTheSameSha() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .error(.timedOut))
        #expect(await h.sync() == .idle)
        let attempts = await h.fake.refUpdateAttempts
        // The failed call never reached the fake's log; the retry did, with the commit already made.
        #expect(attempts.count == 1)
        #expect(await h.fake.count(.updateRef) == 2)
        #expect(await h.fake.count(.createCommit) == 1, "the same commit, not a new one")
        #expect(attempts.last == (await h.fake.head))
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func killAfterALostResponseResolvesAtNextLaunch() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .lostResponse)
        await h.fake.inject(.getRef, .error(.timedOut))  // the verify read fails too
        // The first getRef of the run takes the fault, so fail the one in verify: consume with a clean start.
        await h.fake.clearFaults()
        await h.fake.inject(.updateRef, .lostResponse)
        let fake = h.fake
        // Fail the read that happens during Verifying only.
        await h.fake.beforeNextUpdateRef { f in await f.inject(.getRef, .error(.timedOut)) }
        _ = fake
        let state = await h.sync()
        if case .retrying = state {} else { Issue.record("expected retrying, got \(state)") }
        #expect(h.store.journal.pendingPush() != nil)
        #expect(h.store.journal.outboxCount() == 1)

        try h.relaunch()
        #expect(await h.sync() == .idle)
        #expect(await h.fake.landed.count == before + 1, "exactly one commit")
        #expect(h.store.journal.pendingPush() == nil)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.status(of: "todo.md") == .synced)
        #expect(h.local("todo.md") == "# Todo\nmine\n")
    }

    @Test func killBeforeTheRefUpdateRetriesTheSameCommitAtLaunch() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .error(.timedOut))  // never reached GitHub
        await h.fake.inject(.compare, .error(.timedOut))    // verify cannot finish
        _ = await h.sync()
        let pending = try #require(h.store.journal.pendingPush())
        try h.relaunch()
        #expect(await h.sync() == .idle)
        #expect(await h.fake.head == pending.commit, "the same sha lands")
        #expect(await h.fake.count(.createCommit) == 1)
    }

    @Test func aPendingPushOverriddenByAnotherWriterIsRebuilt() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .error(.timedOut))
        await h.fake.inject(.compare, .error(.timedOut))
        _ = await h.sync()
        let dead = try #require(h.store.journal.pendingPush())
        await h.fake.commitRemote([("people/noa.md", "# Noa\nbot\n")])
        try h.relaunch()
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
        #expect(await h.fake.text("people/noa.md") == "# Noa\nbot\n")
        #expect(await h.fake.head != dead.commit)
        #expect(h.store.journal.pendingPush() == nil)
    }

    @Test func commitLandedThenAnotherCommitOnTop() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .lostResponse)
        await h.fake.beforeNextUpdateRef { f in await f.inject(.getRef, .error(.timedOut)) }
        _ = await h.sync()
        await h.fake.commitRemote([("people/noa.md", "# Noa\nbot\n")])
        let before = await h.fake.landed.count
        try h.relaunch()
        #expect(await h.sync() == .idle, "compare reports head ahead of our commit: it landed")
        #expect(await h.fake.landed.count == before)
        #expect(h.local("people/noa.md") == "# Noa\nbot\n")
        #expect(h.store.journal.outboxCount() == 0)
    }

    /// The trap in the plan's wording: `compare ours...head` = "behind" means head is before our commit.
    @Test func behindDoesNotCountAsLanded() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .error(.timedOut))   // not applied
        await h.fake.inject(.updateRef, .error(.timedOut))   // the retry in verify, not applied either
        let state = await h.sync()
        if case .retrying = state {} else { Issue.record("expected retrying, got \(state)") }
        let c = try await h.fake.compare(base: try #require(h.store.journal.pendingPush()).commit, head: await h.fake.head)
        #expect(c.status == "behind")
        #expect(h.store.journal.outboxCount() == 1, "still pending: the commit is not on main")
        #expect(await h.fake.text("todo.md") != "# Todo\nmine\n")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
    }
}

@Suite struct ErrorStateTests {
    @Test func unauthorizedSignsOutAndKeepsEverything() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.getRef, .error(.unauthorized))
        #expect(await h.sync() == .signedOut)
        #expect(h.store.journal.outboxCount() == 1)
        #expect(h.local("todo.md") == "# Todo\nmine\n")
        let calls = await h.fake.count(.getRef)
        await h.engine.sync(.poll)
        #expect(await h.fake.count(.getRef) == calls, "no calls while signed out")
        try h.store.save(path: "notes/beta.md", text: "# Beta\nstill saving\n")
        await h.engine.signedIn()
        #expect(await h.engine.snapshot.state == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
        #expect(await h.fake.text("notes/beta.md") == "# Beta\nstill saving\n")
    }

    @Test func rateLimitPausesUntilThatTime() async throws {
        let h = try Harness()
        await h.sync()
        let until = h.clock.now.addingTimeInterval(600)
        await h.fake.inject(.getRef, .error(.rateLimited(until: until)))
        #expect(await h.sync() == .paused(.rateLimited(until: until)))
        // Saves continue, no API calls until the time passes.
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        let calls = await h.fake.count(.getRef)
        #expect(await h.sync() == .paused(.rateLimited(until: until)))
        #expect(await h.fake.count(.getRef) == calls)
        h.clock.advance(601)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
    }

    @Test func rateLimitOnThePushKeepsTheOp() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .error(.rateLimited(until: nil)))
        if case .paused = await h.sync() {} else { Issue.record("expected paused") }
        #expect(h.store.journal.pendingPush() == nil, "a 429 is a definite no: nothing to verify")
        #expect(h.store.journal.outboxCount() == 1)
    }

    @Test func accessLostStopsAndKeepsData() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.getRef, .error(.repoAccessLost))
        #expect(await h.sync() == .accessLost)
        #expect(h.store.journal.outboxCount() == 1)
        #expect(await h.sync() == .idle, "back as soon as the repo answers")
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
    }

    @Test func serverErrorsBackOff2_4_8UpTo5Minutes() async throws {
        let h = try Harness()
        await h.sync()
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            await h.fake.inject(.getRef, .error(.server(503)))
            let t0 = h.clock.now
            if case let .retrying(at) = await h.sync() {
                delays.append(at.timeIntervalSince(t0))
                h.clock.advance(at.timeIntervalSince(t0) + 1)
            } else {
                Issue.record("expected retrying")
            }
        }
        #expect(delays == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        #expect(await h.sync() == .idle)
        #expect(await h.engine.currentBackoffStep == 0)
    }

    @Test func pollWaitsOutTheBackoffButForegroundDoesNot() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.inject(.getRef, .error(.server(500)))
        _ = await h.sync()
        let calls = await h.fake.count(.getRef)
        await h.engine.sync(.poll)
        #expect(await h.fake.count(.getRef) == calls)
        await h.engine.sync(.foreground)
        #expect(await h.fake.count(.getRef) == calls + 1)
    }

    @Test func offlineMakesNoCallsThenCatchesUp() async throws {
        let h = try Harness()
        await h.sync()
        await h.engine.setOnline(false)
        try h.store.save(path: "todo.md", text: "# Todo\noffline edit\n")
        let calls = await h.fake.count(.getRef)
        #expect(await h.sync() == .offline)
        #expect(await h.fake.count(.getRef) == calls)
        await h.engine.setOnline(true)
        #expect(await h.engine.snapshot.state == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\noffline edit\n")
    }

    @Test func offlineErrorFromTheNetworkShowsOffline() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.inject(.getRef, .error(.offline))
        #expect(await h.sync() == .offline)
    }

    @Test func userPauseStopsEverythingAndSurvivesRelaunch() async throws {
        let h = try Harness()
        await h.sync()
        await h.engine.setPaused(true)
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        let calls = await h.fake.count(.getRef)
        #expect(await h.sync(.background) == .paused(.user))
        #expect(await h.fake.count(.getRef) == calls)
        try h.relaunch()
        #expect(await h.sync() == .paused(.user))
        await h.engine.setPaused(false)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nx\n")
    }

    @Test func aMergeOfOneRejectedNoteDoesNotHoldBackTheOthers() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nA\n")
        try h.store.save(path: "notes/beta.md", text: "# Beta\nB\n")
        await h.fake.inject(.createTree, .error(.unprocessable("invalid tree")))  // the batch
        await h.fake.inject(.createTree, .error(.unprocessable("invalid tree")))  // first alone
        #expect(await h.sync() == .needsAttention(1))
        let item = h.attention()[0]
        #expect(item.reason == "rejected")
        #expect(item.path == "todo.md")
        #expect(await h.fake.text("notes/beta.md") == "# Beta\nB\n")
        #expect(h.store.journal.outbox().first?.parked == true)
        // Editing the note unparks it and closes the item when it lands.
        try h.store.save(path: "todo.md", text: "# Todo\nA fixed\n")
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nA fixed\n")
        #expect(h.attention().isEmpty)
    }

    @Test func aRejectedRefUpdateParksTheOp() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nA\n")
        await h.fake.inject(.updateRef, .error(.unprocessable("Reference update failed")))
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "rejected")
        #expect(h.store.journal.pendingPush() == nil)
    }

    @Test func staleReadAfterOwnPushIsNotARewrite() async throws {
        let h = try Harness()
        await h.sync()
        let old = await h.fake.head
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.sync()
        // A lagging replica answers with the commit before ours, once.
        await h.fake.serveStaleRef(old, times: 1)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(h.attention().isEmpty)
        #expect(h.store.journal.baseCommit == (await h.fake.head))
    }

    @Test func rewrittenMainStopsAndAFreshSyncKeepsLocalEditsAsCopies() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmy unsynced line\n")
        let p = try h.store.createNote(folder: nil, text: "# New note\nnever pushed\n")
        await h.fake.forcePushForTest(files: [("rewritten.md", "# Rewritten\n"), ("todo.md", "# Todo\nrewritten\n")])
        #expect(await h.sync() == .needsAttention(1))
        let item = h.attention()[0]
        #expect(item.reason == "history-rewritten")
        let calls = await h.fake.count(.createCommit)
        #expect(await h.sync() == .needsAttention(1), "stays stopped")
        #expect(await h.fake.count(.createCommit) == calls)
        #expect(h.local("todo.md") == "# Todo\nmy unsynced line\n", "local text untouched while stopped")

        await h.engine.freshSync()
        #expect(await h.engine.snapshot.state == .idle)
        #expect(await h.fake.text("rewritten.md") == "# Rewritten\n")
        #expect(h.local("rewritten.md") == "# Rewritten\n")
        #expect(h.local("todo.md") == "# Todo\nrewritten\n")
        #expect(h.local(p) == nil)
        let all = await h.fake.files()
        #expect(all.contains { $0.text.contains("my unsynced line") && $0.path.hasPrefix("_inbox/conflict-todo-") })
        #expect(all.contains { $0.text.contains("never pushed") && $0.path.hasPrefix("_inbox/conflict-") })
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func aFreshSyncDoesNotCopyAConflictCopy() async throws {
        let h = try Harness()
        await h.sync()
        let copyText = copyHeader("todo.md", device: "d", time: "2026-11-04T08:00:00Z") + "mine\n"
        try h.store.save(path: "_inbox/conflict-todo-20261104-080000.md", text: copyText)
        await h.fake.forcePushForTest(files: [("rewritten.md", "# Rewritten\n")])
        await h.sync()
        await h.engine.freshSync()
        let inbox = await h.fake.files().filter { $0.path.hasPrefix("_inbox/") }
        #expect(inbox.count == 1, "the copy, once")
        #expect(inbox.first?.text == copyText)
    }

    @Test func baseCommitGoneCountsAsRewritten() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.journal.setMeta(Journal.Key.baseCommit, String(repeating: "a", count: 40))
        try h.store.journal.setMeta(Journal.Key.refEtag, nil)
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "history-rewritten")
    }
}

@Suite struct DeleteTests {
    @Test func deleteMovesToTrashInOneCommit() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        try h.store.delete(path: "people/noa.md")
        #expect(h.local("people/noa.md") == nil)
        #expect(h.store.status(of: "people/noa.md") == .savedOnDevice)
        #expect(await h.store.index.search("Designer").isEmpty)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.has("people/noa.md") == false)
        #expect(await h.fake.text("_trash/people/noa.md") == "# Noa\nDesigner\n")
        #expect(await h.fake.landed.count == before + 1)
        #expect(h.store.journal.file("people/noa.md") == nil)
        #expect(h.local("_trash/people/noa.md") != nil)
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func aDeleteOfAnEditedNoteIsSkippedAndTheNoteComesBack() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.delete(path: "people/noa.md")
        await h.fake.commitRemote([("people/noa.md", "# Noa\nEdited on GitHub\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "delete-skipped")
        #expect(await h.fake.text("people/noa.md") == "# Noa\nEdited on GitHub\n")
        #expect(h.local("people/noa.md") == "# Noa\nEdited on GitHub\n")
        #expect(await h.store.index.search("Edited").count == 1)
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func aDeleteOfANoteAlreadyGoneIsANoop() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.delete(path: "people/noa.md")
        await h.fake.commitRemote([("people/noa.md", nil)])
        let before = await h.fake.landed.count
        #expect(await h.sync() == .idle)
        #expect(await h.fake.landed.count == before, "never a sha null for a missing path")
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.journal.file("people/noa.md") == nil)
    }

    @Test func remoteDeleteOfACleanNoteRemovesIt() async throws {
        let h = try Harness()
        await h.sync()
        await h.fake.commitRemote([("people/noa.md", nil)])
        #expect(await h.sync() == .idle)
        #expect(h.local("people/noa.md") == nil)
        #expect(h.store.journal.file("people/noa.md") == nil)
    }

    @Test func remoteDeleteOfADirtyNoteRestoresMineAsACopy() async throws {
        let h = try Harness()
        await h.sync()
        let mine = "# Noa\nDesigner\nmy unsynced line\n"
        try h.store.save(path: "people/noa.md", text: mine)
        await h.fake.commitRemote([("people/noa.md", nil)])
        #expect(await h.sync() == .needsAttention(1))
        let item = h.attention()[0]
        #expect(item.reason == "conflict-copy")
        #expect(item.detail == "deleted-remotely")
        let copyPath = try #require(item.copyPath)
        #expect(ConflictCopy(text: await h.fake.text(copyPath)!)?.mine == mine)
        #expect(await h.fake.has("people/noa.md") == false, "the delete stands")
        #expect(h.local("people/noa.md") == nil)
        #expect(h.local(copyPath) != nil)
        #expect(h.store.journal.outboxCount() == 0)
    }
}

@Suite struct PolicyInSyncTests {
    @Test func blockedPathStaysLocalAndGoesToNeedsAttention() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        try h.store.save(path: "private/mine.md", text: "not for GitHub\n")
        try h.store.save(path: ".hidden/x.md", text: "nor this\n")
        try h.store.save(path: "todo.md", text: "# Todo\nallowed\n")
        #expect(await h.sync() == .needsAttention(2))
        #expect(Set(h.attention().map(\.reason)) == ["blocked:blocked-folder", "blocked:dot-segment"])
        #expect(await h.fake.has("private/mine.md") == false)
        #expect(await h.fake.has(".hidden/x.md") == false)
        #expect(await h.fake.text("todo.md") == "# Todo\nallowed\n")
        #expect(await h.fake.landed.count == before + 1)
        #expect(h.store.journal.outboxCount() == 2, "blocked ops stay")
        #expect(h.local("private/mine.md") == "not for GitHub\n", "text is not lost")
        // A later run does not pile up more items.
        h.clock.advance(120)
        #expect(await h.sync() == .needsAttention(2))
    }

    @Test func secretBlocksTheCommitUntilFixed() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\ntoken " + Fixture.githubToken + "\n")
        try h.store.save(path: "notes/beta.md", text: "# Beta\nfine\n")
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "blocked:secret:github-token")
        #expect(h.attention()[0].path == "todo.md")
        #expect(await h.fake.text("todo.md") == "# Todo\n- one\n- two\n")
        #expect(await h.fake.text("notes/beta.md") == "# Beta\nfine\n", "the other note still lands")
        #expect(h.store.status(of: "todo.md") == .needsAttention)
        // No secret ever reached a blob.
        for f in await h.fake.files() { #expect(!f.text.contains(Fixture.githubToken)) }

        try h.store.save(path: "todo.md", text: "# Todo\nno token now\n")
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nno token now\n")
        #expect(h.attention().isEmpty)
    }

    @Test func aSecretAlreadyOnGitHubDoesNotBlockOtherEdits() async throws {
        let line = Fixture.apiKeyLine
        let h = try Harness(files: [("a.md", "# A\n" + line + "\n")])
        await h.sync()
        try h.store.save(path: "a.md", text: "# A\n" + line + "\nnew line\n")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("a.md")?.contains("new line") == true)
    }

    @Test func tooLargeStaysInTheOutbox() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: String(repeating: "x", count: maxNoteBytes + 1))
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "blocked:too-large")
        #expect(await h.fake.text("todo.md") == "# Todo\n- one\n- two\n")
        #expect(h.store.journal.outboxCount() == 1)
    }
}

@Suite struct HebrewAndNormalizationTests {
    private let nfdFolder = "Cafe\u{301}"
    private let nfcFolder = "Caf\u{E9}"

    @Test func existingNfdPathKeepsItsBytes() async throws {
        let nfdPath = "\(nfdFolder)/שלום.md"
        let h = try Harness(files: [(nfdPath, "# שלום\nבוקר טוב\n")])
        await h.sync()
        try h.store.save(path: nfdPath, text: "# שלום\nבוקר טוב\nעוד שורה\n")
        #expect(await h.sync() == .idle)
        let paths = await h.fake.files().map(\.path)
        #expect(paths.count == 1)
        #expect(sameBytes(paths[0], nfdPath), "exact bytes kept on GitHub")
        #expect(await h.fake.text(nfdPath)?.contains("עוד שורה") == true)
    }

    @Test func aNewNoteGetsAnNfcPath() async throws {
        let h = try Harness()
        await h.sync()
        let p = try h.store.createNote(folder: "עברית", text: "Cafe\u{301} בעברית\n")
        #expect(sameBytes(p, nfc(p)))
        await h.sync()
        #expect(await h.fake.files().contains { sameBytes($0.path, p) })
    }

    @Test func nfcAndNfdTwinsOnGitHubDoNotCollapse() async throws {
        let a = "\(nfcFolder).md", b = "\(nfdFolder).md"
        let h = try Harness(files: [(a, "nfc twin\n"), (b, "nfd twin\n")])
        await h.sync()
        // One is stored here, the other stays on GitHub, and neither is lost.
        #expect(h.store.journal.allFiles().filter(\.local).count == 1)
        #expect(h.store.journal.allFiles().count == 2)
        let stored = h.store.journal.allFiles().first(where: \.local)!.path
        try h.store.save(path: stored, text: "edited\n")
        await h.sync()
        let files = await h.fake.files()
        #expect(files.count == 2)
        #expect(files.contains { $0.text == "edited\n" })
        #expect(files.contains { $0.text.hasSuffix("twin\n") })
    }

    @Test func hebrewConflictCopyPath() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "עברית/רעיון.md", text: "# רעיון\nשלי\n")
        await h.fake.commitRemote([("עברית/רעיון.md", "# רעיון\nשלהם\n")])
        #expect(await h.sync() == .needsAttention(1))
        let copy = try #require(h.attention()[0].copyPath)
        #expect(copy.hasPrefix("_inbox/conflict-עברית-רעיון-"))
        #expect(await h.fake.text(copy)?.contains("שלי") == true)
        #expect(await h.store.index.search("שלהם").count == 1)
    }

    @Test func nfdPathSurvivesThePendingRecord() async throws {
        let nfdPath = "\(nfdFolder)/a.md"
        let h = try Harness(files: [(nfdPath, "x\n")])
        await h.sync()
        try h.store.save(path: nfdPath, text: "y\n")
        await h.fake.inject(.updateRef, .lostResponse)
        #expect(await h.sync() == .idle)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(h.store.journal.allFiles().contains { sameBytes($0.path, nfdPath) && !$0.dirty })
    }
}

@Suite struct TriggerTests {
    @Test func pollWaitsForIdleThenPushes() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        await h.engine.noteSaved()
        h.clock.advance(10)
        await h.engine.sync(.poll)
        #expect(h.store.journal.outboxCount() == 1, "still typing")
        h.clock.advance(25)
        await h.engine.sync(.poll)
        #expect(h.store.journal.outboxCount() == 0, "30 s idle")
    }

    @Test func atMostOneCommitAMinute() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nfirst\n")
        await h.engine.sync(.leftNote)
        #expect(h.store.journal.outboxCount() == 0)
        let before = await h.fake.landed.count

        try h.store.save(path: "todo.md", text: "# Todo\nsecond\n")
        h.clock.advance(20)
        await h.engine.sync(.leftNote)
        #expect(h.store.journal.outboxCount() == 1, "within the minute: waits")
        #expect(await h.fake.landed.count == before)

        h.clock.advance(41)
        await h.engine.sync(.leftNote)
        #expect(h.store.journal.outboxCount() == 0)
        #expect(await h.fake.landed.count == before + 1)
    }

    @Test func leavingTheAppBypassesTheCap() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nfirst\n")
        await h.engine.sync(.leftNote)
        try h.store.save(path: "todo.md", text: "# Todo\nsecond\n")
        await h.engine.noteSaved()
        await h.engine.sync(.background)
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func snapshotCountsAndTheOneDayBadge() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        await h.engine.noteSaved()
        let s = await h.engine.snapshot
        #expect(s.unsynced == 1)
        #expect(!s.unsyncedTooLong(now: h.clock.now))
        #expect(s.unsyncedTooLong(now: h.clock.now.addingTimeInterval(25 * 3600)))
        #expect(s.lastSync != nil)
        #expect(s.hasFirstSynced)
    }

    @Test func aBlockedOpDoesNotMakeTheSchedulerSpin() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\ntoken " + Fixture.githubToken + "\n")
        await h.engine.noteSaved()
        h.clock.advance(120)
        await h.sync(.poll)
        #expect(h.store.journal.outboxCount() == 1, "the op stays, blocked")
        #expect(await h.engine.delayUntilNextWake == 60, "the next wake is the normal poll")
        // A new edit brings the earlier flush back.
        h.clock.advance(1)
        try h.store.save(path: "todo.md", text: "# Todo\nclean now\n")
        await h.engine.noteSaved()
        #expect(await h.engine.delayUntilNextWake == 30)
    }

    @Test func theCapDelaysTheWake() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nfirst\n")
        await h.engine.sync(.leftNote)
        h.clock.advance(5)
        try h.store.save(path: "todo.md", text: "# Todo\nsecond\n")
        await h.engine.noteSaved()
        #expect(await h.engine.delayUntilNextWake == 55, "60 s since the last commit beats the 30 s idle wait")
    }

    @Test func aSecondRunWaitsForTheFirst() async throws {
        let h = try Harness()
        async let a: Void = h.engine.sync(.manual)
        async let b: Void = h.engine.sync(.manual)
        _ = await (a, b)
        #expect(await h.fake.count(.tarball) == 1)
        #expect(h.store.journal.baseCommit != nil)
    }
}

@Suite struct LaunchRepairTests {
    @Test func aFileChangedOutsideTheJournalIsALocalEdit() async throws {
        let h = try Harness()
        await h.sync()
        let tampered = h.local("notes/alpha.md")!.replacingOccurrences(of: "line one", with: "line one edited on disk")
        try h.store.files.write("notes/alpha.md", tampered)
        await h.fake.commitRemote([("notes/alpha.md", h.local("notes/alpha.md")!.replacingOccurrences(of: "line four", with: "line four bot"))])
        try h.relaunch()
        let r = try h.store.reconcile()
        #expect(r.edited == ["notes/alpha.md"])
        #expect(h.store.journal.outbox()[0].kind == .edit)
        await h.sync()
        let remote = await h.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one edited on disk"), "not overwritten")
        #expect(remote.contains("line four bot"))
    }

    @Test func aMissingFileIsDownloadedNotDeleted() async throws {
        let h = try Harness()
        await h.sync()
        let before = await h.fake.landed.count
        try FileManager.default.removeItem(at: try h.store.files.url(for: "notes/beta.md"))
        try h.relaunch()
        let r = try h.store.reconcile()
        #expect(r.missing == ["notes/beta.md"])
        #expect(h.store.journal.outboxCount() == 0)
        await h.sync()
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
        #expect(await h.fake.landed.count == before, "nothing was pushed")
        #expect(await h.fake.has("notes/beta.md"))
    }

    @Test func unsyncedTextComesBackFromTheOutboxAfterARestore() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nonly on this phone\n")
        // A restored backup holds the journal but not the note files.
        try FileManager.default.removeItem(at: h.store.files.filesRoot)
        try h.relaunch()
        let r = try h.store.reconcile()
        #expect(r.edited.isEmpty)
        #expect(h.local("todo.md") == "# Todo\nonly on this phone\n")
        await h.sync()
        #expect(await h.fake.text("todo.md") == "# Todo\nonly on this phone\n")
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n", "the rest comes back from GitHub")
    }

    /// Two pieces of launch work racing a save: both must leave the save alone.
    @Test func aSaveDuringTheMissingFileDownloadIsKept() async throws {
        struct SavingClient: GitHubClient {
            let fake: FakeGitHub
            let onBlob: @Sendable () -> Void
            func blob(_ sha: String) async throws -> Data {
                onBlob()
                return try await fake.blob(sha)
            }
            func getRef(etag: String?) async throws -> RefResult { try await fake.getRef(etag: etag) }
            func getCommit(_ sha: String) async throws -> CommitInfo { try await fake.getCommit(sha) }
            func compare(base: String, head: String) async throws -> Comparison { try await fake.compare(base: base, head: head) }
            func tree(_ sha: String) async throws -> [TreeEntry] { try await fake.tree(sha) }
            func tarball(_ sha: String) async throws -> Data { try await fake.tarball(sha) }
            func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String { try await fake.createTree(baseTree: baseTree, writes: writes) }
            func createCommit(_ commit: NewCommit) async throws -> String { try await fake.createCommit(commit) }
            func updateRef(to sha: String) async throws { try await fake.updateRef(to: sha) }
            func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] { try await fake.lastCommitDates(head: head, paths: paths) }
        }
        final class Box: @unchecked Sendable { var store: NoteStore? }
        let box = Box()
        let fake = FakeGitHub(files: Harness.seed)
        let client = SavingClient(fake: fake) { _ = try? box.store?.save(path: "notes/beta.md", text: "# Beta\ntyped during the download\n") }
        let h = try Harness(fake: fake, client: client)
        await h.sync()
        try FileManager.default.removeItem(at: try h.store.files.url(for: "notes/beta.md"))
        box.store = h.store
        await h.engine.sync(.poll)
        #expect(h.local("notes/beta.md") == "# Beta\ntyped during the download\n")
    }

    @Test func aSecondEditorSavingOverOtherTextKeepsThatTextAsACopy() async throws {
        let h = try Harness()
        await h.sync()
        let base = h.local("todo.md")!
        try h.store.save(path: "todo.md", text: base + "- from the first window\n", editingFrom: base)
        // A second window opened before that save and now saves its own text.
        try h.store.save(path: "todo.md", text: base + "- from the second window\n", editingFrom: base)
        #expect(h.local("todo.md") == base + "- from the second window\n")
        h.clock.advance(120)
        await h.sync()
        let all = await h.fake.files().map(\.text).joined()
        #expect(all.contains("from the first window"), "kept in a copy")
        #expect(all.contains("from the second window"))
    }

    @Test func cleanFilesCostNoHashing() async throws {
        let h = try Harness()
        await h.sync()
        let r = try h.store.reconcile()
        #expect(r == NoteStore.ReconcileResult())
    }

    @Test func indexIsRebuiltWhenItFellBehind() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.index.clear()
        try h.store.index.setStamp("old")
        try h.relaunch()
        try h.store.repairIndexIfNeeded()
        #expect(h.store.index.count() == 7)
    }

    @Test func aKillBetweenCommitAndIndexRepairsTheOutboxNotes() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nfindme\n")
        try h.store.index.remove(path: "todo.md")
        try h.relaunch()
        try h.store.reconcile()
        #expect(await h.store.index.search("findme").count == 1)
    }

    @Test func inFlightFlagResetsAtLaunch() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nx\n")
        try h.store.journal.transaction { db in try db.execute(sql: "UPDATE outbox SET in_flight = 1") }
        #expect(h.store.status(of: "todo.md") == .syncing)
        try h.relaunch()
        #expect(h.store.status(of: "todo.md") == .savedOnDevice)
    }
}

@Suite struct AttentionActionTests {
    /// A conflict on `notes/alpha.md`. Returns the item, mine and theirs.
    private func conflict(_ h: Harness) async throws -> (AttentionItem, String, String) {
        await h.sync()
        let alpha = h.local("notes/alpha.md")!
        let mine = alpha.replacingOccurrences(of: "line one", with: "line one MINE")
        let theirs = alpha.replacingOccurrences(of: "line one", with: "line one THEIRS")
        try h.store.save(path: "notes/alpha.md", text: mine)
        await h.fake.commitRemote([("notes/alpha.md", theirs)])
        await h.sync()
        return (h.attention()[0], mine, theirs)
    }

    @Test func textsShowBothSides() async throws {
        let h = try Harness()
        let (item, mine, theirs) = try await conflict(h)
        let t = h.store.texts(for: item)
        #expect(t.mine == mine)
        #expect(t.theirs == theirs)
    }

    @Test func keepBothKeepsBoth() async throws {
        let h = try Harness()
        let (item, mine, theirs) = try await conflict(h)
        try h.store.resolve(item, .keepBoth)
        #expect(h.attention().isEmpty)
        #expect(h.local("notes/alpha.md") == theirs)
        #expect(ConflictCopy(text: h.local(item.copyPath!)!)?.mine == mine)
        #expect(h.store.status(of: "notes/alpha.md") == .synced)
    }

    @Test func useMineSwapsAndKeepsTheOtherVersionInTheCopy() async throws {
        let h = try Harness()
        let (item, mine, theirs) = try await conflict(h)
        try h.store.resolve(item, .useMine)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("notes/alpha.md") == mine)
        let copy = try #require(await h.fake.text(item.copyPath!))
        #expect(ConflictCopy(text: copy)?.mine == theirs, "the replaced version stays in the copy")
    }

    @Test func useTheirsMovesTheCopyToTrash() async throws {
        let h = try Harness()
        let (item, mine, theirs) = try await conflict(h)
        try h.store.resolve(item, .useTheirs)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("notes/alpha.md") == theirs)
        #expect(await h.fake.has(item.copyPath!) == false)
        #expect(ConflictCopy(text: await h.fake.text("_trash/" + item.copyPath!)!)?.mine == mine, "text kept in _trash")
    }

    @Test func restoreBringsADeletedNoteBack() async throws {
        let h = try Harness()
        await h.sync()
        let mine = "# Noa\nDesigner\nmine\n"
        try h.store.save(path: "people/noa.md", text: mine)
        await h.fake.commitRemote([("people/noa.md", nil)])
        await h.sync()
        let item = h.attention()[0]
        try h.store.resolve(item, .restore)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("people/noa.md") == mine)
        #expect(await h.fake.has(item.copyPath!) == false)
        #expect(await h.fake.has("_trash/" + item.copyPath!))
    }

    @Test func deleteAnywayAfterASkippedDelete() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.delete(path: "people/noa.md")
        await h.fake.commitRemote([("people/noa.md", "# Noa\nEdited\n")])
        await h.sync()
        try h.store.resolve(h.attention()[0], .deleteAnyway)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.has("people/noa.md") == false)
        #expect(await h.fake.text("_trash/people/noa.md") == "# Noa\nEdited\n")
    }

    @Test func retryUnparks() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nA\n")
        await h.fake.inject(.updateRef, .error(.unprocessable("nope")))
        await h.sync()
        try h.store.resolve(h.attention()[0], .retry)
        #expect(h.store.journal.outbox()[0].parked == false)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nA\n")
    }
}

@Suite struct TwoDeviceTests {
    @Test func bothEditDifferentSectionsAndBothEndUpTheSame() async throws {
        let a = try Harness()
        let b = try a.secondDevice()
        await a.sync()
        await b.sync()
        let alpha = a.local("notes/alpha.md")!
        try a.store.save(path: "notes/alpha.md", text: alpha.replacingOccurrences(of: "line one", with: "line one A"))
        try b.store.save(path: "notes/alpha.md", text: alpha.replacingOccurrences(of: "line four", with: "line four B"))
        await a.sync()
        await b.sync()
        await a.sync()
        let remote = await a.fake.text("notes/alpha.md")!
        #expect(remote.contains("line one A") && remote.contains("line four B"))
        #expect(a.local("notes/alpha.md") == remote)
        #expect(b.local("notes/alpha.md") == remote)
        #expect(a.attention().isEmpty && b.attention().isEmpty)
    }

    @Test func bothPushAtTheSameMoment() async throws {
        let a = try Harness()
        let b = try a.secondDevice()
        await a.sync()
        await b.sync()
        try a.store.save(path: "todo.md", text: "# Todo\n- one\n- two\n- from a\n")
        try b.store.save(path: "notes/beta.md", text: "# Beta\nfrom b\n")
        async let x: Void = a.engine.sync(.manual)
        async let y: Void = b.engine.sync(.manual)
        _ = await (x, y)
        await a.sync()
        await b.sync()
        #expect(await a.fake.text("todo.md")?.contains("from a") == true)
        #expect(await a.fake.text("notes/beta.md") == "# Beta\nfrom b\n")
        #expect(a.store.journal.outboxCount() == 0 && b.store.journal.outboxCount() == 0)
        #expect(a.store.journal.baseCommit == b.store.journal.baseCommit)
    }

    @Test func sameLineOnTwoDevices() async throws {
        let a = try Harness()
        let b = try a.secondDevice()
        await a.sync()
        await b.sync()
        try a.store.save(path: "todo.md", text: "# Todo\n- one A\n- two\n")
        try b.store.save(path: "todo.md", text: "# Todo\n- one B\n- two\n")
        await a.sync()
        await b.sync()
        await a.sync()
        #expect(await a.fake.text("todo.md") == "# Todo\n- one A\n- two\n")
        #expect(b.local("todo.md") == "# Todo\n- one A\n- two\n")
        let copy = try #require(b.attention().first?.copyPath)
        #expect(ConflictCopy(text: await a.fake.text(copy)!)?.mine == "# Todo\n- one B\n- two\n")
        #expect(a.local(copy) != nil, "the other device gets the copy too")
    }
}

@Suite struct CommitRulesTests {
    /// Runs many kinds of commit, then checks each app commit: trailer last, fixed date form, one parent.
    @Test func everyAppCommitCarriesTheTrailer() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nA\n")
        await h.sync()
        h.clock.advance(120)
        try h.store.delete(path: "people/noa.md")
        await h.sync()
        h.clock.advance(120)
        _ = try h.store.createNote(folder: nil, text: "# New\n")
        await h.fake.inject(.updateRef, .lostResponse)
        await h.sync()
        h.clock.advance(120)
        try h.store.save(path: "notes/beta.md", text: "# Beta\nmine\n")
        await h.fake.commitRemote([("notes/beta.md", "# Beta\ntheirs\n")], message: "bot")
        await h.sync()

        let landed = await h.fake.landed
        var opIds = Set<String>()
        var appCommits = 0
        for sha in landed {
            let info = try #require(await h.fake.commitInfo(sha))
            if info.author == "bot" || info.author == "fixture" { continue }
            appCommits += 1
            let lines = info.message.split(separator: "\n").map(String.init)
            let op = try #require(lines.last)
            #expect(op.hasPrefix("Brain-Notes-Op: "))
            #expect(lines.contains { $0.hasPrefix("Brain-Notes-Device: ") })
            #expect(opIds.insert(op).inserted, "no op id twice: \(op)")
            #expect(info.parents.count == 1, "fast-forward commits only")
            #expect(info.date.hasSuffix("Z") && parseISOTime(info.date) != nil)
            #expect(info.author.contains("Brain Notes"))
        }
        #expect(appCommits == 4)
    }

    @Test func aRetryAfterARebaseKeepsDateAndOpId() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        let op = h.store.journal.outbox()[0]
        await h.fake.beforeNextUpdateRef { f in await f.commitRemote([("people/noa.md", "# Noa\nbot\n")]) }
        h.clock.advance(300)
        await h.sync()
        let info = try #require(await h.fake.commitInfo(await h.fake.head))
        #expect(info.date == op.opTime)
        #expect(info.message.hasSuffix("Brain-Notes-Op: \(op.opId)"))
    }

    @Test func anOpEditedAfterItsCommitGetsANewId() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nv1\n")
        let first = h.store.journal.outbox()[0].opId
        let store = h.store
        await h.fake.beforeNextUpdateRef { _ in _ = try? store.save(path: "todo.md", text: "# Todo\nv2\n") }
        await h.sync()
        let second = h.store.journal.outbox()[0].opId
        #expect(first != second)
    }
}

/// The engine reads only what it needs for a plan: the empty placeholders must not change any decision.
@Suite struct SparsePlanTests {
    private func plan(_ base: PathMap, _ theirs: PathMap, _ ops: [Op], renames: PathMap? = nil) throws -> PlanOutput {
        try planCommit(PlanInput(baseTree: base, theirsTree: theirs, ops: ops, renames: renames, device: "d", time: "2026-11-04T08:00:00Z"))
    }

    private func entries(_ p: PlanOutput) -> [String] {
        p.entries.map {
            switch $0 {
            case let .write(path, content): return "W \(path) \(GitBlob.sha(content))"
            case let .delete(path): return "D \(path)"
            }
        }
    }

    @Test func placeholdersDecideNothing() throws {
        let full = PathMap([("a.md", "A\n"), ("b.md", "B\n"), ("_trash/c.md", "C\n"), ("c.md", "C\n"), ("d/e.md", "E\n")])
        var sparse = PathMap()
        for k in full.keys { sparse[k] = "" }
        let cases: [[Op]] = [
            [.edit(path: "a.md", content: "A\nmine\n")],
            [.delete(path: "c.md")],
            [.create(path: "new.md", content: "new\n")],
            [.edit(path: "a.md", content: "x"), .delete(path: "b.md"), .create(path: "d/f.md", content: "y")],
        ]
        for ops in cases {
            var b = sparse, t = sparse
            for op in ops {
                b[op.path] = full[op.path]
                t[op.path] = full[op.path]
                if case .delete = op {
                    b["_trash/\(op.path)"] = full["_trash/\(op.path)"]
                    t["_trash/\(op.path)"] = full["_trash/\(op.path)"]
                }
            }
            let a = try plan(full, full, ops), c = try plan(b, t, ops)
            #expect(entries(a) == entries(c))
            #expect(a.kept == c.kept)
            #expect(a.noops == c.noops)
        }
    }
}

/// Replaces one file in the tarball, to prove the tree check catches it.
struct TamperingClient: GitHubClient {
    let fake: FakeGitHub
    init(_ fake: FakeGitHub) { self.fake = fake }

    func tarball(_ sha: String) async throws -> Data {
        let original = try await fake.tarball(sha)
        let entries = try TarReader.files(in: try Gzip.decompress(original))
        let tampered = entries.map { (path: $0.path, data: $0.path == "todo.md" ? Data("tampered".utf8) : $0.data) }
        return try Gzip.compress(TarWriter.archive(tampered, rootDir: "root"))
    }

    func getRef(etag: String?) async throws -> RefResult { try await fake.getRef(etag: etag) }
    func getCommit(_ sha: String) async throws -> CommitInfo { try await fake.getCommit(sha) }
    func compare(base: String, head: String) async throws -> Comparison { try await fake.compare(base: base, head: head) }
    func tree(_ sha: String) async throws -> [TreeEntry] { try await fake.tree(sha) }
    func blob(_ sha: String) async throws -> Data { try await fake.blob(sha) }
    func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String { try await fake.createTree(baseTree: baseTree, writes: writes) }
    func createCommit(_ commit: NewCommit) async throws -> String { try await fake.createCommit(commit) }
    func updateRef(to sha: String) async throws { try await fake.updateRef(to: sha) }
    func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] { try await fake.lastCommitDates(head: head, paths: paths) }
}
