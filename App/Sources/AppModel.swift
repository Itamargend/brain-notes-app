import BrainNotesKit
import Observation
import SwiftUI
import os

#if os(iOS)
import UIKit
#endif

/// App-wide state on the main actor. It owns the session, listens to the engine, and keeps the
/// lists' data fresh. All disk work is awaited off the main thread.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case needsSignIn
        case ready
        /// The build is configured for a repo the app refuses, or not configured at all.
        case misconfigured(String)
        case failed(String)
    }

    /// `@AppStorage` key: the first-run screens are over, so a device with no sign-in starts at Connect.
    /// Set when the Ready screen shows, so a kill mid-flow starts at Welcome again. The one other writer
    /// is `signOutAndWipe`, for users who signed in before these screens existed.
    static let onboardedKey = "bn.onboarded"
    /// The user chose the sample notes and has not left them, so the next launch opens them again.
    static let sampleModeKey = "bn.sampleMode"

    private(set) var phase: Phase = .loading
    private(set) var session: BrainSession?
    private(set) var snapshot = SyncSnapshot()
    private(set) var folders: [FolderNode] = []
    /// Every folder, `_inbox` too. `folders` is what the home screen lists: no inbox, in any spelling.
    private(set) var folderTree: [FolderNode] = []
    private(set) var rootNotes: [IndexedNote] = []
    private(set) var inboxCount = 0
    private(set) var statuses: [PathKey: NoteSyncStatus] = [:]
    /// Bumps whenever note lists may have changed; list views reload on it.
    private(set) var revision = 0
    /// The paths from the latest sync change, for an open editor.
    private(set) var changedPaths: [String] = []
    private(set) var changeTick = 0
    private(set) var moved: (from: String, to: String)?
    /// Sign in again was requested while data stays browsable.
    var showSignIn = false
    /// Onboarding got to its last screen: a session is opening or running, but the notes are not open yet.
    private(set) var readyScreenPending = false
    /// This session is the sample notes the user chose. A `-BNDemoFixtures` launch is not, unless it says so.
    private(set) var sampleMode = false

    /// Delete UI: optional cinematic swirl (parked) and/or short Undo offer. Nil when idle.
    private(set) var blackHole: BlackHoleUIState?
    /// Snapshots waiting for the swirl to finish (or for Undo after delete).
    private var blackHoleSnapshots: [DeletedNoteSnapshot] = []
    private var blackHoleIntensity: BlackHoleIntensity = .light
    private var undoDismissTask: Task<Void, Never>?

    let options: LaunchOptions
    let defaults: UserDefaults
    private let sessions: SessionFactory
    private let log = Logger(subsystem: "com.itamargendelman.brainnotes", category: "app")
    private var listener: Task<Void, Never>?
    private var monitor: NetworkMonitor?
    private var router: Router?
    private var startedOnce = false
    private var currentPhase: ScenePhase = .active
    private weak var openEditor: NoteEditorModel?

    init(options: LaunchOptions = .current, sessions: SessionFactory = .standard, defaults: UserDefaults? = nil) {
        self.options = options
        self.sessions = sessions
        self.defaults = defaults ?? Self.launchDefaults(for: options)
    }

    /// A demo launch never touches the real app's settings: its own, empty each time.
    private static func launchDefaults(for options: LaunchOptions) -> UserDefaults {
        let name = "com.itamargendelman.brainnotes.demo"
        guard options.demo, let demo = UserDefaults(suiteName: name) else { return .standard }
        demo.removePersistentDomain(forName: name)
        return demo
    }

    /// What `RootView` shows instead of the notes. Only a device with no sign-in gets here: a launch that
    /// finds tokens goes from `.loading` to `.ready` with no Ready screen pending, flag or no flag.
    var showsOnboarding: Bool { phase == .needsSignIn || readyScreenPending }

    /// Every note the home screen counts.
    var noteCount: Int { folders.reduce(0) { $0 + $1.totalCount } + rootNotes.count + inboxCount }

    // MARK: start

    func start(router: Router) async {
        guard !startedOnce else { return }
        startedOnce = true
        self.router = router
        if options.demo {
            await startDemoLaunch()
        } else if defaults.bool(forKey: Self.sampleModeKey), !sessions.tokensExist() {
            await resumeSampleNotes()
        } else {
            // Tokens win over a stray flag, for good: it must not come back after a later wipe.
            defaults.removeObject(forKey: Self.sampleModeKey)
            await startLive()
        }
    }

    /// For the screen walk tests: their own demo session, away from the host app's.
    func start(session: BrainSession, router: Router) async {
        startedOnce = true
        self.router = router
        self.session = session
        listen(to: session)
        await reloadLists()
        snapshot = await session.engine.snapshot
        phase = .ready
    }

    private func startLive() async {
        do {
            let s = try sessions.live(try sessions.baseFolder())
            session = s
            listen(to: s)
            monitor = NetworkMonitor { [weak s] online in
                guard let s else { return }
                Task { await s.engine.setOnline(online) }
            }
            await reloadLists()
            let signedIn = s.hasTokens
            phase = signedIn ? .ready : .needsSignIn
            // Launch repair runs off the main thread and never blocks the first screen. The engine starts
            // after it, so it never mistakes a file the engine just replaced for a local edit.
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = try? s.store.reconcile()
                try? s.store.repairIndexIfNeeded()
                await self?.reloadLists()
                if signedIn { await s.engine.start() }
            }
        } catch RepoTarget.GuardError.repoNotAllowed {
            phase = .misconfigured("This build is not set up for the allowed test repo.")
        } catch {
            phase = .failed("Could not open the local data.")
            log.error("session open failed")
        }
    }

    /// Opens a demo session: fake GitHub in process, no transport, no Keychain, its own folder.
    private func openDemoSession() async -> Bool {
        do {
            let s = try await sessions.demo(try sessions.baseFolder())
            session = s
            listen(to: s)
            await reloadLists()
            snapshot = await s.engine.snapshot
            return true
        } catch {
            readyScreenPending = false
            phase = .failed("Could not load the demo notes.")
            return false
        }
    }

    /// `-BNDemoFixtures`, `BN_DEMO=1` or an onboarding `-BNScreen`.
    private func startDemoLaunch() async {
        guard await openDemoSession(), let s = session else { return }
        switch options.onboardingStep {
        case nil:
            phase = .ready
            router?.applyDeepLink(options: options, attention: await s.store.openAttention())
        case .ready?:
            sampleMode = true
            readyScreenPending = true
            phase = .ready
        case _?:
            phase = .needsSignIn
        }
    }

    /// Cancels the listener first, so nothing from this session reaches the model after this call.
    private func dropSession() {
        listener?.cancel()
        listener = nil
        monitor = nil
        router?.reset()
        session = nil
        folders = []
        folderTree = []
        rootNotes = []
        inboxCount = 0
        statuses = [:]
        snapshot = SyncSnapshot()
    }

    // MARK: sample notes

    /// Try with Sample Notes. The session that was waiting for a sign-in is dropped, not wiped: whatever a
    /// signed-out device still holds in `Brain/` comes back when the sample notes end.
    func startSampleNotes() async {
        // A second tap finds the phase already moved on.
        guard phase == .needsSignIn else { return }
        sampleMode = true
        readyScreenPending = true
        phase = .loading
        let waiting = session
        dropSession()
        await waiting?.engine.stop()
        guard await openDemoSession() else {
            sampleMode = false
            return
        }
        defaults.set(true, forKey: Self.sampleModeKey)
        phase = .ready
    }

    /// A later launch of someone who chose the sample notes: straight to them, freshly made.
    private func resumeSampleNotes() async {
        guard await openDemoSession() else {
            // Never stuck here: the next launch offers Connect again.
            defaults.removeObject(forKey: Self.sampleModeKey)
            return
        }
        sampleMode = true
        phase = .ready
    }

    /// Connect GitHub from Settings: the sample notes, and anything typed in them, are deleted, then the
    /// live session opens as at any launch. Ends in `.needsSignIn`, since sample mode implies no tokens.
    func leaveSampleNotes() async {
        guard sampleMode else { return }
        let sample = session
        phase = .loading
        readyScreenPending = false
        dropSession()
        sampleMode = false
        if let sample {
            await sample.engine.stop()
            await sample.engine.waitUntilIdle()
            do {
                try await sample.signOutAndWipe()
            } catch {
                log.error("sample wipe failed")
            }
        }
        if let base = try? sessions.baseFolder() {
            try? FileManager.default.removeItem(at: BrainSession.demoFolder(in: base))
        }
        // Last: a kill before this point just reopens the sample notes, which starts clean.
        defaults.removeObject(forKey: Self.sampleModeKey)
        if options.demo {
            // A demo launch stays away from the Keychain and GitHub, whatever is tapped.
            if await openDemoSession() { phase = .needsSignIn }
        } else {
            await startLive()
        }
    }

    /// Open My Notes.
    func openNotesFromReadyScreen() {
        readyScreenPending = false
    }

    // MARK: engine events

    private func listen(to s: BrainSession) {
        listener?.cancel()
        listener = Task { [weak self] in
            for await event in s.engine.events {
                // A cancelled stream still hands over what it had buffered, and those events belong to a
                // session that is gone.
                guard !Task.isCancelled, let self, self.session === s else { return }
                switch event {
                case let .snapshot(snap):
                    self.snapshot = snap
                case let .notesChanged(paths):
                    self.changedPaths = paths
                    self.changeTick += 1
                    await self.reloadLists()
                case let .noteMoved(from, to):
                    self.moved = (from, to)
                    self.changeTick += 1
                }
            }
        }
    }

    func reloadLists() async {
        guard let s = session else { return }
        let paths = await s.store.index.allPaths()
        let root = await s.store.index.notes(inFolder: "")
        let journal = s.store.journal
        let files = s.store.files
        let (noteStatuses, emptyFolders) = await Task.detached { (journal.statuses(), files.emptyFolders()) }.value
        // The session can change during those waits: sample notes must not land in the live lists, or the reverse.
        guard session === s else { return }
        folderTree = FolderNode.tree(paths: paths, emptyFolders: emptyFolders)
        folders = folderTree.filter { !PathPolicy.isInbox($0.name) }
        rootNotes = root
        inboxCount = paths.filter(PathPolicy.isInInbox).count
        statuses = noteStatuses
        revision += 1
    }

    func status(of path: String) -> NoteSyncStatus { statuses[PathKey(path)] ?? .synced }

    // MARK: lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        currentPhase = phase
        guard let s = session, self.phase == .ready else { return }
        switch phase {
        case .active:
            Task {
                await s.engine.start()
                await reloadLists()
            }
        case .background:
            flushInBackground(s)
        case .inactive:
            // Whatever is being typed is saved the moment the app stops being in front.
            Task { await openEditor?.saveNow(self) }
            #if os(macOS)
            Task { await s.engine.sync(.leftNote) }
            #endif
        @unknown default:
            break
        }
    }

    /// Plan: a short background task on leaving the app flushes the outbox. No background merge after it.
    /// The open note is saved first, so the flush takes it along.
    private func flushInBackground(_ s: BrainSession) {
        #if os(iOS)
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "flush") { box.end() }
        #endif
        Task {
            await openEditor?.saveNow(self)
            await s.engine.sync(.background)
            // The user may already be back; then polling must go on.
            if currentPhase != .active { await s.engine.stop() }
            #if os(iOS)
            box.end()
            #endif
        }
    }

    /// The note on screen, so that leaving the app can save it first.
    func editorAppeared(_ editor: NoteEditorModel) { openEditor = editor }

    func editorDisappeared(_ editor: NoteEditorModel) {
        if openEditor === editor { openEditor = nil }
    }

    // MARK: actions

    func noteSaved() async {
        guard let s = session else { return }
        await s.engine.noteSaved()
        await reloadLists()
    }

    func leftNote() {
        guard let s = session else { return }
        Task { await s.engine.sync(.leftNote) }
    }

    /// New Folder. On disk now, on GitHub with its first note. `parent` is empty for the top level.
    func createFolder(named name: String, in parent: String) async -> Result<String, NoteStore.FolderProblem> {
        guard let s = session else { return .failure(.notAllowed) }
        let result: Result<String, NoteStore.FolderProblem> = await Task.detached {
            do {
                return .success(try s.store.createFolder(named: name, in: parent))
            } catch let problem as NoteStore.FolderProblem {
                return .failure(problem)
            } catch {
                return .failure(.notAllowed)
            }
        }.value
        await reloadLists()
        return result
    }

    /// Immediate store delete without Undo. Prefer `requestDelete` so the Undo chip can appear.
    func delete(path: String) async {
        guard let s = session else { return }
        do {
            try await Task.detached { try s.store.delete(path: path) }.value
        } catch {
            log.error("delete failed")
        }
        await noteSaved()
    }

    /// Deletes one or more notes.
    ///
    /// Default (parked): Apple Notes–style — store delete now, list closes the gap, short Undo chip.
    /// When `BlackHoleFeature.isEnabled`, plays the Metal black-hole / path-smear first, then deletes.
    /// Intensity defaults from the count (light for 1, full for ≥ 2); pass `.full` for a folder wipe.
    func requestDelete(paths: [String], intensity: BlackHoleIntensity? = nil) async {
        let unique = Self.uniquePaths(paths)
        guard !unique.isEmpty, let s = session else { return }
        // A second delete while Undo is up ends the previous offer (notes already gone).
        undoDismissTask?.cancel()
        undoDismissTask = nil
        if case .undo = blackHole { blackHole = nil }

        var snaps: [DeletedNoteSnapshot] = []
        for path in unique {
            let body: String = await Task.detached {
                (try? s.store.files.readText(path)) ?? ""
            }.value
            snaps.append(DeletedNoteSnapshot(path: path, text: body))
        }

        blackHoleSnapshots = snaps
        blackHoleIntensity = intensity ?? BlackHoleIntensity.forPathCount(snaps.count)

        if BlackHoleFeature.isEnabled {
            blackHole = .swirling(intensity: blackHoleIntensity, count: snaps.count)
            return
        }

        // Simple delete: remove now so the list can slide/dismiss like Apple Notes.
        for snap in snaps {
            do {
                try await Task.detached { try s.store.delete(path: snap.path) }.value
            } catch {
                log.error("delete failed")
            }
        }
        await noteSaved()
        withAnimation(.easeInOut(duration: 0.28)) {
            blackHole = .undo(count: snaps.count)
        }
        scheduleUndoDismiss()
    }

    /// Folder delete: every note under the folder (and subfolders), full intensity.
    /// Empty folders are not offered in the UI; this is a no-op if there are no notes.
    func requestDeleteFolder(path folder: String) async {
        let paths = await notePaths(underFolder: folder)
        guard !paths.isEmpty else { return }
        await requestDelete(paths: paths, intensity: .full)
    }

    /// Paths of notes in `folder` and every subfolder.
    func notePaths(underFolder folder: String) async -> [String] {
        guard let s = session else { return [] }
        let all = await s.store.index.notes(inFolder: nil)
        let prefix = folder + "/"
        return all.map(\.path).filter { $0.hasPrefix(prefix) }
    }

    func blackHoleAnimationDidFinish() async {
        guard case .swirling = blackHole else { return }
        let snaps = blackHoleSnapshots
        guard let s = session else {
            blackHole = nil
            blackHoleSnapshots = []
            return
        }
        for snap in snaps {
            do {
                try await Task.detached { try s.store.delete(path: snap.path) }.value
            } catch {
                log.error("delete failed")
            }
        }
        await noteSaved()
        blackHole = .undo(count: snaps.count)
        scheduleUndoDismiss()
    }

    func undoBlackHoleDelete() async {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        let snaps = blackHoleSnapshots
        blackHole = nil
        blackHoleSnapshots = []
        guard let s = session, !snaps.isEmpty else { return }
        for snap in snaps {
            do {
                try await Task.detached { _ = try s.store.save(path: snap.path, text: snap.text) }.value
            } catch {
                log.error("undo delete failed")
            }
        }
        await noteSaved()
    }

    func dismissBlackHoleUndo() {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        blackHole = nil
        blackHoleSnapshots = []
    }

    private func scheduleUndoDismiss() {
        undoDismissTask?.cancel()
        undoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(BlackHoleDeleteLogic.undoSeconds))
            guard !Task.isCancelled else { return }
            if case .undo = blackHole {
                blackHole = nil
                blackHoleSnapshots = []
            }
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<PathKey>()
        var out: [String] = []
        for p in paths {
            let key = PathKey(p)
            if seen.insert(key).inserted { out.append(p) }
        }
        return out
    }

    func resolve(_ item: AttentionItem, _ choice: AttentionChoice) async {
        guard let s = session else { return }
        do {
            try await Task.detached { try s.store.resolve(item, choice) }.value
        } catch {
            log.error("resolve failed")
        }
        await s.engine.noteSaved()
        await s.engine.refresh()
        await reloadLists()
        await s.engine.sync(.leftNote)
    }

    func freshSync() async {
        guard let s = session else { return }
        await s.engine.freshSync()
        await reloadLists()
    }

    func setPaused(_ paused: Bool) async {
        await session?.engine.setPaused(paused)
    }

    func syncNow() async {
        await session?.engine.sync(.manual)
    }

    func signedIn(pair: TokenPair) async {
        // A demo session has nowhere to keep a real sign-in.
        guard let s = session, !s.isDemo else { return }
        // From the onboarding screens the Ready screen comes next. The plain sheet goes back to the notes.
        if phase == .needsSignIn {
            readyScreenPending = true
            // Ready shows progress from here on. The engine's first event replaces this.
            snapshot.state = .firstSync(.downloading)
        }
        phase = .ready
        showSignIn = false
        do {
            try await s.signedIn(with: pair)
            await s.engine.start()
        } catch {
            readyScreenPending = false
            phase = .failed("Could not store the sign-in in the Keychain.")
        }
    }

    func signOutAndWipe() async {
        guard let s = session else { return }
        phase = .loading
        dropSession()
        // Back to Connect, not Welcome, also for someone who signed in before these screens existed.
        defaults.set(true, forKey: Self.onboardedKey)
        do {
            try await s.signOutAndWipe()
        } catch {
            log.error("wipe failed")
            // The tokens are gone, the notes are not. Connect would hide that, so say it instead.
            readyScreenPending = false
            phase = .failed(Self.wipeFailedMessage)
            return
        }
        startedOnce = false
        if let router { await start(router: router) }
    }

    /// Shown instead of Connect when the notes outlived a wipe: the user must know they are still here.
    static let wipeFailedMessage = "You're signed out, but some notes could not be deleted from this device. Open Brain Notes again, sign in, and choose Sign out and wipe in Settings to try again."
}

