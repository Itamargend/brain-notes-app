import BrainNotesKit
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Device flow: the code, big, with copy and open buttons. No secret anywhere.
@MainActor @Observable
final class SignInModel {
    enum Step: Equatable {
        case start
        case requesting
        case waiting(DeviceCode)
        case failed(String)
    }

    private(set) var step: Step
    /// When the code on screen runs out, from its `expiresIn`.
    private(set) var expiresAt: Date?
    private var waiter: Task<Void, Never>?

    init(step: Step = .start, expiresAt: Date? = nil) {
        self.step = step
        self.expiresAt = expiresAt
    }

    func begin(_ app: AppModel) {
        guard let s = app.session else { return }
        // "Get a new code" can come while the old code is still being polled.
        waiter?.cancel()
        waiter = nil
        if s.isDemo {
            // Screenshots and UI tests: the screen with a sample code, nothing behind it.
            show(DeviceCode(deviceCode: "demo", userCode: "WDJB-MJHT",
                            verificationURI: URL(string: "https://github.com/login/device")!, interval: 5, expiresIn: 900))
            return
        }
        guard let flow = s.deviceFlow() else { return }
        step = .requesting
        expiresAt = nil
        waiter = Task {
            do {
                let code = try await flow.start()
                try Task.checkCancellation()
                show(code)
                let pair = try await flow.waitForApproval(code)
                try Task.checkCancellation()
                // The code is used up: off the Mac's pasteboard, if it is still the last thing copied.
                DeviceCodeClipboard.forget(code.userCode)
                // This screen goes away now, and cancels what it is waiting for when it does.
                // The first sync must not be part of that.
                waiter = nil
                Task { await app.signedIn(pair: pair) }
            } catch {
                // Cancelled, or replaced by a newer run that owns the screen now.
                guard !Task.isCancelled else { return }
                switch error {
                case DeviceFlowError.denied:
                    step = .failed("You declined on GitHub. You can try again.")
                case DeviceFlowError.expired:
                    step = .failed("The code ran out. You can get a new one.")
                default:
                    step = .failed("Couldn't reach GitHub. Check the connection and try again.")
                }
            }
        }
    }

    func cancel() {
        waiter?.cancel()
        waiter = nil
        step = .start
        expiresAt = nil
    }

    private func show(_ code: DeviceCode) {
        expiresAt = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        step = .waiting(code)
    }

    /// Whole seconds until the code runs out, rounded up, so 0 means it has.
    func secondsLeft(at date: Date) -> Int {
        guard let expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSince(date).rounded(.up)))
    }
}

/// The plain sign-in of the Settings sheet, for a user whose sign-in stopped working. First-time users
/// get `OnboardingFlow`. Both show the same code screen.
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SignInModel

    init(model: SignInModel = SignInModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if model.step == .start {
                start
            } else {
                DeviceCodeView(model: model) {
                    model.cancel()
                    app.showSignIn = false
                }
            }
        }
        .tint(Color("AccentColor"))
        .onDisappear { model.cancel() }
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
            Text("Your Markdown notes from GitHub, on this device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Sign in with GitHub") { model.begin(app) }
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

