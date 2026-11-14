import BrainNotesKit
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Device flow: the code first and large, one button that copies it and opens GitHub, polling that carries on whether
/// or not the browser is open, and, once GitHub approves, a required "Connected as @login" step before anything is
/// saved. No secret anywhere.
@MainActor @Observable
final class SignInModel {
    enum Step: Equatable {
        case start
        case requesting
        /// The code is on screen and GitHub is being asked whether it was approved.
        case waiting(DeviceCode)
        /// Approved: asking GitHub whose account this is.
        case checking
        /// The account is known and nothing is saved: Continue, or use a different account.
        case confirming(GitHubAccount)
        case expired
        case denied
        /// Plain words and "Get a new code".
        case failed(String)
        /// Approved, but the account check could not run. Try again, with the same approval.
        case accountCheckFailed(String)
        /// The app did not accept the account (it is not the one the notes on this device belong to).
        case refused(String, differentAccount: Bool)
    }

    enum Wait: Equatable {
        case waiting
        /// Two requests in a row did not get through. Polling goes on.
        case offline
    }

    /// What is true of the sign-in right now. Polling GitHub (`wait`) is inside `.waiting`.
    private(set) var step: Step
    /// Last code shown in this run so the code screen stays steady while the account is checked.
    private(set) var displayedCode: DeviceCode?
    /// While `.waiting`: whether GitHub is being reached. It says "offline" only after two failed polls in a row.
    private(set) var wait: Wait = .waiting
    /// When the code on screen runs out, from its `expiresIn`.
    private(set) var expiresAt: Date?
    /// One number per code. Everything that comes back from polling carries the number of the code it was for, and an
    /// older number is ignored: a new code, Cancel and a closed screen all move this on.
    private(set) var generation = 0
    /// True from the moment Continue is tapped until the sign-in is accepted or refused.
    private(set) var isContinuing = false
    private weak var app: AppModel?
    private var starter: Task<Void, Never>?
    private var verifier: Task<Void, Never>?
    private(set) var poller: DevicePoller?
    private var consecutiveFailures = 0
    /// The verified sign-in the person has not confirmed yet. Memory only: nothing is in the Keychain until Continue.
    private var candidate: (pair: TokenPair, user: GitHubAccount)?
    /// An approved sign-in whose account check could not run (no connection): kept so Try again asks again, with no new code.
    private var unchecked: TokenPair?
    /// Tests give polling its own clock; the app uses the device flow's.
    var pollClock: DevicePoller.Clock?

    init(step: Step = .start, expiresAt: Date? = nil) {
        self.step = step
        self.expiresAt = expiresAt
        if case let .waiting(code) = step {
            self.displayedCode = code
        }
    }

    var confirmingAccount: GitHubAccount? {
        if case let .confirming(account) = step { return account }
        return nil
    }

    /// A refusal or a confirmation belongs to this screen: other screens' reactions to the same event leave it be.
    var ownsOutcome: Bool {
        if isContinuing { return true }
        switch step {
        case .confirming, .refused, .checking, .accountCheckFailed:
            return true
        default:
            return false
        }
    }

    /// Asks GitHub for a code and shows it. The browser is NOT opened: the person sees the code first and opens GitHub
    /// with the button. `ephemeral: true` is "Use a different account": a private window from here on.
    func begin(_ app: AppModel, ephemeral: Bool? = nil) {
        self.app = app
        stopRun()
        displayedCode = nil
        // "Get a new code" can come while the old sheet is still up.
        app.webSession.cancel()
        if let ephemeral { app.usePrivateBrowser(ephemeral) }
        let gen = generation
        if app.isDemoSignIn {
            // Screenshots and UI tests: the screen with a sample code, nothing behind it.
            show(DeviceCode(deviceCode: "demo", userCode: "WDJB-MJHT",
                            verificationURI: URL(string: "https://github.com/login/device")!, interval: 5, expiresIn: 900))
            return
        }
        guard let flow = app.deviceFlow() else {
            onboardingLog.error("code not requested: sign-in not set up")
            step = .failed("GitHub sign-in isn’t set up in this version of the app yet.")
            return
        }
        onboardingLog.info("code requested")
        step = .requesting
        expiresAt = nil
        starter = Task { [weak self] in
            do {
                let code = try await flow.start()
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                self.show(code)
                onboardingLog.info("code shown")
                self.startPolling(code, flow: flow, generation: gen)
            } catch {
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                onboardingLog.error("code request failed")
                self.step = .failed("Couldn’t get a code from GitHub. Check your connection and try again.")
            }
        }
    }

