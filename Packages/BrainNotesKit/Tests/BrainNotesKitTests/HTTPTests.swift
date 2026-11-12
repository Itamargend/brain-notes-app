import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

/// A fake GitHub at the HTTP level: parses the requests `GitHubHTTPClient` sends and answers with the JSON
/// shapes of GitHub's REST API (Git Data, compare, tarball), GraphQL and the OAuth token endpoints. So the
/// engine, the client, the token manager and the wire format run together, with no network.
final class FakeGitHubHTTP: HTTPTransport, @unchecked Sendable {
    let fake: FakeGitHub
    let repoId: Int64
    let installationId: Int64
    let owner: String
    let name: String
    let defaultBranch: String
    private let lock = NSLock()
    private var validAccess: Set<String>
    private var validRefresh: Set<String>
    private var requests: [URLRequest] = []
    private var tokenCounter = 0
    private var failRefreshWith: Int?
    private var repoPrivate: Bool
    private var listedInInstallation: Bool
    private var extraRepos: [[String: Any]] = []
    /// Hook for a device flow: answers for the poll, in order.
    var devicePollAnswers: [[String: Any]] = []

    init(fake: FakeGitHub,
         repoId: Int64 = 1,
         installationId: Int64 = 1,
         owner: String = "Itamargend",
         name: String = "brain-notes-test",
         defaultBranch: String = "main",
         isPrivate: Bool = true,
         listedInInstallation: Bool = true,
         access: String = "ghu_start",
         refresh: String = "ghr_start") {
        self.fake = fake
        self.repoId = repoId
        self.installationId = installationId
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
        self.repoPrivate = isPrivate
        self.listedInInstallation = listedInInstallation
        validAccess = [access]
        validRefresh = [refresh]
    }

    var log: [URLRequest] { lock.withLock { requests } }

    func setRepoPrivate(_ value: Bool) { lock.withLock { repoPrivate = value } }
    func setListedInInstallation(_ value: Bool) { lock.withLock { listedInInstallation = value } }
    func setExtraInstallationRepos(_ repos: [[String: Any]]) { lock.withLock { extraRepos = repos } }

    /// GitHub invalidates the access token (it expired or was revoked), refresh still works.
    func expireAccessTokens() { lock.withLock { validAccess = [] } }
    /// The app was revoked: nothing works.
    func revokeEverything() { lock.withLock { validAccess = []; validRefresh = [] } }
    func failRefresh(status: Int) { lock.withLock { failRefreshWith = status } }

