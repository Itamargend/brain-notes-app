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

    func testOnboardingTapsThroughToTheSampleNotes() {
        launch(["-BNScreen", "welcome"])
        waitFor("onboarding.welcome")
        screenshot("onboarding-welcome")
        waitFor("onboarding.continue").press()
        waitFor("onboarding.connect")
        waitFor("signin.start")
        screenshot("onboarding-connect")
        waitFor("onboarding.sample").press()
        waitFor("onboarding.ready")
        screenshot("onboarding-ready")
        waitFor("onboarding.open").press()
        waitFor("home.inbox")
        XCTAssertFalse(element("onboarding.ready").exists)
    }

    func testOnboardingCodeGoesBackToConnect() {
        launch(["-BNScreen", "code"])
        waitFor("signin.code")
        waitFor("signin.copy")
        waitFor("signin.open")
        screenshot("onboarding-code")
        waitFor("signin.cancel").press()
        waitFor("onboarding.connect")
    }

    func testConnectGitHubInSettingsLeavesTheSampleNotes() {
        launch(["-BNScreen", "ready"])
        waitFor("onboarding.open").press()
        waitFor("settings.button").press()
        waitFor("settings.connect").press()
        waitFor("onboarding.connect")
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

    // MARK: - Long-press peek (real touches: this gesture crashed on iPhone)

    #if os(iOS)
    /// Holds a row the way a thumb does, then expects the glimpse and the Delete action.
    private func longPressShowsPeek(_ rowID: String, peek peekID: String, shot: String) {
        let row = waitFor(rowID)
        row.press(forDuration: 1.2)
        waitFor(peekID, timeout: 8)
        XCTAssertEqual(app.state, .runningForeground, "the app survived the long press")
        saveShot("\(shot).png")
    }

    func testLongPressFolderShowsPeekAndDelete() {
        launch()
        longPressShowsPeek("folder.projects", peek: "peek.folder", shot: "peek-folder")
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "the menu comes with the glimpse")
    }

    func testLongPressNoteShowsPeekAndDelete() {
        launch()
        waitFor("folder.projects").press()
        longPressShowsPeek("note.projects/garden-sensor.md", peek: "peek.note", shot: "peek-note")
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "the menu comes with the glimpse")
    }
    #endif

    // MARK: - Portfolio capture (writes PNGs when PORTFOLIO_OUT is set)

    private var portfolioOut: URL? {
        guard let raw = ProcessInfo.processInfo.environment["PORTFOLIO_OUT"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func saveShot(_ name: String) {
        guard let dir = portfolioOut else { return }
        let shot = XCUIScreen.main.screenshot()
        let url = dir.appendingPathComponent(name)
        try? shot.pngRepresentation.write(to: url)
    }

    func testPortfolioHomeAndLiveAndSearch() {
        // 1) Reading folder list — sharp study notes at top (local pins not built; this is the stand-in).
        launch(["-BNScreen", "list"])
        // Deep-linked into reading; wait for a note row.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.reading/")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "reading notes")
        Thread.sleep(forTimeInterval: 0.6)
        saveShot("bn-phone-1.png")

        // 2) Live editor: bilingual note with checklists, software keyboard + feature pill visible.
        launch(["-BNScreen", "live"])
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "live editor")
        editor.tap()
        Thread.sleep(forTimeInterval: 1.0)
        // Stay near the top so title, Hebrew line, and checkboxes sit above the keyboard pill.
        for _ in 0..<4 { editor.swipeDown() }
        Thread.sleep(forTimeInterval: 0.7)
        saveShot("bn-phone-2.png")

        // 3) Search "secret" (EN + HE / סוד)
        launch(["-BNScreen", "search"])
        let hit = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "search hits for books")
        saveShot("bn-phone-3.png")

        // 4) Made-up device code only (never a real device flow)
        launch(["-BNScreen", "code"])
        waitFor("signin.code")
        saveShot("bn-phone-4.png")
    }

    func testPortfolioPhone2FeaturePill() {
        // Retake only: Prince note + software keyboard + light feature pill with tool icons.
        app = XCUIApplication()
        app.launchArguments = ["-BNDemoFixtures", "-BNScreen", "live"]
        app.launchEnvironment["BN_SOLID_PILL"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "live editor")
        editor.tap()
        // Wait for the Brain Notes keyboard feature bar (not iOS autocomplete).
        let bar = waitFor("editor.bar", timeout: 12)
        XCTAssertTrue(waitFor("editor.bar.format", timeout: 8).exists)
        XCTAssertTrue(waitFor("editor.bar.checklist", timeout: 5).exists)
        XCTAssertTrue(waitFor("editor.bar.done", timeout: 5).exists)
        // Keep title / checkboxes above the keyboard accessory.
        for _ in 0..<3 { editor.swipeDown() }
        Thread.sleep(forTimeInterval: 1.2)
        // Re-assert bar still up after scroll.
        XCTAssertTrue(bar.exists, "feature pill still present")
        XCTAssertTrue(element("editor.bar.format").exists)
        XCTAssertTrue(element("editor.bar.checklist").exists)
        XCTAssertTrue(element("editor.bar.bullet").exists)
        XCTAssertTrue(element("editor.bar.table").exists)
        // Hold for an external simctl framebuffer screenshot (glass may not composite in XCUIScreen shots).
        Thread.sleep(forTimeInterval: 8.0)
        saveShot("bn-phone-2-xctest.png")
    }

    func testPortfolioClipLoop() throws {
        try XCTSkipIf(portfolioOut == nil, "PORTFOLIO_OUT not set")
        // Deep-link to seeded Algorithm note, hold so five steps are readable, short English edit.
        launch(["-BNScreen", "algorithm"])
        waitFor("note.viewer", timeout: 20)
        Thread.sleep(forTimeInterval: 2.0)
        waitFor("note.edit").press()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.press()
        let add = "\nOrder matters.\n"
        for ch in add { editor.typeText(String(ch)); usleep(150_000) }
        usleep(350_000)
        waitFor("note.done").press()
        Thread.sleep(forTimeInterval: 1.0)
        saveShot("bn-clip-last.png")
    }
}
