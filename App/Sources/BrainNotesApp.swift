import BrainNotesKit
import SwiftUI

@main
struct BrainNotesApp: App {
    @State private var app = AppModel()
    @State private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let options = LaunchOptions.current
        #if os(iOS)
        _router = State(initialValue: Router(usesStack: true))
        #else
        _router = State(initialValue: Router(usesStack: options.phoneLayout))
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        Window("Brain Notes", id: "main") {
            content
        }
        .defaultSize(width: LaunchOptions.current.phoneLayout ? 393 : 1120, height: LaunchOptions.current.phoneLayout ? 852 : 720)
        #else
        WindowGroup {
            content
        }
        #endif
    }

    private var content: some View {
        RootView()
            .environment(app)
            .environment(router)
            .task { await app.start(router: router) }
            .onChange(of: scenePhase) { _, phase in
                app.scenePhaseChanged(phase)
            }
            // Plan P2-4: note text must not show in the app switcher snapshot.
            .overlay { if shouldBlur { PrivacyCover() } }
    }

    private var shouldBlur: Bool {
        #if os(iOS)
        scenePhase != .active
        #else
        scenePhase == .background
        #endif
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Image(systemName: "note.text")
                .font(.largeTitle)
                .foregroundStyle(.tint)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("privacy.cover")
    }
}

/// Launch arguments for demo and test mode. `ProcessInfo` only: these never persist.
struct LaunchOptions: Sendable {
    var demo = false
    /// `-BNScreen <name>`: folders, list, note, edit, search, compose, inbox, attention, conflict, signin, settings.
    var screen: String?
    /// `-BNHebrew`: open the Hebrew note.
    var hebrew = false
    /// `-BNPhoneLayout`: the iPhone's NavigationStack layout, in a phone-sized Mac window.
    var phoneLayout = false

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        let args = ProcessInfo.processInfo.arguments
        o.demo = args.contains("-BNDemoFixtures") || ProcessInfo.processInfo.environment["BN_DEMO"] == "1"
        if let i = args.firstIndex(of: "-BNScreen"), i + 1 < args.count { o.screen = args[i + 1] }
        o.hebrew = args.contains("-BNHebrew")
        o.phoneLayout = args.contains("-BNPhoneLayout")
        return o
    }()
}