/// How the model opens its sessions. Tests pass their own: tokens in memory, a transport that refuses
/// every request, a throwaway folder. So no test can reach the Keychain or GitHub.
@MainActor
struct SessionFactory {
    var baseFolder: () throws -> URL
    /// Read without opening a live session, which a device in sample mode never needs.
    var tokensExist: () -> Bool
    var live: (URL) throws -> BrainSession
    var demo: (URL) async throws -> BrainSession

    static let standard = SessionFactory(
        baseFolder: {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        },
        tokensExist: {
            // As `BrainSession.hasTokens`: a token that cannot be read right now still counts.
            do { return try KeychainTokenStore().load() != nil } catch { return true }
        },
        live: { base in
            try BrainSession.live(config: AppConfig(info: Bundle.main.infoDictionary ?? [:]), baseFolder: base, deviceLabel: deviceLabel)
        },
        demo: { base in
            let fixtures = await Task.detached { bundledFixtures() }.value
            return try await BrainSession.demo(fixtures: fixtures, baseFolder: base)
        })

    private static var deviceLabel: String {
        #if os(iOS)
        "iphone"
        #else
        "mac"
        #endif
    }

    /// The bundled demo set, or the small built-in one if the demo set is not in this build.
    private nonisolated static func bundledFixtures() -> [(path: String, text: String)] {
        for name in ["demo-brain", "DemoFixtures"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil) {
                let notes = DemoBrain.load(from: url)
                if !notes.isEmpty { return notes }
            }
        }
        return [("README.md", "# Demo\nNo fixtures in this build.\n")]
    }
}

