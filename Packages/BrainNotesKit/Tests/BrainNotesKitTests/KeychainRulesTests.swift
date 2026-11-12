import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import Testing
@testable import BrainNotesKit

/// Audit F-2. The Keychain's answers as decisions, checked without a Keychain: nothing here reads or writes one.
@Suite struct KeychainRulesTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    #if canImport(Security)
    /// A Mac build goes to the file-based login keychain only when it can't use the data protection keychain at all.
    /// "Not found" used to send a team-signed build there too, where anything running as the user can plant a token,
    /// for instance right after Sign out and wipe.
    @Test func onlyAMissingEntitlementGoesToTheLoginKeychain() {
        #expect(KeychainRules.usesLoginKeychain(afterDataProtectionStatus: errSecMissingEntitlement))
        for status in [errSecItemNotFound, errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed, errSecDuplicateItem,
                       errSecNotAvailable, errSecParam, errSecDecode] {
            #expect(!KeychainRules.usesLoginKeychain(afterDataProtectionStatus: status), "\(status)")
        }
    }

    @Test func whatAReadMeans() {
        #expect(KeychainRules.read(errSecSuccess) == .found)
        #expect(KeychainRules.read(errSecItemNotFound) == .none)
        #expect(KeychainRules.read(errSecInteractionNotAllowed) == .unavailable)
        for status in [errSecMissingEntitlement, errSecAuthFailed, errSecNotAvailable, errSecDecode, errSecParam] {
            #expect(KeychainRules.read(status) == .failed(status), "\(status)")
        }
    }
    #endif

    /// The store and the app take their decisions from these rules. Read from the source: running the store would touch
    /// the real Keychain.
    @Test func theStoreAndTheAppUseTheRules() throws {
        let auth = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/BrainNotesKit/Sources/BrainNotesKit/Auth.swift"),
                              encoding: .utf8)
        #expect(auth.contains("if KeychainRules.usesLoginKeychain(afterDataProtectionStatus: first.0) {"))
        #expect(auth.contains("switch KeychainRules.read(status) {"))
        #expect(!auth.contains("first.0 == errSecItemNotFound"), "not found is no reason to read the login keychain")
        let session = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/BrainNotesKit/Sources/BrainNotesKit/Session.swift"),
                                 encoding: .utf8)
        #expect(session.contains("public var hasTokens: Bool { tokens.holdsTokens() }"))
        let model = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Sources/AppModel.swift"), encoding: .utf8)
        #expect(model.contains("KeychainTokenStore().holdsTokens()"))
        #expect(!model.contains("catch { return true }"), "a failure other than a locked Keychain is no sign-in")
    }

    /// Only a locked Keychain counts as "may hold tokens". Any other failure is no token, not a signed-in app with none.
    @Test func onlyALockedStoreMayHideTokens() {
        #expect(TokenStoreError.mayHideATokenPair(TokenStoreError.unavailable))
        #expect(!TokenStoreError.mayHideATokenPair(TokenStoreError.failed(-25300)))
        #expect(!TokenStoreError.mayHideATokenPair(TokenStoreError.failed(-34018)))
        #expect(!TokenStoreError.mayHideATokenPair(URLError(.notConnectedToInternet)))
        #expect(!TokenStoreError.mayHideATokenPair(CancellationError()))
    }

    private struct Failing: TokenStore {
        let error: TokenStoreError
        func load() throws -> TokenPair? { throw error }
        func save(_ pair: TokenPair) throws { throw error }
        func clear() {}
    }

    private struct Refusing: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    }

    @Test func aSessionCountsOnlyALockedStoreAsSignedIn() throws {
        #expect(Failing(error: .unavailable).holdsTokens())
        #expect(!Failing(error: .failed(-25300)).holdsTokens())
        #expect(!InMemoryTokenStore().holdsTokens())
        #expect(InMemoryTokenStore(TokenPair(access: "a")).holdsTokens())
        let config = AppConfig(clientId: "x")
        let selection = try SelectedRepo(installationId: 1, repoId: 1, owner: "alice", name: "notes")
        for (store, expected) in [(Failing(error: .unavailable), true), (Failing(error: .failed(-25300)), false)] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-tokens-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let s = try BrainSession.live(config: config, selection: selection, baseFolder: dir, deviceLabel: "test", tokens: store, transport: Refusing())
            #expect(s.hasTokens == expected, "\(store.error)")
        }
    }
}
