import AppKit
import BrainNotesKit
import XCTest
@testable import BrainNotes

/// Answers GitHub's sign-in endpoints from a script and refuses everything else. It is all these tests'
/// live sessions have behind them, so none of them can reach the network. Every request is recorded.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var codesIssued = 0
    private var approved = false
    private var expired: Set<String> = []
    private var declined: Set<String> = []
    private var holding = false
    private var refusing = false
    private var codeDelay: Duration = .zero

    var requests: [String] { lock.withLock { recorded } }
    /// Every request to the REST API, as opposed to the sign-in endpoints.
    var apiRequests: [String] { requests.filter { !$0.contains("/login/") } }
    func requests(forCode deviceCode: String) -> Int { lock.withLock { recorded.filter { $0 == "poll \(deviceCode)" }.count } }

    /// The next poll gets a token.
    func approve() { lock.withLock { approved = true } }
    /// Polls for this code get `expired_token`.
    func expire(deviceCode: String) { lock.withLock { _ = expired.insert(deviceCode) } }
    /// Polls for this code get `access_denied`.
    func decline(deviceCode: String) { lock.withLock { _ = declined.insert(deviceCode) } }
    /// New codes take this long to arrive.
    func delayCodes(_ delay: Duration) { lock.withLock { codeDelay = delay } }
    /// API requests wait until `release`, so that a sync stays where it is.
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }
    /// API requests get a 401, as with a token GitHub no longer accepts.
    func refuseToken() { lock.withLock { refusing = true } }

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
            let code = body.split(separator: "&").first { $0.hasPrefix("device_code=") }.map { String($0.dropFirst(12)) } ?? ""
            lock.withLock { recorded.append("poll \(code)") }
            // The real flow waits seconds between polls. A few milliseconds keep this one from spinning.
            try await Task.sleep(for: .milliseconds(5))
            if lock.withLock({ expired.contains(code) }) { return try answer(url, ["error": "expired_token"]) }
            if lock.withLock({ declined.contains(code) }) { return try answer(url, ["error": "access_denied"]) }
            if lock.withLock({ approved }) { return try answer(url, ["access_token": "test-access", "token_type": "bearer"]) }
            return try answer(url, ["error": "authorization_pending"])
        default:
            while lock.withLock({ holding }) { try await Task.sleep(for: .milliseconds(20)) }
            if lock.withLock({ refusing }) { return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))) }
            throw URLError(.notConnectedToInternet)
        }
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
        // A device that signed in has launched before: it has its `Brain/` folder, as every install that
        // ever opened has. Without it the first launch would take the tokens for a deleted app's (audit B2).
        if signedIn {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Brain", isDirectory: true), withIntermediateDirectories: true)
        }
    }

    var sessions: SessionFactory {
        SessionFactory(
            baseFolder: { [folder] in folder },
            // As `SessionFactory.standard`: a token that cannot be read right now still counts.
            tokensExist: { [keychain] in
                do { return try keychain.load() != nil } catch { return true }
            },
            live: { [self] base in
                liveSessionsOpened += 1
                return try BrainSession.live(config: AppConfig(clientId: "test-client", owner: RepoTarget.allowedOwner, name: RepoTarget.allowedName),
                                             baseFolder: base, deviceLabel: "test", tokens: keychain, transport: transport)
            },
            demo: { [self] base in
                demoSessionsOpened += 1
                return try await BrainSession.demo(fixtures: fixtures, baseFolder: base)
            },
            clearTokens: { [keychain] in keychain.clear() })
    }

    func launch(options: LaunchOptions = LaunchOptions(), usesStack: Bool = true) async -> (AppModel, Router) {
        let app = AppModel(options: options, sessions: sessions, defaults: defaults)
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
        XCTAssertEqual(env.liveSessionsOpened, 1, "the session waiting for a sign-in")

        await app.startSampleNotes()

        let session = try XCTUnwrap(app.session)
        XCTAssertTrue(session.isDemo)
        XCTAssertTrue(app.sampleMode)
        XCTAssertEqual(env.liveSessionsOpened, 1, "nothing live was opened for it")
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
        XCTAssertEqual(env.liveSessionsOpened, 1, "only the first launch's")
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
        let session = try XCTUnwrap(app.session)
        XCTAssertFalse(session.isDemo)
        XCTAssertFalse(session.hasTokens)
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
        let app = try await launch()
        let live = try XCTUnwrap(app.session)
        try live.store.save(path: "mine.md", text: "# Mine\nnot on GitHub yet\n")

        await app.startSampleNotes()
        XCTAssertNil(try app.session?.store.read("mine.md"), "not in the sample notes")
        await app.leaveSampleNotes()

        XCTAssertEqual(try app.session?.store.read("mine.md"), "# Mine\nnot on GitHub yet\n")
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
        XCTAssertFalse(try XCTUnwrap(app.session).hasTokens)
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
                                 .signedOut, .retrying(at: Date()), .paused(.user), .paused(.rateLimited(until: nil))] {
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
        for state: SyncState in [.offline, .accessLost, .signedOut, .retrying(at: Date()), .paused(.user),
                                 .paused(.rateLimited(until: nil)), .needsAttention(1), .idle] {
            XCTAssertFalse(status(state).keepsNotesClosed, "\(state)")
            guard case .problem = status(state) else { return XCTFail("\(state) says nothing") }
        }
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
        XCTAssertEqual(options("-BNScreen", "ready").onboardingStep, .ready)
        XCTAssertNil(options("-BNScreen", "list").onboardingStep)
        XCTAssertNil(options().onboardingStep)
        XCTAssertNil(options("-BNScreen").screen, "no value, no screen")

        XCTAssertTrue(options("-BNScreen", "code").demo, "so that opening the code screen can't start a real device flow")
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
}
