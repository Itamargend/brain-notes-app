import BrainMerge
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

/// Non-secret app configuration read from Info.plist (`BNGitHubClientID` and `BNGitHubAppSlug`).
public struct AppConfig: Sendable, Equatable {
    public static let defaultAppSlug = "brain-notes-app"
    public static let createBrainURL = URL(string: "https://github.com/new?name=brain&visibility=private&description=My%20Brain%20Notes")!

    public var clientId: String
    public var appSlug: String

    public init(clientId: String, appSlug: String = AppConfig.defaultAppSlug) {
        self.clientId = clientId
        self.appSlug = appSlug
    }

    public init(info: [String: Any]) {
        clientId = (info["BNGitHubClientID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSlug = (info["BNGitHubAppSlug"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        appSlug = rawSlug.isEmpty ? Self.defaultAppSlug : rawSlug
    }

    /// Validated GitHub App installation URL (`https://github.com/apps/<slug>/installations/new`).
    public func installAppURL() throws -> URL {
        guard RepoTarget.isValidAppSlug(appSlug),
              let url = URL(string: "https://github.com/apps/\(appSlug)/installations/new"),
              url.scheme == "https",
              url.host == "github.com",
              url.port == nil,
              url.user == nil else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        return url
    }
}

/// Signed-in GitHub account context used before or between repository selections (device flow, installation listing,
/// and global sign-out).
public final class BrainAccount: Sendable {
    public let config: AppConfig
    public let baseFolder: URL
    private let tokens: TokenStore
    private let transport: HTTPTransport
    public let manager: TokenManager

    public init(config: AppConfig, baseFolder: URL,
                tokens: TokenStore = BrainSession.platformTokenStore(),
                transport: HTTPTransport = GitHubSession.make()) {
        self.config = config
        self.baseFolder = baseFolder
        self.tokens = tokens
        self.transport = transport
        self.manager = TokenManager(clientId: config.clientId, transport: transport, store: tokens)
    }

    public var hasTokens: Bool { tokens.holdsTokens() }

    public var selectionStore: SelectedRepoStore {
        SelectedRepoStore(baseFolder: baseFolder)
    }

    public func deviceFlow() -> DeviceFlow {
        DeviceFlow(clientId: config.clientId, transport: transport)
    }

    public func discoveryClient() -> GitHubDiscoveryClient {
        GitHubDiscoveryClient(transport: transport, tokens: manager)
    }

    public func saveTokens(_ pair: TokenPair) async throws {
        try tokens.save(pair)
        await manager.reload()
    }

    public func forgetCachedTokens() async {
        _ = await manager.forgetCachedPair()
    }

    /// Clears tokens, stored repo selection, and any local `Brain/` data when no session is open.
    public func signOutAndWipe() async throws {
        tokens.clear()
        await manager.reload()
        selectionStore.clear()
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        if FileManager.default.fileExists(atPath: brain.path) {
            try FileManager.default.removeItem(at: brain)
        }
    }
}

/// Everything for one picked private repository on this device. All local data is keyed by numeric `repoId`
/// (`Brain/<repoId>`), so two users or two repositories never share a folder.
public final class BrainSession: Sendable {
    public let repo: RepoTarget
    public let selection: SelectedRepo?
    public let store: NoteStore
    public let engine: SyncEngine
    public let isDemo: Bool
    public let clientId: String
    public let appSlug: String
    private let baseFolder: URL
    private let tokens: TokenStore
    private let manager: TokenManager?
    private let transport: HTTPTransport?

    private init(repo: RepoTarget, selection: SelectedRepo?, store: NoteStore, engine: SyncEngine, isDemo: Bool,
                 clientId: String, appSlug: String, baseFolder: URL,
                 tokens: TokenStore, manager: TokenManager?, transport: HTTPTransport?) {
        self.repo = repo
        self.selection = selection
        self.store = store
        self.engine = engine
        self.isDemo = isDemo
        self.clientId = clientId
        self.appSlug = appSlug
        self.baseFolder = baseFolder
        self.tokens = tokens
        self.manager = manager
        self.transport = transport
    }

    /// Opens a live session after verifying `selection` against `GET /user/installations` and
    /// `GET /user/installations/{id}/repositories` (matching numeric `repoId` AND byte-exact `owner` AND `name`,
    /// requiring `private == true`, and refreshing `defaultBranch`). Persists the refreshed selection on success.
    public static func openVerified(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                                    tokens: TokenStore = BrainSession.platformTokenStore(),
                                    transport: HTTPTransport = GitHubSession.make()) async throws -> BrainSession {
        guard RepoTarget.isValidAppSlug(config.appSlug) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        let manager = TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: manager)
        let verified = try await discovery.verifySelection(selection)
        try SelectedRepoStore(baseFolder: baseFolder).save(verified)
        return try buildLive(config: config, selection: verified, baseFolder: baseFolder, deviceLabel: deviceLabel,
                             tokens: tokens, transport: transport, manager: manager, initiallyVerified: true)
    }

    /// Opens a live session for a validated `SelectedRepo` (for offline launch fallback or unit tests with injected
    /// transports). `SyncEngine` still verifies installation membership before sending any `/repos/...` request.
    public static func live(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                            tokens: TokenStore = BrainSession.platformTokenStore(),
                            transport: HTTPTransport = GitHubSession.make()) throws -> BrainSession {
        guard RepoTarget.isValidAppSlug(config.appSlug) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        let manager = TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        return try buildLive(config: config, selection: selection, baseFolder: baseFolder, deviceLabel: deviceLabel,
                             tokens: tokens, transport: transport, manager: manager, initiallyVerified: false)
    }

    private static func buildLive(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                                  tokens: TokenStore, transport: HTTPTransport, manager: TokenManager,
                                  initiallyVerified: Bool) throws -> BrainSession {
        let repo = try selection.target()
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: manager)
        let client = GitHubHTTPClient(repo: repo, transport: transport, tokens: manager)
        let root = baseFolder.appendingPathComponent("Brain", isDirectory: true).appendingPathComponent(repo.id, isDirectory: true)
        let store = try NoteStore(root: root, deviceLabel: deviceLabel)
        let engine = SyncEngine(
            store: store,
            client: client,
            installationCheck: { _ = try await discovery.verifySelection(selection) },
            initiallyVerified: initiallyVerified
        )
        return BrainSession(
            repo: repo,
            selection: selection,
            store: store,
            engine: engine,
            isDemo: false,
            clientId: config.clientId,
            appSlug: config.appSlug,
            baseFolder: baseFolder,
            tokens: tokens,
            manager: manager,
            transport: transport
        )
    }

