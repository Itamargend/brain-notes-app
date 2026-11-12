import Foundation

public enum GitHubError: Error, Equatable, Sendable {
    /// 401 after one token refresh (or no refresh possible).
    case unauthorized
    /// 403/429 with retry-after or remaining 0.
    case rateLimited(until: Date?)
    /// 404 or 403 on the repo itself, or removed from installation.
    case repoAccessLost
    /// Repository is public (or non-private); Brain Notes refuses to sync it.
    case publicRepo
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
    /// Repository exists and is accessible, but has zero commits on its default branch yet.
    case empty
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

public struct InitialFile: Sendable, Equatable {
    public var path: String
    public var content: String
    public var message: String
    public var date: String
    public var authorName: String
    public var authorEmail: String

    public init(path: String, content: String, message: String, date: String, authorName: String, authorEmail: String) {
        self.path = path
        self.content = content
        self.message = message
        self.date = date
        self.authorName = authorName
        self.authorEmail = authorEmail
    }
}

public struct InitialCommitResult: Sendable, Equatable {
    public var commitSha: String
    public var blobSha: String

    public init(commitSha: String, blobSha: String) {
        self.commitSha = commitSha
        self.blobSha = blobSha
    }
}

/// Everything the app needs from GitHub. Implemented by `GitHubHTTPClient` and by `FakeGitHub`.
/// Ref updates are always fast-forward only (`force: false`); there is no way to ask for a force.
public protocol GitHubClient: Sendable {
    /// Verifies that the repository is still reachable and strictly private before syncing.
    func verifyPrivateRepo() async throws
    func getRef(etag: String?) async throws -> RefResult
    func getCommit(_ sha: String) async throws -> CommitInfo
    func compare(base: String, head: String) async throws -> Comparison
    /// Recursive listing. Throws if GitHub truncated it.
    func tree(_ sha: String) async throws -> [TreeEntry]
    func blob(_ sha: String) async throws -> Data
    func tarball(_ sha: String) async throws -> Data
    func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String
    func createCommit(_ commit: NewCommit) async throws -> String
    /// PATCH refs/heads/<defaultBranch> with `force: false`. Throws `.notFastForward` on 422.
    func updateRef(to sha: String) async throws
    /// Bootstraps an uninitialized (0-commit) repository on its default branch with the first note.
    func createInitialFile(_ file: InitialFile) async throws -> InitialCommitResult
    /// Date of the last commit that touched each path, as of `head`. At most 100 paths per call.
    func lastCommitDates(head: String, paths: [String]) async throws -> [PathDate]
}

public extension GitHubClient {
    func verifyPrivateRepo() async throws {}
    func createInitialFile(_ file: InitialFile) async throws -> InitialCommitResult {
        throw GitHubError.badResponse("empty-bootstrap-unsupported")
    }
}
