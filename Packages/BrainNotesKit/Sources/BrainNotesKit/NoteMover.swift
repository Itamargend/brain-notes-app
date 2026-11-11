import BrainMerge
import Foundation
import GRDB

/// Moves notes and folders, and keeps an empty folder on GitHub. Each change is one commit, made with the calls a
/// push makes (`createTree` on the head's tree, `createCommit`, `updateRef` with `force: false`). A moved file is a
/// delete of the old path plus the same bytes at the new one, so git keeps the same blob and GitHub sees a rename.
///
/// It needs GitHub now: a move is refused, with nothing changed, unless this device is on GitHub's head and the
/// notes involved have no unsynced changes. Call it while the engine is not running a sync (`waitUntilIdle`).
///
/// Before the ref update it writes the engine's own landing record (`pending_push`). A lost answer or a kill after
/// that point is settled by the engine's next run, with the engine's own code. See `docs/plan/move-pin-kit.md`.
public final class NoteMover: Sendable {
    public let store: NoteStore
    private let client: GitHubClient
    private let pins: PinsStore?
    private let config: SyncEngine.Config

    public init(store: NoteStore, client: GitHubClient, pins: PinsStore? = nil, config: SyncEngine.Config = SyncEngine.Config()) {
        self.store = store
        self.client = client
        self.pins = pins
        self.config = config
    }

    // MARK: operations

    /// Move a note into `folder` ("" for the top level). The folder is made if it is not there yet. A note with
    /// the same name there stays as it is: this one becomes `name 2.md`.
    @discardableResult
    public func moveNote(_ path: String, toFolder folder: String) async throws -> MoveResult {
        _ = try MovePlanner.destination(folder)
        let state = try await remoteState()
        let plan = try MovePlanner.note(path, into: folder, state.tree)
        let subject = "move \(plan.items[0].from) -> \(plan.items[0].to)"
        return try await commit(plan, adding: [], subject: subject, state: state)
    }

    /// Move a folder, with everything in it, into `parent` ("" for the top level). A folder with the same name
    /// there stays as it is: this one becomes `name 2`. A folder that exists only on this device moves here only.
    @discardableResult
    public func moveFolder(_ folder: String, into parent: String) async throws -> MoveResult {
        _ = try MovePlanner.destination(parent)
        if let local = try localOnlyFolderMove(folder, into: parent) { return local }
        let state = try await remoteState()
        let plan = try MovePlanner.folder(folder, into: parent, state.tree)
        let to = plan.folder?.to ?? folder
        let count = plan.items.count
        let subject = "move folder \(folder) -> \(to) (\(count) file\(count == 1 ? "" : "s"))"
        return try await commit(plan, adding: [], subject: subject, state: state)
    }

    /// A new folder, on this device and on GitHub. The name rules are `NoteStore.createFolder`'s. On GitHub the folder
    /// holds `_folder.md` (`FolderPlaceholder`) until it has notes. All or nothing: if GitHub can't be reached the
    /// folder is removed here again and the error is thrown. `NoteStore.createFolder` alone makes a folder on this
    /// device only, which reaches GitHub with its first note.
    @discardableResult
    public func createFolder(named typed: String, in parent: String) async throws -> MoveResult {
        let path = try store.createFolder(named: typed, in: parent)
        do {
            var result = try await keepFolderOnGitHub(path)
            result.folder = MoveResult.Move(from: path, to: path)
            return result
        } catch {
            removeIfEmpty(path)
            throw error
        }
    }

    /// Commit a placeholder for a folder that has nothing on GitHub yet. Nothing to do for a folder that already has.
    @discardableResult
    public func keepFolderOnGitHub(_ folder: String) async throws -> MoveResult {
        guard store.files.exists(folder) else { throw MoveProblem.notFound(folder) }
        let state = try await remoteState()
        guard let placeholder = try MovePlanner.placeholder(for: folder, state.tree) else { return MoveResult(outcome: .noCommit) }
        let plan = MovePlan(items: [], folder: nil, emptyFolders: [])
        return try await commit(plan, adding: [placeholder], subject: "add folder \(folder)", state: state)
    }

    // MARK: state

    struct RemoteState {
        var head: String
        var treeSha: String
        var tree: MoveTree
    }

    /// GitHub's tree at head, after checking this device is on that head with nothing waiting.
    private func remoteState() async throws -> RemoteState {
        guard let base = store.journal.baseCommit else { throw MoveProblem.notSyncedYet }
        guard store.journal.pendingPush() == nil else { throw MoveProblem.pushPending }
        let head: String
        switch try await client.getRef(etag: nil) {
        case let .head(sha, _): head = sha
        case .notModified: head = base
        }
        guard sameBytes(head, base) else { throw MoveProblem.behind }
        let commit = try await client.getCommit(head)
        let entries = try await client.tree(commit.treeSha)
        return RemoteState(head: head, treeSha: commit.treeSha, tree: localTree(entries: entries))
    }

