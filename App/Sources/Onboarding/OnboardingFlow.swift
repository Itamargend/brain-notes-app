import BrainNotesKit
import SwiftUI

/// The first-run screens, in order. `-BNScreen welcome|connect|code|choose|ready` opens one directly.
/// Welcome and Connect are the same screen: a fresh install and a return to sign-in both offer GitHub
/// and sample notes, with no extra Continue step. The two cases stay so a launch can still open either,
/// and so leaving the device code returns to Connect rather than replaying a separate welcome.
enum OnboardingStep: Hashable {
    case welcome, connect, deviceCode, chooseNotes, ready
}

/// The first-run screen, the device code, confirmation, choosing notes, and Ready. `AppModel.showsOnboarding` decides
/// whether this is on screen at all; transitions use default `NavigationStack` pushes with Reduce Motion left to the system.
struct OnboardingFlow: View {
    private enum Destination: Hashable {
        case deviceCode
        case confirm(GitHubAccount)
        case chooseNotes
        case ready
    }

    @Environment(AppModel.self) private var app
    @AppStorage(AppModel.onboardedKey) private var onboarded = false
    @State private var initialStep: OnboardingStep
    @State private var path: [Destination]
    @State private var signIn: SignInModel

    init(start: OnboardingStep, signIn: SignInModel = SignInModel()) {
        _initialStep = State(initialValue: start)
        let startingPath: [Destination]
        switch start {
        case .welcome, .connect:
            startingPath = []
        case .deviceCode:
            startingPath = [.deviceCode]
        case .chooseNotes:
            startingPath = [.chooseNotes]
        case .ready:
            startingPath = [.ready]
        }
        _path = State(initialValue: startingPath)
        _signIn = State(initialValue: signIn)
    }

    /// The Ready screen sets this, and `signOutAndWipe` sets the same key on the model. Either store counts:
    /// `@AppStorage` follows the view's defaults, and the model writes its own.
    private var finishedFirstRun: Bool {
        onboarded || app.defaults.bool(forKey: AppModel.onboardedKey)
    }

    private var rootIdentifier: String {
        (finishedFirstRun || initialStep == .connect) ? "onboarding.connect" : "onboarding.welcome"
    }

    var body: some View {
        NavigationStack(path: $path) {
            StartView(id: rootIdentifier, onSignIn: beginSignIn, onSample: beginSample)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(for: Destination.self) { destination in
                    destinationView(for: destination)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
        }
        // The asset itself: on a Mac, `Color.accentColor` can follow the system's accent setting.
        .tint(Color("AccentColor"))
        .task {
            syncPathWithModel()
            if initialStep == .deviceCode, signIn.step == .start {
                signIn.begin(app)
            }
        }
        .onChange(of: signIn.step) { _, _ in
            syncPathWithModel()
        }
        .onChange(of: app.phase) { oldPhase, newPhase in
            if oldPhase != .needsSignIn, newPhase == .needsSignIn {
                signIn.cancel()
                initialStep = .connect
                path = []
            } else {
                syncPathWithModel()
            }
        }
        .onChange(of: app.readyScreenPending) { _, _ in
            syncPathWithModel()
        }
        .onChange(of: app.reSignInError) { _, err in
            // A refusal that came from this screen's own Continue is shown on the code screen, with its choices.
            if err != nil, !signIn.ownsOutcome {
                signIn.cancel()
                initialStep = .connect
                path = []
            }
        }
        .onDisappear { signIn.cancel() }
    }

    @ViewBuilder
    private func destinationView(for destination: Destination) -> some View {
        switch destination {
        case .deviceCode:
            DeviceCodeView(model: signIn, onCancel: cancelSignIn)
                .navigationBarBackButtonHidden(true)
        case let .confirm(account):
            ConfirmAccountView(model: signIn, account: account, onCancel: cancelSignIn)
                .navigationBarBackButtonHidden(true)
        case .chooseNotes:
            ChooseNotesView()
                .navigationBarBackButtonHidden(true)
        case .ready:
            ReadyView()
                .navigationBarBackButtonHidden(true)
                .onAppear {
                    onboarded = true
                    app.defaults.set(true, forKey: AppModel.onboardedKey)
                }
        }
    }

    private func syncPathWithModel() {
        if app.readyScreenPending {
            if path.last != .ready {
                path.append(.ready)
            }
            return
        }
        if app.phase == .needsRepoSelection {
            if path.last != .chooseNotes {
                path.append(.chooseNotes)
            }
            return
        }
        if case let .confirming(account) = signIn.step {
            let target = Destination.confirm(account)
            if path.last != target {
                path.removeAll { if case .confirm = $0 { return true } else { return false } }
                if !path.contains(.deviceCode) {
                    path.append(.deviceCode)
                }
                path.append(target)
            }
            return
        }
        if let last = path.last, case .confirm = last {
            path = [.deviceCode]
        }
    }

    private func cancelSignIn() {
        app.webSession.cancel()
        signIn.cancel()
        initialStep = .connect
        path = []
    }

    private func beginSignIn() {
        // A new run: the shared browser again, and last time's refusal off the screen.
        app.beginOnboardingRun()
        signIn.begin(app)
        path = [.deviceCode]
    }

    private func beginSample() {
        Task { await app.startSampleNotes() }
    }
}

// MARK: - First screen

/// Welcome and Connect as one screen: the mark, a short list of what the app does, how connecting works,
/// then Connect GitHub and the sample notes.
private struct StartView: View {
    @Environment(AppModel.self) private var app
    let id: String
    let onSignIn: () -> Void
    let onSample: () -> Void

