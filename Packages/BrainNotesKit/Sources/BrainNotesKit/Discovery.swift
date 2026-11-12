import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one private repository the signed-in user picked from an installation of the Brain Notes GitHub App.
/// Persisted locally in `SelectedRepoStore` and re-verified against GitHub's installation endpoints whenever a
/// session opens (and when a sync encounters 403/404): a stored owner/name is never trusted on its own.
public struct SelectedRepo: Codable, Sendable, Equatable {
    public let installationId: Int64
    public let repoId: Int64
    public let owner: String
    public let name: String
    public let defaultBranch: String

    public init(installationId: Int64, repoId: Int64, owner: String, name: String,
                defaultBranch: String = "main", isPrivate: Bool = true) throws {
        guard installationId > 0 else { throw RepoTarget.GuardError.repoNotAllowed }
        let target = try RepoTarget(repoId: repoId, owner: owner, name: name, defaultBranch: defaultBranch, isPrivate: isPrivate)
        self.installationId = installationId
        self.repoId = target.repoId
        self.owner = target.owner
        self.name = target.name
        self.defaultBranch = target.defaultBranch
    }

    private enum CodingKeys: String, CodingKey {
        case installationId, repoId, owner, name, defaultBranch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let installationId = try c.decode(Int64.self, forKey: .installationId)
        let repoId = try c.decode(Int64.self, forKey: .repoId)
        let owner = try c.decode(String.self, forKey: .owner)
        let name = try c.decode(String.self, forKey: .name)
        let defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
        try self.init(installationId: installationId, repoId: repoId, owner: owner, name: name,
                      defaultBranch: defaultBranch, isPrivate: true)
    }

    public var slug: String { "\(owner)/\(name)" }

    public func target() throws -> RepoTarget {
        try RepoTarget(repoId: repoId, owner: owner, name: name, defaultBranch: defaultBranch, isPrivate: true)
    }
}

/// Persists `SelectedRepo` at `<baseFolder>/Brain/selected-repo.json`, out of backups and
/// protected on disk.
public struct SelectedRepoStore: Sendable {
    public let brainRoot: URL
    public let url: URL

    public init(baseFolder: URL) {
        let root = baseFolder.appendingPathComponent("Brain", isDirectory: true)
        self.brainRoot = root
        self.url = root.appendingPathComponent("selected-repo.json", isDirectory: false)
    }

