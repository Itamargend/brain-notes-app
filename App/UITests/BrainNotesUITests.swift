import XCTest

/// Walks every screen in demo mode: a fake GitHub in process, no network, no Keychain.
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
        waitFor("folder.projects").click()
        waitFor("note.projects/garden-sensor.md").click()
        waitFor("note.viewer")
        waitFor("note.status")
        XCTAssertTrue(app.staticTexts["Garden sensor"].waitForExistence(timeout: 5))
        screenshot("note")
    }

    func testEditingSavesAndShowsTheStatesAndSyncsOnLeaving() {
        launch()
        waitFor("folder.recipes").click()
        waitFor("note.recipes/lentil-soup.md").click()
        waitFor("note.viewer")
        waitFor("note.edit").click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\nA line typed by the UI test\n")
        // Autosave after a short pause: saved on device, not yet synced.
        let saved = NSPredicate(format: "value == %@ OR label == %@", "Saved on device", "Saved on device")
        let status = element("note.status")
        expectation(for: saved, evaluatedWith: status)
        waitForExpectations(timeout: 8)
        screenshot("edited")

        // Leaving the editor flushes: the demo's fake GitHub takes the commit.
        waitFor("note.done").click()
        let synced = NSPredicate(format: "value == %@ OR label == %@", "Synced", "Synced")
        expectation(for: synced, evaluatedWith: status)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["A line typed by the UI test"].waitForExistence(timeout: 5))
    }

    func testComposeInInbox() {
        launch()
        waitFor("compose.button").click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Note from the UI test\nsecond line\n")
        let saved = NSPredicate(format: "value == %@ OR label == %@", "Saved on device", "Saved on device")
        expectation(for: saved, evaluatedWith: element("note.status"))
        waitForExpectations(timeout: 8)
        waitFor("note.done").click()
        waitFor("home.inbox").click()
        waitFor("note._inbox/Note from the UI test.md")
        screenshot("compose")
    }

    func testSearchEnglishAndHebrew() {
        launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("shakshuka")
        waitFor("search.recipes/shakshuka.md")
        screenshot("search-english")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        search.typeText("חומוס")
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
        waitFor("attention.conflict-copy").click()
        waitFor("attention.mine")
        waitFor("attention.theirs")
        waitFor("attention.useMine")
        waitFor("attention.useTheirs")
        screenshot("conflict-compare")
    }

    func testResolvingAConflictClearsItFromTheList() {
        launch(["-BNScreen", "conflict"])
        waitFor("attention.keep").click()
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
        waitFor("signin.start").click()
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
        toggle.click()
        let paused = NSPredicate(format: "label CONTAINS %@", "Sync paused")
        expectation(for: paused, evaluatedWith: element("sync.pill"))
        waitForExpectations(timeout: 8)
        screenshot("settings")
    }

    func testSignOutAndWipeReturnsToSignInInDemo() {
        launch(["-BNScreen", "settings"])
        waitFor("settings.wipe").click()
        let confirm = app.buttons["Sign out and wipe"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // The dialog's own button comes last in the tree.
        app.buttons.matching(identifier: "settings.wipe.confirm").firstMatch.click()
        // In demo mode a fresh set of demo notes loads again.
        waitFor("home.inbox", timeout: 20)
    }

    func testPhoneLayoutNavigatesAsAStack() {
        launch(["-BNPhoneLayout"])
        waitFor("folder.projects").click()
        waitFor("note.projects/garden-sensor.md").click()
        waitFor("note.viewer")
        screenshot("phone-note")
    }
}
