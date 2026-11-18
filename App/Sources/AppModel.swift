import BrainNotesKit
import Observation
import SwiftUI
import os

#if os(iOS)
import UIKit
#endif

/// One line per onboarding step and transition, for finding where a sign-in got stuck. Never a token, a device code,
/// a user code, a login, a repository name or anything from a note: only fixed words and counts, which are the only
/// values marked `.public`.
let onboardingLog = Logger(subsystem: "com.itamargendelman.brainnotes", category: "onboarding")

/// What `AppModel.signedIn` did with a sign-in. A refusal always leaves a visible state as well: the same words in
/// `reSignInError`, or `phase == .failed`. Nothing ends silently.
enum SignInOutcome: Equatable {
    /// Accepted: the next screen (choosing notes, or the notes themselves) is on its way.
    case connected
    /// The person left the sign-in (Cancel, or Use a different account) before it finished: nothing to show.
    case cancelled
    /// Not accepted, with what to tell the person. `differentAccount` is true when signing in with another account
    /// is the way forward (the account does not match the notes on this device).
    case refused(String, differentAccount: Bool)
}

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

    enum ActivePane: Equatable {
        case sidebar
        case list
        case editor
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
    /// Set when the notes (or the sample notes) first open, so a kill mid-flow starts at Welcome again. The one other writer
    /// is `signOutAndWipe`, for users who signed in before these screens existed.
    static let onboardedKey = "bn.onboarded"
    /// The user chose the sample notes and has not left them, so the next launch opens them again.
    static let sampleModeKey = "bn.sampleMode"
    /// This install has launched before. `UserDefaults` go when the app is deleted, Keychain items stay, so
    /// a launch without this key and without local data is a new install, and finds no sign-in (audit B2).
    static let installedKey = "bn.installed"

    private enum AccessSessionMode: Equatable {
        /// Opened by itself right after a first sign-in (no confirm step), and again by Open GitHub while waiting.
        case initialAfterSignIn
        /// Opened from `ChooseNotesView` (empty selection or picker).
        case chooseNotes(autoSelectSinglePrivate: Bool)
        /// Opened immediately from Settings → "Change notes…" or `RepoIssueView` while keeping current notes intact.
        case switchFromSession(currentRepoId: Int64, expectedUserId: Int64?)
    }

    private struct AccessBaseline: Equatable {
        let installationIds: Set<Int64>
        let repoIds: Set<Int64>
        let isTruncated: Bool
        let hasAllRepositoriesGrant: Bool

        init(_ result: DiscoveryResult) {
            self.installationIds = Set(result.installations.map(\.id))
            self.repoIds = Set(result.repositories.map(\.repoId))
            self.isTruncated = result.isTruncated
            self.hasAllRepositoriesGrant = result.hasAllRepositoriesGrant
        }
    }

    private struct PendingAccessReturn {
        let mode: AccessSessionMode
        let baseline: AccessBaseline?
    }

    private(set) var phase: Phase = .loading
    private(set) var account: BrainAccount?
    private(set) var session: BrainSession?
    private(set) var snapshot = SyncSnapshot()
    private(set) var isUserPaused = false
    private(set) var discoveryState: DiscoveryViewState = .loading
    private(set) var repoIssue: RepoIssue?
    private(set) var signedInUser: GitHubAccount?
    private(set) var reSignInError: String?
    private(set) var isSelectingRepository = false
    private(set) var isInstallSheetActive = false
    private(set) var isPollingInstallations = false
    private(set) var isAwaitingInitialGitHubGrant = false
    private(set) var isSwitchingRepositories = false
    var isPresentingRepoPicker = false
    private(set) var awaitingInstallAfterCreate = false
    private(set) var repoSelectionAutoSelect = false
    /// "Use a different account" was chosen: for the rest of this onboarding run the sign-in, access and create-notes
    /// pages open in a private window, so that Safari's GitHub account is not offered again. Reset when a new run
    /// starts (`beginOnboardingRun`), on sign-out, and once notes are chosen.
    private(set) var privateBrowser = false
    /// A GitHub page for the notes (access or create) was opened and has not been followed by a successful look at
    /// the list yet: returning to the app checks the list again.
    private var awaitingAccessReturn = false
    private var activeAccessMode: AccessSessionMode?
    private var activeAccessBaseline: AccessBaseline?
    /// What GitHub granted before a first sign-in opened the access page; Open GitHub reuses it while waiting.
    private var initialGrantBaseline: AccessBaseline?
    /// A first sign-in is between approval and the access page (saving the token, asking GitHub). Cancel can stop it.
    private var firstSignInInFlight = false
    /// Bumped when a first sign-in is cancelled, so the one in flight finds out after each wait and stops.
    private var firstSignInGeneration = 0
    /// An access session ended and its look at the list has not finished yet (kept if the background cancels it).
    private var pendingAccessReturn: PendingAccessReturn?
    private var lastKnownInstallations: [GitHubInstallation]?
    private var sessionOwnerVerifiedThisLaunch = false
    private var accountCheckFailedForNetwork = false
    private(set) var isDeviceOnline = true
    private(set) var folders: [FolderNode] = []
    /// Every folder, `_inbox` too. `folders` is what the home screen lists: no inbox, in any spelling.
    private(set) var folderTree: [FolderNode] = []
    private(set) var rootNotes: [IndexedNote] = []
    private(set) var pinnedNotes: [IndexedNote] = []
    private(set) var inboxCount = 0
    private(set) var statuses: [PathKey: NoteSyncStatus] = [:]
    /// Bumps whenever note lists may have changed; list views reload on it.
    private(set) var revision = 0
    /// The paths from the latest sync change, for an open editor.
    private(set) var changedPaths: [String] = []
    private(set) var changeTick = 0
    private(set) var moved: (from: String, to: String)?
    /// Mac focus tracking and multi-selection state.
    var activePane: ActivePane = .sidebar
    var macSearchQuery = ""
    var selectedNotePaths: Set<String> = []
    var selectionAnchor: String?
    private(set) var activeEditorPath: String?
    private(set) var listPreferences = ListPreferences()
    /// Sign in again was requested while data stays browsable.
    var showSignIn = false
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
        if options.screen == "search" {
            self.macSearchQuery = "books"
        }
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

    /// What `RootView` shows instead of the notes: sign-in (and the wait on GitHub), or choosing notes.
    var showsOnboarding: Bool {
        phase == .needsSignIn || phase == .needsRepoSelection
    }

    /// The Mac privacy cover's "is there note text to hide" (B7-3): the notes are on screen, and neither the sign-in
    /// code sheet nor a GitHub browser sheet is up. Those stay readable while the window is unfocused.
    var showsNoteContentForPrivacyCover: Bool {
        phase == .ready && !showSignIn && !webSession.isPresenting
    }

    /// True during the brief live-launch window before `GET /user` confirms the stored selection's owner.
    var isAwaitingOwnerVerificationAtLaunch: Bool {
        guard let s = session, !s.isDemo, !sampleMode, repoIssue == nil else {
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

    /// A new sign-in run from the Connect screen: shared browser again, and last run's refusal off the screen.
    func beginOnboardingRun() {
        privateBrowser = false
        reSignInError = nil
    }

    /// "Use a different account" turns the private window on for the rest of this run.
    func usePrivateBrowser(_ on: Bool) {
        privateBrowser = on
    }

    /// Who the approved sign-in belongs to (`GET /user`), with nothing saved: the pair stays in memory until the
    /// person confirms. Returns the latest pair too, in case a refresh rotated it while asking.
    func verifyCandidate(_ pair: TokenPair) async throws -> (account: GitHubAccount, pair: TokenPair) {
        guard let acct = account else { throw GitHubError.unauthorized }
        return try await acct.verifyCandidateToken(pair)
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
                await beginRepoSelection(autoSelectSinglePrivate: false)
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
                try Task.checkCancellation()
                _ = try? s.store.ensureEmptyFoldersHavePlaceholders()
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
                if activeSession.hasUnsyncedEdits {
                    self.syncImmediatelyIfReady()
                }
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
                    if s.hasUnsyncedEdits {
                        self.syncImmediatelyIfReady()
                    }
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
        pinnedNotes = []
        inboxCount = 0
        statuses = [:]
        selectedNotePaths = []
        selectionAnchor = nil
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
            phase = .failed("Could not load the demo notes.")
            return false
        }
    }

    /// `-BNDemoFixtures`, `BN_DEMO=1` or an onboarding `-BNScreen`.
    private func startDemoLaunch() async {
        guard await openDemoSession(), let s = session else { return }
        switch options.onboardingStep {
        case nil where options.opensSampleNotes:
            // `-BNScreen sample` (or the older `ready`): the sample notes, open, as after Try with Sample Notes.
            sampleMode = true
            phase = .ready
        case nil:
            phase = .ready
            router?.applyDeepLink(options: options, attention: await s.store.openAttention())
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
        isAwaitingInitialGitHubGrant = false
        isSwitchingRepositories = false
        isPresentingRepoPicker = false
        activeAccessMode = nil
        activeAccessBaseline = nil
        initialGrantBaseline = nil
        pendingAccessReturn = nil
        webSession.cancel()
        monitor = nil
        router?.reset()
        session = nil
        isUserPaused = false
        sessionOwnerVerifiedThisLaunch = false
        accountCheckFailedForNetwork = false
        folders = []
        folderTree = []
        rootNotes = []
        pinnedNotes = []
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
        activeEditorPath = nil
        selectedNotePaths = []
        selectionAnchor = nil
        macSearchQuery = ""
        listPreferences = ListPreferences()
        activePane = .sidebar
    }

    // MARK: sample notes

    /// Try with Sample Notes. Any live data waiting in `Brain/` is left untouched on disk so it comes back when
    /// sample mode ends.
    func startSampleNotes() async {
        // A second tap finds the phase already moved on.
        guard phase == .needsSignIn else { return }
        sampleMode = true
        phase = .loading
        let waiting = session
        dropSession()
        await waiting?.engine.stop()
        guard await openDemoSession() else {
            sampleMode = false
            return
        }
        defaults.set(true, forKey: Self.sampleModeKey)
        // Straight into the sample notes, with no ready screen in between. First run is over.
        defaults.set(true, forKey: Self.onboardedKey)
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

    // MARK: discovery, installation browser, and repo selection

    /// Returns the single private repository eligible for auto-connect after a GitHub grant, or `nil` when zero
    /// or multiple repositories are granted, any public repository is listed, the installation list is truncated,
    /// or the installation grants access to "All repositories".
    static func singleAutoConnectableRepo(in result: DiscoveryResult) -> DiscoveredRepo? {
        guard !result.isTruncated,
              !result.hasAllRepositoriesGrant,
              result.repositories.count == 1,
              result.privateRepositories.count == 1 else {
            return nil
        }
        return result.privateRepositories[0]
    }

    func beginRepoSelection(autoSelectSinglePrivate: Bool) async {
        repoSelectionAutoSelect = autoSelectSinglePrivate
        installPollTask?.cancel()
        installPollTask = nil
        isInstallSheetActive = false
        isPollingInstallations = false
        isAwaitingInitialGitHubGrant = false
        awaitingInstallAfterCreate = false
        activeAccessMode = nil
        activeAccessBaseline = nil
        pendingAccessReturn = nil
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
                guard self.phase == .needsRepoSelection || self.isPresentingRepoPicker else { return }
                if let s = self.session, let expectedUserId = s.selection?.userId, user.id != expectedUserId {
                    self.isPresentingRepoPicker = false
                    self.isSwitchingRepositories = false
                    self.sessionOwnerVerifiedThisLaunch = false
                    await s.engine.stop()
                    self.clearLoadedNoteLists()
                    self.repoIssue = .accountMismatch(login: user.login)
                    return
                }
                self.signedInUser = user
                await Task.yield()

                let result = try await acct.discoveryClient().listAccessibleRepositories()
                try Task.checkCancellation()
                guard self.phase == .needsRepoSelection || self.isPresentingRepoPicker else { return }
                self.lastKnownInstallations = result.installations
                self.discoveryState = .loaded(result)
                self.logDiscovery(result)
                if !result.repositories.isEmpty, self.awaitingAccessReturn {
                    // They granted access on GitHub and came back with the page still open: close it.
                    self.awaitingAccessReturn = false
                    self.webSession.cancel()
                }
                await Task.yield()

                if autoSelectSinglePrivate,
                   self.signedInUser != nil,
                   let single = Self.singleAutoConnectableRepo(in: result) {
                    await self.selectRepository(single, fromSettingsSwitch: self.session != nil)
                }
            } catch GitHubError.unauthorized {
                guard !Task.isCancelled else { return }
                onboardingLog.error("discovery failed: unauthorized")
                if self.session == nil {
                    self.signedInUser = nil
                }
                self.discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
            } catch {
                guard !Task.isCancelled else { return }
                onboardingLog.error("discovery failed: could not reach GitHub")
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
        await refreshDiscovery(autoSelectSinglePrivate: false)
    }

    /// What the list of notes on GitHub held: counts only.
    private func logDiscovery(_ result: DiscoveryResult) {
        let installs = result.installationsCount
        let repos = result.repositories.count
        let privateRepos = result.privateRepositories.count
        onboardingLog.info("discovery result: installations \(installs, privacy: .public), repositories \(repos, privacy: .public), private \(privateRepos, privacy: .public)")
        if repos == 0 {
            onboardingLog.info("access step shown: no notes granted yet")
        }
    }

    private func preferredAccessURL(account acct: BrainAccount) throws -> URL {
        let preferredLogin = signedInUser?.login ?? session?.selection?.userLogin
        let preferredId = session?.selection?.installationId
        if case let .loaded(existing) = discoveryState, !existing.installations.isEmpty {
            return try acct.config.accessManagementURL(
                installations: existing.installations,
                preferredInstallationId: preferredId,
                preferredAccountLogin: preferredLogin
            )
        }
        if let known = lastKnownInstallations {
            return try acct.config.accessManagementURL(
                installations: known,
                preferredInstallationId: preferredId,
                preferredAccountLogin: preferredLogin
            )
        }
        if let sel = session?.selection {
            let isOrg: Bool
            if let login = preferredLogin {
                isOrg = sel.owner.lowercased() != login.lowercased()
            } else {
                isOrg = false
            }
            return try acct.config.configureInstallationURL(
                installationId: sel.installationId,
                accountLogin: sel.owner,
                isOrganization: isOrg
            )
        }
        return try acct.config.installAppURL()
    }

    /// Opens GitHub's `installations/new` (first install) or the installation's configure page (`settings/installations/<id>`)
    /// in `ASWebAuthenticationSession`, checks the granted list immediately and every 3 seconds, and rechecks when the
    /// browser closes or the app returns to the foreground.
    func openGitHubAppInstall() {
        if isAwaitingInitialGitHubGrant {
            reopenGitHubForInitialGrant()
            return
        }
        guard !options.demo, let acct = account else { return }
        guard let url = try? preferredAccessURL(account: acct) else {
            discoveryState = .failed("This app build has an invalid GitHub App address.")
            return
        }
        let existingBaseline: AccessBaseline?
        let skipImmediate: Bool
        if case let .loaded(existing) = discoveryState {
            existingBaseline = AccessBaseline(existing)
            skipImmediate = false
        } else {
            existingBaseline = nil
            skipImmediate = false
        }
        let mode: AccessSessionMode
        if let s = session {
            mode = .switchFromSession(currentRepoId: s.repo.repoId, expectedUserId: s.selection?.userId)
        } else {
            mode = .chooseNotes(autoSelectSinglePrivate: repoSelectionAutoSelect)
        }
        startAccessSession(url: url, mode: mode, initialBaseline: existingBaseline, skipImmediateCheck: skipImmediate)
    }

    private func startAccessSession(
        url: URL,
        mode: AccessSessionMode,
        initialBaseline: AccessBaseline?,
        skipImmediateCheck: Bool
    ) {
        guard !options.demo, let acct = account else { return }
        awaitingInstallAfterCreate = false
        awaitingAccessReturn = true
        activeAccessMode = mode
        activeAccessBaseline = initialBaseline
        installPollTask?.cancel()
        isInstallSheetActive = true
        isPollingInstallations = true
        pendingAccessReturn = nil
        if case .switchFromSession = mode {
            // An open picker sheet stays up under the browser (closing it while the browser presents can stop the
            // browser from appearing on iPhone); the return from GitHub decides whether it stays.
            isSwitchingRepositories = true
        }
        onboardingLog.info("browser opened for access page, private window: \(self.privateBrowser, privacy: .public)")

        webSession.open(url, ephemeral: privateBrowser) { [weak self] callbackURL in
            guard let self else { return }
            onboardingLog.info("browser closed on access page")
            if let callbackURL, !Self.isValidSetupCallbackURL(callbackURL) {
                self.stopAccessPollingFlags()
                self.activeAccessMode = nil
                self.activeAccessBaseline = nil
                if case .initialAfterSignIn = mode {
                    self.isAwaitingInitialGitHubGrant = false
                    self.phase = .needsRepoSelection
                } else if case .switchFromSession = mode {
                    self.isSwitchingRepositories = false
                }
                return
            }
            self.completeAccessSession(callbackURL: callbackURL)
        }

        startAccessPollLoop(account: acct, mode: mode, skipImmediateCheck: skipImmediateCheck)
    }

    private func stopAccessPollingFlags(cancelPollTask: Bool = true) {
        isInstallSheetActive = false
        if cancelPollTask {
            installPollTask?.cancel()
        }
        installPollTask = nil
        isPollingInstallations = false
        awaitingAccessReturn = false
    }

    private func isModeStillRelevant(_ mode: AccessSessionMode) -> Bool {
        switch mode {
        case .initialAfterSignIn:
            return isAwaitingInitialGitHubGrant
        case .chooseNotes:
            return phase == .needsRepoSelection || isPresentingRepoPicker
        case .switchFromSession:
            return isSwitchingRepositories || isPresentingRepoPicker
        }
    }

    private func startAccessPollLoop(account acct: BrainAccount, mode: AccessSessionMode, skipImmediateCheck: Bool) {
        installPollTask?.cancel()
        isPollingInstallations = true
        let interval = sessions.installPollInterval

        installPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var baselineKnownBeforePolls = self.activeAccessBaseline != nil

            if !skipImmediateCheck {
                do {
                    guard self.isModeStillRelevant(mode) else { return }
                    let user = try await acct.discoveryClient().authenticatedUser()
                    guard !Task.isCancelled, self.isModeStillRelevant(mode) else { return }
                    if case let .switchFromSession(_, expectedUserId) = mode,
                       let expectedUserId,
                       user.id != expectedUserId {
                        self.stopAccessPollingFlags()
                        self.isSwitchingRepositories = false
                        self.isPresentingRepoPicker = false
                        self.activeAccessMode = nil
                        self.activeAccessBaseline = nil
                        self.webSession.cancel()
                        if let s = self.session {
                            self.sessionOwnerVerifiedThisLaunch = false
                            await s.engine.stop()
                            self.clearLoadedNoteLists()
                            self.repoIssue = .accountMismatch(login: user.login)
                        }
                        return
                    }
                    self.signedInUser = user

                    let immediateResult = try await acct.discoveryClient().listAccessibleRepositories()
                    guard !Task.isCancelled, self.isModeStillRelevant(mode) else { return }
                    self.lastKnownInstallations = immediateResult.installations
                    self.discoveryState = .loaded(immediateResult)
                    let current = AccessBaseline(immediateResult)
                    if let prev = self.activeAccessBaseline, current != prev {
                        self.stopAccessPollingFlags(cancelPollTask: false)
                        self.activeAccessMode = nil
                        self.activeAccessBaseline = nil
                        self.webSession.cancel()
                        let returnTask = Task<Void, Never> { @MainActor [weak self] in
                            guard let self else { return }
                            await self.applyAccessReturn(
                                result: immediateResult,
                                user: user,
                                mode: mode,
                                didChange: true,
                                baselineKnown: true
                            )
                        }
                        self.discoveryTask?.cancel()
                        self.discoveryTask = returnTask
                        await returnTask.value
                        if self.discoveryTask == returnTask {
                            self.discoveryTask = nil
                        }
                        return
                    } else if self.activeAccessBaseline == nil {
                        self.activeAccessBaseline = current
                        baselineKnownBeforePolls = true
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Leave discoveryState and activeAccessBaseline unchanged so polling will not auto-pick without baseline.
                }
            }

            for _ in 0..<Self.maxInstallPolls {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isModeStillRelevant(mode) else { return }
                let user: GitHubAccount
                let result: DiscoveryResult
                do {
                    user = try await acct.discoveryClient().authenticatedUser()
                    guard !Task.isCancelled, self.isModeStillRelevant(mode) else { return }
                    if case let .switchFromSession(_, expectedUserId) = mode,
                       let expectedUserId,
                       user.id != expectedUserId {
                        self.stopAccessPollingFlags(cancelPollTask: false)
                        self.isSwitchingRepositories = false
                        self.isPresentingRepoPicker = false
                        self.activeAccessMode = nil
                        self.activeAccessBaseline = nil
                        self.webSession.cancel()
                        if let s = self.session {
                            self.sessionOwnerVerifiedThisLaunch = false
                            await s.engine.stop()
                            self.clearLoadedNoteLists()
                            self.repoIssue = .accountMismatch(login: user.login)
                        }
                        return
                    }
                    self.signedInUser = user
                    result = try await acct.discoveryClient().listAccessibleRepositories()
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
                guard !Task.isCancelled, self.isModeStillRelevant(mode) else { return }
                self.lastKnownInstallations = result.installations
                self.discoveryState = .loaded(result)

                let current = AccessBaseline(result)
                if let knownBaseline = self.activeAccessBaseline {
                    if current != knownBaseline {
                        self.stopAccessPollingFlags(cancelPollTask: false)
                        self.activeAccessMode = nil
                        self.activeAccessBaseline = nil
                        self.webSession.cancel()
                        let returnTask = Task<Void, Never> { @MainActor [weak self] in
                            guard let self else { return }
                            await self.applyAccessReturn(
                                result: result,
                                user: user,
                                mode: mode,
                                didChange: true,
                                baselineKnown: baselineKnownBeforePolls
                            )
                        }
                        self.discoveryTask?.cancel()
                        self.discoveryTask = returnTask
                        await returnTask.value
                        if self.discoveryTask == returnTask {
                            self.discoveryTask = nil
                        }
                        return
                    }
                } else {
                    // Initial baseline fetch failed (e.g. opened from .failed while offline): record baseline now
                    // and never auto-pick without a known pre-install baseline.
                    self.activeAccessBaseline = current
                    self.repoSelectionAutoSelect = false
                    if case .chooseNotes = mode, !result.repositories.isEmpty {
                        self.stopAccessPollingFlags(cancelPollTask: false)
                        self.activeAccessMode = nil
                        self.activeAccessBaseline = nil
                        self.webSession.cancel()
                        return
                    }
                }
            }
            self.installPollTask = nil
            self.isPollingInstallations = false
        }
    }

    /// The browser closed, a `brainnotes://setup` return came in, or the app came forward with the browser gone. Runs
    /// once per access session: a second signal for the same session (the browser's close and the app's return to the
    /// foreground both arrive on a Mac) is ignored, so it can't cancel the first look and leave the screen waiting.
    ///
    /// A `brainnotes://setup` URL is only a cue to look again: any local app or page can open a custom scheme, so it
    /// proves nothing. It closes the browser and runs the same recheck (GET /user, then the grant list) with the same
    /// change gating as a browser close or a return to the foreground; it never counts as confirmation by itself.
    private func completeAccessSession(callbackURL: URL?) {
        guard let mode = activeAccessMode else { return }
        let pending = PendingAccessReturn(mode: mode, baseline: activeAccessBaseline)
        stopAccessPollingFlags()
        activeAccessMode = nil
        activeAccessBaseline = nil
        pendingAccessReturn = pending
        if callbackURL != nil {
            webSession.cancel()
        }
        Task { @MainActor [weak self] in
            await self?.finishAccessSession(pending)
        }
    }

    /// Back in front with no browser on screen: finish the access session, or the look at the list that going to the
    /// background cancelled. Returns false when neither is waiting.
    private func resumeAccessReturnOnForeground() -> Bool {
        if activeAccessMode != nil {
            completeAccessSession(callbackURL: nil)
            return true
        }
        if let pending = pendingAccessReturn {
            if discoveryTask == nil {
                Task { @MainActor [weak self] in await self?.finishAccessSession(pending) }
            }
            return true
        }
        return false
    }

    private func finishAccessSession(_ pending: PendingAccessReturn) async {
        await finishAccessSession(mode: pending.mode, baseline: pending.baseline)
    }

    private func finishAccessSession(
        mode: AccessSessionMode,
        baseline: AccessBaseline?
    ) async {
        guard let acct = account else {
            isAwaitingInitialGitHubGrant = false
            isSwitchingRepositories = false
            phase = .needsSignIn
            return
        }
        discoveryTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let user: GitHubAccount
            do {
                // Always recheck the signed-in user; never trust any installation_id query parameter in callbackURL.
                user = try await acct.discoveryClient().authenticatedUser()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch GitHubError.unauthorized {
                switch mode {
                case .initialAfterSignIn:
                    self.isAwaitingInitialGitHubGrant = false
                    self.signedInUser = nil
                    self.discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                    self.phase = .needsRepoSelection
                case .chooseNotes:
                    if self.session == nil { self.signedInUser = nil }
                    self.discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                case .switchFromSession:
                    self.isSwitchingRepositories = false
                    if let s = self.session {
                        self.sessionOwnerVerifiedThisLaunch = false
                        self.accountCheckFailedForNetwork = false
                        await s.engine.stop()
                        self.clearLoadedNoteLists()
                        self.repoIssue = (s.selection?.hasVerifiedOwner == false)
                            ? .unverifiedOwner(slug: s.repo.slug)
                            : .accountCheckFailed(unauthorized: true)
                    }
                }
                return
            } catch {
                switch mode {
                case .initialAfterSignIn:
                    self.isAwaitingInitialGitHubGrant = false
                    self.discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
                    self.phase = .needsRepoSelection
                case .chooseNotes:
                    self.discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
                case .switchFromSession:
                    // Transient error after closing configure sheet: keep current session and local notes untouched.
                    self.isSwitchingRepositories = false
                }
                return
            }

            if case let .switchFromSession(_, expectedUserId) = mode,
               let expectedUserId,
               user.id != expectedUserId {
                self.isSwitchingRepositories = false
                self.isPresentingRepoPicker = false
                if let s = self.session {
                    self.sessionOwnerVerifiedThisLaunch = false
                    await s.engine.stop()
                    self.clearLoadedNoteLists()
                    self.repoIssue = .accountMismatch(login: user.login)
                }
                return
            }
            self.signedInUser = user

            let result: DiscoveryResult
            do {
                result = try await acct.discoveryClient().listAccessibleRepositories()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch GitHubError.unauthorized {
                switch mode {
                case .initialAfterSignIn:
                    self.isAwaitingInitialGitHubGrant = false
                    self.signedInUser = nil
                    self.discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                    self.phase = .needsRepoSelection
                case .chooseNotes:
                    if self.session == nil { self.signedInUser = nil }
                    self.discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                case .switchFromSession:
                    self.isSwitchingRepositories = false
                }
                return
            } catch {
                switch mode {
                case .initialAfterSignIn:
                    self.isAwaitingInitialGitHubGrant = false
                    self.discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
                    self.phase = .needsRepoSelection
                case .chooseNotes:
                    self.discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
                case .switchFromSession:
                    self.isSwitchingRepositories = false
                }
                return
            }

            self.lastKnownInstallations = result.installations
            self.discoveryState = .loaded(result)
            self.logDiscovery(result)
            let didChange = baseline.map { AccessBaseline(result) != $0 } ?? false
            await self.applyAccessReturn(
                result: result,
                user: user,
                mode: mode,
                didChange: didChange,
                baselineKnown: baseline != nil
            )
        }
        discoveryTask = task
        await task.value
        if discoveryTask == task {
            discoveryTask = nil
        }
        // Going to the background cancels this look; the next return to the foreground runs it again.
        if !task.isCancelled {
            pendingAccessReturn = nil
        }
    }

    private func applyAccessReturn(
        result: DiscoveryResult,
        user: GitHubAccount,
        mode: AccessSessionMode,
        didChange: Bool,
        baselineKnown: Bool
    ) async {
        if case .initialAfterSignIn = mode, !isAwaitingInitialGitHubGrant { return }
        signedInUser = user
        switch mode {
        case .initialAfterSignIn:
            isAwaitingInitialGitHubGrant = false
            initialGrantBaseline = nil
            if let single = Self.singleAutoConnectableRepo(in: result) {
                await selectRepository(single, fromSettingsSwitch: false)
                if phase != .ready {
                    repoSelectionAutoSelect = false
                    phase = .needsRepoSelection
                }
            } else {
                // Multiple private repos, "All repositories", public repos, 0 repos, or truncated list:
                // show the picker (plus "Create a new private brain"), and allow auto-connect if the user
                // reopens GitHub during initial onboarding and narrows the grant to a single private repo.
                repoSelectionAutoSelect = true
                phase = .needsRepoSelection
            }

        case let .chooseNotes(autoSelectSinglePrivate):
            guard autoSelectSinglePrivate else { return }
            guard baselineKnown else {
                repoSelectionAutoSelect = false
                return
            }
            // Auto-connect only when the grant changed while GitHub was open; a setup URL alone never stands in for that.
            if let single = Self.singleAutoConnectableRepo(in: result), didChange {
                await selectRepository(single, fromSettingsSwitch: session != nil)
            }

        case let .switchFromSession(currentRepoId, _):
            isSwitchingRepositories = false
            if let single = Self.singleAutoConnectableRepo(in: result) {
                if single.repoId == currentRepoId {
                    isPresentingRepoPicker = false
                    if repoIssue != nil {
                        await retryCurrentRepository()
                    }
                } else {
                    await selectRepository(single, fromSettingsSwitch: true)
                }
            } else if result.repositories.isEmpty, !didChange {
                // User cancelled on GitHub while 0 repos were granted: keep current local notes untouched.
                isPresentingRepoPicker = false
            } else {
                // Multiple private repos, "All repositories", public repos, or truncated list: show picker sheet
                // without wiping current local notes until a new private repo is picked and verified.
                repoSelectionAutoSelect = false
                isPresentingRepoPicker = true
            }
        }
    }

    func cancelRepoSwitch() {
        stopAccessPollingFlags()
        discoveryTask?.cancel()
        discoveryTask = nil
        isSwitchingRepositories = false
        isPresentingRepoPicker = false
        awaitingInstallAfterCreate = false
        activeAccessMode = nil
        activeAccessBaseline = nil
        pendingAccessReturn = nil
        webSession.cancel()
    }

    /// Guidance flow for creating a new private notes repository on GitHub without asking for extra account-wide
    /// permissions: opens GitHub's pre-filled "New repository" page (`visibility=private`) in the in-app browser,
    /// then guides the user to the "Choose notes on GitHub" step.
    func openCreateBrain() {
        isInstallSheetActive = false
        awaitingInstallAfterCreate = true
        guard !options.demo else { return }
        awaitingAccessReturn = true
        onboardingLog.info("browser opened for create notes page, private window: \(self.privateBrowser, privacy: .public)")
        webSession.open(AppConfig.createBrainURL, ephemeral: privateBrowser) { [weak self] _ in
            // Back from GitHub's "new repository" page: straight to the access step, which carries the hint.
            guard let self else { return }
            onboardingLog.info("browser closed on create notes page")
            if self.phase == .needsRepoSelection || self.isPresentingRepoPicker {
                Task { @MainActor [weak self] in await self?.retryDiscovery() }
            }
        }
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

    /// Optional custom URL scheme return (`brainnotes://setup`) accepted ONLY while an access/configure sheet is active,
    /// and then only as a cue to recheck: it closes the browser and takes the same verified-grant path as a browser close.
    /// Query items such as `installation_id` are untrusted and ignored; the signed-in user and installations are rechecked.
    func handleOpenURL(_ url: URL) {
        guard isInstallSheetActive,
              (isAwaitingInitialGitHubGrant || phase == .needsRepoSelection || isSwitchingRepositories || isPresentingRepoPicker),
              Self.isValidSetupCallbackURL(url) else {
            return
        }
        completeAccessSession(callbackURL: url)
    }

    /// Selects a discovered private repository (single-flight), verifies it against `/user` and `/user/installations`
    /// BEFORE wiping any previously open session, persists the owner-bound selection, and starts sync.
    func selectRepository(_ repo: DiscoveredRepo, fromSettingsSwitch: Bool = false) async {
        guard !isSelectingRepository else { return }
        guard repo.isPrivate else {
            discoveryState = .failed(RepoTarget.publicRepoMessage)
            if fromSettingsSwitch || session != nil {
                isPresentingRepoPicker = true
            }
            return
        }
        if options.demo {
            isPresentingRepoPicker = false
            phase = .ready
            return
        }
        guard let acct = account else {
            phase = .needsSignIn
            return
        }
        isSelectingRepository = true
        defer { isSelectingRepository = false }

        let switchingExisting = fromSettingsSwitch || session != nil
        if let prev = session, prev.repo.repoId == repo.repoId, repoIssue == nil {
            stopAccessPollingFlags()
            isSwitchingRepositories = false
            isPresentingRepoPicker = false
            activeAccessMode = nil
            activeAccessBaseline = nil
            webSession.cancel()
            router?.reset()
            return
        }

        let user: GitHubAccount
        if let previous = session {
            do {
                let fetched = try await acct.discoveryClient().authenticatedUser()
                if let expectedUserId = previous.selection?.userId, fetched.id != expectedUserId {
                    stopAccessPollingFlags()
                    isSwitchingRepositories = false
                    isPresentingRepoPicker = false
                    activeAccessMode = nil
                    activeAccessBaseline = nil
                    webSession.cancel()
                    sessionOwnerVerifiedThisLaunch = false
                    await previous.engine.stop()
                    clearLoadedNoteLists()
                    repoIssue = .accountMismatch(login: fetched.login)
                    return
                }
                signedInUser = fetched
                user = fetched
            } catch GitHubError.unauthorized {
                discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                isPresentingRepoPicker = true
                return
            } catch {
                discoveryState = .failed("Couldn’t confirm your GitHub account. Check your connection and try again.")
                isPresentingRepoPicker = true
                return
            }
        } else if let knownUser = signedInUser {
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
            onboardingLog.error("repository selection failed: could not build selection")
            discoveryState = .failed("That notes repository could not be opened.")
            if switchingExisting { isPresentingRepoPicker = true }
            return
        }

        onboardingLog.info("repository selected")
        stopAccessPollingFlags()
        activeAccessMode = nil
        activeAccessBaseline = nil
        webSession.cancel()

        if let previous = session {
            // Verify the new selection on GitHub BEFORE dropping or wiping the previous repository's local copy.
            let verifiedSelection: SelectedRepo
            do {
                verifiedSelection = try await acct.discoveryClient().verifySelection(selection)
            } catch SelectionVerificationError.publicRepo, RepoTarget.GuardError.publicRepo {
                onboardingLog.error("repository selection failed: public")
                discoveryState = .failed(RepoTarget.publicRepoMessage)
                isPresentingRepoPicker = true
                return
            } catch SelectionVerificationError.truncated {
                onboardingLog.error("repository selection failed: too many repositories")
                discoveryState = .failed(DiscoveryResult.truncatedMessage)
                isPresentingRepoPicker = true
                return
            } catch SelectionVerificationError.notListed {
                onboardingLog.error("repository selection failed: not listed")
                discoveryState = .failed("GitHub didn’t list \(repo.slug) under your approved notes. Try choosing it again.")
                isPresentingRepoPicker = true
                return
            } catch {
                onboardingLog.error("repository selection failed: could not verify")
                discoveryState = .failed("Couldn’t open \(repo.slug) right now. Check your connection and try again.")
                isPresentingRepoPicker = true
                return
            }

            await openEditor?.saveNow(self)
            dropSession()
            do {
                try await previous.wipeForRepoSwitch()
            } catch {
                log.error("previous session wipe after verify failed")
                phase = .failed(Self.repoSwitchWipeFailedMessage)
                return
            }

            do {
                try acct.selectionStore.save(verifiedSelection)
                let opened = try sessions.live(acct, verifiedSelection)
                await opened.engine.markSelectionVerified()
                session = opened
                sessionOwnerVerifiedThisLaunch = true
                accountCheckFailedForNetwork = false
                repoIssue = nil
                isPresentingRepoPicker = false
                isSwitchingRepositories = false
                privateBrowser = false
                snapshot = SyncSnapshot()
                snapshot.state = .checking
                listen(to: opened)
                await reloadLists()
                router?.reset()
                phase = .ready
                await opened.engine.start()
            } catch {
                onboardingLog.error("repository selection failed: could not open verified session")
                phase = .failed("Could not open the local data.")
            }
            return
        }

        if (try? acct.selectionStore.load()) == nil {
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
            isPresentingRepoPicker = false
            isSwitchingRepositories = false
            privateBrowser = false
            snapshot = SyncSnapshot()
            snapshot.state = .checking
            listen(to: opened)
            await reloadLists()
            // Straight into the notes; the first sync runs behind them (home list and status show its progress).
            // No ready screen comes after this, so first run ends here.
            defaults.set(true, forKey: Self.onboardedKey)
            onboardingLog.info("notes opened, first sync in the background")
            phase = .ready
            await opened.engine.start()
        } catch SelectionVerificationError.publicRepo, RepoTarget.GuardError.publicRepo {
            onboardingLog.error("repository selection failed: public")
            discoveryState = .failed(RepoTarget.publicRepoMessage)
        } catch SelectionVerificationError.truncated {
            onboardingLog.error("repository selection failed: too many repositories")
            discoveryState = .failed(DiscoveryResult.truncatedMessage)
        } catch SelectionVerificationError.notListed {
            onboardingLog.error("repository selection failed: not listed")
            discoveryState = .failed("GitHub didn’t list \(repo.slug) under your approved notes. Try choosing it again.")
        } catch {
            onboardingLog.error("repository selection failed: could not open")
            discoveryState = .failed("Couldn’t open \(repo.slug) right now. Check your connection and try again.")
        }
    }

    // MARK: engine events

    private func listen(to s: BrainSession) {
        isUserPaused = s.isUserPaused
        listener?.cancel()
        listener = Task { [weak self] in
            for await event in s.engine.events {
                // A cancelled stream still hands over what it had buffered, and those events belong to a
                // session that is gone.
                guard !Task.isCancelled, let self, self.session === s else { return }
                switch event {
                case let .snapshot(snap):
                    self.snapshot = snap
                    if case .paused(.user) = snap.state {
                        self.isUserPaused = true
                    } else {
                        self.isUserPaused = s.isUserPaused
                    }
                    if !s.isDemo {
                        switch snap.state {
                        case let .accountMismatch(login):
                            self.sessionOwnerVerifiedThisLaunch = false
                            self.accountCheckFailedForNetwork = false
                            self.clearLoadedNoteLists()
                            self.repoIssue = .accountMismatch(login: login)
                            Task { await s.engine.stop() }
                        case let .accountCheckFailed(unauthorized):
                            self.sessionOwnerVerifiedThisLaunch = false
                            self.accountCheckFailedForNetwork = !unauthorized
                            self.clearLoadedNoteLists()
                            self.repoIssue = (s.selection?.hasVerifiedOwner == false)
                                ? .unverifiedOwner(slug: s.repo.slug)
                                : .accountCheckFailed(unauthorized: unauthorized)
                            Task { await s.engine.stop() }
                        case .accessLost:
                            self.repoIssue = .notListed(slug: s.repo.slug)
                            Task { await s.engine.stop() }
                        case .installationTruncated:
                            self.repoIssue = .truncated(slug: s.repo.slug)
                            Task { await s.engine.stop() }
                        case .publicRepo:
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
        let pinned = await s.store.index.pinnedNotes()
        let store = s.store
        let journal = s.store.journal
        let files = s.store.files
        let prefsStore = FileListPreferencesStore(store: s.store)
        let (noteStatuses, emptyFolders, placeholderFolders, loadedPrefs) = await Task.detached {
            (journal.statuses(), files.emptyFolders(), store.activePlaceholderFolders(), prefsStore.load())
        }.value
        // The session can change during those waits: sample notes must not land in the live lists, or the reverse.
        guard session === s else { return }
        folderTree = FolderNode.tree(paths: paths, emptyFolders: emptyFolders + placeholderFolders)
        folders = folderTree.filter { !PathPolicy.isInbox($0.name) }
        rootNotes = root
        pinnedNotes = pinned
        inboxCount = paths.filter(PathPolicy.isInInbox).count
        statuses = noteStatuses
        listPreferences = loadedPrefs
        revision += 1
    }

    func updateListPreferences(_ change: (inout ListPreferences) -> Void) {
        var next = listPreferences
        change(&next)
        guard next != listPreferences else { return }
        listPreferences = next
        guard let s = session else { return }
        FileListPreferencesStore(store: s.store).save(next)
    }

    func status(of path: String) -> NoteSyncStatus { statuses[PathKey(path)] ?? .synced }

    // MARK: lifecycle

    /// Whether returning to the app while choosing notes should look at the list again: it is still loading, could not
    /// be loaded, holds no notes yet, or a GitHub page for the notes was opened and has not been followed by a look.
    /// A picker the person is reading is left alone.
    private var needsAccessRecheckOnForeground: Bool {
        if awaitingAccessReturn { return true }
        switch discoveryState {
        case .loading, .failed:
            return true
        case let .loaded(result):
            return result.repositories.isEmpty
        }
    }

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
            } else if phase == .active {
                if isAwaitingInitialGitHubGrant {
                    onboardingLog.info("foreground: checking initial GitHub grant")
                    if webSession.isPresenting, let acct = account, let mode = activeAccessMode {
                        isInstallSheetActive = true
                        startAccessPollLoop(account: acct, mode: mode, skipImmediateCheck: false)
                    } else if !resumeAccessReturnOnForeground(), discoveryTask == nil {
                        // Nothing is left to finish: the list screen, never a screen that keeps waiting.
                        isAwaitingInitialGitHubGrant = false
                        self.phase = .needsRepoSelection
                        Task { await retryDiscovery() }
                    }
                } else if self.phase == .needsRepoSelection,
                          discoveryTask == nil,
                          needsAccessRecheckOnForeground {
                    onboardingLog.info("foreground: checking access again")
                    if webSession.isPresenting, let acct = account, let mode = activeAccessMode {
                        isInstallSheetActive = true
                        startAccessPollLoop(account: acct, mode: mode, skipImmediateCheck: false)
                    } else if !resumeAccessReturnOnForeground() {
                        Task { await retryDiscovery() }
                    }
                }
            }
            return
        }
        switch phase {
        case .active:
            if isSwitchingRepositories {
                onboardingLog.info("foreground: checking repository switch on GitHub")
                if webSession.isPresenting, let acct = account, let mode = activeAccessMode {
                    isInstallSheetActive = true
                    startAccessPollLoop(account: acct, mode: mode, skipImmediateCheck: false)
                } else if !resumeAccessReturnOnForeground(), discoveryTask == nil {
                    // Nothing is left to finish: back to the notes as they were.
                    isSwitchingRepositories = false
                }
                return
            }
            if isPresentingRepoPicker, discoveryTask == nil, needsAccessRecheckOnForeground {
                Task { await retryDiscovery() }
            }
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
    func editorAppeared(_ editor: NoteEditorModel) {
        openEditor = editor
        activeEditorPath = editor.path
    }

    func editorDisappeared(_ editor: NoteEditorModel) {
        if openEditor === editor {
            openEditor = nil
            activeEditorPath = nil
        }
    }

    // MARK: selection (Mac)

    func isNoteSelected(_ path: String, detailRoute: Route?) -> Bool {
        if !selectedNotePaths.isEmpty {
            return selectedNotePaths.contains { sameBytes($0, path) }
        }
        if case let .note(openPath)? = detailRoute, sameBytes(openPath, path) {
            return true
        }
        if let active = activeEditorPath, sameBytes(active, path) {
            return true
        }
        return false
    }

    func clearNoteSelection() {
        selectedNotePaths = []
        selectionAnchor = nil
    }

    func selectSingleNote(_ path: String, router: Router) {
        selectedNotePaths = [path]
        selectionAnchor = path
        activePane = .list
        router.open(.note(path))
    }

    func toggleNoteSelection(_ path: String, orderedPaths: [String], router: Router) {
        activePane = .list
        if selectedNotePaths.isEmpty {
            if case let .note(openPath)? = router.detail, orderedPaths.contains(where: { sameBytes($0, openPath) }) {
                selectedNotePaths.insert(openPath)
            } else if let active = activeEditorPath, orderedPaths.contains(where: { sameBytes($0, active) }) {
                selectedNotePaths.insert(active)
            }
        }
        if let match = selectedNotePaths.first(where: { sameBytes($0, path) }) {
            selectedNotePaths.remove(match)
        } else {
            selectedNotePaths.insert(path)
            selectionAnchor = path
        }
        syncDetailForNoteSelection(router: router)
    }

    func selectNoteRange(to path: String, orderedPaths: [String], additive: Bool, router: Router) {
        activePane = .list
        let fallbackAnchor: String? = {
            if let anchor = selectionAnchor, orderedPaths.contains(where: { sameBytes($0, anchor) }) { return anchor }
            if case let .note(openPath)? = router.detail, orderedPaths.contains(where: { sameBytes($0, openPath) }) { return openPath }
            if let active = activeEditorPath, orderedPaths.contains(where: { sameBytes($0, active) }) { return active }
            return nil
        }()
        if let anchor = fallbackAnchor,
           let startIdx = orderedPaths.firstIndex(where: { sameBytes($0, anchor) }),
           let endIdx = orderedPaths.firstIndex(where: { sameBytes($0, path) }) {
            let slice = orderedPaths[min(startIdx, endIdx)...max(startIdx, endIdx)]
            if additive {
                selectedNotePaths.formUnion(slice)
            } else {
                selectedNotePaths = Set(slice)
            }
        } else {
            selectedNotePaths = [path]
            selectionAnchor = path
        }
        syncDetailForNoteSelection(router: router)
    }

    func selectAllNotes(_ orderedPaths: [String], router: Router) {
        guard !orderedPaths.isEmpty else { return }
        activePane = .list
        selectedNotePaths = Set(orderedPaths)
        syncDetailForNoteSelection(router: router)
    }

    private func syncDetailForNoteSelection(router: Router) {
        if selectedNotePaths.count == 1, let single = selectedNotePaths.first {
            router.open(.note(single))
        } else if selectedNotePaths.isEmpty {
            router.detail = nil
        }
    }

    // MARK: actions

    func noteSaved() async {
        activeEditorPath = openEditor?.path
        guard let s = session else { return }
        await s.engine.noteSaved()
        await reloadLists()
    }

    func isPinned(_ path: String) -> Bool {
        if let editor = openEditor, let openPath = editor.path, sameBytes(openPath, path) {
            return editor.isPinned
        }
        return pinnedNotes.contains { sameBytes($0.path, path) }
    }

    func togglePin(path: String) async {
        await setPinned(!isPinned(path), paths: [path])
    }

    func setPinned(_ pinned: Bool, paths: [String]) async {
        let unique = Self.uniquePaths(paths)
        guard !unique.isEmpty, let s = session else { return }
        for path in unique {
            if let editor = openEditor, let openPath = editor.path, sameBytes(openPath, path) {
                if editor.isPinned != pinned {
                    await editor.togglePinned(app: self)
                }
                continue
            }
            do {
                try await Task.detached {
                    guard let current = try s.store.read(path) else { return }
                    let updated = NoteText.settingPinned(pinned, in: current)
                    _ = try s.store.save(path: path, text: updated, editingFrom: current)
                }.value
            } catch {
                log.error("pin toggle failed")
            }
        }
        await noteSaved()
        syncImmediatelyIfReady()
    }

    func duplicateNotes(paths: [String]) async -> [String] {
        await openEditor?.saveNow(self)
        let unique = Self.uniquePaths(paths)
        guard !unique.isEmpty, let s = session else { return [] }
        let created: [String] = await Task.detached {
            var out: [String] = []
            for p in unique {
                if let copy = try? s.store.duplicateNote(p) {
                    out.append(copy)
                }
            }
            return out
        }.value
        if !created.isEmpty {
            await noteSaved()
            syncImmediatelyIfReady()
        }
        return created
    }

    func moveNotes(paths: [String], toFolder folder: String) async -> [String] {
        let unique = Self.uniquePaths(paths)
        var out: [String] = []
        for path in unique {
            if let movedPath = await moveNote(path: path, toFolder: folder) {
                out.append(movedPath)
            }
        }
        return out
    }

    func cleanShareItems(for paths: [String]) async -> [String] {
        let unique = Self.uniquePaths(paths)
        guard !unique.isEmpty, let s = session else { return [] }
        var items: [String] = []
        for path in unique {
            if let editor = openEditor, let openPath = editor.path, sameBytes(openPath, path) {
                items.append(editor.cleanShareText)
                continue
            }
            let text: String? = await Task.detached {
                guard let raw = try? s.store.read(path) else { return nil }
                let cleaned = NoteText.cleanShareText(raw)
                return cleaned.isEmpty ? NoteText.title(of: raw, path: path) : cleaned
            }.value
            if let text {
                items.append(text)
            }
        }
        return items
    }

    func leftNote() {
        guard let s = session, repoIssue == nil, s.isDemo || sessionOwnerVerifiedThisLaunch else { return }
        Task { await s.engine.sync(.background) }
    }

    /// Triggers an immediate background push when the session engine is active so discrete structural and metadata
    /// actions (creating/renaming/moving/deleting folders or notes, pinning, duplicating, tapping Done) appear on GitHub
    /// right away without waiting for the prose-typing idle debounce.
    func syncImmediatelyIfReady() {
        guard let s = session, repoIssue == nil, s.isDemo || sessionOwnerVerifiedThisLaunch else { return }
        Task { @MainActor [weak self] in
            guard await s.engine.isStarted else { return }
            await s.engine.sync(.background)
            if self?.session === s {
                await self?.reloadLists()
            }
        }
    }

    /// New Folder or Subfolder: created on disk with `<folder>/_folder.md` and pushed directly to GitHub.
    func createFolder(named name: String, in parent: String) async -> Result<String, NoteStore.FolderProblem> {
        guard let s = session else { return .failure(.notAllowed) }
        let result: Result<String, NoteStore.FolderProblem> = await Task.detached {
            do {
                return .success(try s.store.createSyncedFolder(named: name, in: parent))
            } catch let problem as NoteStore.FolderProblem {
                return .failure(problem)
            } catch {
                return .failure(.notAllowed)
            }
        }.value
        if case .success = result {
            await noteSaved()
            syncImmediatelyIfReady()
        } else {
            await reloadLists()
        }
        return result
    }

    func renameFolder(path folder: String, to newName: String) async -> Result<String, NoteStore.FolderProblem> {
        await openEditor?.saveNow(self)
        guard let s = session else { return .failure(.notAllowed) }
        if let mover = s.mover, !s.isDemo, isDeviceOnline, repoIssue == nil {
            await s.engine.waitUntilIdle()
            if let result = try? await mover.renameFolder(folder, to: newName),
               let renamed = result.folder?.to {
                updateRoutesAfterFolderRelocation(from: folder, to: renamed)
                await noteSaved()
                return .success(renamed)
            }
        }
        let localResult: Result<String, NoteStore.FolderProblem> = await Task.detached {
            do {
                return .success(try s.store.renameFolderLocally(folder, to: newName))
            } catch let problem as NoteStore.FolderProblem {
                return .failure(problem)
            } catch {
                return .failure(.notAllowed)
            }
        }.value
        if case let .success(renamed) = localResult {
            updateRoutesAfterFolderRelocation(from: folder, to: renamed)
            await noteSaved()
            syncImmediatelyIfReady()
        }
        return localResult
    }

    func moveFolder(path folder: String, into parent: String) async -> String? {
        await openEditor?.saveNow(self)
        guard let s = session else { return nil }
        let cleanParent = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let mover = s.mover, !s.isDemo, isDeviceOnline, repoIssue == nil {
            await s.engine.waitUntilIdle()
            if let result = try? await mover.moveFolder(folder, into: cleanParent),
               let relocated = result.folder?.to {
                updateRoutesAfterFolderRelocation(from: folder, to: relocated)
                await noteSaved()
                return relocated
            }
        }
        let localMoved: String? = await Task.detached {
            try? s.store.moveFolderLocally(folder, into: cleanParent)
        }.value
        if let relocated = localMoved {
            updateRoutesAfterFolderRelocation(from: folder, to: relocated)
            await noteSaved()
            syncImmediatelyIfReady()
        }
        return localMoved
    }

    private func updateRoutesAfterFolderRelocation(from oldFolder: String, to newFolder: String) {
        guard !sameBytes(oldFolder, newFolder) else { return }
        let prefix = oldFolder + "/"
        if let r = router {
            if case let .folder(current)? = r.content {
                if sameBytes(current, oldFolder) {
                    r.content = .folder(newFolder)
                } else if current.hasPrefix(prefix) {
                    r.content = .folder(newFolder + String(current.dropFirst(oldFolder.count)))
                }
            }
            if case let .note(notePath)? = r.detail, notePath.hasPrefix(prefix) {
                let rebased = newFolder + String(notePath.dropFirst(oldFolder.count))
                r.detail = .note(rebased)
                openEditor?.moved(to: rebased)
                activeEditorPath = rebased
            }
        }
        selectedNotePaths = Set(selectedNotePaths.map { p in
            p.hasPrefix(prefix) ? (newFolder + String(p.dropFirst(oldFolder.count))) : p
        })
    }

    /// Moves a note to `folder` (`""` for root `Notes`, `_inbox` for `Inbox`, or a folder path).
    /// Uses `NoteMover` for an atomic GitHub rename commit when online and synced, falling back to `NoteStore.moveNoteLocally`
    /// when offline, in demo mode, or when the note has unsynced local changes.
    func moveNote(path: String, toFolder folder: String) async -> String? {
        await openEditor?.saveNow(self)
        guard let s = session else { return nil }
        let currentPath = (openEditor?.path.map { sameBytes($0, path) } == true ? openEditor?.path : nil) ?? path
        let cleanDest = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if sameBytes(SearchIndex.folder(of: currentPath), cleanDest) { return currentPath }

        var newPath: String?
        var committedViaMover = false
        if let mover = s.mover, !s.isDemo, isDeviceOnline, repoIssue == nil, !PathPolicy.isInbox(cleanDest),
           s.store.status(of: currentPath) == .synced {
            await s.engine.waitUntilIdle()
            if let result = try? await mover.moveNote(currentPath, toFolder: cleanDest),
               let landed = result.files.first?.to {
                newPath = landed
                committedViaMover = true
            }
        }
        if newPath == nil {
            newPath = await Task.detached {
                try? s.store.moveNoteLocally(currentPath, toFolder: cleanDest)
            }.value
        }
        guard let finalPath = newPath else { return nil }
        moved = (from: currentPath, to: finalPath)
        changeTick += 1
        await noteSaved()
        if !committedViaMover {
            syncImmediatelyIfReady()
        }
        return finalPath
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
        syncImmediatelyIfReady()
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

    /// Folder delete: removes every note under the folder (and subfolders) with Undo, or removes an empty folder immediately.
    func requestDeleteFolder(path folder: String) async {
        guard let s = session else { return }
        let paths = await notePaths(underFolder: folder)
        let prefix = folder + "/"
        if let r = router {
            if case let .folder(current)? = r.content, sameBytes(current, folder) || current.hasPrefix(prefix) {
                r.content = nil
                r.detail = nil
            }
        }
        selectedNotePaths = selectedNotePaths.filter { !$0.hasPrefix(prefix) }
        if !paths.isEmpty {
            await requestDelete(paths: paths, intensity: .full)
        }
        await Task.detached {
            try? s.store.removeEmptyOrPlaceholderFolder(folder)
        }.value
        await noteSaved()
        if paths.isEmpty {
            syncImmediatelyIfReady()
        }
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
        syncImmediatelyIfReady()
    }

    func dismissBlackHoleUndo() {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        blackHole = nil
        blackHoleSnapshots = []
        syncImmediatelyIfReady()
    }

    private func scheduleUndoDismiss() {
        undoDismissTask?.cancel()
        undoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(BlackHoleDeleteLogic.undoSeconds))
            guard !Task.isCancelled, let self else { return }
            if case .undo = self.blackHole {
                self.blackHole = nil
                self.blackHoleSnapshots = []
                self.syncImmediatelyIfReady()
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
            await s.engine.sync(.background)
        }
    }

    func freshSync() async {
        guard let s = session, s.isDemo || (sessionOwnerVerifiedThisLaunch && repoIssue == nil) else { return }
        await s.engine.freshSync()
        await reloadLists()
    }

    /// The Settings switch: its state changes in the same frame as the tap (no flick back while the engine is told),
    /// then the engine follows. A resume that `setPaused` refuses puts the switch back.
    func requestPaused(_ paused: Bool) {
        guard session != nil else { return }
        isUserPaused = paused
        Task { await setPaused(paused) }
    }

    func setPaused(_ paused: Bool) async {
        guard let s = session else { return }
        if !paused, !s.isDemo, (!sessionOwnerVerifiedThisLaunch || repoIssue != nil) {
            isUserPaused = s.isUserPaused
            return
        }
        isUserPaused = paused
        await s.engine.setPaused(paused)
        isUserPaused = s.isUserPaused
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

    static let unlinkedNotesMessage = "The notes on this device aren’t tied to a GitHub account yet. Choose Sign out and wipe, then connect again. Your notes on GitHub aren’t touched."
    static let accountCheckCouldNotRunMessage = "We couldn’t check which GitHub account you used. Check your connection and try again."

    /// Records why a sign-in was not accepted, where the person will see it, and says so to the caller.
    private func refuseSignIn(_ message: String, differentAccount: Bool = false) -> SignInOutcome {
        reSignInError = message
        return .refused(message, differentAccount: differentAccount)
    }

    /// An approved sign-in. `verifiedUser` is the account `GET /user` already named for exactly this `pair` (the
    /// sign-in model asked right after approval): nothing is asked twice. Without it, a
    /// re-sign-in asks here, before anything is saved.
    ///
    /// Every way out leaves something to read: `reSignInError`, `phase == .failed`, or the next screen. The result
    /// says which kind it was.
    @discardableResult
    func signedIn(pair: TokenPair, verifiedUser: GitHubAccount? = nil) async -> SignInOutcome {
        // A demo or sample session never accepts a real sign-in.
        if options.demo || sampleMode || session?.isDemo == true {
            onboardingLog.info("signedIn: refused, sample notes in use")
            return refuseSignIn("You’re using sample notes. Leave them from Settings, then connect GitHub.")
        }
        guard let acct = account else {
            onboardingLog.error("signedIn: refused, no account")
            showSignIn = false
            let message = "Brain Notes couldn’t finish connecting. Close and reopen the app, then try again."
            phase = .failed(message)
            return .refused(message, differentAccount: false)
        }

        let storedSelection = session?.selection ?? (try? acct.selectionStore.load())
        if session != nil || storedSelection != nil {
            onboardingLog.info("signedIn: branch re-sign-in with notes on this device")
            guard let existingSelection = storedSelection else {
                onboardingLog.error("signedIn: refused, session without a selection")
                return refuseSignIn(Self.unlinkedNotesMessage)
            }
            // BN-02 / NB-04: Verify the candidate token against GET /user BEFORE saving to the Keychain or starting sync,
            // and capture the latest TokenPair from the candidate store in case refresh rotated a single-use refresh token.
            // A `verifiedUser` from the confirmation screen has had that check, for this very pair.
            let candidateUser: GitHubAccount
            let verifiedPair: TokenPair
            if let verifiedUser {
                (candidateUser, verifiedPair) = (verifiedUser, pair)
            } else {
                do {
                    (candidateUser, verifiedPair) = try await acct.verifyCandidateToken(pair)
                } catch {
                    onboardingLog.error("signedIn: refused, could not check the account")
                    return refuseSignIn(Self.accountCheckCouldNotRunMessage)
                }
            }
            guard let expectedUserId = existingSelection.userId else {
                onboardingLog.error("signedIn: refused, notes not tied to an account")
                return refuseSignIn(Self.unlinkedNotesMessage)
            }
            guard candidateUser.id == expectedUserId else {
                onboardingLog.error("signedIn: refused, different account")
                return refuseSignIn(Self.accountMismatchMessage(login: candidateUser.login), differentAccount: true)
            }

            let refreshedSelection = (try? existingSelection.withAccount(candidateUser)) ?? existingSelection
            do {
                try await acct.saveTokens(verifiedPair)
                try? acct.selectionStore.save(refreshedSelection)
            } catch {
                onboardingLog.error("signedIn: could not store the sign-in")
                showSignIn = false
                let message = "Could not store the sign-in in the Keychain."
                phase = .failed(message)
                return .refused(message, differentAccount: false)
            }
            showSignIn = false
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
                    onboardingLog.error("signedIn: could not open the local data")
                    let message = "Could not open the local data."
                    phase = .failed(message)
                    return .refused(message, differentAccount: false)
                }
            }
            return .connected
        }

        onboardingLog.info("signedIn: branch first-time sign-in")
        firstSignInGeneration += 1
        let firstRun = firstSignInGeneration
        firstSignInInFlight = true
        defer {
            if firstRun == firstSignInGeneration { firstSignInInFlight = false }
        }
        guard let base = try? sessions.baseFolder() else {
            onboardingLog.error("signedIn: could not open the local data")
            showSignIn = false
            let message = "Could not open the local data."
            phase = .failed(message)
            return .refused(message, differentAccount: false)
        }
        acct.selectionStore.clear()
        do {
            try await wipeUnboundBrainFolder(baseFolder: base)
        } catch {
            onboardingLog.error("signedIn: could not clear leftover local data")
            showSignIn = false
            phase = .failed(Self.repoSwitchWipeFailedMessage)
            return .refused(Self.repoSwitchWipeFailedMessage, differentAccount: false)
        }
        guard firstRun == firstSignInGeneration else { return .cancelled }

        reSignInError = nil
        signedInUser = nil
        do {
            try await acct.saveTokens(pair)
        } catch {
            onboardingLog.error("signedIn: could not store the sign-in")
            showSignIn = false
            let message = "Could not store the sign-in in the Keychain."
            phase = .failed(message)
            return .refused(message, differentAccount: false)
        }
        guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
        showSignIn = false
        // Check the signed-in account and current installations immediately, then open GitHub's install/configure page
        // right away without landing on an in-app Choose notes screen first or auto-picking an ungranted repository.
        isAwaitingInitialGitHubGrant = true
        discoveryState = .loading

        let user: GitHubAccount
        if let verifiedUser {
            signedInUser = verifiedUser
            user = verifiedUser
        } else {
            do {
                let fetched = try await acct.discoveryClient().authenticatedUser()
                guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
                signedInUser = fetched
                user = fetched
            } catch GitHubError.unauthorized {
                guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
                onboardingLog.error("signedIn: initial account check unauthorized")
                isAwaitingInitialGitHubGrant = false
                signedInUser = nil
                discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
                phase = .needsRepoSelection
                return .connected
            } catch {
                guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
                onboardingLog.error("signedIn: initial account check failed")
                isAwaitingInitialGitHubGrant = false
                repoSelectionAutoSelect = true
                signedInUser = nil
                discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
                phase = .needsRepoSelection
                return .connected
            }
        }

        let initialResult: DiscoveryResult
        do {
            initialResult = try await acct.discoveryClient().listAccessibleRepositories()
        } catch GitHubError.unauthorized {
            guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
            onboardingLog.error("signedIn: initial installation check unauthorized")
            isAwaitingInitialGitHubGrant = false
            signedInUser = nil
            discoveryState = .failed("GitHub didn’t accept this sign-in. Sign out and connect again.")
            phase = .needsRepoSelection
            return .connected
        } catch {
            guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
            onboardingLog.error("signedIn: initial installation check failed")
            isAwaitingInitialGitHubGrant = false
            repoSelectionAutoSelect = true
            discoveryState = .failed("Couldn’t reach GitHub to load your notes list. Check your connection and try again.")
            phase = .needsRepoSelection
            return .connected
        }

        guard firstRun == firstSignInGeneration else { return await forgetCancelledFirstSignIn(acct) }
        lastKnownInstallations = initialResult.installations
        discoveryState = .loaded(initialResult)
        logDiscovery(initialResult)

        guard let accessURL = try? acct.config.accessManagementURL(
            installations: initialResult.installations,
            preferredAccountLogin: user.login
        ) else {
            isAwaitingInitialGitHubGrant = false
            discoveryState = .failed("This app build has an invalid GitHub App address.")
            phase = .needsRepoSelection
            return .connected
        }

        repoSelectionAutoSelect = true
        initialGrantBaseline = AccessBaseline(initialResult)
        startAccessSession(
            url: accessURL,
            mode: .initialAfterSignIn,
            initialBaseline: AccessBaseline(initialResult),
            skipImmediateCheck: true
        )
        return .connected
    }

    /// A first sign-in that was cancelled while it waited: whatever it saved comes out of the Keychain again.
    private func forgetCancelledFirstSignIn(_ acct: BrainAccount) async -> SignInOutcome {
        onboardingLog.info("signedIn: first sign-in was cancelled, forgetting it")
        if session == nil, (try? acct.selectionStore.load()) == nil {
            acct.tokens.clear()
            await acct.manager.reload()
        }
        return .cancelled
    }

    /// Whether Open GitHub can reopen the access page of a first sign-in that is waiting on GitHub.
    var canReopenGitHubForInitialGrant: Bool {
        isAwaitingInitialGitHubGrant && !isSelectingRepository && account != nil
    }

    /// Open GitHub while a first sign-in waits on the access page (it was closed, is behind the app, or never showed):
    /// the same page again, with the same starting point, so a grant made there is still noticed.
    func reopenGitHubForInitialGrant() {
        guard canReopenGitHubForInitialGrant, !options.demo, let acct = account else { return }
        guard let url = try? preferredAccessURL(account: acct) else { return }
        onboardingLog.info("access page reopened while waiting for GitHub")
        // A look at the list that the last page's close started is replaced by this page's own.
        discoveryTask?.cancel()
        discoveryTask = nil
        startAccessSession(
            url: url,
            mode: .initialAfterSignIn,
            initialBaseline: initialGrantBaseline ?? activeAccessBaseline,
            skipImmediateCheck: true
        )
    }

    /// Cancel or "Use a different account" during a first sign-in, before any notes were chosen: GitHub's page closes,
    /// every wait stops, and the sign-in comes out of the Keychain, so the next launch starts at Connect. Does nothing
    /// when notes are on this device (a re-sign-in never reaches this state) or nothing is in flight.
    func cancelFirstTimeSignIn() async {
        guard !options.demo, session == nil, phase == .needsSignIn,
              isAwaitingInitialGitHubGrant || firstSignInInFlight,
              let acct = account else { return }
        onboardingLog.info("first sign-in cancelled before notes were chosen")
        firstSignInGeneration += 1
        firstSignInInFlight = false
        stopAccessPollingFlags()
        discoveryTask?.cancel()
        discoveryTask = nil
        activeAccessMode = nil
        activeAccessBaseline = nil
        pendingAccessReturn = nil
        initialGrantBaseline = nil
        isAwaitingInitialGitHubGrant = false
        repoSelectionAutoSelect = false
        awaitingInstallAfterCreate = false
        lastKnownInstallations = nil
        signedInUser = nil
        discoveryState = .loading
        webSession.cancel()
        guard (try? acct.selectionStore.load()) == nil else { return }
        acct.tokens.clear()
        await acct.manager.reload()
    }

    private func wipeUnboundBrainFolder(baseFolder base: URL) async throws {
        let brainDir = base.appendingPathComponent("Brain", isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try LegacyBrainMigration.wipeFolderNoFollow(brainDir)
        }.value
    }

    /// Saves any open editor buffer to disk first, then answers whether the local journal has unsynced edits so the UI
    /// can warn and require explicit confirmation before switching repositories.
    func checkUnsyncedBeforeRepoSwitch() async -> Bool {
        await openEditor?.saveNow(self)
        return hasUnsyncedEdits
    }

    /// Opens GitHub's configure/install page immediately while keeping the current session and local copy intact.
    /// Local notes are wiped only inside `selectRepository` after a new private repository is confirmed and verified.
    func changeNotesRepository() async {
        guard let s = session else { return }
        if s.isDemo {
            await leaveSampleNotes()
            return
        }
        await openEditor?.saveNow(self)
        guard let acct = account, !options.demo else { return }
        guard let url = try? preferredAccessURL(account: acct) else {
            discoveryState = .failed("This app build has an invalid GitHub App address.")
            isPresentingRepoPicker = true
            return
        }
        repoSelectionAutoSelect = false
        startAccessSession(
            url: url,
            mode: .switchFromSession(currentRepoId: s.repo.repoId, expectedUserId: s.selection?.userId),
            initialBaseline: nil,
            skipImmediateCheck: false
        )
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
        showSignIn = false
        privateBrowser = false
        awaitingAccessReturn = false
        lastKnownInstallations = nil
        onboardingLog.info("signed out and wiped")
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
    case allNotes
    case rootNotes
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
        case .allNotes, .rootNotes, .folder, .inbox, .attention:
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