    private func json(_ object: Any, status: Int = 200, headers: [String: String] = [:], url: URL) throws -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: object)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let url = request.url!
        if url.host == "github.com" { return try oauth(request, url: url) }
        precondition(url.host == "api.github.com", "the client asked for another host")
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let ok = lock.withLock { validAccess.contains(token) }
        if !ok { return try json(["message": "Bad credentials"], status: 401, url: url) }
        do {
            return try await route(request, url: url)
        } catch let e as GitHubError {
            switch e {
            case .timedOut: throw URLError(.timedOut)
            case .offline: throw URLError(.notConnectedToInternet)
            case .notFastForward: return try json(["message": "Update is not a fast forward"], status: 422, url: url)
            case let .unprocessable(m): return try json(["message": m], status: 422, url: url)
            case .notFound: return try json(["message": "Not Found"], status: 404, url: url)
            case .repoAccessLost: return try json(["message": "Not Found"], status: 404, url: url)
            case .publicRepo: return try json(["message": "Public repository"], status: 403, url: url)
            case let .server(code): return try json(["message": "oops"], status: code, url: url)
            case .unauthorized: return try json(["message": "Bad credentials"], status: 401, url: url)
            case let .rateLimited(until):
                let wait = until.map { String(Int($0.timeIntervalSinceNow)) } ?? "60"
                return try json(["message": "API rate limit exceeded"], status: 429, headers: ["Retry-After": wait], url: url)
            case let .badResponse(m): return try json(["message": m], status: 400, url: url)
            }
        }
    }

    private func oauth(_ request: URLRequest, url: URL) throws -> (Data, HTTPURLResponse) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var form: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { form[p[0]] = p[1].removingPercentEncoding ?? p[1] }
        }
        precondition(form["client_secret"] == nil, "no client secret, ever")
        if url.path == "/login/device/code" {
            return try json(["device_code": "dev", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5], url: url)
        }
        switch form["grant_type"] {
        case "refresh_token":
            if let code = lock.withLock({ failRefreshWith }) { return try json(["message": "down"], status: code, url: url) }
            let result: [String: Any] = lock.withLock {
                guard let r = form["refresh_token"], validRefresh.remove(r) != nil else {
                    // GitHub answers a bad refresh with HTTP 200 and an error field (spike S5).
                    return ["error": "incorrect_client_credentials"]
                }
                validAccess.removeAll()  // the old access token dies at once
                tokenCounter += 1
                let a = "ghu_\(tokenCounter)", n = "ghr_\(tokenCounter)"
                validAccess.insert(a)
                validRefresh.insert(n)
                return ["access_token": a, "refresh_token": n, "expires_in": 28800, "refresh_token_expires_in": 15638400, "token_type": "bearer"]
            }
            return try json(result, url: url)
        default:
            let answer: [String: Any] = lock.withLock { devicePollAnswers.isEmpty ? ["error": "authorization_pending"] : devicePollAnswers.removeFirst() }
            return try json(answer, url: url)
        }
    }

    private func repoObject(isEmpty: Bool) -> [String: Any] {
        let priv = lock.withLock { repoPrivate }
        return [
            "id": repoId,
            "name": name,
            "owner": ["login": owner],
            "private": priv,
            "visibility": priv ? "private" : "public",
            "default_branch": defaultBranch,
            "size": isEmpty ? 0 : 12,
        ]
    }

    private func route(_ request: URLRequest, url: URL) async throws -> (Data, HTTPURLResponse) {
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        let isEmpty = await fake.head.isEmpty
        if method == "GET", url.path == "/user" {
            return try json(["id": 77, "login": owner], url: url)
        }
        if method == "GET", url.path == "/user/installations" {
            let listed = lock.withLock { listedInInstallation }
            let extra = lock.withLock { extraRepos }
            let list: [[String: Any]] = (listed || !extra.isEmpty) ? [["id": installationId, "account": ["login": owner]]] : []
            return try json(["total_count": list.count, "installations": list], url: url)
        }
        if method == "GET", url.path == "/user/installations/\(installationId)/repositories" {
            let listed = lock.withLock { listedInInstallation }
            let extra = lock.withLock { extraRepos }
            var repos: [[String: Any]] = []
            if listed { repos.append(repoObject(isEmpty: isEmpty)) }
            repos.append(contentsOf: extra)
            return try json(["total_count": repos.count, "repositories": repos], url: url)
        }
        if url.path == "/graphql" { return try await graphql(body, url: url) }
        let repoRoot = "/repos/\(owner)/\(name)"
        if method == "GET", url.path == repoRoot {
            let listed = lock.withLock { listedInInstallation }
            if !listed { return try json(["message": "Not Found"], status: 404, url: url) }
            return try json(repoObject(isEmpty: isEmpty), url: url)
        }
        let prefix = repoRoot + "/"
        precondition(url.path.hasPrefix(prefix), "the client asked for another repo: \(url.path)")
        let rest = String(url.path.dropFirst(prefix.count))
        let refGet = "git/ref/heads/\(defaultBranch)"
        let refPatch = "git/refs/heads/\(defaultBranch)"
        switch (method, rest) {
        case ("GET", refGet):
            switch try await fake.getRef(etag: request.value(forHTTPHeaderField: "If-None-Match")) {
            case .empty:
                return try json(["message": "Git Repository is empty."], status: 409, url: url)
            case .notModified:
                return (Data(), HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: nil)!)
            case let .head(sha, etag):
                return try json(["ref": "refs/heads/\(defaultBranch)", "object": ["sha": sha, "type": "commit"]], headers: ["ETag": etag ?? ""], url: url)
            }
        case ("PATCH", refPatch):
            precondition(body["force"] as? Bool == false, "force must be sent and false")
            try await fake.updateRef(to: body["sha"] as! String)
            return try json(["ref": "refs/heads/\(defaultBranch)"], url: url)
        case ("POST", "git/trees"):
            let writes: [TreeWrite] = (body["tree"] as! [[String: Any]]).map { e in
                let path = e["path"] as! String
                if let content = e["content"] as? String { return TreeWrite(path: path, change: .content(content)) }
                precondition(e.keys.contains("sha") && e["sha"] is NSNull, "a delete is sha: null")
                return TreeWrite(path: path, change: .delete)
            }
            let sha = try await fake.createTree(baseTree: body["base_tree"] as! String, writes: writes)
            return try json(["sha": sha], status: 201, url: url)
        case ("POST", "git/commits"):
            let author = body["author"] as! [String: Any], committer = body["committer"] as! [String: Any]
            precondition(author["date"] as? String == committer["date"] as? String)
            let sha = try await fake.createCommit(NewCommit(
                message: body["message"] as! String, tree: body["tree"] as! String, parent: (body["parents"] as! [String])[0],
                date: author["date"] as! String, authorName: author["name"] as! String, authorEmail: author["email"] as! String))
            return try json(["sha": sha], status: 201, url: url)
        default:
            break
        }
        if method == "GET", rest.hasPrefix("git/commits/") {
            let c = try await fake.getCommit(String(rest.dropFirst("git/commits/".count)))
            return try json([
                "sha": c.sha, "tree": ["sha": c.treeSha], "parents": c.parents.map { ["sha": $0] },
                "committer": ["date": c.date.map(isoTime) ?? ""], "message": c.message,
            ] as [String: Any], url: url)
        }
        if method == "GET", rest.hasPrefix("compare/") {
            let shas = String(rest.dropFirst("compare/".count)).components(separatedBy: "...")
            let c = try await fake.compare(base: shas[0], head: shas[1])
            let files: [[String: Any]] = c.files.map { f in
                var o: [String: Any] = ["filename": f.path, "status": f.status.rawValue, "sha": f.sha ?? ""]
                if let p = f.previousPath { o["previous_filename"] = p }
                return o
            }
            return try json([
                "status": c.status, "files": files,
                "commits": [["commit": ["committer": ["date": c.headDate.map(isoTime) ?? ""]]]],
            ] as [String: Any], url: url)
        }
        if method == "GET", rest.hasPrefix("git/trees/") {
            precondition(url.query == "recursive=1")
            let t = try await fake.tree(String(rest.dropFirst("git/trees/".count)))
            return try json([
                "sha": "x", "truncated": false,
                "tree": t.map { ["path": $0.path, "mode": $0.isFile ? "100644" : "040000", "type": $0.isFile ? "blob" : "tree", "sha": $0.sha] },
            ] as [String: Any], url: url)
        }
        if method == "GET", rest.hasPrefix("git/blobs/") {
            let d = try await fake.blob(String(rest.dropFirst("git/blobs/".count)))
            // GitHub wraps base64 at 60 characters.
            let b64 = d.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n"
            return try json(["content": b64, "encoding": "base64", "size": d.count], url: url)
        }
        if method == "GET", rest.hasPrefix("tarball/") {
            let d = try await fake.tarball(String(rest.dropFirst("tarball/".count)))
            return (d, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if method == "PUT", rest.hasPrefix("contents/") {
            let rawFilePath = String(rest.dropFirst("contents/".count))
            precondition(body["branch"] as? String == defaultBranch, "initial commit must target defaultBranch")
            precondition(body["sha"] == nil, "initial commit must not send sha")
            let author = body["author"] as! [String: Any], committer = body["committer"] as! [String: Any]
            precondition(author["date"] as? String == committer["date"] as? String)
            let b64 = body["content"] as! String
            let decoded = String(decoding: Data(base64Encoded: b64)!, as: UTF8.self)
            let res = try await fake.createInitialFile(InitialFile(
                path: rawFilePath,
                content: decoded,
                message: body["message"] as! String,
                date: author["date"] as! String,
                authorName: author["name"] as! String,
                authorEmail: author["email"] as! String
            ))
            return try json([
                "content": ["sha": res.blobSha, "path": rawFilePath],
                "commit": ["sha": res.commitSha],
            ], status: 201, url: url)
        }
        return try json(["message": "Not Found: \(method) \(rest)"], status: 404, url: url)
    }

    private func graphql(_ body: [String: Any], url: URL) async throws -> (Data, HTTPURLResponse) {
        let vars = body["variables"] as! [String: Any]
        precondition(vars["owner"] as? String == owner && vars["name"] as? String == name, "GraphQL for another repo")
        var paths: [(Int, String)] = []
        for (k, v) in vars where k.hasPrefix("p") { paths.append((Int(k.dropFirst())!, v as! String)) }
        paths.sort { $0.0 < $1.0 }
        let dates = try await fake.lastCommitDates(head: vars["oid"] as! String, paths: paths.map(\.1))
        var fields: [String: Any] = [:]
        for (i, p) in paths {
            let d = dates.first { sameBytes($0.path, p) }
            fields["f\(i)"] = ["nodes": d.map { [["committedDate": isoTime($0.date)]] } ?? []]
        }
        return try json(["data": ["repository": ["object": fields]]], url: url)
    }
}

