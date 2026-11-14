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
        // No open/close animation. AppKit runs it (`_NSWindowTransformAnimation`) on a GCD worker thread, and a window
        // ordered out or replaced mid-animation leaves that thread stuck for good: about one per test. After ~64, GCD's
        // thread limit is reached and anything that needs a worker thread (Vision's text reading, a background queue)
        // never runs, so the test waits forever (build 6 run of 2026-11-14, spindump: 64 threads in `_runBlocking`).
        window.animationBehavior = .none
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

    /// A note a sync brought in GitHub's `_Inbox/` spelling is in the Inbox, not a folder of its own.
    func testInboxInAnotherSpellingIsTheInbox() async throws {
        try await start()
        try session.store.index.upsert(path: "_Inbox/Synced from GitHub.md", text: "# Synced from GitHub\n", modified: Date())
        await app.reloadLists()
        XCTAssertFalse(app.folders.contains { PathPolicy.isInbox($0.name) }, "no _Inbox folder next to the Inbox row")
        XCTAssertEqual(app.inboxCount, 7, "6 in _inbox and 1 in _Inbox")
        let inbox = await session.store.index.inboxNotes()
        XCTAssertEqual(inbox.first?.path, "_Inbox/Synced from GitHub.md")
        XCTAssertEqual(inbox.count, 7)
        show(RootView())
        router.open(.inbox)
        await picture("mac-inbox-two-spellings")
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

    /// With the black hole parked (`BlackHoleFeature.isEnabled`), a delete in the UI is at once, and Undo puts the note back.
    func testBlackHoleDeleteThenUndo() async throws {
        try await start()
        let path = "recipes/lentil-soup.md"
        let before = try XCTUnwrap(try session.store.files.readText(path))
        await app.requestDelete(paths: [path])
        guard case let .undo(count)? = app.blackHole else {
            return XCTFail("expected undo chip")
        }
        XCTAssertEqual(count, 1)
        let after = await session.store.index.notes(inFolder: "recipes")
        XCTAssertFalse(after.contains { $0.path == path })
        await app.undoBlackHoleDelete()
        XCTAssertNil(app.blackHole)
        XCTAssertEqual(try session.store.files.readText(path), before)
    }

    func testBlackHoleFolderDeleteUsesFullIntensity() async throws {
        try await start()
        let paths = await app.notePaths(underFolder: "recipes")
        XCTAssertGreaterThanOrEqual(paths.count, 2)
        await app.requestDeleteFolder(path: "recipes")
        guard case let .undo(count)? = app.blackHole else {
            return XCTFail("expected undo chip")
        }
        XCTAssertEqual(count, paths.count)
        let left = await session.store.index.notes(inFolder: "recipes")
        XCTAssertTrue(left.isEmpty)
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
        for needle in ["# Live Preview study note", "**bold phrase**", "שורה בעברית", "- [x] Capture the idea", "- [ ] Leave one box open"] {
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
        // The line is caption-sized. Vision read it as [] on the Mac run, including after the pass finished.
        // The identifier's label is that same sentence, so this waits until the measurement is what the line says.
        let end = Date().addingTimeInterval(20)
        var label = accessibilityNode("spike.timing")?.accessibilityLabel?() ?? ""
        while Date() < end, !label.contains("271 KB") {
            try? await Task.sleep(for: .milliseconds(50))
            label = accessibilityNode("spike.timing")?.accessibilityLabel?() ?? ""
        }
        XCTAssertTrue(label.contains("271 KB"), "the timing line says: \(label)")
        XCTAssertTrue(label.contains("paragraphs"), "the timing line says: \(label)")
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

    1. A numbered list
    2. Its second item, long enough to wrap around under its own text
       1. Nested, with a number of its own
    3. Back out

    1. רשימה ממוספרת
    2. פריט שני

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

    /// The undo steps were for the old text. Replayed on the new one, they would write wrong bytes.
    func testASyncReloadForgetsTheUndoStepsOfTheOldText() async throws {
        try await start()
        let path = try await saved("old text\n")
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        show(NoteEditorHarness(model: model))
        await waitUntil("editor") { self.editorTextView()?.string == "old text\n" }
        let view = try XCTUnwrap(editorTextView())
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("!!", replacementRange: view.selectedRange())
        await settle(50)
        let undo = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(undo.canUndo)
        await model.saveNow(app)

        let new = "n\u{1F642}w text from a sync\n"
        try session.store.files.write(path, new)
        await model.syncChangedNote(app)
        await waitUntil("the new text") { self.editorTextView()?.string == new }
        XCTAssertFalse(undo.canUndo, "nothing left that could replay on it")
        undo.undo()
        XCTAssertEqual(Array(view.string.utf8), Array(new.utf8))
    }

    /// A caret kept across a reload must not land inside an emoji: the next keystroke would split it, and half a pair
    /// can't be saved.
    func testASyncReloadKeepsTheCaretBetweenCharacters() async throws {
        try await start()
        let path = try await saved("abcdef\n")
        let model = NoteEditorModel(path: path, newNoteFolder: nil, isEditing: true)
        await model.load(app)
        show(NoteEditorHarness(model: model))
        await waitUntil("editor") { self.editorTextView()?.string == "abcdef\n" }
        let view = try XCTUnwrap(editorTextView())
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let new = "a\u{1F642}b\n"
        try session.store.files.write(path, new)
        await model.syncChangedNote(app)
        await waitUntil("the new text") { self.editorTextView()?.string == new }
        XCTAssertEqual(view.selectedRange().location, 1, "in front of the emoji, not inside it")
        view.insertText("x", replacementRange: view.selectedRange())
        await settle(50)
        XCTAssertEqual(Array(view.string.utf8), Array("ax\u{1F642}b\n".utf8))
    }

    private struct NoteEditorHarness: View {
        let model: NoteEditorModel
        @Environment(AppModel.self) private var app

        var body: some View {
            MarkdownTextView(text: model.body, externalRevision: model.externalRevision, onEdit: { model.userEdited($0, app: app) })
        }
    }

    // MARK: editor slice: the status icon

    func testATickIsOneByteInTheFileAndShowsOnTheStatusIcon() async throws {
        try await start()
        buildAccessibilityTree()
        let text = "# List\n- [ ] one\n- [x] שתיים\nend\n"
        let path = try await saved(text)
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { self.editorTextView()?.string == text }
        await waitToSee("note.status")
        XCTAssertEqual(accessibilityNode("note.status")?.accessibilityLabel?(), "Synced")
        let view = try XCTUnwrap(editorTextView() as? EditorTextView)
        let start = (view.string as NSString).range(of: "- [ ] one").location
        view.coordinator?.toggleTick(paragraphAt: start, in: view)
        let expected = Array("# List\n- [x] one\n- [x] שתיים\nend\n".utf8)
        await waitUntil("the save") { (try? self.bytes(path)) == expected }
        XCTAssertEqual(try bytes(path).count, Array(text.utf8).count, "same length")
        XCTAssertEqual(zip(try bytes(path), Array(text.utf8)).filter { $0 != $1 }.count, 1, "one byte")
        await waitUntil("the icon") { self.accessibilityNode("note.status")?.accessibilityLabel?() == "Saved on device" }
        await session.engine.sync(.background)
        await app.reloadLists()
        await waitUntil("the icon") { self.accessibilityNode("note.status")?.accessibilityLabel?() == "Synced" }
    }

    func testEveryNoteStateHasAnIconWordsAndADetail() {
        let cases: [(NoteSyncStatus, Bool, Bool, Bool, String, StatusBadge.Tone)] = [
            (.synced, false, false, false, "Synced", .good),
            (.savedOnDevice, false, false, false, "Saved on device", .waiting),
            (.syncing, false, false, false, "Syncing", .moving),
            (.needsAttention, false, false, false, "Needs attention", .problem),
            (.synced, true, false, false, "Offline", .quiet),
            (.savedOnDevice, true, false, false, "Offline", .waiting),
            (.needsAttention, true, false, false, "Needs attention", .problem),
            (.synced, false, true, false, "Couldn't save", .problem),
            (.savedOnDevice, true, true, false, "Couldn't save", .problem),
            (.synced, false, false, true, "Not saved yet", .waiting),
        ]
        for (status, offline, failed, isNew, title, tone) in cases {
            let badge = StatusBadge.note(status: status, offline: offline, saveFailed: failed, isNew: isNew)
            XCTAssertEqual(badge.title, title)
            XCTAssertEqual(badge.tone, tone, title)
            XCTAssertFalse(badge.detail.isEmpty, title)
            XCTAssertNotNil(NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil), badge.symbol)
        }
    }

    func testEverySyncStateHasAnIconWordsAndADetail() {
        let states: [SyncState] = [.idle, .checking, .pulling, .merging, .applying, .pushing, .verifying,
                                   .firstSync(.downloading), .firstSync(.verifying(done: 1, total: 2)), .firstSync(.indexing(done: 1, total: 2)),
                                   .needsAttention(1), .needsAttention(3), .signedOut, .paused(.user), .paused(.rateLimited(until: nil)),
                                   .paused(.rateLimited(until: Date())), .offline, .retrying(at: Date()), .accessLost, .publicRepo,
                                   .repoTooLarge(RepoTooLarge(.download, max: FirstSyncLimits.standard.maxDownloadBytes))]
        for state in states {
            var snapshot = SyncSnapshot()
            snapshot.state = state
            let badge = StatusBadge.sync(snapshot, now: Date())
            XCTAssertFalse(badge.title.isEmpty)
            XCTAssertFalse(badge.detail.isEmpty, badge.title)
            XCTAssertEqual(badge.isBusy, state.isBusy, badge.title)
            XCTAssertNotNil(NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil), badge.symbol)
        }
        var one = SyncSnapshot()
        one.state = .needsAttention(1)
        XCTAssertEqual(StatusBadge.sync(one, now: Date()).title, "1 needs attention")
    }

    /// Words only on a tap: the screen shows an icon, VoiceOver gets the label, and the detail says the rest.
    func testTheNoteScreenShowsAnIconAndATapSaysTheRest() async throws {
        try await start()
        buildAccessibilityTree()
        let path = "recipes/lentil-soup.md"
        show(NavigationStack { NoteScreen(path: path, startEditing: false) })
        await waitToSee("note.viewer")
        await waitToSee("note.status")
        await waitUntil("the status") { self.accessibilityNode("note.status")?.accessibilityLabel?() == "Synced" }
        // This check is the wide Mac window (1120×720). The phone-size picture below is a later capture.
        let wide = windowSize
        let end = Date().addingTimeInterval(5)
        var reading = try await readWindow()
        while Date() < end, !reading.strings.joined(separator: " ").contains("Red lentil soup") {
            reading = try await readWindow()
        }
        let read = reading.strings.joined(separator: " ")
        if !read.contains("Red lentil soup") {
            attachWideOCRBitmap(reading.bitmap)
        }
        XCTAssertTrue(read.contains("Red lentil soup"), "wide \(Int(wide.width))×\(Int(wide.height)) \(Self.bitmapFacts(reading.bitmap)) read: \(read)")
        XCTAssertFalse(read.contains("Synced"), "no words in the bar: \(read)")
        windowSize = NSSize(width: 393, height: 852)
        await picture("phone-note-status-icon", saveAs: "phone-note-status-icon", in: Self.editorShots)
        windowSize = NSSize(width: 1120, height: 720)
        await settle(150)
        window.setContentSize(windowSize)
        await press("note.status")
        await settle(300)
        // A popover is a window of its own, so this asks every window of the app.
        let detail = NSApp.windows.contains { $0 !== window && $0.isVisible && accessibilityNode("note.status.detail", in: $0) != nil }
        XCTAssertTrue(detail, "the tap opened the detail")
    }

    /// A sheet asked for while a popover is up is refused, so what the button does waits for the detail to go.
    func testAStatusActionClosesItsDetailFirst() async throws {
        try await start()
        buildAccessibilityTree()
        show(RootView())
        await waitUntil("the state to settle") { self.accessibilityNode("sync.pill")?.accessibilityLabel?() == "2 need attention · 1 unsynced" }
        await press("sync.pill")
        await settle(300)
        // The test host's own window is up too, so this looks for the button, not for a window.
        await waitUntil("the detail, with its action") { NSApp.windows.contains { $0 !== self.window && $0.isVisible && self.accessibilityNode("sync.pill.action", in: $0) != nil } }
        let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && accessibilityNode("sync.pill.action", in: $0) != nil }, "the detail, with its action")
        XCTAssertNil(router.content)
        _ = accessibilityNode("sync.pill.action", in: popover)?.accessibilityPerformPress?()
        await settle(100)
        XCTAssertNil(router.content, "nothing happens until the detail has gone")
        await waitUntil("the action, after the detail has gone") { self.router.content == .attention }
        XCTAssertFalse(popover.isVisible, "the detail is gone")
    }

    /// A save that fails asks the user to do something, so it stays in words as well as on the icon.
    func testAFailedSaveStaysInWords() async throws {
        try await start()
        buildAccessibilityTree()
        let path = try await saved("a line\n", at: "locked/note.md")
        let folder = try session.store.files.url(for: "locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { self.editorTextView()?.string == "a line\n" }
        await waitToSee("note.status")
        let view = try XCTUnwrap(editorTextView())
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("more", replacementRange: view.selectedRange())
        await waitToSee("note.saveProblem")
        await waitUntil("the icon") { self.accessibilityNode("note.status")?.accessibilityLabel?() == "Couldn't save" }
        XCTAssertEqual(view.string, "a linemore\n", "the text stays on screen")
        windowSize = NSSize(width: 393, height: 852)
        await picture("phone-save-failed", saveAs: "phone-save-failed", in: Self.editorShots)

        // Space again: the next save goes through, and the words go away.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        view.insertText("!", replacementRange: view.selectedRange())
        await waitUntil("the save") { (try? self.bytes(path)) == Array("a linemore!\n".utf8) }
        await waitUntil("the words gone") { !self.isShowing("note.saveProblem") }
    }

    func testTheHomeScreenShowsAnIconAndNoWords() async throws {
        try await start(stack: true)
        buildAccessibilityTree()
        show(RootView())
        await waitToSee("sync.pill")
        // The events of the demo's staging are still coming in when the window goes up.
        await waitUntil("the state to settle") { self.accessibilityNode("sync.pill")?.accessibilityLabel?() == "2 need attention · 1 unsynced" }
        let read = try await textOnScreen().joined(separator: " ")
        XCTAssertFalse(read.contains("unsynced"), "no words in the bar: \(read)")
        await picture("phone-home-status-icon", saveAs: "phone-home-status-icon", in: Self.editorShots)
    }

    // MARK: editor slice: New Folder

    func testNewFolderIsNextToNewNoteInEveryFolderOnBothLayouts() async throws {
        for stack in [true, false] {
            try await start(stack: stack)
            // Wider than a phone: a Mac's toolbar sends items to its overflow, which a phone doesn't have.
            windowSize = NSSize(width: 1120, height: 720)
            window.setContentSize(windowSize)
            buildAccessibilityTree()
            show(RootView())
            await waitToSee("folder.new")
            await waitToSee("compose.button")
            router.open(.folder("projects"))
            await waitToSee("list.projects")
            await waitToSee("compose.button.list")
            await waitToSee("folder.new")
            await picture("\(stack ? "phone" : "mac")-new-folder-button", saveAs: "\(stack ? "phone" : "mac")-new-folder-button", in: Self.editorShots)
            await session.engine.stop()
        }
    }

    func testAFolderMadeInAFolderShowsThereAndHoldsANote() async throws {
        try await start(stack: true)
        buildAccessibilityTree()
        show(RootView())
        router.open(.folder("projects"))
        await waitToSee("list.projects")

        guard case let .success(path) = await app.createFolder(named: "Ideas", in: "projects") else { return XCTFail("no folder") }
        XCTAssertEqual(path, "projects/Ideas")
        XCTAssertTrue(app.folderTree.first { $0.name == "projects" }?.children.contains { $0.path == path } == true)
        // A row of a list has no node of its own here, so this reads the screen.
        let end = Date().addingTimeInterval(8)
        var read = try await textOnScreen()
        while Date() < end, !read.joined(separator: " ").contains("Ideas") { read = try await textOnScreen() }
        XCTAssertTrue(read.joined(separator: " ").contains("Ideas"), "read \(read)")
        await picture("phone-new-folder-in-list", saveAs: "phone-new-folder-in-list", in: Self.editorShots)
        XCTAssertTrue(session.store.journal.outbox().filter { $0.path.hasPrefix(path) }.isEmpty, "nothing to send yet")

        router.open(.folder(path))
        await waitToSee("list.projects/Ideas")
        await picture("phone-new-folder-empty", saveAs: "phone-new-folder-empty", in: Self.editorShots)

        let model = NoteEditorModel(path: nil, newNoteFolder: path, isEditing: true)
        await model.load(app)
        model.userEdited("# First note\n", app: app)
        await model.saveNow(app)
        XCTAssertEqual(model.path, "projects/Ideas/First note.md")
        await session.engine.sync(.background)
        XCTAssertEqual(session.store.status(of: "projects/Ideas/First note.md"), .synced, "the folder is on GitHub with it")
        await waitUntil("the note in the list") { self.app.folderTree.first { $0.name == "projects" }?.children.first { $0.path == path }?.totalCount == 1 }

        // A folder inside that one, and one at the top level.
        guard case .success = await app.createFolder(named: "Deeper", in: path) else { return XCTFail("no folder") }
        guard case .success = await app.createFolder(named: "תיקייה חדשה", in: "") else { return XCTFail("no folder") }
        XCTAssertTrue(app.folders.contains { $0.name == "תיקייה חדשה" })
    }

    func testAFolderNameThatCantBeUsedSaysWhy() async throws {
        try await start()
        if case .success = await app.createFolder(named: "projects", in: "") { XCTFail("taken") }
        guard case .failure(.alreadyExists) = await app.createFolder(named: "PROJECTS", in: "") else { return XCTFail("taken in any spelling") }
        guard case .failure(.noName) = await app.createFolder(named: "  ", in: "") else { return XCTFail("no name") }
        guard case .failure(.notAllowed) = await app.createFolder(named: "private", in: "") else { return XCTFail("blocked") }
        guard case .failure(.notAllowed) = await app.createFolder(named: "x.md", in: "") else { return XCTFail("a note's name") }
    }

    func testPressingNewFolderAsksForAName() async throws {
        try await start()
        buildAccessibilityTree()
        show(RootView())
        await press("folder.new")
        await settle(300)
        // An alert is a sheet of its own.
        let asked = window.attachedSheet != nil || NSApp.windows.contains { $0 !== window && $0.isVisible }
        XCTAssertTrue(asked, "the name prompt came up")
        window.attachedSheet.map { window.endSheet($0) }
    }

    // MARK: editor slice: the Mac's Format menu and toolbar

    func testTheFormatActionsWorkOnTheEditor() async throws {
        try await start()
        let path = try await saved("plain line\nשורה בעברית\n")
        show(NoteScreen(path: path, startEditing: true))
        await waitUntil("editor") { self.editorTextView()?.string == "plain line\nשורה בעברית\n" }
        let view = try XCTUnwrap(editorTextView() as? EditorTextView)
        // What the menu and the toolbar send, up the responder chain from the first responder.
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(view.tryToPerform(#selector(EditorTextView.performEditorAction(_:)), with: EditorActionSender(.bold)))
        XCTAssertEqual(Array(view.string.utf8), Array("**plain** line\nשורה בעברית\n".utf8))
        XCTAssertTrue(view.tryToPerform(#selector(EditorTextView.performEditorAction(_:)), with: EditorActionSender(.bold)))
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
        press(.numbered, "1. plain line\nשורה בעברית\n")
        press(.indent, "   1. plain line\nשורה בעברית\n")
        press(.outdent, "1. plain line\nשורה בעברית\n")
        press(.numbered, "plain line\nשורה בעברית\n")
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
        // Table insert: start from a clean line so the expected bytes stay readable.
        view.string = "Hi\n"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.performEditorAction(EditorActionSender(.table))
        XCTAssertTrue(view.string.hasPrefix("Hi\n\n|"), view.string)
        XCTAssertTrue(view.string.contains("|---|---|---|"), view.string)
        XCTAssertTrue(window.firstResponder is TableCellEditor, "the caret is in the first cell of a grid, not in any text form")
    }

    /// From the real screen to the file: what is saved is valid GFM, and it comes back as a grid.
    func testATableEditedInTheGridIsSavedAsGFMAndReopensAsAGrid() async throws {
        try await start(stack: true)
        let path = try await saved("Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("editor") { (self.editorTextView() as? EditorTextView)?.coordinator?.tables?.grids.count == 1 }
        let view = try XCTUnwrap(editorTextView() as? EditorTextView)
        let overlay = try XCTUnwrap(view.coordinator?.tables)
        // After the note has taken the focus it takes on opening.
        await settle(300)
        overlay.focusCell(TableCellAddress(table: 0, cell: GridCell(row: 1, column: 0)), caret: .end)
        await settle(100)
        let cell = try XCTUnwrap(overlay.grids[0].editor)
        cell.insertText("|x", replacementRange: cell.selectedRange())
        overlay.perform(.addRowBelow)
        cell.insertText("new", replacementRange: cell.selectedRange())
        overlay.perform(.addColumnAfter)
        let expected = "Intro\n\n| a | | b |\n|---|---|---|\n| 1\\|x | | 2 |\n| new | | |\n"
        XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8), view.string.debugDescription)
        await waitUntil("the autosave") { (try? self.bytes(path)) == Array(expected.utf8) }
        let table = try XCTUnwrap(TableDocument(parsing: expected).tables.first)
        XCTAssertTrue(table.isRectangular)
        XCTAssertEqual(table.gridRowCount, 3)
        XCTAssertEqual(table.gridText(row: 1, column: 0), "1|x")

        // Open again: a grid, from the file, and nothing written by looking at it.
        show(NavigationStack { NoteScreen(path: path, startEditing: true) })
        await waitUntil("the grid again") { (self.editorTextView() as? EditorTextView)?.coordinator?.tables?.spans.first?.table.gridText(row: 2, column: 0) == "new" }
        await settle(500)
        XCTAssertEqual(try bytes(path), Array(expected.utf8))
    }

    /// The test host is the real app, so its menu bar is the real one.
    func testTheFormatMenuHasTheShortcutsTheSliceAsksFor() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Format")?.submenu, "the Format menu")
        func item(_ action: EditorAction) throws -> NSMenuItem {
            try XCTUnwrap(menu.item(withTitle: action.label), action.label)
        }
        XCTAssertEqual(try item(.bold).keyEquivalent, "b")
        XCTAssertEqual(try item(.italic).keyEquivalent, "i")
        XCTAssertEqual(try item(.title).keyEquivalent, "1")
        XCTAssertEqual(try item(.heading).keyEquivalent, "2")
        XCTAssertEqual(try item(.subheading).keyEquivalent, "3")
        XCTAssertEqual(try item(.checklist).keyEquivalent.lowercased(), "l")
        XCTAssertTrue(try item(.checklist).keyEquivalentModifierMask.contains(.shift))
        XCTAssertEqual(try item(.indent).keyEquivalent, "]")
        XCTAssertEqual(try item(.outdent).keyEquivalent, "[")
        for action in [EditorAction.bold, .italic, .title, .heading, .subheading, .checklist, .indent, .outdent] {
            XCTAssertTrue(try item(action).keyEquivalentModifierMask.contains(.command), action.label)
        }
        for action in EditorAction.allCases { _ = try item(action) }
    }

    func testTheToolbarShowsFormatToolsWithoutPressingThePencil() async throws {
        try await start()
        buildAccessibilityTree()
        let path = try await saved("a line\n")
        show(NavigationStack { NoteScreen(path: path, startEditing: false) })
        await waitToSee("note.viewer")
        await waitToSee("note.edit")
        for action in [EditorAction.bold, .italic, .code, .checklist, .bullet, .numbered, .link, .table, .direction] {
            await waitToSee("editor.toolbar.\(action.rawValue)")
        }
        await waitToSee("editor.toolbar.style")
        // A tool from the reading view opens the editor. The pencil is still there until then.
        await press("editor.toolbar.bold")
        await waitUntil("the editor") { self.editorTextView() != nil }
        await waitToSee("note.done")
        await waitToSee("editor.toolbar.bold")
        let view = try XCTUnwrap(editorTextView())
        XCTAssertTrue(view.string.contains("**"), view.string)
    }

    /// A narrow window keeps the note. The format tools are a ToolbarItemGroup, so the system parks what does not fit.
    func testANarrowWindowKeepsTheNoteWhenFormatToolsOverflow() async throws {
        try await start()
        buildAccessibilityTree()
        windowSize = NSSize(width: 480, height: 640)
        window.setContentSize(windowSize)
        let path = try await saved("a line\n")
        show(NavigationStack { NoteScreen(path: path, startEditing: false) })
        await waitToSee("note.viewer")
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 480, accuracy: 1)
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
        XCTAssertEqual(router.path.last, .note("עברית/סודות-ועקרונות.md"))
        show(NavigationStack { NoteScreen(path: "עברית/סודות-ועקרונות.md", startEditing: true) })
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
    /// There is no modern setter for it, so the (deprecated) `accessibilitySetValue(_:forAttribute:)` is sent by selector.
    private func buildAccessibilityTree(_ on: Bool = true) {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: on), with: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface").rawValue)
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
        let root: NSWindow = other ?? window
        return find(root, depth: 0)
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
        let end = Date().addingTimeInterval(5)
        while Date() < end, isEnabled(id) == false {
            try? await Task.sleep(for: .milliseconds(25))
        }
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
        for id in ["onboarding.welcome", "onboarding.connect", "onboarding.code", "onboarding.codeEnded", "onboarding.choose"] {
            XCTAssertFalse(isShowing(id), "\(id) on screen. \(context)", file: file, line: line)
        }
    }

    /// One `cacheDisplay` of the test window and the strings Vision read from that exact image.
    private struct WindowReading {
        var strings: [String]
        var bitmap: NSBitmapImageRep
    }

    /// The window's text, read back from its pixels: what a person sees, which the accessibility tree can't
    /// tell, since a label stays the same when the letters on screen are in another order.
    private func textOnScreen() async throws -> [String] {
        try await readWindow().strings
    }

    /// Words in the window bitmap. The 2240×1484 capture of the lentil note shows the title, and the accurate
    /// pass returned no strings and did not throw, so the fast pass never ran. Recognition uses an 8-bit image
    /// of that same bitmap, with the long side capped, and an empty accurate result tries fast.
    private func readWindow() async throws -> WindowReading {
        let drawn = await drawWindow()
        let bitmap = try XCTUnwrap(drawn)
        let image = try XCTUnwrap(Self.imageForRecognition(from: bitmap))
        let strings = try await Self.recognizeText(in: image)
        return WindowReading(strings: strings, bitmap: bitmap)
    }

    private struct TextRecognitionTimedOut: Error, CustomStringConvertible {
        let seconds: Int
        var description: String { "Vision text recognition did not answer within \(seconds) s" }
    }

    /// Vision runs on a background queue, not the main thread, and gives up after `seconds`. A recognition that
    /// can't get a worker thread once froze the whole run for 30 minutes (build 6, 2026-11-14,
    /// `testAFolderMadeInAFolderShowsThereAndHoldsANote`: E5 model warnings, then nothing). The cause was the stranded
    /// window-animation threads `makeWindow` now avoids; this limit makes any repeat a failed test, not a hang.
    private nonisolated static func recognizeText(in image: CGImage, timeout seconds: Int = 45) async throws -> [String] {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        struct Image: @unchecked Sendable { let cg: CGImage }
        let box = Image(cg: image)
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try recognizeTextNow(in: box.cg) }
                if once.claim() { continuation.resume(with: result) }
            }
            // The deadline is on the main queue, which stays free: it fires even if no worker thread is left.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
                if once.claim() { continuation.resume(throwing: TextRecognitionTimedOut(seconds: seconds)) }
            }
        }
    }

    private nonisolated static func recognizeTextNow(in image: CGImage) throws -> [String] {
        func read(_ level: VNRequestTextRecognitionLevel) throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        // Accurate throws on some machines (e5rt error 13). An empty result is the wide-window failure: the
        // pixels contain the title, and fast is the pass that still reads them.
        let accurate: [String]
        do { accurate = try read(.accurate) } catch { accurate = [] }
        return accurate.isEmpty ? try read(.fast) : accurate
    }

    /// The PNG of the cache is the image that shows the title. Its decode is 8-bit, and a long side over 2048
    /// is scaled down. `NSBitmapImageRep.cgImage` from `cacheDisplay` is what the accurate pass read as nothing.
    private static func imageForRecognition(from bitmap: NSBitmapImageRep) -> CGImage? {
        let decoded = bitmap.representation(using: .png, properties: [:]).flatMap { NSBitmapImageRep(data: $0) } ?? bitmap
        let width = decoded.pixelsWide
        let height = decoded.pixelsHigh
        let longest = max(width, height)
        let cap = 2048
        guard longest > cap else { return decoded.cgImage }
        let scale = Double(cap) / Double(longest)
        let destW = max(1, Int((Double(width) * scale).rounded(.down)))
        let destH = max(1, Int((Double(height) * scale).rounded(.down)))
        guard let dest = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: destW,
            pixelsHigh: destH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return decoded.cgImage }
        // The current context is not part of the graphics state. Leaving it on this bitmap sent later
        // window drawing, including Open My Notes, into the bitmap instead of the test window.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dest)
        decoded.draw(in: NSRect(x: 0, y: 0, width: destW, height: destH))
        NSGraphicsContext.current = previous
        return dest.cgImage ?? decoded.cgImage
    }

    /// The bitmap Vision just failed to read, still at the wide size, before the phone-size picture.
    private func attachWideOCRBitmap(_ bitmap: NSBitmapImageRep) {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "wide-ocr-bitmap-\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// How much of the bitmap is dark ink. Zero means the capture itself has no type.
    private static func bitmapFacts(_ bitmap: NSBitmapImageRep) -> String {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var dark = 0
        var samples = 0
        let step = 16
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                samples += 1
                if color.redComponent < 0.32, color.greenComponent < 0.32, color.blueComponent < 0.32 {
                    dark += 1
                }
            }
        }
        let share = samples > 0 ? Double(dark) / Double(samples) : 0
        return "\(width)x\(height) dark \(String(format: "%.3f", share))"
    }

    // MARK: onboarding: who sees what

    func testFreshInstallWalksToTheSampleNotesAndTheNextLaunchGoesStraightToFolders() async throws {
        try await launchDevice()
        await waitToSee("onboarding.welcome")
        await waitToSee("signin.start")
        await waitToSee("onboarding.sample")
        XCTAssertFalse(isShowing("onboarding.continue"), "welcome and connect are one screen")
        XCTAssertFalse(isShowing("onboarding.connect"))
        XCTAssertFalse(environment?.onboardedFlag ?? true)

        await press("onboarding.sample")
        await waitUntil("the sample notes") { self.app.phase == .ready }
        // Straight into the sample notes: no "You're all set" screen in between.
        await waitToSee("home.list")
        assertNoOnboardingOnScreen("sample notes open directly")
        XCTAssertTrue(environment?.onboardedFlag ?? false, "opening the notes ends first run")
        XCTAssertTrue(app.session?.isDemo == true)
        XCTAssertTrue(app.folders.contains { $0.name == "projects" }, "the demo brain")

        try await relaunchDevice()
        await waitToSee("home.list")
        XCTAssertFalse(isShowing("onboarding.welcome"), "second launch: straight to Folders")
        XCTAssertFalse(isShowing("onboarding.connect"))
    }

    func testAKillMidFlowStartsAtWelcomeAgain() async throws {
        try await launchDevice()
        await waitToSee("onboarding.welcome")
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
                let expectedScreen = device.keychainLocked ? "repoIssue.view" : "home.list"
                await waitToSee(expectedScreen)
                assertNoOnboardingOnScreen(context)
                // And not a moment later either, when the launch work has finished.
                await settle(300)
                await waitToSee(expectedScreen)
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
        await waitToSee("repoIssue.view")
        assertNoOnboardingOnScreen()
        XCTAssertEqual(app.noteCount, 0, "cold launch with unverified /user hides local notes until verified")
        await press("repoIssue.signIn")
        await waitUntil("the sheet on relaunch") { self.app.showSignIn }
        assertNoOnboardingOnScreen()
        app.showSignIn = false
    }

    func testSignOutAndWipeReturnsToConnectNotWelcomeEvenAfterAKill() async throws {
        try await launchDevice(signedIn: true)
        await waitToSee("home.list")
        XCTAssertEqual(environment?.onboardedFlag, false, "signed in before these screens existed")

        await app.signOutAndWipe()
        await waitToSee("onboarding.connect")
        await waitToSee("signin.start")
        await waitToSee("onboarding.sample")
        XCTAssertFalse(isShowing("onboarding.welcome"))
        XCTAssertFalse(isShowing("onboarding.continue"))
        XCTAssertNil(try environment?.tokens.load(), "the token is gone")

        try await relaunchDevice()
        await waitToSee("onboarding.connect")
        XCTAssertFalse(isShowing("onboarding.welcome"))
    }

    func testConnectGitHubInSettingsLeavesTheSampleNotesForConnect() async throws {
        try await launchDevice()
        await press("onboarding.sample")
        await waitUntil("the sample notes") { self.app.phase == .ready }
        await waitToSee("home.list")
        XCTAssertTrue(environment?.demoFolderExists ?? false)

        router.open(.settings)
        await waitToSee("settings.connect")
        XCTAssertFalse(isShowing("settings.wipe"), "nothing to sign out of")
        XCTAssertFalse(isShowing("settings.repo"))

        await press("settings.connect")
        await waitToSee("onboarding.connect")
        await waitToSee("signin.start")
        await waitToSee("onboarding.sample")
        XCTAssertFalse(isShowing("onboarding.welcome"))
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertFalse(environment?.demoFolderExists ?? true)
        XCTAssertEqual(router.path, [], "nothing left of the sample session's navigation")
        XCTAssertEqual(environment?.transport.requests, [])
    }

    func testSettingsOfALiveSessionHasNoConnectButton() async throws {
        try await launchDevice(signedIn: true)
        await waitUntil("owner verified at launch") { self.app.signedInUser?.login == "alice" }
        try app.session?.store.save(path: "draft.md", text: "# Draft\n")
        await app.noteSaved()
        await app.setPaused(true)
        XCTAssertTrue(app.isUserPaused, "pause state available synchronously before Settings loads")

        router.open(.settings)
        await waitToSee("settings.wipe")
        await waitToSee("settings.repo")
        await waitToSee("settings.signedInAs")
        await waitToSee("settings.changeRepo")
        await waitToSee("settings.unsynced")
        await waitToSee("settings.githubAccess")
        await waitToSee("settings.privacy")
        await waitToSee("settings.support")
        XCTAssertFalse(isShowing("settings.connect"))
        XCTAssertFalse(isShowing("settings.notYouSignOut"), "duplicate Not you? Sign out row removed")
        XCTAssertFalse(isShowing("settings.storage"), "audit storage row removed")
        XCTAssertFalse(isShowing("settings.credentials"), "audit credentials row removed")
        XCTAssertFalse(isShowing("settings.analytics"), "audit analytics row removed")

        let changeLabel = accessibilityNode("settings.changeRepo")?.accessibilityLabel?() ?? ""
        XCTAssertEqual(changeLabel, "Change notes…")
        let read = try await textOnScreen().joined(separator: " ")
        XCTAssertTrue(read.contains("Signed in as @alice"), "read: \(read)")
        // owner/name: the reading can take the "/" for an "l" or a "|".
        XCTAssertNotNil(read.range(of: "alice.private-notes", options: .regularExpression), "read: \(read)")
        XCTAssertTrue(read.contains("Waiting to sync"), "read: \(read)")

        await app.setPaused(false)
    }

    // MARK: onboarding: signing in

    func testSignInFromTheFirstScreenGoesStraightToGitHubAndThenTheNotes() async throws {
        try await launchDevice()
        await waitToSee("onboarding.welcome")
        await press("signin.start")
        await waitToSee("signin.code")
        await waitToSee("signin.copy")
        await waitToSee("signin.open")
        XCTAssertEqual(app.phase, .needsSignIn)

        // Approved on GitHub. Its API is held, so the first sync stays at its first step.
        environment?.transport.approve()
        // No "Connected as" screen: the code screen says who signed in, and GitHub's access page opens by itself.
        await waitUntil("GitHub configure page opened immediately") {
            self.app.isAwaitingInitialGitHubGrant && self.environment?.webSession.openedURLs.last?.absoluteString == "https://github.com/settings/installations/77"
        }
        await waitToSee("signin.signedInAs")
        await waitToSee("signin.different")
        await waitToSee("signin.waitingForGitHub")
        await waitToSee("signin.reopenGitHub")
        XCTAssertEqual(isEnabled("signin.reopenGitHub"), true, "Open GitHub works while waiting")
        XCTAssertEqual(isEnabled("signin.different"), true, "Use a different account works while waiting")
        XCTAssertEqual(isEnabled("signin.cancel"), true, "Cancel works while waiting")
        XCTAssertFalse(isShowing("onboarding.confirm"))
        XCTAssertFalse(isShowing("onboarding.choose"), "GitHub opens directly without showing Choose notes first")
        await picture("phone-3b-waiting-for-github", saveAs: "phone-3b-waiting-for-github-light")

        environment?.transport.hold()
        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        // One private repository granted: the notes, at once, with the first sync running behind them.
        await waitToSee("home.list")
        assertNoOnboardingOnScreen("one granted repository opens the notes")
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.sampleMode)
        XCTAssertTrue(environment?.onboardedFlag ?? false)
        await waitUntil("the first sync is running") { self.app.snapshot.state.isBusy }
        await picture("phone-4-notes-first-sync", saveAs: "phone-4-notes-first-sync-light")
        environment?.transport.release()
    }

    /// Several granted repositories: the picker. A switch from Settings goes straight back to the notes too.
    func testChooseOmitsNotYouSignOutAndNoReadyScreenAnywhere() async throws {
        environment = try OnboardingEnvironment()
        environment?.transport.setRepositories([
            .init(repoId: 4242, owner: "acme", name: "team-notes", defaultBranch: "main", isPrivate: true)
        ])
        try await launchDevice()
        await waitToSee("onboarding.welcome")
        await press("signin.start")
        await waitToSee("signin.code")
        environment?.transport.approve()
        await waitUntil("GitHub configure page opened") { self.app.isAwaitingInitialGitHubGrant }
        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))

        // Single private org repo ("acme/team-notes") auto-connects after GitHub return: straight into the notes.
        await waitToSee("home.list")
        assertNoOnboardingOnScreen("first run")
        XCTAssertEqual(app.signedInUser?.login, "alice")
        XCTAssertEqual(app.session?.repo.slug, "acme/team-notes")
        let firstRoot = try XCTUnwrap(app.session?.store.root)
        try app.session?.store.save(path: "keep-until-switch.md", text: "# Keep\n")

        // Settings -> Change notes… with two granted repos opens configure immediately, keeps local copy,
        // presents the picker on return (without Not you? Sign out), and goes back to the notes after switching.
        environment?.transport.setRepositories([
            .init(repoId: 4242, owner: "acme", name: "team-notes", defaultBranch: "main", isPrivate: true),
            .init(repoId: 5151, owner: "acme", name: "second-notes", defaultBranch: "main", isPrivate: true),
        ])
        await app.changeNotesRepository()
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstRoot.path), "local copy preserved before new pick verified")
        app.handleOpenURL(try XCTUnwrap(URL(string: "brainnotes://setup")))
        await waitToSee("onboarding.choose")
        await waitToSee("onboarding.pick.acme/second-notes")
        await waitToSee("onboarding.createBrain")
        XCTAssertFalse(isShowing("onboarding.notYouSignOut"), "Not you? Sign out removed from Choose notes")

        await press("onboarding.pick.acme/second-notes")
        await waitUntil("switched to acme/second-notes") { self.app.session?.repo.slug == "acme/second-notes" }
        await waitToSee("home.list")
        assertNoOnboardingOnScreen("a Settings switch")
        XCTAssertFalse(app.showsOnboarding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRoot.path), "previous repo wiped after new pick verified")

        await app.signOutAndWipe()
        await waitToSee("onboarding.connect")
        XCTAssertEqual(app.phase, .needsSignIn)
        XCTAssertNil(app.session)
        XCTAssertNil(try environment?.tokens.load())
    }

    func testCancelOnTheCodeGoesBackToConnectAndStopsPolling() async throws {
        try await launchDevice()
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

    // MARK: the test harness itself

    private func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    /// A test window that animates in and out strands a GCD thread each time, and ~64 of them starve every later
    /// test that needs a worker thread: the 30-minute hang of 2026-11-14. Twenty windows here would leave twenty or more.
    func testOpeningAndClosingTestWindowsLeavesNoThreadsBehind() async throws {
        try await start(stack: true)
        await settle(300)
        let before = threadCount()
        for i in 0..<20 {
            makeWindow(stack: i.isMultiple(of: 2), dark: false)
            show(Text("window \(i)"))
            await settle(30)
        }
        window?.orderOut(nil)
        await settle(1500)
        let after = threadCount()
        XCTAssertGreaterThan(before, 0)
        XCTAssertLessThan(after - before, 8, "threads before \(before), after \(after)")
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

    func testOfflineOnTheFirstScreenPointsToTheSampleNotes() async throws {
        try await launchDevice()
        await waitToSee("onboarding.welcome")
        XCTAssertFalse(isShowing("onboarding.offline"))
        await app.setOnline(false)
        await waitToSee("onboarding.offline")
        await waitToSee("onboarding.sample")
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
                       ("code", "3-code", "signin.code"), ("choose", "3b-choose", "onboarding.choose")]
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

    /// The states the other pictures show in light. Dark has its own slate blue and its own button colours.
    func testStatePicturesInDark() async throws {
        try await launchDevice(dark: true)
        show(OnboardingFlow(start: .connect))
        await app.setOnline(false)
        await waitToSee("onboarding.offline")
        await picture("phone-2-connect-offline-dark", saveAs: "phone-2-connect-offline-dark")
        // Last: a replaced hosting view leaves this screen's toolbar on the test window.
        show(OnboardingFlow(start: .deviceCode, signIn: SignInModel(step: .failed("The code ran out. You can get a new one."))))
        await waitToSee("signin.newCode")
        await picture("phone-3-code-expired-dark", saveAs: "phone-3-code-expired-dark")
    }

    func testSettingsPictureInSampleMode() async throws {
        try await launchDevice()
        await press("onboarding.sample")
        await waitUntil("the sample notes") { self.app.phase == .ready }
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
        for (name, step, button) in [("1-welcome", OnboardingStep.welcome, "onboarding.sample"), ("2-connect", .connect, "signin.start"), ("3-code", .deviceCode, "signin.open")] {
            show(OnboardingFlow(start: step))
            await waitToSee(button)
            await picture("phone-\(name)-small-window", saveAs: "phone-\(name)-small-window")
            let frame = try XCTUnwrap(accessibilityNode(button)?.accessibilityFrame?())
            XCTAssertFalse(frame.isEmpty, button)
            XCTAssertTrue(window.frame.contains(frame), "\(button) is at \(frame), outside the window at \(window.frame)")
        }
    }
}

// MARK: accessibility audit (cloud/a11y-rtl-audit)

extension ScreenWalkTests {
    /// Differentiate Without Color: each note state gets a shape of its own, and every one is a real symbol.
    func testEveryNoteStateHasItsOwnShapeForWhenColourIsNotEnough() {
        let all: [NoteSyncStatus] = [.savedOnDevice, .syncing, .synced, .needsAttention]
        XCTAssertEqual(Set(all.map(\.shapeSymbol)).count, all.count, "two states share a shape")
        XCTAssertEqual(Set(all.map(\.label)).count, all.count, "two states share their words")
        for status in all {
            XCTAssertNotNil(NSImage(systemSymbolName: status.shapeSymbol, accessibilityDescription: nil), status.shapeSymbol)
        }
    }

    /// VoiceOver reads a task as its rendered words, never its Markdown marks, in both languages.
    func testATaskIsReadWithoutItsMarkdownMarks() {
        XCTAssertEqual(BlockView.taskLabel(done: true, inline: NoteText.inlineMarkdown("**Buy** milk")), "Done: Buy milk")
        XCTAssertEqual(BlockView.taskLabel(done: false, inline: NoteText.inlineMarkdown("לקנות *חלב*")), "To do: לקנות חלב")
        XCTAssertEqual(BlockView.taskLabel(done: false, inline: NoteText.inlineMarkdown("see [the docs](https://example.com)")), "To do: see the docs")
    }

    /// A row's icon is decoration: VoiceOver says "Inbox", not "tray, Inbox".
    func testACountRowIsReadWithoutItsIconName() async throws {
        // First Mac run (5 Nov): "home.inbox did not appear". A row inside the Mac List is not reached by this
        // in-process tree walk (no other test finds a List row either). The icon is still hidden in CountRow;
        // check it with VoiceOver on the iPhone until this test can reach the row.
        try XCTSkipIf(true, "Mac List rows are not reachable through the in-process accessibility tree")
        try await start()
        buildAccessibilityTree()
        show(RootView())
        await waitToSee("home.inbox")
        let label = try XCTUnwrap(accessibilityNode("home.inbox")?.accessibilityLabel?())
        XCTAssertTrue(label.contains("Inbox"), label)
        XCTAssertFalse(label.localizedCaseInsensitiveContains("tray"), label)
    }
}
