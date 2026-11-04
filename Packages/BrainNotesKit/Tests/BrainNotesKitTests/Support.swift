import Foundation
@testable import BrainNotesKit

/// A clock tests move by hand. Engine sleeps advance it and are recorded, so no test really waits.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var recorded: [TimeInterval] = []

    init(_ date: Date = Date(timeIntervalSince1970: 1_793_000_000)) { self.date = date }

    var now: Date { lock.withLock { date } }
    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            recorded.append(seconds)
            date = date.addingTimeInterval(seconds)
        }
    }
}

/// A store and engine over a temp folder and a fake GitHub. `relaunch` drops the engine and opens the
/// same folder again, which is what a kill and a new launch look like to the journal.
final class Harness: @unchecked Sendable {
    let fake: FakeGitHub
    let dir: URL
    let clock: TestClock
    private(set) var store: NoteStore
    private(set) var engine: SyncEngine
    private let client: GitHubClient?
    private let config: SyncEngine.Config

    init(files: [(path: String, text: String)] = Harness.seed, client: GitHubClient? = nil, config: SyncEngine.Config = Harness.fastConfig()) throws {
        fake = FakeGitHub(files: files)
        clock = TestClock()
        self.client = client
        self.config = config
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-test-\(UUID().uuidString)", isDirectory: true)
        (store, engine) = try Self.open(dir: dir, fake: fake, client: client, clock: clock, config: config)
    }

    /// For HTTP tests: the client needs the fake before the harness exists.
    init(fake: FakeGitHub, client: GitHubClient) throws {
        self.fake = fake
        clock = TestClock()
        self.client = client
        config = Harness.fastConfig()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-test-\(UUID().uuidString)", isDirectory: true)
        (store, engine) = try Self.open(dir: dir, fake: fake, client: client, clock: clock, config: config)
    }

    static func fastConfig() -> SyncEngine.Config {
        var c = SyncEngine.Config()
        c.staleReadDelay = 1
        return c
    }

    private static func open(dir: URL, fake: FakeGitHub, client: GitHubClient?, clock: TestClock, config: SyncEngine.Config) throws -> (NoteStore, SyncEngine) {
        let store = try NoteStore(root: dir, deviceLabel: "test", now: { clock.now })
        let engine = SyncEngine(store: store, client: client ?? fake, config: config,
                                now: { clock.now }, sleep: { clock.sleep($0) }, random: { $0.lowerBound })
        return (store, engine)
    }

    /// Simulates a kill: nothing in memory survives.
    func relaunch() throws {
        (store, engine) = try Self.open(dir: dir, fake: fake, client: client, clock: clock, config: config)
    }

    /// Opens a second device on the same fake GitHub.
    func secondDevice() throws -> Harness {
        try Harness(sharing: fake, clock: clock)
    }

    private init(sharing fake: FakeGitHub, clock: TestClock) throws {
        self.fake = fake
        self.clock = clock
        client = nil
        config = Harness.fastConfig()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-test-\(UUID().uuidString)", isDirectory: true)
        (store, engine) = try Self.open(dir: dir, fake: fake, client: nil, clock: clock, config: config)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func sync(_ trigger: SyncTrigger = .manual) async -> SyncState {
        await engine.sync(trigger)
        return await engine.snapshot.state
    }

    func local(_ path: String) -> String? { (try? store.files.readText(path)) ?? nil }

    /// Local note files and their text, all of them.
    func allLocal() -> [(path: String, text: String)] {
        store.journal.allFiles().filter(\.local).compactMap { r in local(r.path).map { (r.path, $0) } }
    }

    func attention() -> [AttentionItem] { store.journal.attention() }

    static let seed: [(path: String, text: String)] = [
        ("README.md", "# Readme\nHello\n"),
        ("todo.md", "# Todo\n- one\n- two\n"),
        ("notes/alpha.md", "# Alpha\n\n## First\nline one\nline two\n\n## Second\nline three\nline four\n"),
        ("notes/beta.md", "# Beta\nbody\n"),
        ("people/noa.md", "# Noa\nDesigner\n"),
        ("עברית/רעיון.md", "# רעיון\nטקסט בעברית\n"),
        ("_inbox/quick.md", "quick thought\n"),
        ("_trash/old.md", "old\n"),
        (".obsidian/plugin.md", "hidden\n"),
        ("private/secret.md", "never here\n"),
        ("assets/photo.png", "not a note\n"),
    ]
}

extension FakeGitHub {
    /// True when the commit at `sha` changed exactly these paths compared with its parent.
    func changedPaths(in sha: String) async throws -> [String] {
        guard let info = commitInfo(sha), let parent = info.parents.first else { return [] }
        let c = try await compare(base: parent, head: sha)
        return c.files.flatMap { [$0.path] + ($0.previousPath.map { [$0] } ?? []) }.sorted()
    }
}

/// Text helpers. Secret-shaped strings are assembled at run time so none appears in the sources.
enum Fixture {
    static var githubToken: String { "gh" + "p_" + String(repeating: "a1B2", count: 9) }
    static var awsKey: String { "AK" + "IA" + "IOSFODNN7EXAMPLE" }
    static var privateKeyHeader: String { "-----BEGIN " + "RSA PRIVATE KEY-----" }
    static var apiKeyLine: String { "api_" + "key = " + String(repeating: "x9Y8", count: 8) }
}