/// Builds the full stack over the HTTP-level fake.
private func httpHarness(files: [(path: String, text: String)] = Harness.seed) throws -> (Harness, FakeGitHubHTTP, TokenManager, InMemoryTokenStore) {
    let fake = FakeGitHub(files: files)
    let http = FakeGitHubHTTP(fake: fake)
    let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
    let manager = TokenManager(clientId: "test-client", transport: http, store: tokens)
    let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: http, tokens: manager)
    let h = try Harness(fake: fake, client: client)
    return (h, http, manager, tokens)
}

@Suite struct HTTPStackTests {
    @Test func fullRoundTripOverTheWireFormat() async throws {
        let (h, http, _, _) = try httpHarness()
        #expect(await h.sync() == .idle)
        #expect(h.local("עברית/רעיון.md") == "# רעיון\nטקסט בעברית\n")
        #expect(h.store.journal.file("todo.md")?.modified != nil, "dates arrived through GraphQL")

        try h.store.save(path: "todo.md", text: "# Todo\nedited\n")
        try h.store.delete(path: "people/noa.md")
        let p = try h.store.createNote(folder: "עברית", text: "# חדש\n")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nedited\n")
        #expect(await h.fake.text(p) == "# חדש\n")
        #expect(await h.fake.text("_trash/people/noa.md") == "# Noa\nDesigner\n")

        await h.fake.commitRemote([("notes/beta.md", "# Beta\nremote\n"), ("x/moved.md", nil)])
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nremote\n")

        // Every request stayed on the one repo.
        for r in http.log where r.url?.host == "api.github.com" {
            let path = r.url!.path
            #expect(path == "/graphql" || path == "/repos/Itamargend/brain-notes-test" || path.hasPrefix("/repos/Itamargend/brain-notes-test/"), "\(path)")
        }
    }

