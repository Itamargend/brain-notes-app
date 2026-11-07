import BrainNotesKit
import SwiftUI

#if os(macOS)
import AppKit
#endif
#if os(macOS) && DEBUG
import os
#endif

#if os(macOS) && DEBUG
/// Debug Mac entry. A preview launch records each stage, then calls the SwiftUI app.
/// Every other launch only forwards to that app.
@main
enum BrainNotesMain {
    static func main() {
        PreviewStartup.install()
        BrainNotesApp.main()
    }
}
#endif

#if os(macOS) && DEBUG
// Entry is `BrainNotesMain`.
#else
@main
#endif
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
        #if os(macOS) && DEBUG
        PreviewStartup.note("app init")
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        #if DEBUG
        noteScene(macWindow)
        #else
        macWindow
        #endif
        #else
        WindowGroup {
            content
        }
        #endif
    }

    #if os(macOS)
    /// One expression. `SceneBuilder` rejects an `if`. A demo launch asks for `.disabled` restoration;
    /// a normal launch keeps `.automatic`. That modifier does not by itself decide whether AppKit logs a restore.
    private var macWindow: some Scene {
        Window("Brain Notes", id: "main") {
            content
        }
        .defaultSize(width: LaunchOptions.current.phoneLayout ? 393 : 1120, height: LaunchOptions.current.phoneLayout ? 852 : 720)
        .commands { FormatCommands() }
        .restorationBehavior(LaunchOptions.current.demo ? .disabled : .automatic)
        .defaultLaunchBehavior(.presented)
    }

    #if DEBUG
    private func noteScene<S: Scene>(_ scene: S) -> S {
        PreviewStartup.note("body", "restore=\(LaunchOptions.current.demo ? "disabled" : "automatic")")
        return scene
    }
    #endif
    #endif

    private var content: some View {
        RootView()
            .environment(app)
            .environment(router)
            .defaultAppStorage(app.defaults)
            .brainBlackChrome()
            .task { await app.start(router: router) }
            #if os(macOS) && DEBUG
            .onAppear { PreviewStartup.note("scene appear") }
            #endif
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

#if os(macOS) && DEBUG
/// Debug-only trace for a `-BNPreviewRoot` launch. Writes `startup.log` in that directory and
/// nothing anywhere else. If the SwiftUI scene still has no content window after launch, opens one.
enum PreviewStartup {
    private static let seen = OSAllocatedUnfairLock(initialState: Set<String>())
    @MainActor private static var holding: NSWindow?

    /// The path after `-BNPreviewRoot`, read from argv so a parse miss still leaves a file.
    static func rawRoot(arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: "-BNPreviewRoot"), i + 1 < arguments.count else { return nil }
        let value = arguments[i + 1]
        if value.isEmpty || value.hasPrefix("-") { return nil }
        return value
    }

    static func format(stage: String, demo: Bool, root: String?, detail: String) -> String {
        var line = "\(stage) demo=\(demo) parsedRoot=\(root ?? "nil")"
        if !detail.isEmpty { line += " \(detail)" }
        return line
    }

    static func install() {
        guard rawRoot() != nil else { return }
        note("main")
        NotificationCenter.default.addObserver(
            PreviewLaunchObserver.shared,
            selector: #selector(PreviewLaunchObserver.willFinish),
            name: NSApplication.willFinishLaunchingNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            PreviewLaunchObserver.shared,
            selector: #selector(PreviewLaunchObserver.didFinish),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil)
    }

    static func note(_ stage: String, _ detail: String = "") {
        guard rawRoot() != nil else { return }
        let fresh = seen.withLock { $0.insert(stage).inserted }
        guard fresh else { return }
        let options = LaunchOptions.current
        let line = format(stage: stage, demo: options.demo, root: options.previewRoot?.path, detail: detail)
        NSLog("BNPreview %@", line)
        guard let path = rawRoot() else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("startup.log")
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The scene had its chance. A preview with no content window gets one here. No Keychain and no live folder:
    /// this runs only after `-BNPreviewRoot`, and the model is the demo model.
    @MainActor static func openWindowIfStillMissing() {
        let frames = NSApp.windows.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ",")
        let tall = NSApp.windows.filter { $0.frame.height > 100 }
        note("afterLaunch", "windows=\(NSApp.windows.count) tall=\(tall.count) frames=\(frames)")
        guard tall.isEmpty, LaunchOptions.current.demo, LaunchOptions.current.previewRoot != nil else { return }
        let options = LaunchOptions.current
        let model = AppModel()
        let router = Router(usesStack: options.phoneLayout)
        let host = NSHostingController(rootView:
            RootView()
                .environment(model)
                .environment(router)
                .defaultAppStorage(model.defaults)
                .brainBlackChrome()
                .task { await model.start(router: router) }
                .onAppear { note("fallback appear") })
        let window = NSWindow(contentViewController: host)
        window.title = "Brain Notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: options.phoneLayout ? 393 : 1120, height: options.phoneLayout ? 852 : 720))
        window.center()
        holding = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        note("fallback window", "windows=\(NSApp.windows.count)")
    }
}

final class PreviewLaunchObserver: NSObject {
    static let shared = PreviewLaunchObserver()

    @objc nonisolated func willFinish() {
        PreviewStartup.note("willFinish")
    }

    /// Posted on the main thread at the end of launch. The window check waits until that returns,
    /// so a scene window created during launch is already in `NSApp.windows`.
    @objc nonisolated func didFinish() {
        PreviewStartup.note("didFinish")
        Task { @MainActor in
            PreviewStartup.openWindowIfStillMissing()
        }
    }
}
#endif
