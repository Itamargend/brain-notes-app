import BrainMerge
import Foundation
import Network

/// App settings from Info.plist (filled from the git-ignored `App/Config/GitHubApp.local.xcconfig`).
public struct AppConfig: Sendable, Equatable {
    public var clientId: String
    public var owner: String
    public var name: String

    public init(clientId: String, owner: String, name: String) {
        self.clientId = clientId; self.owner = owner; self.name = name
    }

    public init(info: [String: Any]) {
        clientId = info["BNGitHubClientID"] as? String ?? ""
        owner = info["BNRepoOwner"] as? String ?? ""
        name = info["BNRepoName"] as? String ?? ""
    }
}

/// Everything for one repo on this device. All local data is keyed by repo id, so a second repo later
/// is a second folder, not a migration.
public final class BrainSession: Sendable {
    public let repo: RepoTarget
    public let store: NoteStore
    public let engine: SyncEngine
    public let isDemo: Bool
    public let clientId: String
    private let tokens: TokenStore
    private let manager: TokenManager?
    private let transport: HTTPTransport?

    private init(repo: RepoTarget, store: NoteStore, engine: SyncEngine, isDemo: Bool, clientId: String,
                 tokens: TokenStore, manager: TokenManager?, transport: HTTPTransport?) {
        self.repo = repo; self.store = store; self.engine = engine; self.isDemo = isDemo; self.clientId = clientId
        self.tokens = tokens; self.manager = manager; self.transport = transport
    }

    /// The real app. Throws `RepoTarget.GuardError.repoNotAllowed` if the config names any other repo.
    public static func live(config: AppConfig, baseFolder: URL, deviceLabel: String) throws -> BrainSession {
        let repo = try RepoTarget(owner: config.owner, name: config.name)
        let transport = GitHubSession.make()
        let tokens = KeychainTokenStore()
        let manager = TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        let client = try GitHubHTTPClient(owner: repo.owner, name: repo.name, transport: transport, tokens: manager)
        let root = baseFolder.appendingPathComponent("Brain", isDirectory: true).appendingPathComponent(repo.id, isDirectory: true)
        let store = try NoteStore(root: root, deviceLabel: deviceLabel)
        return BrainSession(repo: repo, store: store, engine: SyncEngine(store: store, client: client), isDemo: false,
                            clientId: config.clientId, tokens: tokens, manager: manager, transport: transport)
    }

    /// True when a token exists, or may exist but cannot be read right now (device locked).
    public var hasTokens: Bool {
        do { return try tokens.load() != nil } catch { return true }
    }

    public func deviceFlow() -> DeviceFlow? {
        transport.map { DeviceFlow(clientId: clientId, transport: $0) }
    }

    /// The device flow finished. The new pair goes to the Keychain before anything uses it.
    public func signedIn(with pair: TokenPair) async throws {
        try tokens.save(pair)
        await manager?.reload()
        await engine.signedIn()
    }

    /// Sign out and wipe: tokens, note files, journal and index, all gone.
    public func signOutAndWipe() async throws {
        await engine.stop()
        tokens.clear()
        try store.wipe()
    }

    /// Demo and test mode: fake GitHub in process, no network, no Keychain, throwaway folder.
    public static func demo(fixtures: [(path: String, text: String)], baseFolder: URL, now: Date = Date()) async throws -> BrainSession {
        let root = baseFolder.appendingPathComponent("BrainDemo", isDirectory: true).appendingPathComponent(RepoTarget.allowed.id, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let store = try NoteStore(root: root, deviceLabel: "demo")
        let fake = DemoBrain.makeGitHub(fixtures: fixtures, now: now)
        await fake.value.setPathDates(DemoBrain.dates(for: fixtures.map(\.path), now: now))
        var config = SyncEngine.Config()
        // Nothing moves by itself in a demo: a note stays "saved on device" until you leave it.
        config.pollInterval = 3600
        config.idleFlush = 3600
        config.minCommitInterval = 0
        let engine = SyncEngine(store: store, client: fake.value, config: config)
        let session = BrainSession(repo: RepoTarget.allowed, store: store, engine: engine, isDemo: true, clientId: "",
                                   tokens: InMemoryTokenStore(TokenPair(access: "demo")), manager: nil, transport: nil)
        await DemoBrain.stage(session: session, github: fake.value)
        return session
    }
}

/// Network reachability, for "offline" instead of a retry loop.
public final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()

    public init(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { onChange($0.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "brainnotes.network", qos: .utility))
    }

    deinit { monitor.cancel() }
}

/// The demo: synthetic notes on a fake GitHub, then the real engine makes the states the screens need.
public enum DemoBrain {
    /// Every `.md` file under a folder, as (repo path, text). Other files and dot folders are skipped.
    public static func load(from folder: URL) -> [(path: String, text: String)] {
        let base = folder.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(path: String, text: String)] = []
        for case let u as URL in e {
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base + "/"), u.pathExtension.lowercased() == "md",
                  let d = try? Data(contentsOf: u), let text = decodeNote(d) else { continue }
            // Bundles and Mac file names can be in NFD; a repo path made here is NFC.
            let path = nfc(String(p.dropFirst(base.count + 1)))
            if PathPolicy.isSyncable(path) { out.append((path, text)) }
        }
        return out.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    struct Fake: @unchecked Sendable { let value: FakeGitHub }

    static func makeGitHub(fixtures: [(path: String, text: String)], now: Date) -> Fake {
        Fake(value: FakeGitHub(files: fixtures, date: now.addingTimeInterval(-40 * 86400)))
    }

    /// Spreads notes over the last weeks, inbox newest, so lists show real dates.
    static func dates(for paths: [String], now: Date) -> [(path: String, date: Date)] {
        var out: [(path: String, date: Date)] = []
        var i = 0
        for p in paths.sorted(by: { a, b in
            let ai = a.hasPrefix(PathPolicy.inboxFolder), bi = b.hasPrefix(PathPolicy.inboxFolder)
            return ai != bi ? ai : a.utf8.lexicographicallyPrecedes(b.utf8)
        }) {
            out.append((p, now.addingTimeInterval(Double(i) * -17 * 3600 - 600)))
            i += 1
        }
        return out
    }

    /// A conflict copy, a note deleted elsewhere and an unsynced note, all made by the real sync code.
    static func stage(session: BrainSession, github fake: FakeGitHub) async {
        let store = session.store
        let engine = session.engine
        await engine.sync(.manual)

        func editLine(_ path: String, _ old: String, mine: String, theirs: String) async {
            guard let text = (try? store.files.readText(path)) ?? nil, text.contains(old) else { return }
            _ = try? store.save(path: path, text: text.replacingOccurrences(of: old, with: mine))
            await fake.commitRemote([(path, text.replacingOccurrences(of: old, with: theirs))], message: "bot: update \(path)")
        }

        await editLine("projects/brain-notes-app.md", "Poll interval: 60 s while open feels right",
                       mine: "Poll interval: 30 s feels snappier on Wi-Fi", theirs: "Poll interval: 90 s saves battery")
        if let text = (try? store.files.readText("ideas/quiet-notifications.md")) ?? nil {
            _ = try? store.save(path: "ideas/quiet-notifications.md", text: text + "\nOne more thought I had on the train.\n")
            await fake.commitRemote([("ideas/quiet-notifications.md", nil)], message: "bot: clean up ideas")
        }
        await engine.sync(.manual)

        if let text = (try? store.files.readText("todo.md")) ?? nil {
            _ = try? store.save(path: "todo.md", text: text + "- Reply to the design review\n")
            await engine.noteSaved()
        }
        await engine.refresh()
    }
}
