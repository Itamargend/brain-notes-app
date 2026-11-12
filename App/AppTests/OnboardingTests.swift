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
    private var codeDelay: Duration = .zero
    private var repositories: [RepoFixture] = [
        RepoFixture(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true)
    ]

    var requests: [String] { lock.withLock { recorded } }
    /// Every request to the REST API, as opposed to the sign-in endpoints.
    var apiRequests: [String] { requests.filter { !$0.contains("/login/") } }
    var repoRequests: [String] { requests.filter { $0.contains("/repositories/") } }
    func requests(forCode deviceCode: String) -> Int { lock.withLock { recorded.filter { $0 == "poll \(deviceCode)" }.count } }

    /// The next poll gets a token.
    func approve() { lock.withLock { approved = true } }
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
            let hasRepos = lock.withLock { !repositories.isEmpty || truncatedDiscovery }
            if hasRepos {
                return try answer(url, ["total_count": 1, "installations": [["id": 77, "account": ["login": userAccount.login]]]])
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
    let webSession = InAppWebSession.inert()
    private(set) var liveSessionsOpened = 0
    private(set) var demoSessionsOpened = 0
    private let suiteName = "bn-onboarding-test-\(UUID().uuidString)"
    private let fixtures: [(path: String, text: String)]

    init(signedIn: Bool = false, keychainLocked: Bool = false) throws {
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
        app.openNotesFromReadyScreen()
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
        XCTAssertTrue(app.readyScreenPending)
        await app.leaveSampleNotes()
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertFalse(app.readyScreenPending)
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
        XCTAssertFalse(app.readyScreenPending)
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

    func testSigningInFromOnboardingKeepsTheFlowUpUntilOpenMyNotes() async throws {
        let app = try await launch()
        let model = SignInModel()
        model.begin(app)
        await waitUntil("the code") { if case .waiting = model.step { true } else { false } }
        guard case let .waiting(code) = model.step else { return XCTFail("no code") }
        XCTAssertEqual(code.userCode, "TEST-0001")
        XCTAssertEqual(app.phase, .needsSignIn)

        env.transport.approve()
        await waitUntil("the sign-in") { app.phase == .ready }
        XCTAssertTrue(app.readyScreenPending, "Ready comes next, not the notes")
        XCTAssertTrue(app.showsOnboarding)
        await waitUntil("the token in the store") { (try? self.env.tokens.load()) != nil }

        // The fake refuses the API, so this first sync can't finish. The screen must not hold the notes back.
        await waitUntil("the engine's answer") { !ReadyStatus(snapshot: app.snapshot, sessionOpen: true).keepsNotesClosed }
        XCTAssertFalse(env.transport.apiRequests.isEmpty, "the sync did start")
        app.openNotesFromReadyScreen()
        XCTAssertFalse(app.showsOnboarding)
        XCTAssertEqual(app.phase, .ready)
    }

    /// Someone whose token stopped working signs in from the plain sheet, inside their notes.
    func testSigningInFromTheSheetStaysInTheNotes() async throws {
        let app = try await launch(signedIn: true)
        app.showSignIn = true
        await app.signedIn(pair: TokenPair(access: "test-access-2"))
        XCTAssertFalse(app.showSignIn)
        XCTAssertFalse(app.readyScreenPending)
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
        await waitUntil("the expired message") { model.step == .failed("The code ran out. You can get a new one.") }

        model.begin(app)
        await waitUntil("the second code") { self.env.transport.requests(forCode: "device-2") > 0 }
        env.transport.decline(deviceCode: "device-2")
        await waitUntil("the declined message") { model.step == .failed("You declined on GitHub. You can try again.") }
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

    // MARK: the Ready screen's words

    func testReadyStatusFollowsTheSnapshot() {
        func status(_ state: SyncState, firstSynced: Bool = false) -> ReadyStatus {
            var snapshot = SyncSnapshot()
            snapshot.state = state
            snapshot.hasFirstSynced = firstSynced
            return ReadyStatus(snapshot: snapshot, sessionOpen: true)
        }
        XCTAssertEqual(ReadyStatus(snapshot: SyncSnapshot(), sessionOpen: false), .working("Getting your notes", fraction: nil))
        XCTAssertEqual(status(.firstSync(.downloading)), .working("Downloading notes", fraction: nil))
        XCTAssertEqual(status(.firstSync(.verifying(done: 3, total: 12))), .working("Checking 3 of 12", fraction: 0.25))
        XCTAssertEqual(status(.firstSync(.indexing(done: 6, total: 12))), .working("Indexing 6 of 12", fraction: 0.5))
        XCTAssertEqual(status(.firstSync(.indexing(done: 0, total: 0))), .working("Indexing 0 of 0", fraction: nil), "no division by zero")
        XCTAssertEqual(status(.idle, firstSynced: true), .done)
        XCTAssertEqual(status(.needsAttention(2), firstSynced: true), .done, "the sample notes' resting state")

        // Once the notes are on the device, a poll or a dropped network changes nothing here.
        for state: SyncState in [.checking, .pulling, .merging, .applying, .pushing, .verifying, .offline, .accessLost,
                                 .installationTruncated, .publicRepo, .signedOut, .retrying(at: Date()), .paused(.user),
                                 .paused(.rateLimited(until: nil))] {
            XCTAssertEqual(status(state, firstSynced: true), .done, "\(state)")
        }
    }

    /// Open My Notes waits only while notes are moving. Every state a first sync can stop in lets the user on.
    func testReadyIsNeverADeadEnd() {
        func status(_ state: SyncState) -> ReadyStatus {
            var snapshot = SyncSnapshot()
            snapshot.state = state
            return ReadyStatus(snapshot: snapshot, sessionOpen: true)
        }
        for state: SyncState in [.offline, .accessLost, .installationTruncated, .publicRepo, .signedOut, .retrying(at: Date()),
                                 .accountMismatch(login: "bob"), .accountCheckFailed(unauthorized: false), .accountCheckFailed(unauthorized: true),
                                 .paused(.user), .paused(.rateLimited(until: nil)), .needsAttention(1), .idle,
                                 .repoTooLarge(RepoTooLarge(.entries, max: FirstSyncLimits.standard.maxEntries))] {
            XCTAssertFalse(status(state).keepsNotesClosed, "\(state)")
            guard case .problem = status(state) else { return XCTFail("\(state) says nothing") }
        }
        XCTAssertEqual(status(.publicRepo), .problem(RepoTarget.publicRepoMessage))
        XCTAssertEqual(status(.installationTruncated), .problem(DiscoveryResult.truncatedMessage))
        for state: SyncState in [.firstSync(.downloading), .firstSync(.verifying(done: 1, total: 2)), .firstSync(.indexing(done: 1, total: 2)),
                                 .checking, .pulling, .merging, .applying, .pushing, .verifying] {
            XCTAssertTrue(status(state).keepsNotesClosed, "\(state)")
        }
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
        XCTAssertEqual(options("-BNScreen", "ready").onboardingStep, .ready)
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
        XCTAssertEqual(app.phase, .ready)
    }

    /// The check is made once. A later launch never clears, whatever the folder holds by then.
    func testALaterLaunchNeverClears() async throws {
        env = try OnboardingEnvironment()
        env.defaults.set(true, forKey: AppModel.installedKey)
        try env.tokens.save(TokenPair(access: "test-access"))
        let app = try await launch()
        XCTAssertNotNil(try env.tokens.load())
        XCTAssertEqual(app.phase, .ready)
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

        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertTrue(app.showsOnboarding)
        guard case let .loaded(initial) = app.discoveryState else { return XCTFail("expected loaded empty discovery") }
        XCTAssertTrue(initial.repositories.isEmpty)

        app.openGitHubAppInstall()
        XCTAssertTrue(app.isPollingInstallations)
        XCTAssertEqual(env.webSession.openedURLs.last?.absoluteString, "https://github.com/apps/brain-notes-app/installations/new")

        env.transport.setRepositories([
            .init(repoId: 888, owner: "dana", name: "my-brain", defaultBranch: "trunk", isPrivate: true)
        ])
        await waitUntil("polled installation selects the single private repo") { app.phase == .ready }
        XCTAssertFalse(app.isPollingInstallations)
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

        XCTAssertEqual(app.phase, .needsRepoSelection)
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

    func testChangeNotesRepositoryWarnsOnUnsyncedWipesOldCopyFirstAndKeepsTokens() async throws {
        let app = try await launch(signedIn: true)
        let oldSession = try XCTUnwrap(app.session)
        let oldRoot = oldSession.store.root
        try oldSession.store.save(path: "unsynced.md", text: "# Local draft\n")

        let hasUnsynced = await app.checkUnsyncedBeforeRepoSwitch()
        XCTAssertTrue(hasUnsynced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))

        await app.changeNotesRepository()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path), "old repo folder wiped before picker")
        XCTAssertNil(try SelectedRepoStore(baseFolder: env.folder).load(), "stored selection cleared")
        XCTAssertNotNil(try env.tokens.load(), "still signed in")
        XCTAssertNil(app.session)
        XCTAssertEqual(app.phase, .needsRepoSelection)
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

    func testInAppWebSessionAlwaysUsesEphemeralBrowserSession() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let web = try String(contentsOf: sources.appendingPathComponent("InAppWebSession.swift"), encoding: .utf8)
        XCTAssertTrue(web.contains("authSession.prefersEphemeralWebBrowserSession = true"))
        XCTAssertFalse(web.contains("prefersEphemeralWebBrowserSession = false"))
        XCTAssertEqual(web.components(separatedBy: "ASWebAuthenticationSession(").count, 2, "one shared sheet builder")

        let flow = try String(contentsOf: sources.appendingPathComponent("Onboarding/OnboardingFlow.swift"), encoding: .utf8)
        XCTAssertTrue(flow.contains("Signed in as @"))
        XCTAssertTrue(flow.contains("Not you? Sign out"))
        let settings = try String(contentsOf: sources.appendingPathComponent("SignInAndSettings.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("Signed in as @"))
        XCTAssertTrue(settings.contains("Not you? Sign out"))
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

        // Change-repo wipe removes Brain/4242, orphan Brain/9999, AND legacy folders (no more preserving legacy folders).
        await app.changeNotesRepository()
        XCTAssertFalse(fm.fileExists(atPath: brainDir.appendingPathComponent("4242").path))
        XCTAssertFalse(fm.fileExists(atPath: brainDir.appendingPathComponent("9999").path), "orphan numeric repo folder cleared")
        XCTAssertFalse(fm.fileExists(atPath: dirtyLegacyRoot.path), "legacy folder deleted on repo switch")

        // Single-flight selectRepository ignores concurrent second tap while first is in flight.
        guard case let .loaded(discovered) = app.discoveryState else { return XCTFail("expected loaded discovery") }
        let repoA = try XCTUnwrap(discovered.privateRepositories.first { $0.repoId == 4242 })
        let repoB = try XCTUnwrap(discovered.privateRepositories.first { $0.repoId == 5151 })
        let opensBefore = env.liveSessionsOpened
        async let firstTap: Void = app.selectRepository(repoA)
        async let secondTap: Void = app.selectRepository(repoB)
        _ = await (firstTap, secondTap)
        XCTAssertEqual(env.liveSessionsOpened, opensBefore + 1, "concurrent tap ignored while selectRepository is in flight")
        XCTAssertEqual(app.session?.repo.repoId, 4242)

        // Selecting another repo while one is already open stops and wipes the previous session first.
        try app.session?.store.save(path: "temp.md", text: "# Temp\n")
        await app.selectRepository(repoB)
        XCTAssertEqual(app.session?.repo.repoId, 5151)
        XCTAssertFalse(fm.fileExists(atPath: brainDir.appendingPathComponent("4242").path), "previous session wiped before opening next")

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

        await app.changeNotesRepository()
        guard case let .loaded(list) = app.discoveryState, let repo = list.privateRepositories.first else {
            return XCTFail("expected single private repo in picker")
        }
        await app.selectRepository(repo)
        let verifiedSession = try XCTUnwrap(app.session)
        XCTAssertTrue(verifiedSession.tokenManager === acct.manager, "BrainSession.openVerified shares BrainAccount's single TokenManager")

        env.transport.setRepositories([])
        await app.changeNotesRepository()
        app.openGitHubAppInstall()
        XCTAssertTrue(app.isPollingInstallations)
        XCTAssertTrue(app.isInstallSheetActive)

        app.scenePhaseChanged(.background)
        XCTAssertFalse(app.isPollingInstallations, "background cancels install polling immediately")
        XCTAssertFalse(app.isInstallSheetActive)

        env.transport.setRepositories([
            .init(repoId: 7070, owner: "alice", name: "appeared-while-backgrounded", defaultBranch: "main", isPrivate: true)
        ])
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(app.phase, .needsRepoSelection, "cancelled background poll never selects or opens a repository")
        XCTAssertNil(app.session)
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

        // Ignored before sign-in.
        app.handleOpenURL(setupURL)
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertTrue(env.transport.requests.isEmpty)

        // Sign in (auto-selects 4242 -> .ready), then switch to manual repo selection (autoSelectSinglePrivate == false).
        await app.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertEqual(app.phase, .ready)
        app.handleOpenURL(setupURL)
        XCTAssertEqual(app.phase, .ready, "ignored in .ready")

        await app.changeNotesRepository()
        XCTAssertEqual(app.phase, .needsRepoSelection)
        XCTAssertFalse(app.isInstallSheetActive)

        // Ignored in .needsRepoSelection when install sheet is NOT active.
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
        let app = try await launch()
        await app.signedIn(pair: TokenPair(access: "test-access", refresh: "ghr_bg_1"))
        await app.changeNotesRepository()
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
        // 1. After "Change notes repository" (repoSelectionAutoSelect == false), nothing auto-picks:
        //    - retryDiscovery() after an offline failure keeps the picker open even with 1 private repo.
        //    - openGitHubAppInstall() from .failed keeps the picker open even when 1 private repo appears.
        env = try OnboardingEnvironment()
        let app = try await launch()
        await app.signedIn(pair: TokenPair(access: "test-access"))
        XCTAssertEqual(app.phase, .ready)

        env.transport.setDiscoveryOffline(true)
        await app.changeNotesRepository()
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
        XCTAssertNil(freshApp.session)

        // 3. Initial onboarding (repoSelectionAutoSelect == true) when openGitHubAppInstall() is called from .failed
        //    while ONLINE with 1 already-installed private repo (4242): pre-poll baseline fetch records [4242],
        //    does NOT auto-pick 4242, and DOES auto-pick a single newly added private repo (8080).
        env.transport.setDiscoveryOffline(true)
        await freshApp.retryDiscovery()
        env.transport.setDiscoveryOffline(false)
        freshApp.openGitHubAppInstall()
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(freshApp.phase, .needsRepoSelection, "already-installed 4242 was in fetched baseline, so not auto-picked")
        XCTAssertNil(freshApp.session)

        env.transport.setRepositories([
            .init(repoId: 4242, owner: "alice", name: "private-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 8080, owner: "alice", name: "newly-added-notes", defaultBranch: "main", isPrivate: true),
        ])
        await waitUntil("newly added single private repo auto-selected") { freshApp.phase == .ready }
        XCTAssertEqual(freshApp.session?.repo.repoId, 8080)
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
}
