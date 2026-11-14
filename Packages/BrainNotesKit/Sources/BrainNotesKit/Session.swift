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
    /// The sign-in screen opens GitHub's code page with `?user_code=<code>` added, so that GitHub can fill the code in.
    /// GitHub may ignore it, and then the page looks like the plain one. Set to false to open the plain page.
    public static let prefillDeviceCodeInURL = true
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
              let url = URL(string: "https://github.com/apps/\(appSlug)/installations/new") else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        return try Self.validatedGitHubWebURL(url)
    }

    /// Validated GitHub App configure URL for an existing installation (`settings/installations/<id>` on a personal
    /// account, or `organizations/<org>/settings/installations/<id>` on an organization account).
    public func configureInstallationURL(
        installationId: Int64,
        accountLogin: String? = nil,
        isOrganization: Bool = false
    ) throws -> URL {
        guard installationId > 0 else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        if let login = accountLogin, !RepoTarget.isValidOwner(login) {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        let path: String
        if isOrganization {
            guard let org = accountLogin else {
                throw RepoTarget.GuardError.repoNotAllowed
            }
            path = "https://github.com/organizations/\(org)/settings/installations/\(installationId)"
        } else {
            path = "https://github.com/settings/installations/\(installationId)"
        }
        guard let url = URL(string: path) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        return try Self.validatedGitHubWebURL(url)
    }

    public func configureInstallationURL(_ installation: GitHubInstallation) throws -> URL {
        try configureInstallationURL(
            installationId: installation.id,
            accountLogin: installation.accountLogin,
            isOrganization: installation.isOrganization
        )
    }

    /// Returns `installations/new` when no installation exists yet, or the configure URL for an existing installation.
    public func accessManagementURL(
        installations: [GitHubInstallation],
        preferredInstallationId: Int64? = nil,
        preferredAccountLogin: String? = nil
    ) throws -> URL {
        guard !installations.isEmpty else {
            return try installAppURL()
        }
        if let preferredId = preferredInstallationId,
           let match = installations.first(where: { $0.id == preferredId }) {
            return try configureInstallationURL(match)
        }
        if installations.count == 1 {
            return try configureInstallationURL(installations[0])
        }
        if let login = preferredAccountLogin,
           let personal = installations.first(where: {
               !$0.isOrganization && ($0.accountLogin?.caseInsensitiveCompare(login) == .orderedSame)
           }) {
            return try configureInstallationURL(personal)
        }
        return try configureInstallationURL(installations[0])
    }

    private static func validatedGitHubWebURL(_ url: URL) throws -> URL {
        guard url.scheme == "https",
              url.host == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
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
    /// or mutating the shared `TokenManager`. Returns both the verified `GitHubAccount` and the latest `TokenPair`
    /// from the candidate store (in case `authenticatedUser()` triggered a single-use refresh token rotation).
    public func verifyCandidateToken(_ pair: TokenPair) async throws -> (account: GitHubAccount, pair: TokenPair) {
        let candidateStore = InMemoryTokenStore(pair)
        let candidateManager = TokenManager(clientId: config.clientId, transport: transport, store: candidateStore)
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: candidateManager)
        let account = try await discovery.authenticatedUser()
        let latestPair = (try? candidateStore.load()) ?? pair
        return (account, latestPair)
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
        try LegacyBrainMigration.wipeFolderNoFollow(folder)
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
    static func openVerified(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
                             tokens: TokenStore = BrainSession.platformTokenStore(),
                             transport: HTTPTransport = GitHubSession.make(),
                             manager: TokenManager? = nil,
                             deviceFlowSleep: (@Sendable (Duration) async throws -> Void)? = nil) async throws -> BrainSession {
        guard RepoTarget.isValidAppSlug(config.appSlug) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        let sharedManager = manager ?? TokenManager(clientId: config.clientId, transport: transport, store: tokens)
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: sharedManager)
        let ownerChecked = try await verifyAuthenticatedOwnerIfBound(selection, using: discovery)
        let verified = try await discovery.verifySelection(ownerChecked)
        try SelectedRepoStore(baseFolder: baseFolder).save(verified)
        return try buildLive(config: config, selection: verified, baseFolder: baseFolder, deviceLabel: deviceLabel,
                             tokens: tokens, transport: transport, manager: sharedManager,
                             initiallyVerified: true, deviceFlowSleep: deviceFlowSleep)
    }

    /// Opens a live session for a validated `SelectedRepo` (for offline launch fallback or unit tests with injected
    /// transports). `SyncEngine` still verifies installation membership before sending any `/repositories/...` request.
    static func live(config: AppConfig, selection: SelectedRepo, baseFolder: URL, deviceLabel: String,
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

    private static func verifyAuthenticatedOwnerIfBound(
        _ selection: SelectedRepo,
        using discovery: GitHubDiscoveryClient
    ) async throws -> SelectedRepo {
        guard let expectedUserId = selection.userId else { return selection }
        let account: GitHubAccount
        do {
            account = try await discovery.authenticatedUser()
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHubError.unauthorized {
            throw SelectionVerificationError.accountCheckFailed(unauthorized: true)
        } catch {
            throw SelectionVerificationError.accountCheckFailed(unauthorized: false)
        }
        guard account.id == expectedUserId else {
            throw SelectionVerificationError.accountMismatch(login: account.login)
        }
        return (try? selection.withAccount(account)) ?? selection
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
        let brainDir = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        if LegacyBrainMigration.isSymbolicLink(brainDir) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: brainDir.path, isDirectory: false))
        }
        let root = brainDir.appendingPathComponent(initialRepo.id, isDirectory: true)
        if LegacyBrainMigration.isSymbolicLink(root) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: root.path, isDirectory: false))
        }
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)
        FileStore.excludeFromBackup(brainDir)
        let store = try NoteStore(root: root, deviceLabel: deviceLabel)
        let engine = SyncEngine(
            store: store,
            client: client,
            installationCheck: {
                let current = stateBox.selection ?? selection
                let ownerChecked = try await Self.verifyAuthenticatedOwnerIfBound(current, using: discovery)
                let refreshed = try await discovery.verifySelection(ownerChecked)
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

    /// Synchronous read of the persisted user-pause setting so Settings never flickers on open.
    public var isUserPaused: Bool { store.journal.isUserPaused }

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

    /// Wipes `<baseFolder>/Brain` (the open repo store, `selected-repo.json`, orphan numeric folders, and any legacy
    /// build-1 folders) without following symlinks, while keeping Keychain tokens and `BrainDemo` intact.
    public func wipeForRepoSwitch() async throws {
        await engine.stop()
        await engine.waitUntilIdle()
        try? store.journal.close()
        try? store.index.close()
        let brain = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        try LegacyBrainMigration.wipeFolderNoFollow(brain)
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
        let demoDir = demoFolder(in: baseFolder)
        if LegacyBrainMigration.isSymbolicLink(demoDir) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: demoDir.path, isDirectory: false))
        }
        let root = demoDir.appendingPathComponent(RepoTarget.demoRepo.id, isDirectory: true)
        try? LegacyBrainMigration.wipeFolderNoFollow(root)
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

