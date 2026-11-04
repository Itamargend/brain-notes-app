import Foundation

/// The URLSession for GitHub: nothing on disk (no URL cache, no cookies, so note bodies and tokens never
/// land in a cache file), and redirects only to GitHub's tarball host, without the Authorization header.
public enum GitHubSession {
    public static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard request.url?.scheme == "https", let host = request.url?.host, host == "codeload.github.com" else { return nil }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            return next
        }
    }
}

/// REST and GraphQL calls for one repository. Every request passes `RepoTarget.guardURL`, in one place.
public struct GitHubHTTPClient: GitHubClient {
    public let repo: RepoTarget
    private let transport: HTTPTransport
    private let tokens: TokenProvider
    private let now: @Sendable () -> Date

    /// Throws `RepoTarget.GuardError.repoNotAllowed` for anything but the one allowed repo.
    public init(owner: String, name: String, transport: HTTPTransport, tokens: TokenProvider,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.repo = try RepoTarget(owner: owner, name: name)
        self.transport = transport
        self.tokens = tokens
        self.now = now
    }

    // MARK: requests

    /// Builds a request for a path under `https://api.github.com/` and applies the guard.
    func request(_ method: String, _ apiPath: String, json: Any? = nil) throws -> URLRequest {
        guard let url = URL(string: "https://api.github.com/" + apiPath) else { throw GitHubError.badResponse("url") }
        try repo.guardURL(url)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func repoPath(_ suffix: String) -> String { "repos/\(repo.owner)/\(repo.name)/\(suffix)" }

    private static func checkedSha(_ sha: String) throws -> String {
        guard sha.utf8.count >= 40, sha.utf8.count <= 64,
              sha.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw GitHubError.badResponse("sha")
        }
        return sha
    }

