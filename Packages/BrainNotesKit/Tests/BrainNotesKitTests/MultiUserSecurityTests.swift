import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

// MARK: - 1. Multi-user installation isolation

@Suite struct MultiUserIsolationTests {
    @Test func userACannotSelectARepoNotInTheirInstallationList() async throws {
        let fake = FakeGitHub(files: [("note.md", "# Private\n")])
        let http = FakeGitHubHTTP(
            fake: fake,
            repoId: 5001,
            installationId: 901,
            owner: "alice",
            name: "alice-brain",
            defaultBranch: "main",
            isPrivate: true
        )
        let store = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let tokens = TokenManager(clientId: "Iv1.test", transport: http, store: store)
        let discovery = GitHubDiscoveryClient(transport: http, tokens: tokens)

        // Valid selection succeeds.
        let valid = try SelectedRepo(installationId: 901, repoId: 5001, owner: "alice", name: "alice-brain")
        let verified = try await discovery.verifySelection(valid)
        #expect(verified == valid)

        // Different repoId, same owner/name -> refused (never trust owner/name alone).
        let wrongId = try SelectedRepo(installationId: 901, repoId: 9999, owner: "alice", name: "alice-brain")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await discovery.verifySelection(wrongId)
        }

        // Same repoId, different owner -> refused.
        let wrongOwner = try SelectedRepo(installationId: 901, repoId: 5001, owner: "bob", name: "alice-brain")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await discovery.verifySelection(wrongOwner)
        }

        // Same repoId, different repo name -> refused.
        let wrongName = try SelectedRepo(installationId: 901, repoId: 5001, owner: "alice", name: "other-notes")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await discovery.verifySelection(wrongName)
        }

        // Case variant of owner or name -> refused (byte-exact comparison via sameBytes).
        let caseOwner = try SelectedRepo(installationId: 901, repoId: 5001, owner: "Alice", name: "alice-brain")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await discovery.verifySelection(caseOwner)
        }
        let caseName = try SelectedRepo(installationId: 901, repoId: 5001, owner: "alice", name: "Alice-Brain")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await discovery.verifySelection(caseName)
        }

        // Repo belonging to another user's installation not returned by GET /user/installations -> refused.
        let bobRepo = try SelectedRepo(installationId: 7777, repoId: 8888, owner: "bob", name: "bob-brain")
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await discovery.verifySelection(bobRepo)
        }
    }

    @Test func sessionForPickedRepoRefusesRequestsToAnyOtherRepo() throws {
        struct NoNetworkTransport: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = InMemoryTokenStore(TokenPair(access: "ghu_a", refresh: "ghr_a"))
        let tokens = TokenManager(clientId: "Iv1.test", transport: NoNetworkTransport(), store: store)
        let picked = try RepoTarget(repoId: 5001, owner: "alice", name: "alice-brain", defaultBranch: "main")
        let client = GitHubHTTPClient(repo: picked, transport: NoNetworkTransport(), tokens: tokens)

        // Picked repo and GraphQL pass the per-request guard.
        _ = try client.request("GET", "repos/alice/alice-brain/git/ref/heads/main")
        _ = try client.request("POST", "graphql")

        // Every other repo, owner, case variant, traversal, or discovery path is refused by RepoTarget.guardURL.
        for forbidden in [
            "repos/alice/other-repo/git/ref/heads/main",
            "repos/bob/alice-brain/git/ref/heads/main",
            "repos/Alice/alice-brain/git/ref/heads/main",
            "repos/alice/alice-brain/../other-repo/git/ref/heads/main",
            "repos/alice/alice-brain/%2e%2e/other-repo",
            "repositories/5001/git/ref/heads/main",
            "user",
            "user/repos",
            "user/installations",
            "orgs/alice/repos",
        ] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(forbidden)") {
                _ = try client.request("GET", forbidden)
            }
        }
    }

    @Test func storedSelectionNoLongerListedIsRefusedAtSessionOpenAndDuringSync() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-iso-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(files: [("inbox.md", "# Hello\n")])
        let http = FakeGitHubHTTP(
            fake: fake,
            repoId: 6100,
            installationId: 310,
            owner: "alice",
            name: "notes",
            defaultBranch: "main",
            isPrivate: true,
            listedInInstallation: true
        )
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let config = AppConfig(clientId: "Iv1.test")
        let selection = try SelectedRepo(installationId: 310, repoId: 6100, owner: "alice", name: "notes")

        // Session opens and syncs while the repo is in the user's installation.
        let session = try await BrainSession.openVerified(
            config: config, selection: selection, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: http
        )
        await session.engine.sync(.manual)
        let snap1 = await session.engine.snapshot
        #expect(snap1.state == .idle)
        #expect(try session.store.read("inbox.md") == "# Hello\n")

        // User removes the repo from the GitHub App installation on GitHub -> sync gets 404 and re-verifies installation.
        http.setListedInInstallation(false)
        await session.engine.sync(.manual)
        let snap2 = await session.engine.snapshot
        #expect(snap2.state == .accessLost)
        await session.engine.stop()

        // Next session open with the persisted selection also refuses to open because it is no longer listed.
        let persisted = try #require(try SelectedRepoStore(baseFolder: base).load())
        await #expect(throws: SelectionVerificationError.notListed) {
            _ = try await BrainSession.openVerified(
                config: config, selection: persisted, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: http
            )
        }
    }
}

