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
        // A `Window` scene does not open by itself. A preview launch then has only menu-bar windows,
        // the content `.task` never runs, and the preview folder stays empty. Tests build their own windows.
        .defaultLaunchBehavior(.presented)
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
    /// `-BNScreen <name>`: folders, list, note, edit, live, table, search, compose, inbox, attention, conflict, settings,
    /// or an onboarding screen: welcome, connect (also signin), code, ready. An onboarding screen implies
    /// demo mode, so that opening `code` can never start a real device flow. So does `editor-spike`, the
    /// Hebrew and English test note open in the editor, so that trying the bar can't touch real notes.
    var screen: String?
    /// `-BNHebrew`: open the Hebrew note. With an onboarding screen: right-to-left layout.
    var hebrew = false
    /// `-BNPhoneLayout`: the iPhone's NavigationStack layout, in a phone-sized Mac window.
    var phoneLayout = false
    /// Debug-only isolated demo directory. Ignored unless this launch is already a demo, and ignored in Release.
    /// Double-click with no arguments is the normal app: live notes stay in Application Support/Brain, and the
    /// Keychain is the live one. A demo launch without this still uses Application Support/BrainDemo, which is
    /// separate from Brain but is the shared sample folder and is recreated. With this set, files go only under
    /// `<root>/BrainDemo/` and settings go to the preview defaults suite, not the shared demo suite.
    ///
    /// Safe preview from a Debug build, synthetic notes, no live GitHub and no Keychain:
    /// `open BrainNotes.app --args -BNDemoFixtures -BNScreen welcome -BNPreviewRoot "$HOME/Desktop/bn-preview"`
    var previewRoot: URL?

    init() {}

    init(arguments: [String], environment: [String: String]) {
        if let i = arguments.firstIndex(of: "-BNScreen"), i + 1 < arguments.count { screen = arguments[i + 1] }
        demo = arguments.contains("-BNDemoFixtures") || environment["BN_DEMO"] == "1" || onboardingStep != nil || isEditorSpike
        hebrew = arguments.contains("-BNHebrew")
        phoneLayout = arguments.contains("-BNPhoneLayout")
        #if DEBUG
        if demo {
            if let i = arguments.firstIndex(of: "-BNPreviewRoot"), i + 1 < arguments.count, !arguments[i + 1].isEmpty {
                previewRoot = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            } else if let path = environment["BN_PREVIEW_ROOT"], !path.isEmpty {
                previewRoot = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        #endif
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
