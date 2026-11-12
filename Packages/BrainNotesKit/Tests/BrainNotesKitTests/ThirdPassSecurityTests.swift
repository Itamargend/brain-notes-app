import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

// MARK: - BN-02: SelectedRepo account binding & candidate token check

@Suite struct AccountBindingSecurityTests {
    @Test func selectedRepoPersistsUserIdAndLoginAndDecodesOlderFilesAsUnverifiedOwner() throws {
        let user = GitHubAccount(id: 9001, login: "alice")
        let disc = try DiscoveredRepo(
            installationId: 12,
            repoId: 5001,
            owner: "alice",
            name: "brain-notes",
            defaultBranch: "main",
            isPrivate: true
        )
        let bound = try disc.select(account: user)
        #expect(bound.userId == 9001)
        #expect(bound.userLogin == "alice")
        #expect(bound.hasVerifiedOwner)

        let encoded = try JSONEncoder().encode(bound)
        let roundTrip = try JSONDecoder().decode(SelectedRepo.self, from: encoded)
        #expect(roundTrip == bound)
        #expect(roundTrip.hasVerifiedOwner)

        // Legacy persisted JSON without userId/userLogin decodes as unknown owner (`!hasVerifiedOwner`), forcing re-verification.
        let legacyJSON = Data(#"{"installationId":12,"repoId":5001,"owner":"alice","name":"brain-notes","defaultBranch":"main"}"#.utf8)
        let legacy = try JSONDecoder().decode(SelectedRepo.self, from: legacyJSON)
        #expect(legacy.userId == nil)
        #expect(legacy.userLogin == nil)
        #expect(!legacy.hasVerifiedOwner)
        #expect(try legacy.withAccount(user) == bound)

        // Tampered partial or invalid owner fields are rejected on init and decode.
        for badJSON in [
            #"{"installationId":12,"repoId":5001,"owner":"alice","name":"brain-notes","defaultBranch":"main","userId":9001}"#,
            #"{"installationId":12,"repoId":5001,"owner":"alice","name":"brain-notes","defaultBranch":"main","userLogin":"alice"}"#,
            #"{"installationId":12,"repoId":5001,"owner":"alice","name":"brain-notes","defaultBranch":"main","userId":0,"userLogin":"alice"}"#,
            #"{"installationId":12,"repoId":5001,"owner":"alice","name":"brain-notes","defaultBranch":"main","userId":9001,"userLogin":"../evil"}"#,
        ] {
            #expect(throws: (any Error).self, "\(badJSON)") {
                _ = try JSONDecoder().decode(SelectedRepo.self, from: Data(badJSON.utf8))
            }
        }
    }

    @Test func verifyCandidateTokenChecksUserWithoutSavingToTokenStore() async throws {
        final class CandidateUserTransport: HTTPTransport, @unchecked Sendable {
            let result: Result<(Int64, String), URLError>
            private let lock = NSLock()
            private(set) var seenAuthHeaders: [String] = []

            init(result: Result<(Int64, String), URLError>) {
                self.result = result
            }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                lock.withLock { seenAuthHeaders.append(auth) }
                let (uid, login) = try result.get()
                let data = try JSONSerialization.data(withJSONObject: ["id": uid, "login": login])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-cand-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = InMemoryTokenStore(nil)
        let bobTransport = CandidateUserTransport(result: .success((202, "bob")))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: store, transport: bobTransport)

        let candidate = TokenPair(access: "ghu_candidate_bob", refresh: "ghr_candidate_bob")
        let (who, unchangedPair) = try await account.verifyCandidateToken(candidate)
        #expect(who == GitHubAccount(id: 202, login: "bob"))
        #expect(unchangedPair == candidate)
        #expect(bobTransport.seenAuthHeaders == ["Bearer ghu_candidate_bob"])
        // Critically, verifyCandidateToken NEVER saves the candidate pair into the persistent store or shared TokenManager.
        #expect(try store.load() == nil)
        #expect(!(await account.manager.holdsPairInMemory))

        // When candidate verification triggers a token refresh (expired access token or 401), verifyCandidateToken returns
        // the rotated single-use refresh token pair while still leaving the persistent store untouched.
        final class RefreshingCandidateTransport: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls: [String] = []

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                if url.path == "/login/oauth/access_token" {
                    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                    lock.withLock { calls.append("refresh:\(body)") }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "access_token": "ghu_rotated_alice",
                        "refresh_token": "ghr_rotated_alice",
                        "token_type": "bearer",
                        "expires_in": 28_800,
                    ])
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                lock.withLock { calls.append("user:\(auth)") }
                if auth == "Bearer ghu_spent" {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                let data = try JSONSerialization.data(withJSONObject: ["id": 77, "login": "alice"])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let refreshTransport = RefreshingCandidateTransport()
        let refreshAccount = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: store, transport: refreshTransport)
        let expiringCandidate = TokenPair(
            access: "ghu_spent",
            refresh: "ghr_single_use_1",
            accessExpiry: Date().addingTimeInterval(-120)
        )
        let (refreshedUser, rotatedPair) = try await refreshAccount.verifyCandidateToken(expiringCandidate)
        #expect(refreshedUser == GitHubAccount(id: 77, login: "alice"))
        #expect(rotatedPair.access == "ghu_rotated_alice")
        #expect(rotatedPair.refresh == "ghr_rotated_alice")
        #expect(try store.load() == nil)

        // Offline / error also leaves the store untouched.
        let offlineAccount = BrainAccount(
            config: AppConfig(clientId: "Iv1.test"),
            baseFolder: base,
            tokens: store,
            transport: CandidateUserTransport(result: .failure(URLError(.notConnectedToInternet)))
        )
        await #expect(throws: GitHubError.offline) {
            _ = try await offlineAccount.verifyCandidateToken(candidate)
        }
        #expect(try store.load() == nil)
    }
}

// MARK: - BN-03 & Legacy Drop: Full wipe scope, orphan & legacy deletion, and symlink safety

