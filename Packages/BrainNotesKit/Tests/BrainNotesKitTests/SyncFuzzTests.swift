import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// Random interleavings of saves, pulls, pushes, kills and other writers, then invariants. Written by an
/// independent reviewer of the engine; every config below found a real bug at some point.
/// Expects a case-insensitive disk, which is what Macs and iPhones have by default.
/// `BN_FUZZ_SEEDS=200 swift test --filter SyncFuzz` runs it for longer.
struct FuzzFlags: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let creates = FuzzFlags(rawValue: 1 << 0)       // compose; the first line moves the path
    static let samePath = FuzzFlags(rawValue: 1 << 1)      // a bot creates a path the user may be composing
    static let deletes = FuzzFlags(rawValue: 1 << 2)       // user and bot delete
    static let renames = FuzzFlags(rawValue: 1 << 3)       // bot renames, exact or edited
    static let caseRenames = FuzzFlags(rawValue: 1 << 4)   // bot renames changing only case
    static let twins = FuzzFlags(rawValue: 1 << 5)         // bot adds case and NFC/NFD twins, edits and deletes them
    static let longNames = FuzzFlags(rawValue: 1 << 6)     // names the disk can't hold, and long paths whose copies can't fit
    static let typedDuring = FuzzFlags(rawValue: 1 << 7)   // a save lands during the PATCH, from text older than the disk's
    static let staleEditor = FuzzFlags(rawValue: 1 << 8)   // an editor saves from text a sync has moved past
    static let kills = FuzzFlags(rawValue: 1 << 9)         // kill at a random call, relaunch, reconcile
    static let faults = FuzzFlags(rawValue: 1 << 10)       // lost responses, timeouts, 422s, races
    static let resolves = FuzzFlags(rawValue: 1 << 11)     // Needs attention choices, as the screen offers them
    static let twoDevices = FuzzFlags(rawValue: 1 << 12)   // a second engine edits too
}

/// Words that must survive. A lock, because a push's hook adds them from inside the fake.
final class FuzzWords: @unchecked Sendable {
    private let lock = NSLock()
    private var must = Set<String>()
    func add(_ w: String) { lock.withLock { _ = must.insert(w) } }
    func drop(where f: (String) -> Bool) { lock.withLock { must = must.filter { !f($0) } } }
    var all: Set<String> { lock.withLock { must } }
}

/// One run. A class, because the steps share state across awaits; it is used from one task at a time.
final class FuzzRun: @unchecked Sendable {
    private let flags: FuzzFlags
    private let steps: Int
    private let fake: FakeGitHub
    private let client: KillSwitchClient
    private let a: Harness
    private let b: Harness?
    private let devices: [Harness]
    private let words = FuzzWords()
    private var rng: SplitMix
    private var counter = 0
    private var opened: [(path: String, text: String)] = []
    private(set) var trace: [String] = []
    private let titles = ["Alpha", "Beta", "Gamma"]

    init(seed: UInt64, flags: FuzzFlags, steps: Int) throws {
        self.flags = flags
        self.steps = steps
        rng = SplitMix(state: seed &* 0x1234_5678_9ABC &+ UInt64(flags.rawValue))
        let bodies = ["# Note\n\n## A\nfirst\nsecond\n\n## B\nthird\nfourth\n\n## C\nfifth\n", "just one line\n", "# כותרת\nשורה ראשונה\nשורה שנייה\n"]
        var seedFiles: [(path: String, text: String)] = (0..<6).map { ("work/n\($0).md", bodies[$0 % bodies.count]) }
        seedFiles.append(("work/Caf\u{E9}.md", "cafe body\n"))
        if flags.contains(.longNames) {
            seedFiles.append((String(repeating: "deep-folder/", count: 20) + "note.md", "long path body\n"))
            seedFiles.append(("long/" + String(repeating: "x", count: 300) + ".md", "no room on disk\n"))
        }
        fake = FakeGitHub(files: seedFiles)
        client = KillSwitchClient(fake)
        a = try Harness(fake: fake, client: client)
        b = flags.contains(.twoDevices) ? try a.secondDevice() : nil
        devices = [a] + (b.map { [$0] } ?? [])
    }

