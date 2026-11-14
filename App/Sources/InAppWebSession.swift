import AuthenticationServices
import Foundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// In-app browser session (`ASWebAuthenticationSession` on both iOS and macOS) used during GitHub Device Flow
/// verification, GitHub App repository selection (`installations/new`), and the "Create my brain" helper.
///
/// Why Device Flow + `ASWebAuthenticationSession` instead of GitHub's Web Application Flow:
/// GitHub's Web Application Flow for GitHub Apps still requires `client_secret` at the code exchange even when PKCE is
/// sent (verified against GitHub's documentation and 2025-07-14 PKCE changelog). A native mobile or desktop binary
/// cannot keep a `client_secret` private, so Brain Notes uses the secretless Device Flow (`Auth.swift`), shows the user
/// code first, copies it and opens `verificationURI` in `ASWebAuthenticationSession` when the user taps the button,
/// cancels the browser programmatically the moment polling succeeds, and treats the user closing the browser early as
/// "not yet" (polling continues until approval or code expiry).
///
/// The sheet shares Safari's cookies and saved passwords by default (`ephemeral: false`), so someone already signed in to
/// GitHub in Safari does not sign in again. `ephemeral: true` is the private window that "Use a different account" asks for.
@MainActor
final class InAppWebSession {
    static let callbackScheme = "brainnotes"

    typealias StartHandler = @MainActor (_ url: URL, _ ephemeral: Bool, _ onFinish: @escaping @MainActor (URL?) -> Void) -> (@MainActor () -> Void)

    private let startImpl: StartHandler
    private var activeCancel: (@MainActor () -> Void)?
    /// Bumped by every `open` and by every programmatic `cancel`. Only a completion that carries the current value
    /// may change this object's state or call its `onFinish`: the one for a sheet that was replaced or cancelled
    /// arrives later, and must not wipe the handle of the sheet that replaced it.
    private var generation = 0
    private(set) var isPresenting = false
    private(set) var openedURLs: [URL] = []
    /// For each entry of `openedURLs`: whether that sheet was a private window.
    private(set) var openedEphemeral: [Bool] = []
    private(set) var cancelCount = 0

    init(start: @escaping StartHandler) {
        self.startImpl = start
    }

    /// Builds the session completion in a `nonisolated` scope so macOS (`SafariLaunchAgent` XPC queue) and iOS
    /// background callbacks never hit a `@MainActor` isolation trap before hopping to the main actor.
    nonisolated static func makeCompletion(
        onFinish: @escaping @MainActor (URL?) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, _ in
            Task { @MainActor in
                // User closing the browser early (canceledLogin) or finishing an optional `brainnotes://` callback
                // both pass through here; callers treat `nil` as "not yet" rather than an error.
                onFinish(callbackURL)
            }
        }
    }

    /// Live `ASWebAuthenticationSession` presenter for iOS and macOS.
    static func system() -> InAppWebSession {
        let context = WebPresentationAnchorProvider()
        return InAppWebSession { url, ephemeral, onFinish in
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: InAppWebSession.callbackScheme,
                completionHandler: Self.makeCompletion(onFinish: onFinish)
            )
            authSession.presentationContextProvider = context
            // Shared with Safari by default (saved passwords, an existing GitHub sign-in). Only "Use a different
            // account" asks for a private window, so that Safari's GitHub account is not offered again.
            authSession.prefersEphemeralWebBrowserSession = ephemeral
            _ = authSession.start()
            return { @MainActor in
                authSession.cancel()
            }
        }
    }

    /// Inert presenter for demo launches and automated tests (records opened URLs and cancellations with no network or window).
    static func inert() -> InAppWebSession {
        InAppWebSession { _, _, _ in
            return {}
        }
    }

    /// Opens `url` in the in-app browser, cancelling any earlier sheet first. `onFinish` runs when the user closes
    /// this sheet or it ends with a callback URL; it does not run for a sheet that `cancel()` or a newer `open` closed.
    func open(_ url: URL, ephemeral: Bool = false, onFinish: @escaping @MainActor (URL?) -> Void = { _ in }) {
        cancel()
        generation += 1
        let mine = generation
        openedURLs.append(url)
        openedEphemeral.append(ephemeral)
        isPresenting = true
        activeCancel = startImpl(url, ephemeral) { [weak self] callbackURL in
            guard let self, self.generation == mine else { return }
            self.activeCancel = nil
            self.isPresenting = false
            onFinish(callbackURL)
        }
    }

    /// Programmatically closes the in-app browser when polling sees approval or a newly added repository.
    func cancel() {
        guard let stop = activeCancel else { return }
        activeCancel = nil
        isPresenting = false
        generation += 1
        cancelCount += 1
        stop()
    }
}

@MainActor
private final class WebPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return key
        }
        if let any = scenes.flatMap(\.windows).first {
            return any
        }
        if let scene = scenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        return ASPresentationAnchor()
        #else
        return NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
