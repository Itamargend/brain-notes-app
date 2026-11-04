import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

// The adversarial merge inputs again, end to end: device edit, GitHub edit on the fake, one sync, then
// what GitHub holds, what the disk holds, and what Needs attention says. Bytes only, never String ==.

private func bytesEqual(_ a: String?, _ b: String?) -> Bool { sameDoc(a, b) }

/// Every conflict copy on GitHub parses back, and its `mine` is exactly `mine`.
private func expectCopy(_ h: Harness, of path: String, mine: String,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
    let item = try #require(h.attention().first { sameBytes($0.path, path) && $0.copyPath != nil }, sourceLocation: sourceLocation)
    let copyPath = try #require(item.copyPath, sourceLocation: sourceLocation)
    let copy = try #require(await h.fake.text(copyPath), "the copy is on GitHub", sourceLocation: sourceLocation)
    let parsed = try #require(ConflictCopy(text: copy), sourceLocation: sourceLocation)
    #expect(sameBytes(parsed.mine, mine), "the copy holds mine byte for byte", sourceLocation: sourceLocation)
    #expect(parsed.conflictOf.map { sameBytes($0, path) } == true, sourceLocation: sourceLocation)
    #expect(bytesEqual(h.local(copyPath), copy), "and the device has it too", sourceLocation: sourceLocation)
    return copyPath
}

@Suite struct AdversarialSyncTests {
    // MARK: line endings

    @Test func crlfNoteMergesCleanlyAndStaysCRLF() async throws {
        let base = "# Win\r\n\r\n## A\r\none\r\n\r\n## B\r\ntwo\r\n"
        let h = try Harness(files: [("win.md", base)])
        await h.sync()
        try h.store.save(path: "win.md", text: base.replacingOccurrences(of: "one", with: "one MINE"))
        await h.fake.commitRemote([("win.md", base.replacingOccurrences(of: "two", with: "two THEIRS"))])
        #expect(await h.sync() == .idle)
        let want = "# Win\r\n\r\n## A\r\none MINE\r\n\r\n## B\r\ntwo THEIRS\r\n"
        #expect(bytesEqual(await h.fake.text("win.md"), want))
        #expect(bytesEqual(h.local("win.md"), want))
        #expect(h.store.journal.file("win.md")?.blobSha == GitBlob.sha(want))
        #expect(h.store.journal.outbox().isEmpty)
    }

    /// GitHub converted the note to CRLF while the device edited it: a conflict, both versions kept.
    @Test func lineEndingConversionOnGitHubAgainstALocalEdit() async throws {
        let base = "# N\none\ntwo\n"
        let h = try Harness(files: [("n.md", base)])
        await h.sync()
        let mine = "# N\none\ntwo MINE\n"
        try h.store.save(path: "n.md", text: mine)
        let theirs = base.replacingOccurrences(of: "\n", with: "\r\n")
        await h.fake.commitRemote([("n.md", theirs)])
        #expect(await h.sync() == .needsAttention(1))
        #expect(bytesEqual(await h.fake.text("n.md"), theirs))
        #expect(bytesEqual(h.local("n.md"), theirs))
        _ = try await expectCopy(h, of: "n.md", mine: mine)
    }

    /// The conflict copy of a CRLF note: an LF header (spec 6.1), then mine's CRLF bytes untouched.
    @Test func conflictCopyOfACRLFNoteKeepsMinesBytes() async throws {
        let base = "# N\r\nshared\r\n"
        let h = try Harness(files: [("n.md", base)])
        await h.sync()
        let mine = "# N\r\nshared MINE\r\nno final newline"
        try h.store.save(path: "n.md", text: mine)
        await h.fake.commitRemote([("n.md", "# N\r\nshared THEIRS\r\n")])
        #expect(await h.sync() == .needsAttention(1))
        let copyPath = try await expectCopy(h, of: "n.md", mine: mine)
        let copy = try #require(await h.fake.text(copyPath))
        #expect(copy.utf8.starts(with: "---\ntype: conflict\n".utf8))
        #expect(copy.utf8.reversed().starts(with: Array("no final newline".utf8).reversed()))
    }

