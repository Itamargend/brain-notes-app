import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// A deterministic random generator, so a failing seed can be replayed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Kills the "app" at a chosen API call: the call fails before or after GitHub applied it, and every later
/// call fails too, until the test relaunches. That is what a force-quit looks like from outside.
final class KillSwitchClient: GitHubClient, @unchecked Sendable {
    enum Killed: Error { case killed }
    let fake: FakeGitHub
    private let lock = NSLock()
    private var countdown: Int?
    private var applyBeforeDying = false
    private(set) var dead = false

    init(_ fake: FakeGitHub) { self.fake = fake }

    func arm(after calls: Int, applyBeforeDying: Bool) {
        lock.withLock {
            countdown = calls
            self.applyBeforeDying = applyBeforeDying
            dead = false
        }
    }

    func disarm() {
        lock.withLock {
            countdown = nil
            dead = false
        }
    }

    private enum Step { case go, die, applyThenDie }

    private func step() -> Step {
        lock.withLock {
            if dead { return .die }
            guard let c = countdown else { return .go }
            if c > 0 {
                countdown = c - 1
                return .go
            }
            dead = true
            countdown = nil
            return applyBeforeDying ? .applyThenDie : .die
        }
    }

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        switch step() {
        case .go:
            return try await body()
        case .die:
            throw GitHubError.timedOut
        case .applyThenDie:
            _ = try? await body()
            throw GitHubError.timedOut
        }
    }

    func getRef(etag: String?) async throws -> RefResult { try await run { try await fake.getRef(etag: etag) } }
    func getCommit(_ sha: String) async throws -> CommitInfo { try await run { try await fake.getCommit(sha) } }
    func compare(base: String, head: String) async throws -> Comparison { try await run { try await fake.compare(base: base, head: head) } }
    func tree(_ sha: String) async throws -> [TreeEntry] { try await run { try await fake.tree(sha) } }
    func blob(_ sha: String) async throws -> Data { try await run { try await fake.blob(sha) } }
    func tarball(_ sha: String) async throws -> Data { try await run { try await fake.tarball(sha) } }
    func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String { try await run { try await fake.createTree(baseTree: baseTree, writes: writes) } }
    func createCommit(_ commit: NewCommit) async throws -> String { try await run { try await fake.createCommit(commit) } }
    func updateRef(to sha: String) async throws { try await run { try await fake.updateRef(to: sha) } }
    func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] { try await run { try await fake.lastCommitDates(head: head, paths: paths) } }
}

@Suite struct ChaosTests {
    /// Every word typed anywhere must end up on GitHub, in its note or in a copy. No op lands twice.
    private func checkInvariants(_ h: Harness, typed: [String], seed: UInt64, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let remote = await h.fake.files()
        let everything = remote.map(\.text).joined(separator: "\n")
        for word in typed {
            #expect(everything.contains(word), "seed \(seed): lost \(word)", sourceLocation: sourceLocation)
        }
        var ops = Set<String>()
        for sha in await h.fake.landed {
            let info = try #require(await h.fake.commitInfo(sha))
            guard info.author.contains("Brain Notes") else { continue }
            let last = info.message.split(separator: "\n").last.map(String.init) ?? ""
            #expect(last.hasPrefix("Brain-Notes-Op: "), "seed \(seed)", sourceLocation: sourceLocation)
            #expect(ops.insert(last).inserted, "seed \(seed): op landed twice: \(last)", sourceLocation: sourceLocation)
            #expect(info.parents.count == 1, sourceLocation: sourceLocation)
        }
        // Device and GitHub agree on every note once the outbox is empty.
        #expect(h.store.journal.outboxCount() == 0, "seed \(seed)", sourceLocation: sourceLocation)
        #expect(h.store.journal.baseCommit == (await h.fake.head), "seed \(seed)", sourceLocation: sourceLocation)
        for f in remote where PathPolicy.isSyncable(f.path) {
            #expect(h.local(f.path) == f.text, "seed \(seed): \(f.path) differs", sourceLocation: sourceLocation)
        }
        let localPaths = Set(h.allLocal().map { PathKey($0.path) })
        let remotePaths = Set(remote.filter { PathPolicy.isSyncable($0.path) }.map { PathKey($0.path) })
        #expect(localPaths == remotePaths, "seed \(seed)", sourceLocation: sourceLocation)
    }

    private static let bodies = [
        "# Note\n\n## A\nfirst\nsecond\n\n## B\nthird\nfourth\n\n## C\nfifth\n",
        "just one line\n",
        "# כותרת\nשורה ראשונה\nשורה שנייה\n",
    ]

    private func seedFiles() -> [(path: String, text: String)] {
        (0..<8).map { ("work/n\($0).md", Self.bodies[$0 % Self.bodies.count]) }
    }