// MARK: - 2. Public repository refusal

@Suite struct PublicRepoRefusalTests {
    private static let expectedPublicMessage =
        "This notes repository is public, so anyone on the internet can read it. Brain Notes only opens private ones. Make it private on GitHub, then try again."

    @Test func publicRepoIsRefusedInPickerAtSessionOpenAndAtEverySyncStart() async throws {
        #expect(RepoTarget.publicRepoMessage == Self.expectedPublicMessage)

        // 1. Picker: DiscoveredRepo keeps public repos visible for greyed-out explanation, but select() refuses them.
        let publicDiscovered = try DiscoveredRepo(
            installationId: 10, repoId: 200, owner: "alice", name: "public-notes", defaultBranch: "main", isPrivate: false
        )
        #expect(!publicDiscovered.isPrivate)
        #expect(throws: RepoTarget.GuardError.publicRepo) {
            _ = try publicDiscovered.select()
        }
        #expect(throws: RepoTarget.GuardError.publicRepo) {
            _ = try RepoTarget(repoId: 200, owner: "alice", name: "public-notes", defaultBranch: "main", isPrivate: false)
        }

        // 2. Session open: if a previously private selection was flipped to public on GitHub, openVerified refuses it.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-pub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fake = FakeGitHub(files: [("a.md", "# A\n")])
        await fake.setPrivate(false)
        let http = FakeGitHubHTTP(
            fake: fake, repoId: 200, installationId: 10, owner: "alice", name: "public-notes", isPrivate: false
        )
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let storedSelection = try SelectedRepo(installationId: 10, repoId: 200, owner: "alice", name: "public-notes")

        await #expect(throws: SelectionVerificationError.publicRepo) {
            _ = try await BrainSession.openVerified(
                config: AppConfig(clientId: "Iv1.test"),
                selection: storedSelection,
                baseFolder: base,
                deviceLabel: "mac",
                tokens: tokens,
                transport: http
            )
        }

        // 3. Sync start: if a repo becomes public after the session opened, the next sync refuses it before reading/pushing notes.
        http.setRepoPrivate(true)
        await fake.setPrivate(true)
        let session = try await BrainSession.openVerified(
            config: AppConfig(clientId: "Iv1.test"),
            selection: storedSelection,
            baseFolder: base,
            deviceLabel: "mac",
            tokens: tokens,
            transport: http
        )
        await session.engine.sync(.manual)
        #expect((await session.engine.snapshot).state == .idle)

        // Flip repo to public on GitHub and attempt to sync a new local note.
        http.setRepoPrivate(false)
        try session.store.save(path: "_inbox/secret-thought.md", text: "# Never push to public\n")
        await session.engine.sync(.manual)
        #expect((await session.engine.snapshot).state == .publicRepo)
        // Confirm the local note was NOT pushed to the remote repo.
        #expect(await fake.count(.createCommit) == 0)
        await session.engine.stop()
    }

    @Test func visibilityMismatchEvenWithPrivateTrueIsRefused() async throws {
        // GitHub Enterprise / org internal repos can have `private: true` with `visibility: "internal"`.
        // Brain Notes requires BOTH `private == true` AND `visibility == "private"` (when present).
        final class VisibilityTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                let body: [String: Any]
                switch url.path {
                case "/user/installations":
                    body = ["total_count": 1, "installations": [["id": 5, "account": ["login": "acme"]]]]
                case "/user/installations/5/repositories":
                    body = [
                        "total_count": 1,
                        "repositories": [[
                            "id": 99,
                            "name": "internal-notes",
                            "owner": ["login": "acme"],
                            "private": true,
                            "visibility": "internal",
                            "default_branch": "main",
                        ]],
                    ]
                case "/repos/acme/internal-notes":
                    body = [
                        "id": 99,
                        "name": "internal-notes",
                        "owner": ["login": "acme"],
                        "private": true,
                        "visibility": "internal",
                        "default_branch": "main",
                        "size": 10,
                    ]
                default:
                    Issue.record("unexpected path \(url.path)")
                    throw URLError(.badURL)
                }
                let data = try JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let transport = VisibilityTransport()
        let tokens = TokenManager(clientId: "Iv1.test", transport: transport, store: InMemoryTokenStore(TokenPair(access: "t")))
        let discovery = GitHubDiscoveryClient(transport: transport, tokens: tokens)
        let result = try await discovery.listAccessibleRepositories()
        #expect(result.repositories.count == 1)
        #expect(result.repositories[0].isPrivate == false)
        #expect(result.privateRepositories.isEmpty)

        let sel = try SelectedRepo(installationId: 5, repoId: 99, owner: "acme", name: "internal-notes")
        await #expect(throws: SelectionVerificationError.publicRepo) {
            _ = try await discovery.verifySelection(sel)
        }

        let target = try RepoTarget(repoId: 99, owner: "acme", name: "internal-notes")
        let client = GitHubHTTPClient(repo: target, transport: transport, tokens: tokens)
        await #expect(throws: GitHubError.publicRepo) {
            try await client.verifyPrivateRepo()
        }
    }
}

