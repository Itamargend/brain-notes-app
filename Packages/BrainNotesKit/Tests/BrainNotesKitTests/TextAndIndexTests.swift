import Foundation
import GRDB
import Testing
@testable import BrainNotesKit

@Suite struct NoteTextTests {
    @Test func frontmatterSplitIsExact() {
        let text = "---\ntitle: Hello\ntype: note\n---\n# Body\nx\n"
        let (fm, body) = NoteText.split(text)
        #expect(fm == "---\ntitle: Hello\ntype: note\n---\n")
        #expect(body == "# Body\nx\n")
        #expect(sameBytes(fm + body, text))

        let unclosed = "---\nno close\n"
        #expect(NoteText.split(unclosed).frontmatter.isEmpty)
        #expect(sameBytes(NoteText.split(unclosed).body, unclosed))

        let crlf = "---\r\na: 1\r\n---\r\nbody\r\n"
        #expect(sameBytes(NoteText.split(crlf).frontmatter + NoteText.split(crlf).body, crlf))
        #expect(NoteText.split(crlf).body == "body\r\n")
    }

    @Test func titleAndSnippet() {
        #expect(NoteText.title(of: "# Heading\nbody\n", path: "a.md") == "Heading")
        #expect(NoteText.title(of: "---\ntitle: \"Front\"\n---\n# Heading\n", path: "a.md") == "Front")
        #expect(NoteText.title(of: "\n\nfirst line\n", path: "a.md") == "first line")
        #expect(NoteText.title(of: "", path: "folder/my note.md") == "my note")
        #expect(NoteText.snippet(of: "# Title\n- [ ] task one\n**bold** text\n", title: "Title") == "task one bold text")
    }

    @Test func conflictCopyParses() throws {
        let text = "---\ntype: conflict\nconflict_of: \"people/a.md\"\ndevice: \"iphone-1\"\ncreated: \"2026-11-03T10:30:00Z\"\n---\n# Mine\nbody\n"
        let copy = try #require(ConflictCopy(text: text))
        #expect(copy.conflictOf == "people/a.md")
        #expect(copy.device == "iphone-1")
        #expect(copy.mine == "# Mine\nbody\n")
        #expect(NoteText.isConflictCopy(text))
        #expect(ConflictCopy(text: "# plain\n") == nil)
        #expect(!NoteText.isConflictCopy("---\ntype: note\n---\nx"))
    }

    @Test func direction() {
        #expect(NoteText.isRightToLeft("שלום world"))
        #expect(!NoteText.isRightToLeft("hello עולם"))
        #expect(NoteText.isRightToLeft("  123 - שלום"))
        #expect(!NoteText.isRightToLeft("123"))
        #expect(!NoteText.isRightToLeft(""))
    }

