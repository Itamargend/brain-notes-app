import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

/// Audit F-6. Once the background flush is over, the tokens are in the Keychain only, not in the token manager's
/// memory as well. A pair the Keychain could not take is the exception: it is the only copy, so it stays.
@Suite struct TokenMemoryTests {
    final class Lockable: TokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var pair: TokenPair?
        private var locked = false
        private var failingSaves: Int
        init(_ pair: TokenPair, failingSaves: Int = 0) {
            self.pair = pair
            self.failingSaves = failingSaves
        }
        var stored: TokenPair? { lock.withLock { pair } }
        func setLocked(_ value: Bool) { lock.withLock { locked = value } }
        func load() throws -> TokenPair? {
            try lock.withLock {
                if locked { throw TokenStoreError.unavailable }
                return pair
            }
        }
        func save(_ pair: TokenPair) throws {
            try lock.withLock {
                if failingSaves > 0 {
                    failingSaves -= 1
                    throw TokenStoreError.failed(-1)
                }
                self.pair = pair
            }
        }
        func clear() { lock.withLock { pair = nil } }
    }

    @Test func forgettingThePairLeavesItInTheStoreOnly() async throws {
        let store = Lockable(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let manager = TokenManager(clientId: "c", transport: FakeGitHubHTTP(fake: FakeGitHub()), store: store)
        #expect(try await manager.accessToken() == "ghu_start")
        #expect(await manager.holdsPairInMemory)
        #expect(await manager.forgetCachedPair())
        #expect(await !manager.holdsPairInMemory)
        // No copy in memory to fall back on: while the store is locked there is no token at all.
        store.setLocked(true)
        await #expect(throws: TokenStoreError.unavailable) { try await manager.accessToken() }
        store.setLocked(false)
        #expect(try await manager.accessToken() == "ghu_start", "read again from the store")
    }

    /// Refresh tokens are single use: a rotated pair the store refused is the only one there is.
    @Test func aPairTheStoreRefusedStaysInMemory() async throws {
        let store = Lockable(TokenPair(access: "ghu_start", refresh: "ghr_start"), failingSaves: 2)
        let manager = TokenManager(clientId: "c", transport: FakeGitHubHTTP(fake: FakeGitHub()), store: store)
        #expect(try await manager.refresh(failed: "ghu_start") == "ghu_1")
        #expect(store.stored?.refresh == "ghr_start", "the save failed")
        #expect(await manager.forgetCachedPair() == false, "the second save fails too")
        #expect(await manager.holdsPairInMemory)
        #expect(try await manager.accessToken() == "ghu_1")
        // The next use stores it; after that it can go.
        #expect(store.stored?.refresh == "ghr_1")
        #expect(await manager.forgetCachedPair())
        #expect(await !manager.holdsPairInMemory)
    }

    @Test func forgettingStoresAnUnsavedPairFirst() async throws {
        let store = Lockable(TokenPair(access: "ghu_start", refresh: "ghr_start"), failingSaves: 1)
        let manager = TokenManager(clientId: "c", transport: FakeGitHubHTTP(fake: FakeGitHub()), store: store)
        #expect(try await manager.refresh(failed: "ghu_start") == "ghu_1")
        #expect(store.stored?.refresh == "ghr_start")
        #expect(await manager.forgetCachedPair())
        #expect(store.stored?.refresh == "ghr_1", "saved before it was let go")
        #expect(await !manager.holdsPairInMemory)
    }

    /// What the app runs when it leaves the screen: the note goes to GitHub, then the tokens leave memory.
    @Test func theBackgroundFlushPushesThenLetsGoOfTheTokens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-flush-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeGitHub(files: Harness.seed)
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let selection = try SelectedRepo(installationId: 1, repoId: 1, owner: "Itamargend", name: "brain-notes-test")
        let s = try BrainSession.live(config: AppConfig(clientId: "c"), selection: selection,
                                      baseFolder: dir, deviceLabel: "test", tokens: tokens, transport: FakeGitHubHTTP(fake: fake))
        await s.engine.sync(.manual)
        try s.store.save(path: "todo.md", text: "# Todo\nwritten just before leaving\n")
        await s.engine.noteSaved()
        let manager = try #require(Mirror(reflecting: s).descendant("manager") as? TokenManager)
        #expect(await manager.holdsPairInMemory)

        await s.flushInBackground()

        #expect(await fake.text("todo.md") == "# Todo\nwritten just before leaving\n")
        #expect(s.store.journal.outboxCount() == 0)
        #expect(await !manager.holdsPairInMemory)
        #expect(try tokens.load()?.access == "ghu_start", "the Keychain keeps them")
        // Back in front: the next run reads them again.
        try s.store.save(path: "todo.md", text: "# Todo\nback again\n")
        await s.engine.sync(.manual)
        #expect(await fake.text("todo.md") == "# Todo\nback again\n")
    }

    /// The app's background flush is the session's, so it lets go of the tokens too. Read from the source: the app
    /// model's own tests run only inside the app.
    @Test func theAppFlushesThroughTheSession() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("App/Sources/AppModel.swift"), encoding: .utf8)
        let start = try #require(model.range(of: "private func flushInBackground(_ s: BrainSession) {"))
        let end = try #require(model.range(of: "\n    }\n", range: start.upperBound..<model.endIndex))
        let body = model[start.upperBound..<end.lowerBound]
        #expect(body.contains("await s.flushInBackground()"))
        #expect(!body.contains("engine.sync(.background)"), "not the engine alone, which leaves the tokens in memory")
    }
}
