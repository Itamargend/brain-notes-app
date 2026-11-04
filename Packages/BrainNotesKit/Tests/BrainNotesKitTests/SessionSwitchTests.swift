import Foundation
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
        let s = try BrainSession.live(config: AppConfig(clientId: "x", owner: RepoTarget.allowedOwner, name: RepoTarget.allowedName),
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
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
            try BrainSession.live(config: AppConfig(clientId: "x", owner: RepoTarget.allowedOwner, name: "brain"),
                                  baseFolder: dir, deviceLabel: "test", tokens: InMemoryTokenStore(), transport: RefusingTransport())
        }
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
