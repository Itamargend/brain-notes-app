import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// Add to Brain: shared text, a link or a quick note becomes a new note in `_inbox`, queued like any save.
/// All content here is synthetic.
@Suite struct CaptureTests {
    /// 2026-10-26T07:33:20Z.
    private static let when = Date(timeIntervalSince1970: 1_793_000_000)

    private func makeStore() throws -> (NoteStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bn-capture-\(UUID().uuidString)", isDirectory: true)
        return (try NoteStore(root: folder, deviceLabel: "test", now: { Self.when }), folder)
    }

    private func note(_ capture: Capture) throws -> String {
        try CaptureNote.text(for: capture, created: Self.when)
    }

    // MARK: the note's text

    @Test func aQuickNoteGetsFrontmatterAndKeepsItsText() throws {
        let text = try note(Capture(text: "Call the printer about the flyers\nbefore Thursday", source: .quickNote))
        #expect(text == """
        ---
        type: capture
        created: "2026-10-26T07:33:20Z"
        source: "quick-note"
        ---
        Call the printer about the flyers
        before Thursday

        """)
        let (fm, body) = NoteText.split(text)
        #expect(NoteText.frontmatterValue(fm, key: "type") == "capture")
        #expect(NoteText.frontmatterValue(fm, key: "created") == "2026-10-26T07:33:20Z")
        #expect(NoteText.frontmatterValue(fm, key: "source") == "quick-note")
        #expect(body.hasPrefix("Call the printer"))
        #expect(NoteText.title(of: text, path: "_inbox/x.md") == "Call the printer about the flyers")
        #expect(!NoteText.isConflictCopy(text))
    }

    @Test func aSharedLinkWithATitleGetsAHeadingTheLinkAndAUrlField() throws {
        let url = URL(string: "https://example.com/articles/42?ref=share")!
        let text = try note(Capture(url: url, title: "How tide tables work", source: .share))
        #expect(text == """
        ---
        type: capture
        created: "2026-10-26T07:33:20Z"
        source: "share"
        url: "https://example.com/articles/42?ref=share"
        ---
        # How tide tables work

        https://example.com/articles/42?ref=share

        """)
    }

    @Test func aBareLinkIsNamedAfterItsHost() throws {
        let text = try note(Capture(url: URL(string: "https://example.org/a/b")!, source: .shortcut))
        #expect(NoteText.firstLine(of: text) == "# example.org")
        #expect(CaptureNote.fileStem(for: text) == "example.org")
    }

    @Test func aLinkAlreadyInTheTextIsNotRepeated() throws {
        let url = URL(string: "https://example.com/x")!
        let text = try note(Capture(text: "worth reading https://example.com/x", url: url, source: .share))
        #expect(text.components(separatedBy: "https://example.com/x").count == 3, "once in url:, once in the body")
    }

    @Test func aTitleTheTextAlreadyStartsWithIsNotRepeated() throws {
        let text = try note(Capture(text: "Tide tables\nlow at 6", title: "Tide tables", source: .share))
        #expect(NoteText.split(text).body == "Tide tables\nlow at 6\n")
    }

    @Test func aTitleIsOneLine() throws {
        let text = try note(Capture(text: "body", title: "  two\n  lines \r\n", source: .share))
        #expect(NoteText.firstLine(of: text) == "# two lines")
    }

    @Test func aTitleAloneIsEnough() throws {
        let text = try note(Capture(title: "Remember the keys", source: .quickNote))
        #expect(NoteText.split(text).body == "# Remember the keys\n")
    }

    @Test func lineEndingsBecomeNewlinesAndEdgesAreTrimmed() throws {
        let text = try note(Capture(text: "\n  \r\nfirst\r\nsecond\rthird  \n\n", source: .share))
        #expect(NoteText.split(text).body == "first\nsecond\nthird\n")
        #expect(!text.utf8.contains(0x0D))
    }

    @Test func aUserNameOrPasswordInALinkIsDropped() throws {
        let text = try note(Capture(url: URL(string: "https://someone:hunter2@example.com/private?q=1")!, source: .share))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("someone"))
        #expect(text.contains("url: \"https://example.com/private?q=1\""))
    }

    @Test func quotesInFrontmatterValuesAreEscaped() throws {
        let text = try note(Capture(url: URL(string: "https://example.com/a%22b")!, source: .share))
        #expect(text.contains("url: \"https://example.com/a%22b\""))
        let (fm, _) = NoteText.split(text)
        #expect(!fm.isEmpty, "the block still parses as frontmatter")
    }

    @Test func emptyCapturesAreRefused() {
        for capture in [Capture(source: .share), Capture(text: " \n\t\r\n", source: .quickNote), Capture(text: "", title: "  ", source: .shortcut)] {
            #expect(throws: CaptureProblem.empty) { try note(capture) }
        }
    }

    @Test func aSecretIsRefusedBeforeAnythingIsWritten() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for secret in [Fixture.githubToken, Fixture.awsKey, Fixture.privateKeyHeader, Fixture.apiKeyLine] {
            #expect(throws: CaptureProblem.self) { try store.capture(Capture(text: "pasted:\n" + secret, source: .share)) }
        }
        let tokenInLink = URL(string: "https://example.com/cb?access_token=" + String(repeating: "Zx9", count: 10))!
        #expect(throws: CaptureProblem.secret("api-key")) { try store.capture(Capture(url: tokenInLink, source: .share)) }
        #expect(store.journal.outbox().isEmpty)
        #expect(store.journal.allFiles().isEmpty)
    }

    @Test func overOneMebibyteIsRefused() throws {
        let big = String(repeating: "x", count: maxNoteBytes)
        #expect(throws: CaptureProblem.tooLarge) { try note(Capture(text: big, source: .share)) }
        // Just under the limit, frontmatter included, is fine.
        let header = try note(Capture(text: "x", source: .share)).utf8.count - 2
        _ = try note(Capture(text: String(repeating: "x", count: maxNoteBytes - header - 1), source: .share))
    }

    @Test func sourceValuesAreTheIntentsContract() {
        #expect(Capture.Source.allCases.map(\.rawValue) == ["share", "shortcut", "quick-note"])
    }

    // MARK: file names

    @Test func hebrewNamesStayHebrewWithoutInvisibleMarks() throws {
        let text = try note(Capture(text: "\u{200F}רעיון חדש על הגינה\nפרטים בהמשך", source: .quickNote))
        let stem = CaptureNote.fileStem(for: text)
        #expect(stem == "רעיון חדש על הגינה")
        #expect(!stem.unicodeScalars.contains { $0.properties.isDefaultIgnorableCodePoint })
    }

    @Test func namesAreNFC() throws {
        let stem = try CaptureNote.fileStem(for: note(Capture(text: "Cafe\u{301} notes", source: .share)))
        #expect(Array(stem.utf8) == Array("Caf\u{E9} notes".utf8))
    }

    @Test func charactersNoDiskTakesAreReplaced() throws {
        let stem = try CaptureNote.fileStem(for: note(Capture(text: "a/b\\c:d?e\"f<g>h|i", source: .share)))
        #expect(!stem.contains { "/\\:*?\"<>|".contains($0) }, "\(stem)")
        #expect(stem.hasPrefix("a-b-c-d"))
        #expect(checkPath(PathPolicy.inboxFolder + "/" + stem + ".md") == nil)
    }

    @Test func leadingDotsAndControlCharactersGo() throws {
        let stem = try CaptureNote.fileStem(for: note(Capture(text: "...hidden\u{7}name. ", source: .share)))
        #expect(stem == "hiddenname")
    }

    @Test func namesAreCappedInCharactersAndInBytes() throws {
        let hebrew = try CaptureNote.fileStem(for: note(Capture(text: String(repeating: "א", count: 200), source: .share)))
        #expect(hebrew.count == 60)
        #expect(hebrew.utf8.count == 120)

        let flags = try CaptureNote.fileStem(for: note(Capture(text: String(repeating: "🇮🇱", count: 60), source: .share)))
        #expect(flags.utf8.count <= CaptureNote.maxStemBytes)
        #expect(!flags.isEmpty)
        #expect(flags.unicodeScalars.count % 2 == 0, "no flag is cut in half")
        #expect(FileStore.nameFits(PathPolicy.inboxFolder + "/" + flags + "-99.md"))
    }

    @Test func aNameOfOnlyMarksIsUntitled() throws {
        #expect(try CaptureNote.fileStem(for: note(Capture(text: "\u{200F}\u{200B}", source: .share))) == "Untitled")
        #expect(try CaptureNote.fileStem(for: note(Capture(text: "***", source: .share))) == "Untitled")
    }

    @Test func windowsDeviceNamesAreAvoided() throws {
        for (typed, expected) in [("CON", "CON-note"), ("nul", "nul-note"), ("Com1", "Com1-note"), ("lpt9", "lpt9-note"),
                                  ("aux.notes", "aux.notes-note"), ("Console", "Console"), ("COM10", "COM10"), ("NULL", "NULL")] {
            #expect(try CaptureNote.fileStem(for: note(Capture(text: typed, source: .share))) == expected, "\(typed)")
        }
    }

    // MARK: the store

    @Test func aCaptureIsANewNoteInTheInboxQueuedAsACreate() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try store.capture(Capture(text: "Buy seeds", source: .quickNote))
        #expect(path == "_inbox/Buy seeds.md")
        let saved = try store.read(path)
        let expected = try note(Capture(text: "Buy seeds", source: .quickNote))
        #expect(saved == expected)
        let ops = store.journal.outbox()
        #expect(ops.count == 1)
        #expect(ops.first?.kind == .create)
        #expect(ops.first.map { sameBytes($0.path, path) } == true)
        #expect(store.status(of: path) == .savedOnDevice)
        #expect(store.index.notesSync(inFolder: PathPolicy.inboxFolder).map(\.path) == [path], "it shows in the Inbox at once")
    }

    @Test func hebrewCapturesLandUnderAHebrewName() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try store.capture(Capture(text: "רשימת קניות\nחלב", source: .share))
        #expect(Array(path.utf8) == Array("_inbox/רשימת קניות.md".utf8))
        #expect(try store.files.readText(path)?.hasSuffix("רשימת קניות\nחלב\n") == true)
    }

    @Test func aTakenNameGetsANumberAndNothingIsOverwritten() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.capture(Capture(text: "Idea", source: .share))
        let second = try store.capture(Capture(text: "Idea\nanother one", source: .share))
        let third = try store.capture(Capture(text: "IDEA", source: .share))
        #expect([first, second, third] == ["_inbox/Idea.md", "_inbox/Idea-2.md", "_inbox/IDEA-3.md"])
        #expect(try store.read(first)?.hasSuffix("---\nIdea\n") == true)
        #expect(try store.read(second)?.hasSuffix("Idea\nanother one\n") == true)
        #expect(store.journal.outbox().count == 3)
    }

    @Test func aStrayFileOnTheDiskIsNeverOverwritten() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.files.write("_inbox/Plan.md", "someone else's text\n")
        let path = try store.capture(Capture(text: "Plan", source: .share))
        #expect(path == "_inbox/Plan-2.md")
        #expect(try store.files.readText("_inbox/Plan.md") == "someone else's text\n")
    }

    @Test func aCreateOnlySaveRefusesATakenPathAndWritesNothing() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(path: "_inbox/a.md", text: "first\n")
        for taken in ["_inbox/a.md", "_inbox/A.md", "_Inbox/a.md"] {
            #expect(throws: NoteStore.PathTaken.self, "\(taken)") {
                try store.save(path: taken, text: "second\n", editingFrom: nil, updateIndex: true, createOnly: true)
            }
        }
        #expect(store.journal.outbox().map(\.content) == ["first\n"], "the first capture's unsynced text is intact")
        #expect(try store.save(path: "_inbox/b.md", text: "second\n", editingFrom: nil, updateIndex: true, createOnly: true) == "_inbox/b.md")
    }

    @Test func thePickedPathAvoidsNamesTakenSinceTheRead() {
        let path = NoteStore.capturePath(stem: "Note", taken: ["_inbox/Note.md", "_inbox/Note-2.md"], onDisk: { _ in false })
        #expect(path == "_inbox/Note-3.md")
        let onDisk = NoteStore.capturePath(stem: "Note", taken: [], onDisk: { $0 == "_inbox/Note.md" || $0 == "_inbox/Note-2.md" })
        #expect(onDisk == "_inbox/Note-3.md")
    }

    @Test func theSampleNotesRefuseACapture() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-capture-demo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try await BrainSession.demo(fixtures: [("a.md", "# A\n")], baseFolder: dir)
        let before = s.store.journal.outboxCount()
        await #expect(throws: CaptureProblem.sampleNotes) { try await s.capture(Capture(text: "lost at quit", source: .share)) }
        #expect(s.store.journal.outboxCount() == before)
    }

    // MARK: through the engine, against the fake GitHub

    @Test func aCaptureIsPushedByTheNextSync() async throws {
        let h = try Harness()
        await h.sync()
        let path = try h.store.capture(Capture(text: "Ask about the bike rack", url: URL(string: "https://example.com/racks")!, source: .shortcut))
        #expect(await h.sync() == .idle)
        let pushed = await h.fake.text(path)
        let local = try h.store.read(path)
        #expect(pushed != nil)
        #expect(pushed == local)
        #expect(h.store.status(of: path) == .synced)
        #expect(await h.fake.commitInfo(await h.fake.head)?.message.hasPrefix("notes: add ") == true)
    }

    @Test func aNameAlreadyOnGitHubIsNotReused() async throws {
        // The seed has `_inbox/quick.md`.
        let h = try Harness()
        await h.sync()
        let path = try h.store.capture(Capture(text: "Quick", source: .share))
        #expect(path == "_inbox/Quick-2.md")
        await h.sync()
        #expect(await h.fake.text("_inbox/quick.md") == "quick thought\n")
        #expect(await h.fake.has(path))
    }

    @Test func theInboxKeepsTheSpellingGitHubHas() async throws {
        let h = try Harness(files: [("_Inbox/older.md", "older\n"), ("a.md", "a\n")])
        await h.sync()
        let path = try h.store.capture(Capture(text: "Newer", source: .share))
        #expect(path == "_Inbox/Newer.md", "no `_inbox` twin next to `_Inbox`")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.has(path))
        // Saved and pushed is not enough: the note must be in the lists and in search, as one in `_inbox` is.
        #expect(PathPolicy.isVisible(path))
        #expect(h.store.index.notesSync().contains { sameBytes($0.path, path) })
    }

    @Test func aCaptureMadeOfflineWaitsAndThenLands() async throws {
        let h = try Harness()
        await h.sync()
        await h.engine.setOnline(false)
        let path = try h.store.capture(Capture(text: "Written on the train", source: .quickNote))
        await h.sync()
        #expect(await h.fake.has(path) == false)
        #expect(h.store.status(of: path) == .savedOnDevice)
        await h.engine.setOnline(true)
        await h.sync()
        #expect(await h.fake.has(path))
    }
}