    /// The Keychain. Where there is none (Linux, which the app does not ship on) a store that never persists.
    @usableFromInline static func platformTokenStore() -> TokenStore {
        #if canImport(Security)
        return KeychainTokenStore()
        #else
        return InMemoryTokenStore()
        #endif
    }

    /// True when a token exists, or may exist but cannot be read right now (device locked). Any other failure to
    /// read the store counts as no token (`TokenStore.holdsTokens`).
    public var hasTokens: Bool { tokens.holdsTokens() }

    /// True when the local journal has unsynced edits in its outbox (requiring confirmation before switching repos).
    public var hasUnsyncedEdits: Bool { store.journal.outboxCount() > 0 }

    public func deviceFlow() -> DeviceFlow? {
        transport.map { DeviceFlow(clientId: clientId, transport: $0) }
    }

    public func discoveryClient() -> GitHubDiscoveryClient? {
        guard let transport, let manager else { return nil }
        return GitHubDiscoveryClient(transport: transport, tokens: manager)
    }

    /// The app is leaving the screen: whatever waits goes to GitHub now, with no idle wait, and then the token manager
    /// lets go of the tokens it held in memory. The Keychain keeps them; the next foreground run reads them from there.
    public func flushInBackground() async {
        await engine.sync(.background)
        _ = await manager?.forgetCachedPair()
    }

    /// The device flow finished. The new pair goes to the Keychain before anything uses it.
    public func signedIn(with pair: TokenPair) async throws {
        try tokens.save(pair)
        await manager?.reload()
        await engine.signedIn()
    }

    /// Shared local-copy wipe used by both "Change notes repository" and "Sign out and wipe": removes note files,
    /// `journal.sqlite` + `-wal`/`-shm`, `pins.json`, staging, search index, and persisted `selected-repo.json`.
    private func wipeLocalDataAndSelection() throws {
        try store.wipe()
        SelectedRepoStore(baseFolder: baseFolder).clear()
    }

    /// Wipes this repository's local copy (files, journal + `-wal`/`-shm`, pins, staging, search index) and clears the
    /// persisted selection BEFORE switching to another repository, while keeping the user's Keychain tokens intact.
    public func wipeForRepoSwitch() async throws {
        await engine.stop()
        await engine.waitUntilIdle()
        try wipeLocalDataAndSelection()
    }

    /// Sign out and wipe: tokens, stored selection, note files, journal and index, all gone.
    ///
    /// A run in flight finishes first. It would otherwise write into the folder after it was deleted: a first sync
    /// stores the downloaded notes outside any journal transaction, so the closed journal would not stop it. The
    /// tokens go first, and the manager forgets its copy, so that run fails at its next request instead of going on.
    /// A refresh already on the wire is dropped by the manager when it comes back; the tokens are cleared once more
    /// when nothing can be writing, as a backstop.
    public func signOutAndWipe() async throws {
        await engine.stop()
        tokens.clear()
        await manager?.reload()
        await engine.waitUntilIdle()
        tokens.clear()
        await manager?.reload()
        try wipeLocalDataAndSelection()
    }

    /// The folder demo sessions keep everything in. Never the live `Brain/` folder.
    public static func demoFolder(in baseFolder: URL) -> URL {
        baseFolder.appendingPathComponent("BrainDemo", isDirectory: true)
    }

    /// Demo and test mode: fake GitHub in process, no network, no Keychain, throwaway folder.
    public static func demo(fixtures: [(path: String, text: String)], baseFolder: URL, now: Date = Date()) async throws -> BrainSession {
        let root = demoFolder(in: baseFolder).appendingPathComponent(RepoTarget.demoRepo.id, isDirectory: true)
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
        let session = BrainSession(repo: RepoTarget.demoRepo, selection: nil, store: store, engine: engine, isDemo: true,
                                   clientId: "", appSlug: AppConfig.defaultAppSlug, baseFolder: baseFolder,
                                   tokens: InMemoryTokenStore(TokenPair(access: "demo")), manager: nil, transport: nil)
        await DemoBrain.stage(session: session, github: fake.value)
        return session
    }
}

#if canImport(Network)
/// Network reachability, for "offline" instead of a retry loop.
public final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()

    public init(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { onChange($0.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "brainnotes.network", qos: .utility))
    }

    deinit { monitor.cancel() }
}
#endif

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
            let ai = PathPolicy.isInInbox(a), bi = PathPolicy.isInInbox(b)
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