    /// A lone CR survives a push and a pull byte for byte.
    @Test func loneCRRoundTrips() async throws {
        let h = try Harness(files: [("cr.md", "a\rb\n")])
        await h.sync()
        try h.store.save(path: "cr.md", text: "a\rb\rc\n")
        #expect(await h.sync() == .idle)
        #expect(bytesEqual(await h.fake.text("cr.md"), "a\rb\rc\n"))
    }

    // MARK: Unicode

    /// Re-typing a word in NFD is a change, though Swift says the texts are equal. It must be pushed, not
    /// dropped as a no-op, and GitHub must get the exact bytes.
    @Test func canonicallyEqualEditIsPushed() async throws {
        let h = try Harness(files: [("cafe.md", "Caf\u{E9}\n")])
        await h.sync()
        let nfd = "Cafe\u{301}\n"
        try h.store.save(path: "cafe.md", text: nfd)
        #expect(h.store.journal.outbox().count == 1, "the save is a change")
        #expect(await h.sync() == .idle)
        #expect(bytesEqual(await h.fake.text("cafe.md"), nfd))
        #expect(bytesEqual(h.local("cafe.md"), nfd))
    }

    /// GitHub reordered niqqud marks on one line (canonically equal, different bytes) while the device
    /// edited another: the merge keeps GitHub's bytes on that line.
    @Test func hebrewNiqqudOrderFromGitHubIsKept() async throws {
        let a = "\u{5E9}\u{5BC}\u{5B8}", b = "\u{5E9}\u{5B8}\u{5BC}"
        let base = "# שלום\n\n\(a)\n\nשורה\n"
        let h = try Harness(files: [("עברית/ניקוד.md", base)])
        await h.sync()
        try h.store.save(path: "עברית/ניקוד.md", text: "# שלום\n\n\(a)\n\nשורה ועוד\n")
        await h.fake.commitRemote([("עברית/ניקוד.md", "# שלום\n\n\(b)\n\nשורה\n")])
        #expect(await h.sync() == .idle)
        let want = "# שלום\n\n\(b)\n\nשורה ועוד\n"
        #expect(bytesEqual(await h.fake.text("עברית/ניקוד.md"), want))
        #expect(bytesEqual(h.local("עברית/ניקוד.md"), want))
    }

    /// Same-line clash in a Hebrew note under a Hebrew folder: the copy's path slug is Hebrew, NFC, in
    /// `_inbox`, and the copy keeps mine's bidi marks.
    @Test func hebrewSameLineClashMakesAHebrewCopy() async throws {
        let h = try Harness()
        await h.sync()
        let mine = "# רעיון\n\u{200F}טקסט בעברית, שלי\n"
        try h.store.save(path: "עברית/רעיון.md", text: mine)
        await h.fake.commitRemote([("עברית/רעיון.md", "# רעיון\nטקסט בעברית, שלהם\n")])
        #expect(await h.sync() == .needsAttention(1))
        let copyPath = try await expectCopy(h, of: "עברית/רעיון.md", mine: mine)
        #expect(copyPath.utf8.starts(with: "_inbox/conflict-עברית-רעיון-".utf8))
        #expect(sameBytes(copyPath, nfc(copyPath)))
        #expect(bytesEqual(await h.fake.text("עברית/רעיון.md"), "# רעיון\nטקסט בעברית, שלהם\n"))
    }