    @Test func markdownBlocks() {
        let body = """
        # Title
        para line one
        para line two

        - bullet
          - nested
        - [ ] open
        - [x] done
        1. first
        > quote
        ---
        ```swift
        let a = 1
        ```
        ## שלום
        """
        let kinds = MarkdownBlock.parse(body).map(\.kind)
        #expect(kinds == [
            .heading(1), .paragraph, .bullet(indent: 0), .bullet(indent: 1), .task(done: false, indent: 0),
            .task(done: true, indent: 0), .numbered(marker: "1.", indent: 0), .quote, .rule, .code, .heading(2),
        ])
        let blocks = MarkdownBlock.parse(body)
        #expect(blocks[1].text == "para line one\npara line two")
        #expect(blocks.last?.isRightToLeft == true)
        #expect(blocks[0].isRightToLeft == false)
        #expect(blocks.first { $0.kind == .code }?.text == "let a = 1")
    }

    @Test func crlfNotesRenderLineByLine() {
        let blocks = MarkdownBlock.parse("# Title\r\nfirst\r\n\r\n- item\r\n- [x] done\r\n```\r\ncode\r\n```\r\n")
        #expect(blocks.map(\.kind) == [.heading(1), .paragraph, .bullet(indent: 0), .task(done: true, indent: 0), .code])
        #expect(blocks[0].text == "Title")
        #expect(blocks[1].text == "first")
        #expect(blocks[2].text == "item")
        #expect(blocks[4].text == "code")
        #expect(NoteText.lines("a\r\nb\nc") == ["a", "b", "c"])
        #expect(NoteText.lines("a\n") == ["a"])
        #expect(NoteText.lines("") == [])
    }

    #if canImport(Darwin)
    @Test func inlineMarkdownIsSafe() {
        func plain(_ s: String) -> String { String(NoteText.inlineMarkdown(s).characters) }
        #expect(plain("**bold** and *soft*") == "bold and soft")
        #expect(plain("<script>alert(1)</script> text") == "<script>alert(1)</script> text")
        #expect(plain("a <b>tag</b>") == "a <b>tag</b>")
        #expect(plain("[[people/noa]] link") == "[[people/noa]] link")
        #expect(plain("עברית **מודגש**") == "עברית מודגש")

        func links(_ s: String) -> [String] { NoteText.inlineMarkdown(s).runs.compactMap { $0.link?.absoluteString } }
        #expect(links("[ok](https://example.com)") == ["https://example.com"])
        #expect(links("[http](http://example.com)") == ["http://example.com"])
        #expect(links("[bad](javascript:alert(1))").isEmpty)
        #expect(links("[bad](file:///etc/passwd)").isEmpty)
        #expect(links("[bad](shortcuts://run)").isEmpty)
    }
    #endif

    @Test func folderTree() {
        let nodes = FolderNode.tree(paths: ["a/x.md", "a/y.md", "a/b/z.md", "c/d/e/f.md", "root.md", "עברית/ש.md"])
        #expect(nodes.map(\.name) == ["a", "c", "עברית"])
        #expect(nodes[0].ownCount == 2)
        #expect(nodes[0].totalCount == 3)
        #expect(nodes[0].children.map(\.path) == ["a/b"])
        #expect(nodes[1].ownCount == 0)
        #expect(nodes[1].totalCount == 1)
        #expect(nodes[1].children[0].children[0].path == "c/d/e")
        #expect(nodes[1].children[0].children[0].childrenOrNil == nil)
    }

    @Test func nfdAndNfcFoldersStaySeparateInTheTree() {
        let nodes = FolderNode.tree(paths: ["Cafe\u{301}/a.md", "Caf\u{E9}/b.md"])
        #expect(nodes.count == 2)
    }

    @Test func numericAwareFolderOrder() {
        let nodes = FolderNode.tree(paths: ["10 ten/a.md", "2 two/a.md", "1 one/a.md"])
        #expect(nodes.map(\.name) == ["1 one", "2 two", "10 ten"])
    }

    @Test func markdownBlocksIncludeTables() {
        let body = """
        Before

        | A | B |
        |---|---|
        | 1 | 2 |

        After
        """
        let blocks = MarkdownBlock.parse(body)
        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].text == "Before")
        guard case .table(let table) = blocks[1].kind else {
            Issue.record("expected a table block, got \(blocks[1].kind)")
            return
        }
        #expect(table.columnCount == 2)
        #expect(table.headerTexts == ["A", "B"])
        #expect(table.text(row: 0, column: 0) == "1")
        #expect(blocks[2].kind == .paragraph)
        #expect(blocks[2].text == "After")
    }

    @Test func aTableInsideAFenceIsNotATableBlock() {
        let body = """
        ```
        | A | B |
        |---|---|
        | 1 | 2 |
        ```
        """
        let kinds = MarkdownBlock.parse(body).map(\.kind)
        #expect(kinds == [.code])
    }

}

@Suite struct SearchIndexTests {
    private func index() throws -> SearchIndex { try SearchIndex(path: nil) }

    /// A sync can bring GitHub's `_Inbox/` next to a note made here in `_inbox/`: the Inbox shows both, newest
    /// first, and nothing from a subfolder or a look-alike folder.
    @Test func inboxNotesTakeEverySpelling() async throws {
        let i = try index()
        let now = Date()
        try i.upsert(path: "_inbox/mine.md", text: "# Mine\n", modified: now.addingTimeInterval(-60))
        try i.upsert(path: "_Inbox/synced.md", text: "# Synced\n", modified: now)
        try i.upsert(path: "_Inbox/later/deep.md", text: "# Deep\n", modified: now)
        try i.upsert(path: "_inboxes/other.md", text: "# Other\n", modified: now)
        try i.upsert(path: "notes/a.md", text: "# A\n", modified: now)
        #expect(await i.inboxNotes().map(\.path) == ["_Inbox/synced.md", "_inbox/mine.md"])
        #expect(i.inboxNotesSync().map(\.path) == ["_Inbox/synced.md", "_inbox/mine.md"])
        #expect(try SearchIndex(path: nil).inboxNotesSync().isEmpty)
    }

