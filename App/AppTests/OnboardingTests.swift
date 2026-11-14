import AppKit
import BrainNotesKit
import XCTest
@testable import BrainNotes

/// Answers GitHub's sign-in and installation-discovery endpoints from a script and refuses everything else.
/// It is all these tests' live sessions have behind them, so none of them can reach the network. Every request is recorded.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct RepoFixture: Sendable {
        var repoId: Int64
        var owner: String
        var name: String
        var defaultBranch: String = "main"
        var isPrivate: Bool = true
    }

    private let lock = NSLock()
    private var recorded: [String] = []
    private var codesIssued = 0
    private var approved = false
    private var expired: Set<String> = []
    private var declined: Set<String> = []
    private var holding = false
    private var refusing = false
    private var discoveryOffline = false
    private var userOffline = false
    private var userStatusOverride: Int?
    private var truncatedDiscovery = false
    private var holdingDiscoveryPage1 = false
    private var inDiscoveryPage1 = false
    private var discoveryPage1Waiters: [CheckedContinuation<Void, Never>] = []
    private var holdingUser = false
    private var inUserRequest = false
    private var userWaiters: [CheckedContinuation<Void, Never>] = []
    private var spentRefreshTokens: Set<String> = []
    private var rotatedTokensIssued = 0
    private var userAccount: (id: Int64, login: String) = (1, "alice")
    private var allRepositoriesSelection = false
    private var installationAccountType = "User"
    private var installationAccountLoginOverride: String?
    private var forceInstallationPresent = false
    private var codeDelay: Duration = .zero
    private var repositories: [RepoFixture] = [
        RepoFixture(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true)
    ]

    var requests: [String] { lock.withLock { recorded } }
    /// Every request to the REST API, as opposed to the sign-in endpoints.
    var apiRequests: [String] { requests.filter { !$0.contains("/login/") } }
    var repoRequests: [String] { requests.filter { $0.contains("/repositories/") } }
    func requests(forCode deviceCode: String) -> Int { lock.withLock { recorded.filter { $0 == "poll \(deviceCode)" }.count } }

    /// The next poll gets a token. `approve(false)` takes the approval back, for the next code.
    func approve(_ on: Bool = true) { lock.withLock { approved = on } }
    /// Polls for this code get `expired_token`.
    func expire(deviceCode: String) { lock.withLock { _ = expired.insert(deviceCode) } }
    /// Polls for this code get `access_denied`.
    func decline(deviceCode: String) { lock.withLock { _ = declined.insert(deviceCode) } }
    /// New codes take this long to arrive.
    func delayCodes(_ delay: Duration) { lock.withLock { codeDelay = delay } }
    /// Repository sync requests wait until `release`, so that a sync stays where it is.
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }
    /// API requests get a 401, as with a token GitHub no longer accepts.
    func refuseToken(_ value: Bool = true) { lock.withLock { refusing = value } }
    /// Configures which repositories `/user/installations` + `/user/installations/77/repositories` return.
    func setRepositories(_ list: [RepoFixture]) { lock.withLock { repositories = list } }
    func setDiscoveryOffline(_ offline: Bool) { lock.withLock { discoveryOffline = offline } }
    func setUserOffline(_ offline: Bool) { lock.withLock { userOffline = offline } }
    func setUserStatus(_ status: Int?) { lock.withLock { userStatusOverride = status } }
    func setUser(id: Int64, login: String) { lock.withLock { userAccount = (id, login) } }
    func setTruncatedDiscovery(_ truncated: Bool) { lock.withLock { truncatedDiscovery = truncated } }
    func setAllRepositoriesSelection(_ all: Bool) { lock.withLock { allRepositoriesSelection = all } }
    func setInstallationAccountType(_ type: String) { lock.withLock { installationAccountType = type } }
    func setInstallationAccountLogin(_ login: String?) { lock.withLock { installationAccountLoginOverride = login } }
    func setForceInstallationPresent(_ present: Bool) { lock.withLock { forceInstallationPresent = present } }
    var isInDiscoveryPage1: Bool { lock.withLock { inDiscoveryPage1 } }
    func holdDiscoveryPage1() { lock.withLock { holdingDiscoveryPage1 = true } }
    func releaseDiscoveryPage1() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            holdingDiscoveryPage1 = false
            inDiscoveryPage1 = false
            let list = discoveryPage1Waiters
            discoveryPage1Waiters = []
            return list
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
    var isInUserRequest: Bool { lock.withLock { inUserRequest } }
    func holdUser() { lock.withLock { holdingUser = true } }
    func releaseUser() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            holdingUser = false
            inUserRequest = false
            let list = userWaiters
            userWaiters = []
            return list
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        lock.withLock { recorded.append(url.absoluteString) }
        switch url.path {
        case "/login/device/code":
            let n: Int = lock.withLock {
                codesIssued += 1
                return codesIssued
            }
            try await Task.sleep(for: lock.withLock { codeDelay })
            return try answer(url, ["device_code": "device-\(n)", "user_code": "TEST-000\(n)",
                                    "verification_uri": "https://github.com/login/device", "interval": 0, "expires_in": 900])
        case "/login/oauth/access_token":
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("grant_type=refresh_token") {
                let rawRefresh = body.split(separator: "&").first { $0.hasPrefix("refresh_token=") }.map { String($0.dropFirst(14)) } ?? ""
                let refreshToken = rawRefresh.removingPercentEncoding ?? rawRefresh
                let rotated: Int? = lock.withLock {
                    if spentRefreshTokens.contains(refreshToken) { return nil }
                    _ = spentRefreshTokens.insert(refreshToken)
                    rotatedTokensIssued += 1
                    return rotatedTokensIssued
                }
                guard let n = rotated else {
                    return try answer(url, ["error": "bad_refresh_token"])
                }
                return try answer(url, [
                    "access_token": "rotated-access-\(n)",
                    "refresh_token": "ghr_rotated_\(n)",
                    "token_type": "bearer",
                    "expires_in": 28_800,
                ])
            }
            let code = body.split(separator: "&").first { $0.hasPrefix("device_code=") }.map { String($0.dropFirst(12)) } ?? ""
            lock.withLock { recorded.append("poll \(code)") }
            // The real flow waits seconds between polls. A few milliseconds keep this one from spinning.
            try await Task.sleep(for: .milliseconds(5))
            if lock.withLock({ expired.contains(code) }) { return try answer(url, ["error": "expired_token"]) }
            if lock.withLock({ declined.contains(code) }) { return try answer(url, ["error": "access_denied"]) }
            if lock.withLock({ approved }) { return try answer(url, ["access_token": "test-access", "token_type": "bearer"]) }
            return try answer(url, ["error": "authorization_pending"])
        case "/user":
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard holdingUser else { return true }
                    inUserRequest = true
                    userWaiters.append(cont)
                    return false
                }
                if resumeNow {
                    cont.resume()
                }
            }
            if lock.withLock({ refusing }) { return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))) }
            if let status = lock.withLock({ userStatusOverride }) {
                return (Data("{\"message\":\"error\"}".utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
            }
            if lock.withLock({ userOffline || discoveryOffline }) { throw URLError(.notConnectedToInternet) }
            let acct = lock.withLock { userAccount }
            return try answer(url, ["id": acct.id, "login": acct.login])
        case "/user/installations":
            if lock.withLock({ refusing }) { return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))) }
            if lock.withLock({ discoveryOffline }) { throw URLError(.notConnectedToInternet) }
            let hasInstallation = lock.withLock { !repositories.isEmpty || truncatedDiscovery || forceInstallationPresent }
            if hasInstallation {
                let (acctLogin, acctType, allSel) = lock.withLock {
                    (installationAccountLoginOverride ?? userAccount.login, installationAccountType, allRepositoriesSelection)
                }
                return try answer(url, [
                    "total_count": 1,
                    "installations": [[
                        "id": 77,
                        "repository_selection": allSel ? "all" : "selected",
                        "account": ["login": acctLogin, "type": acctType],
                    ]],
                ])
            }
            return try answer(url, ["total_count": 0, "installations": [] as [[String: Any]]])
        case "/user/installations/77/repositories":
            if lock.withLock({ refusing }) { return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))) }
            if lock.withLock({ discoveryOffline }) { throw URLError(.notConnectedToInternet) }
            if lock.withLock({ truncatedDiscovery }) {
                let pageStr = url.query?.split(separator: "&").first(where: { $0.hasPrefix("page=") }).map { String($0.dropFirst(5)) } ?? "1"
                let page = Int(pageStr) ?? 1
                if page == 1 {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let resumeNow: Bool = lock.withLock {
                            guard holdingDiscoveryPage1 else { return true }
                            inDiscoveryPage1 = true
                            discoveryPage1Waiters.append(cont)
                            return false
                        }
                        if resumeNow {
                            cont.resume()
                        }
                    }
                }
                let base = (page - 1) * 100
                let pageRepos: [[String: Any]] = (1...100).map { idx in
                    [
                        "id": 90_000 + base + idx,
                        "name": "filler-\(base + idx)",
                        "private": true,
                        "visibility": "private",
                        "default_branch": "main",
                        "owner": ["login": "alice"],
                    ]
                }
                return try answer(url, ["total_count": 999, "repositories": pageRepos])
            }
            let list = lock.withLock { repositories }.map { r -> [String: Any] in
                [
                    "id": r.repoId,
                    "name": r.name,
                    "private": r.isPrivate,
                    "visibility": r.isPrivate ? "private" : "public",
                    "default_branch": r.defaultBranch,
                    "owner": ["login": r.owner],
                ]
            }
            return try answer(url, ["total_count": list.count, "repositories": list])
        default:
            if let repoId = Self.metadataRepoId(from: url.path) {
                if lock.withLock({ refusing }) {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
                }
                if lock.withLock({ discoveryOffline }) { throw URLError(.notConnectedToInternet) }
                guard let repo = lock.withLock({ repositories.first(where: { $0.repoId == repoId }) }) else {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)))
                }
                return try answer(url, [
                    "id": repo.repoId,
                    "name": repo.name,
                    "private": repo.isPrivate,
                    "visibility": repo.isPrivate ? "private" : "public",
                    "default_branch": repo.defaultBranch,
                    "owner": ["login": repo.owner],
                ])
            }
            while lock.withLock({ holding }) { try await Task.sleep(for: .milliseconds(20)) }
            if lock.withLock({ refusing }) { return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))) }
            throw URLError(.notConnectedToInternet)
        }
    }

    private static func metadataRepoId(from path: String) -> Int64? {
        let prefix = "/repositories/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int64(rest)
    }

    private func answer(_ url: URL, _ fields: [String: Any]) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: fields), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

/// A Keychain that can't be read right now, as on a locked device: the token may well be there.
struct LockedTokenStore: TokenStore {
    func load() throws -> TokenPair? { throw TokenStoreError.unavailable }
    func save(_ pair: TokenPair) throws { throw TokenStoreError.unavailable }
    func clear() {}
}

@MainActor
final class Flag {
    var raised = false
}

/// Runs `read` now and after every change to the model state it reads, for what lasts only a turn of the
/// main actor and a look now and then would miss.
@MainActor
func watch(_ read: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking {
        read()
    } onChange: {
        Task { @MainActor in watch(read) }
    }
}

/// What a device keeps across launches: its folder, its defaults, its Keychain. All of it throwaway, and
/// none of it the real thing. `launch` makes a new model over it, as a new launch of the app would.
@MainActor
final class OnboardingEnvironment {
    let folder: URL
    let defaults: UserDefaults
    let tokens: InMemoryTokenStore
    /// What the sessions read: `tokens`, unless the Keychain is locked.
    private let keychain: any TokenStore
    let transport = ScriptedTransport()
    let webSession: InAppWebSession
    private(set) var liveSessionsOpened = 0
    private(set) var demoSessionsOpened = 0
    private let suiteName = "bn-onboarding-test-\(UUID().uuidString)"
    private let fixtures: [(path: String, text: String)]

    init(signedIn: Bool = false, keychainLocked: Bool = false, webSession: InAppWebSession = .inert()) throws {
        self.webSession = webSession
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bn-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        tokens = InMemoryTokenStore(signedIn ? TokenPair(access: "test-access") : nil)
        keychain = keychainLocked ? LockedTokenStore() : tokens
        fixtures = Bundle.main.url(forResource: "demo-brain", withExtension: nil).map(DemoBrain.load) ?? []
        // A device that signed in has launched before: it has its `Brain/` folder and its selected repository,
        // as every install that ever opened a repository has.
        if signedIn {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Brain", isDirectory: true), withIntermediateDirectories: true)
            let sel = try SelectedRepo(
                installationId: 77,
                repoId: 4242,
                owner: "alice",
                name: "private-notes",
                defaultBranch: "main",
                userId: 1,
                userLogin: "alice"
            )
            try SelectedRepoStore(baseFolder: folder).save(sel)
        }
    }

    var sessions: SessionFactory {
        let config = AppConfig(clientId: "test-client", appSlug: "brain-notes-app")
        return SessionFactory(
            baseFolder: { [folder] in folder },
            // As `SessionFactory.standard`: a token that cannot be read right now still counts.
            tokensExist: { [keychain] in
                do { return try keychain.load() != nil } catch { return true }
            },
            account: { [keychain, transport] base in
                BrainAccount(
                    config: config,
                    baseFolder: base,
                    tokens: keychain,
                    transport: transport,
                    deviceFlowSleep: { _ in try await Task.sleep(for: .milliseconds(5)) }
                )
            },
            openVerified: { [self] account, selection in
                liveSessionsOpened += 1
                return try await BrainSession.openVerified(
                    account: account,
                    selection: selection,
                    deviceLabel: "test"
                )
            },
            live: { [self] account, selection in
                liveSessionsOpened += 1
                return try BrainSession.live(
                    account: account,
                    selection: selection,
                    deviceLabel: "test"
                )
            },
            demo: { [self] base in
                demoSessionsOpened += 1
                return try await BrainSession.demo(fixtures: fixtures, baseFolder: base)
            },
            clearTokens: { [keychain] in keychain.clear() },
            installPollInterval: .milliseconds(25),
            usesSystemSideEffects: false)
    }

    func launch(options: LaunchOptions = LaunchOptions(), usesStack: Bool = true) async -> (AppModel, Router) {
        let app = AppModel(options: options, sessions: sessions, defaults: defaults, webSession: webSession)
        let router = Router(usesStack: usesStack)
        await app.start(router: router)
        return (app, router)
    }

    var demoFolder: URL { BrainSession.demoFolder(in: folder) }
    var demoFolderExists: Bool { FileManager.default.fileExists(atPath: demoFolder.path) }
    var onboardedFlag: Bool { defaults.bool(forKey: AppModel.onboardedKey) }