    private func word(_ tag: String) -> String {
        counter += 1
        return "\(tag)\(counter)x"
    }

    private func newWord(_ tag: String) -> String {
        let w = word(tag)
        words.add(w)
        return w
    }

    private func pick<T>(_ x: [T]) -> T? { x.isEmpty ? nil : x[Int.random(in: 0..<x.count, using: &rng)] }

    private func notes(_ h: Harness) -> [String] {
        h.store.journal.allFiles().filter { $0.local && !$0.path.hasPrefix("_trash/") && h.store.files.exists($0.path) }.map(\.path)
    }

    private func remoteNotes() async -> [(path: String, text: String)] {
        await fake.files().filter { !$0.path.hasPrefix("_trash/") }
    }

    private func edit(_ h: Harness, _ path: String) throws {
        guard let cur = try h.store.read(path) else { return }
        let w = newWord("u")
        var lines = cur.components(separatedBy: "\n")
        let at = Int.random(in: 0..<lines.count, using: &rng)
        if Bool.random(using: &rng), !lines[at].isEmpty, !lines[at].hasPrefix("#"), !lines[at].hasPrefix("-") {
            lines[at] += " " + w  // changes a line, which is what makes real clashes
        } else {
            lines.insert(w, at: at)
        }
        let p = try h.store.save(path: path, text: lines.joined(separator: "\n"), editingFrom: cur)
        trace.append("edit \(path) -> \(p) \(w)")
    }

