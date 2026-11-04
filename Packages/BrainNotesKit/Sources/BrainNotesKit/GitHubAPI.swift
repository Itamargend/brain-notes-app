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
    public var date: Date?
    public var message: String
    public init(sha: String, treeSha: String, parents: [String], date: Date? = nil, message: String = "") {
        self.sha = sha; self.treeSha = treeSha; self.parents = parents; self.date = date; self.message = message
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
    /// `compare/{base}...{head}`, status of head relative to base: "ahead" (base is an ancestor of head),
    /// "identical", "behind" (head is an ancestor of base) or "diverged".
    public var status: String
    public var files: [ChangedFile]
    /// True when GitHub capped the file list (300 files).
    public var truncated: Bool
    /// Date of the newest commit in the range.
    public var headDate: Date?
    public init(status: String, files: [ChangedFile], truncated: Bool = false, headDate: Date? = nil) {
        self.status = status; self.files = files; self.truncated = truncated; self.headDate = headDate
    }
}

public struct TreeEntry: Sendable, Equatable {
    public var path: String
    public var sha: String
    /// A regular file blob: not a folder, submodule or symlink.
    public var isFile: Bool
    public init(path: String, sha: String, isFile: Bool = true) {
        self.path = path; self.sha = sha; self.isFile = isFile
    }
}

public struct TreeWrite: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case content(String), delete }
    public var path: String
    public var change: Change
    public init(path: String, change: Change) { self.path = path; self.change = change }
}

public struct NewCommit: Sendable, Equatable {
    public var message: String
    public var tree: String
    public var parent: String
    /// Exact UTC string used for author and committer date: a retry must produce the same commit sha.
    public var date: String
    public var authorName: String
    public var authorEmail: String
    public init(message: String, tree: String, parent: String, date: String, authorName: String, authorEmail: String) {
        self.message = message; self.tree = tree; self.parent = parent; self.date = date
        self.authorName = authorName; self.authorEmail = authorEmail
    }
}

public struct PathDate: Sendable, Equatable {
    public var path: String
    public var date: Date
    public init(path: String, date: Date) { self.path = path; self.date = date }
}

/// Everything the app needs from GitHub. Implemented by `GitHubHTTPClient` and by `FakeGitHub`.
/// Ref updates are always fast-forward only (`force: false`); there is no way to ask for a force.
public protocol GitHubClient: Sendable {
    func getRef(etag: String?) async throws -> RefResult
    func getCommit(_ sha: String) async throws -> CommitInfo
    func compare(base: String, head: String) async throws -> Comparison
    /// Recursive listing. Throws if GitHub truncated it.
    func tree(_ sha: String) async throws -> [TreeEntry]
    func blob(_ sha: String) async throws -> Data
    func tarball(_ sha: String) async throws -> Data
    func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String
    func createCommit(_ commit: NewCommit) async throws -> String
    /// PATCH refs/heads/main with `force: false`. Throws `.notFastForward` on 422.
    func updateRef(to sha: String) async throws
    /// Date of the last commit that touched each path, as of `head`. At most 100 paths per call.
    func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate]
}
