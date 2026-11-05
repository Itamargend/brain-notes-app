import BrainNotesKit
import SwiftUI

@main
struct BrainNotesApp: App {
    @State private var app = AppModel()
    @State private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BrainChrome.applySystemAppearances()
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
        .commands { FormatCommands() }
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
            .defaultAppStorage(app.defaults)
            .brainBlackChrome()
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
    /// `-BNScreen <name>`: folders, list, note, edit, live, search, compose, inbox, attention, conflict, settings,
    /// or an onboarding screen: welcome, connect (also signin), code, ready. An onboarding screen implies
    /// demo mode, so that opening `code` can never start a real device flow. So does `editor-spike`, the
    /// Hebrew and English test note open in the editor, so that trying the bar can't touch real notes.
    var screen: String?
    /// `-BNHebrew`: open the Hebrew note. With an onboarding screen: right-to-left layout.
    var hebrew = false
    /// `-BNPhoneLayout`: the iPhone's NavigationStack layout, in a phone-sized Mac window.
    var phoneLayout = false

    init() {}

    init(arguments: [String], environment: [String: String]) {
        if let i = arguments.firstIndex(of: "-BNScreen"), i + 1 < arguments.count { screen = arguments[i + 1] }
        demo = arguments.contains("-BNDemoFixtures") || environment["BN_DEMO"] == "1" || onboardingStep != nil || isEditorSpike
        hebrew = arguments.contains("-BNHebrew")
        phoneLayout = arguments.contains("-BNPhoneLayout")
    }

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)

    var isEditorSpike: Bool { screen == "editor-spike" }

    /// The onboarding screen `-BNScreen` asks for, if any.
    var onboardingStep: OnboardingStep? {
        switch screen {
        case "welcome": .welcome
        case "connect", "signin": .connect
        case "code": .deviceCode
        case "ready": .ready
        default: nil
        }
    }
}