    /// The home screen's folders leave out the inbox in every spelling, and count its notes once.
    @Test func homeFoldersLeaveOutEveryInboxSpelling() {
        let paths = ["_inbox/a.md", "_Inbox/b.md", "_INBOX/later/c.md", "projects/d.md", "root.md"]
        let tree = FolderNode.tree(paths: paths)
        #expect(tree.filter { !PathPolicy.isInbox($0.name) }.map(\.name) == ["projects"])
        #expect(paths.filter(PathPolicy.isInInbox).count == 3)
    }

    @Test func englishAndHebrewPrefixSearch() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# Lentil soup\nCook the onions first\n", modified: nil)
        try i.upsert(path: "b.md", text: "# מתכון חומוס\nלהשרות את הגרגירים לילה שלם\n", modified: nil)
        #expect(await i.search("onion").map(\.path) == ["a.md"])
        #expect(await i.search("LENTIL").map(\.path) == ["a.md"])
        #expect(await i.search("חומוס").map(\.path) == ["b.md"])
        #expect(await i.search("גרגיר").map(\.path) == ["b.md"])
        #expect(await i.search("nothinghere").isEmpty)
        #expect(await i.search("   ").isEmpty)
        #expect(await i.search("\"*(").isEmpty)
    }

    @Test func wordsAreAllRequired() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "alpha beta\n", modified: nil)
        try i.upsert(path: "b.md", text: "alpha gamma\n", modified: nil)
        #expect(await i.search("alpha beta").map(\.path) == ["a.md"])
    }

    @Test func hebrewPointsDoNotBreakWords() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# כותרת\nשָׁלוֹם עולם\n", modified: nil)
        #expect(await i.search("שלום").map(\.path) == ["a.md"])
        #expect(await i.search("שָׁלוֹם").map(\.path) == ["a.md"])
    }

    @Test func latinDiacriticsFold() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "Caf\u{E9} menu\n", modified: nil)
        try i.upsert(path: "b.md", text: "Cafe\u{301} table\n", modified: nil)
        #expect(await i.search("cafe").count == 2)
        #expect(await i.search("caf\u{E9}").count == 2)
    }

    @Test func snippetMarksMatches() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# Title word\nsome body with a word inside\n", modified: nil)
        let hit = try #require(await i.search("word").first)
        #expect(hit.snippet.contains("\u{E000}word\u{E001}"))
        #expect(hit.title.contains("\u{E000}word\u{E001}"))
    }

    @Test func snippetsShowNoMarkdownMarks() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# Soup recipe\n- **Lentils** and a word\n## Steps\nmore words\n", modified: nil)
        let hit = try #require(await i.search("lentils").first)
        #expect(hit.snippet.replacingOccurrences(of: "\u{E000}", with: "").replacingOccurrences(of: "\u{E001}", with: "") == "Lentils and a word Steps more words")
        // The title still finds the note.
        #expect(await i.search("soup").map(\.path) == ["a.md"])
    }

    @Test func hebrewPrefixLettersDoNotHideAWord() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# כותרת\nלהשרות את הגרגירים ובבית\n", modified: nil)
        #expect(await i.search("גרגירים").map(\.path) == ["a.md"], "ה")
        #expect(await i.search("הגרגירים").map(\.path) == ["a.md"])
        #expect(await i.search("בית").map(\.path) == ["a.md"], "two letters: ו and ב")
        #expect(await i.search("גרגיר").map(\.path) == ["a.md"], "and as a prefix")
    }

    @Test func frontmatterIsNotSearched() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "---\nsecretfield: zzzmarker\n---\nbody\n", modified: nil)
        #expect(await i.search("zzzmarker").isEmpty)
    }

    @Test func listSortsByDateThenTitle() async throws {
        let i = try index()
        let d = Date(timeIntervalSince1970: 1_000)
        try i.upsert(path: "f/old.md", text: "# Old\n", modified: d)
        try i.upsert(path: "f/new.md", text: "# New\n", modified: d.addingTimeInterval(100))
        try i.upsert(path: "f/z.md", text: "# zebra\n", modified: nil)
        try i.upsert(path: "f/a.md", text: "# Apple\n", modified: nil)
        try i.upsert(path: "other.md", text: "# Other\n", modified: d)
        #expect(await i.notes(inFolder: "f").map(\.title) == ["New", "Old", "Apple", "zebra"])
        #expect(await i.notes(inFolder: "").map(\.title) == ["Other"])
    }

    @Test func upsertReplacesAndRemoveRemoves() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# One\nfirst\n", modified: nil)
        try i.upsert(path: "a.md", text: "# Two\nsecond\n", modified: nil)
        #expect(i.count() == 1)
        #expect(await i.search("first").isEmpty)
        #expect(await i.search("second").count == 1)
        try i.remove(path: "a.md")
        #expect(i.count() == 0)
        #expect(await i.search("second").isEmpty)
    }

    /// Review M1. Each note has exactly one full-text row, under its own rowid, so writes never scan the table.
    @Test func fullTextRowsShareTheirNotesRowid() async throws {
        let i = try index()
        try i.upsert(path: "a.md", text: "# A\nalpha\n", modified: nil)
        try i.upsert(path: "b.md", text: "# B\nbravo\n", modified: nil)
        try i.upsert(path: "a.md", text: "# A\nanother\n", modified: nil)
        // Async tests get GRDB's async overloads.
        try await i.queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts") == 2)
            let pairs = try Row.fetchAll(db, sql: "SELECT notes.path AS n, fts.path AS f FROM notes JOIN fts ON fts.rowid = notes.rowid")
            #expect(pairs.count == 2)
            for r in pairs { #expect((r["n"] as String) == (r["f"] as String)) }
        }
        #expect(await i.search("alpha").isEmpty)
        #expect(await i.search("another").map(\.path) == ["a.md"])

        try i.remove(path: "a.md")
        #expect(try await i.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts") } == 1)
        #expect(await i.search("another").isEmpty)
        #expect(await i.search("bravo").map(\.path) == ["b.md"])
    }

    /// An index written by the code before schema 2 has full-text rows under other rowids. It is emptied and loses
    /// its stamp, so the store rebuilds it from the files.
    @Test func anIndexFromBeforeSchemaTwoIsRebuilt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-idx-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try NoteStore(root: root, deviceLabel: "test")
        try s.save(path: "a.md", text: "# A\nalpha\n")
        try s.journal.setMeta(Journal.Key.baseCommit, String(repeating: "b", count: 40))
        try s.index.setStamp(String(repeating: "b", count: 40))
        // What the old code left: no schema key, and a stray full-text row under a rowid no note has.
        try await s.index.queue.write { db in
            try db.execute(sql: "DELETE FROM meta WHERE key = 'schema'")
            try db.execute(sql: "INSERT INTO fts(rowid, path, title, body, stems) VALUES(999, 'gone.md', 'gone', 'ghost', '')")
        }
        try s.index.close()
        try s.journal.close()

        let again = try NoteStore(root: root, deviceLabel: "test")
        #expect(again.index.count() == 0, "emptied on open")
        #expect(again.index.stamp() == nil)
        try again.repairIndexIfNeeded()
        #expect(await again.index.search("alpha").map(\.path) == ["a.md"])
        #expect(await again.index.search("ghost").isEmpty)
        #expect(again.index.stamp() == again.journal.baseCommit)
    }

    @Test func nfcAndNfdPathsAreSeparateRows() throws {
        let i = try index()
        try i.upsert(path: "Caf\u{E9}.md", text: "a", modified: nil)
        try i.upsert(path: "Cafe\u{301}.md", text: "b", modified: nil)
        #expect(i.count() == 2)
    }

    @Test func corruptFileIsResetNotFatal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.sqlite").path
        try Data(repeating: 0x42, count: 8192).write(to: URL(fileURLWithPath: path))
        let i = try SearchIndex(path: path)
        #expect(i.wasReset)
        try i.upsert(path: "a.md", text: "works", modified: nil)
        #expect(i.count() == 1)
        try i.close()
        let again = try SearchIndex(path: path)
        #expect(!again.wasReset)
        #expect(again.count() == 1)
    }

    /// 2,434 notes is the size of the real brain; the budget is 100 ms on a phone.
    @Test func searchIsFastOnABrainSizedIndex() async throws {
        let i = try index()
        var batch: [(path: String, text: String, modified: Date?)] = []
        for n in 0..<2434 {
            batch.append(("folder\(n % 40)/note\(n).md", "# Note \(n)\nשורה בעברית מספר \(n) with some English words about topic\(n % 97)\n" + String(repeating: "more body text here\n", count: 30), nil))
        }
        try i.add(batch)
        // The best of three: this debug run shares the CPU with every other suite, and one bad moment says nothing.
        var best = Double.infinity
        for _ in 0..<3 {
            let start = Date()
            let hits = await i.search("topic42")
            best = min(best, Date().timeIntervalSince(start))
            #expect(!hits.isEmpty)
        }
        #expect(best < 0.1, "search took \(best) s")
    }
}