// MARK: - 3. Repository switch wipe & unsynced-edits check

@Suite struct RepoSwitchWipeTests {
    @Test func switchingReposWipesOldRepoLocalDataWhileKeepingTokens() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fakeA = FakeGitHub(files: [("work/plan.md", "# Plan A\nalpha\n")])
        let httpA = FakeGitHubHTTP(
            fake: fakeA, repoId: 1001, installationId: 11, owner: "alice", name: "brain-a", defaultBranch: "main"
        )
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let config = AppConfig(clientId: "Iv1.test")
        let selA = try SelectedRepo(installationId: 11, repoId: 1001, owner: "alice", name: "brain-a")

        let sessionA = try await BrainSession.openVerified(
            config: config, selection: selA, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: httpA
        )
        await sessionA.engine.sync(.manual)
        try sessionA.store.save(path: "_inbox/draft-a.md", text: "# Local draft in A\n")
        try FilePinsStore(store: sessionA.store).update { $0.append("work/plan.md") }

        let rootA = sessionA.store.root
        #expect(rootA.lastPathComponent == "1001")
        #expect(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("files/work/plan.md").path))
        #expect(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("journal.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("pins.json").path))
        #expect(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("index").path))
        #expect(try SelectedRepoStore(baseFolder: base).load() == selA)
        #expect(sessionA.hasUnsyncedEdits)

        // Wipe old repo BEFORE opening the picker / second repo.
        try await sessionA.wipeForRepoSwitch()

        // Old repo's folder (files, journal + -wal/-shm, pins.json, staging, search index) and selection are gone.
        #expect(!FileManager.default.fileExists(atPath: rootA.path))
        #expect(!FileManager.default.fileExists(atPath: rootA.appendingPathComponent("journal.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: rootA.appendingPathComponent("journal.sqlite-wal").path))
        #expect(!FileManager.default.fileExists(atPath: rootA.appendingPathComponent("journal.sqlite-shm").path))
        #expect(!FileManager.default.fileExists(atPath: rootA.appendingPathComponent("pins.json").path))
        #expect(!FileManager.default.fileExists(atPath: rootA.appendingPathComponent("index").path))
        #expect(try SelectedRepoStore(baseFolder: base).load() == nil)

