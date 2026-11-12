import BrainNotesKit
import Observation
import SwiftUI
import os

#if os(iOS)
import UIKit
#endif

/// App-wide state on the main actor. It owns the account and session, listens to the engine, and keeps the
/// lists' data fresh. All disk work is awaited off the main thread.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case needsSignIn
        case needsRepoSelection
        case ready
        case failed(String)
    }

    /// Plain-language recovery state when the picked repository is no longer in the user's GitHub App installation
    /// or was made public on GitHub. Syncing is stopped until resolved or switched.
    enum RepoIssue: Equatable {
        case notListed(slug: String)
        case publicRepo(slug: String)

        var title: String {
            switch self {
            case .notListed:
                return "Can’t reach these notes"
            case .publicRepo:
                return "Private notes only"
            }
        }

        var message: String {
            switch self {
            case let .notListed(slug):
                return "Brain Notes can no longer reach \(slug) on GitHub. Choose your notes again to keep syncing."
            case .publicRepo:
                return RepoTarget.publicRepoMessage
            }
        }
    }

    enum DiscoveryViewState: Equatable {
        case loading
        case loaded(DiscoveryResult)
        case failed(String)
    }

    static let maxInstallPolls = 60

    /// `@AppStorage` key: the first-run screens are over, so a device with no sign-in starts at Connect.
    /// Set when the Ready screen shows, so a kill mid-flow starts at Welcome again. The one other writer
    /// is `signOutAndWipe`, for users who signed in before these screens existed.
    static let onboardedKey = "bn.onboarded"
    /// The user chose the sample notes and has not left them, so the next launch opens them again.
    static let sampleModeKey = "bn.sampleMode"
    /// This install has launched before. `UserDefaults` go when the app is deleted, Keychain items stay, so
    /// a launch without this key and without local data is a new install, and finds no sign-in (audit B2).
    static let installedKey = "bn.installed"

    private(set) var phase: Phase = .loading
    private(set) var account: BrainAccount?
    private(set) var session: BrainSession?
    private(set) var snapshot = SyncSnapshot()
    private(set) var discoveryState: DiscoveryViewState = .loading
    private(set) var repoIssue: RepoIssue?
    private(set) var isPollingInstallations = false
    private(set) var awaitingInstallAfterCreate = false
    private(set) var isDeviceOnline = true
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
    let webSession: InAppWebSession
    let usesSystemClipboard: Bool
    private let sessions: SessionFactory
    private let log = Logger(subsystem: "com.itamargendelman.brainnotes", category: "app")
    private var listener: Task<Void, Never>?
    private var openVerifyTask: Task<Void, Never>?
    private var installPollTask: Task<Void, Never>?
    private var monitor: NetworkMonitor?
    private var router: Router?
    private var startedOnce = false
    private var currentPhase: ScenePhase = .active
    private weak var openEditor: NoteEditorModel?

    init(options: LaunchOptions = .current,
         sessions: SessionFactory = .standard,
         defaults: UserDefaults? = nil,
         webSession: InAppWebSession? = nil) {
        self.options = options
        self.sessions = sessions
        self.defaults = defaults ?? Self.launchDefaults(for: options)
        self.webSession = webSession ?? (options.demo || !sessions.usesSystemSideEffects ? .inert() : .system())
        self.usesSystemClipboard = !options.demo && sessions.usesSystemSideEffects
    }

    /// A demo launch never touches the real app's settings: its own, empty each time.
    /// A Debug `-BNPreviewRoot` launch uses a different suite, so it does not wipe the shared demo suite.
    private static func launchDefaults(for options: LaunchOptions) -> UserDefaults {
        #if DEBUG
        if options.previewRoot != nil {
            let name = "com.itamargendelman.brainnotes.preview"
            guard let preview = UserDefaults(suiteName: name) else { return .standard }
            preview.removePersistentDomain(forName: name)
            return preview
        }
        #endif
        let name = "com.itamargendelman.brainnotes.demo"
        guard options.demo, let demo = UserDefaults(suiteName: name) else { return .standard }
        demo.removePersistentDomain(forName: name)
        return demo
    }

    /// What `RootView` shows instead of the notes: sign-in, choosing notes, or the Ready screen.
    var showsOnboarding: Bool {
        phase == .needsSignIn || phase == .needsRepoSelection || readyScreenPending
    }

    /// Every note the home screen counts.
    var noteCount: Int { folders.reduce(0) { $0 + $1.totalCount } + rootNotes.count + inboxCount }

    /// True when the open session has unsynced edits in its journal outbox.
    var hasUnsyncedEdits: Bool {
        (session?.hasUnsyncedEdits ?? false) || snapshot.unsynced > 0
    }

    var isDemoSignIn: Bool {
        options.demo || session?.isDemo == true
    }

    func deviceFlow() -> DeviceFlow? {
        if let s = session, !s.isDemo {
            return s.deviceFlow()
        }
        return account?.deviceFlow()
    }

    // MARK: start

    func start(router: Router) async {
        guard !startedOnce else { return }
        startedOnce = true
        self.router = router
        // Before anything reads the Keychain. A demo launch never touches it.
        if !options.demo { forgetTokensOfAnEarlierInstall() }
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

    /// What the first launch of an install does about tokens already in the Keychain.
    enum InstallCheck: Equatable {
        /// Not the first launch: the check was made before.
        case nothing
        /// A new install: whatever the Keychain holds was left by a copy of the app that was deleted.
        case clearTokens
        /// The first launch of a version with this check, on a device that used the app before: an update,
        /// which must never sign anyone out.
        case keepTokens
    }

    static func installCheck(launchedBefore: Bool, localDataExists: Bool) -> InstallCheck {
        if launchedBefore { return .nothing }
        return localDataExists ? .keepTokens : .clearTokens
    }

    /// iOS keeps Keychain items when the app is deleted, so a reinstall would open signed in and download
    /// every note with no prompt. The first launch of an install clears them, unless the device already has
    /// local data of this app (`Brain/`, or one of its settings): then this is an update, and it keeps them.
    private func forgetTokensOfAnEarlierInstall() {
        guard !defaults.bool(forKey: Self.installedKey) else { return }
        // No folder to look in: keep the tokens, and look again at the next launch.
        guard let base = try? sessions.baseFolder() else { return }
        // `BrainSession.live` and `SelectedRepoStore` keep everything under `Brain/`.
        let localData = FileManager.default.fileExists(atPath: base.appendingPathComponent("Brain", isDirectory: true).path)
            || defaults.object(forKey: Self.onboardedKey) != nil
            || defaults.object(forKey: Self.sampleModeKey) != nil
        if Self.installCheck(launchedBefore: false, localDataExists: localData) == .clearTokens {
            sessions.clearTokens()
        }
        defaults.set(true, forKey: Self.installedKey)
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
            let base = try sessions.baseFolder()
            let acct = try sessions.account(base)
            account = acct
            startNetworkMonitor()
            guard acct.hasTokens else {
                phase = .needsSignIn
                return
            }
            let stored: SelectedRepo?
            do {
                stored = try acct.selectionStore.load()
            } catch {
                // Corrupted or invalid selection JSON on disk: discard it and re-verify via the picker.
                acct.selectionStore.clear()
                stored = nil
            }
            guard let stored else {
                await beginRepoSelection(autoSelectSinglePrivate: true)
                return
            }
            let s = try sessions.live(base, stored)
            session = s
            repoIssue = nil
            listen(to: s)
            await reloadLists()
            phase = .ready
            launchRepairAndVerify(session: s, stored: stored, base: base, account: acct)
        } catch {
            phase = .failed("Could not open the local data.")
            log.error("session open failed")
        }
    }

    private func startNetworkMonitor() {
        monitor = NetworkMonitor { [weak self] online in
            Task { @MainActor [weak self] in
                await self?.setOnline(online)
            }
        }
    }

    func setOnline(_ online: Bool) async {
        isDeviceOnline = online
        if let s = session {
            await s.engine.setOnline(online)
        } else {
            snapshot.state = online ? .idle : .offline
        }
    }

    /// Runs local launch repair off the main thread, then re-verifies `stored` against `/user/installations` before
    /// starting sync (or defers verification to `SyncEngine`'s own `installationCheck` if offline or locked at launch).
    private func launchRepairAndVerify(session s: BrainSession, stored: SelectedRepo, base: URL, account acct: BrainAccount) {
        openVerifyTask?.cancel()
        openVerifyTask = Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                _ = try? s.store.reconcile()
                try? s.store.repairIndexIfNeeded()
            }.value
            guard !Task.isCancelled, let self, self.session === s else { return }
            await self.reloadLists()

            do {
                let verified = try await acct.discoveryClient().verifySelection(stored)
                guard !Task.isCancelled, self.session === s else { return }
                try? acct.selectionStore.save(verified)
                if verified != stored, let updated = try? self.sessions.live(base, verified) {
                    await s.engine.stop()
                    guard !Task.isCancelled, self.session === s else { return }
                    self.session = updated
                    self.listen(to: updated)
                    await self.reloadLists()
                    await updated.engine.start()
                } else {
                    await s.engine.start()
                }
            } catch SelectionVerificationError.notListed {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                self.repoIssue = .notListed(slug: stored.slug)
            } catch SelectionVerificationError.publicRepo {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                self.repoIssue = .publicRepo(slug: stored.slug)
            } catch GitHubError.unauthorized {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.start()
            } catch {
                // Offline, timed out, rate-limited, or Keychain locked right now: keep offline notes accessible and
                // let SyncEngine enforce `installationCheck` + `verifyPrivateRepo()` when connectivity returns.
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.start()
            }
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
        case .chooseNotes?:
            discoveryState = .loaded(Self.demoDiscoveryResult)
            phase = .needsRepoSelection
        case _?:
            phase = .needsSignIn
        }
    }

    private static var demoDiscoveryResult: DiscoveryResult {
        let priv = try? DiscoveredRepo(
            installationId: 1, repoId: 1, owner: "alex", name: "brain", defaultBranch: "main", isPrivate: true
        )
        let pub = try? DiscoveredRepo(
            installationId: 1, repoId: 2, owner: "alex", name: "public-blog", defaultBranch: "main", isPrivate: false
        )
        return DiscoveryResult(installationsCount: 1, repositories: [priv, pub].compactMap { $0 })
    }

    /// Cancels the listener first, so nothing from this session reaches the model after this call. What the model
    /// holds of the session's notes goes too, the delete's Undo above all: its snapshots are the deleted notes' text,
    /// and an Undo left on screen after Sign out and wipe would write them into the next session's fresh folder.
    private func dropSession() {
        listener?.cancel()
        listener = nil
        openVerifyTask?.cancel()
        openVerifyTask = nil
        installPollTask?.cancel()
        installPollTask = nil
        webSession.cancel()
        monitor = nil
        router?.reset()
        session = nil
        folders = []
        folderTree = []
        rootNotes = []
        inboxCount = 0
        statuses = [:]
        snapshot = SyncSnapshot()
        changedPaths = []
        moved = nil
        undoDismissTask?.cancel()
        undoDismissTask = nil
        blackHole = nil
        blackHoleSnapshots = []
        openEditor = nil
    }

    // MARK: sample notes

    /// Try with Sample Notes. Any live data waiting in `Brain/` is left untouched on disk so it comes back when
    /// sample mode ends.
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
    /// live flow opens as at any launch. Ends in `.needsSignIn`, since sample mode implies no tokens.
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
        if let s = session, !s.isDemo {
            switch snapshot.state {
            case .accessLost:
                repoIssue = .notListed(slug: s.repo.slug)
            case .publicRepo:
                repoIssue = .publicRepo(slug: s.repo.slug)
            default:
                break
            }
        }
    }

    // MARK: discovery, installation browser, and repo selection

    func beginRepoSelection(autoSelectSinglePrivate: Bool) async {
        installPollTask?.cancel()
        installPollTask = nil
        isPollingInstallations = false
        awaitingInstallAfterCreate = false
        discoveryState = .loading
        phase = .needsRepoSelection
        await refreshDiscovery(autoSelectSinglePrivate: autoSelectSinglePrivate)
    }

    func refreshDiscovery(autoSelectSinglePrivate: Bool) async {
        if options.demo {
            discoveryState = .loaded(Self.demoDiscoveryResult)
            return
        }
        guard let acct = account else {
            phase = .needsSignIn
            return
        }
        discoveryState = .loading
        do {
            let result = try await acct.discoveryClient().listAccessibleRepositories()
            discoveryState = .loaded(result)
            if autoSelectSinglePrivate, result.privateRepositories.count == 1 {
                await selectRepository(result.privateRepositories[0])
            }
        } catch GitHubError.unauthorized {
            discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
        } catch {
            discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
        }
    }

    /// Opens `https://github.com/apps/<slug>/installations/new` in `ASWebAuthenticationSession`, polls
    /// `/user/installations` every few seconds (capped at `maxInstallPolls`), and closes the browser automatically
    /// as soon as a repository appears.
    func openGitHubAppInstall() {
        guard !options.demo, let acct = account else { return }
        guard let url = try? acct.config.installAppURL() else {
            discoveryState = .failed("This app build has an invalid GitHub App address.")
            return
        }
        let baselineIds: Set<Int64>
        if case let .loaded(existing) = discoveryState {
            baselineIds = Set(existing.repositories.map(\.repoId))
        } else {
            baselineIds = []
        }

        awaitingInstallAfterCreate = false
        installPollTask?.cancel()
        isPollingInstallations = true

        webSession.open(url) { [weak self] _ in
            guard let self else { return }
            // User closed the browser sheet (or returned via setup URL): stop background loop and check once now.
            self.installPollTask?.cancel()
            self.installPollTask = nil
            self.isPollingInstallations = false
            if self.phase == .needsRepoSelection {
                Task { @MainActor [weak self] in
                    await self?.refreshDiscovery(autoSelectSinglePrivate: baselineIds.isEmpty)
                }
            }
        }

        let interval = sessions.installPollInterval
        installPollTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.maxInstallPolls {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.phase == .needsRepoSelection else { return }
                guard let result = try? await acct.discoveryClient().listAccessibleRepositories() else { continue }
                guard !Task.isCancelled, self.phase == .needsRepoSelection else { return }
                self.discoveryState = .loaded(result)
                let currentIds = Set(result.repositories.map(\.repoId))
                let foundNew = !currentIds.subtracting(baselineIds).isEmpty
                if (baselineIds.isEmpty && !result.repositories.isEmpty) || foundNew {
                    self.installPollTask = nil
                    self.isPollingInstallations = false
                    self.webSession.cancel()
                    if result.privateRepositories.count == 1 {
                        await self.selectRepository(result.privateRepositories[0])
                    }
                    return
                }
            }
            if let self {
                self.installPollTask = nil
                self.isPollingInstallations = false
            }
        }
    }

    /// Guidance flow for creating a new private notes repository on GitHub without asking for extra account-wide
    /// permissions: opens GitHub's pre-filled "New repository" page (`visibility=private`) in the in-app browser,
    /// then guides the user to the "Choose notes on GitHub" step.
    func openCreateBrain() {
        awaitingInstallAfterCreate = true
        guard !options.demo else { return }
        webSession.open(AppConfig.createBrainURL) { _ in }
    }

    /// Optional custom URL scheme return (`brainnotes://setup`) if configured as the GitHub App's Setup URL.
    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == InAppWebSession.callbackScheme else { return }
        webSession.cancel()
        if phase == .needsRepoSelection {
            Task { await refreshDiscovery(autoSelectSinglePrivate: true) }
        }
    }

    /// Selects a discovered private repository, verifies it against `/user/installations`, persists the selection,
    /// and starts the first sync.
    func selectRepository(_ repo: DiscoveredRepo) async {
        guard repo.isPrivate else {
            discoveryState = .failed(RepoTarget.publicRepoMessage)
            return
        }
        if options.demo {
            readyScreenPending = true
            phase = .ready
            return
        }
        guard let selection = try? repo.select(),
              let base = try? sessions.baseFolder() else {
            discoveryState = .failed("That notes repository could not be opened.")
            return
        }
        installPollTask?.cancel()
        installPollTask = nil
        isPollingInstallations = false
        webSession.cancel()

        do {
            let opened = try await sessions.openVerified(base, selection)
            session = opened
            repoIssue = nil
            readyScreenPending = true
            snapshot = SyncSnapshot()
            snapshot.state = .firstSync(.downloading)
            listen(to: opened)
            await reloadLists()
            phase = .ready
            await opened.engine.start()
        } catch SelectionVerificationError.publicRepo, RepoTarget.GuardError.publicRepo {
            discoveryState = .failed(RepoTarget.publicRepoMessage)
        } catch SelectionVerificationError.notListed {
            discoveryState = .failed("GitHub didn’t list \(repo.slug) under your approved notes. Try choosing it again.")
        } catch {
            discoveryState = .failed("Couldn’t open \(repo.slug) right now. Check your connection and try again.")
        }
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
                    if !s.isDemo, !self.readyScreenPending {
                        switch snap.state {
                        case .accessLost:
                            self.repoIssue = .notListed(slug: s.repo.slug)
                        case .publicRepo:
                            self.repoIssue = .publicRepo(slug: s.repo.slug)
                        default:
                            break
                        }
                    }
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
        if phase == .background {
            Task { await account?.forgetCachedTokens() }
        }
        guard let s = session, self.phase == .ready else { return }
        switch phase {
        case .active:
            if repoIssue == nil {
                Task {
                    await s.engine.start()
                    await reloadLists()
                }
            }
        case .background:
            flushInBackground(s)
        case .inactive:
            // Whatever is being typed is saved the moment the app stops being in front.
            Task { await openEditor?.saveNow(self) }
            #if os(macOS)
            if repoIssue == nil {
                Task { await s.engine.sync(.leftNote) }
            }
            #endif
        @unknown default:
            break
        }
    }

    /// Plan: a short background task on leaving the app flushes the outbox. No background merge after it.
    /// The open note is saved first, so the flush takes it along. Once it is over, the tokens are in the Keychain only.
    private func flushInBackground(_ s: BrainSession) {
        #if os(iOS)
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "flush") { box.end() }
        #endif
        Task {
            await openEditor?.saveNow(self)
            await s.flushInBackground()
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
        guard let s = session, repoIssue == nil else { return }
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
        // The session ended while the notes were read (Sign out and wipe): nothing of it is kept or offered back.
        guard session === s else { return }

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
        // Ended during the deletes: its `dropSession` already cleared the snapshots, and no Undo appears.
        guard session === s else { return }
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
        guard session === s else { return }
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

    /// Re-checks whether a previously public or unreachable repository is now private and reachable again.
    func retryCurrentRepository() async {
        guard let s = session, !s.isDemo, let acct = account else { return }
        guard let selection = s.selection ?? (try? acct.selectionStore.load()) else {
            await changeNotesRepository()
            return
        }
        do {
            let verified = try await acct.discoveryClient().verifySelection(selection)
            try? acct.selectionStore.save(verified)
            repoIssue = nil
            await s.engine.start()
            await s.engine.sync(.manual)
        } catch SelectionVerificationError.publicRepo {
            repoIssue = .publicRepo(slug: selection.slug)
        } catch SelectionVerificationError.notListed {
            repoIssue = .notListed(slug: selection.slug)
        } catch {
            // Keep the current issue visible so the user can retry once online.
        }
    }

    func signedIn(pair: TokenPair) async {
        // A demo or sample session never accepts a real sign-in.
        guard !options.demo, !sampleMode else { return }
        if let s = session {
            guard !s.isDemo else { return }
            showSignIn = false
            do {
                try await s.signedIn(with: pair)
                if let acct = account, let base = try? sessions.baseFolder(), let sel = s.selection {
                    launchRepairAndVerify(session: s, stored: sel, base: base, account: acct)
                } else {
                    await s.engine.start()
                }
            } catch {
                readyScreenPending = false
                phase = .failed("Could not store the sign-in in the Keychain.")
            }
            return
        }

        guard let acct = account else { return }
        showSignIn = false
        do {
            try await acct.saveTokens(pair)
        } catch {
            readyScreenPending = false
            phase = .failed("Could not store the sign-in in the Keychain.")
            return
        }
        await beginRepoSelection(autoSelectSinglePrivate: true)
    }

    /// Saves any open editor buffer to disk first, then answers whether the local journal has unsynced edits so the UI
    /// can warn and require explicit confirmation before wiping and opening the picker.
    func checkUnsyncedBeforeRepoSwitch() async -> Bool {
        await openEditor?.saveNow(self)
        return hasUnsyncedEdits
    }

    /// Wipes the old repository's local copy (same wipe path as Sign out and wipe: files, journal + `-wal`/`-shm`,
    /// pins, staging, search index, plus in-memory plaintext and Undo snapshots) BEFORE opening the picker.
    /// Keychain tokens stay intact because the user remains signed in.
    func changeNotesRepository() async {
        guard let s = session else { return }
        if s.isDemo {
            await leaveSampleNotes()
            return
        }
        await openEditor?.saveNow(self)
        phase = .loading
        repoIssue = nil
        readyScreenPending = false
        dropSession()
        do {
            try await s.wipeForRepoSwitch()
        } catch {
            log.error("repo switch wipe failed")
            phase = .failed(Self.repoSwitchWipeFailedMessage)
            return
        }
        await beginRepoSelection(autoSelectSinglePrivate: false)
    }

    func signOutAndWipe() async {
        let s = session
        let acct = account
        guard s != nil || acct != nil else { return }
        phase = .loading
        repoIssue = nil
        readyScreenPending = false
        dropSession()
        // Back to Connect, not Welcome, also for someone who signed in before these screens existed.
        defaults.set(true, forKey: Self.onboardedKey)
        do {
            if let s {
                try await s.signOutAndWipe()
            } else if let acct {
                try await acct.signOutAndWipe()
            }
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

    static let repoSwitchWipeFailedMessage = "Some notes from the previous repository could not be deleted from this device. Open Brain Notes again and choose Sign out and wipe in Settings before switching."
}

/// How the model opens its account and sessions. Tests pass their own: tokens in memory, a transport that refuses
/// every request, a throwaway folder. So no test can reach the Keychain or GitHub.
@MainActor
struct SessionFactory {
    var baseFolder: () throws -> URL
    /// Read without opening a live session, which a device in sample mode never needs.
    var tokensExist: () -> Bool
    var account: (URL) throws -> BrainAccount
    var openVerified: (URL, SelectedRepo) async throws -> BrainSession
    var live: (URL, SelectedRepo) throws -> BrainSession
    var demo: (URL) async throws -> BrainSession
    /// Removes the tokens without opening a session: the first launch of a new install (`installedKey`).
    var clearTokens: () -> Void
    var installPollInterval: Duration = .seconds(3)
    var usesSystemSideEffects = false

    static let standard = SessionFactory(
        baseFolder: {
            #if DEBUG
            // Demo only. `previewRoot` is nil unless this process was launched as a demo with -BNPreviewRoot.
            if let root = LaunchOptions.current.previewRoot {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                return root
            }
            #endif
            return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        },
        tokensExist: {
            // As `BrainSession.hasTokens`: a token that cannot be read right now still counts, any other failure does not.
            KeychainTokenStore().holdsTokens()
        },
        account: { base in
            BrainAccount(config: AppConfig(info: Bundle.main.infoDictionary ?? [:]), baseFolder: base)
        },
        openVerified: { base, selection in
            try await BrainSession.openVerified(
                config: AppConfig(info: Bundle.main.infoDictionary ?? [:]),
                selection: selection,
                baseFolder: base,
                deviceLabel: deviceLabel
            )
        },
        live: { base, selection in
            try BrainSession.live(
                config: AppConfig(info: Bundle.main.infoDictionary ?? [:]),
                selection: selection,
                baseFolder: base,
                deviceLabel: deviceLabel
            )
        },
        demo: { base in
            let fixtures = await Task.detached { bundledFixtures() }.value
            return try await BrainSession.demo(fixtures: fixtures, baseFolder: base)
        },
        clearTokens: {
            KeychainTokenStore().clear()
        },
        installPollInterval: .seconds(3),
        usesSystemSideEffects: true)

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