    @Test func raceThroughHTTPMapsTo422AndRetries() async throws {
        let (h, _, _, _) = try httpHarness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.beforeNextUpdateRef { f in await f.commitRemote([("people/noa.md", "# Noa\nbot\n")]) }
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine\n")
        #expect(await h.fake.text("people/noa.md") == "# Noa\nbot\n")
    }

    @Test func lostResponseThroughHTTP() async throws {
        let (h, _, _, _) = try httpHarness()
        await h.sync()
        let before = await h.fake.landed.count
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.inject(.updateRef, .lostResponse)
        #expect(await h.sync() == .idle)
        #expect(await h.fake.landed.count == before + 1)
        #expect(h.store.journal.outboxCount() == 0)
    }

    @Test func refAndEtagFlow() async throws {
        let (h, http, _, _) = try httpHarness()
        await h.sync()
        let compares = http.log.filter { $0.url!.path.contains("/compare/") }.count
        await h.engine.sync(.poll)
        await h.engine.sync(.poll)
        let refReads = http.log.filter { $0.url!.path.hasSuffix("git/ref/heads/main") }
        #expect(refReads.last?.value(forHTTPHeaderField: "If-None-Match")?.isEmpty == false)
        #expect(http.log.filter { $0.url!.path.contains("/compare/") }.count == compares)
    }

    @Test func nfdPathSurvivesTheWire() async throws {
        let nfdPath = "Cafe\u{301}/ש.md"
        let (h, _, _, _) = try httpHarness(files: [(nfdPath, "x\n")])
        await h.sync()
        try h.store.save(path: nfdPath, text: "y\n")
        #expect(await h.sync() == .idle)
        let files = await h.fake.files()
        #expect(files.count == 1)
        #expect(sameBytes(files[0].path, nfdPath))
        #expect(files[0].text == "y\n")
    }