    func cancel() {
        stopRun()
        displayedCode = nil
        step = .start
        expiresAt = nil
    }

    /// "Copy code & open GitHub": the code goes to the clipboard again, every time, and GitHub opens. Returns the page
    /// instead of opening it for a demo launch, which the view hands to the system.
    @discardableResult
    func copyAndOpenGitHub(_ app: AppModel) -> URL? {
        guard case let .waiting(code) = step else { return nil }
        copyCode(app)
        let url = code.browserURL()
        if app.isDemoSignIn { return url }
        onboardingLog.info("browser opened for sign-in, private window: \(app.privateBrowser, privacy: .public)")
        app.webSession.open(url, ephemeral: app.privateBrowser) { _ in
            // Closed by the person, or finished. Polling goes on either way: the code is still good.
            onboardingLog.info("browser closed on sign-in page")
        }
        return nil
    }

    /// The small "Copy code" control, and the copy inside the big button.
    func copyCode(_ app: AppModel) {
        guard case let .waiting(code) = step, app.usesSystemClipboard else { return }
        DeviceCodeClipboard.copy(code.userCode, until: expiresAt ?? Date().addingTimeInterval(900))
    }

    /// The app is in front again (back from GitHub, Mail or Passwords). Ask GitHub now instead of at the next tick
    /// (the poller still keeps to GitHub's interval). On iPhone a sign-in on Google or in Passwords will have replaced
    /// the code, so it is copied again. On a Mac the window regains focus often, so the code is copied only when the
    /// person taps "Copy code & open GitHub" or "Copy code".
    func sceneBecameActive(_ app: AppModel) {
        guard case .waiting = step, secondsLeft(at: Date()) > 0 else { return }
        onboardingLog.info("foreground while waiting: poll")
        #if os(iOS)
        copyCode(app)
        #endif
        poller?.wake()
    }

    /// Continue on "Connected as @login": only now is anything saved.
    func confirm(_ app: AppModel) {
        guard case .confirming = step, !isContinuing, let ok = candidate else { return }
        isContinuing = true
        onboardingLog.info("account confirmed")
        Task { [weak self] in
            let outcome = await app.signedIn(pair: ok.pair, verifiedUser: ok.user)
            guard let self else { return }
            self.candidate = nil
            switch outcome {
            case .connected:
                // The next screen takes over; this one keeps Continue off until it does.
                break
            case let .refused(message, differentAccount):
                self.isContinuing = false
                self.step = .refused(message, differentAccount: differentAccount)
            }
        }
    }

    /// "Use a different account": the verified sign-in is dropped unsaved, and a new code opens in a private window,
    /// here and for the access and create-notes pages that follow.
    func useDifferentAccount(_ app: AppModel) {
        onboardingLog.info("different account chosen")
        begin(app, ephemeral: true)
    }

    /// "Try again" after the account check could not run: the approval is still good, so ask again.
    func retryAccountCheck(_ app: AppModel) {
        guard case .accountCheckFailed = step, let pair = unchecked else { return }
        self.app = app
        step = .checking
        verify(pair, generation: generation)
    }

    private func show(_ code: DeviceCode) {
        displayedCode = code
        expiresAt = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        wait = .waiting
        consecutiveFailures = 0
        step = .waiting(code)
    }

    /// Ends whatever belongs to the code on screen. Its answers can no longer get here.
    private func stopRun() {
        generation += 1
        starter?.cancel()
        starter = nil
        verifier?.cancel()
        verifier = nil
        poller?.stop()
        poller = nil
        candidate = nil
        unchecked = nil
        isContinuing = false
        wait = .waiting
        consecutiveFailures = 0
    }

    private func startPolling(_ code: DeviceCode, flow: DeviceFlow, generation gen: Int) {
        guard let expiresAt else { return }
        let clock = pollClock ?? DevicePoller.Clock(now: { Date() }, sleep: { try await flow.pause(for: $0) })
        let poller = DevicePoller(
            code: code,
            expiresAt: expiresAt,
            poll: { code, interval in await flow.poll(code, currentInterval: interval) },
            clock: clock
        ) { [weak self] outcome in
            self?.receive(outcome, generation: gen)
        }
        self.poller = poller
        poller.start()
    }

