import Foundation

public enum GitHubError: Error, Equatable, Sendable {
    /// 401 after one token refresh (or no refresh possible).
    case unauthorized
    /// 403/429 with retry-after or remaining 0.
    case rateLimited(until: Date?)
    /// 404 or 403 on the repo itself.
    case repoAccessLost
    /// 422 on the ref update: not a fast-forward.
    case notFastForward
    /// Other 422 (invalid tree, too large).
    case unprocessable(String)
    case notFound
    case server(Int)
    /// Timeout or dropped connection; the request may or may not have been applied.
    case timedOut
    case offline
    case badResponse(String)
}

public enum RefResult: Sendable, Equatable {
    case notModified
    case head(sha: String, etag: String?)
}

public struct CommitInfo: Sendable, Equatable {
    public var sha: String
    public var treeSha: String
    public var parents: [String]
    public init(sha: String, treeSha: String, parents: [String]) {
        self.sha = sha; self.treeSha = treeSha; self.parents = parents
    }
}

public struct ChangedFile: Sendable, Equatable {
    public enum Status: String, Sendable { case added, modified, removed, renamed }
    public var path: String
    public var status: Status
    public var previousPath: String?
    public var sha: String?
    public init(path: String, status: Status, previousPath: String? = nil, sha: String? = nil) {
        self.path = path; self.status = status; self.previousPath = previousPath; self.sha = sha
    }
}

public struct Comparison: Sendable, Equatable {
    /// "ahead", "behind", "identical" or "diverged" (of head relative to base).
    public var status: String
    public var files: [ChangedFile]
    /// True when GitHub capped the file list (300 files).
    public var truncated: Bool
    public init(status: String, files: [ChangedFile], truncated: Bool = false) {
        self.status = status; self.files = files; self.truncated = truncated
    }
}

public struct TreeEntry: Sendable, Equatable {
    public var path: String
    public var sha: String
    public var isBlob: Bool
    public init(path: String, sha: String, isBlob: Bool = true) {
        self.path = path; self.sha = sha; self.isBlob = isBlob
    }
}

public struct TreeWrite: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case content(String), delete }
    public var path: String
    public var change: Change
    public init(path: String, change: Change) { self.path = path; self.change = change }
}

/// Everything the app needs from GitHub. Implemented by `GitHubHTTPClient` and by `FakeGitHub`.
/// Ref updates are always fast-forward only (`force: false`); there is no way to ask for a force.
public protocol GitHubClient: Sendable {
    func getRef(etag: String?) async throws -> RefResult
    func getCommit(_ sha: String) async throws -> CommitInfo
    func compare(base: String, head: String) async throws -> Comparison
    func tree(_ sha: String) async throws -> [TreeEntry]
    func blob(_ sha: String) async throws -> Data
    func tarball(_ sha: String) async throws -> Data
    func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String
    func createCommit(message: String, tree: String, parent: String, date: String, authorName: String, authorEmail: String) async throws -> String
    /// PATCH refs/heads/main with `force: false`. Throws `.notFastForward` on 422.
    func updateRef(to sha: String) async throws
}
