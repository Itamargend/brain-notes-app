import BrainMerge
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

/// Audit F-8. No answer from GitHub is read without a cap: the tarball and a blob have their own, every other API
/// answer `ReplyLimit.json`, a sign-in or token answer `ReplyLimit.oauth`.
@Suite struct ReplyLimitTests {
    /// Records the cap each request is sent with. The client must never use the uncapped `send(_:)`.
    final class CapRecorder: HTTPTransport, @unchecked Sendable {
        let inner: FakeGitHubHTTP
        private let lock = NSLock()
        private var caps: [(path: String, cap: Int?)] = []
        init(_ inner: FakeGitHubHTTP) { self.inner = inner }
        var recorded: [(path: String, cap: Int?)] { lock.withLock { caps } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { caps.append((request.url?.path ?? "", nil)) }
            return try await inner.send(request)
        }

        func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { caps.append((request.url?.path ?? "", maxBytes)) }
            let (data, http) = try await inner.send(request)
            guard data.count <= maxBytes else { throw RepoTooLarge(.download, max: maxBytes) }
            return (data, http)
        }
    }

    @Test func everyRequestOfASyncIsCapped() async throws {
        let fake = FakeGitHub(files: Harness.seed)
        let http = FakeGitHubHTTP(fake: fake)
        let recorder = CapRecorder(http)
        let manager = TokenManager(clientId: "c", transport: recorder,
                                   store: InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start")))
        let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: recorder, tokens: manager)
        let h = try Harness(fake: fake, client: client)
        #expect(await h.sync() == .idle)  // first sync: ref, commit, tree, tarball, dates
        try h.store.save(path: "todo.md", text: "# Todo\npushed\n")
        #expect(await h.sync() == .idle)  // a push: tree, commit, ref
        await fake.commitRemote([("notes/beta.md", "# Beta\nfrom elsewhere\n")])
        http.expireAccessTokens()
        #expect(await h.sync() == .idle)  // a refresh, then a pull: compare, blob
        #expect(h.local("notes/beta.md") == "# Beta\nfrom elsewhere\n")

        let flow = DeviceFlow(clientId: "c", transport: recorder, sleep: { _ in }, now: { Date(timeIntervalSince1970: 0) })
        http.devicePollAnswers = [["access_token": "ghu_new"]]
        _ = try await flow.waitForApproval(try await flow.start())

        let seen = recorder.recorded
        for path in ["/tarball/", "/git/blobs/", "/compare/", "/git/trees", "/git/commits", "/git/refs/heads/main", "/git/ref/heads/main",
                     "/graphql", "/login/oauth/access_token", "/login/device/code"] {
            #expect(seen.contains { $0.path.contains(path) }, "\(path) was asked for")
        }
        for (path, cap) in seen {
            let expected: Int
            if path.contains("/tarball/") {
                expected = FirstSyncLimits.standard.maxDownloadBytes
            } else if path.contains("/git/blobs/") {
                expected = GitHubHTTPClient.blobReplyCap(forBlobBytes: FirstSyncLimits.standard.maxEntryBytes)
            } else if path.hasPrefix("/login/") {
                expected = ReplyLimit.oauth
            } else {
                expected = ReplyLimit.json
            }
            #expect(cap == expected, "\(path)")
        }
        #expect(ReplyLimit.json == 32 << 20)
        #expect(ReplyLimit.oauth == 64 << 10)
    }

    /// Answers every request with this Content-Length and a short body: a reply that says it is longer than the cap is
    /// refused before any of it is read.
    struct Declares: HTTPTransport {
        var length: Int
        var body = Data("{}".utf8)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Length": String(length), "Content-Type": "application/json"])!)
        }
    }

    @Test func anOversizeAPIReplyIsRefused() async throws {
        func client(_ t: HTTPTransport) throws -> GitHubHTTPClient {
            let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore(TokenPair(access: "a")))
            return try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: t, tokens: m)
        }
        let sha = String(repeating: "a", count: 40)
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.json)) { try await client(Declares(length: ReplyLimit.json + 1)).getRef(etag: nil) }
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.json)) {
            try await client(Declares(length: ReplyLimit.json + 1)).compare(base: sha, head: sha)
        }
        await #expect(throws: RepoTooLarge(.download, max: ReplyLimit.json)) { try await client(Declares(length: ReplyLimit.json + 1)).tree(sha) }
        // At the cap it is read as usual.
        let ok = Data("{\"ref\":\"refs/heads/main\",\"object\":{\"sha\":\"\(sha)\"}}".utf8)
        #expect(try await client(Declares(length: ok.count, body: ok)).getRef(etag: nil) == .head(sha: sha, etag: nil))
    }

    /// A comparison too large to read stops sync with the "too large" state, as a first sync past a limit does, instead
    /// of filling memory or retrying the same download in a loop.
    @Test func aPullWithAnOversizeComparisonStops() async throws {
        struct BigCompare: HTTPTransport {
            let inner: FakeGitHubHTTP
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                guard request.url?.path.contains("/compare/") == true else { return try await inner.send(request) }
                return try await Declares(length: ReplyLimit.json + 1).send(request)
            }
        }
        let fake = FakeGitHub(files: Harness.seed)
        let transport = BigCompare(inner: FakeGitHubHTTP(fake: fake))
        let manager = TokenManager(clientId: "c", transport: transport,
                                   store: InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start")))
        let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: transport, tokens: manager)
        let h = try Harness(fake: fake, client: client)
        #expect(await h.sync() == .idle)
        await fake.commitRemote([("notes/beta.md", "# Beta\nnew\n")])
        #expect(await h.sync() == .repoTooLarge(RepoTooLarge(.download, max: ReplyLimit.json)))
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n", "nothing applied")
    }

    @Test func anOversizeTokenAnswerIsABadResponseNotASignOut() async throws {
        let manager = TokenManager(clientId: "c", transport: Declares(length: ReplyLimit.oauth + 1),
                                   store: InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start")))
        await #expect(throws: GitHubError.badResponse("token")) { try await manager.refresh(failed: "ghu_start") }
    }

    @Test func anOversizeSignInAnswerIsNoAnswer() async throws {
        // Asking for a code: refused as a broken answer.
        await #expect(throws: DeviceFlowError.failed("response")) {
            try await DeviceFlow(clientId: "c", transport: Declares(length: ReplyLimit.oauth + 1)).start()
        }
        // While waiting: one oversize answer is skipped like an error page, and the approval after it still counts.
        final class OnceTooLong: HTTPTransport, @unchecked Sendable {
            let inner: FakeGitHubHTTP
            private let lock = NSLock()
            private var polls = 0
            init(_ inner: FakeGitHubHTTP) { self.inner = inner }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let n = lock.withLock { () -> Int in
                    if request.url?.path == "/login/oauth/access_token" { polls += 1 }
                    return polls
                }
                if n == 1 { return try await Declares(length: ReplyLimit.oauth + 1).send(request) }
                return try await inner.send(request)
            }
        }
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        http.devicePollAnswers = [["access_token": "ghu_new"]]
        let flow = DeviceFlow(clientId: "c", transport: OnceTooLong(http), sleep: { _ in }, now: { Date(timeIntervalSince1970: 0) })
        #expect(try await flow.waitForApproval(try await flow.start()).access == "ghu_new")
    }

    #if canImport(Darwin)
    /// Answers `https://stub.invalid/304` with a bare 304 (no type, no body), anything else with a small JSON body.
    final class NotModifiedStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let client else { return }
            if url.path == "/304" {
                client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!,
                                   cacheStoragePolicy: .notAllowed)
            } else {
                let body = Data("{\"ok\":true}".utf8)
                client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                                     headerFields: ["Content-Type": "application/json",
                                                                                    "Content-Length": String(body.count)])!,
                                   cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: body)
            }
            client.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Every API call now reads its answer as it arrives, as the tarball always did. The poll's bare 304 (no body, no
    /// type) must come back that way too. A read that held it back would end in the request's timeout, a
    /// `URLError` thrown here; a wall clock is no measure while the other tests run alongside.
    @Test func aBare304ComesBackThroughTheCappedRead() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotModifiedStub.self]
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (empty, notModified) = try await session.send(URLRequest(url: URL(string: "https://stub.invalid/304")!), maxBytes: ReplyLimit.json)
        #expect(notModified.statusCode == 304)
        #expect(empty.isEmpty)
        let (json, ok) = try await session.send(URLRequest(url: URL(string: "https://stub.invalid/ref")!), maxBytes: ReplyLimit.json)
        #expect(ok.statusCode == 200)
        #expect(json == Data("{\"ok\":true}".utf8))
    }
    #endif
}