    public func load() throws -> SelectedRepo? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(SelectedRepo.self, from: data)
    }

    public func save(_ selection: SelectedRepo) throws {
        try FileManager.default.createDirectory(at: brainRoot, withIntermediateDirectories: true)
        FileStore.excludeFromBackup(brainRoot)
        let data = try JSONEncoder().encode(selection)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
        FileStore.excludeFromBackup(url)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

public struct GitHubAccount: Sendable, Equatable {
    public let id: Int64
    public let login: String

    public init(id: Int64, login: String) {
        self.id = id
        self.login = login
    }
}

public struct GitHubInstallation: Sendable, Equatable {
    public let id: Int64
    public let accountLogin: String?

    public init(id: Int64, accountLogin: String? = nil) {
        self.id = id
        self.accountLogin = accountLogin
    }
}

/// One repository returned by `GET /user/installations/{installation_id}/repositories`. Public (or internal) repos
/// are carried with `isPrivate == false` so the picker can display them greyed out with `RepoTarget.publicRepoMessage`,
/// while `select()` refuses them with `RepoTarget.GuardError.publicRepo`.
public struct DiscoveredRepo: Identifiable, Sendable, Equatable {
    public var id: Int64 { repoId }
    public let installationId: Int64
    public let repoId: Int64
    public let owner: String
    public let name: String
    public let defaultBranch: String
    public let isPrivate: Bool

    public init(installationId: Int64, repoId: Int64, owner: String, name: String, defaultBranch: String, isPrivate: Bool) throws {
        guard installationId > 0, repoId > 0,
              RepoTarget.isValidOwner(owner),
              RepoTarget.isValidRepoName(name),
              RepoTarget.isValidBranch(defaultBranch) else {
            throw RepoTarget.GuardError.repoNotAllowed
        }
        self.installationId = installationId
        self.repoId = repoId
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate
    }

    public var slug: String { "\(owner)/\(name)" }

    public func select() throws -> SelectedRepo {
        try SelectedRepo(installationId: installationId, repoId: repoId, owner: owner, name: name,
                         defaultBranch: defaultBranch, isPrivate: isPrivate)
    }
}

public struct DiscoveryResult: Sendable, Equatable {
    public let installationsCount: Int
    public let repositories: [DiscoveredRepo]

    public init(installationsCount: Int, repositories: [DiscoveredRepo]) {
        self.installationsCount = installationsCount
        self.repositories = repositories
    }

    public var privateRepositories: [DiscoveredRepo] {
        repositories.filter(\.isPrivate)
    }

    public var publicRepositories: [DiscoveredRepo] {
        repositories.filter { !$0.isPrivate }
    }
}

public enum SelectionVerificationError: Error, Equatable, Sendable {
    /// Selected repository is not listed in any installation returned for this user token, or its numeric ID / owner / name changed.
    case notListed
    /// Selected repository exists in the installation but is no longer private.
    case publicRepo
}

/// Minimal URL and method guard for the ONLY three non-repo endpoints Brain Notes ever calls:
/// - `GET https://api.github.com/user` (no query)
/// - `GET https://api.github.com/user/installations` (`per_page` / `page` positive integer query only)
/// - `GET https://api.github.com/user/installations/{positive_numeric_id}/repositories` (`per_page` / `page` only)
/// Everything else (`/user/repos`, `/orgs/...`, `POST`, non-numeric IDs, extra query params, other hosts) is refused.
public enum DiscoveryGuard {
    public enum GuardError: Error, Equatable, Sendable {
        case endpointNotAllowed
    }

    public static func guardRequest(_ request: URLRequest) throws {
        guard let method = request.httpMethod, let url = request.url else {
            throw GuardError.endpointNotAllowed
        }
        if request.httpBody != nil { throw GuardError.endpointNotAllowed }
        try guardURL(method: method, url: url)
    }

    public static func guardURL(method: String, url: URL) throws {
        guard sameBytes(method, "GET"),
              url.scheme == "https",
              url.host == "api.github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw GuardError.endpointNotAllowed
        }

        let full = url.absoluteString
        let prefix = "https://api.github.com/"
        guard full.hasPrefix(prefix) else { throw GuardError.endpointNotAllowed }
        let afterHost = Substring(full.dropFirst(prefix.count))
        let parts = afterHost.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let rawQuery: String? = parts.count > 1 ? String(parts[1]) : nil

        // None of the three discovery paths ever legitimately contains '%', '.', '\', or empty segments.
        guard !rawPath.isEmpty,
              !rawPath.utf8.contains(0x25),  // '%'
              !rawPath.utf8.contains(0x2E),  // '.'
              !rawPath.utf8.contains(0x5C)   // '\'
        else {
            throw GuardError.endpointNotAllowed
        }

        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.contains(where: \.isEmpty) {
            throw GuardError.endpointNotAllowed
        }

        if segments.count == 1, sameBytes(segments[0], "user") {
            guard rawQuery == nil else { throw GuardError.endpointNotAllowed }
            return
        }

        if segments.count == 2, sameBytes(segments[0], "user"), sameBytes(segments[1], "installations") {
            try guardPaginationQuery(rawQuery)
            return
        }

        if segments.count == 4,
           sameBytes(segments[0], "user"),
           sameBytes(segments[1], "installations"),
           isPositiveDecimalInt64(segments[2]),
           sameBytes(segments[3], "repositories") {
            try guardPaginationQuery(rawQuery)
            return
        }

        throw GuardError.endpointNotAllowed
    }

    private static func guardPaginationQuery(_ rawQuery: String?) throws {
        guard let rawQuery else { return }
        guard !rawQuery.isEmpty else { throw GuardError.endpointNotAllowed }
        var seen = Set<String>()
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let kv = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard kv.count == 2 else { throw GuardError.endpointNotAllowed }
            let key = String(kv[0])
            let val = String(kv[1])
            guard seen.insert(key).inserted else { throw GuardError.endpointNotAllowed }
            if sameBytes(key, "per_page") {
                guard isPositiveDecimalInt64(val), let n = Int(val), (1...100).contains(n) else {
                    throw GuardError.endpointNotAllowed
                }
            } else if sameBytes(key, "page") {
                guard isPositiveDecimalInt64(val), let n = Int(val), (1...10_000).contains(n) else {
                    throw GuardError.endpointNotAllowed
                }
            } else {
                throw GuardError.endpointNotAllowed
            }
        }
    }

    static func isPositiveDecimalInt64(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty, bytes.count <= 19, bytes[0] >= 0x31, bytes[0] <= 0x39 else { return false }
        guard bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
        guard let value = Int64(s), value > 0 else { return false }
        return true
    }
}