    private func step(_ action: String, on h: Harness) async throws {
        switch action {
        case "edit":
            if let p = pick(notes(h)) {
                try edit(h, p)
                await h.engine.noteSaved()
            }
        case "create":
            let w = newWord("c")
            let p = try h.store.createNote(folder: "fresh", text: "\(pick(titles)!)\n\(w)\n")
            trace.append("create \(p) \(w)")
            await h.engine.noteSaved()
        case "retitle":
            if let op = pick(h.store.journal.outbox().filter({ $0.kind == .create && $0.content != nil })), let cur = op.content {
                let p = try h.store.save(path: op.path, text: "\(pick(titles)!) \(newWord("t"))\n" + cur, editingFrom: cur)
                trace.append("retitle \(op.path) -> \(p)")
                await h.engine.noteSaved()
            }
        case "delete":
            if let p = pick(notes(h)), try h.store.read(p) != nil {
                // A draft is simply gone, by design; an edit's unsynced text goes to _trash and must survive.
                if let op = h.store.journal.outbox().first(where: { sameBytes($0.path, p) }), op.kind == .create, let c = op.content {
                    let remote = await fake.text(p) ?? ""
                    words.drop { c.contains($0) && !remote.contains($0) }
                }
                try h.store.delete(path: p)
                trace.append("delete \(p)")
                await h.engine.noteSaved()
            }
        case "bot":
            if let f = pick(await remoteNotes()) {
                let w = newWord("b")
                await fake.commitRemote([(f.path, f.text + w + "\n")])
                trace.append("bot edit \(f.path) \(w)")
            }
        case "botCreate":
            let p = "fresh/\(pick(titles)!).md"
            if await !fake.has(p) {
                let w = newWord("r")
                await fake.commitRemote([(p, "theirs\n\(w)\n")])
                trace.append("bot create \(p) \(w)")
            }
        case "botDelete":
            if let f = pick(await remoteNotes()) {
                words.drop { f.text.contains($0) }
                await fake.commitRemote([(f.path, nil)])
                trace.append("bot delete \(f.path)")
            }
        case "botRename":
            if let f = pick(await remoteNotes().filter { !$0.path.hasPrefix("moved/") && !$0.path.hasPrefix("long/") && !$0.path.hasPrefix("deep-") }) {
                let new = "moved/" + f.path.replacingOccurrences(of: "/", with: "-")
                if await !fake.has(new) {
                    let text = f.text + (Bool.random(using: &rng) ? newWord("m") + "\n" : "")
                    await fake.commitRemote([(f.path, nil), (new, text)])
                    trace.append("bot rename \(f.path) -> \(new)")
                }
            }
        case "botCaseRename":
            if let f = pick(await fake.files().filter { $0.path.hasPrefix("work/n") }) {
                let new = "work/N" + f.path.dropFirst("work/n".count)
                if await !fake.has(new) {
                    await fake.commitRemote([(f.path, nil), (new, f.text)])
                    trace.append("bot case rename \(f.path) -> \(new)")
                }
            }
        case "botTwin":
            // An uppercase spelling sorts before the stored one, and NFD before NFC: the held-back row comes first.
            let twin = pick((0..<6).map { "work/N\($0).md" } + ["work/Cafe\u{301}.md"] + titles.map { "fresh/\($0.lowercased()).md" })!
            let w = newWord("w")
            let old = await fake.text(twin) ?? "twin\n"
            await fake.commitRemote([(twin, old + w + "\n")])
            trace.append("bot twin \(twin) \(w)")
        case "typedDuring":
            if let p = pick(notes(h)), let cur = try h.store.read(p) {
                let w = word("d"), store = h.store, words = self.words
                await fake.beforeNextUpdateRef { _ in
                    words.add(w)
                    _ = try? store.save(path: p, text: cur + w + "\n", editingFrom: cur)
                }
                trace.append("typedDuring armed \(p) \(w)")
                try edit(h, p)
                h.clock.advance(120)
                await h.sync()
            }
        case "open":
            if let p = pick(notes(h)), let t = try h.store.read(p) {
                opened.append((p, t))
                trace.append("open \(p)")
            }
        case "saveOpened":
            if !opened.isEmpty {
                let e = opened.removeFirst(), w = newWord("s")
                let p = try a.store.save(path: e.path, text: e.text + w + "\n", editingFrom: e.text)
                trace.append("saveOpened \(e.path) -> \(p) \(w)")
                await a.engine.noteSaved()
            }
        case "kill":
            let after = Int.random(in: 0..<8, using: &rng), apply = Bool.random(using: &rng)
            client.arm(after: after, applyBeforeDying: apply)
            a.clock.advance(120)
            _ = await a.sync()
            client.disarm()
            try a.relaunch()
            try a.store.reconcile()
            trace.append("kill after \(after) apply=\(apply)")
        case "fault":
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: await fake.inject(.updateRef, .lostResponse)
            case 1: await fake.inject(.updateRef, .error(.timedOut))
            case 2: await fake.inject(.compare, .error(.timedOut))
            case 3: await fake.inject(.createTree, .error(.timedOut))
            case 4: await fake.inject(.getRef, .error(.server(500)))
            case 5: await fake.inject(.updateRef, .error(.notFastForward))
            default: await fake.inject(.blob, .error(.timedOut))
            }
            a.clock.advance(120)
            await a.sync()
            await fake.clearFaults()
            trace.append("fault")
        case "race":
            if let f = pick(await remoteNotes()) {
                let w = word("x"), path = f.path, words = self.words
                await fake.beforeNextUpdateRef { g in
                    if let cur = await g.text(path) {
                        words.add(w)
                        await g.commitRemote([(path, cur + w + "\n")])
                    }
                }
                trace.append("race armed \(path) \(w)")
                h.clock.advance(120)
                await h.sync()
            }
        case "resolve":
            if let item = pick(h.store.journal.attention()) {
                var choices: [AttentionChoice] = [.keepBoth]
                switch item.reason {
                case "conflict-copy" where item.detail == "deleted-remotely": choices += [.restore]
                case "conflict-copy": choices += [.useMine, .useTheirs]
                case "delete-skipped": choices += [.deleteAnyway]
                case "case-clash", "unstorable": break
                default: choices = [.retry]
                }
                let c = pick(choices)!
                try? h.store.resolve(item, c)
                trace.append("resolve \(item.reason)@\(item.path) \(c)")
                await h.engine.noteSaved()
            }
        default:
            let t = pick([SyncTrigger.poll, .foreground, .leftNote, .manual, .background])!
            h.clock.advance(Double.random(in: 0..<90, using: &rng))
            await h.engine.sync(t)
            trace.append("sync \(t) outbox=\(h.store.journal.outboxCount())")
        }
    }

    private func settle(_ rounds: Int) async {
        for i in 0..<rounds {
            for d in devices {
                a.clock.advance(120)
                await d.sync()
            }
            trace.append("settle \(i)")
        }
    }

    func run() async throws -> [String] {
        for d in devices { await d.sync() }
        let menu: [(FuzzFlags, [String])] = [
            (.creates, ["create", "retitle"]), (.samePath, ["botCreate", "botCreate"]), (.deletes, ["delete", "botDelete"]),
            (.renames, ["botRename", "botRename"]), (.caseRenames, ["botCaseRename"]), (.twins, ["botTwin", "botTwin", "botDelete"]),
            (.typedDuring, ["typedDuring", "typedDuring"]), (.staleEditor, ["open", "saveOpened"]), (.kills, ["kill", "kill"]),
            (.faults, ["fault", "fault", "race"]), (.resolves, ["resolve", "resolve"]),
        ]
        let actions = ["edit", "edit", "edit", "bot", "bot", "sync", "sync", "sync"] + menu.filter { flags.contains($0.0) }.flatMap(\.1)
        for _ in 0..<steps {
            let h = b != nil && Bool.random(using: &rng) ? b! : a
            try await step(pick(actions)!, on: h)
        }

        // Settle, then a relaunch: launch repair must find nothing that changes GitHub's text.
        await fake.clearFaults()
        client.disarm()
        await settle(5)
        for d in devices {
            try d.relaunch()
            try d.store.reconcile()
            try d.store.repairIndexIfNeeded()
        }
        trace.append("relaunch")
        await settle(3)
        return try await invariants()
    }

    /// A word is safe on GitHub, or in an op that Needs attention says is waiting.
    private func invariants() async throws -> [String] {
        var v: [String] = []
        let remote = await fake.files()
        let everything = (remote.map(\.text) + devices.flatMap { $0.store.journal.outbox().compactMap(\.content) }).joined(separator: "\n")
        for w in words.all where !everything.contains(w) { v.append("lost:\(w)") }
        let onGitHub = Set(remote.filter { PathPolicy.isSyncable($0.path) }.map { PathKey($0.path) })
        let head = await fake.head
        for (tag, h) in zip(["A", "B"], devices) {
            let rows = h.store.journal.allFiles(), open = h.store.journal.attention(), outbox = h.store.journal.outbox()
            for op in outbox {
                if !open.contains(where: { sameBytes($0.path, op.path) || sameBytes($0.path, nfc(op.path)) }) { v.append("op-unexplained:\(tag) \(op.kind.rawValue) \(op.path)") }
                if op.inFlight { v.append("in-flight-left:\(tag) \(op.path)") }
            }
            if h.store.journal.pendingPush() != nil { v.append("pending-left:\(tag)") }
            if h.store.journal.baseCommit != head { v.append("base-not-head:\(tag)") }
            for f in remote where PathPolicy.isSyncable(f.path) {
                guard let row = h.store.journal.file(f.path) else {
                    v.append("no-row:\(tag) \(f.path)")
                    continue
                }
                if row.local, !row.dirty, !sameDoc(h.local(f.path), f.text) { v.append("differs:\(tag) \(f.path)") }
                if !row.dirty, row.blobSha != GitBlob.sha(f.text) { v.append("sha-differs:\(tag) \(f.path)") }
            }
            var keys: [PathKey: String] = [:]
            for r in rows where r.local {
                let key = PathKey(foldKey(r.path))
                if let other = keys[key], !sameBytes(other, r.path) { v.append("two-spellings:\(tag) \(other) \(r.path)") }
                keys[key] = r.path
            }
            let localIndex = PathIndex(rows.filter(\.local).map(\.path))
            for r in rows {
                if r.dirty, !outbox.contains(where: { sameBytes($0.path, r.path) }) { v.append("dirty-no-op:\(tag) \(r.path)") }
                if r.blobSha != nil, !onGitHub.contains(PathKey(r.path)) { v.append("row-not-on-github:\(tag) \(r.path)") }
                if !r.local, !r.dirty, FileStore.nameFits(r.path), localIndex.clash(r.path) == nil { v.append("held-not-promoted:\(tag) \(r.path)") }
            }
            for item in open where item.reason == "case-clash" || item.reason == "unstorable" {
                if !rows.contains(where: { sameBytes($0.path, item.path) && (!$0.local || $0.dirty) }) { v.append("stale-attention:\(tag) \(item.path)") }
            }
            let indexed = await h.store.index.allPaths()
            let visible = rows.filter { $0.local && PathPolicy.isVisible($0.path) && h.store.files.exists($0.path) }
            for p in indexed where !visible.contains(where: { sameBytes($0.path, p) }) { v.append("ghost-in-index:\(tag) \(p)") }
            for r in visible where !indexed.contains(where: { sameBytes($0, r.path) }) { v.append("missing-from-index:\(tag) \(r.path)") }
        }
        var ops = Set<String>()
        for sha in await fake.landed {
            guard let info = await fake.commitInfo(sha), info.author.contains("Brain Notes") else { continue }
            if !ops.insert(info.message.split(separator: "\n").last.map(String.init) ?? "").inserted { v.append("op-landed-twice") }
        }
        return v
    }
}