    func cleanUp() {
        transport.release()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The session switching and the first-run rules, without a window. `ScreenWalkTests` has the screens.
@MainActor
final class OnboardingTests: XCTestCase {
    private var env: OnboardingEnvironment!
    private var models: [AppModel] = []

    private func launch(signedIn: Bool = false, options: LaunchOptions = LaunchOptions()) async throws -> AppModel {
        if env == nil { env = try OnboardingEnvironment(signedIn: signedIn) }
        let (app, _) = await env.launch(options: options)
        models.append(app)
        return app
    }

    override func tearDown() async throws {
        for app in models { await app.session?.engine.stop() }
        models = []
        env?.cleanUp()
        env = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: sample notes

    func testSampleSessionIsDemoAndNeverBuildsAGitHubClient() async throws {
        let app = try await launch()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertEqual(env.liveSessionsOpened, 0, "no live repo session opened before sign-in")

        await app.startSampleNotes()

        let session = try XCTUnwrap(app.session)
        XCTAssertTrue(session.isDemo)
        XCTAssertTrue(app.sampleMode)
        XCTAssertEqual(env.liveSessionsOpened, 0, "nothing live was opened for it")
        XCTAssertNil(session.deviceFlow(), "no transport")
        let client = Mirror(reflecting: session.engine).descendant("client")
        XCTAssertTrue(client is FakeGitHub, "its engine talks to the fake")
        XCTAssertFalse(client is GitHubHTTPClient)
        // Syncing and saving reach the fake, and nothing else.
        try session.store.save(path: "todo.md", text: "# Todo\nedited\n")
        await session.engine.sync(.manual)
        XCTAssertEqual(session.store.status(of: "todo.md"), .synced)
        XCTAssertEqual(env.transport.requests, [], "not one request")
    }

    func testALaterLaunchInSampleModeOpensNothingLive() async throws {
        let first = try await launch()
        await first.startSampleNotes()
        await first.session?.engine.stop()

        let second = try await launch()
        XCTAssertEqual(second.phase, .ready)
        XCTAssertTrue(second.sampleMode)
        XCTAssertFalse(second.showsOnboarding, "straight to the notes")
        XCTAssertTrue(second.session?.isDemo == true)
        XCTAssertEqual(env.liveSessionsOpened, 0, "no live session opened")
        XCTAssertEqual(env.transport.requests, [])
    }

    func testTokensWinOverAStraySampleFlag() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        env.defaults.set(true, forKey: AppModel.sampleModeKey)
        let app = try await launch()
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.sampleMode)
        XCTAssertTrue(app.session?.isDemo == false, "a signed-in user gets their notes, whatever else is stored")
        XCTAssertFalse(env.defaults.bool(forKey: AppModel.sampleModeKey), "and it can't come back after a later wipe")
        await app.signOutAndWipe()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertFalse(app.sampleMode)
    }

    func testASecondTapOpensOneSession() async throws {
        let app = try await launch()
        async let first: Void = app.startSampleNotes()
        async let second: Void = app.startSampleNotes()
        _ = await (first, second)
        XCTAssertEqual(env.demoSessionsOpened, 1)
    }

    func testSampleNotesOpenInUnderTwoSeconds() async throws {
        let app = try await launch()
        let clock = ContinuousClock()
        let took = await clock.measure { await app.startSampleNotes() }
        XCTAssertEqual(app.phase, .ready)
        XCTAssertGreaterThan(app.noteCount, 40, "the demo brain is there")
        XCTAssertLessThan(took, .seconds(2))
    }

    func testLeavingRemovesBrainDemoAndEndsInNeedsSignInWithNoTokens() async throws {
        let app = try await launch()
        await app.startSampleNotes()
        XCTAssertFalse(app.showsOnboarding, "the sample notes open directly, no You're all set")
        XCTAssertTrue(env.onboardedFlag)
        XCTAssertTrue(env.demoFolderExists)

        await app.leaveSampleNotes()

        XCTAssertFalse(env.demoFolderExists, "BrainDemo/ is gone")
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(app.showsOnboarding)
        XCTAssertNil(app.session)
        XCTAssertEqual(app.account?.hasTokens, false)
        XCTAssertFalse(app.sampleMode)
        XCTAssertFalse(env.defaults.bool(forKey: AppModel.sampleModeKey), "the next launch does not reopen them")
        XCTAssertEqual(app.noteCount, 0, "no sample note in the live lists")
        XCTAssertEqual(env.transport.requests, [])
    }

    func testLeavingOnlyWorksInSampleMode() async throws {
        let app = try await launch(signedIn: true)
        let session = app.session
        await app.leaveSampleNotes()
        XCTAssertEqual(app.phase, .ready)
        XCTAssertTrue(app.session === session, "the signed-in session is untouched")
    }

    /// A device that lost its Keychain item still has its notes in `Brain/`. Trying the sample notes must
    /// not cost it them.
    func testTheLiveFolderSurvivesTheSampleNotes() async throws {
        let signed = try await launch(signedIn: true)
        let live = try XCTUnwrap(signed.session)
        try live.store.save(path: "mine.md", text: "# Mine\nnot on GitHub yet\n")
        await live.engine.stop()
        env.tokens.clear()

        let app = try await launch()
        XCTAssertEqual(app.phase, .needsSignIn)
        await app.startSampleNotes()
        XCTAssertNil(try app.session?.store.read("mine.md"), "not in the sample notes")
        await app.leaveSampleNotes()

        XCTAssertEqual(try live.store.read("mine.md"), "# Mine\nnot on GitHub yet\n")
    }

    /// The risk the plan names. An event already in the stream when the listener is cancelled still comes
    /// out of it, and it must not reach the model.
    func testAStaleListenerCannotFeedTheNextSession() async throws {
        let app = try await launch()
        await app.startSampleNotes()
        let sample = try XCTUnwrap(app.session)

        // Queued, and not yet read by the listener: nothing has given it a turn on the main actor.
        await sample.engine.setPaused(true)
        await app.leaveSampleNotes()
        await sample.engine.setPaused(false)
        await sample.engine.setPaused(true)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotEqual(app.snapshot.state, .paused(.user))
        XCTAssertFalse(app.session === sample)
        XCTAssertEqual(app.noteCount, 0)
    }

    /// A reload that started on the sample notes and ends after the switch must not fill the live lists.
    /// The live session's own reload can put the lists right again, so the end state alone proves nothing.
    func testAReloadInFlightDoesNotCrossSessions() async throws {
        let app = try await launch()
        await app.startSampleNotes()
        let sample = try XCTUnwrap(app.session)
        XCTAssertGreaterThan(app.noteCount, 40)

        let crossed = Flag()
        watch { [weak app] in
            guard let app else { return }
            if app.noteCount > 0, app.session !== sample { crossed.raised = true }
        }

        // One turn of the main actor takes the reload past its check of the session, to its wait for the
        // index. Called any later, it would find the session gone and never start.
        let reload = Task { await app.reloadLists() }
        await Task.yield()
        await app.leaveSampleNotes()
        await reload.value
        // The watcher's last turn.
        await Task.yield()

        XCTAssertFalse(crossed.raised, "sample notes in the lists after their session had gone")
        XCTAssertEqual(app.noteCount, 0)
    }

    /// `-BNDemoFixtures` promises no network and no Keychain, whatever is tapped.
    func testADemoLaunchLeavingSampleNotesStaysInDemo() async throws {
        let app = try await launch(options: LaunchOptions(arguments: ["-BNScreen", "ready"], environment: [:]))
        XCTAssertTrue(app.sampleMode)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.showsOnboarding, "the older -BNScreen ready opens the sample notes, not a Ready screen")
        await app.leaveSampleNotes()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(app.session?.isDemo == true)
        XCTAssertEqual(env.liveSessionsOpened, 0)
    }

    // MARK: who sees onboarding