    @Test func accessLostAndRateLimitsMapFromStatusCodes() async throws {
        let (h, _, _, _) = try httpHarness()
        await h.sync()
        await h.fake.inject(.getRef, .error(.repoAccessLost))  // 404 on the ref
        #expect(await h.sync() == .accessLost)
        await h.fake.inject(.getRef, .error(.rateLimited(until: Date().addingTimeInterval(120))))
        if case .paused(.rateLimited(until: _?)) = await h.sync() {} else { Issue.record("expected paused until a time") }
    }
}

@Suite struct TokenFlowTests {
    @Test func expiredTokenRefreshesOnceAndRetries() async throws {
        let (h, http, manager, tokens) = try httpHarness()
        await h.sync()
        http.expireAccessTokens()
        await h.fake.commitRemote([("notes/beta.md", "# Beta\nremote\n")])
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nremote\n")
        #expect(await manager.refreshCount == 1)
        #expect(try tokens.load()?.access == "ghu_1")
        #expect(try tokens.load()?.refresh == "ghr_1", "the new pair is stored")
    }

    @Test func revokedTokenSignsOutAndKeepsData() async throws {
        let (h, http, _, _) = try httpHarness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        http.revokeEverything()
        #expect(await h.sync() == .signedOut)
        #expect(h.store.journal.outboxCount() == 1)
        #expect(h.local("todo.md") == "# Todo\nmine\n")
    }

    @Test func refreshDuringAPushRetriesInFlight() async throws {
        let (h, http, manager, _) = try httpHarness()
        await h.sync()
        try h.store.save(path: "todo.md", text: "# Todo\nmine\n")
        await h.fake.beforeNextUpdateRef { _ in http.expireAccessTokens() }
        // The first ref update reaches the hook and is applied; the token dies right after. The next call refreshes.
        #expect(await h.sync() == .idle)
        h.clock.advance(120)
        try h.store.save(path: "todo.md", text: "# Todo\nmine again\n")
        #expect(await h.sync() == .idle)
        #expect(await h.fake.text("todo.md") == "# Todo\nmine again\n")
        #expect(await manager.refreshCount == 1)
    }

    @Test func concurrentRefreshesUseOneRequest() async throws {
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let manager = TokenManager(clientId: "c", transport: http, store: tokens)
        async let a = manager.refresh(failed: "ghu_start")
        async let b = manager.refresh(failed: "ghu_start")
        async let c = manager.refresh(failed: "ghu_start")
        let results = try await [a, b, c]
        #expect(Set(results) == ["ghu_1"])
        #expect(await manager.refreshCount == 1)
        // A late caller holding the old token just gets the new one.
        #expect(try await manager.refresh(failed: "ghu_start") == "ghu_1")
        #expect(await manager.refreshCount == 1)
    }

    @Test func errorInA200BodyIsAFailure() async throws {
        let http = FakeGitHubHTTP(fake: FakeGitHub(), refresh: "ghr_other")
        let tokens = InMemoryTokenStore(TokenPair(access: "dead", refresh: "ghr_replayed"))
        let manager = TokenManager(clientId: "c", transport: http, store: tokens)
        await #expect(throws: GitHubError.unauthorized) { try await manager.refresh(failed: "dead") }
    }

    @Test func aServerErrorDuringRefreshIsNotASignOut() async throws {
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        http.failRefresh(status: 503)
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let manager = TokenManager(clientId: "c", transport: http, store: tokens)
        await #expect(throws: GitHubError.server(503)) { try await manager.refresh(failed: "ghu_start") }
        #expect(try tokens.load()?.refresh == "ghr_start", "the pair is untouched")
    }