        // Tokens remain intact because the user is still signed in.
        #expect(try tokens.load() != nil)

        // Open second repo with the preserved tokens; its local data lives in Brain/2002 with zero trace of A.
        let fakeB = FakeGitHub(files: [("ideas/next.md", "# Next B\nbeta\n")])
        let httpB = FakeGitHubHTTP(
            fake: fakeB, repoId: 2002, installationId: 11, owner: "alice", name: "brain-b", defaultBranch: "main"
        )
        let selB = try SelectedRepo(installationId: 11, repoId: 2002, owner: "alice", name: "brain-b")
        let sessionB = try await BrainSession.openVerified(
            config: config, selection: selB, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: httpB
        )
        await sessionB.engine.sync(.manual)
        #expect(sessionB.store.root.lastPathComponent == "2002")
        #expect(!FileManager.default.fileExists(atPath: rootA.path))
        #expect(try sessionB.store.read("work/plan.md") == nil)
        #expect(try sessionB.store.read("ideas/next.md") == "# Next B\nbeta\n")
        #expect(try SelectedRepoStore(baseFolder: base).load() == selB)
        await sessionB.engine.stop()
    }

    @Test func unsyncedEditsAreDetectedBeforeRepoSwitch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-unsynced-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(files: [("a.md", "# A\n")])
        let http = FakeGitHubHTTP(fake: fake, repoId: 3001, installationId: 12, owner: "alice", name: "notes")
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let sel = try SelectedRepo(installationId: 12, repoId: 3001, owner: "alice", name: "notes")

        let session = try await BrainSession.openVerified(
            config: AppConfig(clientId: "Iv1.test"), selection: sel, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: http
        )
        await session.engine.sync(.manual)
        #expect(!session.hasUnsyncedEdits)

        try session.store.save(path: "a.md", text: "# A\nlocal unsynced change\n")
        #expect(session.hasUnsyncedEdits)

        await session.engine.sync(.background)
        #expect(!session.hasUnsyncedEdits)
        await session.engine.stop()
    }
}

// MARK: - 4. Default branch validation & propagation

@Suite struct DefaultBranchPolicyTests {
    @Test func nonMainDefaultBranchIsUsedEverywhereAndRefreshedOnSessionOpen() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-branch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(files: [("journal.md", "# Trunk note\n")])
        let http = FakeGitHubHTTP(
            fake: fake,
            repoId: 7700,
            installationId: 44,
            owner: "alice",
            name: "trunk-notes",
            defaultBranch: "trunk"
        )
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        // Stored selection had stale branch "main"; openVerified refreshes it to "trunk" from the installation API.
        let stale = try SelectedRepo(installationId: 44, repoId: 7700, owner: "alice", name: "trunk-notes", defaultBranch: "main")
        let session = try await BrainSession.openVerified(
            config: AppConfig(clientId: "Iv1.test"), selection: stale, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: http
        )
        #expect(session.repo.defaultBranch == "trunk")
        #expect(try SelectedRepoStore(baseFolder: base).load()?.defaultBranch == "trunk")

        await session.engine.sync(.manual)
        #expect(try session.store.read("journal.md") == "# Trunk note\n")

        // Push an edit and inspect every REST request path to confirm "trunk" was used and "main" never appeared.
        try session.store.save(path: "journal.md", text: "# Trunk note\nupdated on trunk\n")
        await session.engine.sync(.background)
        #expect(session.store.status(of: "journal.md") == .synced)