@Suite struct WipeAndLegacyCleanupTests {
    @Test func signOutAndWipeRemovesEntireBrainAndBrainDemoIncludingOrphanAndLegacyFolders() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bn-wipe3-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let fake = FakeGitHub(files: [("note.md", "# Live\n")])
        let http = FakeGitHubHTTP(fake: fake, repoId: 5001, installationId: 10, owner: "alice", name: "notes")
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: tokens, transport: http)
        let sel = try SelectedRepo(installationId: 10, repoId: 5001, owner: "alice", name: "notes", userId: 77, userLogin: "alice")
        let session = try await BrainSession.openVerified(account: account, selection: sel, deviceLabel: "mac")
        await session.engine.sync(.manual)

        // Create orphan numeric repo folder, legacy <owner>_<name> folder with unsynced edit, and BrainDemo folder.
        let brain = base.appendingPathComponent("Brain", isDirectory: true)
        let orphan = brain.appendingPathComponent("9999", isDirectory: true)
        let legacy = brain.appendingPathComponent("alice_old", isDirectory: true)
        let legacyStore = try NoteStore(root: legacy, deviceLabel: "mac")
        _ = try legacyStore.save(path: "draft.md", text: "# Unsynced legacy\n")
        try? legacyStore.journal.close()
        try? legacyStore.index.close()
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan.appendingPathComponent("leftover.md"))

        let demoSession = try await BrainSession.demo(fixtures: [("sample.md", "# Sample\n")], baseFolder: base)
        let demoDir = BrainSession.demoFolder(in: base)
        #expect(fm.fileExists(atPath: demoDir.path))

        // Leaving sample notes (`isDemo == true`) removes ONLY BrainDemo and keeps live Brain/ intact.
        try await demoSession.signOutAndWipe()
        #expect(!fm.fileExists(atPath: demoDir.path))
        #expect(fm.fileExists(atPath: brain.path))

        // Re-create BrainDemo and run live signOutAndWipe: BOTH Brain/ and BrainDemo/ and selection must be completely gone.
        try fm.createDirectory(at: demoDir, withIntermediateDirectories: true)
        try await session.signOutAndWipe()
        #expect(!fm.fileExists(atPath: brain.path))
        #expect(!fm.fileExists(atPath: demoDir.path))
        #expect(try SelectedRepoStore(baseFolder: base).load() == nil)
        #expect(try tokens.load() == nil)
    }

    @Test func wipeForRepoSwitchDeletesAllNumericOrphanAndLegacyFoldersWhileKeepingTokens() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bn-switch3-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let fake = FakeGitHub(files: [("a.md", "# A\n")])
        let http = FakeGitHubHTTP(fake: fake, repoId: 5001, installationId: 10, owner: "alice", name: "notes")
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: tokens, transport: http)
        let sel = try SelectedRepo(installationId: 10, repoId: 5001, owner: "alice", name: "notes", userId: 77, userLogin: "alice")
        let session = try await BrainSession.openVerified(account: account, selection: sel, deviceLabel: "mac")

        let brain = base.appendingPathComponent("Brain", isDirectory: true)
        let orphanNumeric = brain.appendingPathComponent("8888", isDirectory: true)
        try fm.createDirectory(at: orphanNumeric, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphanNumeric.appendingPathComponent("note.md"))

        let cleanLegacy = brain.appendingPathComponent("bob_clean", isDirectory: true)
        let cleanStore = try NoteStore(root: cleanLegacy, deviceLabel: "mac")
        try? cleanStore.journal.close()
        try? cleanStore.index.close()

        let dirtyLegacy = brain.appendingPathComponent("bob_dirty", isDirectory: true)
        let dirtyStore = try NoteStore(root: dirtyLegacy, deviceLabel: "mac")
        _ = try dirtyStore.save(path: "unsynced.md", text: "# Legacy draft\n")
        try? dirtyStore.journal.close()
        try? dirtyStore.index.close()

        try await session.wipeForRepoSwitch()

        #expect(!LegacyBrainMigration.itemExistsNoFollow(brain))
        #expect(!fm.fileExists(atPath: brain.appendingPathComponent("5001").path))
        #expect(!fm.fileExists(atPath: orphanNumeric.path))
        #expect(!fm.fileExists(atPath: cleanLegacy.path))
        #expect(!fm.fileExists(atPath: dirtyLegacy.path))
        #expect(try SelectedRepoStore(baseFolder: base).load() == nil)
        #expect(try tokens.load() != nil)
    }

    @Test func launchCleanupDeletesLegacyFoldersWithUnsyncedJournalAndFilesAndImportsNothing() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bn-legacy3-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let brain = base.appendingPathComponent("Brain", isDirectory: true)

        // Matching legacy folder `alice_notes` with unsynced create, edit, delete, secret ops and note files on disk.
        let matchingLegacy = brain.appendingPathComponent("alice_notes", isDirectory: true)
        let matchingStore = try NoteStore(root: matchingLegacy, deviceLabel: "mac")
        _ = try matchingStore.save(path: "draft.md", text: "# Legacy draft\nDo not import.\n")
        _ = try matchingStore.save(path: "existing.md", text: "# Legacy overwrite\n")
        _ = try matchingStore.save(path: "to-delete.md", text: "# Delete me\n")
        try matchingStore.delete(path: "to-delete.md")
        let fakeToken = "ghp_" + String(repeating: "Z", count: 36)
        _ = try matchingStore.save(path: "secret-draft.md", text: "# Draft\n\(fakeToken)\n")
        try? matchingStore.journal.close()
        try? matchingStore.index.close()

        // Non-matching legacy folder with unsynced journal + files.
        let otherLegacy = brain.appendingPathComponent("bob_other", isDirectory: true)
        let otherStore = try NoteStore(root: otherLegacy, deviceLabel: "mac")
        _ = try otherStore.save(path: "keep.md", text: "# Bob unsynced\n")
        try? otherStore.journal.close()
        try? otherStore.index.close()

        // Keep one numeric repo folder to ensure numeric stores survive launch cleanup.
        let numericFolder = brain.appendingPathComponent("7001", isDirectory: true)
        try fm.createDirectory(at: numericFolder, withIntermediateDirectories: true)

        LegacyBrainMigration.cleanUpLegacyFolders(baseFolder: base)

        #expect(!LegacyBrainMigration.itemExistsNoFollow(matchingLegacy))
        #expect(!LegacyBrainMigration.itemExistsNoFollow(otherLegacy))
        #expect(fm.fileExists(atPath: numericFolder.path))
        let brainValues = try URL(fileURLWithPath: brain.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(brainValues.isExcludedFromBackup == true)

        // Open verified session for `alice/notes` (repoId 7001), sync, and verify NOTHING from the legacy folders appeared.
        let fake = FakeGitHub(files: [("existing.md", "# Remote existing\n")])
        let http = FakeGitHubHTTP(fake: fake, repoId: 7001, installationId: 15, owner: "alice", name: "notes")
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: tokens, transport: http)
        let sel = try SelectedRepo(installationId: 15, repoId: 7001, owner: "alice", name: "notes", userId: 77, userLogin: "alice")
        let session = try await BrainSession.openVerified(account: account, selection: sel, deviceLabel: "mac")
        await session.engine.sync(.manual)
        await session.engine.sync(.background)

        #expect(try session.store.read("draft.md") == nil)
        #expect(try session.store.read("secret-draft.md") == nil)
        #expect(try session.store.read("keep.md") == nil)
        #expect(try session.store.read("existing.md") == "# Remote existing\n")
        #expect(session.store.journal.outbox().isEmpty)
        #expect(!(await fake.has("draft.md")))
        #expect(!(await fake.has("secret-draft.md")))
        await session.engine.stop()
    }

    @Test func symlinkedBrainAndSymlinkedChildrenAreUnlinkedAndOutsideDirectoryContentsSurvive() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("bn-symlink3-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }

        let base = sandbox.appendingPathComponent("appBase", isDirectory: true)
        let outsideBrain = sandbox.appendingPathComponent("outsideBrain", isDirectory: true)
        let outsideChild = sandbox.appendingPathComponent("outsideChild", isDirectory: true)
        let outsideNumeric = sandbox.appendingPathComponent("outsideNumeric", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideBrain.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideChild, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideNumeric, withIntermediateDirectories: true)

        let brainSentinel = outsideBrain.appendingPathComponent("keep-brain.md")
        let brainNested = outsideBrain.appendingPathComponent("sub/nested.md")
        let childSentinel = outsideChild.appendingPathComponent("keep-child.md")
        let numericSentinel = outsideNumeric.appendingPathComponent("keep-numeric.md")
        let jsonSentinel = sandbox.appendingPathComponent("outside-selected.json")
        try Data("# Outside Brain\n".utf8).write(to: brainSentinel)
        try Data("# Outside Nested\n".utf8).write(to: brainNested)
        try Data("# Outside Child\n".utf8).write(to: childSentinel)
        try Data("# Outside Numeric\n".utf8).write(to: numericSentinel)
        try Data("{\"keep\":true}\n".utf8).write(to: jsonSentinel)

        let brainLink = base.appendingPathComponent("Brain", isDirectory: false)

        // 1. Symlinked Brain/ on launch cleanup: unlinks Brain/ without enumerating or deleting outsideBrain/.
        try fm.createSymbolicLink(at: brainLink, withDestinationURL: outsideBrain)
        #expect(LegacyBrainMigration.isSymbolicLink(brainLink))
        LegacyBrainMigration.cleanUpLegacyFolders(baseFolder: base)
        #expect(!LegacyBrainMigration.itemExistsNoFollow(brainLink))
        #expect(try Data(contentsOf: brainSentinel) == Data("# Outside Brain\n".utf8))
        #expect(try Data(contentsOf: brainNested) == Data("# Outside Nested\n".utf8))

        // 2. Symlinked Brain/ on signOutAndWipe: unlinks Brain/ without deleting outsideBrain/.
        try fm.createSymbolicLink(at: brainLink, withDestinationURL: outsideBrain)
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let fake = FakeGitHub(files: [])
        let http = FakeGitHubHTTP(fake: fake, repoId: 5001, installationId: 10, owner: "alice", name: "notes")
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: tokens, transport: http)
        try await account.signOutAndWipe()
        #expect(!LegacyBrainMigration.itemExistsNoFollow(brainLink))
        #expect(try Data(contentsOf: brainSentinel) == Data("# Outside Brain\n".utf8))
        #expect(try Data(contentsOf: brainNested) == Data("# Outside Nested\n".utf8))

        // 3. Real Brain/ containing symlinked legacy child, symlinked numeric child, and symlinked selected-repo.json.
        let realBrain = base.appendingPathComponent("Brain", isDirectory: true)
        try fm.createDirectory(at: realBrain, withIntermediateDirectories: true)
        let childLink = realBrain.appendingPathComponent("alice_notes", isDirectory: false)
        let numericLink = realBrain.appendingPathComponent("9999", isDirectory: false)
        let jsonLink = realBrain.appendingPathComponent("selected-repo.json", isDirectory: false)
        try fm.createSymbolicLink(at: childLink, withDestinationURL: outsideChild)
        try fm.createSymbolicLink(at: numericLink, withDestinationURL: outsideNumeric)
        try fm.createSymbolicLink(at: jsonLink, withDestinationURL: jsonSentinel)

        #expect(try SelectedRepoStore(baseFolder: base).load() == nil)
        LegacyBrainMigration.cleanUpLegacyFolders(baseFolder: base)
        #expect(!LegacyBrainMigration.itemExistsNoFollow(childLink))
        #expect(!LegacyBrainMigration.itemExistsNoFollow(numericLink))
        #expect(!LegacyBrainMigration.itemExistsNoFollow(jsonLink))
        #expect(try Data(contentsOf: childSentinel) == Data("# Outside Child\n".utf8))
        #expect(try Data(contentsOf: numericSentinel) == Data("# Outside Numeric\n".utf8))
        #expect(try Data(contentsOf: jsonSentinel) == Data("{\"keep\":true}\n".utf8))

        // 4. Symlinked child inside Brain/ during wipeForRepoSwitch: unlinked, outside target survives.
        try tokens.save(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let sel = try SelectedRepo(installationId: 10, repoId: 5001, owner: "alice", name: "notes", userId: 77, userLogin: "alice")
        let session = try await BrainSession.openVerified(account: account, selection: sel, deviceLabel: "mac")
        try fm.createSymbolicLink(at: childLink, withDestinationURL: outsideChild)
        try await session.wipeForRepoSwitch()
        #expect(!LegacyBrainMigration.itemExistsNoFollow(realBrain))
        #expect(try Data(contentsOf: childSentinel) == Data("# Outside Child\n".utf8))
    }
}

