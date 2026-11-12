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

    nonisolated static let accountCheckFailedMessage = "Can't check your GitHub account right now. Try again."

    nonisolated static func accountMismatchMessage(login: String) -> String {
        "Signed in as @\(login), which doesn’t match the account for these notes. Choose Sign out and wipe to switch accounts."
    }

    /// Plain-language recovery state when the picked repository or GitHub account cannot be verified, is no longer
    /// in the user's GitHub App installation, or was made public on GitHub. Syncing is stopped until resolved or switched.
    enum RepoIssue: Equatable {
        case notListed(slug: String)
        case publicRepo(slug: String)
        case truncated(slug: String)
        case unverifiedOwner(slug: String)
        case accountCheckFailed(unauthorized: Bool)
        case accountMismatch(login: String)

        var title: String {
            switch self {
            case .notListed:
                return "Can’t reach these notes"
            case .publicRepo:
                return "Private notes only"
            case .truncated:
                return "Too many repositories"
            case .unverifiedOwner, .accountCheckFailed:
                return "Verify your GitHub account"
            case .accountMismatch:
                return "Different GitHub account"
            }
        }

        var message: String {
            switch self {
            case let .notListed(slug):
                return "Brain Notes can no longer reach \(slug) on GitHub. Try again or choose your notes again."
            case .publicRepo:
                return RepoTarget.publicRepoMessage
            case .truncated:
                return DiscoveryResult.truncatedMessage
            case let .unverifiedOwner(slug):
                return "Sign in to confirm \(slug) belongs to your GitHub account before opening local notes on this device."
            case let .accountCheckFailed(unauthorized):
                if unauthorized {
                    return "GitHub didn’t accept this sign-in. Sign in again or try again to confirm your account."
                }
                return AppModel.accountCheckFailedMessage
            case let .accountMismatch(login):
                return AppModel.accountMismatchMessage(login: login)
            }
        }

        var allowsRetry: Bool {
            switch self {
            case .notListed, .publicRepo, .truncated, .accountCheckFailed:
                return true
            case .unverifiedOwner, .accountMismatch:
                return false
            }
        }

        var offersSignIn: Bool {
            switch self {
            case .unverifiedOwner, .accountMismatch:
                return true
            case let .accountCheckFailed(unauthorized):
                return unauthorized
            case .notListed, .publicRepo, .truncated:
                return false
            }
        }

        var isAccountMismatch: Bool {
            if case .accountMismatch = self { return true }
            return false
        }

        var hidesLocalNotes: Bool {
            switch self {
            case .unverifiedOwner, .accountCheckFailed, .accountMismatch:
                return true
            case .notListed, .publicRepo, .truncated:
                return false
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
    private(set) var signedInUser: GitHubAccount?
    private(set) var reSignInError: String?
    private(set) var isSelectingRepository = false
    private(set) var isInstallSheetActive = false
    private(set) var isPollingInstallations = false
    private(set) var awaitingInstallAfterCreate = false
    private(set) var repoSelectionAutoSelect = true
    private var sessionOwnerVerifiedThisLaunch = false
    private var accountCheckFailedForNetwork = false
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
    private var openVerifyTaskID = UUID()
    private var installPollTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var backgroundCancelTasks: [Task<Void, Never>] = []
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

    /// True during the brief live-launch window before `GET /user` confirms the stored selection's owner.
    var isAwaitingOwnerVerificationAtLaunch: Bool {
        guard let s = session, !s.isDemo, !sampleMode, !readyScreenPending, repoIssue == nil else {
            return false
        }
        return !sessionOwnerVerifiedThisLaunch
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
        let brainURL = base.appendingPathComponent("Brain", isDirectory: true)
        let localData = (!LegacyBrainMigration.isSymbolicLink(brainURL) && FileManager.default.fileExists(atPath: brainURL.path))
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
        self.sessionOwnerVerifiedThisLaunch = true
        listen(to: session)
        await reloadLists()
        snapshot = await session.engine.snapshot
        phase = .ready
    }

    private func startLive() async {
        do {
            let base = try sessions.baseFolder()
            await Task.detached(priority: .userInitiated) {
                LegacyBrainMigration.cleanUpLegacyFolders(baseFolder: base)
            }.value

            let acct = try sessions.account(base)
            account = acct
            reSignInError = nil
            let stored: SelectedRepo?
            do {
                stored = try acct.selectionStore.load()
            } catch {
                // Unreadable or corrupt selection JSON on disk: discard it and wipe orphaned Brain/<id>/ folders.
                acct.selectionStore.clear()
                stored = nil
            }
            if stored == nil {
                do {
                    try await wipeUnboundBrainFolder(baseFolder: base)
                } catch {
                    log.error("orphan brain wipe failed at launch")
                    readyScreenPending = false
                    phase = .failed(Self.repoSwitchWipeFailedMessage)
                    return
                }
            }
            startNetworkMonitor()
            guard acct.hasTokens else {
                signedInUser = nil
                phase = .needsSignIn
                return
            }
            guard let stored else {
                await beginRepoSelection(autoSelectSinglePrivate: true)
                return
            }
            if let uid = stored.userId, let login = stored.userLogin {
                signedInUser = GitHubAccount(id: uid, login: login)
            } else {
                signedInUser = nil
            }
            let s = try sessions.live(acct, stored)
            session = s
            sessionOwnerVerifiedThisLaunch = false
            accountCheckFailedForNetwork = false
            repoIssue = nil
            clearLoadedNoteLists()
            listen(to: s)
            phase = .ready
            launchRepairAndVerify(session: s, stored: stored, account: acct)
        } catch {
            phase = .failed("Could not open the local data.")
            log.error("session open failed")
        }
    }

    private func startNetworkMonitor() {
        guard sessions.usesSystemSideEffects else { return }
        monitor = NetworkMonitor { [weak self] online in
            Task { @MainActor [weak self] in
                await self?.setOnline(online)
            }
        }
    }

    func setOnline(_ online: Bool) async {
        isDeviceOnline = online
        guard let s = session else {
            snapshot.state = online ? .idle : .offline
            return
        }
        if !online {
            await s.engine.setOnline(false)
            return
        }
        if s.isDemo {
            await s.engine.setOnline(true)
            return
        }
        guard sessionOwnerVerifiedThisLaunch, repoIssue == nil else {
            await s.engine.stop()
            await s.engine.setOnline(true)
            if accountCheckFailedForNetwork, currentPhase != .background {
                await retryCurrentRepository()
            }
            return
        }
        await s.engine.setOnline(true)
    }

    /// Runs local launch repair off the main thread, then verifies the signed-in account via `GET /user` and the
    /// installation via `/user/installations` before showing local notes or starting sync.
    private func launchRepairAndVerify(session s: BrainSession, stored: SelectedRepo, account acct: BrainAccount) {
        openVerifyTask?.cancel()
        let taskID = UUID()
        openVerifyTaskID = taskID
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.openVerifyTaskID == taskID {
                    self?.openVerifyTask = nil
                }
            }
            let repairTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                do {
                    _ = try s.store.reconcile()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
                try Task.checkCancellation()
                try s.store.repairIndexIfNeeded()
            }
            await withTaskCancellationHandler {
                _ = try? await repairTask.value
            } onCancel: {
                repairTask.cancel()
            }
            guard !Task.isCancelled, let self, self.session === s else { return }

            let user: GitHubAccount
            do {
                user = try await acct.discoveryClient().authenticatedUser()
            } catch is CancellationError {
                return
            } catch GitHubError.unauthorized {
                guard !Task.isCancelled, self.session === s else { return }
                self.sessionOwnerVerifiedThisLaunch = false
                self.accountCheckFailedForNetwork = false
                await s.engine.stop()
                self.clearLoadedNoteLists()
                self.repoIssue = stored.hasVerifiedOwner
                    ? .accountCheckFailed(unauthorized: true)
                    : .unverifiedOwner(slug: stored.slug)
                return
            } catch {
                guard !Task.isCancelled, self.session === s else { return }
                self.sessionOwnerVerifiedThisLaunch = false
                self.accountCheckFailedForNetwork = true
                await s.engine.stop()
                self.clearLoadedNoteLists()
                self.repoIssue = stored.hasVerifiedOwner
                    ? .accountCheckFailed(unauthorized: false)
                    : .unverifiedOwner(slug: stored.slug)
                return
            }

            guard !Task.isCancelled, self.session === s else { return }
            self.accountCheckFailedForNetwork = false
            if let expectedId = stored.userId, user.id != expectedId {
                self.sessionOwnerVerifiedThisLaunch = false
                await s.engine.stop()
                self.clearLoadedNoteLists()
                self.repoIssue = .accountMismatch(login: user.login)
                return
            }

            do {
                let candidate = try stored.withAccount(user)
                let verified = try await acct.discoveryClient().verifySelection(candidate)
                guard !Task.isCancelled, self.session === s else { return }
                let activeSession = try await self.applyVerifiedSelection(verified, to: s, account: acct)
                guard !Task.isCancelled, self.session === activeSession else { return }
                self.signedInUser = user
                self.sessionOwnerVerifiedThisLaunch = true
                self.repoIssue = nil
                await self.reloadLists()
                await activeSession.engine.start()
            } catch is CancellationError {
                return
            } catch SelectionVerificationError.notListed {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !stored.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                }
                self.repoIssue = .notListed(slug: stored.slug)
            } catch SelectionVerificationError.publicRepo {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !stored.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                }
                self.repoIssue = .publicRepo(slug: stored.slug)
            } catch SelectionVerificationError.truncated {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !stored.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                }
                self.repoIssue = .truncated(slug: stored.slug)
            } catch {
                guard !Task.isCancelled, self.session === s else { return }
                if !stored.hasVerifiedOwner {
                    await s.engine.stop()
                    self.clearLoadedNoteLists()
                    self.repoIssue = .unverifiedOwner(slug: stored.slug)
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                    await s.engine.start()
                }
            }
        }
        openVerifyTask = task
    }

    /// Updates `s` in place when `verified` names the same `repoId`, `owner`, and `name` (avoiding opening a second
    /// `NoteStore` over the same SQLite files). If a rebuild is ever needed, stops the engine, waits until idle, and
    /// closes the old store's databases before opening the new session.
    private func applyVerifiedSelection(
        _ verified: SelectedRepo,
        to s: BrainSession,
        account acct: BrainAccount
    ) async throws -> BrainSession {
        if verified.repoId == s.repo.repoId,
           verified.owner.utf8.elementsEqual(s.repo.owner.utf8),
           verified.name.utf8.elementsEqual(s.repo.name.utf8) {
            try s.updateVerifiedSelection(verified)
            await s.engine.markSelectionVerified()
            return s
        }
        await s.engine.stop()
        await s.engine.waitUntilIdle()
        s.store.close()
        try acct.selectionStore.save(verified)
        let rebuilt = try sessions.live(acct, verified)
        await rebuilt.engine.markSelectionVerified()
        session = rebuilt
        listen(to: rebuilt)
        return rebuilt
    }

    private func clearLoadedNoteLists() {
        folders = []
        folderTree = []
        rootNotes = []
        inboxCount = 0
        statuses = [:]
        revision += 1
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
            signedInUser = GitHubAccount(id: 1, login: "alex")
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
        discoveryTask?.cancel()
        discoveryTask = nil
        isInstallSheetActive = false
        isPollingInstallations = false
        webSession.cancel()
        monitor = nil
        router?.reset()
        session = nil
        sessionOwnerVerifiedThisLaunch = false
        accountCheckFailedForNetwork = false
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
            try? LegacyBrainMigration.wipeFolderNoFollow(BrainSession.demoFolder(in: base))
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
            case let .accountMismatch(login):
                sessionOwnerVerifiedThisLaunch = false
                accountCheckFailedForNetwork = false
                clearLoadedNoteLists()
                repoIssue = .accountMismatch(login: login)
                Task { await s.engine.stop() }
            case let .accountCheckFailed(unauthorized):
                sessionOwnerVerifiedThisLaunch = false
                accountCheckFailedForNetwork = !unauthorized
                clearLoadedNoteLists()
                repoIssue = (s.selection?.hasVerifiedOwner == false)
                    ? .unverifiedOwner(slug: s.repo.slug)
                    : .accountCheckFailed(unauthorized: unauthorized)
                Task { await s.engine.stop() }
            case .accessLost:
                repoIssue = .notListed(slug: s.repo.slug)
                Task { await s.engine.stop() }
            case .installationTruncated:
                repoIssue = .truncated(slug: s.repo.slug)
                Task { await s.engine.stop() }
            case .publicRepo:
                repoIssue = .publicRepo(slug: s.repo.slug)
                Task { await s.engine.stop() }
            default:
                break
            }
        }
    }

    // MARK: discovery, installation browser, and repo selection

    func beginRepoSelection(autoSelectSinglePrivate: Bool) async {
        repoSelectionAutoSelect = autoSelectSinglePrivate
        installPollTask?.cancel()
        installPollTask = nil
        isInstallSheetActive = false
        isPollingInstallations = false
        awaitingInstallAfterCreate = false
        discoveryState = .loading
        phase = .needsRepoSelection
        await refreshDiscovery(autoSelectSinglePrivate: autoSelectSinglePrivate)
    }

    func refreshDiscovery(autoSelectSinglePrivate: Bool) async {
        if options.demo {
            signedInUser = GitHubAccount(id: 1, login: "alex")
            discoveryState = .loaded(Self.demoDiscoveryResult)
            return
        }
        guard let acct = account else {
            phase = .needsSignIn
            return
        }
        discoveryTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.discoveryState = .loading
            do {
                // BN-01: Fetch and expose `@login` on the choose-notes screen BEFORE listing or auto-selecting any repository.
                let user = try await acct.discoveryClient().authenticatedUser()
                try Task.checkCancellation()
                guard self.phase == .needsRepoSelection else { return }
                self.signedInUser = user
                await Task.yield()

                let result = try await acct.discoveryClient().listAccessibleRepositories()
                try Task.checkCancellation()
                guard self.phase == .needsRepoSelection else { return }
                self.discoveryState = .loaded(result)
                await Task.yield()

                if autoSelectSinglePrivate,
                   self.signedInUser != nil,
                   !result.isTruncated,
                   result.repositories.count == 1,
                   result.privateRepositories.count == 1 {
                    await self.selectRepository(result.privateRepositories[0])
                }
            } catch GitHubError.unauthorized {
                guard !Task.isCancelled else { return }
                self.signedInUser = nil
                self.discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
            } catch {
                guard !Task.isCancelled else { return }
                self.discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
            }
        }
        discoveryTask = task
        await task.value
        if discoveryTask == task {
            discoveryTask = nil
        }
    }

    func retryDiscovery() async {
        await refreshDiscovery(autoSelectSinglePrivate: repoSelectionAutoSelect)
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
        let initialBaselineIds: Set<Int64>?
        if case let .loaded(existing) = discoveryState {
            initialBaselineIds = Set(existing.repositories.map(\.repoId))
        } else {
            initialBaselineIds = nil
        }

        awaitingInstallAfterCreate = false
        installPollTask?.cancel()
        isInstallSheetActive = true
        isPollingInstallations = true

        webSession.open(url) { [weak self] callbackURL in
            guard let self else { return }
            self.isInstallSheetActive = false
            self.installPollTask?.cancel()
            self.installPollTask = nil
            self.isPollingInstallations = false
            if let callbackURL, !Self.isValidSetupCallbackURL(callbackURL) {
                return
            }
            if self.phase == .needsRepoSelection {
                Task { @MainActor [weak self] in
                    await self?.retryDiscovery()
                }
            }
        }

        let interval = sessions.installPollInterval
        installPollTask = Task { @MainActor [weak self] in
            var baselineIds = initialBaselineIds
            if baselineIds == nil {
                do {
                    guard let self, self.phase == .needsRepoSelection else { return }
                    if self.signedInUser == nil {
                        let user = try await acct.discoveryClient().authenticatedUser()
                        guard !Task.isCancelled, self.phase == .needsRepoSelection else { return }
                        self.signedInUser = user
                    }
                    let baselineResult = try await acct.discoveryClient().listAccessibleRepositories()
                    guard !Task.isCancelled, self.phase == .needsRepoSelection else { return }
                    self.discoveryState = .loaded(baselineResult)
                    baselineIds = Set(baselineResult.repositories.map(\.repoId))
                } catch is CancellationError {
                    return
                } catch {
                    // Leave discoveryState unchanged and baselineIds nil so polling will not auto-pick without baseline.
                }
            }
            let baselineKnownBeforePolls = baselineIds != nil

            for _ in 0..<Self.maxInstallPolls {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.phase == .needsRepoSelection else { return }
                let result: DiscoveryResult
                do {
                    if self.signedInUser == nil {
                        let user = try await acct.discoveryClient().authenticatedUser()
                        guard !Task.isCancelled, self.phase == .needsRepoSelection else { return }
                        self.signedInUser = user
                    }
                    result = try await acct.discoveryClient().listAccessibleRepositories()
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
                guard !Task.isCancelled, self.phase == .needsRepoSelection else { return }
                self.discoveryState = .loaded(result)

                if let knownBaseline = baselineIds {
                    let appeared = knownBaseline.isEmpty
                        ? result.repositories
                        : result.repositories.filter { !knownBaseline.contains($0.repoId) }
                    if !appeared.isEmpty {
                        self.isInstallSheetActive = false
                        self.installPollTask = nil
                        self.isPollingInstallations = false
                        self.webSession.cancel()
                        if self.repoSelectionAutoSelect,
                           baselineKnownBeforePolls,
                           !result.isTruncated,
                           self.signedInUser != nil,
                           appeared.count == 1,
                           appeared[0].isPrivate {
                            await self.selectRepository(appeared[0])
                        }
                        return
                    }
                } else {
                    // Initial baseline fetch failed (e.g. opened from .failed while offline): never auto-pick
                    // without a known pre-install baseline.
                    baselineIds = Set(result.repositories.map(\.repoId))
                    if !result.repositories.isEmpty {
                        self.isInstallSheetActive = false
                        self.installPollTask = nil
                        self.isPollingInstallations = false
                        self.webSession.cancel()
                        return
                    }
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
        isInstallSheetActive = false
        awaitingInstallAfterCreate = true
        guard !options.demo else { return }
        webSession.open(AppConfig.createBrainURL) { _ in }
    }

    static func isValidSetupCallbackURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == InAppWebSession.callbackScheme,
              url.host?.lowercased() == "setup",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            return false
        }
        return true
    }

    /// Optional custom URL scheme return (`brainnotes://setup`) accepted ONLY while choosing notes and the install sheet is active.
    func handleOpenURL(_ url: URL) {
        guard phase == .needsRepoSelection,
              isInstallSheetActive,
              Self.isValidSetupCallbackURL(url) else {
            return
        }
        isInstallSheetActive = false
        installPollTask?.cancel()
        installPollTask = nil
        isPollingInstallations = false
        webSession.cancel()
        Task { await retryDiscovery() }
    }

    /// Selects a discovered private repository (single-flight), verifies it against `/user` and `/user/installations`,
    /// wipes any previously open session or unbound local folder first, persists the owner-bound selection, and starts sync.
    func selectRepository(_ repo: DiscoveredRepo) async {
        guard !isSelectingRepository else { return }
        guard repo.isPrivate else {
            discoveryState = .failed(RepoTarget.publicRepoMessage)
            return
        }
        if options.demo {
            readyScreenPending = true
            phase = .ready
            return
        }
        guard let acct = account else {
            phase = .needsSignIn
            return
        }
        isSelectingRepository = true
        defer { isSelectingRepository = false }

        let user: GitHubAccount
        if let knownUser = signedInUser {
            user = knownUser
        } else {
            do {
                let fetched = try await acct.discoveryClient().authenticatedUser()
                signedInUser = fetched
                user = fetched
            } catch GitHubError.unauthorized {
                discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                return
            } catch {
                discoveryState = .failed("Couldn’t confirm your GitHub account. Check your connection and try again.")
                return
            }
        }

        guard let selection = try? repo.select(account: user),
              let base = try? sessions.baseFolder() else {
            discoveryState = .failed("That notes repository could not be opened.")
            return
        }

        isInstallSheetActive = false
        installPollTask?.cancel()
        installPollTask = nil
        isPollingInstallations = false
        webSession.cancel()

        if let previous = session {
            dropSession()
            do {
                try await previous.wipeForRepoSwitch()
            } catch {
                log.error("previous session wipe before select failed")
                discoveryState = .failed(Self.repoSwitchWipeFailedMessage)
                return
            }
        } else if (try? acct.selectionStore.load()) == nil {
            acct.selectionStore.clear()
            do {
                try await wipeUnboundBrainFolder(baseFolder: base)
            } catch {
                log.error("orphan brain wipe before select failed")
                discoveryState = .failed(Self.repoSwitchWipeFailedMessage)
                return
            }
        }

        do {
            let opened = try await sessions.openVerified(acct, selection)
            session = opened
            sessionOwnerVerifiedThisLaunch = true
            accountCheckFailedForNetwork = false
            repoIssue = nil
            readyScreenPending = true
            snapshot = SyncSnapshot()
            snapshot.state = .checking
            listen(to: opened)
            await reloadLists()
            phase = .ready
            await opened.engine.start()
        } catch SelectionVerificationError.publicRepo, RepoTarget.GuardError.publicRepo {
            discoveryState = .failed(RepoTarget.publicRepoMessage)
        } catch SelectionVerificationError.truncated {
            discoveryState = .failed(DiscoveryResult.truncatedMessage)
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
                    if !s.isDemo {
                        switch snap.state {
                        case let .accountMismatch(login):
                            self.readyScreenPending = false
                            self.sessionOwnerVerifiedThisLaunch = false
                            self.accountCheckFailedForNetwork = false
                            self.clearLoadedNoteLists()
                            self.repoIssue = .accountMismatch(login: login)
                            Task { await s.engine.stop() }
                        case let .accountCheckFailed(unauthorized):
                            self.readyScreenPending = false
                            self.sessionOwnerVerifiedThisLaunch = false
                            self.accountCheckFailedForNetwork = !unauthorized
                            self.clearLoadedNoteLists()
                            self.repoIssue = (s.selection?.hasVerifiedOwner == false)
                                ? .unverifiedOwner(slug: s.repo.slug)
                                : .accountCheckFailed(unauthorized: unauthorized)
                            Task { await s.engine.stop() }
                        case .accessLost where !self.readyScreenPending:
                            self.repoIssue = .notListed(slug: s.repo.slug)
                            Task { await s.engine.stop() }
                        case .installationTruncated where !self.readyScreenPending:
                            self.repoIssue = .truncated(slug: s.repo.slug)
                            Task { await s.engine.stop() }
                        case .publicRepo where !self.readyScreenPending:
                            self.repoIssue = .publicRepo(slug: s.repo.slug)
                            Task { await s.engine.stop() }
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
        if !s.isDemo {
            if !sessionOwnerVerifiedThisLaunch {
                clearLoadedNoteLists()
                return
            }
            if let sel = s.selection, !sel.hasVerifiedOwner {
                clearLoadedNoteLists()
                return
            }
            if repoIssue?.hidesLocalNotes == true {
                clearLoadedNoteLists()
                return
            }
        }
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
            let tasksToAwait = [installPollTask, openVerifyTask, discoveryTask].compactMap { $0 }
            for task in tasksToAwait {
                task.cancel()
            }
            installPollTask = nil
            isPollingInstallations = false
            isInstallSheetActive = false
            openVerifyTask = nil
            discoveryTask = nil
            backgroundCancelTasks = tasksToAwait
        }
        guard let s = session, self.phase == .ready else {
            if phase == .background {
                let tasksToAwait = backgroundCancelTasks
                backgroundCancelTasks = []
                let acct = account
                #if os(iOS)
                let box = BackgroundTaskBox()
                box.id = UIApplication.shared.beginBackgroundTask(withName: "evict") { box.end() }
                #endif
                Task {
                    for task in tasksToAwait {
                        await task.value
                    }
                    if self.currentPhase != .active {
                        await acct?.forgetCachedTokens()
                    }
                    #if os(iOS)
                    box.end()
                    #endif
                }
            } else if phase == .active,
                      self.phase == .needsRepoSelection,
                      case .loading = discoveryState,
                      discoveryTask == nil {
                Task { await retryDiscovery() }
            }
            return
        }
        switch phase {
        case .active:
            if repoIssue == nil {
                if s.isDemo || sessionOwnerVerifiedThisLaunch {
                    Task {
                        await s.engine.start()
                        await reloadLists()
                    }
                } else if openVerifyTask == nil, let stored = s.selection, let acct = account {
                    launchRepairAndVerify(session: s, stored: stored, account: acct)
                }
            } else if accountCheckFailedForNetwork, isDeviceOnline, openVerifyTask == nil {
                Task { await retryCurrentRepository() }
            }
        case .background:
            if s.isDemo || (sessionOwnerVerifiedThisLaunch && repoIssue == nil) {
                flushInBackground(s)
            } else {
                let tasksToAwait = backgroundCancelTasks
                backgroundCancelTasks = []
                let acct = account
                #if os(iOS)
                let box = BackgroundTaskBox()
                box.id = UIApplication.shared.beginBackgroundTask(withName: "evict") { box.end() }
                #endif
                Task {
                    await openEditor?.saveNow(self)
                    for task in tasksToAwait {
                        await task.value
                    }
                    if self.currentPhase != .active {
                        await acct?.forgetCachedTokens()
                        await s.engine.stop()
                    }
                    #if os(iOS)
                    box.end()
                    #endif
                }
            }
        case .inactive:
            // Whatever is being typed is saved the moment the app stops being in front.
            Task { await openEditor?.saveNow(self) }
            #if os(macOS)
            if repoIssue == nil, s.isDemo || sessionOwnerVerifiedThisLaunch {
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
        let tasksToAwait = backgroundCancelTasks
        backgroundCancelTasks = []
        let acct = account
        #if os(iOS)
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "flush") { box.end() }
        #endif
        Task {
            await openEditor?.saveNow(self)
            for task in tasksToAwait {
                await task.value
            }
            await s.flushInBackground()
            // The user may already be back; then polling must go on.
            if currentPhase != .active {
                await acct?.forgetCachedTokens()
                await s.engine.stop()
            }
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
        guard let s = session, repoIssue == nil, s.isDemo || sessionOwnerVerifiedThisLaunch else { return }
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
        if s.isDemo || (sessionOwnerVerifiedThisLaunch && repoIssue == nil) {
            await s.engine.sync(.leftNote)
        }
    }

    func freshSync() async {
        guard let s = session, s.isDemo || (sessionOwnerVerifiedThisLaunch && repoIssue == nil) else { return }
        await s.engine.freshSync()
        await reloadLists()
    }

    func setPaused(_ paused: Bool) async {
        guard let s = session else { return }
        if !paused, !s.isDemo, (!sessionOwnerVerifiedThisLaunch || repoIssue != nil) { return }
        await s.engine.setPaused(paused)
    }

    func syncNow() async {
        guard let s = session, s.isDemo || (sessionOwnerVerifiedThisLaunch && repoIssue == nil) else { return }
        await s.engine.sync(.manual)
    }

    /// Re-checks `GET /user` (matching `selection.userId` every time) and `/user/installations` before updating the
    /// session in place (including any renamed `default_branch`) without wiping local data or opening a second store.
    func retryCurrentRepository() async {
        guard let s = session, !s.isDemo, let acct = account else { return }
        guard let selection = s.selection ?? (try? acct.selectionStore.load()) else {
            await changeNotesRepository()
            return
        }
        openVerifyTask?.cancel()
        let taskID = UUID()
        openVerifyTaskID = taskID
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.openVerifyTaskID == taskID {
                    self?.openVerifyTask = nil
                }
            }
            guard !Task.isCancelled, let self, self.session === s else { return }
            let user: GitHubAccount
            do {
                user = try await acct.discoveryClient().authenticatedUser()
            } catch is CancellationError {
                return
            } catch GitHubError.unauthorized {
                guard !Task.isCancelled, self.session === s else { return }
                self.sessionOwnerVerifiedThisLaunch = false
                self.accountCheckFailedForNetwork = false
                await s.engine.stop()
                self.clearLoadedNoteLists()
                self.repoIssue = selection.hasVerifiedOwner
                    ? .accountCheckFailed(unauthorized: true)
                    : .unverifiedOwner(slug: selection.slug)
                return
            } catch {
                guard !Task.isCancelled, self.session === s else { return }
                self.sessionOwnerVerifiedThisLaunch = false
                self.accountCheckFailedForNetwork = true
                await s.engine.stop()
                self.clearLoadedNoteLists()
                self.repoIssue = selection.hasVerifiedOwner
                    ? .accountCheckFailed(unauthorized: false)
                    : .unverifiedOwner(slug: selection.slug)
                return
            }

            guard !Task.isCancelled, self.session === s else { return }
            self.accountCheckFailedForNetwork = false
            if let expectedId = selection.userId, user.id != expectedId {
                self.sessionOwnerVerifiedThisLaunch = false
                await s.engine.stop()
                self.clearLoadedNoteLists()
                self.repoIssue = .accountMismatch(login: user.login)
                return
            }

            do {
                let candidate = try selection.withAccount(user)
                let verified = try await acct.discoveryClient().verifySelection(candidate)
                guard !Task.isCancelled, self.session === s else { return }
                let activeSession = try await self.applyVerifiedSelection(verified, to: s, account: acct)
                guard !Task.isCancelled, self.session === activeSession else { return }
                self.signedInUser = user
                self.sessionOwnerVerifiedThisLaunch = true
                self.repoIssue = nil
                await self.reloadLists()
                await activeSession.engine.start()
                await activeSession.engine.sync(.manual)
            } catch is CancellationError {
                return
            } catch SelectionVerificationError.publicRepo {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !selection.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                }
                self.repoIssue = .publicRepo(slug: selection.slug)
            } catch SelectionVerificationError.notListed {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !selection.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                }
                self.repoIssue = .notListed(slug: selection.slug)
            } catch SelectionVerificationError.truncated {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !selection.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                } else {
                    self.signedInUser = user
                    self.sessionOwnerVerifiedThisLaunch = true
                    await self.reloadLists()
                }
                self.repoIssue = .truncated(slug: selection.slug)
            } catch {
                guard !Task.isCancelled, self.session === s else { return }
                await s.engine.stop()
                if !selection.hasVerifiedOwner {
                    self.clearLoadedNoteLists()
                    self.accountCheckFailedForNetwork = true
                    self.repoIssue = .unverifiedOwner(slug: selection.slug)
                } else {
                    self.signedInUser = user
                    if self.repoIssue == nil || self.repoIssue == .accountCheckFailed(unauthorized: false) {
                        self.sessionOwnerVerifiedThisLaunch = false
                        self.accountCheckFailedForNetwork = true
                        self.clearLoadedNoteLists()
                        self.repoIssue = .accountCheckFailed(unauthorized: false)
                    } else {
                        self.sessionOwnerVerifiedThisLaunch = true
                    }
                }
            }
        }
        openVerifyTask = task
        await task.value
    }

    func signedIn(pair: TokenPair) async {
        // A demo or sample session never accepts a real sign-in.
        guard !options.demo, !sampleMode else { return }
        if let s = session, s.isDemo { return }
        guard let acct = account else { return }
        showSignIn = false

        let storedSelection = session?.selection ?? (try? acct.selectionStore.load())
        if session != nil || storedSelection != nil {
            guard let existingSelection = storedSelection else {
                reSignInError = "These local notes aren’t linked to a verified GitHub account yet. Choose Sign out and wipe before signing in."
                return
            }
            // BN-02 / NB-04: Verify the candidate token against GET /user BEFORE saving to the Keychain or starting sync,
            // and capture the latest TokenPair from the candidate store in case refresh rotated a single-use refresh token.
            let candidateUser: GitHubAccount
            let verifiedPair: TokenPair
            do {
                (candidateUser, verifiedPair) = try await acct.verifyCandidateToken(pair)
            } catch {
                reSignInError = "Couldn’t verify which GitHub account signed in. Check your connection and try again."
                return
            }
            guard let expectedUserId = existingSelection.userId else {
                reSignInError = "These local notes aren’t linked to a verified GitHub account yet. Choose Sign out and wipe before signing in."
                return
            }
            guard candidateUser.id == expectedUserId else {
                reSignInError = Self.accountMismatchMessage(login: candidateUser.login)
                return
            }

            let refreshedSelection = (try? existingSelection.withAccount(candidateUser)) ?? existingSelection
            do {
                try await acct.saveTokens(verifiedPair)
                try? acct.selectionStore.save(refreshedSelection)
            } catch {
                readyScreenPending = false
                phase = .failed("Could not store the sign-in in the Keychain.")
                return
            }
            reSignInError = nil
            signedInUser = candidateUser
            sessionOwnerVerifiedThisLaunch = true
            accountCheckFailedForNetwork = false

            if let s = session {
                openVerifyTask?.cancel()
                openVerifyTask = nil
                try? s.updateVerifiedSelection(refreshedSelection)
                repoIssue = nil
                await reloadLists()
                await s.engine.signedIn()
                let snap = await s.engine.snapshot
                if repoIssue == nil,
                   currentPhase == .active,
                   snap.state != .accessLost,
                   snap.state != .installationTruncated,
                   snap.state != .publicRepo,
                   snap.state != .signedOut {
                    if case .accountMismatch = snap.state {} else if case .accountCheckFailed = snap.state {} else {
                        await s.engine.resumePolling()
                    }
                }
            } else {
                do {
                    let s = try sessions.live(acct, refreshedSelection)
                    session = s
                    repoIssue = nil
                    listen(to: s)
                    await reloadLists()
                    phase = .ready
                    launchRepairAndVerify(session: s, stored: refreshedSelection, account: acct)
                } catch {
                    phase = .failed("Could not open the local data.")
                }
            }
            return
        }

        guard let base = try? sessions.baseFolder() else {
            readyScreenPending = false
            phase = .failed("Could not open the local data.")
            return
        }
        acct.selectionStore.clear()
        do {
            try await wipeUnboundBrainFolder(baseFolder: base)
        } catch {
            log.error("orphan brain wipe before sign-in failed")
            readyScreenPending = false
            phase = .failed(Self.repoSwitchWipeFailedMessage)
            return
        }

        reSignInError = nil
        signedInUser = nil
        do {
            try await acct.saveTokens(pair)
        } catch {
            readyScreenPending = false
            phase = .failed("Could not store the sign-in in the Keychain.")
            return
        }
        await beginRepoSelection(autoSelectSinglePrivate: true)
    }

    private func wipeUnboundBrainFolder(baseFolder base: URL) async throws {
        let brainDir = base.appendingPathComponent("Brain", isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try LegacyBrainMigration.wipeFolderNoFollow(brainDir)
        }.value
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
        accountCheckFailedForNetwork = false
        reSignInError = nil
        signedInUser = nil
        readyScreenPending = false
        dropSession()
        // Back to Connect, not Welcome, also for someone who signed in before these screens existed.
        defaults.set(true, forKey: Self.onboardedKey)
        do {
            if let s {
                try await s.signOutAndWipe()
                if let acct {
                    acct.tokens.clear()
                    await acct.manager.reload()
                }
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
    var openVerified: (BrainAccount, SelectedRepo) async throws -> BrainSession
    var live: (BrainAccount, SelectedRepo) throws -> BrainSession
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
        openVerified: { account, selection in
            try await BrainSession.openVerified(
                account: account,
                selection: selection,
                deviceLabel: deviceLabel
            )
        },
        live: { account, selection in
            try BrainSession.live(
                account: account,
                selection: selection,
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