    /// Sends with the current token. A 401 refreshes once and retries once with the new token.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // A second look right before sending: nothing built this request around the guard.
        if let url = request.url { try repo.guardURL(url) }
        var token = try await tokens.accessToken()
        var (data, http) = try await sendOnce(request, token: token)
        if http.statusCode == 401 {
            token = try await tokens.refresh(failed: token)
            (data, http) = try await sendOnce(request, token: token)
            if http.statusCode == 401 { throw GitHubError.unauthorized }
        }
        return (data, http)
    }

    private func sendOnce(_ request: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.send(req)
        } catch let e as URLError {
            throw Self.mapURLError(e)
        }
    }

    static func mapURLError(_ e: URLError) -> Error {
        switch e.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return GitHubError.offline
        default:
            return GitHubError.timedOut
        }
    }

    /// Maps a non-2xx response. `missing` is the error for a 404 at this call.
    private func failure(_ http: HTTPURLResponse, _ data: Data, missing: GitHubError = .notFound) -> GitHubError {
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
        switch http.statusCode {
        case 401:
            return .unauthorized
        case 403, 429:
            if let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
                return .rateLimited(until: now().addingTimeInterval(retry))
            }
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                return .rateLimited(until: reset.map { Date(timeIntervalSince1970: $0) })
            }
            if http.statusCode == 429 || message.localizedCaseInsensitiveContains("rate limit") {
                return .rateLimited(until: nil)
            }
            return .repoAccessLost
        case 404:
            return missing
        case 422:
            return .unprocessable(message)
        case 500...599:
            return .server(http.statusCode)
        default:
            return .badResponse("status \(http.statusCode)")
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.badResponse("json") }
        return o
    }

    private func getJSON(_ apiPath: String, missing: GitHubError = .notFound) async throws -> [String: Any] {
        let (data, http) = try await perform(try request("GET", apiPath))
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data, missing: missing) }
        return try Self.object(data)
    }

    private func postJSON(_ apiPath: String, _ body: Any) async throws -> [String: Any] {
        let (data, http) = try await perform(try request("POST", apiPath, json: body))
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data) }
        return try Self.object(data)
    }

    // MARK: GitHubClient

    public func getRef(etag: String?) async throws -> RefResult {
        var req = try request("GET", repoPath("git/ref/heads/main"))
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await perform(req)
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data, missing: .repoAccessLost) }
        let o = try Self.object(data)
        guard let sha = (o["object"] as? [String: Any])?["sha"] as? String else { throw GitHubError.badResponse("ref") }
        return .head(sha: try Self.checkedSha(sha), etag: http.value(forHTTPHeaderField: "ETag"))
    }

    public func getCommit(_ sha: String) async throws -> CommitInfo {
        let o = try await getJSON(repoPath("git/commits/\(try Self.checkedSha(sha))"))
        guard let tree = (o["tree"] as? [String: Any])?["sha"] as? String else { throw GitHubError.badResponse("commit") }
        let parents = (o["parents"] as? [[String: Any]] ?? []).compactMap { $0["sha"] as? String }
        let date = ((o["committer"] as? [String: Any])?["date"] as? String).flatMap(parseISOTime)
        return CommitInfo(sha: sha, treeSha: tree, parents: parents, date: date, message: o["message"] as? String ?? "")
    }

    public func compare(base: String, head: String) async throws -> Comparison {
        let o = try await getJSON(repoPath("compare/\(try Self.checkedSha(base))...\(try Self.checkedSha(head))"))
        guard let status = o["status"] as? String else { throw GitHubError.badResponse("compare") }
        var files: [ChangedFile] = []
        let raw = o["files"] as? [[String: Any]]
        for f in raw ?? [] {
            guard let path = f["filename"] as? String, let s = f["status"] as? String else { continue }
            let mapped: ChangedFile.Status
            switch s {
            case "added", "copied": mapped = .added
            case "removed": mapped = .removed
            case "renamed": mapped = .renamed
            case "unchanged": continue
            default: mapped = .modified  // "modified", "changed"
            }
            files.append(ChangedFile(path: path, status: mapped, previousPath: f["previous_filename"] as? String, sha: f["sha"] as? String))
        }
        // GitHub lists at most 300 files for a comparison, and may leave the list out of a very large one.
        let truncated = (raw?.count ?? 0) >= 300 || (raw == nil && status != "identical")
        let last = (o["commits"] as? [[String: Any]])?.last
        let date = (((last?["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"] as? String).flatMap(parseISOTime)
        return Comparison(status: status, files: files, truncated: truncated, headDate: date)
    }

    public func tree(_ sha: String) async throws -> [TreeEntry] {
        let o = try await getJSON(repoPath("git/trees/\(try Self.checkedSha(sha))?recursive=1"))
        if (o["truncated"] as? Bool) == true { throw GitHubError.badResponse("tree truncated") }
        return (o["tree"] as? [[String: Any]] ?? []).compactMap { e in
            guard let path = e["path"] as? String, let sha = e["sha"] as? String else { return nil }
            let mode = e["mode"] as? String ?? ""
            return TreeEntry(path: path, sha: sha, isFile: e["type"] as? String == "blob" && mode != "120000")
        }
    }

    public func blob(_ sha: String) async throws -> Data {
        let o = try await getJSON(repoPath("git/blobs/\(try Self.checkedSha(sha))"))
        guard let content = o["content"] as? String, o["encoding"] as? String == "base64",
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw GitHubError.badResponse("blob")
        }
        return data
    }

    public func tarball(_ sha: String) async throws -> Data {
        let (data, http) = try await perform(try request("GET", repoPath("tarball/\(try Self.checkedSha(sha))")))
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data) }
        return data
    }

    public func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String {
        let entries: [[String: Any]] = writes.map { w in
            var e: [String: Any] = ["path": w.path, "mode": "100644", "type": "blob"]
            switch w.change {
            case let .content(text): e["content"] = text
            case .delete: e["sha"] = NSNull()
            }
            return e
        }
        let o = try await postJSON(repoPath("git/trees"), ["base_tree": try Self.checkedSha(baseTree), "tree": entries] as [String: Any])
        guard let sha = o["sha"] as? String else { throw GitHubError.badResponse("tree") }
        return sha
    }

    public func createCommit(_ c: NewCommit) async throws -> String {
        let person: [String: Any] = ["name": c.authorName, "email": c.authorEmail, "date": c.date]
        let body: [String: Any] = [
            "message": c.message, "tree": try Self.checkedSha(c.tree), "parents": [try Self.checkedSha(c.parent)],
            "author": person, "committer": person,
        ]
        let o = try await postJSON(repoPath("git/commits"), body)
        guard let sha = o["sha"] as? String else { throw GitHubError.badResponse("commit") }
        return sha
    }

    public func updateRef(to sha: String) async throws {
        // `force` is always sent, always false: a ref update can only ever fast-forward.
        let body: [String: Any] = ["sha": try Self.checkedSha(sha), "force": false]
        let (data, http) = try await perform(try request("PATCH", repoPath("git/refs/heads/main"), json: body))
        guard (200..<300).contains(http.statusCode) else {
            let error = failure(http, data, missing: .repoAccessLost)
            if case let .unprocessable(message) = error,
               message.localizedCaseInsensitiveContains("fast forward") || message.localizedCaseInsensitiveContains("fast-forward") {
                throw GitHubError.notFastForward
            }
            throw error
        }
    }

    public func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] {
        guard !paths.isEmpty else { return [] }
        // Paths travel as GraphQL variables, never spliced into the query text.
        var declarations = ["$owner: String!", "$name: String!", "$oid: GitObjectID!"]
        var fields: [String] = []
        var variables: [String: Any] = ["owner": repo.owner, "name": repo.name, "oid": try Self.checkedSha(head)]
        for (i, p) in paths.enumerated() {
            declarations.append("$p\(i): String!")
            fields.append("f\(i): history(first: 1, path: $p\(i)) { nodes { committedDate } }")
            variables["p\(i)"] = p
        }
        let query = """
            query(\(declarations.joined(separator: ", "))) {
              repository(owner: $owner, name: $name) {
                object(oid: $oid) { ... on Commit { \(fields.joined(separator: " ")) } }
              }
            }
            """
        let o = try await postJSON("graphql", ["query": query, "variables": variables] as [String: Any])
        let commit = ((o["data"] as? [String: Any])?["repository"] as? [String: Any])?["object"] as? [String: Any] ?? [:]
        var out: [PathDate] = []
        for (i, p) in paths.enumerated() {
            let nodes = (commit["f\(i)"] as? [String: Any])?["nodes"] as? [[String: Any]]
            if let s = nodes?.first?["committedDate"] as? String, let d = parseISOTime(s) {
                out.append(PathDate(path: p, date: d))
            }
        }
        return out
    }
}
