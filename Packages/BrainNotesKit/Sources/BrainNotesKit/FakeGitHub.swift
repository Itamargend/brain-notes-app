import Foundation

/// In-process GitHub: blobs, trees, commits, one `main` ref with compare-and-swap, ETags, compare with
/// GitHub's semantics, tarball generation, and injectable failures. Backs the tests and the demo mode.
/// It is an actor so tests and the engine can use it from any task. No network, no tokens.
public actor FakeGitHub: GitHubClient {
    /// The API call a failure applies to.
    public enum Call: String, Sendable, Hashable, CaseIterable {
        case getRef, getCommit, compare, tree, blob, tarball, createTree, createCommit, updateRef, lastCommitDates
    }

    public enum Fault: Sendable, Equatable {
        /// The request never reaches GitHub, the caller sees this error.
        case error(GitHubError)
        /// GitHub applies the request, the response is lost: the caller sees `.timedOut`.
        case lostResponse
    }

    struct Commit: Sendable {
        var sha: String
        var tree: String
        var parents: [String]
        var message: String
        var date: String
        var author: String
    }

    private var blobs: [String: Data] = [:]
    private var trees: [String: [PathKey: String]] = [:]  // tree sha -> path -> blob sha
    private var commits: [String: Commit] = [:]
    public private(set) var head: String = ""
    public private(set) var isPrivate = true
    private var faults: [Call: [Fault]] = [:]
    /// Commits made by anyone, oldest first, in landing order (for "no duplicates" checks).
    public private(set) var landed: [String] = []
    public private(set) var calls: [Call: Int] = [:]
    /// Runs inside `updateRef`, before the compare-and-swap: a bot wins the race.
    private var beforeUpdateRef: [@Sendable (FakeGitHub) async -> Void] = []
    /// `getRef` answers this sha for the next N reads, as a lagging read replica would.
    private var staleReads: [String] = []
    public var compareCap = 300
    /// Every `updateRef` sha, including failed ones.
    public private(set) var refUpdateAttempts: [String] = []
    private var clock: Date

    public init(files: [(path: String, text: String)] = [], date: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        clock = date
        var tree: [PathKey: String] = [:]
        for f in files {
            let data = Data(f.text.utf8)
            let sha = GitBlob.sha(data)
            blobs[sha] = data
            tree[PathKey(f.path)] = sha
        }
        let treeSha = Self.hash(tree)
        trees[treeSha] = tree
        let c = Self.makeCommit(tree: treeSha, parents: [], message: "Initial commit", date: isoTime(date), author: "fixture")
        commits[c.sha] = c
        head = c.sha
        landed = [c.sha]
    }

    /// Creates an uninitialized 0-commit repository (like a brand-new GitHub repository created without a README).
    public init(empty: Bool, isPrivate: Bool = true, date: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        clock = date
        self.isPrivate = isPrivate
        if !empty {
            let tree: [PathKey: String] = [:]
            let treeSha = Self.hash(tree)
            trees[treeSha] = tree
            let c = Self.makeCommit(tree: treeSha, parents: [], message: "Initial commit", date: isoTime(date), author: "fixture")
            commits[c.sha] = c
            head = c.sha
            landed = [c.sha]
        }
    }

    public func setPrivate(_ value: Bool) {
        isPrivate = value
    }

    private static func hash(_ tree: [PathKey: String]) -> String {
        var h = SHA1Hasher()
        for (k, v) in tree.sorted(by: { $0.key.path.utf8.lexicographicallyPrecedes($1.key.path.utf8) }) {
            h.update(data: Data(k.path.utf8))
            h.update(data: Data([0]))
            h.update(data: Data(v.utf8))
        }
        return h.hex()
    }

    /// Deterministic like git: same tree, parents, message, author and date give the same sha.
    private static func makeCommit(tree: String, parents: [String], message: String, date: String, author: String) -> Commit {
        var h = SHA1Hasher()
        h.update(data: Data(("commit\0" + tree + "\0" + parents.joined(separator: ",") + "\0" + author + "\0" + date + "\0" + message).utf8))
        return Commit(sha: h.hex(), tree: tree, parents: parents, message: message, date: date, author: author)
    }

    // MARK: test controls

    /// Demo dates: what history reports for these paths, when nothing newer touched them.
    private var pathDates: [PathKey: Date] = [:]
    public func setPathDates(_ dates: [(path: String, date: Date)]) {
        for d in dates { pathDates[PathKey(d.path)] = d.date }
    }

    /// Paths GitHub won't take: a tree that writes one is refused whole (422), as GitHub refuses a file it won't store.
    private var refusedPaths: Set<PathKey> = []
    public func refuseTrees(writing path: String) { refusedPaths.insert(PathKey(path)) }
    public func acceptTrees(writing path: String) { refusedPaths.remove(PathKey(path)) }

    public func inject(_ call: Call, _ fault: Fault) { faults[call, default: []].append(fault) }
    public func clearFaults() { faults = [:] }
    public func setCompareCap(_ cap: Int) { compareCap = cap }

    /// `body` runs inside the next `updateRef`, before its compare-and-swap.
    public func beforeNextUpdateRef(_ body: @escaping @Sendable (FakeGitHub) async -> Void) { beforeUpdateRef.append(body) }

    public func serveStaleRef(_ sha: String, times: Int) { staleReads = Array(repeating: sha, count: times) }

    private func gate(_ call: Call) throws -> Bool {
        calls[call, default: 0] += 1
        guard var q = faults[call], !q.isEmpty else { return false }
        let f = q.removeFirst()
        faults[call] = q
        switch f {
        case let .error(e): throw e
        case .lostResponse: return true
        }
    }

    public func count(_ call: Call) -> Int { calls[call] ?? 0 }

    /// A direct commit by someone else (the web UI, a bot). `nil` deletes a path.
    @discardableResult
    public func commitRemote(_ changes: [(path: String, text: String?)], message: String = "bot: update", date: Date? = nil) -> String {
        var tree = head.isEmpty ? [:] : (trees[commits[head]!.tree] ?? [:])
        for c in changes {
            if let text = c.text {
                let data = Data(text.utf8)
                let sha = GitBlob.sha(data)
                blobs[sha] = data
                tree[PathKey(c.path)] = sha
            } else {
                tree[PathKey(c.path)] = nil
            }
        }
        let treeSha = Self.hash(tree)
        trees[treeSha] = tree
        clock = (date ?? clock.addingTimeInterval(60))
        let parents = head.isEmpty ? [] : [head]
        let c = Self.makeCommit(tree: treeSha, parents: parents, message: message, date: isoTime(clock), author: "bot")
        commits[c.sha] = c
        head = c.sha
        landed.append(c.sha)
        return c.sha
    }

    /// Main rewritten: a new root commit with these files replaces history.
    public func forcePushForTest(files: [(path: String, text: String)]) {
        var tree: [PathKey: String] = [:]
        for f in files {
            let data = Data(f.text.utf8)
            let sha = GitBlob.sha(data)
            blobs[sha] = data
            tree[PathKey(f.path)] = sha
        }
        let treeSha = Self.hash(tree)
        trees[treeSha] = tree
        clock = clock.addingTimeInterval(60)
        let c = Self.makeCommit(tree: treeSha, parents: [], message: "rewritten", date: isoTime(clock), author: "bot")
        commits[c.sha] = c
        head = c.sha
    }

    public func files(at sha: String? = nil) -> [(path: String, text: String)] {
        guard let c = commits[sha ?? head], let tree = trees[c.tree] else { return [] }
        return tree.compactMap { k, v in
            guard let data = blobs[v] else { return nil }
            return (k.path, String(decoding: data, as: UTF8.self))
        }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    public func text(_ path: String) -> String? {
        guard let c = commits[head], let tree = trees[c.tree], let sha = tree[PathKey(path)], let d = blobs[sha] else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    public func has(_ path: String) -> Bool {
        guard let c = commits[head], let tree = trees[c.tree] else { return false }
        return tree[PathKey(path)] != nil
    }

    public func commitInfo(_ sha: String) -> (message: String, parents: [String], date: String, author: String)? {
        commits[sha].map { ($0.message, $0.parents, $0.date, $0.author) }
    }

    /// Messages of `main`, oldest first.
    public func history() -> [String] {
        var out: [String] = []
        var cur: String? = head
        while let c = cur, let commit = commits[c] {
            out.append(commit.message)
            cur = commit.parents.first
        }
        return out.reversed()
    }

    // MARK: ancestry

    private func isAncestor(_ a: String, of b: String) -> Bool {
        var stack = [b]
        var seen = Set<String>()
        while let c = stack.popLast() {
            if c == a { return true }
            if seen.insert(c).inserted, let commit = commits[c] { stack.append(contentsOf: commit.parents) }
        }
        return false
    }

    // MARK: GitHubClient

    public private(set) var verifyPrivateRepoCount = 0

    public func verifyPrivateRepo() async throws {
        verifyPrivateRepoCount += 1
        guard isPrivate else { throw GitHubError.publicRepo }
    }

    public func getRef(etag: String?) async throws -> RefResult {
        _ = try gate(.getRef)
        let sha = staleReads.isEmpty ? head : staleReads.removeFirst()
        if sha.isEmpty { return .empty }
        let tag = "W/\"\(sha)\""
        if let etag, etag == tag { return .notModified }
        return .head(sha: sha, etag: tag)
    }

    public func getCommit(_ sha: String) async throws -> CommitInfo {
        _ = try gate(.getCommit)
        guard let c = commits[sha] else { throw GitHubError.notFound }
        return CommitInfo(sha: sha, treeSha: c.tree, parents: c.parents, date: parseISOTime(c.date), message: c.message)
    }

    public func compare(base: String, head h: String) async throws -> Comparison {
        _ = try gate(.compare)
        guard let bc = commits[base], let hc = commits[h] else { throw GitHubError.notFound }
        let status: String
        if base == h {
            status = "identical"
        } else if isAncestor(base, of: h) {
            status = "ahead"
        } else if isAncestor(h, of: base) {
            status = "behind"
        } else {
            status = "diverged"
        }
        let bt = trees[bc.tree] ?? [:], ht = trees[hc.tree] ?? [:]
        var added: [(PathKey, String)] = [], removed: [(PathKey, String)] = []
        var files: [ChangedFile] = []
        for (k, v) in ht {
            if let old = bt[k] {
                if old != v { files.append(ChangedFile(path: k.path, status: .modified, sha: v)) }
            } else {
                added.append((k, v))
            }
        }
        for (k, v) in bt where ht[k] == nil { removed.append((k, v)) }
        // Same blob at one new path and one old path: GitHub reports a rename.
        var matchedAdded = Set<PathKey>()
        for (k, v) in removed {
            let hits = added.filter { $0.1 == v && !matchedAdded.contains($0.0) }
            let twins = removed.filter { $0.1 == v }
            if hits.count == 1, twins.count == 1 {
                matchedAdded.insert(hits[0].0)
                files.append(ChangedFile(path: hits[0].0.path, status: .renamed, previousPath: k.path, sha: v))
            } else {
                files.append(ChangedFile(path: k.path, status: .removed, sha: v))
            }
        }
        for (k, v) in added where !matchedAdded.contains(k) {
            files.append(ChangedFile(path: k.path, status: .added, sha: v))
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let truncated = files.count > compareCap
        return Comparison(status: status, files: truncated ? Array(files.prefix(compareCap)) : files,
                          truncated: truncated, headDate: parseISOTime(hc.date))
    }

    public func tree(_ sha: String) async throws -> [TreeEntry] {
        _ = try gate(.tree)
        guard let t = trees[sha] ?? commits[sha].flatMap({ trees[$0.tree] }) else { throw GitHubError.notFound }
        // As GitHub's `?recursive=1` does: every folder is listed too, as a `tree` entry, which is not a file.
        var entries = t.map { TreeEntry(path: $0.key.path, sha: $0.value) }
        var folders = Set<PathKey>()
        for e in entries {
            var p = MovePaths.parent(e.path)
            while !p.isEmpty, folders.insert(PathKey(p)).inserted { p = MovePaths.parent(p) }
        }
        entries += folders.map { TreeEntry(path: $0.path, sha: GitBlob.sha("tree " + $0.path), isFile: false) }
        return entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    public func blob(_ sha: String) async throws -> Data {
        _ = try gate(.blob)
        guard let d = blobs[sha] else { throw GitHubError.notFound }
        return d
    }

    public func tarball(_ sha: String) async throws -> Data {
        _ = try gate(.tarball)
        guard let c = commits[sha], let t = trees[c.tree] else { throw GitHubError.notFound }
        let items = t.compactMap { k, v in blobs[v].map { (path: k.path, data: $0) } }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let tar = TarWriter.archive(items, rootDir: "brain-notes-\(sha.prefix(7))")
        return try Gzip.compress(tar)
    }

    public func createTree(baseTree: String, writes: [TreeWrite]) async throws -> String {
        let lost = try gate(.createTree)
        guard var t = trees[baseTree] else { throw GitHubError.notFound }
        for w in writes where refusedPaths.contains(PathKey(w.path)) {
            if case .content = w.change { throw GitHubError.unprocessable("refused: \(w.path)") }
        }
        for w in writes {
            switch w.change {
            case let .content(text):
                let data = Data(text.utf8)
                let sha = GitBlob.sha(data)
                blobs[sha] = data
                t[PathKey(w.path)] = sha
            case .delete:
                // Spike S1: a delete of a path missing from the base tree fails the whole tree.
                guard t[PathKey(w.path)] != nil else { throw GitHubError.unprocessable("GitRPC::BadObjectState") }
                t[PathKey(w.path)] = nil
            }
        }
        let sha = Self.hash(t)
        trees[sha] = t
        if lost { throw GitHubError.timedOut }
        return sha
    }

    public func createCommit(_ c: NewCommit) async throws -> String {
        let lost = try gate(.createCommit)
        guard trees[c.tree] != nil, commits[c.parent] != nil else { throw GitHubError.unprocessable("missing object") }
        let commit = Self.makeCommit(tree: c.tree, parents: [c.parent], message: c.message, date: c.date, author: c.authorName + " <" + c.authorEmail + ">")
        commits[commit.sha] = commit
        if lost { throw GitHubError.timedOut }
        return commit.sha
    }

    public func updateRef(to sha: String) async throws {
        let lost = try gate(.updateRef)
        refUpdateAttempts.append(sha)
        if !beforeUpdateRef.isEmpty {
            let hook = beforeUpdateRef.removeFirst()
            await hook(self)
        }
        guard commits[sha] != nil else { throw GitHubError.unprocessable("Object does not exist") }
        // Compare and swap: only a fast-forward moves main. The same sha again is a no-op that succeeds.
        guard isAncestor(head, of: sha) else { throw GitHubError.notFastForward }
        if head != sha {
            head = sha
            landed.append(sha)
        }
        if lost { throw GitHubError.timedOut }
    }

    public func createInitialFile(_ file: InitialFile) async throws -> InitialCommitResult {
        if refusedPaths.contains(PathKey(file.path)) {
            throw GitHubError.unprocessable("refused: \(file.path)")
        }
        var tree: [PathKey: String] = [:]
        var parents: [String] = []
        if !head.isEmpty {
            guard let existing = commits[head], let curTree = trees[existing.tree] else {
                throw GitHubError.notFastForward
            }
            if curTree[PathKey(file.path)] != nil {
                throw GitHubError.notFastForward
            }
            tree = curTree
            parents = [head]
        }
        let data = Data(file.content.utf8)
        let blobSha = GitBlob.sha(data)
        blobs[blobSha] = data
        tree[PathKey(file.path)] = blobSha
        let treeSha = Self.hash(tree)
        trees[treeSha] = tree
        let commit = Self.makeCommit(
            tree: treeSha,
            parents: parents,
            message: file.message,
            date: file.date,
            author: file.authorName + " <" + file.authorEmail + ">"
        )
        commits[commit.sha] = commit
        head = commit.sha
        landed.append(commit.sha)
        return InitialCommitResult(commitSha: commit.sha, blobSha: blobSha)
    }

    public func lastCommitDates(head h: String, paths: [String]) async throws -> [PathDate] {
        _ = try gate(.lastCommitDates)
        var out: [PathDate] = []
        for p in paths {
            let key = PathKey(p)
            if let d = pathDates[key] {
                out.append(PathDate(path: p, date: d))
                continue
            }
            var cur = commits[h]
            var found: String?
            while let c = cur {
                let blob = trees[c.tree]?[key]
                let parent = c.parents.first.flatMap { commits[$0] }
                if blob != nil, parent == nil || trees[parent!.tree]?[key] != blob {
                    found = c.date
                    break
                }
                cur = parent
            }
            if let found, let d = parseISOTime(found) { out.append(PathDate(path: p, date: d)) }
        }
        return out
    }
}
