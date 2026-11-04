import AppKit
import BrainNotesKit
import SwiftUI
import Vision
import XCTest
@testable import BrainNotes

/// Runs inside the app, so it needs no UI automation permission. Each test shows real screens in a real
/// window against the demo session (fake GitHub, no network, no Keychain), checks the state behind them
/// and attaches a picture. The XCUITest walk in `App/UITests` adds real clicks where automation is enabled.
@MainActor
final class ScreenWalkTests: XCTestCase {
    private var window: NSWindow!
    private var windowSize = NSSize(width: 1120, height: 720)
    private var app: AppModel!
    private var router: Router!
    private var session: BrainSession!
    private var folder: URL!

    /// For the onboarding tests: what the device keeps across launches, away from the real thing.
    private var environment: OnboardingEnvironment?

    /// A fresh demo session in a throwaway folder (the host app's own demo session lives elsewhere).
    private func start(stack: Bool = false, dark: Bool = false) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bn-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = Bundle.main.url(forResource: "demo-brain", withExtension: nil).map(DemoBrain.load) ?? []
        XCTAssertGreaterThan(fixtures.count, 40, "the demo set is bundled")
        session = try await BrainSession.demo(fixtures: fixtures, baseFolder: folder)
        router = Router(usesStack: stack)
        app = AppModel()
        await app.start(session: session, router: router)
        makeWindow(stack: stack, dark: dark)
    }

    private func makeWindow(stack: Bool, dark: Bool) {
        window?.orderOut(nil)
        windowSize = stack ? NSSize(width: 393, height: 852) : NSSize(width: 1120, height: 720)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: windowSize),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .unifiedTitleAndToolbar], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.orderFrontRegardless()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        if let session { await session.engine.stop() }
        if let live = app?.session, live !== session { await live.engine.stop() }
        session = nil
        app = nil
        router = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        environment?.cleanUp()
        environment = nil
        buildAccessibilityTree(false)
    }

    private func show(_ view: some View) {
        let host = NSHostingView(rootView: AnyView(view.environment(app).environment(router).defaultAppStorage(app.defaults).tint(Color.accentColor)))
        // The window keeps its size whatever the screen's content wants.
        host.sizingOptions = []
        window.contentView = host
    }

    /// The real text view of the editor on screen.
    private func editorTextView() -> NSTextView? {
        func find(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView, t.isEditable { return t }
            for s in v.subviews {
                if let t = find(s) { return t }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private func settle(_ ms: Int = 500) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// `.logs/shots/onboarding/` in this repo (git-ignored), for the onboarding pictures.
    private static let onboardingShots = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".logs/shots/onboarding", isDirectory: true)

    /// The window as drawn, title bar and toolbar included.
    private func drawWindow() async -> NSBitmapImageRep? {
        await settle()
        // Navigation can shrink a test window to its content; the real windows are sized by the system.
        window.setContentSize(windowSize)
        await settle(150)
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// A picture of the window, attached to the test result.
    /// With `saveAs`, also written to `.logs/shots/onboarding/<saveAs>.png`, or to the folder given.
    private func picture(_ name: String, saveAs: String? = nil, in folder: URL = ScreenWalkTests.onboardingShots) async {
        guard let rep = await drawWindow() else { return XCTFail("no bitmap") }
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let saveAs {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: folder.appendingPathComponent("\(saveAs).png"))
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: Mac layout

    func testHomeListAndNote() async throws {
        try await start()
        show(RootView())
        await picture("mac-home")
        XCTAssertEqual(app.phase, .ready)
        XCTAssertTrue(app.folders.contains { $0.name == "projects" })
        XCTAssertTrue(app.folders.contains { $0.name == "עברית" })
        XCTAssertFalse(app.folders.contains { $0.name.hasPrefix("_") }, "Inbox has its own row; _trash is hidden")
        XCTAssertTrue(app.rootNotes.contains { $0.path == "todo.md" })
        XCTAssertEqual(app.inboxCount, 6, "4 fixtures and 2 staged conflict copies")
        XCTAssertEqual(app.snapshot.attention, 2)
        XCTAssertEqual(app.status(of: "todo.md"), .savedOnDevice)

        router.open(.folder("projects"))
        await picture("mac-list")
        router.open(.note("projects/garden-sensor.md"))
        await picture("mac-note")
        router.open(.note("projects/brain-notes-app.md"))
        await picture("mac-note-with-banner")
        XCTAssertEqual(session.store.journal.attention(forPath: "projects/brain-notes-app.md").count, 1)
    }

    func testHebrewNote() async throws {
        try await start()
        show(RootView())
        router.open(.folder("עברית"))
        router.open(.note("עברית/סיכום-פגישה-עם-נועה.md"))
        await picture("mac-hebrew-note")
        let blocks = MarkdownBlock.parse(try XCTUnwrap(try session.store.read("עברית/סיכום-פגישה-עם-נועה.md")))
        XCTAssertTrue(blocks.allSatisfy(\.isRightToLeft))
    }

    func testDarkMode() async throws {
        try await start(dark: true)
        show(RootView())
        router.open(.folder("עברית"))
        router.open(.note("עברית/סיכום-פגישה-עם-נועה.md"))
        await picture("mac-dark")
    }

    func testEditorShowsHebrewAndEnglish() async throws {
        try await start()
        show(NoteScreen(path: "עברית/סיכום-פגישה-עם-נועה.md", startEditing: true))
        await picture("mac-editor-hebrew")
        show(NoteScreen(path: "projects/garden-sensor.md", startEditing: true))
        await picture("mac-editor-english")
        // Opening a note in the editor must not change it.
        XCTAssertEqual(session.store.status(of: "projects/garden-sensor.md"), .synced)
    }

    /// The bug this guards against: an editor created before the note loaded stayed empty, and whatever
    /// was typed into it replaced the note.
    func testEditorOpensWithTheNoteAndNeverEmpty() async throws {
        try await start()
        let path = "projects/garden-sensor.md"
        let original = try XCTUnwrap(try session.store.read(path))
        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("the editor with the note's text") { self.editorTextView()?.string == original }
        XCTAssertEqual(session.store.status(of: path), .synced, "opening changes nothing")
    }

    /// Types through the real text view: the delegate, the autosave, the file, the status, the flush.
    func testTypingInTheRealEditorSavesAndSyncs() async throws {
        try await start()
        let path = "projects/garden-sensor.md"
        let original = try XCTUnwrap(try session.store.read(path))
        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("editor") { self.editorTextView()?.string == original }
        let view = try XCTUnwrap(editorTextView())
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("Typed through the text view\n", replacementRange: view.selectedRange())
        await waitUntil("autosave") { (try? self.session.store.read(path)) == original + "Typed through the text view\n" }
        XCTAssertEqual(session.store.status(of: path), .savedOnDevice)
        await waitUntil("the row's status") { self.app.status(of: path) == .savedOnDevice }
        await session.engine.sync(.background)
        XCTAssertEqual(session.store.status(of: path), .synced)
        XCTAssertEqual(try session.store.read(path), original + "Typed through the text view\n")
    }

    func testEditorAlignsEachParagraphByItsOwnLanguage() async throws {
        try await start()
        let path = "mixed.md"
        let text = "# כותרת בעברית\nA line in English\nשורה בעברית עם SwiftUI באמצע\n"
        try session.store.save(path: path, text: text)
        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("editor") { self.editorTextView()?.string == text }
        let storage = try XCTUnwrap(editorTextView()?.textStorage)
        func alignment(of needle: String) -> NSTextAlignment? {
            let at = (storage.string as NSString).range(of: needle).location
            return (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        func direction(of needle: String) -> NSWritingDirection? {
            let at = (storage.string as NSString).range(of: needle).location
            return (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection
        }
        XCTAssertEqual(alignment(of: "כותרת"), .right)
        XCTAssertEqual(direction(of: "כותרת"), .rightToLeft)
        XCTAssertEqual(alignment(of: "A line"), .left)
        XCTAssertEqual(direction(of: "A line"), .leftToRight)
        XCTAssertEqual(alignment(of: "שורה"), .right, "Hebrew with an English word in the middle")
        XCTAssertEqual(try session.store.read(path), text, "styling is look only")

        // A new line follows its own language as it is typed.
        let view = try XCTUnwrap(editorTextView())
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("שורה חדשה", replacementRange: view.selectedRange())
        XCTAssertEqual(alignment(of: "חדשה"), .right)
        await picture("mac-editor-mixed")
    }

    func testSearchEnglishAndHebrew() async throws {
        try await start()
        let english = await session.store.index.search("shakshuka")
        XCTAssertEqual(english.map(\.path), ["recipes/shakshuka.md"])
        let hebrew = await session.store.index.search("חומוס")
        XCTAssertTrue(hebrew.contains { $0.path == "עברית/מתכון-חומוס.md" })
        show(NavigationStack { SearchResultsView(query: "local") })
        await picture("mac-search-english")
        show(NavigationStack { SearchResultsView(query: "חומוס") })
        await picture("mac-search-hebrew")
    }

    func testInboxMarksConflictCopies() async throws {
        try await start()
        show(RootView())
        router.open(.inbox)
        await picture("mac-inbox")
        let inbox = await session.store.index.notes(inFolder: "_inbox")
        XCTAssertEqual(inbox.filter(\.isConflictCopy).count, 2)
    }

    func testNeedsAttentionListAndBothSides() async throws {
        try await start()
        show(RootView())
        router.open(.attention)
        await picture("mac-attention")
        let items = session.store.journal.attention()
        let conflict = try XCTUnwrap(items.first { $0.detail != "deleted-remotely" })
        let deleted = try XCTUnwrap(items.first { $0.detail == "deleted-remotely" })
        router.open(.attentionItem(conflict.id))
        await picture("mac-conflict-compare")
        let texts = session.store.texts(for: conflict)
        XCTAssertTrue(texts.mine?.contains("30 s feels snappier") == true)
        XCTAssertTrue(texts.theirs?.contains("90 s saves battery") == true)
        router.open(.attentionItem(deleted.id))
        await picture("mac-deleted-elsewhere")
    }

    func testResolvingAConflictClosesTheItem() async throws {
        try await start()
        let conflict = try XCTUnwrap(session.store.journal.attention().first { $0.detail != "deleted-remotely" })
        await app.resolve(conflict, .keepBoth)
        await waitUntil("one item left") { app.snapshot.attention == 1 }
    }

    func testSettingsPausesSync() async throws {
        try await start()
        show(NavigationStack { SettingsView() })
        await picture("mac-settings")
        await app.setPaused(true)
        await waitUntil("paused") { app.snapshot.state == .paused(.user) }
        await app.setPaused(false)
    }

    func testSignInShowsTheCode() async throws {
        try await start()
        let model = SignInModel()
        show(SignInView(model: model))
        await picture("mac-signin")
        model.begin(app)
        await picture("mac-signin-code")
        guard case let .waiting(code) = model.step else { return XCTFail("no code") }
        XCTAssertEqual(code.verificationURI.absoluteString, "https://github.com/login/device")
    }

    func testSignOutAndWipeLeavesNoFiles() async throws {
        try await start()
        let root = session.store.root
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try await session.signOutAndWipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        session = nil
    }

    // MARK: editor model

    func testEditSaveStatusAndSync() async throws {
        try await start()
        let path = "recipes/lentil-soup.md"
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        XCTAssertEqual(app.status(of: path), .synced)
        let original = model.body
        model.userEdited(original + "\nA line typed in the test\n", app: app)
        await model.saveNow(app)
        XCTAssertEqual(session.store.status(of: path), .savedOnDevice)
        XCTAssertEqual(app.status(of: path), .savedOnDevice)
        XCTAssertEqual(try session.store.read(path), original + "\nA line typed in the test\n")
        // Leaving the note flushes to the fake GitHub.
        await model.finish(app)
        await waitUntil("synced") { self.session.store.status(of: path) == .synced }
        XCTAssertEqual(try session.store.read(path), original + "\nA line typed in the test\n")
    }

    func testAutosaveWaitsForAPauseAndKeepsTheFrontmatter() async throws {
        try await start()
        let path = "fm.md"
        let text = "---\ntitle: With frontmatter\n---\n# Body\n"
        try session.store.save(path: path, text: text)
        await session.engine.sync(.background)
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        XCTAssertEqual(model.body, "# Body\n", "frontmatter is not shown")
        model.userEdited("# Body\nmore\n", app: app)
        XCTAssertEqual(try session.store.read(path), text, "still typing: not saved yet")
        await waitUntil("autosave") { (try? self.session.store.read(path)) == "---\ntitle: With frontmatter\n---\n# Body\nmore\n" }
    }

    func testAnUneditedOpenNoteRefreshesInPlace() async throws {
        try await start()
        let path = "recipes/lentil-soup.md"
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: false)
        await model.load(app)
        let before = model.externalRevision
        // A landed change on disk, as after a pull.
        try session.store.files.write(path, "# Lentil soup\nchanged by a sync\n")
        await model.syncChangedNote(app)
        XCTAssertEqual(model.body, "# Lentil soup\nchanged by a sync\n")
        XCTAssertEqual(model.externalRevision, before + 1)
    }

    func testTextBeingTypedIsNotReplacedByASync() async throws {
        try await start()
        let path = "recipes/lentil-soup.md"
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        model.userEdited(model.body + "typing\n", app: app)
        let typing = model.body
        try session.store.files.write(path, "# Lentil soup\nchanged by a sync\n")
        await model.syncChangedNote(app)
        XCTAssertEqual(model.body, typing)
    }

    /// Several saves started together must end with the newest text on disk, and one new note, not two.
    func testSavesRunInOrderAndCreateOneNote() async throws {
        try await start()
        let model = NoteEditorModel(path: nil, newNoteFolder: "projects", isEditing: true)
        await model.load(app)
        let appModel: AppModel = app
        model.userEdited("# Same note\n1\n", app: appModel)
        async let first: Void = model.saveNow(appModel)
        model.userEdited("# Same note\n1\n2\n", app: appModel)
        async let second: Void = model.saveNow(appModel)
        model.userEdited("# Same note\n1\n2\n3\n", app: appModel)
        async let third: Void = model.saveNow(appModel)
        _ = await (first, second, third)
        XCTAssertEqual(model.path, "projects/Same note.md")
        XCTAssertEqual(try session.store.read("projects/Same note.md"), "# Same note\n1\n2\n3\n")
        let notes = await session.store.index.notes(inFolder: "projects")
        XCTAssertEqual(notes.filter { $0.path.contains("Same note") }.count, 1)
    }

    /// A sync event while a save is on its way must not bring older text back into the editor.
    func testASyncEventDuringASaveKeepsTheEditorsText() async throws {
        try await start()
        let path = "recipes/lentil-soup.md"
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        let typed = model.body + "typed\n"
        let appModel: AppModel = app
        model.userEdited(typed, app: appModel)
        async let saving: Void = model.saveNow(appModel)
        async let event: Void = model.syncChangedNote(appModel)
        _ = await (saving, event)
        XCTAssertEqual(model.body, typed)
        XCTAssertEqual(try session.store.read(path), typed)
    }

    func testComposeCreatesOnFirstTextAndEmptyLeavesNothing() async throws {
        try await start()
        let empty = NoteEditorModel(path: nil, newNoteFolder: nil, isEditing: true)
        await empty.load(app)
        await empty.finish(app)
        XCTAssertNil(empty.path)

        let model = NoteEditorModel(path: nil, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        model.userEdited("Note from the test\nsecond line\n", app: app)
        await model.saveNow(app)
        XCTAssertEqual(model.path, "_inbox/Note from the test.md")
        XCTAssertEqual(try session.store.read("_inbox/Note from the test.md"), "Note from the test\nsecond line\n")

        let inFolder = NoteEditorModel(path: nil, newNoteFolder: "projects", isEditing: true)
        await inFolder.load(app)
        inFolder.userEdited("# New project\n", app: app)
        await inFolder.saveNow(app)
        XCTAssertEqual(inFolder.path, "projects/New project.md")
    }

    /// Leaving the app saves what is being typed first, so the flush takes it along.
    func testBackgroundingSavesTheOpenNoteBeforeFlushing() async throws {
        try await start()
        let path = "recipes/lentil-soup.md"
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        app.editorAppeared(model)
        let typed = model.body + "typed just before leaving\n"
        model.userEdited(typed, app: app)
        app.scenePhaseChanged(.background)
        await waitUntil("flushed to GitHub") { self.session.store.status(of: path) == .synced && (try? self.session.store.read(path)) == typed }
    }

    func testOpeningAMissingNoteSaysSoAndNeverCreatesIt() async throws {
        try await start()
        let model = NoteEditorModel(path: "gone/never-existed.md", newNoteFolder: nil, isEditing: true)
        await model.load(app)
        XCTAssertTrue(model.missing)
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(session.store.files.exists("gone/never-existed.md"))
    }

    func testDeleteFromTheList() async throws {
        try await start()
        await app.delete(path: "recipes/lentil-soup.md")
        let notes = await session.store.index.notes(inFolder: "recipes")
        XCTAssertFalse(notes.contains { $0.path == "recipes/lentil-soup.md" })
        await session.engine.sync(.background)
        XCTAssertNotNil(try session.store.files.readText("_trash/recipes/lentil-soup.md"))
    }

    // MARK: router

    func testRouterOnBothLayouts() {
        let split = Router(usesStack: false)
        split.open(.folder("a"))
        split.open(.note("a/b.md"))
        XCTAssertEqual(split.content, .folder("a"))
        XCTAssertEqual(split.detail, .note("a/b.md"))
        split.open(.folder("c"))
        XCTAssertNil(split.detail, "a new folder clears the open note")
        let stack = Router(usesStack: true)
        stack.open(.folder("a"))
        stack.open(.note("a/b.md"))
        XCTAssertEqual(stack.path, [.folder("a"), .note("a/b.md")])
        stack.replaceTop(with: nil)
        XCTAssertEqual(stack.path, [.folder("a")])
    }

    // MARK: iPhone layout, in a phone-sized window

    func testPhoneLayoutScreens() async throws {
        try await start(stack: true)
        show(RootView())
        await picture("phone-home")
        router.open(.folder("projects"))
        await picture("phone-list")
        router.open(.note("projects/brain-notes-app.md"))
        await picture("phone-note-with-banner")
        router.reset()
        router.open(.folder("עברית"))
        router.open(.note("עברית/סיכום-פגישה-עם-נועה.md"))
        await picture("phone-hebrew-note")
        router.reset()
        router.open(.attention)
        await picture("phone-attention")
        let conflict = try XCTUnwrap(session.store.journal.attention().first { $0.detail != "deleted-remotely" })
        router.open(.attentionItem(conflict.id))
        await picture("phone-conflict-compare")
        router.reset()
        router.open(.settings)
        await picture("phone-settings")
        router.reset()
        router.open(.compose(folder: nil, id: UUID()))
        await picture("phone-compose")
        router.reset()
        router.open(.inbox)
        await picture("phone-inbox")
    }

    func testPhoneDark() async throws {
        try await start(stack: true, dark: true)
        show(RootView())
        await picture("phone-home-dark")
        router.open(.folder("עברית"))
        await picture("phone-hebrew-list-dark")
    }

    // MARK: editor spike

    func testEditorSpikeScreenOpensItsNoteInTheDemoSession() async throws {
        let options = LaunchOptions(arguments: ["-BNScreen", "editor-spike"], environment: [:])
        XCTAssertTrue(options.demo, "trying the bar can't reach real notes")
        XCTAssertNil(options.onboardingStep)
        XCTAssertFalse(LaunchOptions(arguments: ["-BNScreen", "edit"], environment: [:]).isEditorSpike)

        try await start(stack: true)
        router.applyDeepLink(options: options, attention: [])
        let path = "עברית/בדיקת-עורך.md"
        XCTAssertEqual(router.path, [.folder("עברית"), .note(path)])
        let text = try XCTUnwrap(try session.store.read(path))
        for needle in ["# בדיקת עורך", "**מילים מודגשות**", "**bold phrase**", "- [ ] לבדוק", "- [x] משימה", "- [ ] Check"] {
            XCTAssertTrue(text.contains(needle), needle)
        }

        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("the note in the editor") { self.editorTextView()?.string == text }
        XCTAssertEqual(session.store.status(of: path), .synced, "opening changes nothing")
        await picture("phone-editor-spike", saveAs: "editor-spike-phone-layout")
    }

    func testTimingLineShowsTheNumbers() async throws {
        try await start(stack: true)
        buildAccessibilityTree()
        show(VStack(spacing: 0) {
            StyleTimingLine()
            Spacer()
        })
        await waitToSee("spike.timing")
        // A label stays out of the accessibility node here, so this reads what is on screen.
        let end = Date().addingTimeInterval(10)
        var read = try await textOnScreen()
        while Date() < end, !read.joined(separator: " ").contains("271 KB") {
            read = try await textOnScreen()
        }
        XCTAssertTrue(read.joined(separator: " ").contains("271 KB"), "read \(read)")
        await picture("phone-spike-timing", saveAs: "editor-spike-timing-line")
    }

    /// The Mac has no keyboard bar, so this uses the view's own edit call with the same edits. What it shows is the
    /// path behind the buttons: each edit changes the paragraph's look at once and reaches the file.
    func testBarEditsChangeTheLookAndReachTheFile() async throws {
        try await start()
        let path = "bar.md"
        let text = "# Title\nHello there\nשלום עולם\n"
        try session.store.save(path: path, text: text)
        // On GitHub: a note that never got there is renamed from its first line when it is saved.
        await session.engine.sync(.background)
        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("editor") { self.editorTextView()?.string == text }
        let view = try XCTUnwrap(editorTextView())
        let storage = try XCTUnwrap(view.textStorage)

        func press(_ action: EditorAction, at needle: String) {
            let location = (view.string as NSString).range(of: needle).location
            let edit = action.edit(in: view.string, selection: NSRange(location: location + 1, length: 0))
            view.insertText(edit.replacement, replacementRange: edit.range)
            view.setSelectedRange(edit.selection)
        }
        func look(of needle: String) -> (direction: NSWritingDirection?, alignment: NSTextAlignment?) {
            let at = (storage.string as NSString).range(of: needle).location
            let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            return (style?.baseWritingDirection, style?.alignment)
        }
        func waitForFile(_ expected: String, file: StaticString = #filePath, line: UInt = #line) async {
            await waitUntil("the file to hold \(expected.debugDescription)") {
                (try? self.session.store.read(path)).flatMap { $0 }.map { Array($0.utf8) == Array(expected.utf8) } ?? false
            }
            XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8), file: file, line: line)
        }

        XCTAssertEqual(look(of: "Hello").direction, .leftToRight)
        press(.direction, at: "Hello")
        XCTAssertEqual(look(of: "Hello").direction, .rightToLeft)
        XCTAssertEqual(look(of: "Hello").alignment, .right)
        XCTAssertEqual(look(of: "# Title").direction, .leftToRight, "the paragraph above keeps its look")
        await waitForFile("# Title\n\u{200F}Hello there\nשלום עולם\n")
        XCTAssertEqual(session.store.status(of: path), .savedOnDevice)

        press(.direction, at: "Hello")
        XCTAssertEqual(look(of: "Hello").direction, .leftToRight)
        await waitForFile(text)

        press(.checklist, at: "שלום")
        XCTAssertEqual(look(of: "שלום").direction, .rightToLeft)
        await waitForFile("# Title\nHello there\n- [ ] שלום עולם\n")

        press(.bold, at: "עולם")
        await waitForFile("# Title\nHello there\n- [ ] שלום **עולם**\n")
        await picture("mac-editor-bar-edits")
    }

    // MARK: editor slice: the file stays the file

    /// `.logs/shots/editor/` in this repo (git-ignored).
    private static let editorShots = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".logs/shots/editor", isDirectory: true)

    /// A note with something of everything, synthetic. Saved and synced, so it is a clean note on the fake GitHub.
    private static let previewSample = """
    # Live Preview

    The same text on GitHub, with **bold**, *italic*, `code`, a [[wiki link]] and [a link](https://example.com).

    פסקה בעברית עם **מילים מודגשות** ו-*נטויות* באמצע, ואחריה SwiftUI.

    ## רשימת משימות

    - [ ] לבדוק את הסמן
    - [x] משימה שבוצעה
    - [ ] Check the caret
    - [x] A task that is done
    - A bullet
      - A nested bullet

    > A quote, with a bar instead of its mark.

    ---

    ```swift
    let **not** = "bold"
    ```

    """

    private func saved(_ text: String, at path: String = "preview.md") async throws -> String {
        try session.store.save(path: path, text: text)
        await session.engine.sync(.background)
        XCTAssertEqual(session.store.status(of: path), .synced)
        return path
    }

    private func bytes(_ path: String) throws -> [UInt8] { Array(try XCTUnwrap(try session.store.read(path)).utf8) }

    func testOpeningMovingTheCaretAndLeavingWriteNothing() async throws {
        try await start()
        let path = try await saved(Self.previewSample)
        let before = try bytes(path)
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { self.editorTextView()?.string == Self.previewSample }
        let view = try XCTUnwrap(editorTextView())
        window.makeFirstResponder(view)
        let length = (view.string as NSString).length
        for location in stride(from: 0, through: length, by: 13) { view.setSelectedRange(NSRange(location: location, length: 0)) }
        view.setSelectedRange(NSRange(location: 0, length: length))
        window.makeFirstResponder(nil)
        // Past the autosave's pause: a save would have happened by now.
        await settle(700)
        XCTAssertEqual(try bytes(path), before, "no byte of the file changed")
        XCTAssertEqual(session.store.status(of: path), .synced, "nothing to sync")
        XCTAssertEqual(session.store.journal.outbox().filter { sameBytes($0.path, path) }.count, 0)
    }

    /// Frontmatter is never in the view, so no action can touch it, and it is back in front of the body on every save.
    func testFrontmatterStaysOutOfTheEditorAndInTheFile() async throws {
        try await start()
        let text = "---\ntitle: With frontmatter\n---\n- [ ] Task\nA **bold** line\n"
        let path = try await saved(text)
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { self.editorTextView()?.string == "- [ ] Task\nA **bold** line\n" }
        let view = try XCTUnwrap(editorTextView() as? EditorTextView)
        view.coordinator?.toggleTick(paragraphAt: 0, in: view)
        let expected = "---\ntitle: With frontmatter\n---\n- [x] Task\nA **bold** line\n"
        await waitUntil("the save") { (try? self.bytes(path)) == Array(expected.utf8) }
    }

    /// A sync that changes the open note reloads the text: same look rules, no write.
    func testASyncReloadStylesTheNewTextAndWritesNothing() async throws {
        try await start()
        let path = try await saved("**old** text\n")
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        show(NoteEditorHarness(model: model))
        await waitUntil("editor") { self.editorTextView()?.string == "**old** text\n" }
        try session.store.files.write(path, "**new** text from a sync\n- [ ] a task\n")
        await model.syncChangedNote(app)
        await waitUntil("the new text") { self.editorTextView()?.string == "**new** text from a sync\n- [ ] a task\n" }
        window.makeFirstResponder(nil)
        await settle(100)
        let storage = try XCTUnwrap(editorTextView()?.textStorage)
        XCTAssertNotNil(storage.attribute(.bnHiddenMark, at: 0, effectiveRange: nil))
        let task = (storage.string as NSString).range(of: "a task").location
        XCTAssertNotNil(storage.attribute(.bnLineDecoration, at: task, effectiveRange: nil))
    }

    private struct NoteEditorHarness: View {
        let model: NoteEditorModel
        @Environment(AppModel.self) private var app

        var body: some View {
            MarkdownTextView(text: model.body, externalRevision: model.externalRevision, onEdit: { model.userEdited($0, app: app) })
        }
    }

    // MARK: editor slice: the Mac's Format menu and toolbar

    func testTheFormatActionsWorkOnTheEditor() async throws {
        try await start()
        let path = try await saved("plain line\nשורה בעברית\n")
        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("editor") { self.editorTextView()?.string == "plain line\nשורה בעברית\n" }
        let view = try XCTUnwrap(editorTextView() as? EditorTextView)
        XCTAssertTrue(view.responds(to: #selector(EditorTextView.performEditorAction(_:))))
        func press(_ action: EditorAction, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
            view.performEditorAction(EditorActionSender(action))
            XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8), "\(action)", file: file, line: line)
        }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        press(.title, "# plain line\nשורה בעברית\n")
        press(.heading, "## plain line\nשורה בעברית\n")
        press(.subheading, "### plain line\nשורה בעברית\n")
        press(.body, "plain line\nשורה בעברית\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        press(.bold, "**plain** line\nשורה בעברית\n")
        press(.bold, "plain line\nשורה בעברית\n")
        press(.italic, "*plain* line\nשורה בעברית\n")
        press(.italic, "plain line\nשורה בעברית\n")
        press(.code, "`plain` line\nשורה בעברית\n")
        press(.code, "plain line\nשורה בעברית\n")
        press(.checklist, "- [ ] plain line\nשורה בעברית\n")
        press(.checklist, "plain line\nשורה בעברית\n")
        press(.bullet, "- plain line\nשורה בעברית\n")
        press(.bullet, "plain line\nשורה בעברית\n")
        let caret = (view.string as NSString).range(of: "בעברית").location + 2
        view.setSelectedRange(NSRange(location: caret, length: 0))
        press(.bold, "plain line\nשורה **בעברית**\n")
        press(.bold, "plain line\nשורה בעברית\n")
        press(.direction, "plain line\n\u{200E}שורה בעברית\n")
        press(.direction, "plain line\nשורה בעברית\n")
        press(.checklist, "plain line\n- [ ] שורה בעברית\n")
        press(.checklist, "plain line\nשורה בעברית\n")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        press(.link, "plain[[]] line\nשורה בעברית\n")
        XCTAssertEqual(view.selectedRange().location, 7, "the caret between the brackets")
        await waitUntil("the autosave") { (try? self.bytes(path)) == Array("plain[[]] line\nשורה בעברית\n".utf8) }
    }

    func testTheToolbarHasTheActionsOnlyWhileEditing() async throws {
        try await start()
        buildAccessibilityTree()
        let path = try await saved("a line\n")
        show(NavigationStack { NoteScreen(path: path, startEditing: false) })
        await waitToSee("note.edit")
        for action in [EditorAction.bold, .italic, .code, .checklist, .bullet, .link, .direction] {
            XCTAssertFalse(isShowing("editor.toolbar.\(action.rawValue)"), "\(action)")
        }
        await press("note.edit")
        await waitToSee("editor.toolbar.bold")
        for action in [EditorAction.bold, .italic, .code, .checklist, .bullet, .link, .direction] {
            await waitToSee("editor.toolbar.\(action.rawValue)")
        }
        await waitToSee("editor.toolbar.style")
    }

    // MARK: editor slice: pictures

    private func photographEditor(path: String, name: String, stack: Bool, dark: Bool = false) async throws {
        try await start(stack: stack, dark: dark)
        let text = Self.previewSample
        if path == "preview.md" { _ = try await saved(text) }
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { self.editorTextView() != nil }
        window.makeFirstResponder(nil)
        await settle(300)
        await picture(name, saveAs: name, in: Self.editorShots)
        await session.engine.stop()
    }

    func testEditorPictures() async throws {
        try await photographEditor(path: "preview.md", name: "phone-editor-light", stack: true)
        try await photographEditor(path: "preview.md", name: "phone-editor-dark", stack: true, dark: true)
        try await photographEditor(path: "עברית/בדיקת-עורך.md", name: "phone-editor-hebrew", stack: true)
        try await photographEditor(path: "עברית/בדיקת-עורך.md", name: "phone-editor-hebrew-dark", stack: true, dark: true)
        try await photographEditor(path: "preview.md", name: "mac-editor-light", stack: false)
        try await photographEditor(path: "preview.md", name: "mac-editor-dark", stack: false, dark: true)
        try await photographEditor(path: "עברית/בדיקת-עורך.md", name: "mac-editor-hebrew", stack: false)
    }

    /// `-BNHebrew` opens the Hebrew note, in the editor with `-BNScreen edit`.
    func testHebrewLaunchOptionOpensTheHebrewNoteInTheEditorLook() async throws {
        let options = LaunchOptions(arguments: ["-BNScreen", "edit", "-BNHebrew", "-BNPhoneLayout"], environment: ["BN_DEMO": "1"])
        XCTAssertTrue(options.hebrew)
        try await start(stack: true)
        router.applyDeepLink(options: options, attention: [])
        XCTAssertEqual(router.path.last, .note("עברית/סיכום-פגישה-עם-נועה.md"))
        show(NavigationStack { NoteScreen(path: "עברית/סיכום-פגישה-עם-נועה.md", startEditing: true) })
        await waitUntil("editor") { self.editorTextView() != nil }
        window.makeFirstResponder(nil)
        await picture("phone-editor-hebrew-meeting", saveAs: "phone-editor-hebrew-meeting", in: Self.editorShots)
    }

    func testTheCaretLinePicture() async throws {
        try await start(stack: true)
        let path = try await saved(Self.previewSample)
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { self.editorTextView()?.string == Self.previewSample }
        let view = try XCTUnwrap(editorTextView())
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "bold**,").location, length: 0))
        await settle(300)
        await picture("phone-editor-caret-line", saveAs: "phone-editor-caret-line", in: Self.editorShots)
    }

    // MARK: onboarding: finding and pressing what is on screen

    /// SwiftUI builds its accessibility tree only for a client that asks, and this attribute is the asking.
    private func buildAccessibilityTree(_ on: Bool = true) {
        NSApp.accessibilitySetValue(on, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    /// In process, through the accessibility tree: no automation permission, and these are the real buttons.
    /// SwiftUI's nodes answer the Objective-C methods without declaring the protocol, hence `AnyObject`.
    private func accessibilityNode(_ id: String, in other: NSWindow? = nil) -> AnyObject? {
        // Navigation can shrink a test window to its content, and a toolbar too narrow sends its items to the overflow.
        if other == nil, window.contentRect(forFrameRect: window.frame).size != windowSize { window.setContentSize(windowSize) }
        func find(_ element: Any, depth: Int) -> AnyObject? {
            guard depth < 80 else { return nil }
            let node = element as AnyObject
            if node.accessibilityIdentifier?() as? String == id { return node }
            for child in (node.accessibilityChildren?() as? [Any]) ?? [] {
                if let hit = find(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        // From the window, not its content: a toolbar's buttons live outside the hosting view.
        return find((other ?? window) as Any, depth: 0)
    }

    private func isShowing(_ id: String) -> Bool { accessibilityNode(id) != nil }

    private func isEnabled(_ id: String) -> Bool? {
        accessibilityNode(id)?.isAccessibilityEnabled?()
    }

    private func waitToSee(_ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if isShowing(id) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("\(id) did not appear", file: file, line: line)
    }

    private func press(_ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        await waitToSee(id, file: file, line: line)
        // Each test checks what the press did: a toolbar's button acts, and still answers false here.
        _ = accessibilityNode(id)?.accessibilityPerformPress?()
    }

    private func launchDevice(signedIn: Bool = false, dark: Bool = false, stack: Bool = true, options: LaunchOptions = LaunchOptions()) async throws {
        let env = try environment ?? OnboardingEnvironment(signedIn: signedIn)
        environment = env
        (app, router) = await env.launch(options: options, usesStack: stack)
        makeWindow(stack: stack, dark: dark)
        buildAccessibilityTree()
        show(RootView())
    }

    /// A kill and a new launch: nothing in memory survives, the device's folder, defaults and tokens do.
    private func relaunchDevice() async throws {
        await app.session?.engine.stop()
        try await launchDevice()
    }

    private func assertNoOnboardingOnScreen(_ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        for id in ["onboarding.welcome", "onboarding.connect", "onboarding.code", "onboarding.codeEnded", "onboarding.ready"] {
            XCTAssertFalse(isShowing(id), "\(id) on screen. \(context)", file: file, line: line)
        }
    }

    /// The window's text, read back from its pixels: what a person sees, which the accessibility tree can't
    /// tell, since a label stays the same when the letters on screen are in another order.
    private func textOnScreen() async throws -> [String] {
        let bitmap = await drawWindow()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap?.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: onboarding: who sees what

    func testFreshInstallWalksToTheSampleNotesAndTheNextLaunchGoesStraightToFolders() async throws {
        try await launchDevice()
        await waitToSee("onboarding.welcome")
        XCTAssertFalse(isShowing("onboarding.connect"))
        XCTAssertFalse(environment?.onboardedFlag ?? true)

        await press("onboarding.continue")
        await waitToSee("onboarding.connect")
        XCTAssertFalse(environment?.onboardedFlag ?? true, "only Ready sets it")
        await waitToSee("onboarding.repo")

        await press("onboarding.sample")
        await waitToSee("onboarding.ready")
        XCTAssertTrue(environment?.onboardedFlag ?? false, "Ready sets it")
        await waitUntil("the sample notes") { self.app.phase == .ready }
        await waitToSee("onboarding.open")
        XCTAssertTrue(app.session?.isDemo == true)

        await press("onboarding.open")
        await waitToSee("home.list")
        XCTAssertFalse(isShowing("onboarding.ready"))
        XCTAssertTrue(app.folders.contains { $0.name == "projects" }, "the demo brain")

        try await relaunchDevice()
        await waitToSee("home.list")
        XCTAssertFalse(isShowing("onboarding.welcome"), "second launch: straight to Folders")
        XCTAssertFalse(isShowing("onboarding.connect"))
        XCTAssertFalse(isShowing("onboarding.ready"))
    }

    func testAKillMidFlowStartsAtWelcomeAgain() async throws {
        try await launchDevice()
        await press("onboarding.continue")
        await waitToSee("onboarding.connect")
        await press("signin.start")
        await waitToSee("signin.code")

        try await relaunchDevice()
        await waitToSee("onboarding.welcome")
        XCTAssertFalse(isShowing("onboarding.connect"))
    }

    /// The rule this update must not break: a device with a token goes to its notes, whatever else it holds,
    /// and not for one moment through onboarding. The first row is everyone who updates while signed in.
    /// The window goes up before the launch work starts, as in the real app, so `.loading` is watched too.
    func testASignedInDeviceNeverShowsOnboardingAtAnyMoment() async throws {
        let devices: [(name: String, keychainLocked: Bool, onboarded: Bool, sampleFlag: Bool)] = [
            ("updated from before these screens", false, false, false),
            ("signed in through these screens", false, true, false),
            ("a sample flag left behind", false, false, true),
            ("Keychain locked at launch", true, false, false),
        ]
        for stack in [true, false] {
            for device in devices {
                let context = "\(device.name), \(stack ? "phone" : "Mac") layout"
                let env = try OnboardingEnvironment(signedIn: true, keychainLocked: device.keychainLocked)
                environment = env
                if device.onboarded { env.defaults.set(true, forKey: AppModel.onboardedKey) }
                if device.sampleFlag { env.defaults.set(true, forKey: AppModel.sampleModeKey) }
                let model = AppModel(options: LaunchOptions(), sessions: env.sessions, defaults: env.defaults)
                app = model
                router = Router(usesStack: stack)
                makeWindow(stack: stack, dark: false)
                buildAccessibilityTree()

                let shown = Flag()
                watch { [weak model] in
                    if model?.showsOnboarding == true { shown.raised = true }
                }
                show(RootView())
                await waitToSee("loading")
                XCTAssertEqual(model.phase, .loading, context)
                assertNoOnboardingOnScreen(context)

                await model.start(router: router)
                await waitToSee("home.list")
                assertNoOnboardingOnScreen(context)
                // And not a moment later either, when the launch work has finished.
                await settle(300)
                await waitToSee("home.list")
                assertNoOnboardingOnScreen(context)

                XCTAssertFalse(shown.raised, "the model asked for onboarding. \(context)")
                XCTAssertEqual(model.phase, .ready, context)
                XCTAssertFalse(model.sampleMode, context)
                XCTAssertTrue(model.session?.isDemo == false, context)
                XCTAssertEqual(env.onboardedFlag, device.onboarded, "a launch leaves the flag alone. \(context)")

                await model.session?.engine.stop()
                env.cleanUp()
                environment = nil
            }
        }
    }

    /// A token GitHub stops accepting is no reason for onboarding: the notes stay, this launch and the next,
    /// and signing in again is the plain sheet from Settings.
    func testARefusedTokenKeepsTheNotesAndOffersThePlainSheet() async throws {
        try await launchDevice(signedIn: true)
        await waitToSee("home.list")
        environment?.transport.refuseToken()
        await app.syncNow()
        await waitUntil("the token to be refused") { self.app.snapshot.state == .signedOut }
        XCTAssertEqual(app.phase, .ready)
        assertNoOnboardingOnScreen()
        XCTAssertNotNil(try environment?.tokens.load(), "the token stays until the user replaces it")

        router.open(.settings)
        await press("settings.signIn")
        await waitUntil("the sheet") { self.app.showSignIn }
        assertNoOnboardingOnScreen()
        app.showSignIn = false

        try await relaunchDevice()
        await waitToSee("home.list")
        assertNoOnboardingOnScreen()
    }

    func testSignOutAndWipeReturnsToConnectNotWelcomeEvenAfterAKill() async throws {
        try await launchDevice(signedIn: true)
        await waitToSee("home.list")
        XCTAssertEqual(environment?.onboardedFlag, false, "signed in before these screens existed")

        await app.signOutAndWipe()
        await waitToSee("onboarding.connect")
        XCTAssertFalse(isShowing("onboarding.welcome"))
        XCTAssertNil(try environment?.tokens.load(), "the token is gone")

        try await relaunchDevice()
        await waitToSee("onboarding.connect")
        XCTAssertFalse(isShowing("onboarding.welcome"))
    }

    func testConnectGitHubInSettingsLeavesTheSampleNotesForConnect() async throws {
        try await launchDevice()
        await press("onboarding.continue")
        await press("onboarding.sample")
        await waitUntil("the sample notes") { self.app.phase == .ready }
        await press("onboarding.open")
        await waitToSee("home.list")
        XCTAssertTrue(environment?.demoFolderExists ?? false)

        router.open(.settings)
        await waitToSee("settings.connect")
        XCTAssertFalse(isShowing("settings.wipe"), "nothing to sign out of")
        XCTAssertFalse(isShowing("settings.repo"))

        await press("settings.connect")
        await waitToSee("onboarding.connect")
        XCTAssertFalse(isShowing("onboarding.welcome"))
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertFalse(environment?.demoFolderExists ?? true)
        XCTAssertEqual(router.path, [], "nothing left of the sample session's navigation")
        XCTAssertEqual(environment?.transport.requests, [])
    }

    func testSettingsOfALiveSessionHasNoConnectButton() async throws {
        try await launchDevice(signedIn: true)
        router.open(.settings)
        await waitToSee("settings.wipe")
        await waitToSee("settings.repo")
        XCTAssertFalse(isShowing("settings.connect"))
    }

    // MARK: onboarding: signing in

    func testSignInFromConnectGoesThroughTheCodeToReady() async throws {
        try await launchDevice()
        await press("onboarding.continue")
        await press("signin.start")
        await waitToSee("signin.code")
        await waitToSee("signin.copy")
        await waitToSee("signin.open")
        XCTAssertEqual(app.phase, .needsSignIn)

        // Approved on GitHub. Its API is held, so the first sync stays at its first step.
        environment?.transport.hold()
        environment?.transport.approve()
        await waitToSee("onboarding.ready")
        await waitToSee("onboarding.progress")
        XCTAssertEqual(app.snapshot.state, .firstSync(.downloading), "from the engine, live")
        XCTAssertEqual(isEnabled("onboarding.open"), false, "the notes wait for it")
        XCTAssertFalse(app.sampleMode)
        XCTAssertTrue(environment?.onboardedFlag ?? false)
        await picture("phone-4-ready-downloading", saveAs: "phone-4-ready-downloading-light")

        // The sync can't go on: the screen says so and lets the user through.
        environment?.transport.release()
        await waitToSee("onboarding.problem")
        XCTAssertEqual(isEnabled("onboarding.open"), true)
        await picture("phone-4-ready-offline", saveAs: "phone-4-ready-problem-light")
        await press("onboarding.open")
        await waitToSee("home.list")
    }

    func testCancelOnTheCodeGoesBackToConnectAndStopsPolling() async throws {
        try await launchDevice()
        await press("onboarding.continue")
        await press("signin.start")
        await waitToSee("signin.code")
        await waitUntil("polling") { (self.environment?.transport.requests(forCode: "device-1") ?? 0) > 0 }

        await press("signin.cancel")
        await waitToSee("onboarding.connect")
        XCTAssertFalse(isShowing("signin.code"))
        await picture("phone-2-connect-after-cancel", saveAs: "phone-2-connect-after-cancel-light")
        await settle(100)
        let polls = environment?.transport.requests(forCode: "device-1")
        await settle(100)
        XCTAssertEqual(environment?.transport.requests(forCode: "device-1"), polls, "the code is no longer polled")
    }

    func testACodeThatRunsOutOffersANewOne() async throws {
        try await launchDevice()
        let code = DeviceCode(deviceCode: "demo", userCode: "WDJB-MJHT", verificationURI: URL(string: "https://github.com/login/device")!, interval: 5, expiresIn: 900)
        show(OnboardingFlow(start: .deviceCode, signIn: SignInModel(step: .waiting(code), expiresAt: Date().addingTimeInterval(1.5))))
        await waitToSee("signin.code")
        await waitToSee("signin.newCode")
        XCTAssertFalse(isShowing("signin.code"), "the old code is not offered any more")
        await picture("phone-3-code-expired", saveAs: "phone-3-code-expired-light")

        await press("signin.newCode")
        await waitToSee("signin.code")
        XCTAssertFalse(isShowing("signin.newCode"))
    }

    /// Read from the pixels. English layout too, so a failure here can't be the reading.
    func testTheCodeReadsLeftToRightInAHebrewLayout() async throws {
        for args in [["-BNScreen", "code", "-BNPhoneLayout"], ["-BNScreen", "code", "-BNPhoneLayout", "-BNHebrew"]] {
            environment = try OnboardingEnvironment()
            try await launchDevice(options: LaunchOptions(arguments: args, environment: [:]))
            await waitToSee("signin.code")
            let text = try await textOnScreen()
            // The two halves in order. The hyphen is dim and the reading may drop it.
            XCTAssertTrue(text.contains { $0.filter(\.isLetter) == "WDJBMJHT" }, "\(args): read \(text)")
            await app.session?.engine.stop()
            environment?.cleanUp()
            environment = nil
        }
    }

    func testADeclinedCodeSaysSoAndOffersANewOne() async throws {
        try await launchDevice()
        show(OnboardingFlow(start: .deviceCode, signIn: SignInModel(step: .failed("You declined on GitHub. You can try again."))))
        await waitToSee("signin.message")
        await waitToSee("signin.newCode")
        await picture("phone-3-code-declined", saveAs: "phone-3-code-declined-light")
    }

    func testOfflineOnConnectPointsToTheSampleNotes() async throws {
        try await launchDevice()
        await press("onboarding.continue")
        await waitToSee("onboarding.connect")
        XCTAssertFalse(isShowing("onboarding.offline"))
        await app.session?.engine.setOnline(false)
        await waitToSee("onboarding.offline")
        await picture("phone-2-connect-offline", saveAs: "phone-2-connect-offline-light")
        XCTAssertEqual(environment?.transport.requests, [], "no retry loop")
        await settle(200)
        XCTAssertEqual(environment?.transport.requests, [])
    }

    func testThePlainSheetKeepsItsOwnStartScreen() async throws {
        try await start()
        buildAccessibilityTree()
        let model = SignInModel()
        show(NavigationStack { SignInView(model: model) })
        await waitToSee("signin.start")
        XCTAssertFalse(isShowing("onboarding.connect"))
        await picture("mac-signin-sheet-start")
        model.begin(app)
        await waitToSee("signin.code")
        await waitToSee("signin.open")
        await picture("mac-signin-sheet-code", saveAs: "mac-sheet-code-light")
    }

    // MARK: onboarding: pictures

    private func photographOnboardingScreens(stack: Bool, name: String) async throws {
        let screens = [("welcome", "1-welcome", "onboarding.welcome"), ("connect", "2-connect", "onboarding.connect"),
                       ("code", "3-code", "signin.code"), ("ready", "4-ready", "onboarding.open")]
        for (screen, title, id) in screens {
            for variant in ["light", "dark", "hebrew"] where stack || variant != "hebrew" {
                var args = ["-BNScreen", screen]
                if stack { args.append("-BNPhoneLayout") }
                if variant == "hebrew" { args.append("-BNHebrew") }
                let options = LaunchOptions(arguments: args, environment: [:])
                XCTAssertTrue(options.demo)
                XCTAssertEqual(options.phoneLayout, stack)
                environment = try OnboardingEnvironment()
                try await launchDevice(dark: variant == "dark", stack: stack, options: options)
                XCTAssertTrue(app.session?.isDemo == true)
                XCTAssertEqual(environment?.liveSessionsOpened, 0)
                await waitToSee(id)
                await picture("\(name)-\(title)-\(variant)", saveAs: "\(name)-\(title)-\(variant)")
                await app.session?.engine.stop()
                environment?.cleanUp()
                environment = nil
            }
        }
    }

    func testOnboardingPicturesOnPhone() async throws {
        try await photographOnboardingScreens(stack: true, name: "phone")
    }

    func testOnboardingPicturesOnMac() async throws {
        try await photographOnboardingScreens(stack: false, name: "mac")
    }

    func testReadyPicturesWithFirstSyncProgress() async throws {
        try await launchDevice()
        show(ReadyContent(status: .working("Indexing 120 of 300", fraction: 0.4), sample: false, noteCount: 120, lastSync: nil, onOpen: {}))
        await waitToSee("onboarding.progress")
        await picture("phone-4-ready-progress", saveAs: "phone-4-ready-progress-light")
        show(ReadyContent(status: .done, sample: false, noteCount: 2434, lastSync: Date(), onOpen: {}))
        await waitToSee("onboarding.open")
        await picture("phone-4-ready-done", saveAs: "phone-4-ready-done-light")
        // The fonts stay the same on a Mac; the rows still take their largest-text layout.
        show(ReadyContent(status: .done, sample: false, noteCount: 2434, lastSync: Date(), onOpen: {}).dynamicTypeSize(.accessibility3))
        await waitToSee("onboarding.open")
        await picture("phone-4-ready-rows-stacked", saveAs: "phone-4-ready-rows-stacked-light")
    }

    /// The states the other pictures show in light. Dark has its own slate blue and its own button colours.
    func testStatePicturesInDark() async throws {
        try await launchDevice(dark: true)
        show(OnboardingFlow(start: .connect))
        await app.session?.engine.setOnline(false)
        await waitToSee("onboarding.offline")
        await picture("phone-2-connect-offline-dark", saveAs: "phone-2-connect-offline-dark")
        show(ReadyContent(status: .working("Indexing 120 of 300", fraction: 0.4), sample: false, noteCount: 120, lastSync: nil, onOpen: {}))
        await waitToSee("onboarding.progress")
        await picture("phone-4-ready-progress-dark", saveAs: "phone-4-ready-progress-dark")
        show(ReadyContent(status: .problem("You’re offline. Your notes will come down when you’re back."), sample: false, noteCount: 0, lastSync: nil, onOpen: {}))
        await waitToSee("onboarding.problem")
        await picture("phone-4-ready-problem-dark", saveAs: "phone-4-ready-problem-dark")
        show(ReadyContent(status: .done, sample: false, noteCount: 2434, lastSync: Date(), onOpen: {}))
        await waitToSee("onboarding.open")
        await picture("phone-4-ready-done-dark", saveAs: "phone-4-ready-done-dark")
        // Last: a replaced hosting view leaves this screen's toolbar on the test window.
        show(OnboardingFlow(start: .deviceCode, signIn: SignInModel(step: .failed("The code ran out. You can get a new one."))))
        await waitToSee("signin.newCode")
        await picture("phone-3-code-expired-dark", saveAs: "phone-3-code-expired-dark")
    }

    func testSettingsPictureInSampleMode() async throws {
        try await launchDevice()
        await press("onboarding.continue")
        await press("onboarding.sample")
        await waitUntil("the sample notes") { self.app.phase == .ready }
        await press("onboarding.open")
        router.open(.settings)
        await waitToSee("settings.connect")
        await picture("phone-settings-sample", saveAs: "phone-settings-sample-light")
    }

    /// A Mac ignores Dynamic Type, so the largest text can't be seen here. A short window tests the same
    /// layout rule: what doesn't fit scrolls, and the buttons stay inside the window.
    func testOnASmallScreenTheContentScrollsAndTheButtonsStay() async throws {
        try await launchDevice()
        windowSize = NSSize(width: 320, height: 420)
        window.setContentSize(windowSize)
        for (name, step, button) in [("1-welcome", OnboardingStep.welcome, "onboarding.continue"), ("2-connect", .connect, "onboarding.sample"), ("3-code", .deviceCode, "signin.open")] {
            show(OnboardingFlow(start: step))
            await waitToSee(button)
            await picture("phone-\(name)-small-window", saveAs: "phone-\(name)-small-window")
            let frame = try XCTUnwrap(accessibilityNode(button)?.accessibilityFrame?())
            XCTAssertFalse(frame.isEmpty, button)
            XCTAssertTrue(window.frame.contains(frame), "\(button) is at \(frame), outside the window at \(window.frame)")
        }
    }
}