        let paths = http.log.compactMap { $0.url?.path }
        #expect(paths.contains("/repos/alice/trunk-notes/git/ref/heads/trunk"))
        #expect(paths.contains("/repos/alice/trunk-notes/git/refs/heads/trunk"))
        #expect(!paths.contains { $0.contains("/heads/main") })
        await session.engine.stop()
    }

    @Test func slashInValidBranchNameWorksAndMaliciousBranchesAreRejected() throws {
        // Multi-segment git branch names like "notes/primary" or "release-1.0" are valid git refs.
        for valid in ["main", "trunk", "master", "notes/primary", "v1.2_main"] {
            #expect(RepoTarget.isValidBranch(valid), "expected valid branch: \(valid)")
            let r = try RepoTarget(repoId: 1, owner: "alice", name: "notes", defaultBranch: valid)
            #expect(r.defaultBranch == valid)
        }

        // Malicious or invalid git ref names are rejected.
        let malicious = [
            "",
            "..",
            "a..b",
            "../main",
            "heads/../tags/v1",
            "-lead",
            "main ",
            " main",
            "main\n",
            "main\r",
            "main\t",
            "main\u{0000}",
            "main\u{007F}",
            "main~1",
            "main^",
            "main:sub",
            "main?x",
            "main*x",
            "main[0]",
            "main\\x",
            "main/",
            "/main",
            "a//b",
            ".hidden",
            "a/.hidden",
            "a/./b",
            "main.",
            "main.lock",
            "heads/main.lock",
            "@",
            "main@{0}",
            "%2e%2e",
            "m\u{0430}in",  // Cyrillic 'а'
            String(repeating: "b", count: 256),
        ]
        for bad in malicious {
            #expect(!RepoTarget.isValidBranch(bad), "expected rejected branch: \(bad.debugDescription)")
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(bad.debugDescription)") {
                _ = try RepoTarget(repoId: 1, owner: "alice", name: "notes", defaultBranch: bad)
            }
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(bad.debugDescription)") {
                _ = try SelectedRepo(installationId: 1, repoId: 1, owner: "alice", name: "notes", defaultBranch: bad)
            }
        }
    }
}

// MARK: - 5. Malicious owner, repo name, IDs, and persisted JSON

@Suite struct MaliciousOwnerAndRepoNameTests {
    @Test func maliciousOwnersAndRepoNamesAreRejected() throws {
        let badOwners = [
            "",
            "../x",
            "a/b",
            " owner",
            "owner ",
            "ow ner",
            "%2e%2e",
            "\u{0430}lice",  // Cyrillic small letter 'а' (homoglyph)
            ".",
            "..",
            "-lead",
            "trail-",
            "a--b",
            "owner.name",
            "owner_name",
            "owner\n",
            String(repeating: "a", count: 40),
        ]
        for bad in badOwners {
            #expect(!RepoTarget.isValidOwner(bad), "owner should fail: \(bad.debugDescription)")
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "owner: \(bad.debugDescription)") {
                _ = try RepoTarget(repoId: 1, owner: bad, name: "notes")
            }
        }

        let badNames = [
            "",
            "../x",
            "a/b",
            " repo",
            "repo ",
            "re po",
            "%2e%2e",
            "br\u{0430}in",  // Cyrillic small letter 'а' (homoglyph)
            ".",
            "..",
            "x.git",
            "x.GIT",
            "notes.Git",
            "repo\n",
            "repo\\x",
            String(repeating: "r", count: 101),
        ]
        for bad in badNames {
            #expect(!RepoTarget.isValidRepoName(bad), "name should fail: \(bad.debugDescription)")
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "name: \(bad.debugDescription)") {
                _ = try RepoTarget(repoId: 1, owner: "alice", name: bad)
            }
        }

        // Valid edge cases for owner (39 chars, internal single hyphen) and repo name (leading '-', '_', '.', '.github').
        #expect(RepoTarget.isValidOwner("a-b-c-123"))
        #expect(RepoTarget.isValidOwner(String(repeating: "a", count: 39)))
        #expect(RepoTarget.isValidRepoName(".github"))
        #expect(RepoTarget.isValidRepoName("_notes-2026.backup"))
        #expect(RepoTarget.isValidRepoName(String(repeating: "r", count: 100)))

        // Non-positive repoId or installationId rejected.
        for badId: Int64 in [0, -1, .min] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
                _ = try RepoTarget(repoId: badId, owner: "alice", name: "notes")
            }
            #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
                _ = try SelectedRepo(installationId: badId, repoId: 1, owner: "alice", name: "notes")
            }
            #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
                _ = try SelectedRepo(installationId: 1, repoId: badId, owner: "alice", name: "notes")
            }
        }

        // Tampered JSON on disk is also rejected on decode.
        let tampered = Data(#"{"installationId":1,"repoId":1,"owner":"../evil","name":"notes.git","defaultBranch":"main"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SelectedRepo.self, from: tampered)
        }
    }
}