#if os(iOS)
/// Holds a background task id for a completion handler that may run on any thread.
private final class BackgroundTaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
    @MainActor func end() {
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
#endif

/// Navigation for both layouts: a stack on iPhone, three columns on Mac.
enum Route: Hashable {
    case folder(String)
    case inbox
    case note(String)
    /// New note. The folder is nil for the home screen: the note goes to `_inbox`.
    case compose(folder: String?, id: UUID)
    case attention
    case attentionItem(Int64)
    case settings
}

@MainActor @Observable
final class Router {
    let usesStack: Bool
    var path: [Route] = []
    /// Mac: middle column (a list) and right column (a note or a detail).
    var content: Route?
    var detail: Route?

    init(usesStack: Bool) { self.usesStack = usesStack }

    func open(_ route: Route) {
        if usesStack {
            path.append(route)
            return
        }
        switch route {
        case .folder, .inbox, .attention:
            content = route
            detail = nil
        case .note, .compose, .attentionItem, .settings:
            detail = route
        }
    }

    /// A note moved or vanished under the screen showing it.
    func replaceTop(with route: Route?) {
        if usesStack {
            if !path.isEmpty { path.removeLast() }
            if let route { path.append(route) }
        } else {
            detail = route
        }
    }

    func reset() {
        path = []
        content = nil
        detail = nil
    }

    /// `-BNScreen` and `-BNHebrew`: open a screen directly, for screenshots and UI tests.
    func applyDeepLink(options: LaunchOptions, attention: [AttentionItem]) {
        let sampleFolder = "reading"
        let sampleNote = "reading/01-zero-to-one-secrets.md"
        let hebrewNote = "עברית/סודות-ועקרונות.md"
        switch options.screen {
        case "list":
            open(.folder(sampleFolder))
        case "note", "edit":
            open(.folder(sampleFolder))
            open(.note(options.hebrew ? hebrewNote : sampleNote))
        case "editor-spike":
            open(.folder("עברית"))
            open(.note("עברית/בדיקת-עורך.md"))
        case "algorithm":
            open(.folder("reading"))
            open(.note("reading/00-the-algorithm.md"))
        case "live":
            // Screenshot helper: The Prince study note, editing, no StyleTimingLine.
            open(.folder("reading"))
            open(.note("reading/the-prince-virtue-fortune.md"))
        case "table":
            // A note with a table, in the editor: English, or Hebrew with `-BNHebrew`.
            let folder = options.hebrew ? "עברית" : "health"
            open(.folder(folder))
            open(.note(options.hebrew ? "עברית/תקציב-טיול.md" : "health/running-log.md"))
        case "compose":
            open(.compose(folder: nil, id: UUID()))
        case "inbox":
            open(.inbox)
        case "attention":
            open(.attention)
        case "conflict":
            open(.attention)
            if let item = attention.first(where: { $0.reason == "conflict-copy" && $0.detail != "deleted-remotely" }) {
                open(.attentionItem(item.id))
            }
        case "settings":
            open(.settings)
        default:
            if options.hebrew {
                open(.folder("עברית"))
                open(.note(hebrewNote))
            }
        }
    }
}