// MARK: - BN-04: Shared TokenManager & no Keychain/store write after wipe

@Suite struct SharedTokenManagerAndWipeTests {
    @Test func sessionSharesAccountTokenManagerAndSlowRefreshCompletingAfterWipeDoesNotWriteStore() async throws {
        final class SlowRefreshTransport: HTTPTransport, @unchecked Sendable {
            let baseHTTP: FakeGitHubHTTP
            private let lock = NSLock()
            private var refreshStartedCont: CheckedContinuation<Void, Never>?
            private var releaseRefreshCont: CheckedContinuation<Void, Never>?
            private var didEnterRefresh = false

            init(baseHTTP: FakeGitHubHTTP) {
                self.baseHTTP = baseHTTP
            }

            func waitForRefreshStart() async {
                let already = lock.withLock { didEnterRefresh }
                if already { return }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let immediate = lock.withLock { () -> Bool in
                        if didEnterRefresh { return true }
                        refreshStartedCont = c
                        return false
                    }
                    if immediate { c.resume() }
                }
            }

            func releaseRefresh() {
                let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    let cur = releaseRefreshCont
                    releaseRefreshCont = nil
                    return cur
                }
                c?.resume()
            }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.host == "github.com", request.url?.path == "/login/oauth/access_token" {
                    let startCont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        didEnterRefresh = true
                        let c = refreshStartedCont
                        refreshStartedCont = nil
                        return c
                    }
                    startCont?.resume()
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        lock.withLock { releaseRefreshCont = c }
                    }
                }
                return try await baseHTTP.send(request)
            }
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-tm4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(files: [("a.md", "# A\n")])
        let fakeHTTP = FakeGitHubHTTP(fake: fake, repoId: 4001, installationId: 4, owner: "alice", name: "notes")
        let slow = SlowRefreshTransport(baseHTTP: fakeHTTP)
        let store = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: store, transport: slow)
        let sel = try SelectedRepo(installationId: 4, repoId: 4001, owner: "alice", name: "notes", userId: 77, userLogin: "alice")

        let session = try await BrainSession.openVerified(account: account, selection: sel, deviceLabel: "mac")
        #expect(session.tokenManager === account.manager)
        let reopened = try BrainSession.live(account: account, selection: sel, deviceLabel: "mac")
        #expect(reopened.tokenManager === account.manager)

        // Start a slow refresh on the shared TokenManager, then wipe before the refresh HTTP reply arrives.
        let refreshTask = Task {
            try await account.manager.refresh(failed: "ghu_start")
        }
        await slow.waitForRefreshStart()
        try await session.signOutAndWipe()
        #expect(try store.load() == nil)

        // Now let the slow HTTP 200 refresh response arrive AFTER the wipe.
        slow.releaseRefresh()
        await #expect(throws: GitHubError.unauthorized) {
            _ = try await refreshTask.value
        }
        #expect(try store.load() == nil, "completed refresh from pre-wipe generation must never write the TokenStore")
        #expect(!(await account.manager.holdsPairInMemory))
    }
}