// MARK: - 6. Discovery guard & reply/pagination caps

@Suite struct DiscoveryGuardAndLimitsTests {
    @Test func onlyTheThreeDiscoveryEndpointsPassTheGuard() throws {
        let allowed = [
            "https://api.github.com/user",
            "https://api.github.com/user/installations",
            "https://api.github.com/user/installations?per_page=100&page=1",
            "https://api.github.com/user/installations/1/repositories",
            "https://api.github.com/user/installations/987654321/repositories?per_page=50&page=2",
        ]
        for u in allowed {
            var req = URLRequest(url: URL(string: u)!)
            req.httpMethod = "GET"
            try DiscoveryGuard.guardRequest(req)
        }

        // Non-GET methods and GET with body are refused even on allowed URLs.
        for method in ["POST", "PUT", "PATCH", "DELETE", "HEAD"] {
            var req = URLRequest(url: URL(string: "https://api.github.com/user/installations")!)
            req.httpMethod = method
            #expect(throws: DiscoveryGuard.GuardError.endpointNotAllowed, "\(method)") {
                try DiscoveryGuard.guardRequest(req)
            }
        }
        var getWithBody = URLRequest(url: URL(string: "https://api.github.com/user")!)
        getWithBody.httpMethod = "GET"
        getWithBody.httpBody = Data("{}".utf8)
        #expect(throws: DiscoveryGuard.GuardError.endpointNotAllowed) {
            try DiscoveryGuard.guardRequest(getWithBody)
        }

        // Every other endpoint, host, scheme, non-numeric installation ID, or unexpected query is refused.
        let refused = [
            "https://api.github.com/user?page=1",
            "https://api.github.com/user/repos",
            "https://api.github.com/user/orgs",
            "https://api.github.com/orgs/acme/repos",
            "https://api.github.com/repos/alice/notes",
            "https://api.github.com/graphql",
            "https://api.github.com/user/installations/0/repositories",
            "https://api.github.com/user/installations/-5/repositories",
            "https://api.github.com/user/installations/01/repositories",
            "https://api.github.com/user/installations/abc/repositories",
            "https://api.github.com/user/installations/123/repositories/extra",
            "https://api.github.com/user/installations/123",
            "https://api.github.com/user/installations?visibility=all",
            "https://api.github.com/user/installations?per_page=101",
            "https://api.github.com/user/installations?per_page=0",
            "https://api.github.com/user/installations?page=0",
            "https://api.github.com/user/installations?page=1&page=2",
            "https://api.github.com/user/installations?",
            "https://api.github.com/user/%2e%2e/repos",
            "https://api.github.com/user//installations",
            "http://api.github.com/user",
            "https://github.com/user",
            "https://evil.example/user/installations",
            "https://token@api.github.com/user",
            "https://api.github.com:8443/user",
            "https://api.github.com/user#frag",
        ]
        for u in refused {
            var req = URLRequest(url: URL(string: u)!)
            req.httpMethod = "GET"
            #expect(throws: DiscoveryGuard.GuardError.endpointNotAllowed, "\(u)") {
                try DiscoveryGuard.guardRequest(req)
            }
        }
    }

    @Test func discoveryAppliesReplySizeCapsAndHardPaginationCap() async throws {
        // 1. ReplyLimit.json (32 MiB) enforced on discovery responses.
        struct OversizedDiscovery: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": String(ReplyLimit.json + 1)]
                )!
                return (Data(), http)
            }
        }
        let overTokens = TokenManager(clientId: "Iv1.test", transport: OversizedDiscovery(), store: InMemoryTokenStore(TokenPair(access: "t")))
        let overClient = GitHubDiscoveryClient(transport: OversizedDiscovery(), tokens: overTokens)
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.json)) {
            _ = try await overClient.listInstallations()
        }

        // 2. Pagination stops at maxPages even if server keeps returning full pages of 100 items.
        final class EndlessPages: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls = 0

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let pageNumber = lock.withLock { () -> Int in
                    calls += 1
                    return calls
                }
                let base = (pageNumber - 1) * 100
                let items: [[String: Any]] = (1...100).map { i in
                    ["id": base + i, "account": ["login": "alice"]]
                }
                let data = try JSONSerialization.data(withJSONObject: ["total_count": 99_999, "installations": items])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let endless = EndlessPages()
        let pageTokens = TokenManager(clientId: "Iv1.test", transport: endless, store: InMemoryTokenStore(TokenPair(access: "t")))
        let capped = GitHubDiscoveryClient(transport: endless, tokens: pageTokens, maxPages: 3)
        let list = try await capped.listInstallations()
        #expect(endless.calls == 3)
        #expect(list.count == 300)
    }
}