    /// Review M3. The refresh goes to github.com, which can be unreachable like any host: that is offline, and a
    /// cancelled refresh is a cancel. Neither is a failure for the engine to back off from.
    @Test func aNetworkErrorDuringRefreshMapsLikeAnyRequest() async throws {
        struct NoOAuth: HTTPTransport {
            let inner: FakeGitHubHTTP
            let error: URLError
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.host == "github.com" { throw error }
                return try await inner.send(request)
            }
        }
        for (error, expected) in [(URLError(.notConnectedToInternet), "offline"), (URLError(.timedOut), "timedOut"), (URLError(.cancelled), "cancelled")] {
            let fake = FakeGitHub(files: Harness.seed)
            let http = FakeGitHubHTTP(fake: fake)
            http.expireAccessTokens()
            let transport = NoOAuth(inner: http, error: error)
            let manager = TokenManager(clientId: "c", transport: transport,
                                       store: InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start")))
            let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: transport, tokens: manager)
            do {
                _ = try await client.getRef(etag: nil)
                Issue.record("a refresh that cannot reach GitHub must throw")
            } catch GitHubError.offline {
                #expect(expected == "offline")
            } catch GitHubError.timedOut {
                #expect(expected == "timedOut")
            } catch is CancellationError {
                #expect(expected == "cancelled")
            } catch {
                Issue.record("\(error) for \(expected)")
            }
        }
    }

    @Test func expiringTokenRefreshesBeforeUse() async throws {
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        let clock = TestClock()
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start", accessExpiry: clock.now.addingTimeInterval(30)))
        let manager = TokenManager(clientId: "c", transport: http, store: tokens, now: { clock.now })
        #expect(try await manager.accessToken() == "ghu_1")
    }

    @Test func aLockedKeychainIsNotASignOut() async throws {
        struct Locked: TokenStore {
            func load() throws -> TokenPair? { throw TokenStoreError.unavailable }
            func save(_ pair: TokenPair) throws { throw TokenStoreError.unavailable }
            func clear() {}
        }
        let fake = FakeGitHub(files: Harness.seed)
        let http = FakeGitHubHTTP(fake: fake)
        let manager = TokenManager(clientId: "c", transport: http, store: Locked())
        let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: http, tokens: manager)
        let h = try Harness(fake: fake, client: client)
        #expect(await h.sync() == .idle, "no sign-out, the next foreground run continues")
        #expect(h.store.journal.baseCommit == nil)
    }

    @Test func aCachedTokenKeepsAPushGoingAfterLock() async throws {
        final class Lockable: TokenStore, @unchecked Sendable {
            var locked = false
            let inner: InMemoryTokenStore
            init(_ inner: InMemoryTokenStore) { self.inner = inner }
            func load() throws -> TokenPair? {
                if locked { throw TokenStoreError.unavailable }
                return try inner.load()
            }
            func save(_ pair: TokenPair) throws { try inner.save(pair) }
            func clear() { inner.clear() }
        }
        let store = Lockable(InMemoryTokenStore(TokenPair(access: "a", refresh: "r")))
        let manager = TokenManager(clientId: "c", transport: FakeGitHubHTTP(fake: FakeGitHub()), store: store)
        #expect(try await manager.accessToken() == "a")
        store.locked = true
        #expect(try await manager.accessToken() == "a")
    }
}

@Suite struct DeviceFlowTests {
    private func flow(_ http: FakeGitHubHTTP, clock: TestClock) -> DeviceFlow {
        DeviceFlow(clientId: "c", transport: http, sleep: { d in clock.advance(Double(d.components.seconds)) }, now: { clock.now })
    }

    @Test func approvedAfterPolling() async throws {
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        http.devicePollAnswers = [
            ["error": "authorization_pending"],
            ["error": "slow_down", "interval": 10],
            ["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 28800],
        ]
        let clock = TestClock()
        let f = flow(http, clock: clock)
        let code = try await f.start()
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.verificationURI.absoluteString == "https://github.com/login/device")
        let start = clock.now
        let pair = try await f.waitForApproval(code)
        #expect(pair.access == "ghu_new")
        #expect(pair.refresh == "ghr_new")
        #expect(pair.accessExpiry != nil)
        #expect(clock.now.timeIntervalSince(start) == 5 + 5 + 10, "slow_down raises the interval")
    }

