import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// Audit F-5. A conflict copy's name always fits the disk, a name the disk refuses (EILSEQ) is held back instead of
/// stopping sync, and a choice that needs a copy that isn't there throws instead of closing the item as if it worked.
@Suite struct ConflictCopyEdgeTests {
    private func longestMarkRun(_ s: String) -> Int {
        var longest = 0
        var run = 0
        for u in s.unicodeScalars {
            if u.properties.canonicalCombiningClass != .notReordered {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    /// The planner and the device cut the slug the same way: its end kept, at most 150 bytes, runs of marks at most 30.
    @Test func everyCopyUsesTheSameCappedSlug() {
        let paths = [
            String(repeating: "folder-name/", count: 25) + "note.md",
            "notes/" + String(repeating: "\u{5E9}\u{5BC}\u{5B8}", count: 40) + ".md",
            "notes/" + String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 13) + ".md",
            "notes/a" + String(repeating: "\u{301}", count: 200) + ".md",
            "notes/b" + String(repeating: "\u{301}", count: 40) + "c.md",
            "notes/" + String(repeating: "x\u{301}", count: 80) + ".md",
        ]
        for path in paths {
            let slug = copySlug(path)
            #expect(slug.utf8.count <= 150, "\(slug.utf8.count) bytes")
            #expect(longestMarkRun(slug) <= 30)
            #expect(!slug.contains("/"))
            #expect(sameBytes(NoteStore.slug(path), slug), "the device's own copies too")
            let name = "conflict-\(slug)-20261111-120000-99.md"
            #expect(name.utf8.count <= 255 && name.unicodeScalars.count <= 255)
            #expect(FileStore.nameFits("_inbox/" + name))
        }
        #expect(copySlug(paths[0]).hasSuffix("folder-name-note"), "the end of the path is what is kept")
        #expect(copySlug("notes/short.md") == "notes-short")
        #expect(copySlug("a/b.MD") == "a-b")
    }

    /// The planner's copy of a deeply nested note was named after its whole path, longer than any disk takes. It
    /// stayed on GitHub only, and "Use mine" found nothing to use.
    @Test func thePlannersCopyOfALongPathReachesTheDevice() async throws {
        let deep = String(repeating: "folder-name/", count: 25) + "note.md"
        let h = try Harness(files: [(deep, "base line\n"), ("other.md", "x\n")])
        await h.sync()
        try h.store.save(path: deep, text: "mine\n")
        await h.fake.commitRemote([(deep, "theirs\n")])
        #expect(await h.sync() == .needsAttention(1))
        let item = try #require(h.attention().first)
        #expect(item.reason == "conflict-copy")
        let copyPath = try #require(item.copyPath)
        let name = String(copyPath.split(separator: "/").last!)
        #expect(name.utf8.count <= 255)
        #expect(name.hasPrefix("conflict-") && name.hasSuffix(".md"))
        #expect(name.contains("folder-name-note-"))
        #expect(await h.fake.text(copyPath) != nil)
        #expect(ConflictCopy(text: try #require(h.local(copyPath)))?.mine == "mine\n")
        try h.store.resolve(item, .useMine)
        #expect(h.local(deep) == "mine\n")
        #expect(h.store.journal.attention(id: item.id)?.resolved == true)
    }

    /// APFS refuses a name with more than 31 combining marks in a row, counted decomposed (EILSEQ). GitHub and the path
    /// rules take it. Such a note is held back like a name that is too long, and not downloaded again on every run.
    @Test func aNameTheDiskRefusesIsHeldBack() async throws {
        let name = "notes/a" + String(repeating: "\u{301}", count: 40) + ".md"
        #expect(checkPath(name) == nil)
        #expect(!FileStore.nameFits(name))
        #expect(FileStore.nameFits("notes/a" + String(repeating: "\u{301}", count: 31) + ".md"))
        #expect(!FileStore.nameFits("notes/\u{E9}" + String(repeating: "\u{301}", count: 31) + ".md"), "é is e and a mark")
        #expect(FileStore.nameFits("notes/" + String(repeating: "\u{5E9}\u{5BC}\u{5B8}", count: 40) + ".md"), "niqqud in short runs")
        let h = try Harness(files: [(name, "x\n"), ("ok.md", "fine\n")])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention().first?.reason == "unstorable")
        #expect(h.local("ok.md") == "fine\n")
        #expect(h.store.journal.file(name)?.local == false)
        let blobs = await h.fake.count(.blob)
        h.clock.advance(120)
        await h.sync()
        #expect(await h.fake.count(.blob) == blobs)
        #expect(h.store.journal.baseCommit == (await h.fake.head))
    }

    #if canImport(Darwin)
    /// Should the disk refuse a name anyway, its EILSEQ is a name problem: the note is held back, sync goes on. Written
    /// straight to this Mac's disk, which answers 32 marks in a row with EILSEQ.
    @Test func eilseqFromTheDiskIsANameProblem() throws {
        let s = FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("bn-eilseq-\(UUID().uuidString)"))
        try s.prepare()
        defer { try? s.wipe() }
        let refused = "a" + String(repeating: "\u{301}", count: 40) + ".md"
        do {
            try s.write(refused, "x")
            Issue.record("the disk took 40 marks in a row")
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            #expect(underlying?.code == Int(EILSEQ), "\(error)")
            #expect(FileStore.isNameProblem(error))
        }
        #expect(try s.readData(refused) == nil, "no such file, not an error")
    }
    #endif

    /// The copy is gone (deleted from the Inbox, or never reached this device): "Use mine" has nothing to use. It used
    /// to close the item anyway, as if mine had been used.
    @Test func useMineWithoutTheCopyThrowsAndKeepsTheItem() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = try #require(h.local("notes/alpha.md"))
        try h.store.save(path: "notes/alpha.md", text: alpha.replacingOccurrences(of: "line one", with: "line one mine"))
        let theirs = alpha.replacingOccurrences(of: "line one", with: "line one theirs")
        await h.fake.commitRemote([("notes/alpha.md", theirs)])
        #expect(await h.sync() == .needsAttention(1))
        let item = try #require(h.attention().first { $0.copyPath != nil })
        try h.store.delete(path: try #require(item.copyPath))
        #expect(throws: NoteStore.ResolveProblem.copyUnavailable) { try h.store.resolve(item, .useMine) }
        #expect(h.store.journal.attention(id: item.id)?.resolved == false, "still open")
        #expect(h.local("notes/alpha.md") == theirs, "nothing changed")
    }

    @Test func restoreWithoutTheCopyThrowsAndKeepsTheItem() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "people/noa.md", text: "# Noa\nDesigner\nmine\n")
        await h.fake.commitRemote([("people/noa.md", nil)])
        await h.sync()
        let item = try #require(h.attention().first { $0.detail == "deleted-remotely" })
        try h.store.delete(path: try #require(item.copyPath))
        #expect(throws: NoteStore.ResolveProblem.copyUnavailable) { try h.store.resolve(item, .restore) }
        #expect(h.store.journal.attention(id: item.id)?.resolved == false)
        #expect(h.local("people/noa.md") == nil, "not restored from nothing")
        // A copy that no longer reads as one (its header was edited away) is no better.
        try h.store.save(path: try #require(item.copyPath), text: "just text now\n")
        #expect(throws: NoteStore.ResolveProblem.copyUnavailable) { try h.store.resolve(item, .restore) }
    }
}