// MARK: - BN-05: Fail-closed repo metadata validation

@Suite struct FailClosedRepoMetadataTests {
    @Test func fetchVerifiedPrivateRepoFailsClosedWhenRequiredFieldsAreMissingOrNull() async throws {
        final class MetadataTransport: HTTPTransport, @unchecked Sendable {
            var payload: [String: Any]
            init(payload: [String: Any]) { self.payload = payload }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let target = try RepoTarget(repoId: 5001, owner: "alice", name: "notes", defaultBranch: "main")
        let complete: [String: Any] = [
            "id": 5001,
            "owner": ["login": "alice"],
            "name": "notes",
            "private": true,
            "visibility": "private",
            "default_branch": "main",
        ]

        // Missing or null required fields -> GitHubError.repoAccessLost (never fail-open).
        let brokenPayloads: [[String: Any]] = [
            complete.merging(["id": NSNull()]) { _, new in new },
            complete.filter { $0.key != "id" },
            complete.merging(["id": 9999]) { _, new in new },
            complete.merging(["owner": [:] as [String: Any]]) { _, new in new },
            complete.filter { $0.key != "owner" },
            complete.merging(["owner": ["login": "bob"]]) { _, new in new },
            complete.filter { $0.key != "name" },
            complete.merging(["name": NSNull()]) { _, new in new },
            complete.merging(["name": "other"]) { _, new in new },
            complete.filter { $0.key != "private" },
            complete.merging(["private": NSNull()]) { _, new in new },
            complete.filter { $0.key != "default_branch" },
            complete.merging(["default_branch": ""]) { _, new in new },
        ]

        for bad in brokenPayloads {
            let t = MetadataTransport(payload: bad)
            let tokens = TokenManager(clientId: "Iv1.test", transport: t, store: InMemoryTokenStore(TokenPair(access: "ghu_ok")))
            let client = GitHubHTTPClient(repo: target, transport: t, tokens: tokens)
            await #expect(throws: GitHubError.repoAccessLost) {
                try await client.verifyPrivateRepo()
            }
        }
    }
}

// MARK: - BN-06: Default branch rename recovery without wiping local data

@Suite struct DefaultBranchRenameRecoveryTests {
    @Test func defaultBranchRenameRecoversInSessionWithoutWipingUnsyncedNotes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-branch6-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(files: [("hello.md", "# Hello\n")])
        let http = FakeGitHubHTTP(
            fake: fake, repoId: 6006, installationId: 60, owner: "alice", name: "notes", defaultBranch: "master"
        )
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: tokens, transport: http)
        let initial = try SelectedRepo(
            installationId: 60, repoId: 6006, owner: "alice", name: "notes", defaultBranch: "master", userId: 77, userLogin: "alice"
        )

        let session = try await BrainSession.openVerified(account: account, selection: initial, deviceLabel: "mac")
        await session.engine.sync(.manual)
        #expect(session.repo.defaultBranch == "master")

        // User writes an unsynced local note while offline, and renames default branch on GitHub from `master` to `main`.
        _ = try session.store.save(path: "unsynced.md", text: "# Keep across branch rename\n")
        http.setDefaultBranch("main")

        // Sync sees `default_branch == "main"` during verifyPrivateRepo(), updates selection + client in-place without wiping,
        // and pushes the unsynced note onto `main`!
        await session.engine.sync(.background)
        let snap = await session.engine.snapshot
        #expect(snap.state == .idle)
        #expect(session.repo.defaultBranch == "main")
        #expect(session.selection?.defaultBranch == "main")
        #expect(session.selection?.userId == 77)
        let persisted = try #require(try SelectedRepoStore(baseFolder: base).load())
        #expect(persisted.defaultBranch == "main")
        #expect(persisted.userId == 77)
        #expect(await fake.text("unsynced.md") == "# Keep across branch rename\n")
        await session.engine.stop()
    }
}

