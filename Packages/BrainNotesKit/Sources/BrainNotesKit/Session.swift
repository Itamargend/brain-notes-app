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
/// and global sign-out). Owns the single `TokenManager` shared across discovery and any open `BrainSession`.
public final class BrainAccount: Sendable {
    public let config: AppConfig
    public let baseFolder: URL
    public let tokens: TokenStore
    public let transport: HTTPTransport
    public let manager: TokenManager
    private let deviceFlowSleep: (@Sendable (Duration) async throws -> Void)?

    public init(config: AppConfig, baseFolder: URL,
                tokens: TokenStore = BrainSession.platformTokenStore(),
                transport: HTTPTransport = GitHubSession.make(),
                deviceFlowSleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.config = config
        self.baseFolder = baseFolder
        self.tokens = tokens
        self.transport = transport
        self.manager = TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        self.deviceFlowSleep = deviceFlowSleep
    }

    public var hasTokens: Bool { tokens.holdsTokens() }

    public var selectionStore: SelectedRepoStore {
        SelectedRepoStore(baseFolder: baseFolder)
    }

    public func deviceFlow() -> DeviceFlow? {
        guard !config.clientId.isEmpty else { return nil }
        if let sleep = deviceFlowSleep {
            return DeviceFlow(clientId: config.clientId, transport: transport, sleep: sleep)
        }
        return DeviceFlow(clientId: config.clientId, transport: transport)
    }

    public func discoveryClient() -> GitHubDiscoveryClient {
        GitHubDiscoveryClient(transport: transport, tokens: manager)
    }

