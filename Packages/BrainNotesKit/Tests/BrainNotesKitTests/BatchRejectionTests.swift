import Foundation
import Testing
@testable import BrainNotesKit

/// Audit F-7. A batch GitHub refuses because of one op: that op is parked in Needs attention, and the others still land
/// together, as one commit. They used to land as one commit each, which split a rename or a move into pieces.
@Suite struct BatchRejectionTests {
    @Test func oneRefusedOpIsParkedAndTheRestLandAsOneCommit() async throws {
        let h = try Harness()
        await h.sync()
        let landed = await h.fake.landed.count
        let commits = await h.fake.count(.createCommit)
        try h.store.save(path: "todo.md", text: "# Todo\nA\n")
        try h.store.save(path: "notes/beta.md", text: "# Beta\nB\n")
        try h.store.save(path: "people/noa.md", text: "# Noa\nC\n")
        try h.store.save(path: "notes/gamma.md", text: "# Gamma\nD\n")
        await h.fake.refuseTrees(writing: "notes/beta.md")

        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.landed.count == landed + 1, "one commit")
        #expect(await h.fake.count(.createCommit) == commits + 1, "and no other one was made")
        let head = await h.fake.head
        #expect(try await h.fake.changedPaths(in: head) == ["notes/gamma.md", "people/noa.md", "todo.md"])
        #expect(await h.fake.text("todo.md") == "# Todo\nA\n")
        #expect(await h.fake.text("notes/beta.md") == "# Beta\nbody\n", "the refused one is not on GitHub")
        let item = try #require(h.attention().first)
        #expect(item.reason == "rejected")
        #expect(item.path == "notes/beta.md")
        #expect(h.store.journal.outbox().map(\.path) == ["notes/beta.md"])
        #expect(h.store.journal.outbox().first?.parked == true)
        #expect(h.local("notes/beta.md") == "# Beta\nB\n", "the text stays on the device")

        // Parked, it doesn't go again by itself. Edited once GitHub takes it, it lands and the item closes.
        h.clock.advance(120)
        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.landed.count == landed + 1)
        await h.fake.acceptTrees(writing: "notes/beta.md")
        try h.store.save(path: "notes/beta.md", text: "# Beta\nB again\n")
        h.clock.advance(120)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("notes/beta.md") == "# Beta\nB again\n")
        #expect(h.attention().isEmpty)
    }

    /// A note moved by hand, deleted at its old path and written at a new one, is two ops. With a refused op in the same
    /// batch, the move still lands as one commit: never the delete without the new note, or the other way round.
    @Test func aMoveOfSeveralOpsStaysOneCommit() async throws {
        let h = try Harness()
        await h.sync()
        let alpha = try #require(h.local("notes/alpha.md"))
        let landed = await h.fake.landed.count
        try h.store.delete(path: "notes/alpha.md")
        try h.store.save(path: "archive/alpha.md", text: alpha + "moved\n")
        try h.store.save(path: "people/noa.md", text: "# Noa\nrefused\n")
        await h.fake.refuseTrees(writing: "people/noa.md")

        #expect(await h.sync() == .needsAttention(1))
        #expect(await h.fake.landed.count == landed + 1)
        let head = await h.fake.head
        #expect(try await h.fake.changedPaths(in: head) == ["_trash/notes/alpha.md", "archive/alpha.md", "notes/alpha.md"])
        #expect(await h.fake.has("notes/alpha.md") == false)
        #expect(await h.fake.text("archive/alpha.md") == alpha + "moved\n")
        #expect(h.attention().map(\.path) == ["people/noa.md"])
    }

    /// Several refused ops among many: each is found and parked, and everything else is still one commit.
    @Test func everyRefusedOpIsFoundAmongMany() async throws {
        let h = try Harness()
        await h.sync()
        let landed = await h.fake.landed.count
        var good: [String] = []
        for i in 0..<12 {
            let path = "batch/n\(i).md"
            try h.store.save(path: path, text: "# N\(i)\n")
            if i == 3 || i == 10 { await h.fake.refuseTrees(writing: path) } else { good.append(path) }
        }
        #expect(await h.sync() == .needsAttention(2))
        #expect(await h.fake.landed.count == landed + 1)
        #expect(try await h.fake.changedPaths(in: await h.fake.head) == good.sorted())
        #expect(Set(h.attention().map(\.path)) == ["batch/n3.md", "batch/n10.md"])
        #expect(Set(h.store.journal.outbox().map(\.path)) == ["batch/n3.md", "batch/n10.md"])
    }
}