    @Test func deniedAndExpiredEndTheFlow() async throws {
        let clock = TestClock()
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        http.devicePollAnswers = [["error": "access_denied"]]
        let f = flow(http, clock: clock)
        let code = try await f.start()
        await #expect(throws: DeviceFlowError.denied) { try await f.waitForApproval(code) }
        http.devicePollAnswers = [["error": "expired_token"]]
        await #expect(throws: DeviceFlowError.expired) { try await f.waitForApproval(code) }
        // Nothing comes back: the code runs out on its own.
        http.devicePollAnswers = []
        await #expect(throws: DeviceFlowError.expired) {
            try await f.waitForApproval(DeviceCode(deviceCode: "d", userCode: "U", verificationURI: code.verificationURI, interval: 300, expiresIn: 900))
        }
    }

    @Test func aDroppedConnectionDoesNotEndTheSignIn() async throws {
        struct Flaky: HTTPTransport {
            let inner: FakeGitHubHTTP
            let counter = Counter()
            final class Counter: @unchecked Sendable {
                let lock = NSLock()
                var n = 0
                func next() -> Int { lock.withLock { n += 1; return n } }
            }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if counter.next() == 2 { throw URLError(.networkConnectionLost) }
                return try await inner.send(request)
            }
        }
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        http.devicePollAnswers = [["access_token": "ghu_new"]]
        let clock = TestClock()
        let f = DeviceFlow(clientId: "c", transport: Flaky(inner: http), sleep: { d in clock.advance(Double(d.components.seconds)) }, now: { clock.now })
        let code = try await f.start()
        #expect(try await f.waitForApproval(code).access == "ghu_new")
    }

    /// Review M4. A server error page in the middle of the wait is a blip, not the end of the sign-in.
    @Test func aServerErrorWhilePollingDoesNotEndTheSignIn() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            func next() -> Int { lock.withLock { n += 1; return n } }
        }
        struct Blip: HTTPTransport {
            let inner: FakeGitHubHTTP
            let counter: Counter
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                // Call 1 asks for the code, call 2 is the first poll.
                if counter.next() == 2 {
                    return (Data("<html>502 Bad Gateway</html>".utf8),
                            HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!)
                }
                return try await inner.send(request)
            }
        }
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        http.devicePollAnswers = [["error": "authorization_pending"], ["access_token": "ghu_new"]]
        let clock = TestClock()
        let f = DeviceFlow(clientId: "c", transport: Blip(inner: http, counter: Counter()),
                           sleep: { d in clock.advance(Double(d.components.seconds)) }, now: { clock.now })
        let code = try await f.start()
        #expect(try await f.waitForApproval(code).access == "ghu_new")
    }

    @Test func aServerErrorWhenAskingForACodeIsShownAtOnce() async throws {
        struct Down: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                (Data("<html>503</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
        }
        let f = DeviceFlow(clientId: "c", transport: Down())
        await #expect(throws: DeviceFlowError.failed("response")) { try await f.start() }
    }

    @Test func requestsCarryNoSecret() async throws {
        let http = FakeGitHubHTTP(fake: FakeGitHub())
        let f = flow(http, clock: TestClock())
        _ = try await f.start()
        let body = String(decoding: http.log[0].httpBody!, as: UTF8.self)
        #expect(body == "client_id=c")
    }
}

#if canImport(Security)
@Suite struct KeychainTests {
    /// Runs against the real Keychain of the machine running the tests, on a test-only account.
    @Test func roundTripAndAccessibility() throws {
        let store = KeychainTokenStore(account: "bn-unit-test-\(UUID().uuidString)")
        defer { store.clear() }
        #expect(try store.load() == nil)
        let pair = TokenPair(access: "synthetic-access", refresh: "synthetic-refresh", accessExpiry: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(pair)
        #expect(try store.load() == pair)
        var next = pair
        next.access = "synthetic-access-2"
        try store.save(next)
        #expect(try store.load() == next)
        store.clear()
        #expect(try store.load() == nil)
    }
}
#endif

@Suite struct ClientErrorMappingTests {
    /// A transport that answers every request the same way.
    struct Canned: HTTPTransport {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = "{}"
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private func client(_ t: HTTPTransport, now: Date = Date(timeIntervalSince1970: 1_000)) throws -> GitHubHTTPClient {
        let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore(TokenPair(access: "a")))
        return try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: t, tokens: m, now: { now })
    }

    private let sha = String(repeating: "a", count: 40)