    var body: some View {
        OnboardingPage(id: id) {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    NotepadMark()
                    Text("Welcome to Brain Notes")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(symbol: "doc.text", title: "Plain Markdown, synced with your notes on GitHub")
                    FeatureRow(symbol: "arrow.triangle.2.circlepath", title: "Works offline, syncs when you’re back")
                    FeatureRow(symbol: "character.bubble", title: "Hebrew and English, side by side")
                }
                VStack(spacing: 6) {
                    Text("Notes travel straight from this device to GitHub. There is no Brain Notes server.")
                    Text("Brain Notes connects with a one-time code. No password is stored on this device.")
                    Text("Your sign-in stays in this device’s Keychain and only reaches the private notes you choose.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        } bottom: {
            VStack(spacing: 12) {
                if let reSignInError = app.reSignInError {
                    Text(reSignInError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("onboarding.reSignInError")
                    Button("Sign out and wipe", role: .destructive) {
                        Task { await app.signOutAndWipe() }
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("onboarding.wipeForNewAccount")
                }
                if !app.isDeviceOnline || app.snapshot.state == .offline {
                    Label("You’re offline. Try Sample Notes now and connect later.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 2)
                        .accessibilityIdentifier("onboarding.offline")
                }
                Button(action: onSignIn) {
                    Label("Connect GitHub", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.onboarding(.ink))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.start")
                Button("Try with Sample Notes", action: onSample)
                    .buttonStyle(.onboarding(.quiet))
                    .accessibilityIdentifier("onboarding.sample")
            }
        }
    }
}

/// The approved notepad page: black top band, punched dots, white paper, gray rules.
/// Original colors, so it is not tinted into the old accent mark.
private struct NotepadMark: View {
    private let side: CGFloat = 76

    var body: some View {
        Image("BrainMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Choose your notes

struct ChooseNotesView: View {
    @Environment(AppModel.self) private var app

    private var isSwitchingExistingSession: Bool {
        app.session != nil
    }

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSwitchingExistingSession {
                        Button("Cancel") {
                            app.cancelRepoSwitch()
                        }
                        .accessibilityIdentifier("onboarding.cancelSwitch")
                    } else {
                        Button("Sign out") {
                            Task { await app.signOutAndWipe() }
                        }
                        .accessibilityIdentifier("onboarding.signOut")
                    }
                }
            }
    }

    @ViewBuilder private var signedInBanner: some View {
        if let user = app.signedInUser {
            Text("Signed in as @\(user.login)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.signedInAs")
        }
    }

    @ViewBuilder private var content: some View {
        switch app.discoveryState {
        case .loading:
            OnboardingPage(id: "onboarding.choose") {
                VStack(spacing: 18) {
                    signedInBanner
                        .padding(.top, 24)
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.top, 40)
                    Text("Checking your notes on GitHub…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboarding.choose.loading")
                }
            } bottom: {
                EmptyView()
            }
        case let .failed(message):
            OnboardingPage(id: "onboarding.choose") {
                VStack(spacing: 16) {
                    signedInBanner
                        .padding(.top, 12)
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .padding(.top, 32)
                        .accessibilityHidden(true)
                    Text("Choose your notes")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.choose.error")
                }
            } bottom: {
                VStack(spacing: 12) {
                    Button("Try again") {
                        Task { await app.retryDiscovery() }
                    }
                    .buttonStyle(.onboarding(.accent))
                    .accessibilityIdentifier("onboarding.refreshRepos")
                    Button {
                        app.openGitHubAppInstall()
                    } label: {
                        Label("Choose notes on GitHub", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.onboarding(.quiet))
                    .accessibilityIdentifier("onboarding.installApp")
                }
            }
        case let .loaded(result):
            if result.repositories.isEmpty {
                emptySelectionScreen(isTruncated: result.isTruncated)
            } else {
                repositoryPickerScreen(result)
            }
        }
    }

    private func emptySelectionScreen(isTruncated: Bool) -> some View {
        OnboardingPage(id: "onboarding.choose") {
            VStack(spacing: 18) {
                signedInBanner
                Image(systemName: "lock.doc")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .padding(.top, 20)
                    .accessibilityHidden(true)
                Text("Give Brain Notes access to your notes")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.access.title")
                if isTruncated {
                    Text(DiscoveryResult.truncatedMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("onboarding.truncatedNotice")
                }
                Text("On GitHub, choose ‘Only select repositories’ and pick your notes.")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("onboarding.installHint")
                if app.awaitingInstallAfterCreate {
                    Label("Made your new notes? Now tap the button below and pick them.", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 16, style: .continuous))
                        .accessibilityIdentifier("onboarding.createHint")
                }
            }
        } bottom: {
            VStack(spacing: 12) {
                if app.isPollingInstallations {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for GitHub…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.installPolling")
                }
                Button {
                    app.openGitHubAppInstall()
                } label: {
                    Label("Open GitHub to choose notes", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.onboarding(.accent))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.installApp")
                Button("Create a new private brain") {
                    app.openCreateBrain()
                }
                .buttonStyle(.onboarding(.quiet))
                .accessibilityIdentifier("onboarding.createBrain")
            }
        }
    }

    @ViewBuilder
    private func repositoryPickerScreen(_ result: DiscoveryResult) -> some View {
        #if os(iOS)
        List {
            pickerSections(result)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose Notes")
        .accessibilityIdentifier("onboarding.choose")
        #else
        Form {
            pickerSections(result)
        }
        .formStyle(.grouped)
        .navigationTitle("Choose Notes")
        .accessibilityIdentifier("onboarding.choose")
        #endif
    }

    @ViewBuilder
    private func pickerSections(_ result: DiscoveryResult) -> some View {
        if let user = app.signedInUser {
            Section {
                Text("Signed in as @\(user.login)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.signedInAs")
            }
        }

        if result.isTruncated {
            Section {
                Text(DiscoveryResult.truncatedMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.truncatedNotice")
            }
        }

        Section {
            ForEach(result.privateRepositories) { repo in
                Button {
                    Task { await app.selectRepository(repo, fromSettingsSwitch: isSwitchingExistingSession) }
                } label: {
                    RepoPickerRow(repo: repo)
                }
                .disabled(app.isSelectingRepository)
                .accessibilityIdentifier("onboarding.pick.\(repo.slug)")
            }
            ForEach(result.publicRepositories) { repo in
                RepoPickerRow(repo: repo)
                    .disabled(true)
                    .accessibilityIdentifier("onboarding.public.\(repo.slug)")
            }
        } header: {
            Text(result.privateRepositories.isEmpty ? "Repositories" : "Private Notes")
        } footer: {
            Text(pickerFooter(for: result))
                .accessibilityIdentifier("onboarding.installHint")
        }

        Section {
            Button {
                app.openGitHubAppInstall()
            } label: {
                Label(
                    result.privateRepositories.isEmpty ? "Choose notes on GitHub" : "Choose different notes on GitHub",
                    systemImage: "arrow.up.forward.app"
                )
            }
            .accessibilityIdentifier("onboarding.installApp")

            Button("Create a new private brain") {
                app.openCreateBrain()
            }
            .accessibilityIdentifier("onboarding.createBrain")

            Button("Refresh") {
                Task { await app.refreshDiscovery(autoSelectSinglePrivate: false) }
            }
            .accessibilityIdentifier("onboarding.refreshRepos")

            if app.awaitingInstallAfterCreate {
                Label("Made your new notes? Now tap Choose notes on GitHub and pick them.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.createHint")
            }

            if app.isPollingInstallations || app.isSelectingRepository {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(app.isSelectingRepository ? "Connecting notes…" : "Waiting for GitHub…")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .accessibilityIdentifier("onboarding.installPolling")
            }
        }
    }

    private func pickerFooter(for result: DiscoveryResult) -> String {
        if result.privateRepositories.isEmpty {
            return "None of your selected repositories on GitHub are private. Brain Notes only opens private ones."
        }
        if result.hasAllRepositoriesGrant {
            return "GitHub granted access to all repositories. Pick the private notes for this device, or limit access on GitHub to only select repositories."
        }
        return "On GitHub, choose ‘Only select repositories’ and pick your notes."
    }
}

private struct RepoPickerRow: View {
    let repo: DiscoveredRepo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                    .foregroundStyle(repo.isPrivate ? Color("AccentColor") : Color.secondary)
                    .accessibilityHidden(true)
                Text(repo.slug)
                    .font(.body.monospaced())
                    .foregroundStyle(repo.isPrivate ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Text(repo.isPrivate ? "Private" : "Public")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if !repo.isPrivate {
                Text(RepoTarget.publicRepoMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Ready

/// What the Ready screen says, from the engine's snapshot and nothing else.
enum ReadyStatus: Equatable {
    /// Notes are on their way, and Open My Notes waits for them.
    case working(String, fraction: Double?)
    case done
    /// Sync can't finish right now. The notes open anyway: the screen must never be a dead end, and the
    /// home screen's sync pill carries on from here.
    case problem(String)

    /// `repo` is the session's `owner/name`, for the words when it can't be reached.
    init(snapshot: SyncSnapshot, sessionOpen: Bool, repo: String? = nil) {
        guard sessionOpen else {
            self = .working("Getting your notes", fraction: nil)
            return
        }
        switch snapshot.state {
        case .firstSync(.downloading):
            self = .working("Downloading notes", fraction: nil)
        case let .firstSync(.verifying(done, total)):
            self = .working("Checking \(done) of \(total)", fraction: Self.fraction(done, total))
        case let .firstSync(.indexing(done, total)):
            self = .working("Indexing \(done) of \(total)", fraction: Self.fraction(done, total))
        case let .accountMismatch(login):
            self = .problem(AppModel.accountMismatchMessage(login: login))
        case let .accountCheckFailed(unauthorized):
            self = .problem(unauthorized
                ? "GitHub didn’t accept this sign-in. Sign in again or try again to confirm your account."
                : AppModel.accountCheckFailedMessage)
        case _ where snapshot.hasFirstSynced:
            self = .done
        case .checking, .pulling, .merging, .applying, .pushing, .verifying:
            self = .working("Getting your notes", fraction: nil)
        case .offline:
            self = .problem("You’re offline. Your notes will come down when you’re back.")
        case .retrying:
            self = .problem("GitHub isn’t answering. Brain Notes keeps trying.")
        case .paused(.rateLimited):
            self = .problem("GitHub asked Brain Notes to wait. Your notes will follow.")
        case .paused(.user):
            self = .problem("Sync is paused. Your notes will come down when it’s back on.")
        case .signedOut:
            self = .problem("GitHub didn’t accept this sign-in. You can sign in again from your notes.")
        case .accessLost:
            self = .problem(repo.map { "This sign-in can’t reach \($0)." } ?? "This sign-in can’t reach your notes.")
        case .installationTruncated:
            self = .problem(DiscoveryResult.truncatedMessage)
        case .publicRepo:
            self = .problem(RepoTarget.publicRepoMessage)
        case let .repoTooLarge(limit):
            self = .problem(limit.message)
        case .needsAttention, .idle:
            // A first sync stopped short of a commit, for a reason that clears by itself (a locked device).
            self = .problem("Your notes will follow in a moment.")
        }
    }

    private static func fraction(_ done: Int, _ total: Int) -> Double? {
        total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    var keepsNotesClosed: Bool {
        if case .working = self { return true }
        return false
    }
}

private struct ReadyView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.session?.repo.slug
        let isLive = !app.sampleMode && !(app.session?.isDemo ?? false)
        let signedInLogin = isLive ? (app.signedInUser?.login ?? app.session?.selection?.userLogin) : nil
        ReadyContent(
            status: ReadyStatus(snapshot: app.snapshot, sessionOpen: app.session != nil, repo: repo),
            sample: app.sampleMode,
            noteCount: app.noteCount,
            lastSync: app.snapshot.lastSync,
            repo: repo,
            signedInLogin: signedInLogin,
            onSignOut: isLive ? { Task { await app.signOutAndWipe() } } : nil
        ) {
            app.openNotesFromReadyScreen()
        }
    }
}

/// The Ready screen, from plain values.
struct ReadyContent: View {
    let status: ReadyStatus
    let sample: Bool
    let noteCount: Int
    let lastSync: Date?
    /// The session's `owner/name`: the repo this build names.
    var repo: String? = nil
    var signedInLogin: String? = nil
    var onSignOut: (() -> Void)? = nil
    let onOpen: () -> Void

    private var message: String {
        if sample {
            return "Sample notes live on this device only. Connect GitHub any time in Settings."
        }
        return status == .done
            ? "Your brain is on this device and stays in sync with GitHub."
            : "Brain Notes is bringing your notes to this device."
    }

    var body: some View {
        OnboardingPage(id: "onboarding.ready") {
            VStack(spacing: 14) {
                if !sample, let login = signedInLogin {
                    Text("Signed in as @\(login)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboarding.signedInAs")
                }
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 88))
                    .padding(.top, 24)
                    .padding(.bottom, 10)
                    .accessibilityHidden(true)
                Text("You’re all set")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.ready.message")
                facts
                    .padding(.top, 18)
            }
        } bottom: {
            VStack(spacing: 14) {
                statusLine
                Button("Open My Notes", action: onOpen)
                    .buttonStyle(.onboarding(.accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(status.keepsNotesClosed)
                    .accessibilityIdentifier("onboarding.open")
            }
        }
        .toolbar {
            if let onSignOut {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out", action: onSignOut)
                        .accessibilityIdentifier("onboarding.signOut")
                }
            }
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            FactRow(symbol: "book.closed", title: "Notes on GitHub") {
                if sample {
                    Text("Sample notes")
                        .accessibilityIdentifier("onboarding.repo")
                } else {
                    Text(repo ?? "—")
                        .font(.footnote.monospaced())
                        .accessibilityIdentifier("onboarding.repo")
                }
            }
            Divider()
            FactRow(symbol: "list.bullet", title: "Notes") {
                if noteCount > 0 {
                    Text(noteCount, format: .number)
                        .monospacedDigit()
                } else {
                    Text("Not yet")
                }
            }
            Divider()
            FactRow(symbol: "arrow.triangle.2.circlepath", title: "Last synced") {
                if let lastSync {
                    Text(lastSync, format: .relative(presentation: .named))
                } else {
                    Text("Not yet")
                }
            }
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case let .working(label, fraction):
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if fraction == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(label)
                        .monospacedDigit()
                }
                if let fraction {
                    ProgressView(value: fraction)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(label == "Getting your notes" ? "onboarding.checking" : "onboarding.progress")
        case let .problem(message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.problem")
        case .done:
            EmptyView()
        }
    }
}

private struct FactRow<Value: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let symbol: String
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        // At the largest text sizes a title and a repo name don't fit side by side.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(title)
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            value
                .foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared

/// One screen: content that scrolls when it has to, buttons that stay at the bottom.
struct OnboardingPage<Content: View, Bottom: View>: View {
    /// The screen's accessibility identifier. A container, so its buttons keep theirs.
    let id: String
    @ViewBuilder let content: Content
    @ViewBuilder let bottom: Bottom

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: Self.columnWidth)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottom
                .frame(maxWidth: Self.columnWidth)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(.background)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    private static var columnWidth: CGFloat { 460 }
}

/// The filled pills of the mockups, with the same look on iPhone and Mac.
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind {
        /// The main action: slate blue.
        case accent
        /// Sign in with GitHub: black in light mode, white in dark.
        case ink
        /// The other way forward: slate blue on a neutral fill.
        case quiet
    }

    let kind: Kind
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .background(background, in: .capsule)
            .contentShape(.capsule)
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
    }

    private var inverse: Color { colorScheme == .dark ? .black : .white }

    /// The dark slate blue is light: black text on it reads 7.5:1, white only 2.8:1.
    private var foreground: Color {
        switch kind {
        case .accent, .ink: inverse
        case .quiet: Color("AccentColor")
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .accent: AnyShapeStyle(Color("AccentColor"))
        case .ink: AnyShapeStyle(colorScheme == .dark ? Color.white : Color.black)
        case .quiet: AnyShapeStyle(.fill.tertiary)
        }
    }
}

extension ButtonStyle where Self == OnboardingButtonStyle {
    static func onboarding(_ kind: OnboardingButtonStyle.Kind) -> OnboardingButtonStyle {
        OnboardingButtonStyle(kind: kind)
    }
}