/// Client for GitHub App installation discovery and selection verification. Every request passes `DiscoveryGuard`
/// twice, uses `ReplyLimit.json` (Audit F-8), and paginates with a hard page cap.
public struct GitHubDiscoveryClient: Sendable {
    public static let defaultMaxPages = 10
    public static let perPage = 100

    private let transport: HTTPTransport
    private let tokens: TokenProvider
    public let maxPages: Int
    private let now: @Sendable () -> Date

    public init(transport: HTTPTransport, tokens: TokenProvider,
                maxPages: Int = GitHubDiscoveryClient.defaultMaxPages,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.tokens = tokens
        self.maxPages = max(1, maxPages)
        self.now = now
    }

    func request(_ apiPath: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.github.com/" + apiPath) else {
            throw GitHubError.badResponse("url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        try DiscoveryGuard.guardRequest(req)
        return req
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try DiscoveryGuard.guardRequest(request)
        var token = try await mapped { try await tokens.accessToken() }
        var (data, http) = try await sendOnce(request, token: token)
        if http.statusCode == 401 {
            let failed = token
            token = try await mapped { try await tokens.refresh(failed: failed) }
            (data, http) = try await sendOnce(request, token: token)
            if http.statusCode == 401 { throw GitHubError.unauthorized }
        }
        return (data, http)
    }

    private func mapped(_ body: () async throws -> String) async throws -> String {
        do {
            return try await body()
        } catch let e as URLError {
            throw GitHubHTTPClient.mapURLError(e)
        }
    }

    private func sendOnce(_ request: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.send(req, maxBytes: ReplyLimit.json)
        } catch let e as URLError {
            throw GitHubHTTPClient.mapURLError(e)
        }
    }

    private func getJSON(_ apiPath: String) async throws -> [String: Any] {
        let (data, http) = try await perform(try request(apiPath))
        guard (200..<300).contains(http.statusCode) else {
            throw mapFailure(http, data)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.badResponse("json")
        }
        return obj
    }

