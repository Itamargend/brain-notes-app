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

    private(set) var step: Step = .start
    private var waiter: Task<Void, Never>?

    func begin(_ app: AppModel) {
        guard let s = app.session else { return }
        if s.isDemo {
            // Screenshots and UI tests: the screen with a sample code, nothing behind it.
            step = .waiting(DeviceCode(deviceCode: "demo", userCode: "WDJB-MJHT",
                                       verificationURI: URL(string: "https://github.com/login/device")!, interval: 5, expiresIn: 900))
            return
        }
        guard let flow = s.deviceFlow() else { return }
        step = .requesting
        waiter?.cancel()
        waiter = Task {
            do {
                let code = try await flow.start()
                step = .waiting(code)
                let pair = try await flow.waitForApproval(code)
                await app.signedIn(pair: pair)
            } catch is CancellationError {
                step = .start
            } catch DeviceFlowError.denied {
                step = .failed("You declined on GitHub. You can try again.")
            } catch DeviceFlowError.expired {
                step = .failed("The code ran out. You can get a new one.")
            } catch {
                step = .failed("Couldn't reach GitHub. Check the connection and try again.")
            }
        }
    }

    func cancel() {
        waiter?.cancel()
        waiter = nil
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var model: SignInModel

    init(model: SignInModel = SignInModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Brain Notes")
                .font(.largeTitle.bold())
            content
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 460)
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .start:
            Text("Your Markdown notes from GitHub, on this device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            signInButton
        case .requesting:
            ProgressView("Asking GitHub for a code")
        case let .waiting(code):
            Text("Enter this code on GitHub")
                .foregroundStyle(.secondary)
            Text(code.userCode)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("signin.code")
            HStack(spacing: 12) {
                Button {
                    copy(code.userCode)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("signin.copy")
                Button {
                    openURL(code.verificationURI)
                } label: {
                    Label("Open github.com/login/device", systemImage: "safari")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("signin.open")
            }
            ProgressView("Waiting for you to approve")
                .controlSize(.small)
        case let .failed(message):
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            signInButton
        }
    }

    private var signInButton: some View {
        Button {
            model.begin(app)
        } label: {
            Text("Sign in with GitHub")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("signin.start")
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmWipe = false
    @State private var paused = false

    var body: some View {
        Form {
            Section("Repository") {
                LabeledContent("Repo", value: app.session?.repo.slug ?? "")
                    .accessibilityIdentifier("settings.repo")
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
        .formStyle(.grouped)
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