// MARK: - BN-07: Discovery truncation & 4 MiB cap

@Suite struct DiscoveryTruncationAndCapTests {
    @Test func truncatedDiscoveryIsNotTreatedAsNotListedAndEnforces4MiBCap() async throws {
        #expect(ReplyLimit.discovery == 4 * 1024 * 1024)

        // 1. All three discovery endpoints (/user, /user/installations, /user/installations/{id}/repositories) enforce 4 MiB cap.
        struct Over4MiBTransport: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": String(ReplyLimit.discovery + 1)]
                )!
                return (Data(), http)
            }
        }
        let overTokens = TokenManager(clientId: "Iv1.test", transport: Over4MiBTransport(), store: InMemoryTokenStore(TokenPair(access: "t")))
        let overClient = GitHubDiscoveryClient(transport: Over4MiBTransport(), tokens: overTokens)
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.discovery)) {
            _ = try await overClient.authenticatedUser()
        }
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.discovery)) {
            _ = try await overClient.listInstallations()
        }
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.discovery)) {
            _ = try await overClient.listRepositories(installationId: 1)
        }

        // 2. When installation repositories hit `maxPages` with a full page of 100 repos and our repo is beyond the cap,
        // `discoverRepositories` marks `isTruncated = true`, `verifySelection` throws `.truncated` (NOT `.notListed`),
        // and `SyncEngine` enters `.installationTruncated` (NOT `.accessLost`).
        final class TruncatedReposTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                if url.path == "/user/installations" {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "total_count": 1,
                        "installations": [["id": 10, "account": ["login": "alice"]]],
                    ])
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                if url.path == "/user/installations/10/repositories" {
                    let repos: [[String: Any]] = (1...100).map { idx in
                        [
                            "id": idx,
                            "name": "other-\(idx)",
                            "owner": ["login": "alice"],
                            "private": true,
                            "visibility": "private",
                            "default_branch": "main",
                        ]
                    }
                    let data = try JSONSerialization.data(withJSONObject: ["total_count": 500, "repositories": repos])
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let data = try JSONSerialization.data(withJSONObject: ["message": "Not Found"])
                return (data, HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }

        let truncTransport = TruncatedReposTransport()
        let truncTokens = TokenManager(clientId: "Iv1.test", transport: truncTransport, store: InMemoryTokenStore(TokenPair(access: "t")))
        let cappedDiscovery = GitHubDiscoveryClient(transport: truncTransport, tokens: truncTokens, maxPages: 1)

        let discovered = try await cappedDiscovery.listAccessibleRepositories()
        #expect(discovered.isTruncated)
        #expect(discovered.repositories.count == 100)

        let beyondCap = try SelectedRepo(installationId: 10, repoId: 9999, owner: "alice", name: "my-brain")
        await #expect(throws: SelectionVerificationError.truncated) {
            _ = try await cappedDiscovery.verifySelection(beyondCap)
        }

        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bn-trunc7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let noteStore = try NoteStore(root: storeRoot, deviceLabel: "mac")
        let repoClient = GitHubHTTPClient(repo: try beyondCap.target(), transport: truncTransport, tokens: truncTokens)
        let engine = SyncEngine(
            store: noteStore,
            client: repoClient,
            installationCheck: {
                _ = try await cappedDiscovery.verifySelection(beyondCap)
            },
            initiallyVerified: false
        )
        await engine.sync(.manual)
        let snap = await engine.snapshot
        #expect(snap.state == SyncState.installationTruncated)
    }

    @Test func exact500ItemsIsNotTruncatedWhile501IsTruncated() async throws {
        #expect(GitHubDiscoveryClient.defaultMaxPages == 5)

        final class ExactCountTransport: HTTPTransport, @unchecked Sendable {
            let totalRepos: Int
            let totalInstallations: Int
            private let lock = NSLock()
            private(set) var repoPagesFetched: [Int] = []
            private(set) var installationPagesFetched: [Int] = []

            init(totalRepos: Int, totalInstallations: Int = 1) {
                self.totalRepos = totalRepos
                self.totalInstallations = totalInstallations
            }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                let pageStr = url.query?.split(separator: "&").first(where: { $0.hasPrefix("page=") }).map { String($0.dropFirst(5)) } ?? "1"
                let page = Int(pageStr) ?? 1
                if url.path == "/user/installations" {
                    lock.withLock { installationPagesFetched.append(page) }
                    let start = (page - 1) * 100 + 1
                    let end = min(page * 100, totalInstallations)
                    let installs: [[String: Any]] = start <= end ? (start...end).map { idx in
                        ["id": idx, "account": ["login": "alice"]]
                    } : []
                    let data = try JSONSerialization.data(withJSONObject: [
                        "total_count": totalInstallations,
                        "installations": installs,
                    ])
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                if url.path == "/user/installations/1/repositories" {
                    lock.withLock { repoPagesFetched.append(page) }
                    let start = (page - 1) * 100 + 1
                    let end = min(page * 100, totalRepos)
                    let repos: [[String: Any]] = start <= end ? (start...end).map { idx in
                        [
                            "id": idx,
                            "name": "repo-\(idx)",
                            "owner": ["login": "alice"],
                            "private": true,
                            "visibility": "private",
                            "default_branch": "main",
                        ]
                    } : []
                    let data = try JSONSerialization.data(withJSONObject: [
                        "total_count": totalRepos,
                        "repositories": repos,
                    ])
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let data = try JSONSerialization.data(withJSONObject: ["total_count": 0, "repositories": [] as [[String: Any]]])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        // 1. Exactly 500 repositories (5 pages * 100 == total_count 500) is NOT truncated.
        let t500 = ExactCountTransport(totalRepos: 500)
        let tokens500 = TokenManager(clientId: "Iv1.test", transport: t500, store: InMemoryTokenStore(TokenPair(access: "t")))
        let client500 = GitHubDiscoveryClient(transport: t500, tokens: tokens500)
        let res500 = try await client500.listAccessibleRepositories()
        #expect(res500.repositories.count == 500)
        #expect(!res500.isTruncated)
        #expect(t500.repoPagesFetched == [1, 2, 3, 4, 5])

        let missing500 = try SelectedRepo(installationId: 1, repoId: 9999, owner: "alice", name: "missing")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await client500.verifySelection(missing500)
        }

        // Exactly 500 installations (5 pages * 100 == total_count 500) is NOT truncated on listInstallationsWithTruncation.
        let tInst500 = ExactCountTransport(totalRepos: 0, totalInstallations: 500)
        let tokensInst500 = TokenManager(clientId: "Iv1.test", transport: tInst500, store: InMemoryTokenStore(TokenPair(access: "t")))
        let clientInst500 = GitHubDiscoveryClient(transport: tInst500, tokens: tokensInst500)
        let instRes500 = try await clientInst500.listInstallationsWithTruncation()
        #expect(instRes500.installations.count == 500)
        #expect(!instRes500.truncated)
        #expect(tInst500.installationPagesFetched == [1, 2, 3, 4, 5])

        // 2. 501 repositories (5 pages * 100 < total_count 501) IS truncated.
        let t501 = ExactCountTransport(totalRepos: 501)
        let tokens501 = TokenManager(clientId: "Iv1.test", transport: t501, store: InMemoryTokenStore(TokenPair(access: "t")))
        let client501 = GitHubDiscoveryClient(transport: t501, tokens: tokens501)
        let res501 = try await client501.listAccessibleRepositories()
        #expect(res501.repositories.count == 500)
        #expect(res501.isTruncated)
        await #expect(throws: SelectionVerificationError.truncated) {
            _ = try await client501.verifySelection(missing500)
        }

        // 501 installations IS truncated.
        let tInst501 = ExactCountTransport(totalRepos: 0, totalInstallations: 501)
        let tokensInst501 = TokenManager(clientId: "Iv1.test", transport: tInst501, store: InMemoryTokenStore(TokenPair(access: "t")))
        let clientInst501 = GitHubDiscoveryClient(transport: tInst501, tokens: tokensInst501)
        let instRes501 = try await clientInst501.listInstallationsWithTruncation()
        #expect(instRes501.installations.count == 500)
        #expect(instRes501.truncated)
    }

    @Test func overallRequestBudgetAndCancellationStopPaging() async throws {
        // 1. Overall request budget caps total HTTP requests across many installations and reports truncation.
        final class ManyInstallationsTransport: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var requestCount = 0

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                lock.withLock { requestCount += 1 }
                if url.path == "/user/installations" {
                    let installs: [[String: Any]] = (1...10).map { ["id": $0, "account": ["login": "alice"]] }
                    let data = try JSONSerialization.data(withJSONObject: ["total_count": 10, "installations": installs])
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let pageStr = url.query?.split(separator: "&").first(where: { $0.hasPrefix("page=") }).map { String($0.dropFirst(5)) } ?? "1"
                let page = Int(pageStr) ?? 1
                let base = (page - 1) * 100
                let repos: [[String: Any]] = (1...100).map { idx in
                    [
                        "id": base + idx,
                        "name": "r-\(base + idx)",
                        "owner": ["login": "alice"],
                        "private": true,
                        "visibility": "private",
                        "default_branch": "main",
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: ["total_count": 500, "repositories": repos])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let budgetTransport = ManyInstallationsTransport()
        let budgetTokens = TokenManager(clientId: "Iv1.test", transport: budgetTransport, store: InMemoryTokenStore(TokenPair(access: "t")))
        let budgetedClient = GitHubDiscoveryClient(transport: budgetTransport, tokens: budgetTokens, maxPages: 5, maxRequests: 4)
        let budgetedResult = try await budgetedClient.listAccessibleRepositories()
        #expect(budgetTransport.requestCount == 4)
        #expect(budgetedResult.isTruncated)

        // 2. Task cancellation stops paging before the next page is requested.
        final class CancellablePagingTransport: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var pagesSeen: [Int] = []
            private var page1EnteredCont: CheckedContinuation<Void, Never>?
            private var releasePage1Cont: CheckedContinuation<Void, Never>?
            private var entered = false

            func waitForPage1() async {
                if lock.withLock({ entered }) { return }
                await withCheckedContinuation { cont in
                    lock.withLock { page1EnteredCont = cont }
                }
            }

            func releasePage1() {
                let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    let c = releasePage1Cont
                    releasePage1Cont = nil
                    return c
                }
                cont?.resume()
            }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                let pageStr = url.query?.split(separator: "&").first(where: { $0.hasPrefix("page=") }).map { String($0.dropFirst(5)) } ?? "1"
                let page = Int(pageStr) ?? 1
                lock.withLock { pagesSeen.append(page) }
                if page == 1 {
                    let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        entered = true
                        let c = page1EnteredCont
                        page1EnteredCont = nil
                        return c
                    }
                    cont?.resume()
                    await withCheckedContinuation { waitCont in
                        lock.withLock { releasePage1Cont = waitCont }
                    }
                }
                let base = (page - 1) * 100
                let repos: [[String: Any]] = (1...100).map { idx in
                    [
                        "id": base + idx,
                        "name": "r-\(base + idx)",
                        "owner": ["login": "alice"],
                        "private": true,
                        "visibility": "private",
                        "default_branch": "main",
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: ["total_count": 500, "repositories": repos])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let cancelTransport = CancellablePagingTransport()
        let cancelTokens = TokenManager(clientId: "Iv1.test", transport: cancelTransport, store: InMemoryTokenStore(TokenPair(access: "t")))
        let cancelClient = GitHubDiscoveryClient(transport: cancelTransport, tokens: cancelTokens)
        let pagingTask = Task {
            try await cancelClient.listRepositoriesWithTruncation(installationId: 10)
        }
        await cancelTransport.waitForPage1()
        pagingTask.cancel()
        cancelTransport.releasePage1()
        do {
            _ = try await pagingTask.value
            Issue.record("expected CancellationError when paging task was cancelled")
        } catch is CancellationError {
            // Expected.
        }
        #expect(cancelTransport.pagesSeen == [1])
    }
}

// MARK: - BN-08: /repositories/{id} guard & GraphQL databaseId verification

@Suite struct RepositoryIdRoutingAndDatabaseIdTests {
    @Test func repoTargetGuardAllowsOnlyMatchingNumericRepositoryIdAndGraphQLChecksDatabaseId() async throws {
        let target = try RepoTarget(repoId: 4242, owner: "alice", name: "notes", defaultBranch: "main")
        try target.guardURL(URL(string: "https://api.github.com/repositories/4242")!)
        try target.guardURL(URL(string: "https://api.github.com/repositories/4242/git/ref/heads/main")!)
        try target.guardURL(URL(string: "https://api.github.com/graphql")!)

        for refused in [
            "https://api.github.com/repos/alice/notes",
            "https://api.github.com/repos/alice/notes/git/ref/heads/main",
            "https://api.github.com/repositories/4243",
            "https://api.github.com/repositories/04242",
            "https://api.github.com/repositories/%34242",
            "https://api.github.com/repositories/4242/../4243",
        ] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(refused)") {
                try target.guardURL(URL(string: refused)!)
            }
        }

        // GraphQL `lastCommitDates` must select `databaseId` and reject any mismatched or missing `databaseId`.
        final class SpoofedGraphQLTransport: HTTPTransport, @unchecked Sendable {
            let databaseId: Any
            private(set) var lastQuery = ""

            init(databaseId: Any) { self.databaseId = databaseId }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                lastQuery = body?["query"] as? String ?? ""
                let reply: [String: Any] = [
                    "data": [
                        "repository": [
                            "databaseId": databaseId,
                            "object": ["f0": ["nodes": [["committedDate": "2026-01-01T00:00:00Z"]]]],
                        ],
                    ],
                ]
                let data = try JSONSerialization.data(withJSONObject: reply)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let sha = String(repeating: "a", count: 40)
        for badDbId: Any in [9999, NSNull()] {
            let spoofed = SpoofedGraphQLTransport(databaseId: badDbId)
            let tokens = TokenManager(clientId: "Iv1.test", transport: spoofed, store: InMemoryTokenStore(TokenPair(access: "t")))
            let client = GitHubHTTPClient(repo: target, transport: spoofed, tokens: tokens)
            await #expect(throws: GitHubError.repoAccessLost) {
                _ = try await client.lastCommitDates(head: sha, paths: ["note.md"])
            }
            #expect(spoofed.lastQuery.contains("databaseId"))
        }
    }
}

