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
    /// First sync stopped at a size limit. A retry would download the same repo again, so only Sync now tries.
    case repoTooLarge(RepoTooLarge)

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
        /// What first sync takes in at most: download, inflated size, entries, one entry. Blobs from the API are held to
        /// the same: one blob to `maxEntryBytes`, one batch of them to `maxExtractedBytes`, first sync's fallback to
        /// `maxEntries` notes.
        public var limits = FirstSyncLimits.standard
        /// Blob bodies a run keeps, so a retry does not fetch them again. Past this, bodies are fetched again instead.
        public var blobCacheBytes = 64 << 20
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
    /// Set when first sync stopped at a size limit. Until a manual run, nothing downloads the repo again.
    private var tooLarge: RepoTooLarge?
    private var userPaused: Bool
    private var pausedUntil: Date?
    private var backoffStep = 0
    private var retryAt: Date?
    private var lastLocalEdit: Date = .distantPast
    private var lastPushAttempt: Date = .distantPast
    private var pushHoldUntil: Date?
    private var pushHoldStep = 0
    private var started = false
    private var wakeTask: Task<Void, Never>?
    /// Blob bodies fetched during one run, by sha, so a 422 retry does not fetch them twice. Bounded by bytes.
    private var blobCache: BlobCache

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
        blobCache = BlobCache(limitBytes: config.blobCacheBytes)
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

    /// Returns once no run is in flight. For closing a session: a run still going would write into a
    /// folder that is being deleted. Call `stop` first, or the timer can start another.
    public func waitUntilIdle() async {
        guard running else { return }
        await withCheckedContinuation { waiters.append($0) }
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

    /// Timer tick. The wake task hands the tick to a task of its own, which `stop` does not cancel: a tick that
    /// arrives after `stop` must not start a run, or a session being closed or wiped gets one more.
    func tick() async {
        guard started else { return }
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
            // The run gets its own task. Moving the timer, which every save does, must not cancel a push
            // on its way: only this sleep belongs to the timer.
            Task { [weak self] in await self?.tick() }
        }
    }

    private func nextDelay() -> TimeInterval {
        let t = now()
        var next = t.addingTimeInterval(config.pollInterval)
        // An earlier wake only when a push could run, and only for edits made since the last attempt. Ops
        // that stay in the outbox (blocked, parked, or waiting for a network) wait for the normal poll:
        // they must never turn this into a tight loop.
        let canPush = online && !userPaused && !signedOut && !accessLost && tooLarge == nil && !hasOpenRewriteItem()
        if canPush, lastLocalEdit > lastPushAttempt, store.journal.pushableCount() > 0 {
            let idleDue = lastLocalEdit.addingTimeInterval(config.idleFlush)
            var due = max(idleDue, lastCommitAt().addingTimeInterval(config.minCommitInterval))
            if let pushHoldUntil { due = max(due, pushHoldUntil) }
            next = min(next, due)
        }
        if let retryAt, retryAt > t { next = retryAt }
        if let pausedUntil, pausedUntil > t { next = max(next, pausedUntil) }
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
        blobCache.removeAll()
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
        // Too large for first sync: polls, foregrounds and saves must not download it all again. Sync now may.
        if tooLarge != nil, trigger != .manual { return publish(restingState()) }
        if !online { return publish(.offline) }
        let t = now()
        if let until = pausedUntil {
            if until > t { return publish(.paused(.rateLimited(until: until))) }
            pausedUntil = nil
        }
        if trigger == .poll, let at = retryAt, at > t { return publish(.retrying(at: at)) }
        if hasOpenRewriteItem() { return publish(restingState()) }
        // Counted before anything can fail, so a failed run waits for the backoff or the poll, not the timer.
        if shouldPush(trigger) { lastPushAttempt = t }
        do {
            if store.journal.baseCommit == nil {
                try await firstSync()
            }
            try await resolvePendingPush()
            try await checkPullPush(trigger)
            try await refetchMissing()
            try await promoteHeldBackNotes()
            await backfillDatesIfNeeded()
            backoffStep = 0
            retryAt = nil
            accessLost = false
            tooLarge = nil
            signedOut = false
            try? store.journal.setMeta(Journal.Key.lastSync, isoTime(now()))
            publish(restingState())
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        retryAt = nil  // only the backoff case below sets it
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
        case let limit as RepoTooLarge:
            // Not a backoff: the same repo is past the same limit on every try.
            tooLarge = limit
            Log.sync.notice("first sync stopped: repository past a size limit")
            publish(.repoTooLarge(limit))
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
        if let tooLarge { return .repoTooLarge(tooLarge) }
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
        guard store.journal.pushableCount() > 0 else { return false }
        let t = now()
        if let hold = pushHoldUntil, hold > t, trigger != .manual, trigger != .background { return false }
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
        // Only an edit can have an unknown base. A note I created has none, whatever GitHub now holds at
        // that path, and a delete without one is skipped: that text was never mine to delete.
        let edits = Set(store.journal.outbox().filter { $0.kind == .edit }.map { PathKey($0.path) })
        for row in store.journal.allFiles() where row.dirty && row.baseText == nil {
            guard let sha = row.blobSha, edits.contains(PathKey(row.path)) else { continue }
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

    /// The bodies a pull applies. They are applied together, so they are held together, within the limits
    /// `fetchBlobs` keeps.
    private func fetchBodies(_ changes: [RemoteChange]) async throws -> [String: Data] {
        var wanted: [String] = []
        var seen = Set<String>()
        for c in changes {
            if let sha = c.sha, blobCache[sha] == nil, seen.insert(sha).inserted { wanted.append(sha) }
        }
        var fetched: [String: Data] = [:]
        try await fetchBlobs(wanted) { sha, data in fetched[sha] = data }
        for c in changes {
            if let sha = c.sha, fetched[sha] == nil, let d = blobCache[sha] { fetched[sha] = d }
        }
        for (sha, d) in fetched { blobCache.keep(d, for: sha) }
        return fetched
    }

    /// Blob bodies by sha, verified, a few at a time, each handed to `each` as it arrives and not kept here. They are
    /// held to first sync's limits: one body to `maxEntryBytes`, all of them together to `maxExtractedBytes`
    /// (`RepoTooLarge`). At most `blobConcurrency` bodies are in memory here at once.
    private func fetchBlobs(_ shas: [String], each: (String, Data) throws -> Void) async throws {
        let client = self.client
        let limits = config.limits
        var pending = shas[...]
        var total = 0
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var active = 0
            func launch() {
                while active < config.blobConcurrency, let sha = pending.popFirst() {
                    active += 1
                    group.addTask { (sha, try await Self.verifiedBlob(sha, from: client, maxBytes: limits.maxEntryBytes)) }
                }
            }
            launch()
            while let (sha, data) = try await group.next() {
                active -= 1
                guard data.count <= limits.maxExtractedBytes - total else {
                    throw RepoTooLarge(.extracted, max: limits.maxExtractedBytes)
                }
                total += data.count
                try each(sha, data)
                launch()
            }
        }
    }

    /// One blob, refused past `maxBytes` (the HTTP client stops reading there already; any other client is held to it
    /// here) and checked against its sha.
    private static func verifiedBlob(_ sha: String, from client: GitHubClient, maxBytes: Int) async throws -> Data {
        let data = try await client.blob(sha)
        guard data.count <= maxBytes else { throw RepoTooLarge(.entry, max: maxBytes) }
        guard GitBlob.sha(data) == sha else { throw GitHubError.badResponse("blob hash") }
        return data
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
        var leaving = Set<PathKey>()
        for c in ordered where c.kind == .remove { leaving.insert(PathKey(c.path)) }
        // Who owns each name on this disk: rows with a file. A clean note that GitHub removes frees its name.
        // A dirty one keeps its file, and so its name: on a case-insensitive disk, writing "notes.md" would
        // land on the unsynced text of "Notes.md". A held-back row owns nothing, whatever it sorts before.
        var tree = PathIndex(store.journal.allFiles().filter { $0.local && (!leaving.contains(PathKey($0.path)) || $0.dirty) }.map(\.path))

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
                            // A note held back has no file of its own: that name is its twin's.
                            if row.local { try files.remove(c.path) }
                            try Journal.removeFile(db, c.path)
                            try Journal.resolvePushProblems(db, path: c.path)
                            touched.append(c.path)
                            if let to = c.renamedTo { moved.append((c.path, to)) }
                        }
                    case .upsert:
                        guard let sha = c.sha else { continue }
                        if var row, row.dirty {
                            row.blobSha = sha
                            row.renameTo = nil  // the path is back on GitHub
                            try Journal.putFile(db, row)
                            continue
                        }
                        if let row, row.blobSha == sha, row.local, files.exists(c.path) { continue }
                        // A second spelling that cannot exist next to the first on this file system stays on
                        // GitHub only. It still counts for the planner, and it is listed in Needs attention.
                        if row == nil || row?.local == false, let other = tree.clash(c.path) {
                            try holdBack(db, path: c.path, sha: sha, modified: date, reason: "case-clash", detail: other, created: created)
                            continue
                        }
                        guard let data = bodies[sha] else { throw GitHubError.badResponse("missing body") }
                        guard try files.writeIfPossible(c.path, data) else {
                            // A clean note that grew past what this device keeps: its older text must not stay on
                            // as if it were current. Only this row's own file goes.
                            if row?.local == true {
                                try files.remove(c.path)
                                touched.append(c.path)
                            }
                            try holdBack(db, path: c.path, sha: sha, modified: date, reason: Self.heldBackReason(data), detail: nil, created: created)
                            continue
                        }
                        let st = files.stat(c.path)
                        try Journal.putFile(db, FileRow(path: c.path, blobSha: sha, modified: date, diskSize: st?.size, diskMtime: st?.mtime))
                        try Journal.resolvePushProblems(db, path: c.path)
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

    /// A note this device cannot hold: GitHub keeps it, the planner still sees it, and it never reaches the disk.
    private func holdBack(_ db: Database, path: String, sha: String, modified: Date?, reason: String, detail: String?, created: String) throws {
        try Journal.putFile(db, FileRow(path: path, blobSha: sha, modified: modified, local: false))
        try Journal.addAttention(db, path: path, reason: reason, detail: detail, created: created)
    }

    /// Why a note from GitHub that `writeIfPossible` turned down stays there: over `maxNoteBytes`, more than the app
    /// opens or could push back ("too-large"), or a name this disk can't hold ("unstorable").
    static func heldBackReason(_ data: Data) -> String {
        data.count > maxNoteBytes ? Self.tooLargeReason : "unstorable"
    }

    static let tooLargeReason = "too-large"

    /// Files the journal has but the disk lost (restored device): download them again, by blob sha.
    private func refetchMissing() async throws {
        let rows = store.journal.allFiles().filter { !$0.dirty && $0.local && $0.blobSha != nil && !store.files.exists($0.path) }
        guard !rows.isEmpty else { return }
        try await download(rows)
    }

    /// A note held back because another spelling had its name gets its file once that name is free. One held back for
    /// its size is not downloaded again on every run: it stays on GitHub until GitHub's note changes, and a pull brings
    /// that change like any other.
    private func promoteHeldBackNotes() async throws {
        let rows = store.journal.allFiles()
        let tooLarge = store.journal.pathsEverHeldBack(for: Self.tooLargeReason)
        let held = rows.filter {
            !$0.local && !$0.dirty && $0.blobSha != nil && FileStore.nameFits($0.path) && !tooLarge.contains(PathKey($0.path))
        }
        guard !held.isEmpty else { return }
        var tree = PathIndex(rows.filter(\.local).map(\.path))
        var free: [FileRow] = []
        for row in held where tree.clash(row.path) == nil {
            tree.add(row.path)
            free.append(row)
        }
        if !free.isEmpty { try await download(free) }
    }

    /// Each note is written as its body arrives, so the bodies are never all in memory at once.
    private func download(_ rows: [FileRow]) async throws {
        var bySha: [String: [FileRow]] = [:]
        var order: [String] = []
        for row in rows {
            guard let sha = row.blobSha else { continue }
            if bySha[sha] == nil { order.append(sha) }
            bySha[sha, default: []].append(row)
        }
        var touched: [String] = []
        let files = store.files
        let created = isoTime(now())
        try await fetchBlobs(order) { sha, data in
            for row in bySha[sha] ?? [] {
                // Looked at again here: a save during the download must not be overwritten.
                try store.journal.transaction { db in
                    guard let cur = try Journal.file(db, row.path), !cur.dirty, cur.blobSha == sha else { return }
                    guard try files.writeIfPossible(row.path, data) else {
                        return try holdBack(db, path: row.path, sha: sha, modified: cur.modified, reason: Self.heldBackReason(data),
                                            detail: nil, created: created)
                    }
                    let st = files.stat(row.path)
                    try db.execute(sql: "UPDATE files SET local = 1, disk_size = ?, disk_mtime = ? WHERE path = ?", arguments: [st?.size, st?.mtime, row.path])
                    try Journal.resolvePushProblems(db, path: row.path)
                    touched.append(row.path)
                }
            }
        }
        store.reindex(touched)
        if !touched.isEmpty { continuation.yield(.notesChanged(touched)) }
    }

    // MARK: - Push

    /// One commit for all pushable ops. If GitHub or the planner refuses it, the ops refused on their own are found
    /// without committing anything and parked in Needs attention, and the others go again as one commit, so the bad one
    /// does not hold them back (scenario 10). A rename or a move is several ops: it stays one commit.
    private func pushAll(head: String) async throws {
        let ops = store.journal.outbox().filter { !$0.parked }
        do {
            try await pushBatch(ops, head: head)
            return
        } catch let EngineError.rejected(why) {
            guard ops.count > 1 else {
                if let op = ops.first { try park(op, why: why) }
                return
            }
        }
        let half = ops.count / 2
        let refused = try await refusedAlone(Array(ops[..<half]), head: head) + refusedAlone(Array(ops[half...]), head: head)
        for (op, why) in refused { try park(op, why: why) }
        let parked = Set(refused.map { $0.op.seq })
        let rest = ops.filter { !parked.contains($0.seq) }
        guard !rest.isEmpty else { return }
        do {
            try await pushBatch(rest, head: head)
        } catch EngineError.rejected {
            // Every op goes through alone, but not all of them together: a commit each, as a last resort, so that
            // none is held back by the others.
            for op in rest {
                guard let current = store.journal.baseCommit else { return }
                do {
                    try await pushBatch([op], head: current)
                } catch let EngineError.rejected(why) {
                    try park(op, why: why)
                }
            }
        }
    }

    /// The ops among `ops` that GitHub or the planner refuses on their own, found by halves. Nothing is committed: each
    /// try is planned and sent as a tree only (`treeOnly`), and a half whose tree is taken holds none of them.
    private func refusedAlone(_ ops: [OutboxOp], head: String) async throws -> [(op: OutboxOp, why: String)] {
        guard !ops.isEmpty else { return [] }
        do {
            try await pushBatch(ops, head: head, treeOnly: true)
            return []
        } catch let EngineError.rejected(why) {
            guard ops.count > 1 else { return [(ops[0], why)] }
            let half = ops.count / 2
            return try await refusedAlone(Array(ops[..<half]), head: head) + refusedAlone(Array(ops[half...]), head: head)
        }
    }

    private func park(_ op: OutboxOp, why: String) throws {
        let created = isoTime(now())
        try store.journal.transaction { db in
            try db.execute(sql: "UPDATE outbox SET parked = 1, in_flight = 0 WHERE seq = ?", arguments: [op.seq])
            try Journal.addAttention(db, path: op.path, reason: "rejected", detail: why, created: created)
        }
    }

    /// Out of retries. A real race clears up by itself, but a ref that refuses every time must not go on
    /// costing 3 write calls per try per poll (GitHub allows 500 an hour): wait 5 minutes, doubling to an hour.
    private func recordPushFailed() {
        let created = isoTime(now())
        let paths = store.journal.outbox().filter { !$0.parked }.map(\.path)
        try? store.journal.transaction { db in
            for p in paths { try Journal.addAttention(db, path: p, reason: "push-failed", created: created) }
        }
        pushHoldStep += 1
        pushHoldUntil = now().addingTimeInterval(min(300 * pow(2, Double(pushHoldStep - 1)), 3600))
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
        /// Notes a move commit (`NoteMover`) takes elsewhere. They have no outbox op, so no effect says so: landing
        /// reports them as `.noteMoved`, which keeps their pins when the engine, not the mover, finishes the move.
        /// Optional, so a record written before this field still decodes.
        var moves: [Move]? = nil

        struct Move: Codable, Equatable {
            var from: String
            var to: String
        }
    }

    /// Merging, then Pushing. Throws `.notFastForward` to the caller's retry loop. With `treeOnly`, a trial: everything up
    /// to the tree GitHub builds from the plan, and no further. No commit is made, nothing lands, no op is in flight;
    /// it throws `.rejected` where the push would.
    private func pushBatch(_ ops: [OutboxOp], head: String, treeOnly: Bool = false) async throws {
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
                if base == nil, op.kind == .edit, let sha = row.blobSha {
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
            if treeOnly { return }
            // Everything was already true on GitHub: no commit, the outbox just clears.
            try land(LandingPlan(commit: head, parent: head, date: time, isCommit: false, writes: [], deletes: [],
                                 effects: effects, attention: landingAttention))
            return
        }

        if treeOnly {
            do {
                let parent = try await client.getCommit(head)
                _ = try await client.createTree(baseTree: parent.treeSha, writes: treeWrites)
            } catch let GitHubError.unprocessable(message) {
                throw EngineError.rejected(message)
            }
            return
        }

        publish(.pushing)
        try setInFlight(outgoing, true)
        // While a commit's fate is unknown its ops stay in flight: that note must not be renamed or forgotten.
        defer { if store.journal.pendingPush() == nil { try? setInFlight(outgoing, false) } }

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
        } catch GitHubError.notFastForward, GitHubError.unprocessable {
            // Plan: a 422 on the ref is a race. Pull, merge, rebuild, retry; after 3 tries, Needs attention.
            try store.journal.clearPendingPush()
            throw GitHubError.notFastForward
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
            } catch GitHubError.notFastForward, GitHubError.unprocessable {
                // Someone got in between: rebuild on the new head.
            }
        }
        try store.journal.clearPendingPush()
        continuation.yield(.notesChanged([]))
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

    /// A note this device can't hold (a name too long for the disk) stays on GitHub only: the commit is on
    /// main either way, and one such note must not stop every later sync.
    private func storeLanded(_ db: Database, _ path: String, _ text: String, sha: String?, modified: Date, stamp: String, touched: inout [String]) throws {
        let data = Data(text.utf8)
        if try store.files.writeIfPossible(path, data) {
            let st = store.files.stat(path)
            try Journal.putFile(db, FileRow(path: path, blobSha: sha, modified: modified, diskSize: st?.size, diskMtime: st?.mtime))
            touched.append(path)
        } else if let sha {
            // GitHub's text, too large to keep: an older text of this note here goes too (this row's own file only).
            if try Journal.file(db, path)?.local == true {
                try store.files.remove(path)
                touched.append(path)
            }
            try holdBack(db, path: path, sha: sha, modified: modified, reason: Self.heldBackReason(data), detail: nil, created: stamp)
        }
    }

    /// A row held back has no file of its own: that name is its twin's.
    private func removeLanded(_ db: Database, _ path: String, touched: inout [String]) throws {
        if try Journal.file(db, path)?.local != false { try store.files.remove(path) }
        try Journal.removeFile(db, path)
        touched.append(path)
    }

    /// `Applying` after a push: the commit is on main, so the device catches up, all in one transaction.
    /// Text typed while the push was in flight is never touched: that note stays dirty, based on what was pushed.
    private func land(_ plan: LandingPlan) throws {
        publish(.applying)
        var touched: [String] = []
        var moved: [(String, String)] = []
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
            // Notes still being edited keep their files. A write that would land on one, under another
            // spelling (a case-only rename, typed over during the push), waits on GitHub until it settles.
            var liveNames: [PathKey: String] = [:]
            for op in try Journal.outbox(db) where op.kind != .delete && finishing[PathKey(op.path)]?.seq != op.seq {
                liveNames[PathKey(foldKey(op.path))] = op.path
            }

            // A note GitHub renamed leaves its old path first: with a case-only rename both are one file
            // here, and what follows writes the new one.
            for e in plan.effects where !sameBytes(e.opPath, e.target) && finishing[PathKey(e.opPath)]?.seq == e.seq {
                try removeLanded(db, e.opPath, touched: &touched)
                try Journal.resolvePushProblems(db, path: e.target)
                moved.append((e.opPath, e.target))
            }

            var written = Set<PathKey>()
            for w in plan.writes {
                written.insert(PathKey(w.path))
                if try hasLiveOp(w.path) {
                    var row = try Journal.file(db, w.path) ?? FileRow(path: w.path, blobSha: nil, dirty: true)
                    row.blobSha = w.sha
                    try Journal.putFile(db, row)
                } else if let owner = liveNames[PathKey(foldKey(w.path))] {
                    try holdBack(db, path: w.path, sha: w.sha, modified: modified, reason: "case-clash", detail: owner, created: stamp)
                } else {
                    try storeLanded(db, w.path, w.content, sha: w.sha, modified: modified, stamp: stamp, touched: &touched)
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
                    try removeLanded(db, d, touched: &touched)
                }
            }
            for e in plan.effects {
                guard let cur = try Journal.op(db, seq: e.seq) else { continue }
                let renamed = !sameBytes(e.opPath, e.target)
                if cur.rev == e.rev {
                    try Journal.removeOp(db, seq: e.seq)
                    try Journal.resolvePushProblems(db, path: e.opPath)
                    if written.contains(PathKey(e.target)) { continue }
                    if let text = e.finalText {
                        // The commit leaves GitHub's text here: the device takes it.
                        if try !hasLiveOp(e.target), liveNames[PathKey(foldKey(e.target))] == nil {
                            try storeLanded(db, e.target, text, sha: e.finalSha, modified: modified, stamp: stamp, touched: &touched)
                        }
                    } else if !e.finalExists {
                        try removeLanded(db, e.target, touched: &touched)
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
            try db.execute(sql: "UPDATE outbox SET in_flight = 0 WHERE in_flight = 1")
        }
        for m in plan.moves ?? [] { moved.append((m.from, m.to)) }
        if plan.isCommit {
            pushHoldUntil = nil
            pushHoldStep = 0
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
            data = try await Self.verifiedBlob(sha, from: client, maxBytes: config.limits.maxEntryBytes)
            blobCache.keep(data, for: sha)
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
        // Notes already written here, not yet on GitHub, own their names on this device: a second spelling
        // from GitHub stays there, or it would land on the same file on a case-insensitive disk.
        var tree = PathIndex(store.journal.outbox().filter { $0.kind != .delete }.map(\.path))
        var accepted: [TreeEntry] = []
        var heldBack: [(entry: TreeEntry, reason: String, detail: String?)] = []
        for e in listing where e.isFile && PathPolicy.isSyncable(e.path) {
            if let other = tree.clash(e.path) {
                heldBack.append((e, "case-clash", other))
            } else {
                tree.add(e.path)
                accepted.append(e)
            }
        }

        let files = store.files
        let staging = files.staging
        try files.resetStaging()
        var stored: [TreeEntry] = []
        // Notes that reached staging, or were held back, by path. Whatever is not in here comes from the blobs API.
        var done = Set<PathKey>()
        var byPath: [PathKey: TreeEntry] = [:]
        for e in accepted { byPath[PathKey(e.path)] = e }
        // A repo past one of these limits stops here with `RepoTooLarge`: not a fallback to blobs, not a retry loop.
        let limits = config.limits
        do {
            let gz = try await client.tarball(head)
            // The HTTP client stops reading at this size already; any other client is held to it here.
            guard gz.count <= limits.maxDownloadBytes else { throw RepoTooLarge(.download, max: limits.maxDownloadBytes) }
            // Each note this sync stores goes to staging the moment it is read, checked against the tree, so only one is
            // in memory at a time. Everything else in the tarball streams past.
            let wanted = byPath
            try TarReader.forEachFile(inGzip: gz, limits: limits, keep: { wanted[PathKey($0)] != nil }) { entry in
                let key = PathKey(entry.path)
                guard let e = byPath[key], !done.contains(key), GitBlob.sha(entry.data) == e.sha else { return }
                done.insert(key)
                try Self.stage(e, entry.data, in: staging, stored: &stored, heldBack: &heldBack)
                if done.count % 100 == 0 { publish(.firstSync(.verifying(done: done.count, total: accepted.count))) }
            }
        } catch is TarballError {
            // The notes read before the archive broke off are in staging already; the blobs bring the rest.
            Log.sync.notice("tarball unusable, using blobs")
        } catch GitHubError.notFound, GitHubError.server, GitHubError.badResponse, GitHubError.timedOut {
            // `timedOut` covers a slow or dropped download too (any transient URLError): retrying the whole
            // tarball would only time out again, every time. The blobs come in small requests of their own.
            Log.sync.notice("tarball unavailable, using blobs")
        }

        let missing = accepted.filter { !done.contains(PathKey($0.path)) }
        if !missing.isEmpty {
            // Under the tarball's limits: no more notes than it may hold, none larger than one of its files, and no
            // more bytes in all than it may inflate to (`fetchBlobs`). Each note goes to staging as it arrives.
            guard missing.count <= limits.maxEntries else { throw RepoTooLarge(.entries, max: limits.maxEntries) }
            var bySha: [String: [TreeEntry]] = [:]
            var order: [String] = []
            for e in missing {
                if bySha[e.sha] == nil { order.append(e.sha) }
                bySha[e.sha, default: []].append(e)
            }
            try await fetchBlobs(order) { sha, data in
                for e in bySha[sha] ?? [] { try Self.stage(e, data, in: staging, stored: &stored, heldBack: &heldBack) }
            }
        }

        publish(.firstSync(.verifying(done: accepted.count, total: accepted.count)))
        // Between the swap and the commit below the files and the rows disagree; launch repair must know.
        try store.journal.setMeta(Journal.Key.swapping, "1")
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
            for e in stored {
                let st = files.stat(e.path)
                if keepSet.contains(PathKey(e.path)) {
                    try db.execute(sql: "UPDATE files SET blob_sha = ? WHERE path = ?", arguments: [e.sha, e.path])
                } else {
                    try Journal.putFile(db, FileRow(path: e.path, blobSha: e.sha, diskSize: st?.size, diskMtime: st?.mtime))
                }
            }
            for held in heldBack {
                try holdBack(db, path: held.entry.path, sha: held.entry.sha, modified: nil, reason: held.reason, detail: held.detail, created: created)
            }
            try Journal.setMeta(db, Journal.Key.baseCommit, head)
            try Journal.setMeta(db, Journal.Key.remoteHead, head)
            try Journal.setMeta(db, Journal.Key.datesPending, "1")
            try Journal.setMeta(db, Journal.Key.swapping, nil)
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

    /// One note of first sync into staging, or held back when this disk can't hold its name or it is too large to keep.
    private static func stage(_ e: TreeEntry, _ data: Data, in staging: FileStore, stored: inout [TreeEntry],
                              heldBack: inout [(entry: TreeEntry, reason: String, detail: String?)]) throws {
        if try staging.writeIfPossible(e.path, data) {
            stored.append(e)
        } else {
            heldBack.append((e, heldBackReason(data), nil))
        }
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

/// Blob bodies fetched during one run, by sha, up to a budget in bytes. A body that would pass it is not kept: a retry
/// fetches it again, which costs a request and never memory.
struct BlobCache: Sendable {
    let limitBytes: Int
    private(set) var bytes = 0
    private var bodies: [String: Data] = [:]

    init(limitBytes: Int) { self.limitBytes = limitBytes }

    subscript(sha: String) -> Data? { bodies[sha] }

    mutating func keep(_ data: Data, for sha: String) {
        guard bodies[sha] == nil, data.count <= limitBytes - bytes else { return }
        bodies[sha] = data
        bytes += data.count
    }

    mutating func removeAll() {
        bodies = [:]
        bytes = 0
    }
}
