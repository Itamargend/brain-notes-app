import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

/// What the app needs to switch between the sample notes and the live session at run time.
@Suite struct SessionSwitchTests {
    private struct RefusingTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bn-switch-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aDemoSessionHasNoWayToTheNetwork() async throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try await BrainSession.demo(fixtures: [("a.md", "# A\n")], baseFolder: dir)
        #expect(s.isDemo)
        #expect(s.deviceFlow() == nil, "no transport, so no device flow")
        #expect(Mirror(reflecting: s).descendant("transport") as? HTTPTransport == nil)
        #expect(Mirror(reflecting: s.engine).descendant("client") is FakeGitHub)
    }

    @Test func demoFilesStayInTheirOwnFolder() async throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try await BrainSession.demo(fixtures: [("a.md", "# A\n")], baseFolder: dir)
        #expect(s.store.root.path.hasPrefix(BrainSession.demoFolder(in: dir).path + "/"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Brain").path))
    }

    @Test func aLiveSessionUsesTheTokenStoreAndTransportItIsGiven() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = InMemoryTokenStore()
        let selection = try SelectedRepo(installationId: 1, repoId: 1, owner: "Itamargend", name: "brain-notes-test")
        let s = try BrainSession.live(config: AppConfig(clientId: "x"), selection: selection,
                                      baseFolder: dir, deviceLabel: "test", tokens: tokens, transport: RefusingTransport())
        #expect(!s.isDemo)
        #expect(!s.hasTokens)
        try tokens.save(TokenPair(access: "x"))
        #expect(s.hasTokens)
        #expect(Mirror(reflecting: s).descendant("transport") is RefusingTransport)
    }

    @Test func theRepoGuardStillRunsWithAnInjectedTransport() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["../Brain", "brain.git", "..", ""] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(name)") {
                let bad = try SelectedRepo(installationId: 1, repoId: 1, owner: "Itamargend", name: name)
                _ = try BrainSession.live(config: AppConfig(clientId: "x"), selection: bad,
                                          baseFolder: dir, deviceLabel: "test", tokens: InMemoryTokenStore(), transport: RefusingTransport())
            }
        }
    }

    /// Review H2. A first sync held at the tarball while the user signs out and wipes. When the download comes back,
    /// the notes must not be written into the deleted folder.
    @Test func wipeWaitsForAFirstSyncInFlight() async throws {
        struct HeldTarball: HTTPTransport {
            let inner: FakeGitHubHTTP
            let gate: Gate
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.path.contains("/tarball/") == true { await gate.enterAndWait() }
                return try await inner.send(request)
            }
        }
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let transport = HeldTarball(inner: FakeGitHubHTTP(fake: FakeGitHub(files: Harness.seed)), gate: gate)
        let selection = try SelectedRepo(installationId: 1, repoId: 1, owner: "Itamargend", name: "brain-notes-test")
        let s = try BrainSession.live(config: AppConfig(clientId: "c"), selection: selection,
                                      baseFolder: dir, deviceLabel: "test", tokens: tokens, transport: transport)
        let root = dir.appendingPathComponent("Brain", isDirectory: true).appendingPathComponent("1", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: root.path))

        let run = Task { await s.engine.sync(.manual) }
        await gate.waitUntilEntered()
        let wipe = Task { try await s.signOutAndWipe() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        try await wipe.value
        await run.value

        #expect(!FileManager.default.fileExists(atPath: root.path), "no note came back after the wipe")
        #expect(try tokens.load() == nil)
    }

    /// Audit B1. The access token has expired, so the first sync refreshes it first. That refresh is held on the wire
    /// while the user signs out and wipes. When GitHub answers, the fresh pair must not land back in the token store.
    @Test func wipeDropsATokenRefreshInFlight() async throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start", accessExpiry: Date(timeIntervalSinceNow: -3600)))
        let http = FakeGitHubHTTP(fake: FakeGitHub(files: Harness.seed))
        let selection = try SelectedRepo(installationId: 1, repoId: 1, owner: "Itamargend", name: "brain-notes-test")
        let s = try BrainSession.live(config: AppConfig(clientId: "c"), selection: selection,
                                      baseFolder: dir, deviceLabel: "test", tokens: tokens, transport: HeldRefresh(inner: http, gate: gate))
        let root = dir.appendingPathComponent("Brain", isDirectory: true).appendingPathComponent("1", isDirectory: true)

        let run = Task { await s.engine.sync(.manual) }
        await gate.waitUntilEntered()
        let wipe = Task { try await s.signOutAndWipe() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        try await wipe.value
        await run.value

        #expect(http.log.contains { $0.url?.path == "/login/oauth/access_token" }, "the refresh really was on the wire")
        #expect(try tokens.load() == nil, "the refreshed pair was not stored")
        #expect(!s.hasTokens)
        #expect(!FileManager.default.fileExists(atPath: root.path), "no note came back after the wipe")
    }

    /// Audit B1, at the token manager. Neither the caller that started the refresh nor one waiting on it gets the
    /// pair that comes back after a sign-out, and it is not saved.
    @Test func aRefreshThatReturnsAfterSignOutIsDropped() async throws {
        let gate = Gate()
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start", accessExpiry: Date(timeIntervalSinceNow: -3600)))
        let manager = TokenManager(clientId: "c", transport: HeldRefresh(inner: http, gate: gate), store: tokens)

        let first = Task { try await manager.accessToken() }
        await gate.waitUntilEntered()
        let second = Task { try await manager.refresh(failed: "ghu_start") }
        try await Task.sleep(for: .milliseconds(50))
        // What `BrainSession.signOutAndWipe` does first.
        tokens.clear()
        await manager.reload()
        await gate.open()

        await #expect(throws: GitHubError.unauthorized) { try await first.value }
        await #expect(throws: GitHubError.unauthorized) { try await second.value }
        #expect(try tokens.load() == nil, "the fresh pair was not saved")
        await #expect(throws: GitHubError.unauthorized) { try await manager.accessToken() }
        #expect(await manager.refreshCount == 1, "one refresh went out")
    }

    /// Review H3. `stop` cancels the timer's sleep, but a tick already handed to its own task still arrives.
    @Test func aTickAfterStopStartsNoRun() async throws {
        let h = try Harness()
        await h.sync()
        await h.engine.start()
        await h.engine.stop()
        await h.engine.waitUntilIdle()
        let before = await h.fake.count(.getRef)
        await h.engine.tick()
        #expect(await h.fake.count(.getRef) == before, "a stopped engine does not check GitHub")
    }

    @Test func waitingForIdleReturnsAtOnceWhenNothingRuns() async throws {
        let h = try Harness()
        await h.engine.waitUntilIdle()
    }

    /// A push held at the ref update: the wait must not finish until the run does.
    @Test func waitingForIdleWaitsForTheRunInFlight() async throws {
        let h = try Harness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\n- changed\n")
        let gate = Gate()
        await h.fake.beforeNextUpdateRef { _ in await gate.enterAndWait() }
        let run = Task { await h.engine.sync(.manual) }
        await gate.waitUntilEntered()

        let finished = Flag()
        let waiting = Task {
            await h.engine.waitUntilIdle()
            await finished.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await finished.value == false, "the run is still held")

        await gate.open()
        await waiting.value
        await run.value
        #expect(h.store.status(of: "todo.md") == .synced)
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

/// Holds the token refresh POST at a gate; everything else goes straight through.
private struct HeldRefresh: HTTPTransport {
    let inner: FakeGitHubHTTP
    let gate: Gate
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/login/oauth/access_token" { await gate.enterAndWait() }
        return try await inner.send(request)
    }
}

/// Holds one task until the test opens it, and tells the test when that task has arrived.
private actor Gate {
    private var entered = false
    private var isOpen = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        arrival?.resume()
        arrival = nil
        if isOpen { return }
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }
}