    /// Verifies who `pair` belongs to via `GET /user` in memory WITHOUT writing `pair` to the persistent `TokenStore`
    /// or mutating the shared `TokenManager`.
    public func verifyCandidateToken(_ pair: TokenPair) async throws -> GitHubAccount {
        let candidateStore = InMemoryTokenStore(pair)
        let candidateManager = TokenManager(clientId: config.clientId, transport: transport, store: candidateStore)
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: candidateManager)
        return try await discovery.authenticatedUser()
    }

    public func saveTokens(_ pair: TokenPair) async throws {
        try tokens.save(pair)
        await manager.reload()
    }

    public func forgetCachedTokens() async {
        _ = await manager.forgetCachedPair()
    }

    /// Clears tokens, cancels any in-flight refresh, removes stored selection, and deletes the entire `<baseFolder>/Brain`
    /// and `<baseFolder>/BrainDemo` directories, throwing if either still exists on disk.
    public func signOutAndWipe() async throws {
        tokens.clear()
        await manager.reload()
        selectionStore.clear()
        try Self.wipeAllLocalDirectories(baseFolder: baseFolder)
    }

    static func wipeDirectory(_ folder: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
        if fm.fileExists(atPath: folder.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func wipeAllLocalDirectories(baseFolder: URL) throws {
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        let demo = BrainSession.demoFolder(in: baseFolder)
        var firstError: Error?
        for folder in [brain, demo] {
            do {
                try wipeDirectory(folder)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

/// Everything for one picked private repository on this device. All local data is keyed by numeric `repoId`
/// (`Brain/<repoId>`), so two users or two repositories never share a folder.
public final class BrainSession: Sendable {
    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var currentRepo: RepoTarget
        private var currentSelection: SelectedRepo?

        init(repo: RepoTarget, selection: SelectedRepo?) {
            self.currentRepo = repo
            self.currentSelection = selection
        }

        var repo: RepoTarget { lock.withLock { currentRepo } }
        var selection: SelectedRepo? { lock.withLock { currentSelection } }

        func update(repo: RepoTarget, selection: SelectedRepo?) {
            lock.withLock {
                self.currentRepo = repo
                self.currentSelection = selection
            }
        }
    }

    private let stateBox: StateBox
    private let httpClient: GitHubHTTPClient?
    public var repo: RepoTarget { stateBox.repo }
    public var selection: SelectedRepo? { stateBox.selection }
    public let store: NoteStore
    public let engine: SyncEngine
    public let isDemo: Bool
    public let clientId: String
    public let appSlug: String
    private let baseFolder: URL
    private let tokens: TokenStore
    private let manager: TokenManager?
    private let transport: HTTPTransport?
    private let deviceFlowSleep: (@Sendable (Duration) async throws -> Void)?
    public var tokenManager: TokenManager? { manager }

    private init(repo: RepoTarget, selection: SelectedRepo?, httpClient: GitHubHTTPClient?,
                 store: NoteStore, engine: SyncEngine, isDemo: Bool,
                 clientId: String, appSlug: String, baseFolder: URL,
                 tokens: TokenStore, manager: TokenManager?, transport: HTTPTransport?,
                 deviceFlowSleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.stateBox = StateBox(repo: repo, selection: selection)
        self.httpClient = httpClient
        self.store = store
        self.engine = engine
        self.isDemo = isDemo
        self.clientId = clientId
        self.appSlug = appSlug
        self.baseFolder = baseFolder
        self.tokens = tokens
        self.manager = manager
        self.transport = transport
        self.deviceFlowSleep = deviceFlowSleep
    }

    /// Opens a verified live session sharing `account`'s single `TokenManager`, `TokenStore`, and `HTTPTransport`.
    public static func openVerified(account: BrainAccount, selection: SelectedRepo, deviceLabel: String) async throws -> BrainSession {
        try await openVerified(
            config: account.config,
            selection: selection,
            baseFolder: account.baseFolder,
            deviceLabel: deviceLabel,
            tokens: account.tokens,
            transport: account.transport,
            manager: account.manager,
            deviceFlowSleep: account.deviceFlowSleepValue
        )
    }

    /// Opens a live session sharing `account`'s single `TokenManager`, `TokenStore`, and `HTTPTransport`.
    public static func live(account: BrainAccount, selection: SelectedRepo, deviceLabel: String) throws -> BrainSession {
        try live(
            config: account.config,
            selection: selection,
            baseFolder: account.baseFolder,
            deviceLabel: deviceLabel,
            tokens: account.tokens,
            transport: account.transport,
            manager: account.manager,
            deviceFlowSleep: account.deviceFlowSleepValue
        )
    }

    /// Opens a live session after verifying `selection` against `GET /user/installations` and
    /// `GET /user/installations/{id}/repositories` (matching numeric `repoId` AND byte-exact `owner` AND `name`,
    /// requiring `private == true`, and refreshing `defaultBranch`). Persists the refreshed selection on success.
    public static func openVerified(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                                    tokens: TokenStore = BrainSession.platformTokenStore(),
                                    transport: HTTPTransport = GitHubSession.make(),
                                    manager: TokenManager? = nil,
                                    deviceFlowSleep: (@Sendable (Duration) async throws -> Void)? = nil) async throws -> BrainSession {
        guard RepoTarget.isValidAppSlug(config.appSlug) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        let sharedManager = manager ?? TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: sharedManager)
        let verified = try await discovery.verifySelection(selection)
        try SelectedRepoStore(baseFolder: baseFolder).save(verified)
        return try buildLive(config: config, selection: verified, baseFolder: baseFolder, deviceLabel: deviceLabel,
                             tokens: tokens, transport: transport, manager: sharedManager,
                             initiallyVerified: true, deviceFlowSleep: deviceFlowSleep)
    }

    /// Opens a live session for a validated `SelectedRepo` (for offline launch fallback or unit tests with injected
    /// transports). `SyncEngine` still verifies installation membership before sending any `/repositories/...` request.
    public static func live(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                            tokens: TokenStore = BrainSession.platformTokenStore(),
                            transport: HTTPTransport = GitHubSession.make(),
                            manager: TokenManager? = nil,
                            deviceFlowSleep: (@Sendable (Duration) async throws -> Void)? = nil) throws -> BrainSession {
        guard RepoTarget.isValidAppSlug(config.appSlug) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        let sharedManager = manager ?? TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        return try buildLive(config: config, selection: selection, baseFolder: baseFolder, deviceLabel: deviceLabel,
                             tokens: tokens, transport: transport, manager: sharedManager,
                             initiallyVerified: false, deviceFlowSleep: deviceFlowSleep)
    }

    private static func buildLive(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                                  tokens: TokenStore, transport: HTTPTransport, manager: TokenManager,
                                  initiallyVerified: Bool,
                                  deviceFlowSleep: (@Sendable (Duration) async throws -> Void)?) throws -> BrainSession {
        let initialRepo = try selection.target()
        let stateBox = StateBox(repo: initialRepo, selection: selection)
        let selectionStore = SelectedRepoStore(baseFolder: baseFolder)
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: manager)
        let client = GitHubHTTPClient(
            repo: initialRepo,
            transport: transport,
            tokens: manager,
            onDefaultBranchChanged: { updatedRepo in
                if let cur = stateBox.selection,
                   let updatedSelection = try? cur.withDefaultBranch(updatedRepo.defaultBranch) {
                    stateBox.update(repo: updatedRepo, selection: updatedSelection)
                    try? selectionStore.save(updatedSelection)
                } else {
                    stateBox.update(repo: updatedRepo, selection: stateBox.selection)
                }
            }
        )
        let root = baseFolder.appendingPathComponent("Brain", isDirectory: true).appendingPathComponent(initialRepo.id, isDirectory: true)
        FileStore.excludeFromBackup(baseFolder.appendingPathComponent("Brain", isDirectory: true))
        let store = try NoteStore(root: root, deviceLabel: deviceLabel)
        let engine = SyncEngine(
            store: store,
            client: client,
            installationCheck: {
                let current = stateBox.selection ?? selection
                let refreshed = try await discovery.verifySelection(current)
                if refreshed != current {
                    try client.updateDefaultBranch(refreshed.defaultBranch)
                    stateBox.update(repo: client.repo, selection: refreshed)
                    try? selectionStore.save(refreshed)
                }
            },
            initiallyVerified: initiallyVerified
        )
        let session = BrainSession(
            repo: initialRepo,
            selection: selection,
            httpClient: client,
            store: store,
            engine: engine,
            isDemo: false,
            clientId: config.clientId,
            appSlug: config.appSlug,
            baseFolder: baseFolder,
            tokens: tokens,
            manager: manager,
            transport: transport,
            deviceFlowSleep: deviceFlowSleep
        )
        // Share the exact same StateBox used by `client` and `installationCheck`.
        return session.replacingStateBox(stateBox)
    }

    private func replacingStateBox(_ sharedBox: StateBox) -> BrainSession {
        BrainSession(
            sharedBox: sharedBox,
            httpClient: httpClient,
            store: store,
            engine: engine,
            isDemo: isDemo,
            clientId: clientId,
            appSlug: appSlug,
            baseFolder: baseFolder,
            tokens: tokens,
            manager: manager,
            transport: transport,
            deviceFlowSleep: deviceFlowSleep
        )
    }

    private init(sharedBox: StateBox, httpClient: GitHubHTTPClient?,
                 store: NoteStore, engine: SyncEngine, isDemo: Bool,
                 clientId: String, appSlug: String, baseFolder: URL,
                 tokens: TokenStore, manager: TokenManager?, transport: HTTPTransport?,
                 deviceFlowSleep: (@Sendable (Duration) async throws -> Void)?) {
        self.stateBox = sharedBox
        self.httpClient = httpClient
        self.store = store
        self.engine = engine
        self.isDemo = isDemo
        self.clientId = clientId
        self.appSlug = appSlug
        self.baseFolder = baseFolder
        self.tokens = tokens
        self.manager = manager
        self.transport = transport
        self.deviceFlowSleep = deviceFlowSleep
    }

    /// Updates this session's persisted and in-memory `SelectedRepo` (for default-branch renames or owner binding)
    /// when `verified` names the exact same `repoId`, `owner`, and `name`.
    public func updateVerifiedSelection(_ verified: SelectedRepo) throws {
        let current = stateBox.repo
        guard verified.repoId == current.repoId,
              sameBytes(verified.owner, current.owner),
              sameBytes(verified.name, current.name) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        try httpClient?.updateDefaultBranch(verified.defaultBranch)
        let updatedRepo = try verified.target()
        stateBox.update(repo: updatedRepo, selection: verified)
        try SelectedRepoStore(baseFolder: baseFolder).save(verified)
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
        guard !clientId.isEmpty else { return nil }
        if let sleep = deviceFlowSleep {
            return transport.map { DeviceFlow(clientId: clientId, transport: $0, sleep: sleep) }
        }
        return transport.map { DeviceFlow(clientId: clientId, transport: $0) }
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

    /// Wipes this repository's local copy, clears `selected-repo.json`, and removes any orphan `Brain/<other>` folders
    /// (preserving only unrescued legacy `<owner>_<name>` folders that still hold unsynced outbox edits), while keeping
    /// the user's Keychain tokens intact.
    public func wipeForRepoSwitch() async throws {
        await engine.stop()
        await engine.waitUntilIdle()
        try store.wipe()
        SelectedRepoStore(baseFolder: baseFolder).clear()
        try LegacyBrainMigration.removeRepoAndOrphanFoldersPreservingUnrescuedLegacy(baseFolder: baseFolder)
    }

    /// Sign out and wipe: for a live session, tokens, stored selection, and the entire `<baseFolder>/Brain` and
    /// `<baseFolder>/BrainDemo` directories (including any orphan or legacy folders) are deleted and verified gone.
    /// For a sample-notes demo session (`isDemo == true`), only `BrainDemo` is wiped so live `Brain/` data stays intact.
    public func signOutAndWipe() async throws {
        await engine.stop()
        tokens.clear()
        await manager?.reload()
        await engine.waitUntilIdle()
        tokens.clear()
        await manager?.reload()
        try? store.journal.close()
        try? store.index.close()
        if isDemo {
            try BrainAccount.wipeDirectory(Self.demoFolder(in: baseFolder))
        } else {
            SelectedRepoStore(baseFolder: baseFolder).clear()
            try BrainAccount.wipeAllLocalDirectories(baseFolder: baseFolder)
        }
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
        let session = BrainSession(repo: RepoTarget.demoRepo, selection: nil, httpClient: nil, store: store, engine: engine, isDemo: true,
                                   clientId: "", appSlug: AppConfig.defaultAppSlug, baseFolder: baseFolder,
                                   tokens: InMemoryTokenStore(TokenPair(access: "demo")), manager: nil, transport: nil)
        await DemoBrain.stage(session: session, github: fake.value)
        return session
    }
}

extension BrainAccount {
    fileprivate var deviceFlowSleepValue: (@Sendable (Duration) async throws -> Void)? {
        deviceFlowSleep
    }
}

/// Detects, excludes from backup, rescues, and cleans up legacy build-1 folders (`Brain/<owner>_<name>/`) in live mode.
public enum LegacyBrainMigration {
    public static let settingsNotice =
        "Unsynced notes from an earlier version are kept safely on this device until you connect their repository or choose Sign out and wipe."

    public struct ScanResult: Sendable, Equatable {
        public let unrescuedFolders: [String]
        public let rescuedCount: Int

        public init(unrescuedFolders: [String], rescuedCount: Int = 0) {
            self.unrescuedFolders = unrescuedFolders
            self.rescuedCount = rescuedCount
        }

        public var notice: String? {
            unrescuedFolders.isEmpty ? nil : LegacyBrainMigration.settingsNotice
        }
    }

    /// Marks `<baseFolder>/Brain` and any legacy subfolders excluded from backup immediately.
    public static func excludeBrainFromBackup(baseFolder: URL) {
        let fm = FileManager.default
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        guard fm.fileExists(atPath: brain.path) else { return }
        FileStore.excludeFromBackup(brain)
        let children = (try? fm.contentsOfDirectory(at: brain, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            FileStore.excludeFromBackup(child)
        }
    }

    private static func isLegacyFolderName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "selected-repo.json" else { return false }
        return !DiscoveryGuard.isPositiveDecimalInt64(name)
    }

    private enum LegacyDisposition {
        case clean
        case hasUnsynced([OutboxOp])
        case unreadable
    }

    private static func inspectLegacyFolder(_ dir: URL) -> LegacyDisposition {
        let fm = FileManager.default
        let journalURL = dir.appendingPathComponent("journal.sqlite", isDirectory: false)
        guard fm.fileExists(atPath: journalURL.path) else {
            return .clean
        }
        do {
            let journal = try Journal(path: journalURL.path)
            defer { try? journal.close() }
            let ops = journal.outbox()
            return ops.isEmpty ? .clean : .hasUnsynced(ops)
        } catch {
            return .unreadable
        }
    }

    /// Scans `<baseFolder>/Brain` for non-numeric legacy folders: marks `Brain/` excluded from backup, deletes legacy
    /// folders that have no unsynced outbox edits, and keeps any legacy folder with unsynced (or unreadable) edits.
    @discardableResult
    public static func inspectAndCleanLegacyFolders(baseFolder: URL) -> ScanResult {
        excludeBrainFromBackup(baseFolder: baseFolder)
        let fm = FileManager.default
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        guard fm.fileExists(atPath: brain.path) else {
            return ScanResult(unrescuedFolders: [])
        }
        let items = (try? fm.contentsOfDirectory(at: brain, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var unrescued: [String] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDir else { continue }
            let name = item.lastPathComponent
            guard isLegacyFolderName(name) else { continue }
            FileStore.excludeFromBackup(item)
            switch inspectLegacyFolder(item) {
            case .clean:
                try? fm.removeItem(at: item)
                if fm.fileExists(atPath: item.path) {
                    unrescued.append(name)
                }
            case .hasUnsynced, .unreadable:
                unrescued.append(name)
            }
        }
        return ScanResult(unrescuedFolders: unrescued.sorted())
    }

    /// After `session` has been verified, checks for a matching legacy `Brain/<owner>_<name>/` folder, moves any
    /// unsynced outbox edits into `session.store` using existing `NoteStore` APIs, and deletes the legacy folder.
    @discardableResult
    public static func rescueMatchingLegacyFolder(baseFolder: URL, into session: BrainSession) -> ScanResult {
        guard !session.isDemo else { return ScanResult(unrescuedFolders: []) }
        excludeBrainFromBackup(baseFolder: baseFolder)
        let fm = FileManager.default
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        let expectedName = "\(session.repo.owner)_\(session.repo.name)"
        let legacyDir = brain.appendingPathComponent(expectedName, isDirectory: true)
        var rescuedCount = 0

        if fm.fileExists(atPath: legacyDir.path) {
            FileStore.excludeFromBackup(legacyDir)
            switch inspectLegacyFolder(legacyDir) {
            case .clean:
                try? fm.removeItem(at: legacyDir)
            case .unreadable:
                break
            case let .hasUnsynced(ops):
                let legacyFiles = FileStore(root: legacyDir)
                var canDeleteLegacy = true
                do {
                    for op in ops {
                        _ = try session.store.files.url(for: op.path)
                        guard FileStore.nameFits(op.path) else {
                            throw FileStoreError.invalidPath
                        }
                        switch op.kind {
                        case .create, .edit:
                            guard let content = op.content ?? ((try? legacyFiles.readText(op.path)) ?? nil) else {
                                throw FileStoreError.notText
                            }
                            if let existing = try session.store.read(op.path) {
                                if !sameBytes(existing, content) {
                                    _ = try session.store.createCopy(of: op.path, text: content)
                                }
                            } else {
                                _ = try session.store.save(path: op.path, text: content)
                            }
                            rescuedCount += 1
                        case .delete:
                            if session.store.journal.file(op.path) != nil {
                                try session.store.delete(path: op.path)
                                rescuedCount += 1
                            }
                        }
                    }
                } catch {
                    canDeleteLegacy = false
                }
                if canDeleteLegacy {
                    try? fm.removeItem(at: legacyDir)
                }
            }
        }

        let remaining = inspectAndCleanLegacyFolders(baseFolder: baseFolder)
        return ScanResult(unrescuedFolders: remaining.unrescuedFolders, rescuedCount: rescuedCount)
    }

    /// Removes every numeric `Brain/<repoId>` folder and every clean/orphan item under `Brain/`, preserving only
    /// legacy `<owner>_<name>` folders that hold unsynced (or unreadable) edits. Throws if any non-preserved item remains.
    static func removeRepoAndOrphanFoldersPreservingUnrescuedLegacy(baseFolder: URL) throws {
        let fm = FileManager.default
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        guard fm.fileExists(atPath: brain.path) else { return }
        FileStore.excludeFromBackup(brain)
        let items = (try? fm.contentsOfDirectory(at: brain, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var keptAny = false
        var firstError: Error?
        for item in items {
            let name = item.lastPathComponent
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir, isLegacyFolderName(name) {
                switch inspectLegacyFolder(item) {
                case .hasUnsynced, .unreadable:
                    FileStore.excludeFromBackup(item)
                    keptAny = true
                    continue
                case .clean:
                    break
                }
            }
            do {
                try fm.removeItem(at: item)
            } catch {
                if fm.fileExists(atPath: item.path), firstError == nil {
                    firstError = error
                }
            }
            if fm.fileExists(atPath: item.path), firstError == nil {
                firstError = CocoaError(.fileWriteNoPermission)
            }
        }
        if !keptAny {
            try? fm.removeItem(at: brain)
        }
        if let firstError {
            throw firstError
        }
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