/// Deletes legacy build-1 folders (`Brain/<non-numeric name>`) on live launch without reading or migrating them, and
/// wipes `<baseFolder>/Brain` and `<baseFolder>/BrainDemo` without following symlinks.
public enum LegacyBrainMigration {
    /// lstat-style check: true when `url` itself is a symbolic link (including a dangling link), without following it.
    public static func isSymbolicLink(_ url: URL) -> Bool {
        let entry = URL(fileURLWithPath: url.path, isDirectory: false)
        if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return true
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            return true
        }
        return false
    }

    /// lstat-style existence check: true when an entry (including a dangling symbolic link) exists at `url.path`.
    public static func itemExistsNoFollow(_ url: URL) -> Bool {
        let entry = URL(fileURLWithPath: url.path, isDirectory: false)
        return (try? FileManager.default.attributesOfItem(atPath: entry.path)) != nil
    }

    /// Live-launch cleanup (never called in demo mode):
    /// - If `<baseFolder>/Brain` itself is a symlink, unlinks it without enumerating or touching its target.
    /// - Marks `<baseFolder>/Brain` `isExcludedFromBackup`.
    /// - Unlinks any symlinked direct child without touching its target.
    /// - Marks each legacy `<non-numeric name>` folder `isExcludedFromBackup` until removed, then deletes it without
    ///   reading, opening, parsing, or migrating anything inside it.
    public static func cleanUpLegacyFolders(baseFolder: URL) {
        let fm = FileManager.default
        let brain = URL(
            fileURLWithPath: baseFolder.appendingPathComponent("Brain", isDirectory: false).path,
            isDirectory: false
        )
        guard itemExistsNoFollow(brain) else { return }
        if isSymbolicLink(brain) {
            try? fm.removeItem(at: brain)
            return
        }
        let isBrainDir = (try? brain.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard isBrainDir else {
            try? fm.removeItem(at: brain)
            return
        }
        FileStore.excludeFromBackup(brain)
        let items = (try? fm.contentsOfDirectory(
            at: brain,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        )) ?? []
        for rawItem in items {
            let item = URL(fileURLWithPath: rawItem.path, isDirectory: false)
            if isSymbolicLink(item) {
                try? fm.removeItem(at: item)
                continue
            }
            let name = item.lastPathComponent
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if name == "selected-repo.json" && !isDir {
                FileStore.excludeFromBackup(item)
                continue
            }
            if isDir && DiscoveryGuard.isPositiveDecimalInt64(name) {
                FileStore.excludeFromBackup(item)
                continue
            }
            FileStore.excludeFromBackup(item)
            try? fm.removeItem(at: item)
        }
    }

    /// Removes `folder` (`<baseFolder>/Brain` or `<baseFolder>/BrainDemo`) without following symlinks:
    /// if `folder` itself is a symlink, unlinks only the symlink; otherwise checks each child with lstat-style
    /// `isSymbolicLink`, unlinks/removes children, removes `folder`, and throws if `folder` still exists.
    public static func wipeFolderNoFollow(_ folder: URL) throws {
        let fm = FileManager.default
        let entry = URL(fileURLWithPath: folder.path, isDirectory: false)
        guard itemExistsNoFollow(entry) else { return }
        if isSymbolicLink(entry) {
            try fm.removeItem(at: entry)
            if itemExistsNoFollow(entry) {
                throw CocoaError(.fileWriteNoPermission)
            }
            return
        }
        var firstError: Error?
        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir {
            FileStore.excludeFromBackup(entry)
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
                )
            } catch {
                items = []
                if firstError == nil {
                    firstError = error
                }
            }
            for rawChild in items {
                let child = URL(fileURLWithPath: rawChild.path, isDirectory: false)
                if !isSymbolicLink(child) {
                    FileStore.excludeFromBackup(child)
                }
                do {
                    try fm.removeItem(at: child)
                } catch {
                    if itemExistsNoFollow(child), firstError == nil {
                        firstError = error
                    }
                }
                if itemExistsNoFollow(child), firstError == nil {
                    firstError = CocoaError(.fileWriteNoPermission)
                }
            }
        }
        do {
            try fm.removeItem(at: entry)
        } catch {
            if itemExistsNoFollow(entry), firstError == nil {
                firstError = error
            }
        }
        if itemExistsNoFollow(entry) {
            throw firstError ?? CocoaError(.fileWriteNoPermission)
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