    /// Emoji ZWJ sequences, flags and skin tones in different sections merge cleanly.
    @Test func emojiSectionsMerge() async throws {
        let fam = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let base = "# 🎉 Trip\n\n## Who\n\(fam)\n\n## Where\n🇮🇱\n"
        let h = try Harness(files: [("trip.md", base)])
        await h.sync()
        try h.store.save(path: "trip.md", text: base.replacingOccurrences(of: fam, with: fam + "\u{200D}\u{1F466}"))
        await h.fake.commitRemote([("trip.md", base.replacingOccurrences(of: "🇮🇱\n", with: "🇮🇱 🇺🇸 👍🏽\n"))])
        #expect(await h.sync() == .idle)
        let want = "# 🎉 Trip\n\n## Who\n\(fam)\u{200D}\u{1F466}\n\n## Where\n🇮🇱 🇺🇸 👍🏽\n"
        #expect(bytesEqual(await h.fake.text("trip.md"), want))
    }

    /// The fake and the real GitHub hash bytes: an NFD note pushed from the device gets the sha of its
    /// NFD bytes, so the next pull does not see a phantom change.
    @Test func nfdContentShaIsOfTheBytes() async throws {
        let h = try Harness(files: [("n.md", "x\n")])
        await h.sync()
        let nfd = "e\u{301}\n"
        try h.store.save(path: "n.md", text: nfd)
        await h.sync()
        #expect(h.store.journal.file("n.md")?.blobSha == GitBlob.sha(Data(nfd.utf8)))
        #expect(h.store.journal.file("n.md")?.blobSha != GitBlob.sha(Data("\u{E9}\n".utf8)))
        await h.sync()
        #expect(h.store.journal.outbox().isEmpty)
    }

    // MARK: deletes against edits

    @Test func iDeletedGitHubEditedSkipsTheDelete() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.delete(path: "people/noa.md")
        await h.fake.commitRemote([("people/noa.md", "# Noa\nDesigner\nnow lead\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention()[0].reason == "delete-skipped")
        #expect(bytesEqual(await h.fake.text("people/noa.md"), "# Noa\nDesigner\nnow lead\n"))
        #expect(await h.fake.has("_trash/people/noa.md") == false)
    }

    @Test func gitHubDeletedIEditedKeepsMineInACopy() async throws {
        let h = try Harness()
        await h.sync()
        let mine = "# Noa\nDesigner\nמשהו שלי 👍🏽\n"
        try h.store.save(path: "people/noa.md", text: mine)
        await h.fake.commitRemote([("people/noa.md", nil)])
        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.has("people/noa.md") == false)
        _ = try await expectCopy(h, of: "people/noa.md", mine: mine)
    }

    /// GitHub emptied the note (a file of zero bytes, not a delete) while the device edited it.
    @Test func gitHubEmptiedIEdited() async throws {
        let h = try Harness()
        await h.sync()
        let mine = "# Todo\n- one\n- two\n- three\n"
        try h.store.save(path: "todo.md", text: mine)
        await h.fake.commitRemote([("todo.md", "")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.has("todo.md"))
        #expect(bytesEqual(await h.fake.text("todo.md"), ""))
        _ = try await expectCopy(h, of: "todo.md", mine: mine)
    }

    // MARK: empty files

    /// Saving a note as empty pushes an empty file. It does not delete the note.
    @Test func anEmptiedNoteIsAnEmptyFileNotADelete() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.has("todo.md"))
        #expect(bytesEqual(await h.fake.text("todo.md"), ""))
        #expect(bytesEqual(h.local("todo.md"), ""))
        #expect(h.store.journal.file("todo.md")?.blobSha == GitBlob.sha(""))
    }

    /// An empty note on GitHub comes down as an empty file and can then be filled.
    @Test func anEmptyNoteFromGitHubCanBeFilled() async throws {
        let h = try Harness(files: [("empty.md", "")])
        await h.sync()
        #expect(bytesEqual(h.local("empty.md"), ""))
        #expect(h.store.journal.file("empty.md")?.blobSha == GitBlob.sha(""))
        try h.store.save(path: "empty.md", text: "now text\n")
        #expect(await h.sync() == .idle)
        #expect(bytesEqual(await h.fake.text("empty.md"), "now text\n"))
    }