// MARK: - 7. Device flow helper & AppConfig URL validation

@Suite struct DeviceFlowAndAppConfigSecurityTests {
    @Test func deviceFlowExposesUserCodeForCopyAndNeverSendsClientSecret() async throws {
        let fake = FakeGitHub()
        let http = FakeGitHubHTTP(fake: fake)
        http.devicePollAnswers = [
            ["access_token": "ghu_fresh", "refresh_token": "ghr_fresh", "token_type": "bearer"],
        ]
        let flow = DeviceFlow(clientId: "Iv1.publicClient", transport: http, sleep: { _ in })
        let code = try await flow.start()
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.verificationURI.absoluteString == "https://github.com/login/device")

        let pair = try await flow.waitForApproval(code)
        #expect(pair.access == "ghu_fresh")
        #expect(pair.refresh == "ghr_fresh")

        #expect(http.log.count == 2)
        for req in http.log {
            let url = req.url?.absoluteString ?? ""
            let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
            #expect(!url.localizedCaseInsensitiveContains("secret"))
            #expect(!body.localizedCaseInsensitiveContains("secret"))
            for (k, v) in req.allHTTPHeaderFields ?? [:] {
                #expect(!k.localizedCaseInsensitiveContains("secret"))
                #expect(!v.localizedCaseInsensitiveContains("secret"))
            }
        }
    }

    @Test func appConfigValidatesSlugAndBuildsInstallAndCreateURLs() throws {
        let def = AppConfig(info: ["BNGitHubClientID": "Iv1.abc"])
        #expect(def.clientId == "Iv1.abc")
        #expect(def.appSlug == "brain-notes-app")
        #expect(try def.installAppURL().absoluteString == "https://github.com/apps/brain-notes-app/installations/new")
        #expect(AppConfig.createBrainURL.absoluteString == "https://github.com/new?name=brain&visibility=private&description=My%20Brain%20Notes")

        for badSlug in ["Brain-Notes", "../evil", "a/b", "slug with space", "slug?x=1", String(repeating: "a", count: 101)] {
            let cfg = AppConfig(clientId: "Iv1.abc", appSlug: badSlug)
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(badSlug)") {
                _ = try cfg.installAppURL()
            }
        }
    }
}

// MARK: - 8. Empty repository (0 commits) first sync & initial commit bootstrap

@Suite struct EmptyRepoSupportTests {
    @Test func emptyRepository409SyncsCleanlyAndBootstrapsFirstCommitOnSave() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-empty409-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fake = FakeGitHub(empty: true, isPrivate: true)
        let http = FakeGitHubHTTP(
            fake: fake, repoId: 8801, installationId: 55, owner: "alice", name: "fresh-brain", defaultBranch: "trunk"
        )
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let sel = try SelectedRepo(installationId: 55, repoId: 8801, owner: "alice", name: "fresh-brain", defaultBranch: "trunk")

        let session = try await BrainSession.openVerified(
            config: AppConfig(clientId: "Iv1.test"), selection: sel, baseFolder: base, deviceLabel: "iphone", tokens: tokens, transport: http
        )

        // First sync on a brand-new empty repo finishes cleanly with 0 notes, hasFirstSynced == true, no crash or loop.
        await session.engine.sync(.manual)
        let afterFirst = await session.engine.snapshot
        #expect(afterFirst.state == .idle)
        #expect(afterFirst.hasFirstSynced)
        #expect(await session.store.index.allPaths().isEmpty)

