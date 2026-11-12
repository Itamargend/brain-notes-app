import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The URLSession for GitHub: nothing on disk (no URL cache, no cookies, so note bodies and tokens never
/// land in a cache file), and redirects only to GitHub's tarball host, without the Authorization header.
public enum GitHubSession {
    public static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        #if canImport(Darwin)
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        #endif
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            Self.allowed(request)
        }

        #if !canImport(Darwin)
        // swift-corelibs-foundation asks through the completion handler form only.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(Self.allowed(request))
        }
        #endif

        private static func allowed(_ request: URLRequest) -> URLRequest? {
            guard request.httpMethod == "GET",
                  request.url?.scheme == "https",
                  request.url?.user == nil,
                  let host = request.url?.host,
                  host == "codeload.github.com" else { return nil }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            return next
        }
    }
}

/// REST and GraphQL calls for one repository. Every request passes `RepoTarget.guardURL`, in one place.
public struct GitHubHTTPClient: GitHubClient {
    /// Holds the immutable numeric ID, owner, and name of the repository while allowing a validated `defaultBranch`
    /// rename on that exact repository to propagate without wiping local notes.
    private final class TargetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RepoTarget
        private let onDefaultBranchChanged: (@Sendable (RepoTarget) -> Void)?

        init(_ initial: RepoTarget, onDefaultBranchChanged: (@Sendable (RepoTarget) -> Void)?) {
            self.value = initial
            self.onDefaultBranchChanged = onDefaultBranchChanged
        }

        var current: RepoTarget { lock.withLock { value } }

