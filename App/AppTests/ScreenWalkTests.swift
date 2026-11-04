import AppKit
import BrainNotesKit
import SwiftUI
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
        session = nil
        app = nil
        router = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func show(_ view: some View) {
        let host = NSHostingView(rootView: AnyView(view.environment(app).environment(router).tint(Color.accentColor)))
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

    /// The window as drawn, title bar and toolbar included, attached to the test result.
    private func picture(_ name: String) async {
        await settle()
        // Navigation can shrink a test window to its content; the real windows are sized by the system.
        window.setContentSize(windowSize)
        await settle(150)
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
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
}