        // SecretScan still protects the very first note on an empty repo!
        let fakeSecret = "ghp_" + String(repeating: "A", count: 36)
        try session.store.save(path: "_inbox/leaked.md", text: "# Token\n\(fakeSecret)\n")
        await session.engine.sync(.background)
        #expect(await fake.head.isEmpty, "secret note must not bootstrap the remote repo")
        #expect(session.store.status(of: "_inbox/leaked.md") == .needsAttention)
        try session.store.delete(path: "_inbox/leaked.md")
        // Resolve the attention item and clear the trashed secret note from local test state before testing normal bootstrap.
        for item in session.store.journal.attention() {
            try session.store.journal.resolveAttention(id: item.id)
        }

        // Write a clean first note and sync: bootstraps the initial commit on "trunk" via Contents API, then pushes any remaining ops.
        let cleanSessionBase = FileManager.default.temporaryDirectory.appendingPathComponent("bn-empty409b-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cleanSessionBase) }
        let cleanSession = try await BrainSession.openVerified(
            config: AppConfig(clientId: "Iv1.test"), selection: sel, baseFolder: cleanSessionBase, deviceLabel: "iphone", tokens: tokens, transport: http
        )
        await cleanSession.engine.sync(.manual)
        let createdPath = try cleanSession.store.createNote(folder: nil, text: "# My first thought\nWelcome to my brain.\n")
        await cleanSession.engine.sync(.background)

        #expect(!(await fake.head.isEmpty))
        #expect(cleanSession.store.status(of: createdPath) == .synced)
        #expect(cleanSession.store.journal.baseCommit != nil)

        // Subsequent note edits use ordinary Git Data commits on top of the bootstrapped commit.
        try cleanSession.store.save(path: "projects/roadmap.md", text: "# Roadmap\nStep 2\n")
        await cleanSession.engine.sync(.background)
        #expect(cleanSession.store.status(of: "projects/roadmap.md") == .synced)
        #expect(await fake.count(.createCommit) == 1)

        await session.engine.stop()
        await cleanSession.engine.stop()
    }

    @Test func emptyRepositoryReturning404WithSizeZeroIsHandledGracefully() async throws {
        // GitHub can also return 404 on `git/ref/heads/<branch>` when the default branch has not been created yet,
        // while `GET /repos/<owner>/<name>` returns 200 with `size == 0` and `private == true`.
        final class Empty404Transport: HTTPTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                let status: Int
                let body: [String: Any]
                switch url.path {
                case "/user/installations":
                    status = 200
                    body = ["total_count": 1, "installations": [["id": 8, "account": ["login": "alice"]]]]
                case "/user/installations/8/repositories":
                    status = 200
                    body = [
                        "total_count": 1,
                        "repositories": [[
                            "id": 4040,
                            "name": "brand-new",
                            "owner": ["login": "alice"],
                            "private": true,
                            "visibility": "private",
                            "default_branch": "main",
                            "size": 0,
                        ]],
                    ]
                case "/repos/alice/brand-new":
                    status = 200
                    body = [
                        "id": 4040,
                        "name": "brand-new",
                        "owner": ["login": "alice"],
                        "private": true,
                        "visibility": "private",
                        "default_branch": "main",
                        "size": 0,
                    ]
                case "/repos/alice/brand-new/git/ref/heads/main":
                    status = 404
                    body = ["message": "Not Found"]
                default:
                    Issue.record("unexpected path \(url.path)")
                    throw URLError(.badURL)
                }
                let data = try JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-empty404-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let transport = Empty404Transport()
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_ok"))
        let sel = try SelectedRepo(installationId: 8, repoId: 4040, owner: "alice", name: "brand-new")

        let session = try await BrainSession.openVerified(
            config: AppConfig(clientId: "Iv1.test"), selection: sel, baseFolder: base, deviceLabel: "mac", tokens: tokens, transport: transport
        )
        await session.engine.sync(.manual)
        let snap = await session.engine.snapshot
        #expect(snap.state == .idle)
        #expect(snap.hasFirstSynced)
        #expect(await session.store.index.allPaths().isEmpty)
        await session.engine.stop()
    }
}
