import BrainNotesKit
import SwiftUI

/// The first-run screens, in order. `-BNScreen welcome|connect|code|choose` opens one directly.
/// Welcome and Connect are the same screen: a fresh install and a return to sign-in both offer GitHub
/// and sample notes, with no extra Continue step. The two cases stay so a launch can still open either,
/// and so leaving the device code returns to Connect rather than replaying a separate welcome.
enum OnboardingStep: Hashable {
    case welcome, connect, deviceCode, chooseNotes
}

/// The first-run screen, the device code (which, once signed in, waits on GitHub's access page), and choosing notes
/// when GitHub granted several or none. There is no confirm step and no ready screen: exactly one granted private
/// repository goes straight to the notes. `AppModel.showsOnboarding` decides whether this is on screen at all;
/// transitions use default `NavigationStack` pushes with Reduce Motion left to the system.
struct OnboardingFlow: View {
    private enum Destination: Hashable {
        case deviceCode
        case chooseNotes
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
        }
        _path = State(initialValue: startingPath)
        _signIn = State(initialValue: signIn)
    }

    /// The model sets this once notes open (or the sample notes do), and `signOutAndWipe` sets it too. Either store
    /// counts: `@AppStorage` follows the view's defaults, and the model writes its own.
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
        .onChange(of: app.reSignInError) { _, err in
            // A refusal that came from this screen's own sign-in is shown on the code screen, with its choices.
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
        case .chooseNotes:
            ChooseNotesView()
                .navigationBarBackButtonHidden(true)
        }
    }

    /// The code screen stays on through sign-in and the wait on GitHub; choosing notes is pushed only when GitHub
    /// granted several repositories, "All repositories", or none. One granted private repository opens the notes,
    /// which takes this whole flow off screen.
    private func syncPathWithModel() {
        if app.phase == .needsRepoSelection, path.last != .chooseNotes {
            path.append(.chooseNotes)
        }
    }

    /// Cancel on the code screen, also while it waits on GitHub: the page closes, and a first sign-in that was
    /// already saved is forgotten, so this is never a dead end.
    private func cancelSignIn() {
        app.webSession.cancel()
        signIn.cancel()
        initialStep = .connect
        path = []
        Task { await app.cancelFirstTimeSignIn() }
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

    /// Nothing granted yet: one line, Choose repositories on GitHub, and Create a new private brain. No extra chrome.
    private func emptySelectionScreen(isTruncated: Bool) -> some View {
        OnboardingPage(id: "onboarding.choose") {
            VStack(spacing: 14) {
                signedInBanner
                Text("Choose your notes")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    .accessibilityIdentifier("onboarding.access.title")
                Text("On GitHub, choose ‘Only select repositories’ and pick your notes.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.installHint")
                if isTruncated {
                    Text(DiscoveryResult.truncatedMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("onboarding.truncatedNotice")
                }
                if app.awaitingInstallAfterCreate {
                    Text("Made your new notes? Now choose them on GitHub.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
                    Label("Choose repositories on GitHub", systemImage: "arrow.up.forward.app")
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
                Label("Choose repositories on GitHub", systemImage: "arrow.up.forward.app")
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
                Label("Made your new notes? Now tap Choose repositories on GitHub and pick them.", systemImage: "checkmark.circle")
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
