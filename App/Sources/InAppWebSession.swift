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
/// cannot keep a `client_secret` private, so Brain Notes uses the secretless Device Flow (`Auth.swift`), auto-copies
/// the user code, opens `verificationURI` in `ASWebAuthenticationSession`, cancels the browser programmatically the
/// moment background polling succeeds, and treats the user closing the browser early as "not yet" (polling continues
/// until approval or code expiry).
@MainActor
final class InAppWebSession {
    static let callbackScheme = "brainnotes"

    typealias StartHandler = @MainActor (_ url: URL, _ onFinish: @escaping @MainActor (URL?) -> Void) -> (@MainActor () -> Void)

    private let startImpl: StartHandler
    private var activeCancel: (@MainActor () -> Void)?
    private(set) var isPresenting = false
    private(set) var openedURLs: [URL] = []
    private(set) var cancelCount = 0

    init(start: @escaping StartHandler) {
        self.startImpl = start
    }

    /// Live `ASWebAuthenticationSession` presenter for iOS and macOS.
    static func system() -> InAppWebSession {
        let context = WebPresentationAnchorProvider()
        return InAppWebSession { url, onFinish in
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: InAppWebSession.callbackScheme
            ) { callbackURL, _ in
                Task { @MainActor in
                    // User closing the browser early (canceledLogin) or finishing an optional `brainnotes://` callback
                    // both pass through here; callers treat `nil` as "not yet" rather than an error.
                    onFinish(callbackURL)
                }
            }
            authSession.presentationContextProvider = context
            // Ephemeral browser session on every sheet so an ambient Safari GitHub cookie cannot silently sign in or install onto another account.
            authSession.prefersEphemeralWebBrowserSession = true
            _ = authSession.start()
            return { @MainActor in
                authSession.cancel()
            }
        }
    }

    /// Inert presenter for demo launches and automated tests (records opened URLs and cancellations with no network or window).
    static func inert() -> InAppWebSession {
        InAppWebSession { _, _ in
            return {}
        }
    }

    /// Opens `url` in the in-app browser, cancelling any earlier sheet first.
    func open(_ url: URL, onFinish: @escaping @MainActor (URL?) -> Void = { _ in }) {
        cancel()
        openedURLs.append(url)
        isPresenting = true
        activeCancel = startImpl(url) { [weak self] callbackURL in
            guard let self else { return }
            self.activeCancel = nil
            self.isPresenting = false
            onFinish(callbackURL)
        }
    }

    /// Programmatically closes the in-app browser when background polling sees approval or a newly added repository.
    func cancel() {
        guard let stop = activeCancel else { return }
        activeCancel = nil
        isPresenting = false
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