    private func localTree(entries: [TreeEntry]) -> MoveTree {
        MoveTree(entries: entries, rows: store.journal.allFiles(), opPaths: store.journal.outbox().map(\.path),
                 emptyFolders: store.files.emptyFolders())
    }

    /// A folder with nothing in the journal under it: only its empty folders on this disk move, and no call is made.
    private func localOnlyFolderMove(_ folder: String, into parent: String) throws -> MoveResult? {
        guard !folder.isEmpty else { return nil }
        let tree = localTree(entries: [])
        let folded = foldKey(folder) + "/"
        let known = tree.rows.map(\.path) + tree.opPaths
        if known.contains(where: { MovePaths.hasPrefix(foldKey($0), folded) }) { return nil }
        guard tree.emptyFolders.contains(where: { sameBytes($0, folder) || MovePaths.hasPrefix($0, folder + "/") }) else { return nil }
        let plan = try MovePlanner.folder(folder, into: parent, tree)
        moveEmptyFolders(plan.emptyFolders)
        return MoveResult(folder: plan.folder, outcome: .noCommit)
    }

    // MARK: commit

    /// One commit for the whole plan, made and landed as the engine makes and lands a push.
    private func commit(_ plan: MovePlan, adding added: [String], subject: String, state: RemoteState) async throws -> MoveResult {
        // The bytes for each new path: the same blob as the old path, checked before anything is sent.
        var texts: [String] = []
        for item in plan.items { texts.append(try await text(of: item)) }
        let addedTexts = added.map { (path: $0, text: FolderPlaceholder.text) }

        var writes: [TreeWrite] = []
        for (item, text) in zip(plan.items, texts) {
            writes.append(TreeWrite(path: item.from, change: .delete))
            writes.append(TreeWrite(path: item.to, change: .content(text)))
        }
        for a in addedTexts { writes.append(TreeWrite(path: a.path, change: .content(a.text))) }
        let files = plan.items.map { MoveResult.Move(from: $0.from, to: $0.to) }
        guard !writes.isEmpty else {
            moveEmptyFolders(plan.emptyFolders)
            return MoveResult(files: files, folder: plan.folder, outcome: .noCommit)
        }

        let date = isoTime(store.now())
        let message = "notes: \(subject)\n\nBrain-Notes-Device: \(store.device)\nBrain-Notes-Op: \(store.newId())"
        let treeSha = try await client.createTree(baseTree: state.treeSha, writes: writes)
        let commitSha = try await client.createCommit(NewCommit(message: message, tree: treeSha, parent: state.head, date: date,
                                                                authorName: config.authorName, authorEmail: config.authorEmail))

        // The engine's record, so its next run can finish this commit if the answer below never arrives.
        var landingWrites = zip(plan.items, texts).map { SyncEngine.LandingPlan.Write(path: $0.to, content: $1, sha: $0.sha) }
        landingWrites += addedTexts.map { SyncEngine.LandingPlan.Write(path: $0.path, content: $0.text, sha: GitBlob.sha($0.text)) }
        let landing = SyncEngine.LandingPlan(commit: commitSha, parent: state.head, date: date, isCommit: true,
                                             writes: landingWrites, deletes: plan.items.map(\.from), effects: [], attention: [],
                                             moves: files.map { .init(from: $0.from, to: $0.to) })
        // A sync may have started since `remoteState` (the mover cannot stop one): its record is not ours to replace.
        guard store.journal.pendingPush() == nil else { throw MoveProblem.pushPending }
        try store.journal.setPendingPush(PendingPush(commit: commitSha, parent: state.head, planJSON: try JSONEncoder().encode(landing)))

        do {
            try await client.updateRef(to: commitSha)
        } catch GitHubError.notFastForward, GitHubError.unprocessable {
            try clearOwnRecord(commitSha)
            throw MoveProblem.remoteChanged
        } catch let error as GitHubError where Self.neverApplied(error) {
            try clearOwnRecord(commitSha)
            throw error
        } catch is CancellationError {
            // The request may be on its way: the record stays, and the engine's next run checks the ref.
            throw CancellationError()
        } catch {
            // Timeout, dropped connection, 5xx: the ref may or may not have moved. One look; else the engine settles it.
            guard case let .head(sha, _)? = try? await client.getRef(etag: nil), sameBytes(sha, commitSha) else {
                return MoveResult(files: files, folder: plan.folder, added: added, outcome: .unconfirmed(commit: commitSha))
            }
        }

        try land(plan, texts: texts, added: addedTexts, commit: commitSha)
        try? pins?.notesMoved(files)
        return MoveResult(files: files, folder: plan.folder, added: added, outcome: .landed(commit: commitSha))
    }