@Suite(.serialized) struct SyncFuzzTests {
    static let seeds = ProcessInfo.processInfo.environment["BN_FUZZ_SEEDS"].flatMap(Int.init) ?? 12

    /// Prints a line per config, and the shortest failing trace per kind of violation.
    static func run(_ name: String, _ flags: FuzzFlags, steps: Int = 40) async throws {
        var kinds: [String: Int] = [:], shortest: [String: (UInt64, [String], [String])] = [:], bad = 0
        for seed in 1...UInt64(seeds) {
            let fuzz = try FuzzRun(seed: seed, flags: flags, steps: steps)
            let violations = try await fuzz.run()
            if !violations.isEmpty { bad += 1 }
            for v in violations {
                let k = String(v.prefix { $0 != ":" })
                kinds[k, default: 0] += 1
                if shortest[k] == nil || fuzz.trace.count < shortest[k]!.2.count { shortest[k] = (seed, violations, fuzz.trace) }
            }
        }
        print("[FUZZ] \(name): \(bad)/\(seeds) bad \(kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
        for (k, s) in shortest.sorted(by: { $0.key < $1.key }) {
            print("[FUZZ] \(name) \(k) seed=\(s.0) \(s.1.filter { $0.hasPrefix(k) }.prefix(2))")
            for line in s.2.suffix(25) { print("[FUZZ]   \(line)") }
        }
        #expect(bad == 0, "\(name): \(kinds)")
    }

    static let configs: [(String, FuzzFlags)] = [
        ("base", []), ("creates+samePath", [.creates, .samePath]), ("deletes", [.deletes]), ("renames", [.renames]),
        ("caseRenames", [.caseRenames]), ("twins", [.twins]), ("longNames", [.longNames, .resolves]), ("typedDuring", [.typedDuring]),
        ("staleEditor", [.staleEditor]), ("kills+faults", [.kills, .faults]), ("twoDevices", [.twoDevices, .creates, .resolves, .deletes]),
        ("noTwins", [.creates, .samePath, .deletes, .renames, .typedDuring, .staleEditor, .kills, .faults, .resolves]),
        ("everything", [.creates, .samePath, .deletes, .renames, .caseRenames, .twins, .longNames, .typedDuring, .staleEditor, .kills, .faults, .resolves, .twoDevices]),
    ]

    @Test(arguments: configs.indices) func fuzz(_ i: Int) async throws {
        try await Self.run(Self.configs[i].0, Self.configs[i].1)
    }
}