    private func mapFailure(_ http: HTTPURLResponse, _ data: Data) -> GitHubError {
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
            return .notFound
        case 500...599:
            return .server(http.statusCode)
        default:
            return .badResponse("status \(http.statusCode)")
        }
    }

    public func authenticatedUser() async throws -> GitHubAccount {
        let o = try await getJSON("user")
        guard let id = (o["id"] as? NSNumber)?.int64Value, id > 0,
              let login = o["login"] as? String, RepoTarget.isValidOwner(login) else {
            throw GitHubError.badResponse("user")
        }
        return GitHubAccount(id: id, login: login)
    }

    public func listInstallations() async throws -> [GitHubInstallation] {
        var out: [GitHubInstallation] = []
        var seen = Set<Int64>()
        for page in 1...maxPages {
            let o = try await getJSON("user/installations?per_page=\(Self.perPage)&page=\(page)")
            guard let raw = o["installations"] as? [[String: Any]] else {
                throw GitHubError.badResponse("installations")
            }
            for item in raw {
                guard let id = (item["id"] as? NSNumber)?.int64Value, id > 0 else { continue }
                let login = (item["account"] as? [String: Any])?["login"] as? String
                if seen.insert(id).inserted {
                    out.append(GitHubInstallation(id: id, accountLogin: login))
                }
            }
            let total = (o["total_count"] as? NSNumber)?.intValue
            if raw.count < Self.perPage || (total != nil && out.count >= total!) {
                break
            }
        }
        return out
    }

    public func listRepositories(installationId: Int64) async throws -> [DiscoveredRepo] {
        guard installationId > 0 else { throw DiscoveryGuard.GuardError.endpointNotAllowed }
        var out: [DiscoveredRepo] = []
        var seen = Set<Int64>()
        for page in 1...maxPages {
            let o = try await getJSON("user/installations/\(installationId)/repositories?per_page=\(Self.perPage)&page=\(page)")
            guard let raw = o["repositories"] as? [[String: Any]] else {
                throw GitHubError.badResponse("repositories")
            }
            for item in raw {
                guard let repoId = (item["id"] as? NSNumber)?.int64Value, repoId > 0,
                      let name = item["name"] as? String,
                      let owner = (item["owner"] as? [String: Any])?["login"] as? String else {
                    continue
                }
                let branch = (item["default_branch"] as? String) ?? "main"
                let priv = (item["private"] as? Bool) == true
                let vis = item["visibility"] as? String
                let isPrivate = priv && (vis == nil || sameBytes(vis!, "private"))
                guard let repo = try? DiscoveredRepo(
                    installationId: installationId,
                    repoId: repoId,
                    owner: owner,
                    name: name,
                    defaultBranch: branch,
                    isPrivate: isPrivate
                ) else {
                    continue
                }
                if seen.insert(repoId).inserted {
                    out.append(repo)
                }
            }
            let total = (o["total_count"] as? NSNumber)?.intValue
            if raw.count < Self.perPage || (total != nil && out.count >= total!) {
                break
            }
        }
        return out
    }

    /// Lists all repositories across every installation accessible to the signed-in user, private ones first.
    public func listAccessibleRepositories() async throws -> DiscoveryResult {
        let installations = try await listInstallations()
        guard !installations.isEmpty else {
            return DiscoveryResult(installationsCount: 0, repositories: [])
        }
        var repos: [DiscoveredRepo] = []
        var seen = Set<Int64>()
        for inst in installations {
            let list: [DiscoveredRepo]
            do {
                list = try await listRepositories(installationId: inst.id)
            } catch GitHubError.notFound, GitHubError.repoAccessLost {
                continue
            }
            for r in list where seen.insert(r.repoId).inserted {
                repos.append(r)
            }
        }
        repos.sort { a, b in
            if a.isPrivate != b.isPrivate { return a.isPrivate && !b.isPrivate }
            return a.slug.utf8.lexicographicallyPrecedes(b.slug.utf8)
        }
        return DiscoveryResult(installationsCount: installations.count, repositories: repos)
    }

    /// Verifies that `selection` is present in `GET /user/installations/{id}/repositories` for an installation returned
    /// by `GET /user/installations` for this token — matching numeric `repoId` AND byte-exact `owner` AND `name` —
    /// is still private, and returns the selection with its refreshed `defaultBranch`.
    public func verifySelection(_ selection: SelectedRepo) async throws -> SelectedRepo {
        let installations = try await listInstallations()
        guard !installations.isEmpty else { throw SelectionVerificationError.notListed }
        // Check the stored installation first, then any other installation returned for this user (e.g. if reinstalled).
        let ordered = installations.filter { $0.id == selection.installationId }
            + installations.filter { $0.id != selection.installationId }
        for inst in ordered {
            let repos: [DiscoveredRepo]
            do {
                repos = try await listRepositories(installationId: inst.id)
            } catch GitHubError.notFound, GitHubError.repoAccessLost {
                continue
            }
            if let match = repos.first(where: {
                $0.repoId == selection.repoId && sameBytes($0.owner, selection.owner) && sameBytes($0.name, selection.name)
            }) {
                guard match.isPrivate else {
                    throw SelectionVerificationError.publicRepo
                }
                return try SelectedRepo(
                    installationId: inst.id,
                    repoId: match.repoId,
                    owner: match.owner,
                    name: match.name,
                    defaultBranch: match.defaultBranch,
                    isPrivate: true
                )
            }
        }
        throw SelectionVerificationError.notListed
    }
}