// MARK: - BN-09: NoteMover verifies private repository before reading or committing

@Suite struct NoteMoverPrivateRepoVerificationTests {
    @Test func noteMoverVerifiesPrivateRepoBeforeMoveAndFolderOperations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bn-mover9-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try NoteStore(root: root, deviceLabel: "mac")
        let fake = FakeGitHub(files: [("a.md", "# A\n"), ("folder/b.md", "# B\n")])
        let engine = SyncEngine(store: store, client: fake)
        await engine.sync(.manual)

        let baselineVerifies = await fake.verifyPrivateRepoCount
        await fake.setPrivate(false)
        let baselineCommits = await fake.count(.createCommit)

        let mover = NoteMover(store: store, client: fake)

        await #expect(throws: GitHubError.publicRepo) {
            _ = try await mover.moveNote("a.md", toFolder: "folder")
        }
        #expect(await fake.verifyPrivateRepoCount == baselineVerifies + 1)

        await #expect(throws: GitHubError.publicRepo) {
            _ = try await mover.moveFolder("folder", into: "")
        }
        #expect(await fake.verifyPrivateRepoCount == baselineVerifies + 2)

        await #expect(throws: GitHubError.publicRepo) {
            _ = try await mover.createFolder(named: "new-folder", in: "")
        }
        #expect(await fake.verifyPrivateRepoCount == baselineVerifies + 3)

        _ = try store.createFolder(named: "local-empty", in: "")
        await #expect(throws: GitHubError.publicRepo) {
            _ = try await mover.keepFolderOnGitHub("local-empty")
        }
        #expect(await fake.verifyPrivateRepoCount == baselineVerifies + 4)
        #expect(await fake.count(.createCommit) == baselineCommits)
    }
}

