import BrainMerge
import Foundation
import GRDB

public enum PauseReason: Sendable, Equatable {
    case user
    case rateLimited(until: Date?)
}

public enum FirstSyncPhase: Sendable, Equatable {
    case downloading
    case verifying(done: Int, total: Int)
    case indexing(done: Int, total: Int)
}

public enum SyncState: Sendable, Equatable {
    case idle
    case checking, pulling, merging, applying, pushing, verifying
    case firstSync(FirstSyncPhase)
    case needsAttention(Int)
    case signedOut
    case paused(PauseReason)
    case offline
    /// 5xx or timeouts: waiting before the next try.
    case retrying(at: Date)
    /// 404 or 403 on the repo: sync stops, data is kept.
    case accessLost

    public var isBusy: Bool {
        switch self {
        case .checking, .pulling, .merging, .applying, .pushing, .verifying, .firstSync: return true
        default: return false
        }
    }
}

public struct SyncSnapshot: Sendable, Equatable {
    public var state: SyncState = .idle
    public var unsynced = 0
    public var attention = 0
    public var lastSync: Date?
    public var oldestUnsynced: Date?
    public var hasFirstSynced = false

    public init() {}

    /// Plan: a badge if anything stays unsynced for 24 hours.
    public func unsyncedTooLong(now: Date) -> Bool {
        oldestUnsynced.map { now.timeIntervalSince($0) > 24 * 3600 } ?? false
    }
}

public enum SyncEvent: Sendable, Equatable {
    case snapshot(SyncSnapshot)
    /// These notes changed on disk, or are gone, because of a sync.
    case notesChanged([String])
    /// GitHub renamed a note: an open editor follows it.
    case noteMoved(from: String, to: String)
}

public enum SyncTrigger: Sendable, Equatable {
    /// Timer while open. Pushes only after the idle wait and within the commit cap.
    case poll
    /// App came to the foreground, or the network returned. Same rules as a poll, but runs now.
    case foreground
    /// Left a note: no idle wait, still at most one commit a minute.
    case leftNote
    /// App is leaving the screen: this may be the last chance for a while, so no idle wait and no cap.
    case background
    /// User asked, or a test. No idle wait and no cap.
    case manual
}

