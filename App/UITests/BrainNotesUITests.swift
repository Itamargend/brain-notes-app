import XCTest

private extension XCUIElement {
    /// A click on Mac, a tap on iPhone.
    func press() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }

    /// Puts the caret at the end of a text view.
    func moveCaretToEnd() {
        #if os(macOS)
        typeKey(.downArrow, modifierFlags: .command)
        #endif
    }

    /// Replaces what a search field holds.
    func replaceText(with text: String) {
        #if os(macOS)
        typeKey("a", modifierFlags: .command)
        typeKey(.delete, modifierFlags: [])
        #else
        if buttons["Clear text"].exists { buttons["Clear text"].tap() }
        #endif
        typeText(text)
    }
}

/// Walks every screen in demo mode: a fake GitHub in process, no network, no Keychain.
/// Real clicks, so a Mac needs automation mode enabled once by an admin:
/// `sudo automationmodetool enable-automationmode-without-authentication`.
/// Run with the `BrainNotesUITests` scheme.
final class BrainNotesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-BNDemoFixtures"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func waitFor(_ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) did not appear", file: file, line: line)
        return e
    }

    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testHomeShowsInboxFoldersAndAttention() {
        launch()
        waitFor("home.inbox")
        waitFor("home.attention")
        waitFor("folder.projects")
        waitFor("folder.עברית")
        waitFor("note.todo.md")
        waitFor("sync.pill")
        XCTAssertFalse(element("folder._trash").exists)
        XCTAssertFalse(element("folder._inbox").exists, "Inbox is its own row, not a folder")
        screenshot("home")
    }

    func testFolderListAndNoteView() {
        launch()
        waitFor("folder.projects").press()
        waitFor("note.projects/garden-sensor.md").press()
        waitFor("note.viewer")
        waitFor("note.status")
        XCTAssertTrue(app.staticTexts["Garden soil sensor"].waitForExistence(timeout: 5))
        screenshot("note")
    }

    func testEditingSavesAndShowsTheStatesAndSyncsOnLeaving() {
        launch()
        waitFor("folder.recipes").press()
        waitFor("note.recipes/lentil-soup.md").press()
        waitFor("note.viewer")
        waitFor("note.edit").press()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.press()
        editor.moveCaretToEnd()
        editor.typeText("\nA line typed by the UI test\n")
        // Autosave after a short pause: saved on device, not yet synced.
        let saved = NSPredicate(format: "value == %@ OR label == %@", "Saved on device", "Saved on device")
        let status = element("note.status")
        expectation(for: saved, evaluatedWith: status)
        waitForExpectations(timeout: 8)
        screenshot("edited")

        // Leaving the editor flushes: the demo's fake GitHub takes the commit.
        waitFor("note.done").press()
        let synced = NSPredicate(format: "value == %@ OR label == %@", "Synced", "Synced")
        expectation(for: synced, evaluatedWith: status)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["A line typed by the UI test"].waitForExistence(timeout: 5))
    }

    func testComposeInInbox() {
        launch()
        waitFor("compose.button").press()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.press()
        editor.typeText("Note from the UI test\nsecond line\n")
        let saved = NSPredicate(format: "value == %@ OR label == %@", "Saved on device", "Saved on device")
        expectation(for: saved, evaluatedWith: element("note.status"))
        waitForExpectations(timeout: 8)
        waitFor("note.done").press()
        waitFor("home.inbox").press()
        waitFor("note._inbox/Note from the UI test.md")
        screenshot("compose")
    }

    func testSearchEnglishAndHebrew() {
        launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.press()
        search.typeText("shakshuka")
        waitFor("search.recipes/shakshuka.md")
        screenshot("search-english")
        search.replaceText(with: "חומוס")
        waitFor("search.עברית/מתכון-חומוס.md")
        screenshot("search-hebrew")
    }

    func testInboxMarksConflictCopies() {
        launch(["-BNScreen", "inbox"])
        waitFor("list._inbox")
        let copy = app.staticTexts["Conflict copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        screenshot("inbox")
    }

    func testNeedsAttentionOpensBothSidesAndKeepBothCloses() {
        launch(["-BNScreen", "attention"])
        waitFor("attention.conflict-copy").press()
        waitFor("attention.mine")
        waitFor("attention.theirs")
        waitFor("attention.useMine")
        waitFor("attention.useTheirs")
        screenshot("conflict-compare")
    }

    func testResolvingAConflictClearsItFromTheList() {
        launch(["-BNScreen", "conflict"])
        waitFor("attention.keep").press()
        // Two items were staged: one remains after resolving this one.
        waitFor("home.attention")
        let pill = element("sync.pill")
        let one = NSPredicate(format: "label CONTAINS %@", "1 needs attention")
        expectation(for: one, evaluatedWith: pill)
        waitForExpectations(timeout: 10)
    }

    func testConflictNoteShowsABanner() {
        launch(["-BNScreen", "note"])
        waitFor("note.banner")
        screenshot("banner")
    }

    func testHebrewNoteOpens() {
        launch(["-BNHebrew"])
        waitFor("note.viewer")
        XCTAssertTrue(app.staticTexts["סיכום פגישה עם נועה"].waitForExistence(timeout: 5))
        screenshot("hebrew")
    }

    func testSignInScreenShowsTheCode() {
        launch(["-BNScreen", "signin"])
        waitFor("signin.start").press()
        waitFor("signin.code")
        waitFor("signin.copy")
        waitFor("signin.open")
        screenshot("signin")
    }

    func testSettingsShowsTheRepoAndPauses() {
        launch(["-BNScreen", "settings"])
        waitFor("settings.repo")
        XCTAssertTrue(app.staticTexts["Itamargend/brain-notes-test"].waitForExistence(timeout: 5))
        let toggle = waitFor("settings.pause")
        toggle.press()
        let paused = NSPredicate(format: "label CONTAINS %@", "Sync paused")
        expectation(for: paused, evaluatedWith: element("sync.pill"))
        waitForExpectations(timeout: 8)
        screenshot("settings")
    }

    func testSignOutAndWipeReturnsToSignInInDemo() {
        launch(["-BNScreen", "settings"])
        waitFor("settings.wipe").press()
        let confirm = app.buttons["Sign out and wipe"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // The dialog's own button comes last in the tree.
        app.buttons.matching(identifier: "settings.wipe.confirm").firstMatch.press()
        // In demo mode a fresh set of demo notes loads again.
        waitFor("home.inbox", timeout: 20)
    }

    func testPhoneLayoutNavigatesAsAStack() {
        launch(["-BNPhoneLayout"])
        waitFor("folder.projects").press()
        waitFor("note.projects/garden-sensor.md").press()
        waitFor("note.viewer")
        screenshot("phone-note")
    }
}
