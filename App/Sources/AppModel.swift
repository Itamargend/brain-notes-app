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

    private(set) var phase: Phase = .loading
    private(set) var session: BrainSession?
    private(set) var snapshot = SyncSnapshot()
    private(set) var folders: [FolderNode] = []
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

    let options = LaunchOptions.current
    private let log = Logger(subsystem: "com.itamargendelman.brainnotes", category: "app")
    private var listener: Task<Void, Never>?
    private var monitor: NetworkMonitor?
    private var router: Router?
    private var startedOnce = false
    private var currentPhase: ScenePhase = .active
    private weak var openEditor: NoteEditorModel?

    // MARK: start

    func start(router: Router) async {
        guard !startedOnce else { return }
        startedOnce = true
        self.router = router
        if options.demo {
            await startDemo()
        } else {
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

    private static var baseFolder: URL {
        get throws {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
    }

    private static var deviceLabel: String {
        #if os(iOS)
        "iphone"
        #else
        "mac"
        #endif
    }

    private func startLive() async {
        let config = AppConfig(info: Bundle.main.infoDictionary ?? [:])
        do {
            let s = try BrainSession.live(config: config, baseFolder: try Self.baseFolder, deviceLabel: Self.deviceLabel)
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

    private func startDemo() async {
        do {
            let fixtures = Self.demoFixtures()
            let s = try await BrainSession.demo(fixtures: fixtures, baseFolder: try Self.baseFolder)
            session = s
            listen(to: s)
            await reloadLists()
            phase = options.screen == "signin" ? .needsSignIn : .ready
            snapshot = await s.engine.snapshot
            router?.applyDeepLink(options: options, attention: await s.store.openAttention())
        } catch {
            phase = .failed("Could not load the demo notes.")
        }
    }

    /// The bundled demo set, or the small built-in one if the demo set is not in this build.
    private static func demoFixtures() -> [(path: String, text: String)] {
        for name in ["demo-brain", "DemoFixtures"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil) {
                let notes = DemoBrain.load(from: url)
                if !notes.isEmpty { return notes }
            }
        }
        return [("README.md", "# Demo\nNo fixtures in this build.\n")]
    }

    // MARK: engine events

    private func listen(to s: BrainSession) {
        listener?.cancel()
        listener = Task { [weak self] in
            for await event in s.engine.events {
                guard let self else { return }
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
        folders = FolderNode.tree(paths: paths).filter { $0.name != PathPolicy.inboxFolder }
        rootNotes = await s.store.index.notes(inFolder: "")
        inboxCount = paths.filter { $0.hasPrefix(PathPolicy.inboxFolder + "/") }.count
        let journal = s.store.journal
        statuses = await Task.detached { journal.statuses() }.value
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

    func delete(path: String) async {
        guard let s = session else { return }
        do {
            try await Task.detached { try s.store.delete(path: path) }.value
        } catch {
            log.error("delete failed")
        }
        await noteSaved()
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
        guard let s = session else { return }
        phase = .ready
        showSignIn = false
        do {
            try await s.signedIn(with: pair)
            await s.engine.start()
        } catch {
            phase = .failed("Could not store the sign-in in the Keychain.")
        }
    }

    func signOutAndWipe() async {
        guard let s = session else { return }
        phase = .loading
        listener?.cancel()
        router?.reset()
        session = nil
        folders = []
        rootNotes = []
        inboxCount = 0
        statuses = [:]
        snapshot = SyncSnapshot()
        do {
            try await s.signOutAndWipe()
        } catch {
            log.error("wipe failed")
        }
        startedOnce = false
        if let router { await start(router: router) }
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
        let sampleFolder = "projects"
        let sampleNote = "projects/brain-notes-app.md"
        let hebrewNote = "עברית/סיכום-פגישה-עם-נועה.md"
        switch options.screen {
        case "list":
            open(.folder(sampleFolder))
        case "note", "edit":
            open(.folder(sampleFolder))
            open(.note(options.hebrew ? hebrewNote : sampleNote))
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