    /// One poll's answer, for the code numbered `gen`. An answer for an older code, or one that arrives after the
    /// screen has moved on, changes nothing.
    func receive(_ outcome: PollOutcome, generation gen: Int) {
        guard gen == generation, case let .waiting(code) = step else { return }
        switch outcome {
        case .pending:
            onboardingLog.info("poll outcome: pending")
            wait = .waiting
            consecutiveFailures = 0
        case .slowDown:
            onboardingLog.info("poll outcome: slow down")
            wait = .waiting
            consecutiveFailures = 0
        case .transientFailure:
            onboardingLog.info("poll outcome: could not reach GitHub, still trying")
            consecutiveFailures += 1
            if consecutiveFailures >= 2 { wait = .offline }
        case let .approved(pair):
            onboardingLog.info("poll outcome: approved")
            approved(pair, code: code)
        case .expired:
            onboardingLog.info("poll outcome: expired")
            finish(.expired, code: code)
        case .denied:
            onboardingLog.info("poll outcome: denied")
            finish(.denied, code: code)
        case .fatal:
            onboardingLog.error("poll outcome: refused by GitHub")
            finish(.failed("GitHub couldn’t finish connecting. Try again in a moment."), code: code)
        }
    }

    /// The code ended without a sign-in: stop asking, close the sheet, and say why.
    private func finish(_ ended: Step, code: DeviceCode) {
        poller?.stop()
        poller = nil
        app?.webSession.cancel()
        DeviceCodeClipboard.forget(code.userCode)
        step = ended
    }

    /// Approved on GitHub. Close the sheet, then find out whose account it is before saving anything.
    private func approved(_ pair: TokenPair, code: DeviceCode) {
        poller?.stop()
        poller = nil
        app?.webSession.cancel()
        // The code is used up: off the Mac's pasteboard, if it is still the last thing copied.
        DeviceCodeClipboard.forget(code.userCode)
        step = .checking
        verify(pair, generation: generation)
    }

    private func verify(_ pair: TokenPair, generation gen: Int) {
        guard let app else { return }
        verifier?.cancel()
        verifier = Task { [weak self] in
            do {
                let (user, latest) = try await app.verifyCandidate(pair)
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                self.unchecked = nil
                self.candidate = (latest, user)
                self.step = .confirming(user)
                onboardingLog.info("account found, waiting for confirmation")
            } catch is CancellationError {
                return
            } catch GitHubError.unauthorized {
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                onboardingLog.error("account check failed: not accepted")
                self.step = .failed("GitHub didn’t accept that sign-in. Get a new code to try again.")
            } catch {
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                onboardingLog.error("account check failed: could not reach GitHub")
                self.unchecked = pair
                self.step = .accountCheckFailed("We couldn’t check your GitHub account. Check your connection and try again.")
            }
        }
    }

    /// Whole seconds until the code runs out, rounded up, so 0 means it has.
    func secondsLeft(at date: Date) -> Int {
        guard let expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSince(date).rounded(.up)))
    }
}

/// Polls GitHub for exactly one device code. Each request waits for the interval GitHub asked for, counted from the
/// last request, and `slow_down` raises it. `wake()` (the app is in front again) asks at once if the interval is
/// already over, and otherwise leaves the next scheduled request alone, so it can never be faster than GitHub allows.
/// Any failure that is no verdict is reported and retried; only a verdict, a token or the code's end stops it. After
/// the code's end, one last request finds out whether an approval just beat the clock.
@MainActor
final class DevicePoller {
    struct Clock {
        var now: () -> Date
        var sleep: (Duration) async throws -> Void
    }

    let code: DeviceCode
    let expiresAt: Date
    private let poll: (DeviceCode, Int) async -> PollOutcome
    private let clock: Clock
    private let onOutcome: (PollOutcome) -> Void
    /// Seconds between requests, as GitHub last asked.
    private(set) var interval: Int
    private(set) var lastRequestAt: Date?
    private(set) var requestCount = 0
    private(set) var isFinished = false
    private var inFlight = false
    private var run = 0
    private var task: Task<Void, Never>?

    init(code: DeviceCode, expiresAt: Date,
         poll: @escaping (DeviceCode, Int) async -> PollOutcome,
         clock: Clock,
         onOutcome: @escaping (PollOutcome) -> Void) {
        self.code = code
        self.expiresAt = expiresAt
        self.poll = poll
        self.clock = clock
        self.onOutcome = onOutcome
        self.interval = max(5, code.interval)
    }

