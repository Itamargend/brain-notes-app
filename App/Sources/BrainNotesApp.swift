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
    /// Process entry is the main thread. Isolation starts here so the preview observers are main-actor state.
    @MainActor
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
        previewRoot = Self.validatedPreviewRoot(demo: demo, arguments: arguments, environment: environment)
        #endif
    }

    #if DEBUG
    /// Demo plus one absolute directory. A relative path, `/`, or a launch that is not a demo is not a preview.
    /// The early startup log uses this same function, so it cannot accept a path the session would reject.
    static func validatedPreviewRoot(demo: Bool, arguments: [String], environment: [String: String]) -> URL? {
        guard demo else { return nil }
        let candidate: String?
        if let i = arguments.firstIndex(of: "-BNPreviewRoot"), i + 1 < arguments.count {
            candidate = arguments[i + 1]
        } else {
            candidate = environment["BN_PREVIEW_ROOT"]
        }
        return validatedPreviewRoot(demo: true, path: candidate)
    }

    static func validatedPreviewRoot(demo: Bool, path: String?) -> URL? {
        guard demo, let path, path.hasPrefix("/"), path != "/" else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: true)
    }
    #endif

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
/// Debug-only trace for a demo launch whose preview directory is absolute.
/// Writes `startup.log` only in that directory. If the scene still has no content window, opens one.
enum PreviewStartup {
    private static let seen = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Retained on the main actor. Releasing a token removes that notification observer.
    @MainActor private static var observers: [any NSObjectProtocol] = []
    @MainActor private static var holding: NSWindow?

    /// The directory observers, logging, and the fallback window share. Nil unless this launch is a demo
    /// and `LaunchOptions` accepted an absolute preview root.
    static func activeRoot(_ options: LaunchOptions = .current) -> URL? {
        LaunchOptions.validatedPreviewRoot(demo: options.demo, path: options.previewRoot?.path)
    }

    static func format(stage: String, demo: Bool, root: String?, detail: String) -> String {
        var line = "\(stage) demo=\(demo) parsedRoot=\(root ?? "nil")"
        if !detail.isEmpty { line += " \(detail)" }
        return line
    }

    /// Main actor: it stores the observer tokens. The callbacks are sendable and do not touch that storage.
    /// A window check hops to the main actor after the launch notification returns.
    @MainActor static func install() {
        guard activeRoot() != nil else { return }
        note("main")
        let center = NotificationCenter.default
        let willFinish: @Sendable (Notification) -> Void = { _ in
            note("willFinish")
        }
        let didFinish: @Sendable (Notification) -> Void = { _ in
            note("didFinish")
            Task { @MainActor in
                openWindowIfStillMissing()
            }
        }
        observers.append(center.addObserver(
            forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil, using: willFinish))
        observers.append(center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil, using: didFinish))
    }

    static func note(_ stage: String, _ detail: String = "") {
        guard let root = activeRoot() else { return }
        let fresh = seen.withLock { $0.insert(stage).inserted }
        guard fresh else { return }
        let options = LaunchOptions.current
        let line = format(stage: stage, demo: options.demo, root: root.path, detail: detail)
        NSLog("BNPreview %@", line)
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

    /// The scene had its chance. A preview with no content window gets one here.
    @MainActor static func openWindowIfStillMissing() {
        guard activeRoot() != nil else { return }
        let frames = NSApp.windows.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ",")
        let tall = NSApp.windows.filter { $0.frame.height > 100 }
        note("afterLaunch", "windows=\(NSApp.windows.count) tall=\(tall.count) frames=\(frames)")
        guard tall.isEmpty else { return }
        let options = LaunchOptions.current
        let model = AppModel()
        let router = Router(usesStack: options.phoneLayout)
        // The scene asks for 1120×720. A hosting view that publishes its ideal size replaced that:
        // the preview window measured 140×217 and clipped the onboarding. Empty sizing options
        // leave the window in charge, so the content lays out at the requested size and can still be resized.
        let contentSize = NSSize(width: options.phoneLayout ? 393 : 1120, height: options.phoneLayout ? 852 : 720)
        let minimumSize = NSSize(width: options.phoneLayout ? 320 : 720, height: options.phoneLayout ? 640 : 640)
        let host = NSHostingController(rootView:
            RootView()
                .environment(model)
                .environment(router)
                .defaultAppStorage(model.defaults)
                .brainBlackChrome()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await model.start(router: router) }
                .onAppear { note("fallback appear") })
        host.sizingOptions = []
        host.preferredContentSize = contentSize
        let window = NSWindow(contentViewController: host)
        window.title = "Brain Notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(contentSize)
        window.contentMinSize = minimumSize
        window.center()
        holding = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let shown = window.contentRect(forFrameRect: window.frame).size
        note("fallback window", "windows=\(NSApp.windows.count) content=\(Int(shown.width))x\(Int(shown.height))")
    }
}
#endif