// MARK: - BN-10: DeviceFlow clamps, slow_down, verification_uri port/password, empty clientId refresh

@Suite struct DeviceFlowAndRefreshHardeningTests {
    @Test func deviceFlowClampsBoundsHandlesSlowDownRejectsPortAndPasswordAndEmptyClientIdRefreshFailsLocally() async throws {
        final class StaticJSONTransport: HTTPTransport, @unchecked Sendable {
            let objects: [[String: Any]]
            private let lock = NSLock()
            private var idx = 0
            private(set) var calls = 0

            init(_ objects: [[String: Any]]) { self.objects = objects }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let obj = lock.withLock { () -> [String: Any] in
                    calls += 1
                    let cur = objects[min(idx, objects.count - 1)]
                    idx += 1
                    return cur
                }
                let data = try JSONSerialization.data(withJSONObject: obj)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        // 1. Clamping interval >= 5 and expires_in to 1...3600.
        let lowBounds = StaticJSONTransport([[
            "device_code": "dc",
            "user_code": "ABCD-1234",
            "verification_uri": "https://github.com/login/device",
            "interval": 0,
            "expires_in": -50,
        ]])
        let lowCode = try await DeviceFlow(clientId: "Iv1.test", transport: lowBounds, sleep: { _ in }).start()
        #expect(lowCode.interval == 5)
        #expect(lowCode.expiresIn == 1)

        let highBounds = StaticJSONTransport([[
            "device_code": "dc",
            "user_code": "ABCD-1234",
            "verification_uri": "https://github.com/login/device",
            "interval": 2,
            "expires_in": 999_999,
        ]])
        let highCode = try await DeviceFlow(clientId: "Iv1.test", transport: highBounds, sleep: { _ in }).start()
        #expect(highCode.interval == 5)
        #expect(highCode.expiresIn == 3600)

        // 2. Reject verification_uri with explicit port or password.
        for badURI in [
            "https://github.com:443/login/device",
            "https://github.com:8443/login/device",
            "https://:pw@github.com/login/device",
            "https://alice:pw@github.com/login/device",
        ] {
            let t = StaticJSONTransport([[
                "device_code": "dc",
                "user_code": "ABCD-1234",
                "verification_uri": badURI,
            ]])
            await #expect(throws: DeviceFlowError.failed("verification_uri"), "\(badURI)") {
                _ = try await DeviceFlow(clientId: "Iv1.test", transport: t, sleep: { _ in }).start()
            }
        }

        // 3. `slow_down` increases interval by at least +5 even when server echoes `"interval": 5`, and respects larger echoed intervals.
        final class SleepRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var seconds: [Int64] = []
            func record(_ d: Duration) {
                lock.withLock { seconds.append(d.components.seconds) }
            }
        }
        let sleeps = SleepRecorder()
        let pollTransport = StaticJSONTransport([
            ["error": "slow_down", "interval": 5],
            ["error": "slow_down", "interval": 25],
            ["access_token": "ghu_ok", "refresh_token": "ghr_ok"],
        ])
        let startTime = Date(timeIntervalSince1970: 1_000)
        let flow = DeviceFlow(
            clientId: "Iv1.test",
            transport: pollTransport,
            sleep: { sleeps.record($0) },
            now: { startTime }
        )
        let code = DeviceCode(
            deviceCode: "dc",
            userCode: "ABCD-1234",
            verificationURI: URL(string: "https://github.com/login/device")!,
            interval: 5,
            expiresIn: 900
        )
        let pair = try await flow.waitForApproval(code)
        #expect(pair.access == "ghu_ok")
        #expect(sleeps.seconds == [5, 10, 25])