    /// When the next request may go: one interval after the last (the code request counts as the first).
    var nextPollAt: Date {
        (lastRequestAt ?? clock.now()).addingTimeInterval(TimeInterval(interval))
    }

    func start() {
        guard task == nil, !isFinished else { return }
        lastRequestAt = clock.now()
        launch()
    }

    func stop() {
        isFinished = true
        task?.cancel()
        task = nil
    }

    /// The app came to the front. If the wait is over (a sleeping timer may not have fired while the app was
    /// suspended), ask now; if not, the scheduled request is already as soon as GitHub allows.
    func wake() {
        guard !isFinished, !inFlight, task != nil, clock.now() >= nextPollAt else { return }
        launch()
    }

    private func launch() {
        run += 1
        let mine = run
        task?.cancel()
        task = Task { [weak self] in await self?.loop(mine) }
    }

    private func isCurrent(_ mine: Int) -> Bool {
        !Task.isCancelled && mine == run && !isFinished
    }

    private func loop(_ mine: Int) async {
        while isCurrent(mine) {
            let delay = nextPollAt.timeIntervalSince(clock.now())
            if delay > 0 {
                do { try await clock.sleep(.seconds(delay)) } catch { return }
                guard isCurrent(mine) else { return }
            }
            let closing = clock.now() >= expiresAt
            inFlight = true
            lastRequestAt = clock.now()
            requestCount += 1
            var outcome = await poll(code, interval)
            inFlight = false
            guard isCurrent(mine) else { return }
            if case let .slowDown(newInterval) = outcome {
                interval = max(interval, newInterval)
            }
            let ended: Bool
            switch outcome {
            case .approved, .expired, .denied, .fatal:
                ended = true
            case .pending, .slowDown, .transientFailure:
                // The last request after the code's end found nothing: the code has run out.
                if closing { outcome = .expired }
                ended = closing
            }
            if ended {
                isFinished = true
                task = nil
            }
            onOutcome(outcome)
            if ended { return }
        }
    }
}

/// The plain sign-in of the Settings sheet, for a user whose sign-in stopped working. First-time users
/// get `OnboardingFlow`. Both show the same code screen and push confirmation on the navigation stack.
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SignInModel

    init(model: SignInModel = SignInModel()) {
        _model = State(initialValue: model)
    }

    private var isConfirmingBinding: Binding<Bool> {
        Binding(
            get: { model.confirmingAccount != nil },
            set: { presented in
                if !presented, model.confirmingAccount != nil {
                    app.webSession.cancel()
                    model.cancel()
                    app.showSignIn = false
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.step == .start {
                    start
                } else {
                    DeviceCodeView(model: model, onCancel: closeSheet)
                        .navigationDestination(isPresented: isConfirmingBinding) {
                            if let account = model.confirmingAccount {
                                ConfirmAccountView(model: model, account: account, onCancel: closeSheet)
                                    .navigationBarBackButtonHidden(true)
                            }
                        }
                }
            }
        }
        .tint(Color("AccentColor"))
        .onDisappear { model.cancel() }
    }

    private func closeSheet() {
        app.webSession.cancel()
        model.cancel()
        app.showSignIn = false
    }

    private var start: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Brain Notes")
                .font(.largeTitle.bold())
            Text("Your Markdown notes on GitHub, synced privately with this device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Connect GitHub") {
                app.beginOnboardingRun()
                model.begin(app)
            }
            .buttonStyle(.onboarding(.accent))
            .accessibilityIdentifier("signin.start")
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { app.showSignIn = false }
            }
        }
    }
}