/// Audit F-8. A note on GitHub over `maxNoteBytes` is more than the app opens or could ever push back. It stays on
/// GitHub, held back like a name this disk can't hold, and Needs attention says so. It is not downloaded again on every
/// run, and comes back when GitHub's note is small enough again.
@Suite struct TooLargeNoteTests {
    static let big = String(repeating: "x", count: maxNoteBytes) + "\n"
    static let atLimit = String(repeating: "y", count: maxNoteBytes - 1) + "\n"

    @Test func firstSyncHoldsBackANoteOverTheLimit() async throws {
        #expect(Self.big.utf8.count == maxNoteBytes + 1)
        #expect(Self.atLimit.utf8.count == maxNoteBytes)
        let h = try Harness(files: Harness.seed + [("big.md", Self.big), ("edge.md", Self.atLimit)])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention().map(\.reason) == ["too-large"])
        #expect(h.attention().first?.path == "big.md")
        #expect(h.store.journal.file("big.md")?.local == false)
        #expect(h.local("big.md") == nil)
        #expect(h.store.index.note(path: "big.md") == nil, "not in any list")
        #expect(h.local("edge.md") == Self.atLimit, "exactly 1 MiB is kept")
        #expect(h.local("todo.md") == "# Todo\n- one\n- two\n")
        #expect(h.store.journal.baseCommit == (await h.fake.head))
    }

    @Test func theBlobFallbackHoldsItBackToo() async throws {
        let h = try Harness(files: Harness.seed + [("big.md", Self.big)])
        await h.fake.inject(.tarball, .error(.timedOut))
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention().map(\.reason) == ["too-large"])
        #expect(h.local("big.md") == nil)
    }

    @Test func aNoteThatGrowsPastTheLimitLeavesThisDeviceAndComesBack() async throws {
        let h = try Harness()
        await h.sync()
        #expect(h.store.index.note(path: "notes/beta.md") != nil)
        await h.fake.commitRemote([("notes/beta.md", Self.big)])
        #expect(await h.sync() == .needsAttention(1))
        #expect(h.attention().map(\.reason) == ["too-large"])
        #expect(h.local("notes/beta.md") == nil, "the older, smaller text does not stay as if current")
        #expect(h.store.journal.file("notes/beta.md")?.local == false)
        #expect(h.store.index.note(path: "notes/beta.md") == nil)
        #expect(h.store.journal.baseCommit == (await h.fake.head))
        // Later runs don't download it again, not even once the user has closed the item.
        let blobs = await h.fake.count(.blob)
        h.clock.advance(120)
        await h.sync(.poll)
        try h.store.resolve(try #require(h.attention().first), .keepBoth)
        await h.sync()
        #expect(await h.fake.count(.blob) == blobs)
        // Small enough again on GitHub: the pull brings it, and nothing needs attention.
        await h.fake.commitRemote([("notes/beta.md", "# Beta\nshort again\n")])
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nshort again\n")
        #expect(h.store.journal.file("notes/beta.md")?.local == true)
        #expect(h.store.index.note(path: "notes/beta.md") != nil)
    }

    /// The item closes by itself when the note reaches the device after all.
    @Test func theItemClosesWhenTheNoteIsStored() async throws {
        let h = try Harness(files: Harness.seed + [("big.md", Self.big)])
        #expect(await h.sync() == .needsAttention(1))
        await h.fake.commitRemote([("big.md", "# Big\nnot any more\n")])
        #expect(await h.sync() == .idle)
        #expect(h.attention().isEmpty)
        #expect(h.local("big.md") == "# Big\nnot any more\n")
    }

    @Test func theReasonFollowsTheSize() {
        #expect(SyncEngine.heldBackReason(Data(count: maxNoteBytes + 1)) == "too-large")
        #expect(SyncEngine.heldBackReason(Data(count: maxNoteBytes)) == "unstorable")
    }
}