        // 4. Empty clientId refresh fails locally with zero HTTP calls.
        let zeroCallTransport = StaticJSONTransport([["access_token": "never"]])
        let emptyClientManager = TokenManager(
            clientId: "",
            transport: zeroCallTransport,
            store: InMemoryTokenStore(TokenPair(access: "ghu_old", refresh: "ghr_old"))
        )
        await #expect(throws: GitHubError.unauthorized) {
            _ = try await emptyClientManager.refresh(failed: "ghu_old")
        }
        #expect(zeroCallTransport.calls == 0)
    }
}

// MARK: - BN-11: Branch segment percent-encoding & 255-byte cap

@Suite struct BranchSegmentEncodingTests {
    @Test func getRefAndUpdateRefPercentEncodeEachBranchSegmentAndAlign255ByteCap() async throws {
        // 255-byte branch cap aligned between PathPolicy.isValidBranch and SECURITY.md.
        #expect(RepoTarget.isValidBranch(String(repeating: "b", count: 255)))
        #expect(!RepoTarget.isValidBranch(String(repeating: "b", count: 256)))

        // Valid git branch name containing characters (`"`, `<`, `>`, `{`, `}`, `|`) that require URL path percent-encoding,
        // across multiple `/`-separated segments.
        let trickyBranch = #"feat/"quote"<tag>/v{1}|2"#
        #expect(RepoTarget.isValidBranch(trickyBranch))

        let fake = FakeGitHub(files: [("note.md", "# Hi\n")])
        let http = FakeGitHubHTTP(
            fake: fake, repoId: 1111, installationId: 1, owner: "alice", name: "notes", defaultBranch: trickyBranch
        )
        let tokens = TokenManager(clientId: "Iv1.test", transport: http, store: InMemoryTokenStore(TokenPair(access: "ghu_start")))
        let repo = try RepoTarget(repoId: 1111, owner: "alice", name: "notes", defaultBranch: trickyBranch)
        let client = GitHubHTTPClient(repo: repo, transport: http, tokens: tokens)

        let ref = try await client.getRef(etag: nil)
        guard case let .head(sha, _) = ref else {
            Issue.record("expected .head ref")
            return
        }
        try await client.updateRef(to: sha)

        let urls = http.log.compactMap { $0.url?.absoluteString }
        #expect(urls == [
            "https://api.github.com/repositories/1111/git/ref/heads/feat/%22quote%22%3Ctag%3E/v%7B1%7D%7C2",
            "https://api.github.com/repositories/1111/git/refs/heads/feat/%22quote%22%3Ctag%3E/v%7B1%7D%7C2",
        ])
    }
}

// MARK: - BN-13: Empty remote bootstrap parks 422 candidate and continues in same run

@Suite struct Bootstrap422RecoveryTests {
    @Test func bootstrapEmptyRemoteParks422CandidateAndContinuesWithNextUnparkedNoteInSameRun() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-boot13-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(empty: true, isPrivate: true)
        await fake.refuseTrees(writing: "first-bad.md")

        let http = FakeGitHubHTTP(fake: fake, repoId: 1313, installationId: 13, owner: "alice", name: "empty-notes")
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let account = BrainAccount(config: AppConfig(clientId: "Iv1.test"), baseFolder: base, tokens: tokens, transport: http)
        let sel = try SelectedRepo(installationId: 13, repoId: 1313, owner: "alice", name: "empty-notes", userId: 77, userLogin: "alice")

        let session = try await BrainSession.openVerified(account: account, selection: sel, deviceLabel: "mac")
        // Initial sync marks the remote as empty (`emptyRemote == "1"`).
        await session.engine.sync(.manual)
        #expect(await fake.head.isEmpty)

        // Queue three notes locally: the first gets HTTP 422 (`GitHubError.unprocessable`), while the second and third are valid.
        _ = try session.store.save(path: "first-bad.md", text: "# Refused by server\n")
        _ = try session.store.save(path: "second-good.md", text: "# Bootstraps the repo\n")
        _ = try session.store.save(path: "third-good.md", text: "# Pushes right after\n")

        // In a SINGLE sync run, `first-bad.md` is parked in Needs attention, `second-good.md` bootstraps the empty remote,
        // and `third-good.md` pushes cleanly on top of it!
        await session.engine.sync(.background)

        #expect(!(await fake.head.isEmpty))
        #expect(session.store.status(of: "first-bad.md") == .needsAttention)
        #expect(session.store.status(of: "second-good.md") == .synced)
        #expect(session.store.status(of: "third-good.md") == .synced)
        #expect(await fake.text("second-good.md") == "# Bootstraps the repo\n")
        #expect(await fake.text("third-good.md") == "# Pushes right after\n")
        #expect(!(await fake.has("first-bad.md")))
        await session.engine.stop()
    }
}