/// The device code: big and first, one button that copies it and opens GitHub, a quiet countdown, and plain words for
/// every way the wait can end. Keeps the person on the code screen while requesting a code and while checking the
/// approved GitHub account (no spinner-only pages). Shared by onboarding and the Settings sheet.
struct DeviceCodeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    /// The code grows with the text size; it still shrinks to fit one line.
    @ScaledMetric(relativeTo: .largeTitle) private var codeSize: CGFloat = 44
    let model: SignInModel
    let onCancel: () -> Void

    private enum CodeScreenStatus {
        case requesting
        case waiting(secondsLeft: Int)
        case checking
    }

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: onCancel)
                        .accessibilityIdentifier("signin.cancel")
                }
            }
            // Back in front (from GitHub, Mail, Passwords): GitHub is asked at once. On iPhone the code is also
            // copied again; on a Mac it is not, so a window that becomes active does not overwrite the clipboard.
            // Nothing is cancelled on the way out: polling goes on while the app is away.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.sceneBecameActive(app) }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .start, .requesting:
            codeScreen(code: nil, status: .requesting)
        case let .waiting(code):
            // GitHub's answer can come a few seconds after the time is up, as it is polled.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = model.secondsLeft(at: context.date)
                if seconds > 0 {
                    codeScreen(code: code, status: .waiting(secondsLeft: seconds))
                } else {
                    ended("This code expired.", button: "Get a new code")
                }
            }
        case .checking, .confirming:
            codeScreen(code: model.displayedCode, status: .checking)
        case .expired:
            ended("This code expired.", button: "Get a new code")
        case .denied:
            ended("You chose not to allow access.", button: "Try again")
        case let .failed(message):
            ended(message, button: "Get a new code")
        case let .accountCheckFailed(message):
            accountCheckFailed(message)
        case let .refused(message, differentAccount):
            refused(message, differentAccount: differentAccount)
        }
    }

    private func codeScreen(code: DeviceCode?, status: CodeScreenStatus) -> some View {
        let canInteractWithCode: Bool = {
            if case .waiting = status { return code != nil }
            return false
        }()
        return OnboardingPage(id: "onboarding.code") {
            VStack(spacing: 0) {
                Text("Your code for GitHub")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("GitHub asks for this code to make sure it’s you.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                codeCard(code, isInteractive: canInteractWithCode)
                    .padding(.top, 26)
                VStack(alignment: .leading, spacing: 14) {
                    CodeStep(number: 1, text: "Tap the button below. We copy the code and open GitHub.")
                    CodeStep(number: 2, text: "Paste the code if it isn’t there already, then tap **Authorize**.")
                    CodeStep(number: 3, text: "Come back here. Brain Notes carries on by itself.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
                Text("GitHub only grants access to the private notes you choose. Your password never touches Brain Notes, and you can turn off access anytime at github.com/settings/applications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .accessibilityIdentifier("signin.permissions")
            }
        } bottom: {
            VStack(spacing: 14) {
                codeStatusView(status)
                Button {
                    flashCopied()
                    // A demo launch has no sign-in behind it: the system opens the page instead.
                    if let page = model.copyAndOpenGitHub(app) {
                        openURL(page)
                    }
                } label: {
                    Label("Copy code & open GitHub", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.onboarding(.accent))
                .disabled(!canInteractWithCode)
                .accessibilityIdentifier("signin.open")
            }
        }
    }

    @ViewBuilder private func codeStatusView(_ status: CodeScreenStatus) -> some View {
        switch status {
        case .requesting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking GitHub for a code…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("signin.requesting")
        case let .waiting(secondsLeft):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for you to approve on GitHub")
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    Text(verbatim: String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60))
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waiting for you to approve on GitHub. The code runs out in \(Duration.seconds(secondsLeft).formatted(.units(allowed: [.minutes, .seconds], width: .wide))).")
                .accessibilityIdentifier("signin.waiting")
                if model.wait == .offline {
                    Label("Can’t reach GitHub right now. Brain Notes keeps trying.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("signin.offline")
                }
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Approved — checking your GitHub account…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("signin.checking")
        }
    }

    /// Approved, but GitHub could not be asked whose account it is.
    private func accountCheckFailed(_ message: String) -> some View {
        OnboardingPage(id: "onboarding.codeEnded") {
            VStack(spacing: 18) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .padding(.top, 56)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signin.message")
            }
        } bottom: {
            Button("Try again") { model.retryAccountCheck(app) }
                .buttonStyle(.onboarding(.accent))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.retryCheck")
        }
    }

    /// The account is not the one the notes on this device belong to (or those notes are not tied to any account).
    private func refused(_ message: String, differentAccount: Bool) -> some View {
        OnboardingPage(id: "onboarding.codeRefused") {
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .padding(.top, 56)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signin.message")
            }
        } bottom: {
            VStack(spacing: 12) {
                if differentAccount {
                    Button("Use a different account") { model.useDifferentAccount(app) }
                        .buttonStyle(.onboarding(.accent))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("signin.refused.different")
                }
                Button("Sign out and wipe", role: .destructive) {
                    Task { await app.signOutAndWipe() }
                }
                .buttonStyle(.onboarding(.quiet))
                .accessibilityIdentifier("signin.refused.wipe")
            }
        }
    }

    private func codeCard(_ code: DeviceCode?, isInteractive: Bool) -> some View {
        VStack(spacing: 12) {
            if let code {
                Text(Self.styled(code.userCode))
                    .font(.system(size: codeSize, weight: .semibold, design: .monospaced))
                    .kerning(4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    // A code reads left to right in every language.
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityLabel(code.userCode.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("signin.code")
                Button {
                    flashCopied()
                    model.copyCode(app)
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!isInteractive)
                .accessibilityIdentifier("signin.copy")
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .frame(height: codeSize + 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 22, style: .continuous))
    }

    /// The code with its hyphen dimmed, as one text, so that no layout can reorder the two halves.
    private static func styled(_ code: String) -> AttributedString {
        var text = AttributedString(code)
        if let hyphen = text.range(of: "-") { text[hyphen].foregroundColor = .secondary }
        return text
    }

    /// The code is over (it ran out, was refused, or the sign-in failed): what happened, and a way to go on.
    private func ended(_ message: String, button: LocalizedStringKey) -> some View {
        OnboardingPage(id: "onboarding.codeEnded") {
            VStack(spacing: 18) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .padding(.top, 56)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signin.message")
            }
        } bottom: {
            Button(button) { model.begin(app) }
                .buttonStyle(.onboarding(.accent))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.newCode")
        }
    }

    /// "Copied" on the small control for two seconds, plus a standard success haptic on iPhone.
    private func flashCopied() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// "Connected as @login": pushed onto the navigation stack once GitHub confirms the account, before anything is saved.
struct ConfirmAccountView: View {
    @Environment(AppModel.self) private var app
    let model: SignInModel
    let account: GitHubAccount
    let onCancel: () -> Void

    private var isWaitingForGitHub: Bool {
        model.isContinuing || app.isAwaitingInitialGitHubGrant
    }

    var body: some View {
        OnboardingPage(id: "onboarding.confirm") {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 48)
                    .accessibilityHidden(true)
                Text("Connected as @\(account.login)")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signin.confirm.login")
                Text("Is this the GitHub account with your notes? Nothing is saved on this device until you continue.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } bottom: {
            VStack(spacing: 12) {
                if isWaitingForGitHub {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for GitHub…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("signin.confirm.waiting")
                }
                Button("Continue") { model.confirm(app) }
                    .buttonStyle(.onboarding(.accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWaitingForGitHub)
                    .accessibilityIdentifier("signin.confirm.continue")
                Button("Use a different account") { model.useDifferentAccount(app) }
                    .buttonStyle(.onboarding(.quiet))
                    .disabled(isWaitingForGitHub)
                    .accessibilityIdentifier("signin.confirm.different")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", action: onCancel)
                    .disabled(isWaitingForGitHub)
                    .accessibilityIdentifier("signin.cancel")
            }
        }
    }
}

/// The device code on the pasteboard (audit S-L1). On iOS it stays on this device (no Universal Clipboard) and expires
/// with the code. macOS has neither option, so the app takes the code off again once sign-in succeeds or the code runs
/// out, and only if the pasteboard still holds exactly what it put there: anything copied since is left alone.
@MainActor
enum DeviceCodeClipboard {
    #if os(macOS)
    /// The pasteboard's change count right after the copy, and the code that was copied.
    private static var copied: (change: Int, code: String)?
    private static var expiry: Task<Void, Never>?
    #endif

    static func copy(_ code: String, until expiresAt: Date) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code]],
                                      options: [.expirationDate: expiresAt, .localOnly: true])
        #else
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(code, forType: .string)
        copied = (board.changeCount, code)
        expiry?.cancel()
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            forget(code)
        }
        #endif
    }

    /// The code is used up or ran out. On macOS it comes off the pasteboard if nothing was copied over it since.
    /// On iOS the expiry set by `copy` does this.
    static func forget(_ code: String) {
        #if os(macOS)
        guard let mine = copied, mine.code == code else { return }
        copied = nil
        expiry?.cancel()
        expiry = nil
        let board = NSPasteboard.general
        guard board.changeCount == mine.change, board.string(forType: .string) == code else { return }
        board.clearContents()
        #endif
    }
}

private struct CodeStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Text(number, format: .number)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.fill.tertiary, in: .circle)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmChangeRepo = false
    @State private var confirmWipe = false

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { app.isUserPaused },
            set: { newValue in app.requestPaused(newValue) }
        )
    }

    private var isSignedOut: Bool {
        if case .signedOut = app.snapshot.state { return true }
        return false
    }

    var body: some View {
        Form {
            if app.sampleMode {
                Section {
                    LabeledContent("Notes", value: "Sample notes")
                        .accessibilityIdentifier("settings.sample")
                    Button("Connect GitHub") {
                        Task { await app.leaveSampleNotes() }
                    }
                    .accessibilityIdentifier("settings.connect")
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Sample notes live on this device only. Connecting GitHub removes them.")
                }
            } else {
                if let login = app.signedInUser?.login ?? app.session?.selection?.userLogin {
                    Section("Account") {
                        Text("Signed in as @\(login)")
                            .accessibilityIdentifier("settings.signedInAs")
                    }
                }
                Section {
                    Text(app.session?.repo.slug ?? "")
                        .accessibilityIdentifier("settings.repo")
                    Button("Change notes…") {
                        Task {
                            if await app.checkUnsyncedBeforeRepoSwitch() {
                                confirmChangeRepo = true
                            } else {
                                await app.changeNotesRepository()
                            }
                        }
                    }
                    .disabled(app.isSwitchingRepositories || app.isSelectingRepository)
                    .accessibilityIdentifier("settings.changeRepo")
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Switching keeps GitHub’s copy; this device updates after you pick.")
                }
            }
            Section("Sync") {
                Toggle("Pause sync", isOn: pauseBinding)
                    .accessibilityIdentifier("settings.pause")
                LabeledContent("Last sync") {
                    if let date = app.snapshot.lastSync {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet")
                    }
                }
                .accessibilityIdentifier("settings.lastSync")
                LabeledContent("Waiting to sync", value: "\(app.snapshot.unsynced)")
                    .accessibilityIdentifier("settings.unsynced")
                Button("Sync now") {
                    Task { await app.syncNow() }
                }
                .accessibilityIdentifier("settings.syncNow")
                if isSignedOut {
                    Button("Sign in again") { app.showSignIn = true }
                        .accessibilityIdentifier("settings.signIn")
                }
                if let reSignInError = app.reSignInError {
                    Text(reSignInError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.reSignInError")
                }
            }
            Section {
                if let githubApps = URL(string: "https://github.com/settings/applications") {
                    Link("Review or revoke GitHub access", destination: githubApps)
                        .accessibilityIdentifier("settings.githubAccess")
                }
                if let privacy = URL(string: "https://brain-notes-app.vercel.app/#privacy") {
                    Link("Privacy Policy", destination: privacy)
                        .accessibilityIdentifier("settings.privacy")
                }
                if let support = URL(string: "https://brain-notes-app.vercel.app/#support") {
                    Link("Support", destination: support)
                        .accessibilityIdentifier("settings.support")
                }
            } header: {
                Text("Data & Permissions")
            } footer: {
                Text("Notes live as Markdown on this device and on GitHub, with no Brain Notes server.")
            }
            if !app.sampleMode {
                Section {
                    Button("Sign out and wipe", role: .destructive) {
                        confirmWipe = true
                    }
                    .accessibilityIdentifier("settings.wipe")
                } footer: {
                    Text(app.snapshot.unsynced > 0
                         ? "\(app.snapshot.unsynced) notes have changes that aren’t on GitHub yet. Wiping deletes them from this device."
                         : "Removes your sign-in and local copy from this device. GitHub keeps your notes.")
                }
            }
        }
        .formStyle(.grouped)
        .brainBlackList()
        .animation(.default, value: isSignedOut)
        .animation(.default, value: app.reSignInError != nil)
        .navigationTitle("Settings")
        .confirmationDialog("Unsynced changes on this device", isPresented: $confirmChangeRepo) {
            Button("Continue to GitHub", role: .destructive) {
                Task { await app.changeNotesRepository() }
            }
            .accessibilityIdentifier("settings.changeRepo.confirm")
        } message: {
            Text("Some notes on this device haven’t synced to GitHub yet. Switching repositories replaces this local copy once you pick different notes.")
        }
        .confirmationDialog("Sign out and wipe this device?", isPresented: $confirmWipe) {
            Button("Sign out and wipe", role: .destructive) {
                Task { await app.signOutAndWipe() }
            }
            .accessibilityIdentifier("settings.wipe.confirm")
        } message: {
            Text("This can't be undone.")
        }
    }
}
