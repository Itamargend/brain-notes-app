import Foundation
import Testing
@testable import BrainNotesKit

/// The real brain has 2,434 notes (p50 3.3 KB, p99 42 KB, largest 271 KB with 81 headings). These run the
/// engine at that size with synthetic text, to catch anything that grows badly. The budgets themselves are
/// for a device; a debug build on a shared CPU only has to stay in the same order of magnitude.
@Suite(.serialized) struct ScaleTests {
    private static func notes() -> [(path: String, text: String)] {
        var out: [(path: String, text: String)] = []
        for i in 0..<2433 {
            let folder = i % 3 == 0 ? "people" : i % 3 == 1 ? "media/podcasts" : "concepts/\(i % 40)"
            let paragraphs = i % 100 == 0 ? 400 : 30
            var body = "# Note \(i)\n\n## Compiled Truth\n"
            for p in 0..<paragraphs { body += "Paragraph \(p) of note \(i), שורה בעברית, with some words about topic\(i % 97).\n" }
            body += "\n## Timeline\n- 2026-11-0\(i % 9 + 1): something happened\n"
            out.append(("\(folder)/note-\(i).md", body))
        }
        var big = "# The largest note\n"
        for h in 0..<81 {
            big += "\n## Heading \(h)\n"
            for l in 0..<55 { big += "Line \(l) under heading \(h), with enough words to reach the real size.\n" }
        }
        out.append(("people/largest.md", big))
        return out
    }

    private func timed<T>(_ label: String, limit: TimeInterval, _ body: () async throws -> T) async rethrows -> T {
        let start = Date()
        let value = try await body()
        let elapsed = Date().timeIntervalSince(start)
        print("SCALE \(label): \(Int(elapsed * 1000)) ms")
        #expect(elapsed < limit, "\(label) took \(elapsed) s")
        return value
    }

    @Test func aBrainSizedRepo() async throws {
        let files = Self.notes()
        let h = try Harness(files: files)
        #expect(files.first { $0.path == "people/largest.md" }!.text.utf8.count > 250_000)

        _ = await timed("first sync of 2,434 notes", limit: 60) { await h.sync() }
        #expect(h.store.journal.baseCommit == (await h.fake.head))
        #expect(h.store.index.count() == 2434)

        await timed("poll with nothing new", limit: 0.5) { await h.engine.sync(.poll) }

        let hits = await timed("search", limit: 0.25) { await h.store.index.search("topic42") }
        #expect(!hits.isEmpty)
        _ = await timed("list a large folder", limit: 0.25) { await h.store.index.notes(inFolder: "people") }

        // One edit in the largest note, then a commit.
        let big = h.local("people/largest.md")!
        let edited = big.replacingOccurrences(of: "Line 3 under heading 40,", with: "Line 3 edited under heading 40,")
        _ = try await timed("save the 271 KB note", limit: 0.5) { try h.store.save(path: "people/largest.md", text: edited) }
        _ = await timed("push one note", limit: 3) { await h.sync() }
        #expect(await h.fake.text("people/largest.md") == edited)

        // A bot edits the same note elsewhere while I edit it: a real merge of the largest note.
        let mine = edited.replacingOccurrences(of: "Line 5 under heading 2,", with: "Line 5 mine under heading 2,")
        try h.store.save(path: "people/largest.md", text: mine)
        await h.fake.commitRemote([("people/largest.md", edited.replacingOccurrences(of: "Line 7 under heading 70,", with: "Line 7 bot under heading 70,"))])
        h.clock.advance(120)
        _ = await timed("pull and merge the largest note, then push", limit: 3) { await h.sync() }
        let merged = await h.fake.text("people/largest.md")!
        #expect(merged.contains("Line 5 mine") && merged.contains("Line 7 bot"))

        // Twenty notes edited offline, five of them by a bot too.
        let paths = (0..<20).map { "people/note-\($0 * 3).md" }
        for p in paths { try h.store.save(path: p, text: h.local(p)! + "offline edit\n") }
        var bot: [(path: String, text: String?)] = []
        for p in paths.prefix(5) { bot.append((p, h.local(p)!.replacingOccurrences(of: "# Note", with: "# Bot note"))) }
        await h.fake.commitRemote(bot)
        h.clock.advance(120)
        _ = await timed("twenty offline edits with five merges", limit: 3) { await h.sync() }
        #expect(h.store.journal.outboxCount() == 0)

        // A bulk commit over the 300-file limit: the tree diff path.
        var bulk: [(path: String, text: String?)] = []
        for i in stride(from: 1, to: 1000, by: 3) { bulk.append(("media/podcasts/note-\(i).md", "# Bulk \(i)\n")) }
        await h.fake.commitRemote(bulk)
        _ = await timed("pull 333 changed files by tree diff", limit: 10) { await h.sync() }
        #expect(h.local("media/podcasts/note-1.md") == "# Bulk 1\n")
        #expect(await h.fake.count(.tree) >= 2)

        let repaired = try await timed("launch repair with nothing to do", limit: 2) { try h.store.reconcile() }
        #expect(repaired == NoteStore.ReconcileResult())
        try await timed("rebuild the index", limit: 30) { try h.store.rebuildIndex() }
        #expect(h.store.index.count() == 2434)
    }
}