    /// Both sides fill an empty note: a conflict (spec 5.2), not lost, not glued.
    @Test func bothFillAnEmptyNote() async throws {
        let h = try Harness(files: [("empty.md", "")])
        await h.sync()
        try h.store.save(path: "empty.md", text: "mine\n")
        await h.fake.commitRemote([("empty.md", "theirs\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(bytesEqual(await h.fake.text("empty.md"), "theirs\n"))
        _ = try await expectCopy(h, of: "empty.md", mine: "mine\n")
    }

    // MARK: frontmatter

    @Test func frontmatterClashKeepsTheirsAndMergesTheBody() async throws {
        let body = "# P\n\n## A\nalpha\n\n## B\nbeta\n"
        let base = "---\nstatus: draft\n---\n" + body
        let h = try Harness(files: [("p.md", base)])
        await h.sync()
        let mine = "---\nstatus: done\n---\n" + body.replacingOccurrences(of: "beta", with: "beta MINE")
        try h.store.save(path: "p.md", text: mine)
        await h.fake.commitRemote([("p.md", "---\nstatus: review\n---\n" + body.replacingOccurrences(of: "alpha", with: "alpha THEIRS"))])
        #expect(await h.sync() == .needsAttention(1))
        let want = "---\nstatus: review\n---\n# P\n\n## A\nalpha THEIRS\n\n## B\nbeta MINE\n"
        #expect(bytesEqual(await h.fake.text("p.md"), want))
        #expect(bytesEqual(h.local("p.md"), want))
        _ = try await expectCopy(h, of: "p.md", mine: mine)
    }

    /// A note whose own frontmatter says `type: conflict` and has the same keys as a copy header, edited
    /// on both sides: the copy of it nests, and reads back as the outer header with all of mine inside.
    @Test func aConflictCopyOfAConflictCopy() async throws {
        let inner = copyHeader("x.md", device: "other", time: "2026-11-01T00:00:00Z") + "inner line\n"
        let h = try Harness(files: [("_inbox/old-copy.md", inner)])
        await h.sync()
        let mine = inner.replacingOccurrences(of: "inner line", with: "inner line MINE")
        try h.store.save(path: "_inbox/old-copy.md", text: mine)
        await h.fake.commitRemote([("_inbox/old-copy.md", inner.replacingOccurrences(of: "inner line", with: "inner line THEIRS"))])
        #expect(await h.sync() == .needsAttention(1))
        let copyPath = try await expectCopy(h, of: "_inbox/old-copy.md", mine: mine)
        #expect(ConflictCopy(text: try #require(await h.fake.text(copyPath)))?.conflictOf == "_inbox/old-copy.md")
    }

    // MARK: size budget

    /// Both sides grow a note that is just under 1 MiB; each is under the limit, the merge is over. The
    /// planner writes nothing, the op stays, Needs attention says too-large, and mine is still on the device.
    @Test func mergedNoteOverTheLimitIsHeldWithMineSafe() async throws {
        let filler = String(repeating: String(repeating: "x", count: 99) + "\n", count: 10_480)
        let base = "# Big\n\n## Top\nt\n\n## Body\n" + filler
        let h = try Harness(files: [("big.md", base)])
        await h.sync()
        let mine = base.replacingOccurrences(of: "## Top\nt\n", with: "## Top\nt\n" + String(repeating: "m", count: 300) + "\n")
        let theirs = base + String(repeating: "t", count: 300) + "\n"
        try h.store.save(path: "big.md", text: mine)
        await h.fake.commitRemote([("big.md", theirs)])
        let before = await h.fake.head
        let state = await h.sync()
        #expect(state == .needsAttention(1))
        #expect(await h.fake.head == before, "no commit")
        #expect(bytesEqual(await h.fake.text("big.md"), theirs))
        #expect(h.attention().map(\.reason) == ["blocked:too-large"])
        #expect(bytesEqual(h.store.journal.outbox().first?.content, mine), "the op stays with all of mine")
        #expect(bytesEqual(h.local("big.md"), mine), "the device keeps mine")
    }

    /// A Hebrew note of 524,288 letters is exactly 1 MiB of UTF-8, and pushes; one more letter is over.
    @Test func hebrewAtTheByteLimit() async throws {
        let h = try Harness(files: [("he.md", "א\n")])
        await h.sync()
        let atLimit = String(repeating: "א", count: 524_287) + "\n\n"
        #expect(atLimit.utf8.count == 1_048_576)
        try h.store.save(path: "he.md", text: atLimit)
        #expect(await h.sync() == .idle)
        #expect(bytesEqual(await h.fake.text("he.md"), atLimit))
        let over = atLimit + "א"
        try h.store.save(path: "he.md", text: over)
        h.clock.advance(120)
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention().map(\.reason) == ["blocked:too-large"])
        #expect(bytesEqual(await h.fake.text("he.md"), atLimit))
    }

    // MARK: resolving

    /// "Use mine" on a CRLF, NFD, emoji note puts mine's exact bytes on GitHub and theirs' in the copy.
    @Test func useMineIsByteExact() async throws {
        let base = "# R\r\nshared\r\n"
        let h = try Harness(files: [("r.md", base)])
        await h.sync()
        let mine = "# R\r\nshared Cafe\u{301} \u{1F468}\u{200D}\u{1F469}\r\n"
        let theirs = "# R\r\nshared Caf\u{E9}\r\n"
        try h.store.save(path: "r.md", text: mine)
        await h.fake.commitRemote([("r.md", theirs)])
        #expect(await h.sync() == .needsAttention(1))
        let item = try #require(h.attention().first)
        try h.store.resolve(item, .useMine)
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(bytesEqual(await h.fake.text("r.md"), mine))
        let copy = try #require(await h.fake.text(item.copyPath!))
        #expect(bytesEqual(ConflictCopy(text: copy)?.mine, theirs), "the replaced version stays in the copy")
    }

    /// The side-by-side view shows exact bytes for both sides.
    @Test func textsForAConflictAreByteExact() async throws {
        let h = try Harness(files: [("t.md", "a\r\n")])
        await h.sync()
        try h.store.save(path: "t.md", text: "a mine\r\n")
        await h.fake.commitRemote([("t.md", "a theirs\n")])
        await h.sync()
        let item = try #require(h.attention().first)
        let t = h.store.texts(for: item)
        #expect(bytesEqual(t.mine, "a mine\r\n"))
        #expect(bytesEqual(t.theirs, "a theirs\n"))
    }

    // MARK: two devices

    /// Two devices type on the same Hebrew line, offline, then both sync: one copy, no text lost anywhere.
    @Test func twoDevicesSameHebrewLine() async throws {
        let a = try Harness()
        await a.sync()
        let b = try a.secondDevice()
        await b.sync()
        let mineA = "# רעיון\nטקסט בעברית — א׳\n"
        let mineB = "# רעיון\nטקסט בעברית — ב׳\n"
        try a.store.save(path: "עברית/רעיון.md", text: mineA)
        try b.store.save(path: "עברית/רעיון.md", text: mineB)
        #expect(await a.sync() == .idle)
        #expect(await b.sync() == .needsAttention(1))
        #expect(bytesEqual(await a.fake.text("עברית/רעיון.md"), mineA))
        _ = try await expectCopy(b, of: "עברית/רעיון.md", mine: mineB)
        a.clock.advance(120)
        await a.sync()
        let copies = a.allLocal().filter { $0.path.hasPrefix("_inbox/conflict-") }
        #expect(copies.count == 1)
        #expect(bytesEqual(copies.first.flatMap { ConflictCopy(text: $0.text)?.mine }, mineB))
    }
}

/// Copies the device makes itself (`NoteStore.createCopy`) must always fit on the disk, whatever the
/// original's name is made of. The name was cut to 150 Characters; a Character can be many scalars and
/// bytes, so a name the disk could hold produced a copy name it could not.
@Suite struct CopyNameLengthTests {
    /// 80 Characters of "x" + U+0301 (no precomposed form, so NFC keeps two scalars, three bytes each):
    /// 240 bytes, a legal name on APFS and ext4. Its copy name would be 274 bytes.
    static let longName = String(repeating: "x\u{301}", count: 80)
    static let longPath = "notes/" + longName + ".md"

    @Test func theOriginalFitsTheDisk() {
        #expect(sameBytes(nfc(Self.longPath), Self.longPath))
        #expect(checkPath(Self.longPath) == nil)
        #expect(FileStore.nameFits(Self.longPath))
        #expect((Self.longName + ".md").utf8.count <= 255)
    }

    /// The second-window save: the disk text differs from what this editor started from, so the disk text
    /// goes to a copy. The copy must be written, or that text is gone.
    @Test func aSecondWindowSaveKeepsTheOtherTextUnderALongName() async throws {
        let h = try Harness(files: [(Self.longPath, "base\n")])
        await h.sync()
        #expect(bytesEqual(h.local(Self.longPath), "base\n"))
        try h.store.save(path: Self.longPath, text: "window A\n")
        try h.store.save(path: Self.longPath, text: "window B\n", editingFrom: "base\n")
        #expect(bytesEqual(h.local(Self.longPath), "window B\n"))
        let copies = h.allLocal().filter { $0.path.hasPrefix("_inbox/conflict-") }
        #expect(copies.count == 1)
        #expect(bytesEqual(copies.first.flatMap { ConflictCopy(text: $0.text)?.mine }, "window A\n"), "window A's text is kept")
        for c in copies {
            #expect(c.path.split(separator: "/").allSatisfy { $0.utf8.count <= 255 }, "\(c.path.utf8.count) bytes")
        }
    }

    /// Starting over (history rewritten) copies every unsynced note first. A long name must not make that
    /// fail on every try.
    @Test func freshSyncCopiesALongNamedUnsyncedNote() async throws {
        let h = try Harness(files: [(Self.longPath, "base\n")])
        await h.sync()
        try h.store.save(path: Self.longPath, text: "unsynced\n")
        await h.engine.freshSync()
        #expect(h.store.journal.outbox().allSatisfy { NoteText.isConflictCopy($0.content ?? "") })
        let copies = h.allLocal().filter { $0.path.hasPrefix("_inbox/conflict-") }
        #expect(copies.count == 1)
        #expect(bytesEqual(copies.first.flatMap { ConflictCopy(text: $0.text)?.mine }, "unsynced\n"))
        #expect(bytesEqual(await h.fake.text(copies.first?.path ?? "-"), copies.first?.text), "and it reached GitHub")
    }

    /// Hebrew with niqqud and family emoji: many bytes per Character. The copy keeps the end of the name
    /// and stays within 255 bytes and 255 scalars.
    @Test func copyNamesStayWithinTheLimitForAnyText() throws {
        let h = try Harness()
        let he = String(repeating: "\u{5E9}\u{5BC}\u{5B8}", count: 40)  // 240 bytes
        let fam = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 13)  // 234 bytes
        let zalgo = "a" + String(repeating: "\u{301}", count: 200)  // one Character, 401 bytes
        for name in [he, fam, zalgo, Self.longName] {
            let p = try h.store.createCopy(of: "notes/" + name + ".md", text: "t\n")
            let file = String(p.split(separator: "/").last!)
            #expect(file.utf8.count <= 255 && file.unicodeScalars.count <= 255, "\(file.utf8.count) bytes")
            #expect(file.hasPrefix("conflict-") && file.hasSuffix(".md"))
            #expect(bytesEqual(h.local(p).flatMap { ConflictCopy(text: $0)?.mine }, "t\n"))
        }
    }
}