@Suite struct NoteStoreLocalTests {
    private func makeStore() throws -> (NoteStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-store-\(UUID().uuidString)")
        return (try NoteStore(root: dir, deviceLabel: "test"), dir)
    }

    @Test func saveWritesFileJournalAndIndexTogether() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(path: "a.md", text: "# One\nbody\n")
        #expect(try s.files.readText("a.md") == "# One\nbody\n")
        #expect(s.journal.outbox().map(\.path) == ["a.md"])
        #expect(s.journal.outbox()[0].kind == .create)
        #expect(s.journal.outbox()[0].content == "# One\nbody\n")
        #expect(s.status(of: "a.md") == .savedOnDevice)
        #expect(await s.index.search("body").count == 1)
    }

    @Test func repeatedSavesKeepOneOpAndItsTime() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(path: "a.md", text: "one\n")
        let first = s.journal.outbox()[0]
        try s.save(path: "a.md", text: "one\ntwo\n")
        let second = s.journal.outbox()[0]
        #expect(s.journal.outboxCount() == 1)
        #expect(second.opId == first.opId)
        #expect(second.opTime == first.opTime)
        #expect(second.rev == first.rev + 1)
        #expect(second.contentHash != first.contentHash)
    }

    @Test func savingTheSameTextDoesNothing() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(path: "a.md", text: "one\n")
        let rev = s.journal.outbox()[0].rev
        try s.save(path: "a.md", text: "one\n")
        #expect(s.journal.outbox()[0].rev == rev)
    }

    @Test func saveIsFastEnoughForABigNote() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "## Heading\nA line of text in a large note with some Hebrew שלום\n", count: 4200)
        #expect(big.utf8.count > 270_000)
        try s.save(path: "big.md", text: big)
        // The budget is 50 ms on a device, measured there. This debug run shares the CPU with the other
        // tests, so it only catches something far off, by the best of three.
        var best = Double.infinity
        for n in 0..<3 {
            let start = Date()
            _ = try s.save(path: "big.md", text: big + "one more line \(n)\n", editingFrom: nil, updateIndex: false)
            best = min(best, Date().timeIntervalSince(start))
        }
        #expect(best < 0.2, "the durable part took \(best) s")
    }

    @Test func composeNamesFromFirstLineInFolderOrInbox() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try s.createNote(folder: nil, text: "# Groceries\nmilk\n") == "_inbox/Groceries.md")
        #expect(try s.createNote(folder: "notes", text: "Call Dana\n") == "notes/Call Dana.md")
        #expect(try s.createNote(folder: nil, text: "# Groceries\neggs\n") == "_inbox/Groceries-2.md")
        #expect(try s.createNote(folder: nil, text: "\n\n") == "_inbox/Untitled.md")
        let hebrew = try s.createNote(folder: "עברית", text: "רעיון חדש\n")
        #expect(sameBytes(hebrew, "עברית/רעיון חדש.md"))
    }

    @Test func composeRespellsAnExistingFolder() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(path: "People/a.md", text: "x")
        #expect(try s.createNote(folder: "people", text: "New\n") == "People/New.md")
    }

    @Test func draftFollowsItsFirstLineUntilPushed() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = try s.createNote(folder: "notes", text: "Gro\n")
        #expect(p1 == "notes/Gro.md")
        let p2 = try s.save(path: p1, text: "Groceries\n")
        #expect(p2 == "notes/Groceries.md")
        #expect(try s.files.readText(p1) == nil)
        #expect(try s.files.readText(p2) == "Groceries\n")
        #expect(s.journal.outbox().map(\.path) == [p2])
        #expect(s.journal.file(p1) == nil)
        // Same name again: nothing moves.
        #expect(try s.save(path: p2, text: "Groceries\nmilk\n") == p2)
    }

    @Test func deletingANeverPushedNoteLeavesNothing() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try s.createNote(folder: nil, text: "Draft\n")
        try s.delete(path: p)
        #expect(s.journal.outboxCount() == 0)
        #expect(s.journal.file(p) == nil)
        #expect(try s.files.readText(p) == nil)
        #expect(await s.index.search("Draft").isEmpty)
    }

    @Test func wipeLeavesNothing() throws {
        let (s, dir) = try makeStore()
        try s.save(path: "a/b.md", text: "text")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        try s.wipe()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// A wipe that could not remove the folder says so (audit B3). Here the folder's parent can't be written,
    /// so the folder itself can't go. A folder already gone is a wipe that worked.
    @Test func aWipeThatLeavesTheFolderBehindThrows() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("bn-wipe-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent("repo", isDirectory: true)
        let s = try NoteStore(root: dir, deviceLabel: "test")
        try s.save(path: "a/b.md", text: "text")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        // A superuser writes anyway (a Linux container): nothing to prove there.
        guard !FileManager.default.isWritableFile(atPath: parent.path) else { return }
        #expect(throws: (any Error).self) { try s.wipe() }
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try s.files.wipe()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        try s.files.wipe()
    }

    @Test func aKilledSaveIsRepairedAtLaunch() throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(path: "a.md", text: "one\n")
        // The file was written, the journal commit never happened.
        try s.files.write("a.md", "one\ntwo typed before the kill\n")
        let again = try NoteStore(root: dir, deviceLabel: "test")
        let r = try again.reconcile()
        #expect(r.edited == ["a.md"])
        #expect(again.journal.outbox()[0].content == "one\ntwo typed before the kill\n")
    }

    @Test func snippetsStripPipeTablesAndDelimiters() {
        let md = """
        # Notes that sync like git, without git
        - [ ] Users should never see
        |   |   |   |
        |---|---|---|
        |   |   |   |
        - [ ] word "commit". Th
        | aas |  | **bold cell** |
        | :---: | :--- | ---: |
        |  | val |  |
        """
        let s = NoteText.snippet(of: md, title: "Notes that sync like git, without git")
        #expect(s == "Users should never see word \"commit\". Th aas bold cell val")
        #expect(!s.contains("|"))
        #expect(!s.contains("---"))
    }

    @Test func duplicateRenameMoveAndEmptyFolderOperations() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try s.save(path: "ideas/plan.md", text: "---\npinned: true\n---\n# Plan\nbody\n")
        let copy1 = try #require(try s.duplicateNote("ideas/plan.md"))
        #expect(copy1 == "ideas/plan copy.md")
        #expect(NoteText.isPinned(try #require(try s.read(copy1))) == false)
        let copy2 = try #require(try s.duplicateNote("ideas/plan.md"))
        #expect(copy2 == "ideas/plan copy 2.md")

        let emptyFolder = try s.createFolder(named: "empty-sub", in: "ideas")
        #expect(s.files.emptyFolders().contains(emptyFolder))
        try s.removeEmptyOrPlaceholderFolder(emptyFolder)
        #expect(!s.files.emptyFolders().contains(emptyFolder))

        let sub = try s.createFolder(named: "drafts", in: "ideas")
        let renamed = try s.renameFolderLocally("ideas", to: "concepts")
        #expect(renamed == "concepts")
        #expect(try s.read("concepts/plan.md") != nil)
        #expect(try s.read("ideas/plan.md") == nil)
        #expect(s.files.emptyFolders().contains("concepts/drafts"))
        _ = sub

        try s.createFolder(named: "archive", in: "")
        let moved = try s.moveFolderLocally("concepts", into: "archive")
        #expect(moved == "archive/concepts")
        #expect(try s.read("archive/concepts/plan.md") != nil)

        // List preferences persist inside store.root/ui-prefs.json without UserDefaults.
        let prefsStore = FileListPreferencesStore(store: s)
        let custom = ListPreferences(sortBy: .title, newestFirst: false, titleAscending: false, groupByDate: false, pinnedCollapsed: true)
        prefsStore.save(custom)
        #expect(prefsStore.load() == custom)
        let notes = await s.index.notes(inFolder: "archive/concepts")
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.created != nil })
    }
}