    /// The one that matters most: everyone who updates while signed in.
    func testASignedInUserNeverGoesThroughOnboarding() async throws {
        let app = try await launch(signedIn: true)
        XCTAssertFalse(env.onboardedFlag, "this user never saw the new screens")
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.showsOnboarding)
        XCTAssertTrue(app.session?.isDemo == false)
    }

    func testAFreshInstallNeedsSignIn() async throws {
        let app = try await launch()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(app.showsOnboarding)
        XCTAssertFalse(env.onboardedFlag)
        XCTAssertFalse(app.sampleMode)
    }

    func testWipeOfAUserFromBeforeTheseScreensSetsTheFlagForConnect() async throws {
        let app = try await launch(signedIn: true)
        await app.signOutAndWipe()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(env.onboardedFlag)
        XCTAssertNil(app.session)
        XCTAssertEqual(app.account?.hasTokens, false)
        XCTAssertNil(try SelectedRepoStore(baseFolder: env.folder).load())
    }

    /// A wipe that left the notes behind must not end at Connect as if it had worked (audit B3).
    func testAWipeThatCannotDeleteTheNotesSaysSo() async throws {
        let app = try await launch(signedIn: true)
        let session = try XCTUnwrap(app.session)
        let root = session.store.root
        try session.store.save(path: "mine.md", text: "# Mine\n")
        // `Brain/`, which holds this repo's folder: while it can't be written, the folder can't go.
        let brain = root.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: brain.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brain.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: brain.path), "a superuser deletes it anyway")

        await app.signOutAndWipe()
        // The model no longer holds this session, so tearDown can't stop it.
        await session.engine.stop()

        XCTAssertEqual(app.phase, .failed(AppModel.wipeFailedMessage))
        XCTAssertFalse(app.showsOnboarding, "the message shows, not Connect")
        XCTAssertNil(app.session)
        XCTAssertNil(try env.tokens.load(), "signed out all the same")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: sign-in

    /// Approval goes straight to GitHub's access page (no "Connected as" step), and coming back with exactly one
    /// private repository granted opens the notes directly (no "You're all set"), with the first sync behind them.
    func testSigningInGoesStraightToGitHubAndOneGrantedRepoOpensTheNotes() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { if case .waiting = model.step { true } else { false } }
        guard case let .waiting(code) = model.step else { return XCTFail("no code") }
        XCTAssertEqual(code.userCode, "TEST-0001")
        XCTAssertEqual(app.phase, .needsSignIn)

        env.transport.approve()
        await waitUntil("GitHub configure page opened with no confirm step") {
            app.isAwaitingInitialGitHubGrant && self.env.webSession.openedURLs.last?.absoluteString == "https://github.com/settings/installations/77"
        }
        XCTAssertEqual(model.signedInAccount, GitHubAccount(id: 1, login: "alice"), "Signed in as @alice on the code screen")
        XCTAssertEqual(app.phase, .needsSignIn, "never auto-picks before returning from GitHub")
        XCTAssertNil(app.session)
        XCTAssertTrue(app.canReopenGitHubForInitialGrant, "Open GitHub works while waiting")

        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("the notes") { app.phase == .ready }
        XCTAssertFalse(app.showsOnboarding, "straight into the notes, no You're all set")
        XCTAssertEqual(app.session?.repo.slug, "alice/private-notes")
        XCTAssertTrue(env.onboardedFlag, "first run is over once the notes open")
        XCTAssertFalse(app.isAwaitingInitialGitHubGrant)

        // The fake refuses the API, so this first sync can't finish: it shows in the notes, never as a blocking screen.
        await waitUntil("the sync started") { !self.env.transport.apiRequests.filter { $0.contains("/repositories/") }.isEmpty }
        XCTAssertFalse(app.showsOnboarding)
        model.cancel()
    }

    /// Someone whose token stopped working signs in from the plain sheet, inside their notes.
    func testSigningInFromTheSheetStaysInTheNotes() async throws {
        let app = try await launch(signedIn: true)
        app.showSignIn = true
        await app.signedIn(pair: TokenPair(access: "test-access-2"))
        XCTAssertFalse(app.showSignIn)
        XCTAssertFalse(app.showsOnboarding)
    }

    func testARealSignInCannotLandInASampleSession() async throws {
        let app = try await launch()
        await app.startSampleNotes()
        await app.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertNil(try env.tokens.load())
        XCTAssertTrue(app.sampleMode)
    }

    /// "Get a new code" while the old one is still being polled: the old run must not come back and
    /// replace what is on screen, and must stop polling.
    func testANewCodeReplacesTheOldRun() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the first code") { self.env.transport.requests(forCode: "device-1") > 0 }

        // While the new code is on its way, the cancelled run must leave the screen alone.
        env.transport.delayCodes(.milliseconds(200))
        model.begin(app)
        XCTAssertEqual(model.step, .requesting)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.step, .requesting, "the cancelled run came back")

        await waitUntil("the second code") {
            if case let .waiting(code) = model.step { code.userCode == "TEST-0002" } else { false }
        }
        env.transport.expire(deviceCode: "device-1")
        try await Task.sleep(for: .milliseconds(50))
        guard case let .waiting(code) = model.step else { return XCTFail("the old run took the screen: \(model.step)") }
        XCTAssertEqual(code.userCode, "TEST-0002")
        let polls = env.transport.requests(forCode: "device-1")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(env.transport.requests(forCode: "device-1"), polls, "the old code is no longer polled")
        model.cancel()
    }

    func testAnExpiredAndADeclinedCodeSaySo() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.env.transport.requests(forCode: "device-1") > 0 }
        env.transport.expire(deviceCode: "device-1")
        await waitUntil("the expired state") { model.step == .expired }

        model.begin(app)
        await waitUntil("the second code") { self.env.transport.requests(forCode: "device-2") > 0 }
        env.transport.decline(deviceCode: "device-2")
        await waitUntil("the declined state") { model.step == .denied }
        XCTAssertNil(try env.tokens.load())
    }

    func testCancelGoesBackToTheStartAndStopsPolling() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.env.transport.requests(forCode: "device-1") > 0 }
        model.cancel()
        XCTAssertEqual(model.step, .start)
        XCTAssertNil(model.expiresAt)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.step, .start, "the cancelled run leaves it there")
        let polls = env.transport.requests(forCode: "device-1")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(env.transport.requests(forCode: "device-1"), polls)
    }

    func testTheCountdownComesFromExpiresIn() async throws {
        let now = Date()
        let model = SignInModel(step: .start, expiresAt: now.addingTimeInterval(90))
        XCTAssertEqual(model.secondsLeft(at: now), 90)
        XCTAssertEqual(model.secondsLeft(at: now.addingTimeInterval(0.5)), 90, "rounded up")
        XCTAssertEqual(model.secondsLeft(at: now.addingTimeInterval(89.5)), 1)
        XCTAssertEqual(model.secondsLeft(at: now.addingTimeInterval(90)), 0)
        XCTAssertEqual(model.secondsLeft(at: now.addingTimeInterval(1000)), 0)
        XCTAssertEqual(SignInModel().secondsLeft(at: now), 0, "no code, no time")

        let app = try await launch(options: LaunchOptions(arguments: ["-BNScreen", "code"], environment: [:]))
        let demo = SignInModel()
        demo.begin(app)
        guard case .waiting = demo.step else { return XCTFail("no code") }
        XCTAssertEqual(demo.secondsLeft(at: Date()), 900)
    }

    // MARK: launch options and tokens

    func testLaunchOptionsForOnboarding() {
        func options(_ args: String...) -> LaunchOptions { LaunchOptions(arguments: args, environment: [:]) }
        XCTAssertEqual(options("-BNScreen", "welcome").onboardingStep, .welcome)
        XCTAssertEqual(options("-BNScreen", "connect").onboardingStep, .connect)
        XCTAssertEqual(options("-BNScreen", "signin").onboardingStep, .connect, "the older name still works")
        XCTAssertEqual(options("-BNScreen", "code").onboardingStep, .deviceCode)
        XCTAssertEqual(options("-BNScreen", "choose").onboardingStep, .chooseNotes)
        XCTAssertEqual(options("-BNScreen", "picker").onboardingStep, .chooseNotes)
        XCTAssertNil(options("-BNScreen", "ready").onboardingStep, "there is no Ready screen any more")
        XCTAssertTrue(options("-BNScreen", "ready").opensSampleNotes, "the older name opens the sample notes")
        XCTAssertTrue(options("-BNScreen", "ready").demo)
        XCTAssertTrue(options("-BNScreen", "sample").opensSampleNotes)
        XCTAssertFalse(options("-BNScreen", "list").opensSampleNotes)
        XCTAssertNil(options("-BNScreen", "list").onboardingStep)
        XCTAssertNil(options().onboardingStep)
        XCTAssertNil(options("-BNScreen").screen, "no value, no screen")

        XCTAssertTrue(options("-BNScreen", "code").demo, "so that opening the code screen can't start a real device flow")
        XCTAssertTrue(options("-BNScreen", "choose").demo)
        XCTAssertFalse(options("-BNScreen", "list").demo)
        XCTAssertFalse(options().demo)
        XCTAssertTrue(options("-BNDemoFixtures").demo)
        XCTAssertTrue(LaunchOptions(arguments: [], environment: ["BN_DEMO": "1"]).demo)
        XCTAssertTrue(options("-BNScreen", "welcome", "-BNHebrew").hebrew)
        XCTAssertTrue(options("-BNScreen", "welcome", "-BNPhoneLayout").phoneLayout)
    }

    /// A demo launch has settings of its own, so `-BNScreen ready` on a Mac can't mark the real app onboarded.
    func testADemoLaunchLeavesTheRealDefaultsAlone() {
        let demo = AppModel(options: LaunchOptions(arguments: ["-BNDemoFixtures"], environment: [:]))
        XCTAssertFalse(demo.defaults === UserDefaults.standard)
        XCTAssertFalse(demo.defaults.bool(forKey: AppModel.onboardedKey))
        let live = AppModel(options: LaunchOptions())
        XCTAssertTrue(live.defaults === UserDefaults.standard)
    }

    // MARK: a new install finds no sign-in (audit B2)

    func testTheInstallCheckClearsOnlyOnANewInstall() {
        XCTAssertEqual(AppModel.installCheck(launchedBefore: false, localDataExists: false), .clearTokens, "a new install")
        XCTAssertEqual(AppModel.installCheck(launchedBefore: false, localDataExists: true), .keepTokens, "an update from before the check")
        XCTAssertEqual(AppModel.installCheck(launchedBefore: true, localDataExists: false), .nothing)
        XCTAssertEqual(AppModel.installCheck(launchedBefore: true, localDataExists: true), .nothing)
    }

    /// The app was deleted and installed again: the Keychain kept the token, nothing else survived.
    func testAReinstallStartsSignedOut() async throws {
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "left-behind"))
        let app = try await launch()
        XCTAssertNil(try env.tokens.load(), "the old install's token is gone")
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(env.defaults.bool(forKey: AppModel.installedKey))
        XCTAssertEqual(env.transport.requests, [])
    }

    /// The first launch of the version with the check, on a device that already used the app.
    func testAnUpdateKeepsTheSignIn() async throws {
        let app = try await launch(signedIn: true)
        XCTAssertNotNil(try env.tokens.load())
        XCTAssertEqual(app.phase, .ready)
        XCTAssertTrue(env.defaults.bool(forKey: AppModel.installedKey))
    }

    /// The same, for a device whose only trace is a setting.
    func testAnUpdateWithOnlyASettingKeepsTheSignIn() async throws {
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "test-access"))
        env.defaults.set(true, forKey: AppModel.onboardedKey)
        let app = try await launch()
        XCTAssertNotNil(try env.tokens.load())
        XCTAssertEqual(app.phase, .needsRepoSelection, "keeps tokens without auto-picking ungranted repo")
        XCTAssertNil(app.session)
    }

    /// The check is made once. A later launch never clears, whatever the folder holds by then.
    func testALaterLaunchNeverClears() async throws {
        env = try OnboardingEnvironment()
        env.defaults.set(true, forKey: AppModel.installedKey)
        try env.tokens.save(TokenPair(access: "test-access"))
        let app = try await launch()
        XCTAssertNotNil(try env.tokens.load())
        XCTAssertEqual(app.phase, .needsRepoSelection, "keeps tokens without auto-picking ungranted repo")
        XCTAssertNil(app.session)
    }

    /// A demo launch stays away from the Keychain, and leaves the check for a real launch.
    func testADemoLaunchMakesNoInstallCheck() async throws {
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "test-access"))
        _ = try await launch(options: LaunchOptions(arguments: ["-BNDemoFixtures"], environment: [:]))
        XCTAssertNotNil(try env.tokens.load())
        XCTAssertFalse(env.defaults.bool(forKey: AppModel.installedKey))
    }

    func testTheAccentIsTheSlateBlueTokenInBothModes() throws {
        func components(_ appearance: NSAppearance.Name) throws -> [Int] {
            let color = try XCTUnwrap(NSColor(named: "AccentColor"))
            var out: [Int] = []
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                if let c = color.usingColorSpace(.sRGB) {
                    out = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
                }
            }
            return out
        }
        XCTAssertEqual(try components(.aqua), [0x4A, 0x6F, 0xA5])
        XCTAssertEqual(try components(.darkAqua), [0x7A, 0x9C, 0xD3])
    }

    // MARK: multi-user repository discovery, switching, and privacy guard

    func testZeroReposOpensInstallBrowserPollsAndAutoSelectsWhenOnePrivateRepoAppears() async throws {
        env = try OnboardingEnvironment()
        env.transport.setRepositories([])
        let app = try await launch()
        await app.signedIn(pair: TokenPair(access: "test-access"))

        XCTAssertEqual(app.phase, .needsSignIn, "opens GitHub immediately without landing on Choose notes first")
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)
        XCTAssertTrue(app.showsOnboarding)
        XCTAssertTrue(app.isPollingInstallations)
        XCTAssertEqual(env.webSession.openedURLs.last?.absoluteString, "https://github.com/apps/brain-notes-app/installations/new")

        env.transport.setRepositories([
            .init(repoId: 888, owner: "dana", name: "my-brain", defaultBranch: "trunk", isPrivate: true)
        ])
        await waitUntil("polled installation selects the single private repo") { app.phase == .ready }
        XCTAssertFalse(app.isPollingInstallations)
        XCTAssertFalse(app.isAwaitingInitialGitHubGrant)
        XCTAssertGreaterThan(env.webSession.cancelCount, 0, "in-app browser closed automatically")
        XCTAssertEqual(app.session?.repo.slug, "dana/my-brain")
        XCTAssertEqual(app.session?.repo.defaultBranch, "trunk")
    }

    func testMultipleReposShowsPickerAndRefusesPublicRepo() async throws {
        env = try OnboardingEnvironment()
        env.transport.setRepositories([
            .init(repoId: 101, owner: "dana", name: "notes-one", defaultBranch: "main", isPrivate: true),
            .init(repoId: 102, owner: "dana", name: "notes-two", defaultBranch: "main", isPrivate: true),
            .init(repoId: 103, owner: "dana", name: "public-notes", defaultBranch: "main", isPrivate: false),
        ])
        let app = try await launch()
        await app.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertEqual(env.webSession.openedURLs.last?.absoluteString, "https://github.com/settings/installations/77")
        XCTAssertEqual(app.phase, .needsSignIn, "configure page opens before picker")

        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("picker shown after return from GitHub") { app.phase == .needsRepoSelection }
        guard case let .loaded(list) = app.discoveryState else { return XCTFail("expected loaded picker") }
        XCTAssertEqual(list.privateRepositories.count, 2)
        XCTAssertEqual(list.publicRepositories.count, 1)

        await app.selectRepository(try XCTUnwrap(list.publicRepositories.first))
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertEqual(app.discoveryState, .failed(RepoTarget.publicRepoMessage))

        await app.selectRepository(try XCTUnwrap(list.privateRepositories.last))
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.session?.repo.slug, "dana/notes-two")
    }

    func testChangeNotesRepositoryOpensConfigureImmediatelyKeepsLocalCopyOnCancelAndWipesOnlyAfterVerifiedPick() async throws {
        let sheets = FakeSheets()
        env = try OnboardingEnvironment(signedIn: true, webSession: sheets.makeSession())
        let app = try await launch()
        let oldSession = try XCTUnwrap(app.session)
        let oldRoot = oldSession.store.root
        try oldSession.store.save(path: "unsynced.md", text: "# Local draft\n")

        let sawLoading = Flag()
        watch { [weak app] in
            if app?.phase == .loading { sawLoading.raised = true }
        }

        let hasUnsynced = await app.checkUnsyncedBeforeRepoSwitch()
        XCTAssertTrue(hasUnsynced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))

        // 1. Change notes opens configure page immediately; local copy and selection stay intact.
        await app.changeNotesRepository()
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/settings/installations/77")
        XCTAssertEqual(app.phase, .ready, "never flips to .loading or .needsRepoSelection")
        XCTAssertFalse(sawLoading.raised)
        XCTAssertTrue(app.session === oldSession, "current session stays open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path), "local copy is NOT wiped before new pick is verified")
        XCTAssertNotNil(try SelectedRepoStore(baseFolder: env.folder).load(), "stored selection kept until replacement verified")
        XCTAssertNotNil(try env.tokens.load(), "still signed in")

        // 2. Cancelling on GitHub leaves current notes and unsynced draft untouched.
        sheets.sheets.last?.finish(nil)
        await waitUntil("switch cancelled cleanly") { !app.isSwitchingRepositories }
        XCTAssertFalse(app.isPresentingRepoPicker)
        XCTAssertTrue(app.session === oldSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertEqual(try oldSession.store.read("unsynced.md"), "# Local draft\n")

        // 3. Granting multiple repos on GitHub shows picker sheet without wiping; failed verification (public or offline)
        //    still leaves current local notes untouched.
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "alice", name: "second-notes", defaultBranch: "trunk", isPrivate: true),
            .init(repoId: 6161, owner: "alice", name: "public-notes", defaultBranch: "main", isPrivate: false),
        ])
        await app.changeNotesRepository()
        sheets.sheets.last?.finish(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("picker sheet presented") { app.isPresentingRepoPicker }
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path), "still not wiped on picker")
        guard case let .loaded(pickerList) = app.discoveryState else { return XCTFail("expected loaded picker") }

        let publicPick = try XCTUnwrap(pickerList.publicRepositories.first)
        await app.selectRepository(publicPick, fromSettingsSwitch: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path), "public refusal leaves old notes untouched")
        XCTAssertTrue(app.session === oldSession)

        let secondPrivate = try XCTUnwrap(pickerList.privateRepositories.first { $0.repoId == 5151 })
        env.transport.setDiscoveryOffline(true)
        await app.selectRepository(secondPrivate, fromSettingsSwitch: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path), "failed verification leaves old notes untouched")
        XCTAssertTrue(app.session === oldSession)
        XCTAssertEqual(try oldSession.store.read("unsynced.md"), "# Local draft\n")

        // 4. Cancelling the picker sheet also leaves current notes untouched.
        env.transport.setDiscoveryOffline(false)
        app.cancelRepoSwitch()
        XCTAssertFalse(app.isPresentingRepoPicker)
        XCTAssertTrue(app.session === oldSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))

        // 5. Verified new private pick wipes the old folder, opens the new repository directly, and stays out of .loading.
        await app.selectRepository(secondPrivate, fromSettingsSwitch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path), "old repo folder wiped after new pick verified")
        XCTAssertEqual(app.session?.repo.slug, "alice/second-notes")
        XCTAssertEqual(app.session?.repo.defaultBranch, "trunk")
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.showsOnboarding, "a Settings switch goes straight back to the notes")
        XCTAssertFalse(app.isPresentingRepoPicker)
        XCTAssertFalse(sawLoading.raised, "never flipped to .loading during repository switch")
    }

    func testDelistedOrPublicRepoAtLaunchStopsSyncAndShowsPlainRepoIssue() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        env.transport.setRepositories([])
        let delistedApp = try await launch()
        await waitUntil("delisted repo detected at launch") { delistedApp.repoIssue == .notListed(slug: "alice/private-notes") }

        await delistedApp.session?.engine.stop()
        env.cleanUp()

        env = try OnboardingEnvironment(signedIn: true)
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: false)
        ])
        let publicApp = try await launch()
        await waitUntil("public repo refused at launch") { publicApp.repoIssue == .publicRepo(slug: "alice/private-notes") }
        XCTAssertEqual(publicApp.repoIssue?.message, RepoTarget.publicRepoMessage)
    }

    // MARK: security pass 3 (BN-01..BN-12 app rules)

    /// Replaces the BN-01 "always ephemeral" rule: the sheet shares Safari's sign-in by default, and a private window
    /// is what "Use a different account" asks for. The account is confirmed in the app before anything is saved.
    func testInAppWebSessionIsSharedByDefaultAndPrivateOnlyOnRequest() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let web = try String(contentsOf: sources.appendingPathComponent("InAppWebSession.swift"), encoding: .utf8)
        XCTAssertTrue(web.contains("authSession.prefersEphemeralWebBrowserSession = ephemeral"))
        XCTAssertFalse(web.contains("prefersEphemeralWebBrowserSession = true"), "never forced on")
        XCTAssertFalse(web.contains("prefersEphemeralWebBrowserSession = false"), "never forced off either: the caller decides")
        XCTAssertTrue(web.contains("func open(_ url: URL, ephemeral: Bool = false,"), "shared with Safari unless asked otherwise")
        XCTAssertEqual(web.components(separatedBy: "ASWebAuthenticationSession(").count, 2, "one shared sheet builder")
        // Every page the app opens in that sheet takes the mode from one place.
        let model = try String(contentsOf: sources.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        XCTAssertEqual(model.components(separatedBy: "ephemeral: privateBrowser").count, 3, "the access page and the create page")
        let signIn = try String(contentsOf: sources.appendingPathComponent("SignInAndSettings.swift"), encoding: .utf8)
        XCTAssertTrue(signIn.contains("ephemeral: app.privateBrowser"), "and the sign-in page")

        let flow = try String(contentsOf: sources.appendingPathComponent("Onboarding/OnboardingFlow.swift"), encoding: .utf8)
        XCTAssertTrue(flow.contains("Signed in as @"))
        XCTAssertFalse(flow.contains("Not you? Sign out"))
        let settings = try String(contentsOf: sources.appendingPathComponent("SignInAndSettings.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("Signed in as @"))
        XCTAssertFalse(settings.contains("Not you? Sign out"))
    }

    func testSignedInFetchesLoginBeforeOpeningRepoAndNotYouSignsOut() async throws {
        env = try OnboardingEnvironment()
        env.transport.setUserOffline(true)
        let app = try await launch()
        await app.signedIn(pair: TokenPair(access: "test-access"))

        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertNil(app.signedInUser, "login fetch failed, so no user is known")
        XCTAssertNil(app.session, "never auto-selects or opens a repo before @login is known")
        XCTAssertEqual(env.liveSessionsOpened, 0)
        XCTAssertFalse(env.transport.requests.contains { $0.contains("/user/installations") })
        XCTAssertTrue(env.transport.repoRequests.isEmpty)

        let requestsBeforeRefresh = env.transport.requests.count
        env.transport.setUserOffline(false)
        let loginShownOnChooseScreenBeforeSessionOpen = Flag()
        let sessionOpenedBeforeLogin = Flag()
        watch { [weak app] in
            guard let app else { return }
            let user = app.signedInUser
            let hasSession = app.session != nil
            let state = app.discoveryState
            if hasSession, user == nil {
                sessionOpenedBeforeLogin.raised = true
            }
            if !hasSession, user?.login == "alice", case .loaded = state {
                loginShownOnChooseScreenBeforeSessionOpen.raised = true
            }
        }
        await app.refreshDiscovery(autoSelectSinglePrivate: true)
        await Task.yield()

        XCTAssertEqual(app.signedInUser?.login, "alice")
        XCTAssertEqual(app.phase, .ready)
        XCTAssertTrue(loginShownOnChooseScreenBeforeSessionOpen.raised, "@login was exposed on Choose Notes before auto-select")
        XCTAssertFalse(sessionOpenedBeforeLogin.raised)
        let refreshRequests = Array(env.transport.requests.dropFirst(requestsBeforeRefresh))
        let firstRefreshUserIdx = try XCTUnwrap(refreshRequests.firstIndex { $0.hasSuffix("/user") })
        let firstInstallIdx = try XCTUnwrap(refreshRequests.firstIndex { $0.contains("/user/installations") })
        XCTAssertLessThan(firstRefreshUserIdx, firstInstallIdx, "GET /user precedes installation discovery")
        XCTAssertGreaterThanOrEqual(refreshRequests.filter { $0.hasSuffix("/user") }.count, 2, "openVerified also verifies GET /user")

        await app.signOutAndWipe()
        XCTAssertNil(app.signedInUser)
        XCTAssertNil(try env.tokens.load())
        XCTAssertEqual(app.phase, .needsSignIn)
    }

    func testReSignInChecksCandidateUserBeforeSavingOrSyncingAndHidesUnverifiedOwnerNotes() async throws {
        let app = try await launch(signedIn: true)
        await waitUntil("initial owner verified") { app.signedInUser?.login == "alice" }
        await app.session?.engine.stop()

        let repoCallsBefore = env.transport.repoRequests.count

        // 1. Different user signs in: refused before Keychain save or sync.
        env.transport.setUser(id: 2, login: "bob")
        await app.signedIn(pair: TokenPair(access: "bob-candidate-token"))
        XCTAssertEqual(try env.tokens.load()?.access, "test-access", "candidate token for wrong user was never saved")
        XCTAssertEqual(app.reSignInError?.contains("@bob"), true)
        XCTAssertEqual(env.transport.repoRequests.count, repoCallsBefore, "no sync started with mismatched user")

        // 2. Offline /user check on re-sign-in: refused before Keychain save or sync.
        env.transport.setUserOffline(true)
        await app.signedIn(pair: TokenPair(access: "offline-candidate-token"))
        XCTAssertEqual(try env.tokens.load()?.access, "test-access", "candidate token was not saved while /user failed")
        XCTAssertNotNil(app.reSignInError)
        XCTAssertEqual(env.transport.repoRequests.count, repoCallsBefore)

        await app.session?.engine.stop()
        env.cleanUp()

        // 3. Stored selection without userId (legacy file) hides local notes until owner is verified, and refuses re-sign-in without wipe.
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "stale-token"))
        let legacySel = try SelectedRepo(installationId: 77, repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main")
        XCTAssertFalse(legacySel.hasVerifiedOwner)
        try SelectedRepoStore(baseFolder: env.folder).save(legacySel)
        let preRoot = env.folder.appendingPathComponent("Brain/4242", isDirectory: true)
        let preStore = try NoteStore(root: preRoot, deviceLabel: "seed")
        try preStore.save(path: "secret.md", text: "# Secret note\n")
        try preStore.journal.close()
        try preStore.index.close()

        env.transport.refuseToken(true)
        let unverifiedApp = try await launch()
        await waitUntil("unverified owner issue surfaced") {
            unverifiedApp.repoIssue == .unverifiedOwner(slug: "alice/private-notes")
        }
        XCTAssertEqual(unverifiedApp.noteCount, 0, "local notes stay hidden while selection owner is unverified")
        XCTAssertTrue(unverifiedApp.rootNotes.isEmpty)

        env.transport.refuseToken(false)
        await unverifiedApp.signedIn(pair: TokenPair(access: "new-user-token"))
        XCTAssertEqual(try env.tokens.load()?.access, "stale-token", "legacy selection without userId refuses save until wipe")
        XCTAssertNotNil(unverifiedApp.reSignInError)
    }

    func testWipeRemovesWholeBrainAndBrainDemoAndSingleFlightSelectWipesPreviousSession() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "alice", name: "second-notes", defaultBranch: "main", isPrivate: true),
        ])
        let app = try await launch()
        let firstSession = try XCTUnwrap(app.session)
        try firstSession.store.save(path: "first.md", text: "# First\n")

        let fm = FileManager.default
        let brainDir = env.folder.appendingPathComponent("Brain", isDirectory: true)
        let orphanDir = brainDir.appendingPathComponent("9999/files", isDirectory: true)
        try fm.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try Data("# Orphan\n".utf8).write(to: orphanDir.appendingPathComponent("orphan.md"))

        let dirtyLegacyRoot = brainDir.appendingPathComponent("other_legacy", isDirectory: true)
        let dirtyLegacyStore = try NoteStore(root: dirtyLegacyRoot, deviceLabel: "old")
        try dirtyLegacyStore.save(path: "unsynced.md", text: "# Legacy draft\n")
        try dirtyLegacyStore.journal.close()
        try dirtyLegacyStore.index.close()

        let demoFile = env.demoFolder.appendingPathComponent("0/files", isDirectory: true)
        try fm.createDirectory(at: demoFile, withIntermediateDirectories: true)
        try Data("# Demo\n".utf8).write(to: demoFile.appendingPathComponent("demo.md"))

        // Change-repo opens configure page immediately and keeps Brain/4242 intact until a new pick is verified.
        await app.changeNotesRepository()
        XCTAssertTrue(fm.fileExists(atPath: brainDir.appendingPathComponent("4242").path), "local copy preserved before verify")
        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("picker sheet opened") { app.isPresentingRepoPicker }

        // Single-flight selectRepository ignores concurrent second tap while first is in flight, and wipes Brain/4242,
        // orphan Brain/9999, and legacy folders once the new pick (5151) is verified.
        guard case let .loaded(discovered) = app.discoveryState else { return XCTFail("expected loaded discovery") }
        let repoA = try XCTUnwrap(discovered.privateRepositories.first { $0.repoId == 4242 })
        let repoB = try XCTUnwrap(discovered.privateRepositories.first { $0.repoId == 5151 })
        let opensBefore = env.liveSessionsOpened
        // Deterministic order: the first tap is started and observed in flight before the second tap is made.
        // (Two `async let` taps race to the main actor, so "first" was not defined in the old form of this test.)
        let firstTap = Task { @MainActor in await app.selectRepository(repoB, fromSettingsSwitch: true) }
        var spins = 0
        while !app.isSelectingRepository, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(app.isSelectingRepository, "first tap is in flight when the second tap arrives")
        await app.selectRepository(repoA, fromSettingsSwitch: true)
        await firstTap.value
        XCTAssertEqual(env.liveSessionsOpened, opensBefore + 1, "concurrent tap ignored while selectRepository is in flight")
        XCTAssertEqual(app.session?.repo.repoId, 5151)
        XCTAssertFalse(fm.fileExists(atPath: brainDir.appendingPathComponent("4242").path), "previous session wiped once new pick verified")
        XCTAssertFalse(fm.fileExists(atPath: brainDir.appendingPathComponent("9999").path), "orphan numeric repo folder cleared")
        XCTAssertFalse(fm.fileExists(atPath: dirtyLegacyRoot.path), "legacy folder deleted on repo switch")

        // Selecting another repo while one is already open stops and wipes the previous session first.
        try app.session?.store.save(path: "temp.md", text: "# Temp\n")
        await app.selectRepository(repoA, fromSettingsSwitch: true)
        XCTAssertEqual(app.session?.repo.repoId, 4242)
        XCTAssertFalse(fm.fileExists(atPath: brainDir.appendingPathComponent("5151").path), "previous session wiped before opening next")

        // Sign out and wipe deletes the entire Brain/ and BrainDemo/.
        await app.signOutAndWipe()
        XCTAssertFalse(fm.fileExists(atPath: brainDir.path), "whole Brain/ directory deleted")
        XCTAssertFalse(fm.fileExists(atPath: env.demoFolder.path), "BrainDemo/ directory deleted")
        XCTAssertNil(try SelectedRepoStore(baseFolder: env.folder).load())
    }

    func testLiveLaunchDeletesLegacyFoldersWithoutImportingWhileDemoLaunchNeverTouchesBrainAndSymlinksUnlinkSafely() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        let fm = FileManager.default
        let brainDir = env.folder.appendingPathComponent("Brain", isDirectory: true)

        let outsideRoot = fm.temporaryDirectory.appendingPathComponent("bn-app-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: outsideRoot) }
        let outsideChild = outsideRoot.appendingPathComponent("child", isDirectory: true)
        let outsideBrain = outsideRoot.appendingPathComponent("brainTarget", isDirectory: true)
        try fm.createDirectory(at: outsideChild, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideBrain, withIntermediateDirectories: true)
        let outsideChildFile = outsideChild.appendingPathComponent("survives.md")
        let outsideBrainFile = outsideBrain.appendingPathComponent("survives-brain.md")
        try Data("# Outside Child\n".utf8).write(to: outsideChildFile)
        try Data("# Outside Brain\n".utf8).write(to: outsideBrainFile)

        // Matching legacy folder with journal.sqlite holding unsynced create/edit/delete ops and files/.
        let matchingRoot = brainDir.appendingPathComponent("alice_private-notes", isDirectory: true)
        let matchingStore = try NoteStore(root: matchingRoot, deviceLabel: "legacy")
        try matchingStore.save(path: "rescued.md", text: "# Legacy draft\n")
        try matchingStore.save(path: "to-remove.md", text: "# Remove\n")
        try matchingStore.delete(path: "to-remove.md")
        try matchingStore.journal.close()
        try matchingStore.index.close()

        // Non-matching legacy folder with unsynced ops + files/.
        let otherDirtyRoot = brainDir.appendingPathComponent("bob_other", isDirectory: true)
        let otherDirtyStore = try NoteStore(root: otherDirtyRoot, deviceLabel: "legacy")
        try otherDirtyStore.save(path: "keep.md", text: "# Other legacy\n")
        try otherDirtyStore.journal.close()
        try otherDirtyStore.index.close()

        // Symlinked child inside Brain/ pointing at outsideChild.
        let childLink = brainDir.appendingPathComponent("symlink_legacy", isDirectory: false)
        try fm.createSymbolicLink(at: childLink, withDestinationURL: outsideChild)

        // 1. Demo launch NEVER touches Brain/.
        _ = try await launch(options: LaunchOptions(arguments: ["-BNDemoFixtures"], environment: [:]))
        XCTAssertTrue(fm.fileExists(atPath: matchingRoot.path), "demo launch must never touch Brain/")
        XCTAssertTrue(fm.fileExists(atPath: otherDirtyRoot.path), "demo launch must never touch Brain/")
        XCTAssertTrue(LegacyBrainMigration.isSymbolicLink(childLink), "demo launch must never touch symlinks in Brain/")

        // 2. Live launch deletes every legacy folder, unlinks the symlink child without touching outsideChild,
        // marks Brain/ excluded from backup, and imports NOTHING into the new repo store/outbox.
        let app = try await launch()
        await waitUntil("live session verified and started sync") {
            !self.env.transport.repoRequests.isEmpty
        }

        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(matchingRoot), "matching legacy folder deleted on live launch")
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(otherDirtyRoot), "non-matching legacy folder deleted on live launch")
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(childLink), "symlink child unlinked on live launch")
        XCTAssertEqual(try Data(contentsOf: outsideChildFile), Data("# Outside Child\n".utf8), "outside child target survives intact")
        XCTAssertEqual(try URL(fileURLWithPath: brainDir.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        let store = try XCTUnwrap(app.session?.store)
        XCTAssertNil(try store.read("rescued.md"), "nothing from legacy folder appears in store")
        XCTAssertNil(try store.read("keep.md"), "nothing from legacy folder appears in store")
        XCTAssertTrue(store.journal.outbox().isEmpty, "nothing from legacy folder appears in outbox")

        // 3. Symlinked Brain/ itself on live launch is unlinked without enumerating or deleting outsideBrain.
        await app.session?.engine.stop()
        let secondEnv = try OnboardingEnvironment(signedIn: false)
        secondEnv.defaults.set(true, forKey: AppModel.installedKey)
        try secondEnv.tokens.save(TokenPair(access: "token"))
        let secondBrainLink = secondEnv.folder.appendingPathComponent("Brain", isDirectory: false)
        try fm.createSymbolicLink(at: secondBrainLink, withDestinationURL: outsideBrain)
        let (secondApp, _) = await secondEnv.launch()
        await waitUntil("second app finished live launch") {
            secondApp.phase == .needsRepoSelection || secondApp.phase == .ready
        }
        XCTAssertFalse(LegacyBrainMigration.isSymbolicLink(secondBrainLink), "symlinked Brain/ unlinked on live launch")
        XCTAssertEqual(try Data(contentsOf: outsideBrainFile), Data("# Outside Brain\n".utf8), "outside Brain target survives intact")
        await secondApp.session?.engine.stop()
        secondEnv.cleanUp()
    }

    func testAccountAndSessionShareSingleTokenManagerAndBackgroundCancelsInstallPolling() async throws {
        let app = try await launch(signedIn: true)
        let acct = try XCTUnwrap(app.account)
        let liveSession = try XCTUnwrap(app.session)
        XCTAssertTrue(liveSession.tokenManager === acct.manager, "BrainSession.live shares BrainAccount's single TokenManager")

        env.transport.setRepositories([])
        await app.changeNotesRepository()
        XCTAssertTrue(app.isPollingInstallations)
        XCTAssertTrue(app.isInstallSheetActive)

        app.scenePhaseChanged(.background)
        XCTAssertFalse(app.isPollingInstallations, "background cancels install polling immediately")
        XCTAssertFalse(app.isInstallSheetActive)

        env.transport.setRepositories([
            .init(repoId: 7070, owner: "alice", name: "appeared-while-backgrounded", defaultBranch: "main", isPrivate: true)
        ])
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(app.session?.repo.repoId, 4242, "cancelled background poll never switches repositories")

        // Also verify BrainSession.openVerified shares BrainAccount's single TokenManager on fresh selection.
        await app.signOutAndWipe()
        env.transport.setRepositories([
            .init(repoId: 7070, owner: "alice", name: "fresh-notes", defaultBranch: "main", isPrivate: true)
        ])
        await app.signedIn(pair: TokenPair(access: "fresh-access"))
        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("fresh verified session opened") { app.phase == .ready }
        let verifiedSession = try XCTUnwrap(app.session)
        let freshAcct = try XCTUnwrap(app.account)
        XCTAssertTrue(verifiedSession.tokenManager === freshAcct.manager, "BrainSession.openVerified shares BrainAccount's single TokenManager")
    }

    func testRetryCurrentRepositoryRecoversFromNotListedAndDefaultBranchRenameWithoutWipingOrSecondStore() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        env.transport.setRepositories([])
        let app = try await launch()
        await waitUntil("notListed issue shown") { app.repoIssue == .notListed(slug: "alice/private-notes") }
        XCTAssertEqual(app.repoIssue?.allowsRetry, true)
        XCTAssertEqual(env.liveSessionsOpened, 1)
        let originalSession = try XCTUnwrap(app.session)

        try originalSession.store.save(path: "local-draft.md", text: "# Survives branch rename\n")

        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "trunk", isPrivate: true)
        ])
        await app.retryCurrentRepository()

        XCTAssertNil(app.repoIssue)
        XCTAssertTrue(app.session === originalSession, "updated in place via updateVerifiedSelection without opening a second NoteStore")
        XCTAssertEqual(env.liveSessionsOpened, 1, "no second live session opened over the same folder")
        XCTAssertEqual(app.session?.repo.defaultBranch, "trunk")
        XCTAssertEqual(try SelectedRepoStore(baseFolder: env.folder).load()?.defaultBranch, "trunk")
        XCTAssertEqual(try app.session?.store.read("local-draft.md"), "# Survives branch rename\n")

        // Also verify launchRepairAndVerify updates default_branch in place without opening a second store.
        await originalSession.engine.stop()
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "next-branch", isPrivate: true)
        ])
        let opensBeforeRelaunch = env.liveSessionsOpened
        originalSession.store.close()
        let relaunched = try await launch()
        await waitUntil("relaunch updated branch in place") {
            relaunched.session?.repo.defaultBranch == "next-branch"
        }
        XCTAssertEqual(env.liveSessionsOpened, opensBeforeRelaunch + 1, "launchRepairAndVerify updated session in place without opening a second store")
    }

    func testLaunchAndRetryRequireAuthenticatedUserCheckAndCandidateRefreshSavesRotatedPair() async throws {
        // Seed a verified-owner repo store on disk with a local note so we can prove notes stay hidden whenever /user fails or mismatches.
        env = try OnboardingEnvironment(signedIn: true)
        let storeRoot = env.folder.appendingPathComponent("Brain/4242", isDirectory: true)
        let seeded = try NoteStore(root: storeRoot, deviceLabel: "seed")
        try seeded.save(path: "private-thought.md", text: "# Alice secret note\n")
        seeded.close()

        // 1. Launch when /user fails (network offline): do not start sync, do not show notes, show plain retry message.
        env.transport.setUserOffline(true)
        let offlineApp = try await launch()
        await waitUntil("account check retry issue shown") {
            offlineApp.repoIssue == .accountCheckFailed(unauthorized: false)
        }
        XCTAssertEqual(offlineApp.repoIssue?.message, "Can't check your GitHub account right now. Try again.")
        XCTAssertEqual(offlineApp.repoIssue?.allowsRetry, true)
        XCTAssertEqual(offlineApp.noteCount, 0, "notes stay hidden when /user fails")
        XCTAssertTrue(offlineApp.rootNotes.isEmpty)
        XCTAssertTrue(env.transport.repoRequests.isEmpty, "sync does not start when /user fails")

        // 2. retryCurrentRepository() also checks /user every time:
        //    (a) 500 error on /user -> still blocked, notes hidden, sync not started.
        env.transport.setUserOffline(false)
        env.transport.setUserStatus(500)
        await offlineApp.retryCurrentRepository()
        XCTAssertEqual(offlineApp.repoIssue, .accountCheckFailed(unauthorized: false))
        XCTAssertEqual(offlineApp.repoIssue?.message, "Can't check your GitHub account right now. Try again.")
        XCTAssertEqual(offlineApp.noteCount, 0)
        XCTAssertTrue(env.transport.repoRequests.isEmpty)

        //    (b) Mismatched user (@bob, id 2) on retryCurrentRepository() -> same refusal message as sign-in-again, notes hidden, sync stopped.
        env.transport.setUserStatus(nil)
        env.transport.setUser(id: 2, login: "bob")
        await offlineApp.retryCurrentRepository()
        XCTAssertEqual(offlineApp.repoIssue, .accountMismatch(login: "bob"))
        XCTAssertEqual(offlineApp.repoIssue?.message, AppModel.accountMismatchMessage(login: "bob"))
        XCTAssertEqual(offlineApp.noteCount, 0)
        XCTAssertTrue(env.transport.repoRequests.isEmpty)

        //    (c) Launch with mismatched user (@bob, id 2) -> same refusal message as sign-in-again, notes hidden, sync stopped.
        await offlineApp.session?.engine.stop()
        offlineApp.session?.store.close()
        let mismatchLaunchApp = try await launch()
        await waitUntil("mismatch refusal shown at launch") {
            mismatchLaunchApp.repoIssue == .accountMismatch(login: "bob")
        }
        XCTAssertEqual(mismatchLaunchApp.repoIssue?.message, AppModel.accountMismatchMessage(login: "bob"))
        XCTAssertEqual(mismatchLaunchApp.noteCount, 0)
        XCTAssertTrue(env.transport.repoRequests.isEmpty)

        //    (d) Correct user (@alice, id 1) restored -> retryCurrentRepository() verifies /user, reveals notes, starts sync in place.
        env.transport.setUser(id: 1, login: "alice")
        let opensBeforeRetry = env.liveSessionsOpened
        await mismatchLaunchApp.retryCurrentRepository()
        XCTAssertNil(mismatchLaunchApp.repoIssue)
        XCTAssertEqual(mismatchLaunchApp.noteCount, 1, "notes revealed once /user matches selection.userId")
        XCTAssertEqual(env.liveSessionsOpened, opensBeforeRetry, "updated in place without opening second store")
        XCTAssertFalse(env.transport.repoRequests.isEmpty, "sync started after /user matched")

        // 3. Re-sign-in with an expired candidate token that rotates its single-use refresh token during /user check:
        //    AppModel saves the rotated TokenPair, NEVER the spent initial pair.
        let spentCandidate = TokenPair(
            access: "expired-candidate-access",
            refresh: "ghr_single_use_initial",
            accessExpiry: Date().addingTimeInterval(-120)
        )
        await mismatchLaunchApp.signedIn(pair: spentCandidate)
        XCTAssertNil(mismatchLaunchApp.reSignInError)
        let savedPair = try XCTUnwrap(try env.tokens.load())
        XCTAssertEqual(savedPair.access, "rotated-access-1", "saved pair uses rotated access token")
        XCTAssertEqual(savedPair.refresh, "ghr_rotated_1", "saved pair uses rotated single-use refresh token, never the spent one")
    }

    func testTruncatedDiscoveryShowsTruncatedMessageInsteadOfNotListed() async throws {
        env = try OnboardingEnvironment()
        env.transport.setTruncatedDiscovery(true)
        let onboardingApp = try await launch()
        await onboardingApp.signedIn(pair: TokenPair(access: "test-access"))
        onboardingApp.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("truncated picker shown") { onboardingApp.phase == .needsRepoSelection }

        XCTAssertEqual(onboardingApp.phase, .needsRepoSelection, "truncated discovery does not auto-select")
        guard case let .loaded(result) = onboardingApp.discoveryState else {
            return XCTFail("expected loaded truncated discovery")
        }
        XCTAssertTrue(result.isTruncated)

        env.cleanUp()
        env = try OnboardingEnvironment(signedIn: true)
        env.transport.setTruncatedDiscovery(true)
        let launchApp = try await launch()
        await waitUntil("truncated repo issue shown instead of notListed") {
            launchApp.repoIssue == .truncated(slug: "alice/private-notes")
        }
        XCTAssertEqual(launchApp.repoIssue?.message, DiscoveryResult.truncatedMessage)
        XCTAssertEqual(launchApp.repoIssue?.allowsRetry, true)
    }

    func testSetupURLIgnoredOutsideActiveInstallSheetAndPublicRepoAmbiguityDoesNotAutoSelect() async throws {
        env = try OnboardingEnvironment()
        let app = try await launch()
        let setupURL = try XCTUnwrap(URL(string: "brainnotes://setup"))
        let spoofedSetupURL = try XCTUnwrap(URL(string: "brainnotes://setup?installation_id=999999&setup_action=install"))

        // Ignored before sign-in.
        app.handleOpenURL(setupURL)
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(env.transport.requests.isEmpty)

        // Sign in opens initial access sheet; spoofed installation_id query is untrusted and rechecks /user + /user/installations.
        await app.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertTrue(app.isInstallSheetActive)
        let userCallsBeforeReturn = env.transport.requests.filter { $0.hasSuffix("/user") }.count
        app.handleOpenURL(spoofedSetupURL)
        await waitUntil("single private repo auto-connected after recheck") { app.phase == .ready }
        XCTAssertGreaterThan(env.transport.requests.filter { $0.hasSuffix("/user") }.count, userCallsBeforeReturn, "rechecked GET /user")
        XCTAssertEqual(app.session?.selection?.installationId, 77, "never trusted spoofed installation_id=999999")

        // Ignored in .ready when no install sheet is active.
        let reqCountInReady = env.transport.requests.count
        app.handleOpenURL(setupURL)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(env.transport.requests.count, reqCountInReady, "ignored in .ready without active sheet")

        // Switch to manual picker (no active session) and verify setup URL is ignored while sheet is inactive.
        await app.signOutAndWipe()
        try env.tokens.save(TokenPair(access: "test-access"))
        await app.beginRepoSelection(autoSelectSinglePrivate: false)
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertFalse(app.isInstallSheetActive)

        let reqCountBeforeInactiveCallback = env.transport.requests.count
        app.handleOpenURL(setupURL)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(env.transport.requests.count, reqCountBeforeInactiveCallback, "ignored when install sheet is inactive")
        XCTAssertNil(app.session)

        // Accepted when install sheet IS active, while keeping repoSelectionAutoSelect == false.
        app.openGitHubAppInstall()
        XCTAssertTrue(app.isInstallSheetActive)
        app.handleOpenURL(setupURL)
        await waitUntil("install sheet closed on setup callback") { !app.isInstallSheetActive }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(app.phase, .needsRepoSelection, "kept manual picker mode (autoSelectSinglePrivate == false)")
        XCTAssertNil(app.session)

        // Install polling with 1 private + 1 public newly appearing does NOT auto-select.
        env.transport.setRepositories([])
        await app.beginRepoSelection(autoSelectSinglePrivate: true)
        app.openGitHubAppInstall()
        env.transport.setRepositories([
            .init(repoId: 601, owner: "alice", name: "priv", defaultBranch: "main", isPrivate: true),
            .init(repoId: 602, owner: "alice", name: "pub", defaultBranch: "main", isPrivate: false),
        ])
        await waitUntil("ambiguous poll stops") { !app.isPollingInstallations }
        XCTAssertEqual(app.phase, .needsRepoSelection, "1 private + 1 public does not auto-select")
        XCTAssertNil(app.session)

        // Install polling when a public repo is newly added alongside an already-listed private repo does NOT auto-select.
        env.transport.setRepositories([
            .init(repoId: 601, owner: "alice", name: "priv", defaultBranch: "main", isPrivate: true)
        ])
        await app.beginRepoSelection(autoSelectSinglePrivate: false)
        app.openGitHubAppInstall()
        env.transport.setRepositories([
            .init(repoId: 601, owner: "alice", name: "priv", defaultBranch: "main", isPrivate: true),
            .init(repoId: 602, owner: "alice", name: "pub", defaultBranch: "main", isPrivate: false),
        ])
        await waitUntil("public-only addition stops poll") { !app.isPollingInstallations }
        XCTAssertEqual(app.phase, .needsRepoSelection, "newly added public repo does not auto-select existing private repo")
        XCTAssertNil(app.session)
    }

    func testInFlightMultiPageDiscoveryCancelledByBackgroundDoesNotReloadForgottenToken() async throws {
        // 1. Multi-page installPollTask cancelled by backgrounding while page 1 is in flight:
        //    page 1 returns HTTP 200 after backgrounding was initiated, page 2 is never requested,
        //    and forgetCachedTokens() runs only AFTER the cancelled task completes so no token remains in memory.
        env = try OnboardingEnvironment()
        env.defaults.set(true, forKey: AppModel.installedKey)
        try env.tokens.save(TokenPair(access: "test-access", refresh: "ghr_bg_1"))
        let app = try await launch()
        XCTAssertEqual(app.phase, .needsRepoSelection)
        let acct = try XCTUnwrap(app.account)

        env.transport.setTruncatedDiscovery(true)
        env.transport.holdDiscoveryPage1()
        app.openGitHubAppInstall()

        await waitUntil("installPollTask inside page 1") { self.env.transport.isInDiscoveryPage1 }
        let heldDuringPage1 = await acct.manager.holdsPairInMemory
        XCTAssertTrue(heldDuringPage1, "page 1 loaded token into memory")

        let page2Before = env.transport.requests.filter { $0.contains("page=2") }.count
        app.scenePhaseChanged(.background)

        // Wait long enough that an unawaited forgetCachedTokens() task would have already executed before page 1 returns.
        try await Task.sleep(for: .milliseconds(50))
        env.transport.releaseDiscoveryPage1()

        for _ in 0..<200 {
            if !(await acct.manager.holdsPairInMemory) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))
        let page2After = env.transport.requests.filter { $0.contains("page=2") }.count
        XCTAssertEqual(page2After, page2Before, "cancelled multi-page discovery never requests page 2")
        let holdsAfterPollCancel = await acct.manager.holdsPairInMemory
        XCTAssertFalse(holdsAfterPollCancel, "token was not reloaded into memory after being forgotten")
        XCTAssertNotNil(try env.tokens.load(), "token remains in Keychain store")

        // 2. Multi-page openVerifyTask at launch cancelled by backgrounding while page 1 is in flight:
        //    page 2 is never requested and the token is forgotten from memory once openVerifyTask finishes.
        env.cleanUp()
        env = try OnboardingEnvironment(signedIn: true)
        env.transport.setTruncatedDiscovery(true)
        env.transport.holdDiscoveryPage1()

        let launchApp = try await launch()
        let launchAcct = try XCTUnwrap(launchApp.account)
        await waitUntil("openVerifyTask inside page 1") { self.env.transport.isInDiscoveryPage1 }
        let heldAtLaunchPage1 = await launchAcct.manager.holdsPairInMemory
        XCTAssertTrue(heldAtLaunchPage1)

        launchApp.scenePhaseChanged(.background)
        try await Task.sleep(for: .milliseconds(50))
        env.transport.releaseDiscoveryPage1()

        for _ in 0..<200 {
            if !(await launchAcct.manager.holdsPairInMemory) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(env.transport.requests.contains { $0.contains("page=2") }, "cancelled openVerifyTask never requests page 2")
        let holdsAfterVerifyCancel = await launchAcct.manager.holdsPairInMemory
        XCTAssertFalse(holdsAfterVerifyCancel, "token stays evicted from memory in background")
        XCTAssertNotNil(try env.tokens.load(), "token remains in Keychain store")
    }

    func testChangeNotesRepositoryDisablesAutoPickAcrossRetryDiscoveryAndInstallFromFailedOrLoading() async throws {
        // 1. Manual picker mode (repoSelectionAutoSelect == false): nothing auto-picks:
        //    - retryDiscovery() after an offline failure keeps the picker open even with 1 private repo.
        //    - openGitHubAppInstall() from .failed keeps the picker open even when 1 private repo appears.
        env = try OnboardingEnvironment()
        env.defaults.set(true, forKey: AppModel.installedKey)
        try env.tokens.save(TokenPair(access: "test-access"))
        env.transport.setDiscoveryOffline(true)
        let app = try await launch()
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertFalse(app.repoSelectionAutoSelect)
        if case .failed = app.discoveryState {} else {
            XCTFail("expected .failed discovery state while offline")
        }

        // Come back online with 1 private repo and tap "Try again" (retryDiscovery): must NOT auto-pick.
        env.transport.setDiscoveryOffline(false)
        await app.retryDiscovery()
        XCTAssertEqual(app.phase, .needsRepoSelection, "retryDiscovery honors repoSelectionAutoSelect == false")
        XCTAssertNil(app.session, "no session opened automatically")
        guard case let .loaded(loadedAfterRetry) = app.discoveryState else {
            return XCTFail("expected .loaded discovery state")
        }
        XCTAssertEqual(loadedAfterRetry.privateRepositories.map(\.repoId), [4242])

        // Fail discovery again (.failed), open GitHub App install while online, and add a new repo:
        // baseline [4242] is fetched before polling, sheet closes when 5050 appears, and still does NOT auto-pick.
        env.transport.setDiscoveryOffline(true)
        await app.retryDiscovery()
        if case .failed = app.discoveryState {} else {
            XCTFail("expected .failed discovery state")
        }
        env.transport.setDiscoveryOffline(false)
        app.openGitHubAppInstall()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(app.isPollingInstallations, "existing repo 4242 was recorded in baseline and did not close sheet")
        XCTAssertNil(app.session)

        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5050, owner: "alice", name: "second-notes", defaultBranch: "main", isPrivate: true),
        ])
        await waitUntil("install poll detected new repo and closed sheet") { !app.isPollingInstallations }
        XCTAssertEqual(app.phase, .needsRepoSelection, "manual switch never auto-picks")
        XCTAssertNil(app.session)

        // 2. Initial onboarding (repoSelectionAutoSelect == true) when openGitHubAppInstall() is called from .failed
        //    while OFFLINE (so no baseline is known at open): once back online with 1 already-installed private repo,
        //    closes the sheet and disables auto-pick because no baseline was known.
        env.cleanUp()
        env = try OnboardingEnvironment()
        env.transport.setDiscoveryOffline(true)
        let freshApp = try await launch()
        await freshApp.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertEqual(freshApp.phase, .needsRepoSelection)
        XCTAssertTrue(freshApp.repoSelectionAutoSelect)

        freshApp.openGitHubAppInstall()
        try await Task.sleep(for: .milliseconds(35))
        env.transport.setDiscoveryOffline(false)
        await waitUntil("offline-opened install sheet closes once online") { !freshApp.isPollingInstallations }
        XCTAssertEqual(freshApp.phase, .needsRepoSelection, "no auto-pick when baseline was unknown at install-sheet open")
        XCTAssertFalse(freshApp.repoSelectionAutoSelect, "unknown baseline disables auto-pick")
        XCTAssertNil(freshApp.session)

        // 3. Initial onboarding (repoSelectionAutoSelect == true) when openGitHubAppInstall() is called from .failed
        //    while ONLINE with 1 already-installed private repo (4242):
        //    - pre-poll baseline fetch records [4242] and does NOT auto-pick 4242;
        //    - granting 2 private repos ([4242, 8080]) closes the sheet and stays on the picker;
        //    - narrowing the grant on GitHub to a single private repo ([8080]) auto-connects 8080.
        env.cleanUp()
        env = try OnboardingEnvironment()
        env.transport.setDiscoveryOffline(true)
        let onlineOpenApp = try await launch()
        await onlineOpenApp.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertTrue(onlineOpenApp.repoSelectionAutoSelect)

        env.transport.setDiscoveryOffline(false)
        onlineOpenApp.openGitHubAppInstall()
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(onlineOpenApp.phase, .needsRepoSelection, "already-installed 4242 was in fetched baseline, so not auto-picked")
        XCTAssertNil(onlineOpenApp.session)

        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 8080, owner: "alice", name: "newly-added-notes", defaultBranch: "main", isPrivate: true),
        ])
        await waitUntil("multi-repo grant closes sheet and stays on picker") { !onlineOpenApp.isPollingInstallations }
        XCTAssertEqual(onlineOpenApp.phase, .needsRepoSelection, "several private repos granted stays on picker")
        XCTAssertNil(onlineOpenApp.session)

        onlineOpenApp.openGitHubAppInstall()
        try await Task.sleep(for: .milliseconds(50))
        env.transport.setRepositories([
            .init(repoId: 8080, owner: "alice", name: "newly-added-notes", defaultBranch: "main", isPrivate: true)
        ])
        await waitUntil("single granted private repo auto-connected") { onlineOpenApp.phase == .ready }
        XCTAssertEqual(onlineOpenApp.session?.repo.repoId, 8080)
    }

    // MARK: round 3 (RB-01..RB-04)

    func testOfflineLaunchReconnectBlocksRepoAndSyncUntilAccountCheckPasses() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        let storeRoot = env.folder.appendingPathComponent("Brain/4242", isDirectory: true)
        let seeded = try NoteStore(root: storeRoot, deviceLabel: "seed")
        try seeded.save(path: "alice-draft.md", text: "# Alice offline draft\n")
        seeded.close()

        // 1. Offline launch -> GET /user fails -> accountCheckFailed(unauthorized: false), notes hidden, zero repo calls.
        env.transport.setUserOffline(true)
        let app = try await launch()
        await app.setOnline(false)
        await waitUntil("offline launch account check failed") {
            app.repoIssue == .accountCheckFailed(unauthorized: false)
        }
        XCTAssertEqual(app.noteCount, 0)
        XCTAssertTrue(env.transport.repoRequests.isEmpty)
        XCTAssertFalse(env.transport.requests.contains { $0.contains("/user/installations") })

        // 2. Reconnect while holding GET /user in flight: NO installation or repo request and NO sync happen until /user passes.
        env.transport.setUserOffline(false)
        env.transport.holdUser()
        let reconnect = Task { await app.setOnline(true) }
        await waitUntil("reconnect entered GET /user") { self.env.transport.isInUserRequest }
        try await Task.sleep(for: .milliseconds(45))

        XCTAssertTrue(env.transport.repoRequests.isEmpty, "no /repositories request before GET /user passes")
        XCTAssertFalse(env.transport.requests.contains { $0.contains("/user/installations") }, "no installation request before GET /user passes")
        XCTAssertEqual(app.noteCount, 0, "local notes stay hidden until GET /user passes")
        XCTAssertEqual(app.repoIssue, .accountCheckFailed(unauthorized: false))

        // 3. Release GET /user with matching user (id 1 == selection.userId 1): account check passes, notes appear, and sync starts.
        env.transport.releaseUser()
        await reconnect.value
        await waitUntil("sync started after passing reconnect check") {
            !self.env.transport.repoRequests.isEmpty
        }
        XCTAssertNil(app.repoIssue)
        XCTAssertEqual(app.signedInUser, GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(app.noteCount, 1)
        XCTAssertFalse(env.transport.repoRequests.isEmpty)
        await app.session?.engine.stop()
    }

    func testOfflineLaunchReconnectWithDifferentUserIdRefusesAndNeverSyncs() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        let storeRoot = env.folder.appendingPathComponent("Brain/4242", isDirectory: true)
        let seeded = try NoteStore(root: storeRoot, deviceLabel: "seed")
        try seeded.save(path: "alice-draft.md", text: "# Alice secret outbox\n")
        seeded.close()

        // 1. Offline launch -> GET /user fails.
        env.transport.setUserOffline(true)
        let app = try await launch()
        await app.setOnline(false)
        await waitUntil("offline launch account check failed") {
            app.repoIssue == .accountCheckFailed(unauthorized: false)
        }
        XCTAssertTrue(env.transport.repoRequests.isEmpty)

        // 2. Reconnect when token belongs to a different user (id 2, @bob) even on a shared installation containing 4242:
        //    refuses with accountMismatch, keeps notes hidden, and NEVER calls /user/installations or /repositories.
        env.transport.setUser(id: 2, login: "bob")
        env.transport.setUserOffline(false)
        await app.setOnline(true)

        XCTAssertEqual(app.repoIssue, .accountMismatch(login: "bob"))
        XCTAssertEqual(app.repoIssue?.message, AppModel.accountMismatchMessage(login: "bob"))
        XCTAssertEqual(app.noteCount, 0)
        XCTAssertFalse(env.transport.requests.contains { $0.contains("/user/installations") })
        XCTAssertTrue(env.transport.repoRequests.isEmpty, "never syncs on user mismatch")

        // 3. Subsequent offline -> online transitions while .accountMismatch is showing never re-check or sync.
        let reqCountAfterMismatch = env.transport.requests.count
        await app.setOnline(false)
        await app.setOnline(true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(env.transport.requests.count, reqCountAfterMismatch, "no network calls on reconnect while mismatch issue is showing")
        XCTAssertTrue(env.transport.repoRequests.isEmpty)
        XCTAssertEqual(app.repoIssue, .accountMismatch(login: "bob"))
    }

    func testCorruptOrUnreadableSelectionWipesLeftoverNumericFoldersBeforeAnyRepoOpens() async throws {
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "test-access"))
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "org", name: "shared-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "alice", name: "other-notes", defaultBranch: "main", isPrivate: true),
        ])

        let fm = FileManager.default
        let brainDir = env.folder.appendingPathComponent("Brain", isDirectory: true)
        let outsideDir = fm.temporaryDirectory.appendingPathComponent("bn-rb02-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: outsideDir) }
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outsideFile = outsideDir.appendingPathComponent("keep.md")
        let outsideNestedFile = outsideDir.appendingPathComponent("nested-keep.md")
        try Data("# Outside\n".utf8).write(to: outsideFile)
        try Data("# Outside Nested\n".utf8).write(to: outsideNestedFile)

        // 1. Corrupt Brain/selected-repo.json + leftover Brain/4242 (with note + outbox + nested symlink) + symlinked Brain/9999.
        let leftover4242 = brainDir.appendingPathComponent("4242", isDirectory: true)
        let seeded = try NoteStore(root: leftover4242, deviceLabel: "alice")
        try seeded.save(path: "alice-secret.md", text: "# Alice secret\n")
        XCTAssertEqual(seeded.journal.outboxCount(), 1)
        seeded.close()

        try fm.createSymbolicLink(
            at: leftover4242.appendingPathComponent("files/nested-link"),
            withDestinationURL: outsideNestedFile
        )
        let symlinkNumeric = brainDir.appendingPathComponent("9999", isDirectory: false)
        try fm.createSymbolicLink(at: symlinkNumeric, withDestinationURL: outsideDir)

        let selectionURL = brainDir.appendingPathComponent("selected-repo.json", isDirectory: false)
        try Data("{corrupt-json".utf8).write(to: selectionURL)

        let app = try await launch()
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertNil(app.session, "no repo opened yet")
        XCTAssertEqual(env.liveSessionsOpened, 0)
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(leftover4242), "leftover Brain/4242 deleted before any new repo opens")
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(symlinkNumeric), "symlinked numeric entry unlinked")
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(selectionURL), "corrupt selection file removed")
        XCTAssertTrue(fm.fileExists(atPath: outsideFile.path), "outside symlink target untouched")
        XCTAssertTrue(fm.fileExists(atPath: outsideNestedFile.path), "nested symlink target outside Brain untouched")

        // 2. Unreadable Brain/selected-repo.json (directory at selected-repo.json path + chmod 0o000 file) also wipes leftover Brain/4242.
        env.cleanUp()
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "test-access"))
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "org", name: "shared-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "alice", name: "other-notes", defaultBranch: "main", isPrivate: true),
        ])
        let brainDir2 = env.folder.appendingPathComponent("Brain", isDirectory: true)
        let leftover2 = brainDir2.appendingPathComponent("4242", isDirectory: true)
        let seeded2 = try NoteStore(root: leftover2, deviceLabel: "alice")
        try seeded2.save(path: "unreadable-case.md", text: "# Unreadable selection case\n")
        seeded2.close()
        let selectionURL2 = brainDir2.appendingPathComponent("selected-repo.json", isDirectory: false)
        try Data("{\"repoId\":4242}".utf8).write(to: selectionURL2)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: selectionURL2.path)

        let app2 = try await launch()
        XCTAssertEqual(app2.phase, .needsRepoSelection)
        XCTAssertNil(app2.session)
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(leftover2), "leftover Brain/4242 wiped when selected-repo.json is unreadable")
    }

    func testMissingSelectionWipesLeftoverFolderAndReopeningSameSharedRepoIdStartsFreshWhileValidSelectionKeepsFolder() async throws {
        // 1. Missing Brain/selected-repo.json at launch (signed out) + leftover Brain/4242 -> deleted;
        //    signing in as @bob and selecting the same shared repo id (4242) opens a fresh empty store (no old outbox/notes).
        env = try OnboardingEnvironment()
        env.transport.setUser(id: 2, login: "bob")
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "org", name: "shared-notes", defaultBranch: "main", isPrivate: true),
        ])

        let brainDir = env.folder.appendingPathComponent("Brain", isDirectory: true)
        let leftover4242 = brainDir.appendingPathComponent("4242", isDirectory: true)
        let aliceStore = try NoteStore(root: leftover4242, deviceLabel: "alice")
        try aliceStore.save(path: "alice-outbox.md", text: "# Alice private note\n")
        XCTAssertEqual(aliceStore.journal.outboxCount(), 1)
        aliceStore.close()

        let app = try await launch()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertFalse(LegacyBrainMigration.itemExistsNoFollow(leftover4242), "missing selected-repo.json wipes leftover Brain/4242 at live launch")

        // Also verify selectRepository directly when session == nil and no readable stored selection exists,
        // even if a leftover Brain/4242 folder appeared right before selecting shared repo 4242.
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "org", name: "shared-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "org", name: "other-shared", defaultBranch: "main", isPrivate: true),
        ])
        await app.signedIn(pair: TokenPair(access: "bob-token"))
        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("picker shown after GitHub return") { app.phase == .needsRepoSelection }
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertNil(app.session)

        let injected4242 = brainDir.appendingPathComponent("4242", isDirectory: true)
        let injectedStore = try NoteStore(root: injected4242, deviceLabel: "stale")
        try injectedStore.save(path: "stale-outbox.md", text: "# Stale outbox\n")
        XCTAssertEqual(injectedStore.journal.outboxCount(), 1)
        injectedStore.close()

        guard case let .loaded(discovered) = app.discoveryState,
              let sharedRepo = discovered.privateRepositories.first(where: { $0.repoId == 4242 }) else {
            return XCTFail("expected shared repo 4242 in picker")
        }
        await app.selectRepository(sharedRepo)
        XCTAssertEqual(app.phase, .ready)
        let openedSession = try XCTUnwrap(app.session)
        XCTAssertEqual(openedSession.repo.repoId, 4242)
        XCTAssertEqual(openedSession.selection?.userId, 2)
        XCTAssertNil(try openedSession.store.read("alice-outbox.md"), "no old notes in reopened shared repo id")
        XCTAssertNil(try openedSession.store.read("stale-outbox.md"), "selectRepository wiped unbound Brain/4242 before opening")
        XCTAssertEqual(openedSession.store.journal.outboxCount(), 0, "fresh empty outbox")
        XCTAssertEqual(app.noteCount, 0)
        await openedSession.engine.stop()

        // 2. A valid stored selection keeps its Brain/<id> folder across launch (both signed out and signed in).
        env.cleanUp()
        env = try OnboardingEnvironment(signedIn: true)
        let keptRoot = env.folder.appendingPathComponent("Brain/4242", isDirectory: true)
        let keptStore = try NoteStore(root: keptRoot, deviceLabel: "alice")
        try keptStore.save(path: "kept.md", text: "# Kept note\n")
        keptStore.close()

        env.tokens.clear()
        let signedOutApp = try await launch()
        XCTAssertEqual(signedOutApp.phase, .needsSignIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptRoot.path), "valid stored selection keeps Brain/4242 while signed out")

        try env.tokens.save(TokenPair(access: "test-access"))
        let signedInApp = try await launch()
        await waitUntil("valid selection verified and loaded kept note") { signedInApp.noteCount == 1 }
        XCTAssertEqual(try signedInApp.session?.store.read("kept.md"), "# Kept note\n")
        XCTAssertEqual(signedInApp.session?.store.journal.outboxCount(), 1)
        await signedInApp.session?.engine.stop()
    }

    func testUnboundBrainWipeFailureBlocksRepoOpenWithExistingFailureState() async throws {
        env = try OnboardingEnvironment()
        try env.tokens.save(TokenPair(access: "test-access"))
        let fm = FileManager.default
        let brainDir = env.folder.appendingPathComponent("Brain", isDirectory: true)
        let leftover = brainDir.appendingPathComponent("4242", isDirectory: true)
        let seeded = try NoteStore(root: leftover, deviceLabel: "alice")
        try seeded.save(path: "locked.md", text: "# Locked\n")
        seeded.close()

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: brainDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brainDir.path) }
        try XCTSkipIf(fm.isWritableFile(atPath: brainDir.path), "Current user bypasses POSIX 0500 permissions")

        // 1. Live launch fail-safe when wipe cannot be verified: does not open a repo and shows existing failure state.
        let app = try await launch()
        XCTAssertEqual(app.phase, .failed(AppModel.repoSwitchWipeFailedMessage))
        XCTAssertNil(app.session)
        XCTAssertEqual(env.liveSessionsOpened, 0)
        XCTAssertTrue(LegacyBrainMigration.itemExistsNoFollow(leftover))

        // Restore permissions so clean launch enters picker, then lock a re-seeded Brain/ before selectRepository.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brainDir.path)
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "alice", name: "second-notes", defaultBranch: "main", isPrivate: true),
        ])
        let pickerApp = try await launch()
        XCTAssertEqual(pickerApp.phase, .needsRepoSelection)

        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("# Leftover\n".utf8).write(to: leftover.appendingPathComponent("note.md"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: brainDir.path)

        guard case let .loaded(list) = pickerApp.discoveryState,
              let repo = list.privateRepositories.first else {
            return XCTFail("expected loaded picker")
        }
        await pickerApp.selectRepository(repo)
        XCTAssertEqual(pickerApp.discoveryState, .failed(AppModel.repoSwitchWipeFailedMessage))
        XCTAssertNil(pickerApp.session)
        XCTAssertEqual(env.liveSessionsOpened, 0)
    }

    func testBackgroundDuringColdLaunchIndexRebuildCancelsPromptlyEvictsTokensAndHealsOnForeground() async throws {
        env = try OnboardingEnvironment(signedIn: true)
        let repoFolder = env.folder
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("4242", isDirectory: true)
        let seeded = try NoteStore(root: repoFolder, deviceLabel: "mac")
        for i in 0..<220 {
            try seeded.save(path: String(format: "cold-%03d.md", i), text: "# Cold \(i)\ncoldtoken\(i)\n")
        }
        try seeded.index.clear()
        try seeded.index.setStamp("stale")
        seeded.close()

        env.transport.holdUser()
        let app = try await launch()
        let acct = try XCTUnwrap(app.account)
        _ = try? await acct.manager.accessToken()
        let heldBeforeBg = await acct.manager.holdsPairInMemory
        XCTAssertTrue(heldBeforeBg)

        // Background immediately during cold launch repair/verify.
        app.scenePhaseChanged(.background)
        try await Task.sleep(for: .milliseconds(40))
        env.transport.releaseUser()

        for _ in 0..<200 {
            if !(await acct.manager.holdsPairInMemory) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let heldInBg = await acct.manager.holdsPairInMemory
        XCTAssertFalse(heldInBg, "cached tokens evicted promptly after cancelling cold-launch repair/verify")
        XCTAssertTrue(app.isAwaitingOwnerVerificationAtLaunch)
        XCTAssertEqual(app.noteCount, 0)

        // Returning to foreground resumes launchRepairAndVerify, heals all 220 notes in the index, and verifies /user.
        app.scenePhaseChanged(.active)
        await waitUntil("cold launch index rebuilt and /user verified on foreground") {
            !app.isAwaitingOwnerVerificationAtLaunch && app.noteCount == 220
        }
        let session = try XCTUnwrap(app.session)
        XCTAssertEqual(session.store.index.count(), 220)
        XCTAssertEqual(session.store.index.stamp(), session.store.journal.baseCommit)
    }

    func testInstallSheetPollingRequiresAuthenticatedUserBeforeLoadedAndReSignInAvoidsDuplicateVerify() async throws {
        // 1. Open Choose Notes while /user is failing (500): discoveryState is .failed and signedInUser == nil.
        //    Opening openGitHubAppInstall() while /user continues to fail MUST NOT transition discoveryState to .loaded
        //    even though /user/installations would succeed; once /user succeeds, polling populates signedInUser first and loads.
        env = try OnboardingEnvironment()
        env.defaults.set(true, forKey: AppModel.installedKey)
        try env.tokens.save(TokenPair(access: "test-access"))
        env.transport.setUserStatus(500)
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "alice", name: "second-notes", defaultBranch: "main", isPrivate: true),
        ])

        let app = try await launch()
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertNil(app.signedInUser)
        if case .failed = app.discoveryState {} else {
            XCTFail("expected .failed discoveryState when /user returns 500")
        }

        let requestsBeforeInstall = env.transport.requests.count
        app.openGitHubAppInstall()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(app.signedInUser)
        if case .loaded = app.discoveryState {
            XCTFail("openGitHubAppInstall must never show .loaded picker while authenticatedUser() fails")
        }
        let failedSlice = Array(env.transport.requests.dropFirst(requestsBeforeInstall))
        XCTAssertTrue(failedSlice.contains { $0.hasSuffix("/user") })
        XCTAssertFalse(failedSlice.contains { $0.contains("/user/installations") }, "installations never queried before /user succeeds")

        // Restore /user -> next poll fetches /user first, sets signedInUser, then loads repositories.
        env.transport.setUserStatus(nil)
        await waitUntil("install poll loads repositories after /user succeeds") {
            if case .loaded = app.discoveryState { return true }
            return false
        }
        XCTAssertEqual(app.signedInUser?.login, "alice")

        // 2. Re-sign-in on an open session runs one installationCheck + sync without spawning a second launchRepairAndVerify.
        env.cleanUp()
        env = try OnboardingEnvironment(signedIn: true)
        let liveApp = try await launch()
        await waitUntil("initial launch verified") { !liveApp.isAwaitingOwnerVerificationAtLaunch }
        try await Task.sleep(for: .milliseconds(30))

        let beforeReSignIn = env.transport.requests.count
        await liveApp.signedIn(pair: TokenPair(access: "reauth-access"))
        try await Task.sleep(for: .milliseconds(50))

        let reSignInRequests = Array(env.transport.requests.dropFirst(beforeReSignIn))
        let installChecks = reSignInRequests.filter { $0.contains("/user/installations?") }.count
        XCTAssertEqual(installChecks, 1, "re-sign-in runs installationCheck once without duplicate launchRepairAndVerify")
    }

    // MARK: build 6: grant-first repo flow, All repositories, and lag fixes

    func testRepoSelectionNeverAutoPicksWithoutUserGrantAndAllRepositoriesGrantStaysOnPicker() async throws {
        // 1. Cold launch with tokens + 1 already-installed private repo and no stored selection NEVER auto-picks.
        let sheets = FakeSheets()
        env = try OnboardingEnvironment(webSession: sheets.makeSession())
        env.defaults.set(true, forKey: AppModel.installedKey)
        try env.tokens.save(TokenPair(access: "test-access"))
        let coldApp = try await launch()
        XCTAssertEqual(coldApp.phase, .needsRepoSelection, "never auto-picks without a user grant")
        XCTAssertNil(coldApp.session)
        XCTAssertEqual(env.liveSessionsOpened, 0)

        // 2. First-time sign-in with an existing org installation opens organizations/<org>/settings/installations/77
        //    immediately without auto-picking before returning from GitHub.
        await coldApp.signOutAndWipe()
        env.transport.setInstallationAccountType("Organization")
        env.transport.setInstallationAccountLogin("acme-org")
        env.transport.setRepositories([
            .init(repoId: 4242, owner: "acme-org", name: "team-brain", defaultBranch: "main", isPrivate: true)
        ])
        await coldApp.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/organizations/acme-org/settings/installations/77")
        XCTAssertEqual(coldApp.phase, .needsSignIn, "does not show Choose notes or auto-pick before GitHub returns")
        XCTAssertNil(coldApp.session)

        // 3. If the installation grants "All repositories" (repository_selection == "all"), even with 1 private repo,
        //    returning from GitHub does NOT auto-connect and stays on the in-app picker.
        env.transport.setAllRepositoriesSelection(true)
        sheets.sheets.last?.finish(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("picker shown for All repositories grant") { coldApp.phase == .needsRepoSelection }
        XCTAssertNil(coldApp.session, "All repositories grant must not auto-connect")
        guard case let .loaded(allReposResult) = coldApp.discoveryState else {
            return XCTFail("expected loaded discovery")
        }
        XCTAssertTrue(allReposResult.hasAllRepositoriesGrant)
        XCTAssertNil(AppModel.singleAutoConnectableRepo(in: allReposResult))

        // 4. Once narrowed to a single selected private repository ("selected"), returning from GitHub auto-connects.
        env.transport.setAllRepositoriesSelection(false)
        coldApp.openGitHubAppInstall()
        sheets.sheets.last?.finish(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitUntil("single selected private repo auto-connected") { coldApp.phase == .ready }
        XCTAssertEqual(coldApp.session?.repo.slug, "acme-org/team-brain")
        XCTAssertFalse(coldApp.showsOnboarding, "first-time onboarding goes straight to the notes")
    }

    func testLagFixesKeepCodeScreenDuringRequestAndAccountCheckAndNeverShowBlankLoadingOnRepoSwitch() async throws {
        env = try OnboardingEnvironment()
        env.transport.delayCodes(.milliseconds(80))
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        XCTAssertEqual(model.step, .requesting)
        XCTAssertNil(model.displayedCode, "code card stays on code screen with inline progress while requesting")

        await waitUntil("code arrived") {
            if case .waiting = model.step { return true }
            return false
        }
        XCTAssertEqual(model.displayedCode?.userCode, "TEST-0001")

        // Hold GET /user so model stays in .checking after approval: displayedCode stays populated for the code screen.
        env.transport.holdUser()
        env.transport.approve()
        await waitUntil("checking account on code screen") { model.step == .checking }
        XCTAssertEqual(model.displayedCode?.userCode, "TEST-0001", "code remains visible during account check")
        env.transport.releaseUser()
        await waitUntil("signed in") {
            if case .signedIn = model.step { return true }
            return false
        }
        XCTAssertEqual(model.signedInAccount, GitHubAccount(id: 1, login: "alice"))
        model.cancel()
    }
}

// MARK: - The in-app browser

/// Records every sheet the web session is asked for, and lets a test deliver a sheet's completion whenever it likes,
/// as the system does: asynchronously, and for a replaced sheet after the new one is up.
@MainActor
final class FakeSheets {
    struct Sheet {
        let url: URL
        let ephemeral: Bool
        let finish: @MainActor (URL?) -> Void
    }

    private(set) var sheets: [Sheet] = []
    private(set) var stopped: [Int] = []

    func makeSession() -> InAppWebSession {
        InAppWebSession { [unowned self] url, ephemeral, finish in
            let index = self.sheets.count
            self.sheets.append(Sheet(url: url, ephemeral: ephemeral, finish: finish))
            return { [unowned self] in self.stopped.append(index) }
        }
    }
}

@MainActor
final class InAppWebSessionTests: XCTestCase {
    private let first = URL(string: "https://github.com/login/device")!
    private let second = URL(string: "https://github.com/apps/brain-notes-app/installations/new")!

    /// Reopening cancels the old sheet, and the old sheet's completion arrives after the new one is up. It used to
    /// clear the new sheet's handle: `cancel()` then did nothing and the window never closed on approval.
    func testAStaleCompletionDoesNotClearTheNewSession() {
        let sheets = FakeSheets()
        let session = sheets.makeSession()
        var finished: [String] = []
        session.open(first) { _ in finished.append("first") }
        session.open(second) { _ in finished.append("second") }
        XCTAssertEqual(sheets.stopped, [0], "the old sheet was stopped by the reopen")
        XCTAssertTrue(session.isPresenting)

        // The old sheet's completion, late.
        sheets.sheets[0].finish(nil)
        XCTAssertTrue(session.isPresenting, "the new sheet is still up")
        XCTAssertEqual(finished, [], "nobody hears about a sheet that was replaced")

        session.cancel()
        XCTAssertEqual(sheets.stopped, [0, 1], "cancel() closes the CURRENT sheet")
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(session.cancelCount, 2)
    }

    func testTheCurrentSheetsOwnCompletionClearsStateAndIsHeard() {
        let sheets = FakeSheets()
        let session = sheets.makeSession()
        var finished: [URL?] = []
        session.open(first) { finished.append($0) }
        sheets.sheets[0].finish(nil)
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(finished.count, 1)
        session.cancel()
        XCTAssertEqual(sheets.stopped, [], "nothing left to close")
    }

    func testACancelledSheetsLateCompletionIsIgnored() {
        let sheets = FakeSheets()
        let session = sheets.makeSession()
        var finished = 0
        session.open(first) { _ in finished += 1 }
        session.cancel()
        sheets.sheets[0].finish(nil)
        XCTAssertEqual(finished, 0, "the caller closed it, and does not hear about it again")
        // A sheet opened after the cancel is not touched by the old completion either.
        var secondFinished = 0
        session.open(second) { _ in secondFinished += 1 }
        sheets.sheets[0].finish(nil)
        XCTAssertTrue(session.isPresenting)
        sheets.sheets[1].finish(nil)
        XCTAssertEqual(secondFinished, 1)
        XCTAssertFalse(session.isPresenting)
    }

    func testTheBrowserIsSharedUnlessAPrivateWindowIsAskedFor() {
        let sheets = FakeSheets()
        let session = sheets.makeSession()
        session.open(first)
        session.open(second, ephemeral: true)
        session.open(first, ephemeral: false)
        XCTAssertEqual(session.openedEphemeral, [false, true, false])
        XCTAssertEqual(sheets.sheets.map(\.ephemeral), [false, true, false])
        XCTAssertEqual(session.openedURLs, [first, second, first])
    }

    /// Regression for Mac `ASWebAuthenticationSession` crash (`EXC_BREAKPOINT` / `swift_task_checkIsolatedSwift` on
    /// `com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent`): invoking the live completion off the main queue
    /// must not trap and must hop `onFinish` onto `@MainActor`, while preserving cancel-during-approval protection.
    func testCompletionInvokedOffMainQueueDoesNotTrapAndRunsOnMainActor() async throws {
        let xpcQueue = DispatchQueue(label: "com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent")
        let callbackURL = try XCTUnwrap(URL(string: "brainnotes://setup?installation_id=77"))

        // 1. Direct nonisolated completion helper invoked on background XPC queue hops cleanly to @MainActor.
        let directDelivered = expectation(description: "direct makeCompletion hopped to MainActor")
        var directReceived: URL?
        let rawCompletion = InAppWebSession.makeCompletion { url in
            MainActor.assertIsolated()
            XCTAssertTrue(Thread.isMainThread)
            directReceived = url
            directDelivered.fulfill()
        }
        xpcQueue.async {
            XCTAssertFalse(Thread.isMainThread)
            rawCompletion(callbackURL, nil)
        }
        await fulfillment(of: [directDelivered], timeout: 5)
        XCTAssertEqual(directReceived, callbackURL)

        // 2. Full InAppWebSession presenter firing makeCompletion from background XPC queue, including cancel-during-approval.
        final class OffMainSheetDriver: @unchecked Sendable {
            private let lock = NSLock()
            private var handlers: [@Sendable (URL?, (any Error)?) -> Void] = []
            func record(_ h: @escaping @Sendable (URL?, (any Error)?) -> Void) {
                lock.withLock { handlers.append(h) }
            }
            func handler(at index: Int) -> (@Sendable (URL?, (any Error)?) -> Void) {
                lock.withLock { handlers[index] }
            }
        }

        let driver = OffMainSheetDriver()
        let session = InAppWebSession { _, _, onFinish in
            driver.record(InAppWebSession.makeCompletion(onFinish: onFinish))
            return {}
        }

        // First sheet is cancelled before its off-main-queue XPC completion arrives; late callback must be ignored.
        var cancelledHeard = 0
        session.open(first) { _ in
            MainActor.assertIsolated()
            cancelledHeard += 1
        }
        session.cancel()
        let cancelledSettled = expectation(description: "cancelled off-main callback settled")
        xpcQueue.async {
            driver.handler(at: 0)(nil, nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
                cancelledSettled.fulfill()
            }
        }
        await fulfillment(of: [cancelledSettled], timeout: 5)
        XCTAssertEqual(cancelledHeard, 0)
        XCTAssertFalse(session.isPresenting)

        // Second sheet completes off the main queue and delivers on MainActor.
        let activeDelivered = expectation(description: "active off-main callback delivered on MainActor")
        var activeURL: URL?
        session.open(second) { url in
            MainActor.assertIsolated()
            XCTAssertTrue(Thread.isMainThread)
            activeURL = url
            activeDelivered.fulfill()
        }
        xpcQueue.async {
            XCTAssertFalse(Thread.isMainThread)
            driver.handler(at: 1)(callbackURL, nil)
        }
        await fulfillment(of: [activeDelivered], timeout: 5)
        XCTAssertEqual(activeURL, callbackURL)
        XCTAssertFalse(session.isPresenting)
    }
}

// MARK: - Polling one device code

/// A clock tests move by hand. `sleep` waits for `fire()` (and ends if its task is cancelled); `now` moves only with
/// `advance`, so a test can have time pass with no timer firing, as when the app was suspended.
final class FakePollClock: @unchecked Sendable {
    private let lock = NSLock()
    /// Starts at the real time: a code that expires "in 15 minutes" is measured against it.
    private var date = Date()
    private var ticks = 0
    private var sleeps: [Double] = []

    var now: Date { lock.withLock { date } }
    var requestedSleeps: [Double] { lock.withLock { sleeps } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func fire() { lock.withLock { ticks += 1 } }

    func sleep(_ duration: Duration) async throws {
        let start: Int = lock.withLock {
            sleeps.append(Double(duration.components.seconds))
            return ticks
        }
        while lock.withLock({ ticks }) == start {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    var clock: DevicePoller.Clock {
        DevicePoller.Clock(now: { self.now }, sleep: { try await self.sleep($0) })
    }
}

@MainActor
final class DevicePollerTests: XCTestCase {
    private let code = DeviceCode(deviceCode: "d", userCode: "WDJB-MJHT", verificationURI: URL(string: "https://github.com/login/device")!,
                                  interval: 5, expiresIn: 900)

    private final class Script {
        var outcomes: [PollOutcome]
        var intervals: [Int] = []
        var delivered: [PollOutcome] = []
        init(_ outcomes: [PollOutcome]) { self.outcomes = outcomes }
        func next(_ interval: Int) -> PollOutcome {
            intervals.append(interval)
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
    }

    private func make(_ script: Script, _ clock: FakePollClock, expiresIn: TimeInterval = 900) -> DevicePoller {
        DevicePoller(code: code, expiresAt: clock.now.addingTimeInterval(expiresIn),
                     poll: { _, interval in script.next(interval) }, clock: clock.clock) { script.delivered.append($0) }
    }

    private func until(_ what: String, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(3))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

    func testTheFirstRequestWaitsOneIntervalAndEveryNextOneToo() async {
        let clock = FakePollClock(), script = Script([.pending])
        let poller = make(script, clock)
        poller.start()
        await until("the first wait") { clock.requestedSleeps == [5] }
        XCTAssertEqual(poller.requestCount, 0)
        clock.fire()
        await until("the first request") { poller.requestCount == 1 }
        await until("the second wait") { clock.requestedSleeps == [5, 5] }
        XCTAssertEqual(script.delivered, [.pending])
        poller.stop()
    }

    func testSlowDownRaisesTheIntervalForEveryLaterRequest() async {
        let clock = FakePollClock(), script = Script([.slowDown(newInterval: 10), .pending])
        let poller = make(script, clock)
        poller.start()
        await until("wait 1") { clock.requestedSleeps.count == 1 }
        clock.fire()
        await until("wait 2") { clock.requestedSleeps.count == 2 }
        XCTAssertEqual(clock.requestedSleeps, [5, 10], "the next request waits the longer interval")
        XCTAssertEqual(poller.interval, 10)
        clock.fire()
        await until("request 2") { poller.requestCount == 2 }
        XCTAssertEqual(script.intervals, [5, 10], "and is made with it")
        poller.stop()
    }

    /// Coming to the front must never ask sooner than GitHub's interval since the last request.
    func testWakingBeforeTheIntervalIsOverAsksNothing() async {
        let clock = FakePollClock(), script = Script([.pending])
        let poller = make(script, clock)
        poller.start()
        await until("the wait") { clock.requestedSleeps.count == 1 }
        clock.advance(2)
        poller.wake()
        await settle()
        XCTAssertEqual(poller.requestCount, 0, "3 of 5 seconds still to go")
        poller.stop()
    }

    func testWakingAfterTheIntervalAsksAtOnceButNotTwice() async {
        let clock = FakePollClock(), script = Script([.pending])
        let poller = make(script, clock)
        poller.start()
        await until("the wait") { clock.requestedSleeps.count == 1 }
        // Time passed while the app was suspended, and the timer has not fired.
        clock.advance(6)
        poller.wake()
        await until("the request on waking") { poller.requestCount == 1 }
        await until("the next wait") { clock.requestedSleeps.count == 2 }
        poller.wake()
        poller.wake()
        await settle()
        XCTAssertEqual(poller.requestCount, 1, "just asked: the next one waits the full interval")
        XCTAssertEqual(clock.requestedSleeps.last, 5)
        poller.stop()
    }

    func testFailuresAreReportedAndRetriedUntilAnApproval() async {
        let clock = FakePollClock()
        let pair = TokenPair(access: "ghu_test")
        let script = Script([.transientFailure, .transientFailure, .approved(pair)])
        let poller = make(script, clock)
        poller.start()
        for n in 1...3 {
            await until("wait \(n)") { clock.requestedSleeps.count == n }
            clock.fire()
            await until("request \(n)") { poller.requestCount == n }
        }
        XCTAssertEqual(script.delivered, [.transientFailure, .transientFailure, .approved(pair)])
        XCTAssertTrue(poller.isFinished)
        await settle()
        XCTAssertEqual(clock.requestedSleeps.count, 3, "an approval ends the polling")
    }

    func testAVerdictEndsThePolling() async {
        for verdict in [PollOutcome.expired, .denied, .fatal("incorrect_device_code")] {
            let clock = FakePollClock(), script = Script([verdict])
            let poller = make(script, clock)
            poller.start()
            await until("wait") { clock.requestedSleeps.count == 1 }
            clock.fire()
            await until("verdict") { script.delivered == [verdict] }
            XCTAssertTrue(poller.isFinished)
            await settle()
            XCTAssertEqual(clock.requestedSleeps.count, 1, "\(verdict)")
        }
    }

    /// The last request after the code's end finds out whether an approval beat the clock.
    func testAfterTheCodesEndOneLastRequestDecides() async {
        let clock = FakePollClock()
        let nothing = Script([.pending])
        let expiring = make(nothing, clock, expiresIn: 3)
        expiring.start()
        await until("wait") { clock.requestedSleeps.count == 1 }
        clock.advance(6)
        clock.fire()
        await until("the closing request") { nothing.delivered == [.expired] }
        XCTAssertTrue(expiring.isFinished)

        let pair = TokenPair(access: "ghu_just_in_time")
        let clock2 = FakePollClock(), beat = Script([.approved(pair)])
        let racing = make(beat, clock2, expiresIn: 3)
        racing.start()
        await until("wait 2") { clock2.requestedSleeps.count == 1 }
        clock2.advance(6)
        clock2.fire()
        await until("approval") { beat.delivered == [.approved(pair)] }
    }

    func testStoppingEndsTheLoop() async {
        let clock = FakePollClock(), script = Script([.pending])
        let poller = make(script, clock)
        poller.start()
        await until("wait") { clock.requestedSleeps.count == 1 }
        poller.stop()
        clock.fire()
        await settle()
        XCTAssertEqual(poller.requestCount, 0)
        XCTAssertEqual(script.delivered, [])
    }
}

// MARK: - The sign-in, from code to Continue

@MainActor
final class SignInFlowTests: XCTestCase {
    private var env: OnboardingEnvironment!
    private var models: [AppModel] = []
    private let sheets = FakeSheets()

    private func launch(signedIn: Bool = false, repositories: [ScriptedTransport.RepoFixture]? = nil,
                        tokensCleared: Bool = false, options: LaunchOptions = LaunchOptions()) async throws -> AppModel {
        if env == nil { env = try OnboardingEnvironment(signedIn: signedIn, webSession: sheets.makeSession()) }
        if let repositories { env.transport.setRepositories(repositories) }
        if tokensCleared { env.tokens.clear() }
        let (app, _) = await env.launch(options: options)
        models.append(app)
        return app
    }

    override func tearDown() async throws {
        for app in models { await app.session?.engine.stop() }
        models = []
        env?.cleanUp()
        env = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func isWaiting(_ model: SignInModel) -> Bool {
        if case .waiting = model.step { return true }
        return false
    }

    private func isSignedIn(_ model: SignInModel) -> Bool {
        if case .signedIn = model.step { return true }
        return false
    }

    // MARK: the code screen

    func testTheCodeIsShownFirstAndTheBrowserOpensOnlyOnTheButton() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        XCTAssertEqual(sheets.sheets.count, 0, "nothing opens over the code before the person has seen it")

        model.copyAndOpenGitHub(app)
        model.copyAndOpenGitHub(app)
        XCTAssertEqual(sheets.sheets.count, 2, "every press opens it")
        XCTAssertEqual(sheets.sheets.map(\.url.absoluteString),
                       Array(repeating: "https://github.com/login/device?user_code=TEST-0001", count: 2))
        XCTAssertEqual(sheets.sheets.map(\.ephemeral), [false, false], "shared with Safari by default")
        XCTAssertEqual(sheets.stopped, [0], "a second press replaces the first sheet")
        model.cancel()
    }

    /// The user closes the browser, or it is closed under them: the code is still good, and polling goes on.
    func testPollingContinuesWhenTheBrowserIsClosedByTheUser() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        model.copyAndOpenGitHub(app)
        await waitUntil("polling") { self.env.transport.requests(forCode: "device-1") > 0 }

        sheets.sheets[0].finish(nil)
        let before = env.transport.requests(forCode: "device-1")
        await waitUntil("more polling after the browser closed") { self.env.transport.requests(forCode: "device-1") > before }
        XCTAssertTrue(isWaiting(model))

        env.transport.approve()
        await waitUntil("the account") { self.isSignedIn(model) }
        model.cancel()
    }

    /// Whatever polling reports for an older code, nothing changes for the code on screen.
    func testResultsForAnOldCodeAreIgnored() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("code 1") { self.isWaiting(model) }
        let old = model.generation
        model.begin(app)
        await waitUntil("code 2") {
            if case let .waiting(code) = model.step { code.userCode == "TEST-0002" } else { false }
        }
        XCTAssertGreaterThan(model.generation, old)
        guard case let .waiting(current) = model.step else { return XCTFail("no code") }

        for stale in [PollOutcome.approved(TokenPair(access: "old")), .expired, .denied, .fatal("x"), .transientFailure, .transientFailure] {
            model.receive(stale, generation: old)
        }
        XCTAssertEqual(model.step, .waiting(current), "the old code's results changed nothing")
        XCTAssertEqual(model.wait, .waiting)
        XCTAssertNil(try env.tokens.load())

        model.receive(.denied, generation: model.generation)
        XCTAssertEqual(model.step, .denied, "the current code's do")
    }

    func testGetANewCodeStopsPollingTheOldOne() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("polling code 1") { self.env.transport.requests(forCode: "device-1") > 0 }
        model.begin(app)
        await waitUntil("polling code 2") { self.env.transport.requests(forCode: "device-2") > 0 }
        let polls = env.transport.requests(forCode: "device-1")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(env.transport.requests(forCode: "device-1"), polls, "the old code is not polled again")
        model.cancel()
    }

    func testExpiredAndDeniedCodesSayWhatHappenedAndCloseTheBrowser() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        model.copyAndOpenGitHub(app)
        env.transport.expire(deviceCode: "device-1")
        await waitUntil("expired") { model.step == .expired }
        XCTAssertEqual(sheets.stopped, [0], "the browser is closed")
        XCTAssertNil(model.poller, "nothing is polling any more")

        model.begin(app)
        await waitUntil("code 2") { self.isWaiting(model) }
        model.copyAndOpenGitHub(app)
        env.transport.decline(deviceCode: "device-2")
        await waitUntil("denied") { model.step == .denied }
        XCTAssertEqual(sheets.stopped, [0, 1])
        XCTAssertNil(try env.tokens.load())
    }

    func testOfflineIsSaidAfterTwoFailuresInARowAndGoesAwayWhenGitHubAnswers() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        let gen = model.generation
        model.receive(.transientFailure, generation: gen)
        XCTAssertEqual(model.wait, .waiting, "one failed request is not news")
        model.receive(.transientFailure, generation: gen)
        XCTAssertEqual(model.wait, .offline)
        XCTAssertTrue(isWaiting(model), "and polling goes on")
        model.receive(.pending, generation: gen)
        XCTAssertEqual(model.wait, .waiting)
        model.cancel()
    }

    /// Back in front: ask now if GitHub's interval is over, and never sooner.
    func testReturningToTheForegroundPollsAtOnceButNeverFasterThanTheInterval() async throws {
        let app = try await launch()
        let clock = FakePollClock()
        let model = SignInModel()
        model.pollClock = clock.clock
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        await waitUntil("the first wait") { clock.requestedSleeps.count == 1 }

        model.sceneBecameActive(app)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(env.transport.requests(forCode: "device-1"), 0, "5 seconds had not passed")

        clock.advance(6)
        model.sceneBecameActive(app)
        await waitUntil("the poll on returning") { self.env.transport.requests(forCode: "device-1") == 1 }
        model.sceneBecameActive(app)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(env.transport.requests(forCode: "device-1"), 1, "just asked")
        model.cancel()
    }

    // MARK: no "Connected as" step

    /// Approval closes the sign-in page and opens GitHub's access page by itself: no confirm step, no Continue.
    func testApprovalOpensGitHubAtOnceWithNoConfirmStep() async throws {
        let app = try await launch(repositories: [])
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        model.copyAndOpenGitHub(app)
        env.transport.approve()
        await waitUntil("GitHub install page opened by itself") {
            self.sheets.sheets.last?.url.absoluteString == "https://github.com/apps/brain-notes-app/installations/new"
        }
        XCTAssertEqual(model.step, .signedIn(GitHubAccount(id: 1, login: "alice")))
        XCTAssertTrue(sheets.stopped.contains(0), "the sign-in browser closed on approval")
        XCTAssertEqual(try env.tokens.load()?.access, "test-access", "saved without a Continue")
        XCTAssertEqual(app.phase, .needsSignIn, "does not land on Choose notes before GitHub opens")
        XCTAssertNil(try SelectedRepoStore(baseFolder: env.folder).load(), "nothing picked")
        sheets.sheets.last?.finish(nil)
        await waitUntil("notes step after closing GitHub") { app.phase == .needsRepoSelection }
    }

    /// The 17:40 report: the installation already granted the one private repository, so polling saw no change and
    /// only closing GitHub's window could end the wait, while every button was disabled. Now the wait keeps Open GitHub
    /// and Cancel working, and the return (however late) opens the notes directly.
    func testAnUnchangedGrantKeepsWaitingWithWaysOutAndItsReturnOpensTheNotes() async throws {
        let app = try await launch()
        let outcome = await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/settings/installations/77")
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)

        // Many polls, the grant never changes: still waiting, and nothing is picked behind the user's back.
        let before = env.transport.requests.filter { $0.contains("/user/installations") }.count
        await waitUntil("several polls") { self.env.transport.requests.filter { $0.contains("/user/installations") }.count >= before + 4 }
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)
        XCTAssertNil(app.session)
        XCTAssertTrue(app.canReopenGitHubForInitialGrant, "Open GitHub is never disabled while waiting")

        // Coming back to the app with GitHub's window still open (a Mac) does not end it either, and does not get stuck.
        app.scenePhaseChanged(.active)
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)

        // Open GitHub: the same page again, the old window closed.
        let count = sheets.sheets.count
        app.reopenGitHubForInitialGrant()
        XCTAssertEqual(sheets.sheets.count, count + 1)
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/settings/installations/77")
        XCTAssertTrue(sheets.stopped.contains(count - 1), "the earlier window was closed")
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)

        // The person closes it: one private repository, not All, not truncated → the notes, directly.
        sheets.sheets.last?.finish(nil)
        await waitUntil("the notes") { app.phase == .ready }
        XCTAssertFalse(app.showsOnboarding)
        XCTAssertEqual(app.session?.repo.slug, "alice/private-notes")
        XCTAssertFalse(app.canReopenGitHubForInitialGrant)
    }

    /// Cancel while waiting on GitHub is never disabled, and it is a clean way back to Connect: the page closes, the
    /// saved sign-in comes out of the Keychain, and a late return from that page decides nothing.
    func testCancelWhileWaitingOnGitHubForgetsTheSignIn() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        env.transport.approve()
        await waitUntil("waiting on GitHub") { app.isAwaitingInitialGitHubGrant }
        XCTAssertNotNil(try env.tokens.load())
        let page = try XCTUnwrap(sheets.sheets.last)
        let pageIndex = sheets.sheets.count - 1

        model.cancel()
        await app.cancelFirstTimeSignIn()
        XCTAssertEqual(model.step, .start)
        XCTAssertFalse(app.isAwaitingInitialGitHubGrant)
        XCTAssertFalse(app.isPollingInstallations)
        XCTAssertTrue(sheets.stopped.contains(pageIndex), "GitHub's page closed")
        XCTAssertNil(try env.tokens.load(), "the sign-in is forgotten")
        XCTAssertEqual(app.account?.hasTokens, false)
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertNil(app.signedInUser)

        page.finish(nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(app.phase, .needsSignIn, "a late close of the cancelled page changes nothing")
        XCTAssertNil(app.session)
    }

    /// Cancel on a re-sign-in or with notes on the device never touches the stored sign-in.
    func testCancellingFirstSignInLeavesAnExistingSignInAlone() async throws {
        let app = try await launch(signedIn: true)
        await app.cancelFirstTimeSignIn()
        XCTAssertEqual(try env.tokens.load()?.access, "test-access")
        XCTAssertEqual(app.phase, .ready)
    }

    /// Cancel while the sign-in is still being saved and GitHub asked: it stops after its next wait, and what it saved
    /// is taken out again.
    func testCancelDuringTheHandOverStopsIt() async throws {
        let app = try await launch()
        env.transport.holdUser()
        let handOver = Task { await app.signedIn(pair: TokenPair(access: "test-access")) }
        await waitUntil("asking GitHub who this is") { self.env.transport.isInUserRequest }
        await app.cancelFirstTimeSignIn()
        env.transport.releaseUser()
        let outcome = await handOver.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(try env.tokens.load())
        XCTAssertFalse(app.isAwaitingInitialGitHubGrant)
        XCTAssertTrue(sheets.sheets.isEmpty, "GitHub was never opened for a cancelled sign-in")
    }

    /// A browser that could not start (its completion may never come) ends like a closed one, never a wait that can't end.
    func testABrowserThatCannotOpenDoesNotLeaveTheWaitStuck() async throws {
        let failing = InAppWebSession { _, _, onFinish in
            InAppWebSession.reportFailedStart(onFinish)
            return {}
        }
        env = try OnboardingEnvironment(webSession: failing)
        let app = try await launch()
        await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        await waitUntil("the wait ended") { !app.isAwaitingInitialGitHubGrant }
        await waitUntil("the one granted private repository opened") { app.phase == .ready }
        XCTAssertFalse(app.showsOnboarding)
    }

    func testUseADifferentAccountForgetsTheSignInAndOpensPrivatelyFromThenOn() async throws {
        let app = try await launch(repositories: [])
        let model = SignInModel()
        app.beginOnboardingRun()
        model.begin(app)
        await waitUntil("code 1") { self.isWaiting(model) }
        model.copyAndOpenGitHub(app)
        env.transport.approve()
        await waitUntil("alice waiting on GitHub") { app.isAwaitingInitialGitHubGrant }
        XCTAssertEqual(model.signedInAccount, GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(sheets.sheets.count, 2, "the code page, then GitHub's install page")

        env.transport.approve(false)
        env.transport.setUser(id: 2, login: "bob")
        model.useDifferentAccount(app)
        await waitUntil("code 2") {
            if case let .waiting(code) = model.step { code.userCode == "TEST-0002" } else { false }
        }
        XCTAssertTrue(app.privateBrowser)
        XCTAssertNil(try env.tokens.load(), "alice's sign-in was forgotten")
        XCTAssertFalse(app.isAwaitingInitialGitHubGrant)
        XCTAssertTrue(sheets.stopped.contains(1), "alice's GitHub page closed")
        XCTAssertEqual(sheets.sheets.count, 2, "the new code opens nothing by itself")
        model.copyAndOpenGitHub(app)
        XCTAssertEqual(sheets.sheets.last?.ephemeral, true, "the next browser is a private window")
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/login/device?user_code=TEST-0002")

        env.transport.approve()
        await waitUntil("private install page opened by itself") { self.sheets.sheets.count == 4 }
        XCTAssertEqual(model.signedInAccount, GitHubAccount(id: 2, login: "bob"))
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/apps/brain-notes-app/installations/new")
        XCTAssertEqual(sheets.sheets.last?.ephemeral, true, "initial GitHub install page uses the same private window")
        sheets.sheets.last?.finish(nil)
        await waitUntil("the notes step") { app.phase == .needsRepoSelection }

        // The same private window for the access page and the create page, for the rest of this run.
        app.openGitHubAppInstall()
        XCTAssertEqual(sheets.sheets.last?.ephemeral, true)
        app.openCreateBrain()
        XCTAssertEqual(sheets.sheets.last?.ephemeral, true)
        // A new run from Connect goes back to the shared browser.
        app.beginOnboardingRun()
        XCTAssertFalse(app.privateBrowser)
    }

    /// Several private repositories granted: the in-app picker, with Create a new private brain; nothing auto-picked.
    func testSeveralGrantedReposGoToThePicker() async throws {
        let app = try await launch(repositories: [])
        await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        env.transport.setRepositories([
            .init(repoId: 1, owner: "alice", name: "brain", defaultBranch: "main", isPrivate: true),
            .init(repoId: 2, owner: "alice", name: "work-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 3, owner: "alice", name: "blog", defaultBranch: "main", isPrivate: false),
        ])
        sheets.sheets.last?.finish(nil)
        await waitUntil("the picker") { app.phase == .needsRepoSelection }
        XCTAssertNil(app.session, "nothing picked for the user")
        guard case let .loaded(result) = app.discoveryState else { return XCTFail("no list") }
        XCTAssertEqual(result.privateRepositories.count, 2)
        XCTAssertEqual(result.publicRepositories.count, 1, "public ones listed, not selectable")
        XCTAssertNil(AppModel.singleAutoConnectableRepo(in: result))
        XCTAssertTrue(app.showsOnboarding)
    }

    // MARK: re-sign-in keeps its checks

    func testReSignInWithASelectionStillRequiresTheSameUserId() async throws {
        let app = try await launch(signedIn: true)
        await waitUntil("the launch check") { app.signedInUser?.login == "alice" }
        await app.session?.engine.stop()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }

        env.transport.setUser(id: 2, login: "bob")
        env.transport.approve()
        await waitUntil("the refusal, with no confirm step") { if case .refused = model.step { true } else { false } }
        XCTAssertEqual(try env.tokens.load()?.access, "test-access", "still the old sign-in: nothing replaced it")

        guard case let .refused(message, differentAccount) = model.step else { return XCTFail("not refused") }
        XCTAssertEqual(message, AppModel.accountMismatchMessage(login: "bob"), "the existing plain mismatch message")
        XCTAssertTrue(differentAccount)
        XCTAssertEqual(app.reSignInError, message)
        XCTAssertEqual(try env.tokens.load()?.access, "test-access", "bob's token was never saved")
        XCTAssertFalse(model.isContinuing)
        XCTAssertTrue(model.ownsOutcome, "the screen keeps the refusal on display")
        // The same refusal when the confirmed pair is handed over directly, with a token that is not the old one.
        let again = await app.signedIn(pair: TokenPair(access: "bob-candidate"), verifiedUser: GitHubAccount(id: 2, login: "bob"))
        XCTAssertEqual(again, .refused(message, differentAccount: true))
        XCTAssertEqual(try env.tokens.load()?.access, "test-access", "bob-candidate was never saved")
    }

    func testReSignInWithTheSameUserIsAccepted() async throws {
        let app = try await launch(signedIn: true)
        await waitUntil("the launch check") { app.signedInUser?.login == "alice" }
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        env.transport.approve()
        await waitUntil("alice signed in") { self.isSignedIn(model) }
        await waitUntil("handed over") { !model.isContinuing }
        XCTAssertNil(app.reSignInError)
        XCTAssertEqual(app.phase, .ready, "back in the notes, no screen in between")
        let outcome = await app.signedIn(pair: TokenPair(access: "reauth"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(outcome, .connected)
        XCTAssertNil(app.reSignInError)
        XCTAssertEqual(try env.tokens.load()?.access, "reauth")
        model.cancel()
    }

    /// The report's device: a selected-repo.json from an earlier build, and no token in the Keychain.
    func testALeftoverSelectionWithNoTokensEndsOnAClearScreen() async throws {
        // Same person: straight back into their notes.
        let app = try await launch(signedIn: true, tokensCleared: true)
        XCTAssertEqual(app.phase, .needsSignIn)
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        env.transport.approve()
        await waitUntil("the notes") { app.phase == .ready }
        XCTAssertNil(app.reSignInError)
        XCTAssertNotNil(try env.tokens.load())
    }

    func testALeftoverSelectionOfSomeoneElseIsExplainedWithAWayOut() async throws {
        let app = try await launch(signedIn: true, tokensCleared: true)
        let model = SignInModel()
        env.transport.setUser(id: 9, login: "casey")
        model.begin(app)
        await waitUntil("the code") { self.isWaiting(model) }
        env.transport.approve()
        await waitUntil("the refusal") { if case .refused = model.step { true } else { false } }
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertEqual(app.reSignInError, AppModel.accountMismatchMessage(login: "casey"))
        XCTAssertNil(try env.tokens.load(), "nothing saved")
    }

    // MARK: signedIn never ends silently

    func testNoSignInEndsWithoutSomethingToRead() async throws {
        func assertVisible(_ outcome: SignInOutcome, _ app: AppModel, _ what: String) {
            guard case let .refused(message, _) = outcome else { return }
            let failed: Bool
            if case .failed = app.phase { failed = true } else { failed = false }
            XCTAssertTrue(app.reSignInError == message || failed, "\(what): a refusal with nothing on screen")
            XCTAssertFalse(message.isEmpty, what)
        }

        // 1. A demo launch.
        let demo = try await launch(options: LaunchOptions(arguments: ["-BNScreen", "code"], environment: [:]))
        let demoOutcome = await demo.signedIn(pair: TokenPair(access: "x"))
        XCTAssertNotEqual(demoOutcome, .connected)
        XCTAssertNotNil(demo.reSignInError)
        assertVisible(demoOutcome, demo, "demo")
        await demo.session?.engine.stop()
        models = []
        env.cleanUp()
        env = nil

        // 2. Sample notes.
        let sample = try await launch()
        await sample.startSampleNotes()
        let sampleOutcome = await sample.signedIn(pair: TokenPair(access: "x"))
        XCTAssertNotEqual(sampleOutcome, .connected)
        XCTAssertNotNil(sample.reSignInError)
        assertVisible(sampleOutcome, sample, "sample")
        XCTAssertNil(try env.tokens.load())
        await sample.session?.engine.stop()
        models = []
        env.cleanUp()
        env = nil

        // 3. Notes on the device that belong to no account (a selection from before accounts were recorded).
        env = try OnboardingEnvironment(webSession: sheets.makeSession())
        try SelectedRepoStore(baseFolder: env.folder).save(try SelectedRepo(installationId: 77, repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main"))
        let legacy = try await launch()
        let legacyOutcome = await legacy.signedIn(pair: TokenPair(access: "x"))
        XCTAssertEqual(legacyOutcome, .refused(AppModel.unlinkedNotesMessage, differentAccount: false))
        assertVisible(legacyOutcome, legacy, "legacy selection")
        XCTAssertNil(try env.tokens.load())
        models = []
        env.cleanUp()
        env = nil

        // 4. The account check cannot run (no connection) on a re-sign-in.
        let offline = try await launch(signedIn: true)
        await offline.session?.engine.stop()
        env.transport.setUserOffline(true)
        let offlineOutcome = await offline.signedIn(pair: TokenPair(access: "y"))
        XCTAssertEqual(offlineOutcome, .refused(AppModel.accountCheckCouldNotRunMessage, differentAccount: false))
        assertVisible(offlineOutcome, offline, "offline re-sign-in")
        env.transport.setUserOffline(false)
        env.transport.setUser(id: 2, login: "bob")
        let mismatch = await offline.signedIn(pair: TokenPair(access: "y"))
        XCTAssertEqual(mismatch, .refused(AppModel.accountMismatchMessage(login: "bob"), differentAccount: true))
        assertVisible(mismatch, offline, "mismatch")
        models = []
        env.cleanUp()
        env = nil

        // 5. The Keychain refuses the new sign-in.
        env = try OnboardingEnvironment(keychainLocked: true, webSession: sheets.makeSession())
        let locked = try await launch()
        let lockedOutcome = await locked.signedIn(pair: TokenPair(access: "z"))
        XCTAssertEqual(lockedOutcome, .refused("Could not store the sign-in in the Keychain.", differentAccount: false))
        XCTAssertEqual(locked.phase, .failed("Could not store the sign-in in the Keychain."))
        assertVisible(lockedOutcome, locked, "keychain")
    }

    /// A first sign-in where the GitHub App has no installation: opens installations/new immediately, and closing it
    /// routes to the access step, never a blank or silent screen.
    func testNoInstallationRoutesToTheAccessStep() async throws {
        let app = try await launch(repositories: [])
        let outcome = await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/apps/brain-notes-app/installations/new")
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)
        sheets.sheets.last?.finish(nil)
        await waitUntil("access step after closing install sheet") { app.phase == .needsRepoSelection }
        XCTAssertTrue(app.showsOnboarding)
        guard case let .loaded(result) = app.discoveryState else { return XCTFail("no list: \(app.discoveryState)") }
        XCTAssertEqual(result.installationsCount, 0)
        XCTAssertTrue(result.repositories.isEmpty)
        XCTAssertEqual(app.signedInUser?.login, "alice")
        XCTAssertNil(app.session)

        // The screen for exactly this state says what to do, with the button that opens GitHub and the create option.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let flow = try String(contentsOf: sources.appendingPathComponent("Onboarding/OnboardingFlow.swift"), encoding: .utf8)
        let empty = try XCTUnwrap(flow.range(of: "private func emptySelectionScreen(isTruncated: Bool)"))
        let rest = String(flow[empty.upperBound...])
        let until = try XCTUnwrap(rest.range(of: "private func repositoryPickerScreen"))
        let screen = String(rest[..<until.lowerBound])
        XCTAssertTrue(screen.contains("Choose repositories on GitHub"))
        XCTAssertTrue(screen.contains("On GitHub, choose ‘Only select repositories’ and pick your notes."))
        XCTAssertTrue(screen.contains("app.openGitHubAppInstall()"))
        XCTAssertTrue(screen.contains("Create a new private brain"))
        XCTAssertFalse(screen.contains("Image(systemName"), "minimal: no icon")
        XCTAssertFalse(screen.contains(".background(.fill"), "minimal: no boxed hints")
        XCTAssertEqual(screen.components(separatedBy: "Button").count - 1, 2, "exactly two buttons")
        XCTAssertTrue(flow.contains("result.repositories.isEmpty {\n                emptySelectionScreen("), "an empty list goes to that screen")
    }

    /// Back in the app while the access page is open or just closed: the list is looked at again, with no tap.
    func testReturningToTheForegroundChecksAccessAgain() async throws {
        let app = try await launch(repositories: [])
        await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        XCTAssertEqual(sheets.sheets.last?.url.absoluteString, "https://github.com/apps/brain-notes-app/installations/new")
        // Background cancels the install polling.
        app.scenePhaseChanged(.background)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(app.isPollingInstallations)

        // They granted access while away.
        env.transport.setRepositories([.init(repoId: 888, owner: "dana", name: "my-brain", defaultBranch: "main", isPrivate: true)])
        let before = env.transport.requests.filter { $0.contains("/user/installations") }.count
        app.scenePhaseChanged(.active)
        await waitUntil("the list was asked for again") { self.env.transport.requests.filter { $0.contains("/user/installations") }.count > before }
        await waitUntil("the single private notes picked") { app.phase == .ready }
        XCTAssertEqual(app.session?.repo.slug, "dana/my-brain")
        XCTAssertFalse(sheets.stopped.isEmpty, "the GitHub page that was still open is closed")
    }

    /// On a Mac the browser's close and the app's return to the front come together. The second signal must not cancel
    /// the look the first one started, or the code screen keeps saying "Waiting for GitHub…" for good (build 6's fix,
    /// kept).
    func testBrowserCloseAndForegroundTogetherFinishTheGitHubReturnOnce() async throws {
        let app = try await launch(repositories: [])
        await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant)
        env.transport.setRepositories([.init(repoId: 888, owner: "dana", name: "my-brain", defaultBranch: "main", isPrivate: true)])
        sheets.sheets.last?.finish(nil)
        app.scenePhaseChanged(.active)
        app.scenePhaseChanged(.active)
        await waitUntil("the single granted private notes connected") { app.phase == .ready }
        XCTAssertFalse(app.isAwaitingInitialGitHubGrant)
        XCTAssertFalse(app.showsOnboarding, "straight into the notes")
        XCTAssertEqual(app.session?.repo.slug, "dana/my-brain")
        XCTAssertEqual(env.liveSessionsOpened, 1)

        // The same for a switch from Settings that is cancelled on GitHub: the notes stay, nothing keeps waiting.
        await app.changeNotesRepository()
        XCTAssertTrue(app.isSwitchingRepositories)
        sheets.sheets.last?.finish(nil)
        app.scenePhaseChanged(.active)
        await waitUntil("the switch ended") { !app.isSwitchingRepositories }
        XCTAssertEqual(app.session?.repo.slug, "dana/my-brain")
        XCTAssertFalse(app.isPresentingRepoPicker)
    }

    /// Going to the background while the return from GitHub is being looked at cancels the look; coming back runs it.
    func testABackgroundedGitHubReturnIsFinishedOnTheWayBack() async throws {
        let app = try await launch(repositories: [])
        await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        env.transport.setRepositories([.init(repoId: 888, owner: "dana", name: "my-brain", defaultBranch: "main", isPrivate: true)])
        env.transport.holdUser()
        sheets.sheets.last?.finish(nil)
        await waitUntil("the look at the return is asking GitHub who this is") { self.env.transport.isInUserRequest }
        app.scenePhaseChanged(.background)
        env.transport.releaseUser()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(app.isAwaitingInitialGitHubGrant, "the cancelled look left nothing decided")
        app.scenePhaseChanged(.active)
        await waitUntil("finished on the way back") { app.phase == .ready }
        XCTAssertEqual(app.session?.repo.slug, "dana/my-brain")
    }

    /// Coming back from GitHub's "new repository" page goes straight to the access step with its hint.
    func testCreateBrainReturnsToTheAccessStepWithAHint() async throws {
        let app = try await launch(repositories: [])
        await app.signedIn(pair: TokenPair(access: "test-access"), verifiedUser: GitHubAccount(id: 1, login: "alice"))
        sheets.sheets.last?.finish(nil)
        await waitUntil("access step") { app.phase == .needsRepoSelection }
        app.openCreateBrain()
        XCTAssertEqual(sheets.sheets.last?.url, AppConfig.createBrainURL)
        XCTAssertTrue(app.awaitingInstallAfterCreate)
        let before = env.transport.requests.filter { $0.contains("/user/installations") }.count
        sheets.sheets.last?.finish(nil)
        await waitUntil("the list asked for after the page closed") { self.env.transport.requests.filter { $0.contains("/user/installations") }.count > before }
        await waitUntil("the access step again") {
            if case let .loaded(result) = app.discoveryState { result.repositories.isEmpty } else { false }
        }
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertTrue(app.awaitingInstallAfterCreate, "the one-line hint is still shown")
    }
}