    /// Drops the landing record only if it is still this move's. A push that won the race may have written its
    /// own by now, and the engine needs that one to verify its commit.
    private func clearOwnRecord(_ commit: String) throws {
        guard let pending = store.journal.pendingPush(), sameBytes(pending.commit, commit) else { return }
        try store.journal.clearPendingPush()
    }

    /// Answers that mean GitHub did not move the ref.
    private static func neverApplied(_ error: GitHubError) -> Bool {
        switch error {
        case .unauthorized, .rateLimited, .repoAccessLost, .offline, .notFound: return true
        default: return false
        }
    }

    /// The exact text of the old path. From the disk when its bytes match GitHub's blob, else from GitHub.
    private func text(of item: MovePlan.Item) async throws -> String {
        if store.journal.file(item.from)?.local == true, let data = try store.files.readData(item.from),
           sameBytes(GitBlob.sha(data), item.sha) {
            guard let text = decodeNote(data) else { throw MoveProblem.notText(item.from) }
            return text
        }
        let data = try await client.blob(item.sha)
        // The HTTP client stops at this size already; any other client is held to it here.
        guard data.count <= config.limits.maxEntryBytes else { throw RepoTooLarge(.entry, max: config.limits.maxEntryBytes) }
        guard sameBytes(GitBlob.sha(data), item.sha) else { throw GitHubError.badResponse("blob hash") }
        guard let text = decodeNote(data), sameBytes(GitBlob.sha(text), item.sha) else { throw MoveProblem.notText(item.from) }
        return text
    }

    // MARK: landing

    /// The commit is on main: the device catches up in one journal transaction. Each file moves on disk with its row
    /// and blob sha, the base moves to the commit, and the landing record goes. If this throws, the record is still
    /// there and the engine's next run lands the commit with its own code.
    private func land(_ plan: MovePlan, texts: [String], added: [(path: String, text: String)], commit: String) throws {
        let files = store.files
        let stamp = isoTime(store.now())
        var written: [String] = []
        try store.journal.transaction { db in
            for (item, text) in zip(plan.items, texts) {
                let old = try Journal.file(db, item.from)
                let local: Bool
                if old?.local == true, files.exists(item.from) {
                    try files.move(item.from, to: item.to)
                    // The file is gone already; this tidies the folders it leaves empty.
                    try files.remove(item.from)
                    local = true
                } else {
                    local = try files.writeIfPossible(item.to, Data(text.utf8))
                }
                try Journal.removeFile(db, item.from)
                let st = local ? files.stat(item.to) : nil
                try Journal.putFile(db, FileRow(path: item.to, blobSha: item.sha, modified: old?.modified,
                                                diskSize: st?.size, diskMtime: st?.mtime, local: local))
                written.append(item.to)
            }
            for a in added {
                let local = try files.writeIfPossible(a.path, Data(a.text.utf8))
                let st = local ? files.stat(a.path) : nil
                try Journal.putFile(db, FileRow(path: a.path, blobSha: GitBlob.sha(a.text), modified: store.now(),
                                                diskSize: st?.size, diskMtime: st?.mtime, local: local))
                written.append(a.path)
            }
            try Journal.setMeta(db, Journal.Key.baseCommit, commit)
            try Journal.setMeta(db, Journal.Key.remoteHead, commit)
            try Journal.setMeta(db, Journal.Key.refEtag, nil)
            try Journal.setMeta(db, Journal.Key.lastCommitAt, stamp)
            try db.execute(sql: "DELETE FROM pending_push")
        }
        for item in plan.items { try? store.index.remove(path: item.from) }
        store.reindex(written)
        store.markIndexCurrent()
        moveEmptyFolders(plan.emptyFolders)
    }

    /// Empty folders exist only on this disk: they move here, after the files, and their old parents are tidied.
    private func moveEmptyFolders(_ moves: [MoveResult.Move]) {
        for m in moves {
            guard isEmptyFolder(m.from) else { continue }
            do {
                if !store.files.exists(m.to) { try store.files.move(m.from, to: m.to) }
                try store.files.remove(m.from)
            } catch {
                Log.store.error("empty folder move failed")
            }
        }
    }

    private func isEmptyFolder(_ path: String) -> Bool {
        guard let url = try? store.files.url(for: path),
              let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return items.isEmpty
    }

    /// Undo a folder made a moment ago, only while it is still empty.
    private func removeIfEmpty(_ path: String) {
        guard isEmptyFolder(path) else { return }
        try? store.files.remove(path)
    }
}