    /// Kill at every API call of a run, before and after the call was applied, with an edit waiting.
    @Test(arguments: [false, true])
    func killAtEveryCallOfAPush(applied: Bool) async throws {
        for kill in 0..<14 {
            let fake = FakeGitHub(files: seedFiles())
            let client = KillSwitchClient(fake)
            let h = try Harness(fake: fake, client: client)
            await h.sync()
            try h.store.save(path: "work/n0.md", text: Self.bodies[0] + "typed-\(kill)\n")
            await h.fake.commitRemote([("work/n1.md", Self.bodies[1] + "bot\n")])
            client.arm(after: kill, applyBeforeDying: applied)
            _ = await h.sync()
            client.disarm()
            try h.relaunch()
            try h.store.reconcile()
            h.clock.advance(120)
            await h.sync()
            await h.sync()
            try await checkInvariants(h, typed: ["typed-\(kill)", "bot"], seed: UInt64(kill))
        }
    }

    /// Kill during first sync: it restarts cleanly, whatever had been done.
    @Test func killAtEveryCallOfAFirstSync() async throws {
        for kill in 0..<8 {
            let fake = FakeGitHub(files: seedFiles())
            let client = KillSwitchClient(fake)
            let h = try Harness(fake: fake, client: client)
            client.arm(after: kill, applyBeforeDying: false)
            _ = await h.sync()
            client.disarm()
            try h.relaunch()
            await h.sync()
            await h.sync()
            try await checkInvariants(h, typed: [], seed: UInt64(kill))
        }
    }

    /// Random edits on two devices and a bot, with random kills and lost responses. Ends by settling.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    func randomRun(seed: UInt64) async throws {
        var rng = SplitMix(state: seed &* 0x1234_5678)
        let fake = FakeGitHub(files: seedFiles())
        let clientA = KillSwitchClient(fake)
        let a = try Harness(fake: fake, client: clientA)
        await a.sync()
        var typed: [String] = []
        var word = 0

        func edit(_ path: String, on h: Harness) throws {
            guard var text = h.local(path) else { return }
            word += 1
            let w = "w\(word)x"
            typed.append(w)
            var lines = text.components(separatedBy: "\n")
            let at = Int.random(in: 0..<lines.count, using: &rng)
            if Bool.random(using: &rng) && lines[at].hasPrefix("#") == false && !lines[at].isEmpty {
                // Replace a line: this is what makes real clashes. The old line may go, the new word may not.
                lines[at] = lines[at] + " " + w
            } else {
                lines.insert(w, at: at)
            }
            text = lines.joined(separator: "\n")
            try h.store.save(path: path, text: text)
        }

        for _ in 0..<25 {
            let path = "work/n\(Int.random(in: 0..<8, using: &rng)).md"
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...3:
                try edit(path, on: a)
            case 4...5:
                // A bot commit on current main.
                if let cur = await fake.text(path) {
                    word += 1
                    let w = "b\(word)x"
                    typed.append(w)
                    await fake.commitRemote([(path, cur + w + "\n")])
                }
            case 6:
                await fake.inject(.updateRef, .lostResponse)
                await a.sync()
            case 7:
                clientA.arm(after: Int.random(in: 0..<8, using: &rng), applyBeforeDying: Bool.random(using: &rng))
                _ = await a.sync()
                clientA.disarm()
                try a.relaunch()
                try a.store.reconcile()
            case 8:
                await fake.beforeNextUpdateRef { f in
                    if let cur = await f.text("work/n7.md") { await f.commitRemote([("work/n7.md", cur + "race\n")]) }
                }
                a.clock.advance(120)
                await a.sync()
            default:
                a.clock.advance(120)
                await a.sync()
            }
        }
        await fake.clearFaults()
        clientA.disarm()
        // Conflict copies are expected in this run; settle.
        for _ in 0..<4 {
            a.clock.advance(120)
            await a.sync()
        }
        try await checkInvariants(a, typed: typed, seed: seed)
    }

    /// Two devices editing the same notes: both end up identical, and nothing typed is lost.
    @Test(arguments: [UInt64(21), 22, 23, 24, 25, 26])
    func twoDevices(seed: UInt64) async throws {
        var rng = SplitMix(state: seed &* 0x9876_5431)
        let a = try Harness(files: seedFiles())
        let b = try a.secondDevice()
        await a.sync()
        await b.sync()
        var typed: [String] = []
        var word = 0
        for _ in 0..<20 {
            let h = Bool.random(using: &rng) ? a : b
            let path = "work/n\(Int.random(in: 0..<4, using: &rng)).md"
            if let text = h.local(path) {
                word += 1
                let w = "t\(word)x"
                typed.append(w)
                var lines = text.components(separatedBy: "\n")
                lines.insert(w, at: Int.random(in: 0..<lines.count, using: &rng))
                try h.store.save(path: path, text: lines.joined(separator: "\n"))
            }
            if Int.random(in: 0..<3, using: &rng) == 0 {
                a.clock.advance(120)
                await h.sync()
            }
        }
        for _ in 0..<3 {
            a.clock.advance(120)
            await a.sync()
            await b.sync()
        }
        try await checkInvariants(a, typed: typed, seed: seed)
        try await checkInvariants(b, typed: typed, seed: seed)
    }
}
