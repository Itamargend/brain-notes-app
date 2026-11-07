import BrainNotesKit
import SwiftUI

/// The first-run screens, in order. `-BNScreen welcome|connect|code|ready` opens one directly.
/// Welcome and Connect are the same screen: a fresh install and a return to sign-in both offer GitHub
/// and sample notes, with no extra Continue step. The two cases stay so a launch can still open either,
/// and so leaving the device code returns to Connect rather than replaying a separate welcome.
enum OnboardingStep: Hashable {
    case welcome, connect, deviceCode, ready
}

/// The first-run screen, the device code, and Ready. `AppModel.showsOnboarding` decides whether this is
/// on screen at all; this view decides only which step. A signed-in launch never gets here.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppModel.onboardedKey) private var onboarded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep
    @State private var signIn: SignInModel

    init(start: OnboardingStep, signIn: SignInModel = SignInModel()) {
        _step = State(initialValue: start)
        _signIn = State(initialValue: signIn)
    }

    /// Ready takes over the moment the model says so, from any step.
    private var current: OnboardingStep { app.readyScreenPending ? .ready : step }

    var body: some View {
        NavigationStack {
            Group {
                switch current {
                case .welcome:
                    StartView(id: "onboarding.welcome", onSignIn: beginSignIn, onSample: beginSample)
                case .connect:
                    StartView(id: "onboarding.connect", onSignIn: beginSignIn, onSample: beginSample)
                case .deviceCode:
                    DeviceCodeView(model: signIn) {
                        signIn.cancel()
                        step = .connect
                    }
                case .ready:
                    ReadyView()
                        .onAppear { onboarded = true }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        // The asset itself: on a Mac, `Color.accentColor` can follow the system's accent setting.
        .tint(Color("AccentColor"))
        // With Reduce Motion, steps change in place: no sliding of content between them.
        .animation(reduceMotion ? nil : .smooth, value: current)
        .task {
            if step == .deviceCode, signIn.step == .start { signIn.begin(app) }
        }
        .onDisappear { signIn.cancel() }
    }

    private func beginSignIn() {
        signIn.begin(app)
        step = .deviceCode
    }

    private func beginSample() {
        Task { await app.startSampleNotes() }
    }
}

// MARK: - First screen

/// Welcome and Connect as one screen: the mark, a short list of what the app does, how sign-in works,
/// then GitHub and the sample notes. No second step and no repo picker. The test repo line stays.
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
                    FeatureRow(symbol: "doc.text", title: "Plain Markdown, in your GitHub repo")
                    FeatureRow(symbol: "arrow.triangle.2.circlepath", title: "Works offline, syncs when you’re back")
                    FeatureRow(symbol: "character.bubble", title: "Hebrew and English, side by side")
                }
                VStack(spacing: 6) {
                    Text("Notes travel straight from this device to GitHub. There is no Brain Notes server.")
                    Text("Brain Notes signs in with a one-time code. No password is stored on this device.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        } bottom: {
            VStack(spacing: 12) {
                if app.snapshot.state == .offline {
                    Label("You’re offline. Try Sample Notes now and connect later.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 2)
                        .accessibilityIdentifier("onboarding.offline")
                }
                Button(action: onSignIn) {
                    Label("Sign in with GitHub", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.onboarding(.ink))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.start")
                Button("Try with Sample Notes", action: onSample)
                    .buttonStyle(.onboarding(.quiet))
                    .accessibilityIdentifier("onboarding.sample")
                Text("This build uses \(Text(RepoTarget.allowed.slug).monospaced())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .accessibilityIdentifier("onboarding.repo")
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

// MARK: - Ready

/// What the Ready screen says, from the engine's snapshot and nothing else.
enum ReadyStatus: Equatable {
    /// Notes are on their way, and Open My Notes waits for them.
    case working(String, fraction: Double?)
    case done
    /// Sync can't finish right now. The notes open anyway: the screen must never be a dead end, and the
    /// home screen's sync pill carries on from here.
    case problem(String)

    init(snapshot: SyncSnapshot, sessionOpen: Bool) {
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
            self = .problem("This sign-in can’t reach \(RepoTarget.allowed.slug).")
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
        ReadyContent(status: ReadyStatus(snapshot: app.snapshot, sessionOpen: app.session != nil),
                     sample: app.sampleMode, noteCount: app.noteCount, lastSync: app.snapshot.lastSync) {
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
    }

    private var facts: some View {
        VStack(spacing: 0) {
            FactRow(symbol: "book.closed", title: "Repository") {
                if sample {
                    Text("Sample notes")
                } else {
                    Text(RepoTarget.allowed.slug)
                        .font(.footnote.monospaced())
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
            .accessibilityIdentifier("onboarding.progress")
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