        func updateDefaultBranch(_ branch: String) throws {
            let current = lock.withLock { value }
            let updated = try RepoTarget(
                repoId: current.repoId,
                owner: current.owner,
                name: current.name,
                defaultBranch: branch,
                isPrivate: true
            )
            let changed: Bool = lock.withLock {
                if sameBytes(value.defaultBranch, updated.defaultBranch) { return false }
                value = updated
                return true
            }
            if changed {
                onDefaultBranchChanged?(updated)
            }
        }
    }

    private let targetBox: TargetBox
    public var repo: RepoTarget { targetBox.current }
    /// The tarball download stops at `limits.maxDownloadBytes`, a blob at `limits.maxEntryBytes`.
    public let limits: FirstSyncLimits
    private let transport: HTTPTransport
    private let tokens: TokenProvider
    private let now: @Sendable () -> Date

    public init(repo: RepoTarget, transport: HTTPTransport, tokens: TokenProvider,
                limits: FirstSyncLimits = .standard, now: @escaping @Sendable () -> Date = { Date() },
                onDefaultBranchChanged: (@Sendable (RepoTarget) -> Void)? = nil) {
        self.targetBox = TargetBox(repo, onDefaultBranchChanged: onDefaultBranchChanged)
        self.limits = limits
        self.transport = transport
        self.tokens = tokens
        self.now = now
    }

    /// Validates target fields (`repoId`, `owner`, `name`, `defaultBranch`, `isPrivate`). Every request it builds
    /// is then checked against this single repository.
    public init(repoId: Int64 = 1, owner: String, name: String, defaultBranch: String = "main", isPrivate: Bool = true,
                transport: HTTPTransport, tokens: TokenProvider,
                limits: FirstSyncLimits = .standard, now: @escaping @Sendable () -> Date = { Date() },
                onDefaultBranchChanged: (@Sendable (RepoTarget) -> Void)? = nil) throws {
        let target = try RepoTarget(repoId: repoId, owner: owner, name: name, defaultBranch: defaultBranch, isPrivate: isPrivate)
        self.init(repo: target, transport: transport, tokens: tokens, limits: limits, now: now,
                  onDefaultBranchChanged: onDefaultBranchChanged)
    }

    /// Updates the validated default branch for this exact `repoId`/`owner`/`name`.
    public func updateDefaultBranch(_ branch: String) throws {
        try targetBox.updateDefaultBranch(branch)
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

    private var repoRootPath: String { "repositories/\(repo.id)" }
    private func repoPath(_ suffix: String) -> String { "repositories/\(repo.id)/\(suffix)" }

    private static func checkedSha(_ sha: String) throws -> String {
        guard sha.utf8.count >= 40, sha.utf8.count <= 64,
              sha.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw GitHubError.badResponse("sha")
        }
        return sha
    }

    /// Sends with the current token. A 401 refreshes once and retries once with the new token. A body past `maxBytes`
    /// is refused as it arrives (`RepoTooLarge(.download)`); every call has a cap, `ReplyLimit.json` unless it says.
    private func perform(_ request: URLRequest, maxBytes: Int = ReplyLimit.json) async throws -> (Data, HTTPURLResponse) {
        // A second look right before sending: nothing built this request around the guard.
        if let url = request.url { try repo.guardURL(url) }
        var token = try await mapped { try await tokens.accessToken() }
        var (data, http) = try await sendOnce(request, token: token, maxBytes: maxBytes)
        if http.statusCode == 401 {
            let failed = token
            token = try await mapped { try await tokens.refresh(failed: failed) }
            (data, http) = try await sendOnce(request, token: token, maxBytes: maxBytes)
            if http.statusCode == 401 { throw GitHubError.unauthorized }
        }
        return (data, http)
    }

    /// Getting a token can go to the network too (a refresh before expiry or after a 401). Its connection errors
    /// mean what they mean for any request: offline is offline, not a failure to back off from.
    private func mapped(_ body: () async throws -> String) async throws -> String {
        do {
            return try await body()
        } catch let e as URLError {
            throw Self.mapURLError(e)
        }
    }

    private func sendOnce(_ request: URLRequest, token: String, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.send(req, maxBytes: maxBytes)
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

    @discardableResult
    private func fetchVerifiedPrivateRepo() async throws -> [String: Any] {
        let target = self.repo
        let o = try await getJSON(repoRootPath, missing: .repoAccessLost)
        guard let id = (o["id"] as? NSNumber)?.int64Value, id == target.repoId,
              let login = (o["owner"] as? [String: Any])?["login"] as? String, sameBytes(login, target.owner),
              let repoName = o["name"] as? String, sameBytes(repoName, target.name),
              let priv = o["private"] as? Bool else {
            throw GitHubError.repoAccessLost
        }
        let vis = o["visibility"] as? String
        guard priv, vis == nil || sameBytes(vis!, "private") else {
            throw GitHubError.publicRepo
        }
        guard let branch = o["default_branch"] as? String, RepoTarget.isValidBranch(branch) else {
            throw GitHubError.repoAccessLost
        }
        if !sameBytes(branch, target.defaultBranch) {
            try updateDefaultBranch(branch)
        }
        return o
    }

    public func verifyPrivateRepo() async throws {
        _ = try await fetchVerifiedPrivateRepo()
    }

    public func getRef(etag: String?) async throws -> RefResult {
        var req = try request("GET", repoPath("git/ref/heads/\(Self.encodeBranchPath(repo.defaultBranch))"))
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await perform(req)
        if http.statusCode == 304 { return .notModified }
        if http.statusCode == 409 { return .empty }
        if http.statusCode == 404 {
            // Distinguish an inaccessible repository from a brand-new private repository with zero commits (`size == 0`).
            let meta = try await fetchVerifiedPrivateRepo()
            if (meta["size"] as? NSNumber)?.intValue == 0 {
                return .empty
            }
            throw GitHubError.repoAccessLost
        }
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

    /// A blob's bytes, at most `limits.maxEntryBytes` of them, as for one file of the tarball (`RepoTooLarge(.entry)`):
    /// the answer stops as it arrives once it is past what that many bytes encode to, the size GitHub states is checked
    /// before anything is decoded, and the decoded bytes once more.
    public func blob(_ sha: String) async throws -> Data {
        let max = limits.maxEntryBytes
        let req = try request("GET", repoPath("git/blobs/\(try Self.checkedSha(sha))"))
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await perform(req, maxBytes: Self.blobReplyCap(forBlobBytes: max))
        } catch is RepoTooLarge {
            throw RepoTooLarge(.entry, max: max)
        }
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data) }
        let o = try Self.object(data)
        if let size = (o["size"] as? NSNumber)?.intValue, size > max { throw RepoTooLarge(.entry, max: max) }
        guard let content = o["content"] as? String, o["encoding"] as? String == "base64",
              let blob = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw GitHubError.badResponse("blob")
        }
        guard blob.count <= max else { throw RepoTooLarge(.entry, max: max) }
        return blob
    }

    /// The most a blob's JSON answer may be for a blob of `bytes`: base64 is 4 bytes for every 3, broken into lines of
    /// 60 (each break is `\n` in JSON, two bytes), an eighth more for anything else the encoder escapes, and 64 KiB for
    /// the other fields.
    static func blobReplyCap(forBlobBytes bytes: Int) -> Int {
        guard bytes < Int.max / 8 else { return .max }
        let encoded = (bytes / 3 + 1) * 4
        let breaks = (encoded / 60 + 1) * 2
        return encoded + encoded / 8 + breaks + (64 << 10)
    }

    /// The first-sync download, refused past `limits.maxDownloadBytes` before or while it arrives (`RepoTooLarge`).
    public func tarball(_ sha: String) async throws -> Data {
        let req = try request("GET", repoPath("tarball/\(try Self.checkedSha(sha))"))
        let (data, http) = try await perform(req, maxBytes: limits.maxDownloadBytes)
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
        let (data, http) = try await perform(try request("PATCH", repoPath("git/refs/heads/\(Self.encodeBranchPath(repo.defaultBranch))"), json: body))
        guard (200..<300).contains(http.statusCode) else {
            let error = failure(http, data, missing: .repoAccessLost)
            // Plan: any 422 on the ref is a race. Besides "not a fast forward", GitHub can answer a concurrent
            // update in other words. The engine pulls and retries, then goes to Needs attention.
            if case .unprocessable = error { throw GitHubError.notFastForward }
            throw error
        }
    }

    public func createInitialFile(_ file: InitialFile) async throws -> InitialCommitResult {
        let segments = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw GitHubError.unprocessable("invalid path")
        }
        let encodedPath = segments.map(Self.encodePathSegment).joined(separator: "/")
        let person: [String: Any] = ["name": file.authorName, "email": file.authorEmail, "date": file.date]
        // `sha` is omitted on purpose: Contents API creates only a brand-new file and never overwrites an existing one.
        let body: [String: Any] = [
            "message": file.message,
            "content": Data(file.content.utf8).base64EncodedString(),
            "branch": repo.defaultBranch,
            "author": person,
            "committer": person,
        ]
        let (data, http) = try await perform(try request("PUT", repoPath("contents/\(encodedPath)"), json: body))
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 409 {
                throw GitHubError.notFastForward
            }
            let err = failure(http, data, missing: .repoAccessLost)
            if case let .unprocessable(message) = err,
               message.localizedCaseInsensitiveContains("\"sha\"") || message.localizedCaseInsensitiveContains("fast forward") {
                throw GitHubError.notFastForward
            }
            throw err
        }
        let o = try Self.object(data)
        guard let commitSha = (o["commit"] as? [String: Any])?["sha"] as? String,
              let blobSha = (o["content"] as? [String: Any])?["sha"] as? String else {
            throw GitHubError.badResponse("contents")
        }
        return InitialCommitResult(commitSha: try Self.checkedSha(commitSha), blobSha: try Self.checkedSha(blobSha))
    }

    static func encodeBranchPath(_ branch: String) -> String {
        branch.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.encodePathSegment(String($0)) }
            .joined(separator: "/")
    }

    private static func encodePathSegment(_ segment: String) -> String {
        var out = ""
        for b in segment.utf8 {
            let unreserved = (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39)
                || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
            if unreserved {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    public func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate] {
        guard !paths.isEmpty else { return [] }
        let currentRepo = repo
        // Paths travel as GraphQL variables, never spliced into the query text.
        var declarations = ["$owner: String!", "$name: String!", "$oid: GitObjectID!"]
        var fields: [String] = []
        var variables: [String: Any] = ["owner": currentRepo.owner, "name": currentRepo.name, "oid": try Self.checkedSha(head)]
        for (i, p) in paths.enumerated() {
            declarations.append("$p\(i): String!")
            fields.append("f\(i): history(first: 1, path: $p\(i)) { nodes { committedDate } }")
            variables["p\(i)"] = p
        }
        let query = """
            query(\(declarations.joined(separator: ", "))) {
              repository(owner: $owner, name: $name) {
                databaseId
                object(oid: $oid) { ... on Commit { \(fields.joined(separator: " ")) } }
              }
            }
            """
        let o = try await postJSON("graphql", ["query": query, "variables": variables] as [String: Any])
        guard let repository = (o["data"] as? [String: Any])?["repository"] as? [String: Any],
              let dbId = (repository["databaseId"] as? NSNumber)?.int64Value,
              dbId == currentRepo.repoId else {
            throw GitHubError.repoAccessLost
        }
        let commit = repository["object"] as? [String: Any] ?? [:]
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