    @Test func statusesMap() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        await #expect(throws: GitHubError.rateLimited(until: now.addingTimeInterval(30))) {
            try await client(Canned(status: 429, headers: ["Retry-After": "30"])).getRef(etag: nil)
        }
        await #expect(throws: GitHubError.rateLimited(until: Date(timeIntervalSince1970: 5_000))) {
            try await client(Canned(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "5000"])).getRef(etag: nil)
        }
        await #expect(throws: GitHubError.rateLimited(until: nil)) {
            try await client(Canned(status: 403, body: "{\"message\":\"You have exceeded a secondary rate limit\"}")).getRef(etag: nil)
        }
        await #expect(throws: GitHubError.repoAccessLost) {
            try await client(Canned(status: 403, body: "{\"message\":\"Resource not accessible by integration\"}")).getRef(etag: nil)
        }
        await #expect(throws: GitHubError.repoAccessLost) { try await client(Canned(status: 404)).getRef(etag: nil) }
        await #expect(throws: GitHubError.notFound) { try await client(Canned(status: 404)).compare(base: sha, head: sha) }
        await #expect(throws: GitHubError.server(502)) { try await client(Canned(status: 502)).getRef(etag: nil) }
        await #expect(throws: GitHubError.notFastForward) {
            try await client(Canned(status: 422, body: "{\"message\":\"Update is not a fast forward\"}")).updateRef(to: sha)
        }
        // Plan: any 422 on the ref is a race. The engine pulls and retries, then goes to Needs attention.
        await #expect(throws: GitHubError.notFastForward) {
            try await client(Canned(status: 422, body: "{\"message\":\"Reference update failed\"}")).updateRef(to: sha)
        }
        await #expect(throws: GitHubError.unprocessable("GitRPC::BadObjectState")) {
            try await client(Canned(status: 422, body: "{\"message\":\"GitRPC::BadObjectState\"}")).createTree(baseTree: sha, writes: [])
        }
    }

    @Test func urlErrorsMap() {
        #expect(GitHubHTTPClient.mapURLError(URLError(.notConnectedToInternet)) as? GitHubError == .offline)
        #expect(GitHubHTTPClient.mapURLError(URLError(.cannotFindHost)) as? GitHubError == .offline)
        #expect(GitHubHTTPClient.mapURLError(URLError(.timedOut)) as? GitHubError == .timedOut)
        #expect(GitHubHTTPClient.mapURLError(URLError(.networkConnectionLost)) as? GitHubError == .timedOut)
        #expect(GitHubHTTPClient.mapURLError(URLError(.cancelled)) is CancellationError)
    }

    @Test func aBadShaNeverReachesAURL() async throws {
        let c = try client(Canned(status: 200))
        await #expect(throws: GitHubError.badResponse("sha")) { try await c.blob("../../brain") }
        await #expect(throws: GitHubError.badResponse("sha")) { try await c.tree("main") }
    }

    @Test func truncatedComparisonAndTree() async throws {
        let many = (0..<300).map { "{\"filename\":\"f\($0).md\",\"status\":\"modified\",\"sha\":\"s\"}" }.joined(separator: ",")
        let c = try await client(Canned(status: 200, body: "{\"status\":\"ahead\",\"files\":[\(many)]}")).compare(base: sha, head: sha)
        #expect(c.truncated)
        let none = try await client(Canned(status: 200, body: "{\"status\":\"ahead\"}")).compare(base: sha, head: sha)
        #expect(none.truncated)
        let same = try await client(Canned(status: 200, body: "{\"status\":\"identical\"}")).compare(base: sha, head: sha)
        #expect(!same.truncated)
        await #expect(throws: GitHubError.badResponse("tree truncated")) {
            try await client(Canned(status: 200, body: "{\"truncated\":true,\"tree\":[]}")).tree(sha)
        }
    }

    @Test func symlinksAndFoldersAreNotFiles() async throws {
        let body = """
        {"truncated":false,"tree":[
          {"path":"a.md","mode":"100644","type":"blob","sha":"1"},
          {"path":"folder","mode":"040000","type":"tree","sha":"2"},
          {"path":"link.md","mode":"120000","type":"blob","sha":"3"},
          {"path":"sub","mode":"160000","type":"commit","sha":"4"}
        ]}
        """
        let t = try await client(Canned(status: 200, body: body)).tree(sha)
        #expect(t.filter(\.isFile).map(\.path) == ["a.md"])
    }
}