/// The device code: big, with copy and open buttons, a quiet countdown, and a new code when it runs out.
/// Shared by onboarding and the Settings sheet. The state is all in `SignInModel`.
struct DeviceCodeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    /// The code grows with the text size; it still shrinks to fit one line.
    @ScaledMetric(relativeTo: .largeTitle) private var codeSize: CGFloat = 44
    let model: SignInModel
    let onCancel: () -> Void

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: onCancel)
                        .accessibilityIdentifier("signin.cancel")
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .start, .requesting:
            ProgressView("Asking GitHub for a code")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .waiting(code):
            // GitHub's answer can come a few seconds after the time is up, as it is polled.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = model.secondsLeft(at: context.date)
                if seconds > 0 {
                    waiting(code, secondsLeft: seconds)
                } else {
                    ended("The code ran out. You can get a new one.")
                }
            }
        case let .failed(message):
            ended(message)
        }
    }

    private func waiting(_ code: DeviceCode, secondsLeft: Int) -> some View {
        OnboardingPage(id: "onboarding.code") {
            VStack(spacing: 0) {
                Text("Enter this code\non GitHub")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("GitHub will ask for this code to confirm it’s you.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                codeCard(code)
                    .padding(.top, 26)
                VStack(alignment: .leading, spacing: 14) {
                    CodeStep(number: 1, text: "Open **github.com/login/device**. The code is copied for you.")
                    CodeStep(number: 2, text: "Paste the code and tap **Authorize**.")
                    CodeStep(number: 3, text: "Come back here. Brain Notes continues on its own.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
                Text("GitHub only grants access to the repository you choose. Your password never touches Brain Notes, and you can revoke access anytime at github.com/settings/applications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .accessibilityIdentifier("signin.permissions")
            }
        } bottom: {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for you to approve")
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    Text(verbatim: String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60))
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waiting for you to approve. The code runs out in \(Duration.seconds(secondsLeft).formatted(.units(allowed: [.minutes, .seconds], width: .wide))).")
                Button {
                    copy(code.userCode)
                    openURL(code.verificationURI)
                } label: {
                    Label("Open github.com/login/device", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.onboarding(.accent))
                .accessibilityIdentifier("signin.open")
            }
        }
    }

    private func codeCard(_ code: DeviceCode) -> some View {
        VStack(spacing: 12) {
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
                copy(code.userCode)
            } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("signin.copy")
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

    /// The code is over (it ran out, or the sign-in failed): what happened, and a new one.
    private func ended(_ message: String) -> some View {
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
            Button("Get a new code") { model.begin(app) }
                .buttonStyle(.onboarding(.accent))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.newCode")
        }
    }

    private func copy(_ text: String) {
        DeviceCodeClipboard.copy(text, until: model.expiresAt ?? Date().addingTimeInterval(900))
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
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
    @State private var confirmWipe = false
    @State private var paused = false

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
                    Text("Repository")
                } footer: {
                    Text("Sample notes live on this device only. Connecting GitHub removes them, and anything typed in them.")
                }
            } else {
                Section("Repository") {
                    LabeledContent("Repo", value: app.session?.repo.slug ?? "")
                        .accessibilityIdentifier("settings.repo")
                }
            }
            Section("Sync") {
                Toggle("Pause sync", isOn: $paused)
                    .accessibilityIdentifier("settings.pause")
                    .onChange(of: paused) { _, value in
                        Task { await app.setPaused(value) }
                    }
                LabeledContent("Last sync") {
                    if let date = app.snapshot.lastSync {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet")
                    }
                }
                .accessibilityIdentifier("settings.lastSync")
                LabeledContent("Not yet on GitHub", value: "\(app.snapshot.unsynced)")
                    .accessibilityIdentifier("settings.unsynced")
                Button("Sync now") {
                    Task { await app.syncNow() }
                }
                .accessibilityIdentifier("settings.syncNow")
                if case .signedOut = app.snapshot.state {
                    Button("Sign in again") { app.showSignIn = true }
                        .accessibilityIdentifier("settings.signIn")
                }
            }
            if !app.sampleMode {
                Section {
                    Button("Sign out and wipe", role: .destructive) {
                        confirmWipe = true
                    }
                    .accessibilityIdentifier("settings.wipe")
                } footer: {
                    Text(app.snapshot.unsynced > 0
                         ? "\(app.snapshot.unsynced) notes have changes that are not on GitHub yet. Wiping deletes them from this device."
                         : "Removes the token and every note from this device. GitHub keeps your notes.")
                }
            }
            Section {
                LabeledContent("Where notes live", value: app.sampleMode ? "This device only" : "This device + GitHub")
                    .accessibilityIdentifier("settings.storage")
                LabeledContent("Credentials", value: app.sampleMode ? "None" : "Device Keychain")
                    .accessibilityIdentifier("settings.credentials")
                LabeledContent("Servers & analytics", value: "None")
                    .accessibilityIdentifier("settings.analytics")
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
                Text("Your notes are plain .md files. Brain Notes has no server, collects no analytics, and only talks to github.com and api.github.com.")
            }
        }
        .formStyle(.grouped)
        .brainBlackList()
        .navigationTitle("Settings")
        .task {
            paused = await app.session?.engine.isUserPaused ?? false
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