/// The sync state machine (plan v2): Check, Pull, Merge, Apply, Push, Verify. Foreground only.
/// All merges run here, off the main thread. Local edits never wait for any of this.
public actor SyncEngine {
    public struct Config: Sendable {
        public var pollInterval: TimeInterval = 60
        public var idleFlush: TimeInterval = 30
        public var minCommitInterval: TimeInterval = 60
        public var maxPushRetries = 3
        public var jitter: ClosedRange<Double> = 1...4
        public var maxBackoff: TimeInterval = 300
        public var staleReadDelay: TimeInterval = 2
        public var blobConcurrency = 6
        public var authorName = "Brain Notes"
        public var authorEmail = "brain-notes-app@noreply.invalid"
        public init() {}
    }

    enum EngineError: Error, Equatable {
        case historyRewritten
        /// The batch or an op cannot be pushed as it is. Goes to Needs attention, the rest continue.
        case rejected(String)
    }

    public let store: NoteStore
    private let client: GitHubClient
    private let config: Config
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let random: @Sendable (ClosedRange<Double>) -> Double

    public nonisolated let events: AsyncStream<SyncEvent>
    private nonisolated let continuation: AsyncStream<SyncEvent>.Continuation

    public private(set) var snapshot = SyncSnapshot()
    private var running = false
    private var rerun: SyncTrigger?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var online = true
    private var signedOut = false
    private var accessLost = false
    private var userPaused: Bool
    private var pausedUntil: Date?
    private var backoffStep = 0
    private var retryAt: Date?
    private var lastLocalEdit: Date = .distantPast
    private var lastPushAttempt: Date = .distantPast
    private var started = false
    private var wakeTask: Task<Void, Never>?
    /// Blob bodies fetched during one run, by sha, so a 422 retry does not fetch them twice.
    private var blobCache: [String: Data] = [:]

    public init(store: NoteStore, client: GitHubClient, config: Config = Config(),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
        self.store = store
        self.client = client
        self.config = config
        self.now = now
        self.sleep = sleep
        self.random = random
        (events, continuation) = AsyncStream.makeStream(of: SyncEvent.self, bufferingPolicy: .bufferingNewest(64))
        userPaused = store.journal.meta(Journal.Key.userPaused) == "1"
    }

    // MARK: - Triggers

    /// Begin polling. Foreground only: the app calls `stop` when it leaves the screen.
    public func start() async {
        started = true
        publish(restingState())
        await sync(.foreground)
        reschedule()
    }

    public func stop() {
        started = false
        wakeTask?.cancel()
        wakeTask = nil
    }

    /// A save happened: wait for the idle time before pushing.
    public func noteSaved() {
        lastLocalEdit = now()
        publish(snapshot.state)
        reschedule()
    }

    public func setOnline(_ value: Bool) async {
        let was = online
        online = value
        if value && !was {
            retryAt = nil
            await sync(.foreground)
            reschedule()
        } else if !value {
            publish(.offline)
        }
    }

    public func setPaused(_ paused: Bool) async {
        userPaused = paused
        try? store.journal.setMeta(Journal.Key.userPaused, paused ? "1" : nil)
        publish(restingState())
        if !paused { await sync(.foreground) }
        reschedule()
    }

    public var isUserPaused: Bool { userPaused }

    /// Sign-in finished: tokens are in the store, sync can run.
    public func signedIn() async {
        signedOut = false
        accessLost = false
        await sync(.manual)
        reschedule()
    }

    /// Timer tick.
    private func tick() async {
        await sync(.poll)
        reschedule()
    }

    private func reschedule() {
        wakeTask?.cancel()
        wakeTask = nil
        guard started else { return }
        let delay = nextDelay()
        let sleep = self.sleep
        wakeTask = Task { [weak self] in
            try? await sleep(delay)
            if Task.isCancelled { return }
            await self?.tick()
        }
    }

    private func nextDelay() -> TimeInterval {
        let t = now()
        var next = t.addingTimeInterval(config.pollInterval)
        // An earlier wake only for edits made since the last push attempt. Ops that stay in the outbox
        // (blocked, parked) wait for the normal poll: they must not turn this into a tight loop.
        if lastLocalEdit > lastPushAttempt, store.journal.outboxCount() > 0 {
            let idleDue = lastLocalEdit.addingTimeInterval(config.idleFlush)
            let due = max(idleDue, lastCommitAt().addingTimeInterval(config.minCommitInterval))
            next = min(next, due)
        }
        if let retryAt { next = retryAt }
        if let pausedUntil { next = max(next, pausedUntil) }
        return max(1, next.timeIntervalSince(t))
    }

    private func lastCommitAt() -> Date {
        store.journal.meta(Journal.Key.lastCommitAt).flatMap(parseISOTime) ?? .distantPast
    }

    // MARK: - One run

    /// Runs one sync. If one is already running, it runs again after it, and this call returns when both are done.
    public func sync(_ trigger: SyncTrigger = .manual) async {
        if running {
            rerun = Self.stronger(rerun, trigger)
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        var next: SyncTrigger? = trigger
        while let t = next {
            rerun = nil
            await runOnce(t)
            next = rerun
        }
        running = false
        blobCache = [:]
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    private static func stronger(_ a: SyncTrigger?, _ b: SyncTrigger) -> SyncTrigger {
        func rank(_ t: SyncTrigger?) -> Int {
            switch t {
            case nil: return 0
            case .poll?: return 1
            case .foreground?: return 2
            case .leftNote?: return 3
            case .background?, .manual?: return 4
            }
        }
        return rank(a) >= rank(b) ? (a ?? b) : b
    }

    private func runOnce(_ trigger: SyncTrigger) async {
        if userPaused { return publish(.paused(.user)) }
        if signedOut, trigger != .manual { return publish(.signedOut) }
        if !online { return publish(.offline) }
        let t = now()
        if let until = pausedUntil {
            if until > t { return publish(.paused(.rateLimited(until: until))) }
            pausedUntil = nil
        }
        if trigger == .poll, let at = retryAt, at > t { return publish(.retrying(at: at)) }
        if hasOpenRewriteItem() { return publish(restingState()) }
        do {
            if store.journal.baseCommit == nil {
                try await firstSync()
            }
            try await resolvePendingPush()
            try await checkPullPush(trigger)
            try await refetchMissing()
            await backfillDatesIfNeeded()
            backoffStep = 0
            retryAt = nil
            accessLost = false
            signedOut = false
            try? store.journal.setMeta(Journal.Key.lastSync, isoTime(now()))
            publish(restingState())
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        switch error {
        case GitHubError.unauthorized:
            signedOut = true
            publish(.signedOut)
        case let GitHubError.rateLimited(until):
            let resume = until ?? now().addingTimeInterval(60)
            pausedUntil = resume
            publish(.paused(.rateLimited(until: resume)))
        case GitHubError.repoAccessLost:
            accessLost = true
            publish(.accessLost)
        case GitHubError.offline:
            publish(.offline)
        case EngineError.historyRewritten:
            recordRewrite()
            publish(restingState())
        case is CancellationError:
            publish(restingState())
        case is TokenStoreError, is FileStoreError:
            // Device locked mid-run: nothing is lost, the next foreground run continues.
            Log.sync.notice("sync stopped: local data not readable right now")
            publish(restingState())
        default:
            // 5xx, timeouts and anything unexpected: back off 2, 4, 8 s up to 5 min.
            backoffStep += 1
            let delay = min(pow(2, Double(backoffStep)), config.maxBackoff)
            let at = now().addingTimeInterval(delay)
            retryAt = at
            Log.sync.error("sync failed, retry in \(delay, privacy: .public) s")
            publish(.retrying(at: at))
        }
    }

    /// The next retry delay, for tests.
    public var currentBackoffStep: Int { backoffStep }

    /// Seconds until the scheduler would wake, for tests.
    var delayUntilNextWake: TimeInterval { nextDelay() }

    /// Ends the event stream, so a test can read everything that was published.
    func finishEvents() { continuation.finish() }

    private func restingState() -> SyncState {
        if userPaused { return .paused(.user) }
        if signedOut { return .signedOut }
        if accessLost { return .accessLost }
        let open = store.journal.attentionCount()
        if open > 0 { return .needsAttention(open) }
        return .idle
    }

    private func publish(_ state: SyncState) {
        snapshot.state = state
        snapshot.unsynced = store.journal.outboxCount()
        snapshot.attention = store.journal.attentionCount()
        snapshot.lastSync = store.journal.meta(Journal.Key.lastSync).flatMap(parseISOTime)
        snapshot.oldestUnsynced = store.journal.oldestOpTime()
        snapshot.hasFirstSynced = store.journal.baseCommit != nil
        continuation.yield(.snapshot(snapshot))
    }

    /// App state refresh after a change made outside a run (attention resolved, note deleted).
    public func refresh() {
        publish(running ? snapshot.state : restingState())
    }

    // MARK: - Check

    /// `Checking`, then `Pulling`/`Applying` if main moved, then `Merging`/`Pushing` if there is something to send.
    private func checkPullPush(_ trigger: SyncTrigger) async throws {
        var attempt = 0
        while true {
            publish(.checking)
            var head = try await currentHead(useEtag: attempt == 0)
            if head != store.journal.baseCommit { head = try await pull(to: head) }
            guard shouldPush(trigger) else { return }
            lastPushAttempt = now()
            do {
                try await pushAll(head: head)
                return
            } catch GitHubError.notFastForward {
                // Someone pushed first (scenario 7): pull, merge, rebuild on the new head, retry with jitter.
                attempt += 1
                if attempt > config.maxPushRetries {
                    recordPushFailed()
                    return
                }
                try await sleep(random(config.jitter))
            }
        }
    }

    private func shouldPush(_ trigger: SyncTrigger) -> Bool {
        guard store.journal.outbox().contains(where: { !$0.parked }) else { return false }
        let t = now()
        switch trigger {
        case .manual, .background:
            return true
        case .leftNote:
            return t.timeIntervalSince(lastCommitAt()) >= config.minCommitInterval
        case .poll, .foreground:
            return t.timeIntervalSince(lastLocalEdit) >= config.idleFlush
                && t.timeIntervalSince(lastCommitAt()) >= config.minCommitInterval
        }
    }

    private func currentHead(useEtag: Bool) async throws -> String {
        let j = store.journal
        let etag = useEtag ? j.meta(Journal.Key.refEtag) : nil
        switch try await client.getRef(etag: etag) {
        case .notModified:
            if let known = j.meta(Journal.Key.remoteHead) { return known }
            return try await currentHead(useEtag: false)
        case let .head(sha, tag):
            try j.transaction { db in
                try Journal.setMeta(db, Journal.Key.remoteHead, sha)
                try Journal.setMeta(db, Journal.Key.refEtag, tag)
            }
            return sha
        }
    }

    // MARK: - Pull

    private struct RemoteChange {
        enum Kind { case upsert, remove }
        var path: String
        var kind: Kind
        var sha: String?
        /// For `.remove` of a renamed path, the new path.
        var renamedTo: String?
    }

    /// Brings the journal to `head` and returns the head to build on. Clean notes are replaced on disk.
    /// A dirty note keeps its text; only its blob sha moves, and the merge happens at push.
    private func pull(to head: String) async throws -> String {
        publish(.pulling)
        guard let base = store.journal.baseCommit else { return head }
        try await ensureMergeBases()
        let comparison: Comparison
        do {
            comparison = try await client.compare(base: base, head: head)
        } catch GitHubError.notFound {
            // The base commit is gone, or the repo is: a fresh ref read tells them apart.
            _ = try await client.getRef(etag: nil)
            throw EngineError.historyRewritten
        }
        switch comparison.status {
        case "identical":
            try moveBase(to: head)
            return head
        case "ahead":
            break
        default:
            // Not a fast-forward from our base. A read replica lagging behind our own push looks the same,
            // so look again before calling it a rewrite.
            try await sleep(config.staleReadDelay)
            let fresh = try await currentHead(useEtag: false)
            if fresh == base { return base }
            if fresh == head { throw EngineError.historyRewritten }
            return try await pull(to: fresh)
        }

        let date: Date?
        let changes: [RemoteChange]
        if comparison.truncated {
            let commit = try await client.getCommit(head)
            date = commit.date
            changes = try await treeDiff(treeSha: commit.treeSha)
        } else {
            date = comparison.headDate
            changes = Self.changes(from: comparison)
        }

        let bodies = try await fetchBodies(changes)
        publish(.applying)
        try apply(changes, bodies: bodies, date: date ?? now())
        try moveBase(to: head)
        store.markIndexCurrent()
        return head
    }

    /// A note found edited at launch has a merge base known only as a blob sha. Fetch its text while
    /// that sha still means the base, before a pull moves it to GitHub's newer version.
    private func ensureMergeBases() async throws {
        for row in store.journal.allFiles() where row.dirty && row.baseText == nil {
            guard let sha = row.blobSha else { continue }
            let text: String
            do { text = try await self.text(ofBlob: sha) } catch EngineError.rejected { continue }
            try store.journal.transaction { db in
                try db.execute(sql: "UPDATE files SET base_text = ? WHERE path = ? AND base_text IS NULL", arguments: [text, row.path])
            }
        }
    }

    private func moveBase(to head: String) throws {
        try store.journal.transaction { db in
            try Journal.setMeta(db, Journal.Key.baseCommit, head)
            try Journal.setMeta(db, Journal.Key.remoteHead, head)
        }
    }

    private static func changes(from c: Comparison) -> [RemoteChange] {
        var out: [RemoteChange] = []
        for f in c.files {
            switch f.status {
            case .removed:
                if PathPolicy.isSyncable(f.path) { out.append(RemoteChange(path: f.path, kind: .remove)) }
            case .added, .modified:
                if PathPolicy.isSyncable(f.path) { out.append(RemoteChange(path: f.path, kind: .upsert, sha: f.sha)) }
            case .renamed:
                let newOK = PathPolicy.isSyncable(f.path)
                if let old = f.previousPath, PathPolicy.isSyncable(old) {
                    out.append(RemoteChange(path: old, kind: .remove, renamedTo: newOK ? f.path : nil))
                }
                if newOK { out.append(RemoteChange(path: f.path, kind: .upsert, sha: f.sha)) }
            }
        }
        return out
    }

    /// Over 300 changed files: compare the head tree with the journal's blob shas.
    /// A removed path and an added path with the same blob, one to one, are a rename.
    private func treeDiff(treeSha: String) async throws -> [RemoteChange] {
        let entries = try await client.tree(treeSha).filter { $0.isFile && PathPolicy.isSyncable($0.path) }
        var remote: [PathKey: String] = [:]
        for e in entries { remote[PathKey(e.path)] = e.sha }
        var known: [PathKey: String] = [:]
        for row in store.journal.allFiles() {
            if let sha = row.blobSha { known[PathKey(row.path)] = sha }
        }
        let added = entries.filter { known[PathKey($0.path)] == nil }
        let removed = known.filter { remote[$0.key] == nil }
        var out: [RemoteChange] = []
        for (k, sha) in removed {
            let hits = added.filter { $0.sha == sha }
            let twins = removed.filter { $0.value == sha }
            out.append(RemoteChange(path: k.path, kind: .remove, renamedTo: hits.count == 1 && twins.count == 1 ? hits[0].path : nil))
        }
        for e in entries where known[PathKey(e.path)] != e.sha {
            out.append(RemoteChange(path: e.path, kind: .upsert, sha: e.sha))
        }
        return out
    }

    private func fetchBodies(_ changes: [RemoteChange]) async throws -> [String: Data] {
        var wanted: [String] = []
        var seen = Set<String>()
        for c in changes {
            if let sha = c.sha, blobCache[sha] == nil, seen.insert(sha).inserted { wanted.append(sha) }
        }
        var fetched = try await fetchBlobs(wanted)
        for c in changes {
            if let sha = c.sha, let d = blobCache[sha] { fetched[sha] = d }
        }
        for (sha, d) in fetched { blobCache[sha] = d }
        return fetched
    }

    /// Blob bodies by sha, verified, a few at a time.
    private func fetchBlobs(_ shas: [String]) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        let client = self.client
        var pending = shas[...]
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var active = 0
            func launch() {
                while active < config.blobConcurrency, let sha = pending.popFirst() {
                    active += 1
                    group.addTask {
                        let data = try await client.blob(sha)
                        guard GitBlob.sha(data) == sha else { throw GitHubError.badResponse("blob hash") }
                        return (sha, data)
                    }
                }
            }
            launch()
            while let (sha, data) = try await group.next() {
                out[sha] = data
                active -= 1
                launch()
            }
        }
        return out
    }

    /// Clean notes change on disk, dirty notes only move their blob sha. Removes run before writes so a
    /// case-only rename frees its name first. Safe to repeat: the base moves only after this finishes.
    private func apply(_ changes: [RemoteChange], bodies: [String: Data], date: Date) throws {
        let ordered = changes.filter { $0.kind == .remove } + changes.filter { $0.kind == .upsert }
        var touched: [String] = []
        var moved: [(String, String)] = []
        let files = store.files
        let created = isoTime(now())
        var chunkStart = 0
        var removedSoFar = Set<PathKey>()
        for c in ordered where c.kind == .remove { removedSoFar.insert(PathKey(c.path)) }
        var tree = PathIndex(store.journal.allFiles().map(\.path).filter { !removedSoFar.contains(PathKey($0)) })

        // Chunks, so a very large pull does not hold the journal against a save.
        while chunkStart < ordered.count {
            let chunk = ordered[chunkStart..<min(chunkStart + 100, ordered.count)]
            chunkStart += chunk.count
            try store.journal.transaction { db in
                for c in chunk {
                    let row = try Journal.file(db, c.path)
                    switch c.kind {
                    case .remove:
                        guard var row else { continue }
                        if row.dirty {
                            row.blobSha = nil
                            row.renameTo = c.renamedTo
                            try Journal.putFile(db, row)
                        } else {
                            try files.remove(c.path)
                            try Journal.removeFile(db, c.path)
                            touched.append(c.path)
                            if let to = c.renamedTo { moved.append((c.path, to)) }
                        }
                    case .upsert:
                        guard let sha = c.sha else { continue }
                        if var row, row.dirty {
                            row.blobSha = sha
                            try Journal.putFile(db, row)
                            continue
                        }
                        if let row, row.blobSha == sha, row.local, files.exists(c.path) { continue }
                        // A second spelling that cannot exist next to the first on this file system stays on
                        // GitHub only. It still counts for the planner, and it is listed in Needs attention.
                        if row == nil || row?.local == false, let other = tree.clash(c.path) {
                            try Journal.putFile(db, FileRow(path: c.path, blobSha: sha, modified: date, local: false))
                            try Journal.addAttention(db, path: c.path, reason: "case-clash", detail: other, created: created)
                            continue
                        }
                        guard let data = bodies[sha] else { throw GitHubError.badResponse("missing body") }
                        try files.write(c.path, data)
                        let st = files.stat(c.path)
                        try Journal.putFile(db, FileRow(path: c.path, blobSha: sha, modified: date, diskSize: st?.size, diskMtime: st?.mtime))
                        tree.add(c.path)
                        touched.append(c.path)
                    }
                }
            }
        }
        store.reindex(touched)
        if !touched.isEmpty { continuation.yield(.notesChanged(touched)) }
        for (from, to) in moved { continuation.yield(.noteMoved(from: from, to: to)) }
    }

    /// Files the journal has but the disk lost (restored device): download them again, by blob sha.
    private func refetchMissing() async throws {
        let rows = store.journal.allFiles().filter { !$0.dirty && $0.local && $0.blobSha != nil && !store.files.exists($0.path) }
        guard !rows.isEmpty else { return }
        let bodies = try await fetchBlobs(Array(Set(rows.compactMap(\.blobSha))))
        var touched: [String] = []
        let files = store.files
        for row in rows {
            guard let sha = row.blobSha, let data = bodies[sha] else { continue }
            // Looked at again here: a save during the download must not be overwritten.
            try store.journal.transaction { db in
                guard let cur = try Journal.file(db, row.path), !cur.dirty, cur.blobSha == sha else { return }
                try files.write(row.path, data)
                let st = files.stat(row.path)
                try db.execute(sql: "UPDATE files SET disk_size = ?, disk_mtime = ? WHERE path = ?", arguments: [st?.size, st?.mtime, row.path])
                touched.append(row.path)
            }
        }
        store.reindex(touched)
        if !touched.isEmpty { continuation.yield(.notesChanged(touched)) }
    }

    // MARK: - Push

    /// One commit for all pushable ops. If GitHub or the planner refuses it, each op is tried alone, so
    /// the bad one goes to Needs attention and the others still land (scenario 10).
    private func pushAll(head: String) async throws {
        let ops = store.journal.outbox().filter { !$0.parked }
        do {
            try await pushBatch(ops, head: head)
        } catch let EngineError.rejected(why) {
            guard ops.count > 1 else {
                if let op = ops.first { try park(op, why: why) }
                return
            }
            for op in ops {
                guard let current = store.journal.baseCommit else { return }
                do {
                    try await pushBatch([op], head: current)
                } catch let EngineError.rejected(why) {
                    try park(op, why: why)
                }
            }
        }
    }

    private func park(_ op: OutboxOp, why: String) throws {
        let created = isoTime(now())
        try store.journal.transaction { db in
            try db.execute(sql: "UPDATE outbox SET parked = 1, in_flight = 0 WHERE seq = ?", arguments: [op.seq])
            try Journal.addAttention(db, path: op.path, reason: "rejected", detail: why, created: created)
        }
    }

    private func recordPushFailed() {
        let created = isoTime(now())
        let paths = store.journal.outbox().filter { !$0.parked }.map(\.path)
        try? store.journal.transaction { db in
            for p in paths { try Journal.addAttention(db, path: p, reason: "push-failed", created: created) }
        }
    }

    /// What a landed commit means for the device. Stored before the ref update, so a lost response or a
    /// kill can finish the job later without anything recomputed.
    struct LandingPlan: Codable, Equatable {
        struct Write: Codable, Equatable {
            var path: String
            var content: String
            var sha: String
        }
        struct Effect: Codable, Equatable {
            var seq: Int64
            var rev: Int
            var opPath: String
            /// The text this op pushed: the merge base for anything typed after it (nil for a delete).
            var mine: String?
            /// Where the note is on GitHub after the commit (`opPath` unless GitHub renamed it).
            var target: String
            /// Text at `target` when this commit does not write it; nil if absent or written by the commit.
            var finalText: String?
            var finalExists: Bool
            var finalSha: String?
        }
        struct NewAttention: Codable, Equatable {
            var path: String
            var reason: String
            var copy: String?
            var detail: String?
        }
        var commit: String
        var parent: String
        var date: String
        var isCommit: Bool
        var writes: [Write]
        var deletes: [String]
        var effects: [Effect]
        var attention: [NewAttention]
    }

    /// Merging, then Pushing. Throws `.notFastForward` to the caller's retry loop.
    private func pushBatch(_ ops: [OutboxOp], head: String) async throws {
        guard !ops.isEmpty else { return }
        publish(.merging)
        let rows = store.journal.allFiles()
        var rowByPath: [PathKey: FileRow] = [:]
        for r in rows { rowByPath[PathKey(r.path)] = r }

        // Both trees list every path on main; only texts the planner reads are loaded. The other paths
        // carry an empty placeholder. The planner reads a text only for op targets, `_trash` candidates
        // and paths in one tree but not the other, and all of those are loaded below.
        var baseTree = PathMap()
        var theirsTree = PathMap()
        for r in rows where r.blobSha != nil {
            baseTree[r.path] = ""
            theirsTree[r.path] = ""
        }
        var renames = PathMap()
        var planOps: [Op] = []
        var planned: [OutboxOp] = []
        var blocked: [(OutboxOp, String)] = []
        var theirsByTarget: [PathKey: String] = [:]

        func remember(_ path: String, _ text: String?) {
            guard let text else { return }
            theirsByTarget[PathKey(path)] = text
            theirsTree[path] = text
        }

        for op in ops {
            guard let row = rowByPath[PathKey(op.path)] else { continue }
            var base = row.baseText
            do {
                // Base known only as a blob sha: a file edited outside the app, found at launch.
                if base == nil, op.kind != .create, let sha = row.blobSha {
                    base = try await text(ofBlob: sha)
                    try store.journal.transaction { db in
                        try db.execute(sql: "UPDATE files SET base_text = ? WHERE path = ? AND base_text IS NULL", arguments: [base, op.path])
                    }
                }
                remember(op.path, try await theirsText(of: row))
                if let to = row.renameTo, let targetRow = rowByPath[PathKey(to)] {
                    let text = try await theirsText(of: targetRow)
                    remember(to, text)
                    if text != nil { renames[op.path] = to }
                }
                if op.kind == .delete {
                    let target = row.renameTo ?? op.path
                    let trashKey = foldKey(nfc("_trash/\(target)"))
                    for r in rows where r.blobSha != nil && sameBytes(foldKey(r.path), trashKey) {
                        remember(r.path, try await theirsText(of: r))
                    }
                }
            } catch EngineError.rejected(let why) {
                blocked.append((op, "rejected:" + why))
                continue
            }
            // A note I created has no base; everything else merges against the text the edit started from.
            if let base, op.kind != .create {
                baseTree[op.path] = base
            } else {
                baseTree[op.path] = nil
            }
            switch op.kind {
            case .delete:
                planOps.append(.delete(path: op.path))
            case .edit, .create:
                guard let mine = op.content else { continue }
                if let kind = SecretScan.scanAdded(mine, comparedTo: base) {
                    blocked.append((op, "blocked:secret:" + kind))
                    continue
                }
                planOps.append(op.kind == .create ? .create(path: op.path, content: mine) : .edit(path: op.path, content: mine))
            }
            planned.append(op)
        }

        // Blocked before planning: the op stays in the outbox, one item in Needs attention.
        if !blocked.isEmpty {
            let created = isoTime(now())
            try store.journal.transaction { db in
                for (op, reason) in blocked { try Journal.addAttention(db, path: op.path, reason: reason, created: created) }
            }
        }
        guard !planOps.isEmpty else { return }

        let time = planned.map(\.opTime).min() ?? isoTime(now())
        let plan: PlanOutput
        do {
            plan = try planCommit(PlanInput(baseTree: baseTree, theirsTree: theirsTree, ops: planOps, renames: renames,
                                            device: store.device, time: time))
        } catch {
            // A failed final guard is a planner bug: send nothing, keep the ops, show it (merge spec 7.6).
            throw EngineError.rejected("planner: \(error)")
        }

        let kept = Set(plan.kept)
        var writes: [LandingPlan.Write] = []
        var deletes: [String] = []
        var writtenSha: [PathKey: String] = [:]
        var deleted = Set<PathKey>()
        var treeWrites: [TreeWrite] = []
        for e in plan.entries {
            switch e {
            case let .write(path, content):
                let sha = GitBlob.sha(content)
                writes.append(.init(path: path, content: content, sha: sha))
                writtenSha[PathKey(path)] = sha
                treeWrites.append(TreeWrite(path: path, change: .content(content)))
            case let .delete(path):
                deletes.append(path)
                deleted.insert(PathKey(path))
                treeWrites.append(TreeWrite(path: path, change: .delete))
            }
        }

        var effects: [LandingPlan.Effect] = []
        var outgoing: [OutboxOp] = []
        for (i, op) in planned.enumerated() {
            if kept.contains(i) { continue }
            outgoing.append(op)
            let row = rowByPath[PathKey(op.path)]
            var target = row?.renameTo.flatMap { renames[op.path] != nil ? $0 : nil } ?? op.path
            if op.kind == .create { target = nfc(op.path) }
            let key = PathKey(target)
            var e = LandingPlan.Effect(seq: op.seq, rev: op.rev, opPath: op.path, mine: op.content, target: target,
                                       finalText: nil, finalExists: false, finalSha: nil)
            if let sha = writtenSha[key] {
                e.finalExists = true
                e.finalSha = sha
            } else if !deleted.contains(key), let text = theirsByTarget[key] {
                e.finalExists = true
                e.finalText = text
                e.finalSha = rowByPath[key]?.blobSha
            }
            effects.append(e)
        }
        let attention = plan.attention.map { LandingPlan.NewAttention(path: $0.path, reason: $0.reason.rawValue, copy: $0.copy, detail: $0.detail) }

        // The planner's refusals (path policy, clash, size): the op stays, one item in Needs attention.
        let keptAttention = attention.filter { $0.reason.hasPrefix("blocked:") || $0.reason == "case-clash" }
        if !keptAttention.isEmpty {
            let created = isoTime(now())
            try store.journal.transaction { db in
                for a in keptAttention {
                    try Journal.addAttention(db, path: a.path, reason: a.reason, copyPath: a.copy, detail: a.detail, created: created)
                }
            }
        }
        let landingAttention = attention.filter { !($0.reason.hasPrefix("blocked:") || $0.reason == "case-clash") }

        guard !outgoing.isEmpty else { return }

        if plan.entries.isEmpty {
            // Everything was already true on GitHub: no commit, the outbox just clears.
            try land(LandingPlan(commit: head, parent: head, date: time, isCommit: false, writes: [], deletes: [],
                                 effects: effects, attention: landingAttention))
            return
        }

        publish(.pushing)
        try setInFlight(outgoing, true)
        defer { try? setInFlight(outgoing, false) }

        let treeSha: String
        let commitSha: String
        do {
            let parent = try await client.getCommit(head)
            treeSha = try await client.createTree(baseTree: parent.treeSha, writes: treeWrites)
            commitSha = try await client.createCommit(NewCommit(
                message: Self.commitMessage(outgoing: outgoing, device: store.device),
                tree: treeSha, parent: head, date: time,
                authorName: config.authorName, authorEmail: config.authorEmail))
        } catch let GitHubError.unprocessable(message) {
            throw EngineError.rejected(message)
        }

        let landing = LandingPlan(commit: commitSha, parent: head, date: time, isCommit: true, writes: writes,
                                  deletes: deletes, effects: effects, attention: landingAttention)
        try store.journal.setPendingPush(PendingPush(commit: commitSha, parent: head, planJSON: try JSONEncoder().encode(landing)))

        do {
            try await client.updateRef(to: commitSha)
        } catch GitHubError.notFastForward {
            try store.journal.clearPendingPush()
            throw GitHubError.notFastForward
        } catch let GitHubError.unprocessable(message) {
            try store.journal.clearPendingPush()
            throw EngineError.rejected(message)
        } catch GitHubError.unauthorized {
            try store.journal.clearPendingPush()
            throw GitHubError.unauthorized
        } catch let GitHubError.rateLimited(until) {
            try store.journal.clearPendingPush()
            throw GitHubError.rateLimited(until: until)
        } catch GitHubError.repoAccessLost {
            try store.journal.clearPendingPush()
            throw GitHubError.repoAccessLost
        } catch is CancellationError {
            // The request may already be on its way: the record stays, the next run verifies.
            throw CancellationError()
        } catch {
            // Timeout, dropped connection, 5xx: the ref may or may not have moved (scenario 9).
            try await resolvePendingPush()
            return
        }
        try land(landing)
    }

    /// `Verifying`: did the commit of a push whose answer never came land? Runs right after a lost
    /// response and at every launch. Read the ref; our commit at head or in its history means it landed.
    /// Otherwise retry the same sha if main has not moved, else drop it: the ops are still in the outbox.
    private func resolvePendingPush() async throws {
        guard let pending = store.journal.pendingPush() else { return }
        guard let landing = try? JSONDecoder().decode(LandingPlan.self, from: pending.planJSON) else {
            // Cannot happen with our own encoder; the ops are safe in the outbox either way.
            try store.journal.clearPendingPush()
            return
        }
        publish(.verifying)
        let head: String
        switch try await client.getRef(etag: nil) {
        case let .head(sha, _): head = sha
        case .notModified: return
        }
        if head == pending.commit { return try land(landing) }
        var inHistory = false
        do {
            // `compare/{ours}...{head}`: "ahead" means head has moved on from our commit, so ours is in its
            // history (measured in spike S1). "behind" would mean head is still before our commit: not landed.
            let c = try await client.compare(base: pending.commit, head: head)
            inHistory = c.status == "ahead" || c.status == "identical"
        } catch GitHubError.notFound {
            inHistory = false
        }
        if inHistory { return try land(landing) }
        if head == pending.parent {
            do {
                try await client.updateRef(to: pending.commit)
                return try land(landing)
            } catch GitHubError.notFastForward {
                // Someone got in between: rebuild on the new head.
            } catch let GitHubError.unprocessable(message) {
                Log.sync.error("retry of a pending push refused: \(message, privacy: .private)")
            }
        }
        try store.journal.clearPendingPush()
    }

    private func setInFlight(_ ops: [OutboxOp], _ value: Bool) throws {
        try store.journal.transaction { db in
            for op in ops {
                try db.execute(sql: "UPDATE outbox SET in_flight = ? WHERE seq = ?", arguments: [value, op.seq])
            }
        }
        continuation.yield(.notesChanged(ops.map(\.path)))
    }

    /// Subject, a blank line, then the trailers. The message always ends with `Brain-Notes-Op`, the audit
    /// mark that finds every app commit; the op id is the batch's oldest op.
    static func commitMessage(outgoing: [OutboxOp], device: String) -> String {
        guard let first = outgoing.first else { return "" }
        let verb: String
        switch first.kind {
        case .edit: verb = "edit"
        case .create: verb = "add"
        case .delete: verb = "delete"
        }
        let extra = outgoing.count > 1 ? " (+\(outgoing.count - 1))" : ""
        return "notes: \(verb) \(first.path)\(extra)\n\nBrain-Notes-Device: \(device)\nBrain-Notes-Op: \(first.opId)"
    }

    /// `Applying` after a push: the commit is on main, so the device catches up, all in one transaction.
    /// Text typed while the push was in flight is never touched: that note stays dirty, based on what was pushed.
    private func land(_ plan: LandingPlan) throws {
        publish(.applying)
        var touched: [String] = []
        var moved: [(String, String)] = []
        let files = store.files
        let modified = parseISOTime(plan.date) ?? now()
        let stamp = isoTime(now())
        let newId = store.newId

        try store.journal.transaction { db in
            var finishing: [PathKey: LandingPlan.Effect] = [:]
            for e in plan.effects {
                if let cur = try Journal.op(db, seq: e.seq), cur.rev == e.rev { finishing[PathKey(e.opPath)] = e }
            }
            // A newer op than the one this commit carries, or an op that appeared after the batch was made.
            func hasLiveOp(_ path: String) throws -> Bool {
                guard let cur = try Journal.op(db, path: path) else { return false }
                if let e = finishing[PathKey(path)], e.seq == cur.seq { return false }
                return true
            }

            var written = Set<PathKey>()
            for w in plan.writes {
                written.insert(PathKey(w.path))
                if try hasLiveOp(w.path) {
                    var row = try Journal.file(db, w.path) ?? FileRow(path: w.path, blobSha: nil, dirty: true)
                    row.blobSha = w.sha
                    try Journal.putFile(db, row)
                } else {
                    try files.write(w.path, w.content)
                    let st = files.stat(w.path)
                    try Journal.putFile(db, FileRow(path: w.path, blobSha: w.sha, modified: modified, diskSize: st?.size, diskMtime: st?.mtime))
                    touched.append(w.path)
                }
            }
            for d in plan.deletes {
                written.insert(PathKey(d))
                if try hasLiveOp(d) {
                    if var row = try Journal.file(db, d) {
                        row.blobSha = nil
                        try Journal.putFile(db, row)
                    }
                } else {
                    try files.remove(d)
                    try Journal.removeFile(db, d)
                    touched.append(d)
                }
            }
            for e in plan.effects {
                guard let cur = try Journal.op(db, seq: e.seq) else { continue }
                let renamed = !sameBytes(e.opPath, e.target)
                if cur.rev == e.rev {
                    try Journal.removeOp(db, seq: e.seq)
                    try Journal.resolvePushProblems(db, path: e.opPath)
                    if renamed {
                        try files.remove(e.opPath)
                        try Journal.removeFile(db, e.opPath)
                        touched.append(e.opPath)
                        moved.append((e.opPath, e.target))
                    }
                    if written.contains(PathKey(e.target)) { continue }
                    if let text = e.finalText {
                        if try !hasLiveOp(e.target) {
                            // The commit leaves GitHub's text here: the device takes it.
                            try files.write(e.target, text)
                            let st = files.stat(e.target)
                            try Journal.putFile(db, FileRow(path: e.target, blobSha: e.finalSha, modified: modified, diskSize: st?.size, diskMtime: st?.mtime))
                            touched.append(e.target)
                        }
                    } else if !e.finalExists {
                        try files.remove(e.target)
                        try Journal.removeFile(db, e.target)
                        touched.append(e.target)
                    }
                } else {
                    // Typed during the push. What was pushed is the base for what was typed after it.
                    var row = try Journal.file(db, e.opPath) ?? FileRow(path: e.opPath, blobSha: nil, dirty: true)
                    row.dirty = true
                    row.baseText = e.mine ?? e.finalText
                    row.blobSha = renamed ? nil : (e.finalExists ? e.finalSha : nil)
                    row.renameTo = renamed ? e.target : nil
                    try Journal.putFile(db, row)
                    var kind: OpKind = cur.kind
                    if cur.kind != .delete {
                        kind = e.finalExists && e.mine != nil ? .edit : .create
                    }
                    try db.execute(sql: "UPDATE outbox SET op_id = ?, op_time = ?, kind = ?, in_flight = 0 WHERE seq = ?",
                                   arguments: [newId(), stamp, kind.rawValue, e.seq])
                }
            }
            for a in plan.attention {
                try Journal.addAttention(db, path: a.path, reason: a.reason, copyPath: a.copy, detail: a.detail, created: stamp)
            }
            if plan.isCommit {
                try Journal.setMeta(db, Journal.Key.baseCommit, plan.commit)
                try Journal.setMeta(db, Journal.Key.remoteHead, plan.commit)
                try Journal.setMeta(db, Journal.Key.refEtag, nil)
                try Journal.setMeta(db, Journal.Key.lastCommitAt, stamp)
            }
            try db.execute(sql: "DELETE FROM pending_push")
        }
        store.reindex(touched)
        store.markIndexCurrent()
        if !touched.isEmpty { continuation.yield(.notesChanged(touched)) }
        for (from, to) in moved { continuation.yield(.noteMoved(from: from, to: to)) }
    }

    // MARK: - Texts

    private func text(ofBlob sha: String) async throws -> String {
        let data: Data
        if let cached = blobCache[sha] {
            data = cached
        } else {
            data = try await client.blob(sha)
            guard GitBlob.sha(data) == sha else { throw GitHubError.badResponse("blob hash") }
            blobCache[sha] = data
        }
        guard let text = decodeNote(data) else { throw EngineError.rejected("not-text") }
        return text
    }

    /// GitHub's text of a path at the base commit, from the cheapest place that surely has it.
    /// nil when the path is not on GitHub.
    private func theirsText(of row: FileRow) async throws -> String? {
        guard let sha = row.blobSha else { return nil }
        if let base = row.baseText, GitBlob.sha(base) == sha { return base }
        if !row.dirty, row.local, let d = try store.files.readData(row.path), GitBlob.sha(d) == sha {
            if let text = decodeNote(d) { return text }
            throw EngineError.rejected("not-text")
        }
        return try await text(ofBlob: sha)
    }

    // MARK: - First sync

    /// Tarball into a staging folder, every file verified against the recursive tree, swapped in only then.
    /// Anything the tarball did not deliver comes from the blobs API. An interrupted run leaves no trace.
    private func firstSync() async throws {
        publish(.firstSync(.downloading))
        let head = try await currentHead(useEtag: false)
        let commit = try await client.getCommit(head)
        let listing = try await client.tree(commit.treeSha)
        var tree = PathIndex()
        var accepted: [TreeEntry] = []
        var twins: [(TreeEntry, String)] = []
        for e in listing where e.isFile && PathPolicy.isSyncable(e.path) {
            if let other = tree.clash(e.path) {
                twins.append((e, other))
            } else {
                tree.add(e.path)
                accepted.append(e)
            }
        }

        let files = store.files
        let staging = files.staging
        try files.resetStaging()
        var missing = accepted
        do {
            let tar = try Gzip.decompress(try await client.tarball(head))
            var byPath: [PathKey: Data] = [:]
            for entry in try TarReader.files(in: tar) { byPath[PathKey(entry.path)] = entry.data }
            var still: [TreeEntry] = []
            for (i, e) in accepted.enumerated() {
                if let data = byPath[PathKey(e.path)], GitBlob.sha(data) == e.sha {
                    try staging.write(e.path, data)
                } else {
                    still.append(e)
                }
                if i % 100 == 0 { publish(.firstSync(.verifying(done: i, total: accepted.count))) }
            }
            missing = still
        } catch is TarballError {
            Log.sync.notice("tarball unusable, using blobs")
        } catch GitHubError.notFound, GitHubError.server, GitHubError.badResponse {
            Log.sync.notice("tarball unavailable, using blobs")
        }

        if !missing.isEmpty {
            let bodies = try await fetchBlobs(Array(Set(missing.map(\.sha))))
            for e in missing {
                guard let data = bodies[e.sha] else { throw GitHubError.badResponse("missing body") }
                try staging.write(e.path, data)
            }
        }

        publish(.firstSync(.verifying(done: accepted.count, total: accepted.count)))
        try files.swapIn()

        // Unsynced notes made before the first sync finished survive, from the outbox.
        let created = isoTime(now())
        try store.journal.transaction { db in
            let unsynced = try Journal.outbox(db)
            let keepSet = Set(unsynced.map { PathKey($0.path) })
            for row in try Row.fetchAll(db, sql: "SELECT path FROM files") {
                let path: String = row["path"]
                if !keepSet.contains(PathKey(path)) { try Journal.removeFile(db, path) }
            }
            for e in accepted {
                let st = files.stat(e.path)
                if keepSet.contains(PathKey(e.path)) {
                    try db.execute(sql: "UPDATE files SET blob_sha = ? WHERE path = ?", arguments: [e.sha, e.path])
                } else {
                    try Journal.putFile(db, FileRow(path: e.path, blobSha: e.sha, diskSize: st?.size, diskMtime: st?.mtime))
                }
            }
            for (e, other) in twins {
                try Journal.putFile(db, FileRow(path: e.path, blobSha: e.sha, local: false))
                try Journal.addAttention(db, path: e.path, reason: "case-clash", detail: other, created: created)
            }
            try Journal.setMeta(db, Journal.Key.baseCommit, head)
            try Journal.setMeta(db, Journal.Key.remoteHead, head)
            try Journal.setMeta(db, Journal.Key.datesPending, "1")
            // The swap replaced the folder: unsynced notes go back, as they are in the outbox right now.
            for op in unsynced where op.kind != .delete {
                guard let c = op.content else { continue }
                try files.write(op.path, c)
                let st = files.stat(op.path)
                try db.execute(sql: "UPDATE files SET disk_size = ?, disk_mtime = ? WHERE path = ?", arguments: [st?.size, st?.mtime, op.path])
            }
        }
        continuation.yield(.notesChanged([]))

        try store.rebuildIndex { [weak self] done, total in
            guard let self else { return }
            Task { await self.reportIndexing(done, total) }
        }
        publish(.firstSync(.indexing(done: accepted.count, total: accepted.count)))
        continuation.yield(.notesChanged([]))
    }

    private func reportIndexing(_ done: Int, _ total: Int) {
        if case .firstSync = snapshot.state {
            publish(.firstSync(.indexing(done: done, total: total)))
            continuation.yield(.notesChanged([]))
        }
    }

    /// The tarball gives every file the same date, so per-note dates come from history in batches of 100.
    /// Best effort: lists fall back to title order until the dates arrive.
    private func backfillDatesIfNeeded() async {
        guard store.journal.meta(Journal.Key.datesPending) == "1", let head = store.journal.baseCommit else { return }
        let paths = store.journal.allFiles().filter { $0.modified == nil && $0.blobSha != nil && PathPolicy.isVisible($0.path) }.map(\.path)
        var i = 0
        do {
            while i < paths.count {
                let batch = Array(paths[i..<min(i + 100, paths.count)])
                try store.applyDates(try await client.lastCommitDates(head: head, paths: batch))
                i += batch.count
            }
            try store.journal.setMeta(Journal.Key.datesPending, nil)
            continuation.yield(.notesChanged([]))
        } catch {
            Log.sync.notice("date backfill postponed")
        }
    }

    // MARK: - History rewritten

    private static let rewriteReason = "history-rewritten"

    private func hasOpenRewriteItem() -> Bool {
        store.journal.attention().contains { $0.reason == Self.rewriteReason }
    }

    /// Main was rewritten: stop syncing, say so, wait for the user to ask for a fresh sync.
    private func recordRewrite() {
        let created = isoTime(now())
        try? store.journal.transaction { db in
            try Journal.addAttention(db, path: "", reason: Self.rewriteReason, created: created)
        }
    }

    /// Start over from main as it is now. Every unsynced note goes to `_inbox` as a copy first, so no text is lost.
    public func freshSync() async {
        // A conflict copy that is still unsynced is already a copy: it just stays in the outbox.
        let ops = store.journal.outbox().filter { !($0.content.map(NoteText.isConflictCopy) ?? false) }
        do {
            // Unsynced text moves to copies. A delete has no text of its own and the note is on GitHub or gone.
            for op in ops {
                if let content = op.content { _ = try store.createCopy(of: op.path, text: content) }
            }
            try store.journal.transaction { db in
                for op in ops {
                    try Journal.removeOp(db, seq: op.seq)
                    try Journal.removeFile(db, op.path)
                }
                try db.execute(sql: "UPDATE attention SET resolved = 1 WHERE resolved = 0")
                try db.execute(sql: "DELETE FROM pending_push")
                try Journal.setMeta(db, Journal.Key.baseCommit, nil)
                try Journal.setMeta(db, Journal.Key.remoteHead, nil)
                try Journal.setMeta(db, Journal.Key.refEtag, nil)
            }
        } catch {
            handle(error)
            return
        }
        await sync(.manual)
    }
}
