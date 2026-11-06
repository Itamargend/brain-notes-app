import XCTest

/// Tables in the editor with real touches and the real keyboard, against the demo session. Run with the
/// `BrainNotesUITests` scheme. With `TEST_RUNNER_TABLE_SHOTS=<folder>`, a few of these leave pictures there, and each
/// writes `<name>.ready` while it holds, so that an outside `simctl io screenshot` can catch the real glass.
final class BrainNotesTableUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) {
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
        let found = element(id)
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "\(id) did not appear\n\(app.debugDescription)", file: file, line: line)
        return found
    }

    private func press(_ item: XCUIElement) {
        #if os(macOS)
        item.click()
        #else
        item.tap()
        #endif
    }

    /// The note's own text view: what is in the file, the table's source with it, whatever is on screen.
    private var note: XCUIElement { app.textViews.element(boundBy: 0) }

    private func noteText(file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let text = note.value as? String else {
            XCTFail("the note has no text", file: file, line: line)
            return ""
        }
        return text
    }

    private func waitForNoteText(_ what: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line, _ condition: (String) -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(noteText()) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("\(what): \(noteText().debugDescription)", file: file, line: line)
    }

    private func hasKeyboardFocus(_ item: XCUIElement) -> Bool {
        (item.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func waitForFocus(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let cell = waitFor(id, file: file, line: line)
        let focused = NSPredicate { object, _ in
            (object as? NSObject)?.value(forKey: "hasKeyboardFocus") as? Bool ?? false
        }
        expectation(for: focused, evaluatedWith: cell)
        waitForExpectations(timeout: 8)
    }

    private var shots: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TABLE_SHOTS"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func picture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shots else { return }
        try? shot.pngRepresentation.write(to: shots.appendingPathComponent("\(name)-xctest.png"))
        // Glass doesn't always composite in that shot: hold still for one taken from outside.
        try? Data().write(to: shots.appendingPathComponent("\(name).ready"))
        Thread.sleep(forTimeInterval: 6)
    }

    /// The table in a note's text, as GitHub reads it: a header row, a delimiter row with as many cells, and body rows with
    /// no more cells than that, every pipe in a cell escaped.
    private func assertValidGFM(_ markdown: String, columns: Int, rows: Int, file: StaticString = #filePath, line: UInt = #line) {
        let lines = markdown.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
        XCTAssertEqual(lines.count, rows + 1, "\(markdown.debugDescription)", file: file, line: line)
        guard lines.count >= 2 else { return }
        func cells(_ row: String) -> [String] {
            var out = [""]
            var last: Character?
            for character in row {
                if character == "|", last != "\\" { out.append("") } else { out[out.count - 1].append(character) }
                last = character
            }
            return Array(out.dropFirst().dropLast())
        }
        for row in lines { XCTAssertEqual(cells(row).count, columns, row, file: file, line: line) }
        for mark in cells(lines[1]) {
            XCTAssertTrue(mark.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" }, lines[1], file: file, line: line)
        }
    }

    // MARK: - from the pill

    private func newNoteWithATable() {
        launch(["-BNScreen", "compose"])
        waitFor("editor.bar.table", timeout: 20)
        press(element("editor.bar.table"))
        waitFor("editor.table")
    }

    func testThePillInsertsAGridWithTheCaretInItsFirstCell() {
        newNoteWithATable()
        for row in 0..<3 {
            for column in 0..<3 {
                let id = "editor.table.cell.\(row).\(column)"
                XCTAssertTrue(element(id).exists, id)
            }
        }
        waitForFocus("editor.table.cell.0.0")
        XCTAssertTrue(element("editor.bar").exists, "the glass bar is still over the keyboard")
        assertValidGFM(noteText(), columns: 3, rows: 3)
    }

    func testTypingInACellAndReturnMovesToTheNext() {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        app.typeText("Name")
        app.typeText("\n")
        waitForFocus("editor.table.cell.0.1")
        app.typeText("Qty")
        press(waitFor("editor.table.cell.1.0"))
        waitForFocus("editor.table.cell.1.0")
        app.typeText("a|b")
        waitForNoteText("the cells in the file") { $0.contains("Name") && $0.contains("Qty") && $0.contains("a\\|b") }
        XCTAssertEqual(element("editor.table.cell.0.0").value as? String, "Name")
        XCTAssertEqual(element("editor.table.cell.1.0").value as? String, "a|b", "the cell says a pipe, the file an escaped one")
        assertValidGFM(noteText(), columns: 3, rows: 3)
        picture("table-grid-edit")
    }

    func testReturnAtTheLastCellAddsARow() {
        newNoteWithATable()
        press(waitFor("editor.table.cell.2.2"))
        waitForFocus("editor.table.cell.2.2")
        app.typeText("\n")
        waitForFocus("editor.table.cell.3.0")
        assertValidGFM(noteText(), columns: 3, rows: 4)
    }

    func testAddingARowAndAColumnFromTheGrid() {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        app.typeText("Top")
        press(waitFor("editor.table.addRow"))
        waitFor("editor.table.cell.3.0")
        assertValidGFM(noteText(), columns: 3, rows: 4)
        press(waitFor("editor.table.addColumn"))
        waitFor("editor.table.cell.0.3")
        assertValidGFM(noteText(), columns: 4, rows: 4)
        XCTAssertTrue(noteText().contains("Top"))
    }

    func testTheHandlesMenusAddAndDelete() {
        newNoteWithATable()
        press(waitFor("editor.table.cell.1.1"))
        waitForFocus("editor.table.cell.1.1")
        app.typeText("mid")

        press(waitFor("editor.table.rowHandle"))
        press(waitForMenuItem("Add Row Below"))
        waitFor("editor.table.cell.3.0")
        assertValidGFM(noteText(), columns: 3, rows: 4)
        XCTAssertEqual(element("editor.table.cell.1.1").value as? String, "mid")

        press(waitFor("editor.table.columnHandle"))
        press(waitForMenuItem("Add Column Before"))
        waitFor("editor.table.cell.0.3")
        assertValidGFM(noteText(), columns: 4, rows: 4)

        press(waitFor("editor.table.columnHandle"))
        press(waitForMenuItem("Delete Column"))
        waitForNoteText("the column went") { !$0.isEmpty && !self.element("editor.table.cell.0.3").exists }
        assertValidGFM(noteText(), columns: 3, rows: 4)

        press(waitFor("editor.table.rowHandle"))
        press(waitForMenuItem("Delete Row"))
        waitForNoteText("the row went") { _ in !self.element("editor.table.cell.3.0").exists }
        assertValidGFM(noteText(), columns: 3, rows: 3)

        press(waitFor("editor.table.rowHandle"))
        press(waitForMenuItem("Delete Table"))
        waitForNoteText("the table went") { !$0.contains("|") }
        XCTAssertFalse(element("editor.table").exists)
    }

    private func waitForMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8), "\(title)\n\(app.debugDescription)", file: file, line: line)
        return item
    }

    // MARK: - notes that already have a table

    func testAnExistingNoteOpensAsAGridAndNothingChanges() {
        launch(["-BNScreen", "table"])
        waitFor("editor.table", timeout: 20)
        XCTAssertEqual(waitFor("editor.table.cell.0.1").value as? String, "Distance")
        XCTAssertEqual(waitFor("editor.table.cell.2.3").value as? String, "long run, felt good")
        XCTAssertTrue(noteText().contains("| 3 Nov | 8.0 km | 5:55 | long run, felt good |"), "the file is what it was")
    }

    func testEditingAndReopeningShowsTheGridAgain() {
        launch(["-BNScreen", "table"])
        // At the cell's far end, past its text: the caret goes behind the text.
        waitFor("editor.table.cell.3.0", timeout: 20).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        waitForFocus("editor.table.cell.3.0")
        app.typeText(" more")
        waitForNoteText("the edit in the file") { $0.contains("| 4 Nov more | 4.0 km | 5:20 | tempo |") }
        assertValidGFM(noteText(), columns: 4, rows: 4)

        press(waitFor("note.done"))
        waitFor("note.table", timeout: 10)
        XCTAssertFalse(element("editor.table").exists, "the note view has its own grid")

        // Out to the folder and in again: the note comes from the file now, and this launch option opens it in the editor.
        press(app.navigationBars.buttons.element(boundBy: 0))
        press(waitFor("note.health/running-log.md"))
        XCTAssertEqual(waitFor("editor.table.cell.3.0", timeout: 10).value as? String, "4 Nov more")
        XCTAssertTrue(noteText().contains("| 4 Nov more | 4.0 km | 5:20 | tempo |"))
        assertValidGFM(noteText(), columns: 4, rows: 4)
    }

    func testATapOnACellInTheNoteViewStartsEditingThatCell() {
        launch(["-BNScreen", "list"])
        press(app.navigationBars.buttons.element(boundBy: 0))
        press(waitFor("folder.health", timeout: 20))
        press(waitFor("note.health/running-log.md"))
        let table = waitFor("note.table", timeout: 10)
        picture("table-reading")
        // The middle of the table: the second body row, second of the four columns or thereabouts.
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.375, dy: 0.625)).tap()
        waitForFocus("editor.table.cell.2.1")
    }

    func testATableTypedByHandBecomesAGridAndWhatIsTypedNextGoesBelowIt() {
        launch(["-BNScreen", "compose"])
        waitFor("editor.bar", timeout: 20)
        app.typeText("| one | two |\n|---|---|")
        waitForNoteText("the lines typed") { $0.hasSuffix("|---|---|") }
        XCTAssertFalse(element("editor.table").exists, "still being typed, and nothing got in the way of that")
        app.typeText("\n")
        XCTAssertEqual(waitFor("editor.table.cell.0.1").value as? String, "two")
        app.typeText("after")
        waitForNoteText("the text below the table") { $0.hasSuffix("| one | two |\n|---|---|\n\nafter") }
        XCTAssertTrue(element("editor.table").exists)
        XCTAssertFalse(element("editor.table.cell.1.0").exists, "and no row came of it")
    }

    // MARK: - the bar in a cell

    func testTheBarsMarksWorkInACellAndItsTableButtonOpensTheTablesActions() {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        app.typeText("word")
        // Aa, Bold: on the word the caret is on, as on a line of the note.
        press(waitFor("editor.bar.format"))
        press(waitForMenuItem("Bold"))
        waitForNoteText("the marks in the file") { $0.contains("**word**") }
        XCTAssertEqual(element("editor.table.cell.0.0").value as? String, "**word**", "marks show in the cell being edited")
        // The table button can't put a table in a table: it opens what can be done to this one.
        press(waitFor("editor.bar.table"))
        press(waitForMenuItem("Add Row Below"))
        waitFor("editor.table.cell.3.0")
        assertValidGFM(noteText(), columns: 3, rows: 4)
        XCTAssertEqual(noteText().components(separatedBy: "\n").filter { $0.hasPrefix("|---") }.count, 1, "one table, not two")
        // Off the cell, the marks are gone and the text is bold.
        press(waitFor("editor.table.cell.1.1"))
        waitForFocus("editor.table.cell.1.1")
        XCTAssertEqual(waitFor("editor.table.cell.0.0").value as? String, "**word**", "VoiceOver gets what the file says")
    }

    // MARK: - around the grid

    func testDoneOnTheBarEndsTheCellAndKeepsTheGrid() {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        app.typeText("Kept")
        press(waitFor("editor.bar.done"))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("editor.table.addRow"))
        waitForExpectations(timeout: 8)
        XCTAssertEqual(element("editor.table.cell.0.0").value as? String, "Kept")
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5), "the keyboard went")
        // And a tap on a cell brings it all back.
        press(waitFor("editor.table.cell.1.1"))
        waitForFocus("editor.table.cell.1.1")
        XCTAssertTrue(waitFor("editor.bar").exists)
    }

    func testTypingUnderTheTableStaysOutOfIt() {
        launch(["-BNScreen", "table"])
        let grid = waitFor("editor.table", timeout: 20)
        // A cell has the focus first: a tap on the note takes it back.
        press(waitFor("editor.table.cell.1.0"))
        waitForFocus("editor.table.cell.1.0")
        // Under the grid: the line after the table.
        note.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: grid.frame.maxY - note.frame.minY + 30)).tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("editor.table.addRow"))
        waitForExpectations(timeout: 8)
        app.typeText("After")
        waitForNoteText("the text under the table") { $0.hasSuffix("| 4 Nov | 4.0 km | 5:20 | tempo |\n\nAfter") }
        XCTAssertFalse(element("editor.table.cell.4.0").exists, "and no new row")
        XCTAssertTrue(noteText().contains("| 1 Nov | 5.2 km | 5:41 | easy, windy |"), "the cell is as it was")
    }

    /// Ending a cell puts the keyboard away for good: the note around it doesn't take the focus and bring it back.
    func testTheKeyboardStaysAwayAfterACellEndsAndComesBackForTheNote() {
        launch(["-BNScreen", "table"])
        press(waitFor("editor.table.cell.1.0", timeout: 20))
        waitForFocus("editor.table.cell.1.0")
        press(waitFor("editor.bar.done"))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.keyboards.element.exists, "and nothing brings it back")
        // The note can have the keyboard again, as before.
        note.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: waitFor("editor.table").frame.maxY - note.frame.minY + 30)).tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
    }

    /// The keyboard covers half the screen: a cell with the focus is always above it and its glass bar.
    func testACellDownALongNoteStaysAboveTheKeyboard() {
        launch(["-BNScreen", "live"])
        waitFor("editor.bar.table", timeout: 20)
        press(element("editor.bar.table"))
        waitForFocus("editor.table.cell.0.0")
        let bar = waitFor("editor.bar.done")
        func assertAboveTheBar(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
            let cell = waitFor(id, file: file, line: line)
            // Give the scroll its time.
            let clear = NSPredicate { _, _ in cell.frame.maxY <= bar.frame.minY && cell.frame.minY >= 0 && cell.isHittable }
            expectation(for: clear, evaluatedWith: cell)
            waitForExpectations(timeout: 5)
        }
        assertAboveTheBar("editor.table.cell.0.0")
        for row in 3...9 {
            press(waitFor("editor.table.addRow"))
            assertAboveTheBar("editor.table.cell.\(row).0")
        }
        app.typeText("low")
        waitForNoteText("typed down there") { $0.contains("| low |") }
        assertAboveTheBar("editor.table.cell.9.0")
        XCTAssertTrue(element("editor.bar").exists)
        // Up through the table with the keyboard still up.
        press(waitFor("editor.bar.done"))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))
    }

    func testAWideTableScrollsSidewaysAndItsCellsCanBeReached() {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        for column in 3...7 {
            press(waitFor("editor.table.addColumn"))
            waitForFocus("editor.table.cell.0.\(column)")
        }
        let last = element("editor.table.cell.0.7")
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(last.frame.maxX, width + 1, "scrolled to the cell with the focus")
        XCTAssertGreaterThanOrEqual(last.frame.minX, 0)
        app.typeText("end")
        waitForNoteText("typed in the last column") { $0.contains("end") }
        assertValidGFM(noteText(), columns: 8, rows: 3)
        picture("table-grid-wide")
        // Dragged back, the first column is there to tap, and the plus buttons stay on screen.
        waitFor("editor.table").swipeRight(velocity: .fast)
        let first = waitFor("editor.table.cell.1.0")
        first.tap()
        waitForFocus("editor.table.cell.1.0")
        XCTAssertLessThanOrEqual(waitFor("editor.table.addColumn").frame.maxX, width + 1)
    }

    #if os(iOS)
    /// Cmd-Z, until it has done what it should. The first key from a hardware keyboard only puts the keyboard in that mode,
    /// and nothing comes of it, in plain text too.
    private func pressUndoKeys(_ flags: XCUIElement.KeyModifierFlags, until what: String, file: StaticString = #filePath, line: UInt = #line, _ done: (String) -> Bool) {
        for _ in 0..<3 {
            app.typeKey("z", modifierFlags: flags)
            Thread.sleep(forTimeInterval: 0.8)
            if done(noteText()) { return }
        }
        XCTFail("\(what): \(noteText().debugDescription)", file: file, line: line)
    }

    func testUndoGoesBackThroughACellsTypingInOneStep() throws {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        app.typeText("Gone")
        waitForNoteText("typed") { $0.contains("Gone") }
        pressUndoKeys(.command, until: "undone, all of it") { !$0.contains("G") }
        XCTAssertEqual((element("editor.table.cell.0.0").value as? String) ?? "", "", "the cell follows")
        waitForFocus("editor.table.cell.0.0")
        pressUndoKeys([.command, .shift], until: "redone") { $0.contains("Gone") }
        XCTAssertEqual(element("editor.table.cell.0.0").value as? String, "Gone")
        assertValidGFM(noteText(), columns: 3, rows: 3)
    }

    func testUndoTakesBackARowAndAColumn() throws {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        press(waitFor("editor.table.addRow"))
        waitFor("editor.table.cell.3.0")
        press(waitFor("editor.table.addColumn"))
        waitFor("editor.table.cell.0.3")
        pressUndoKeys(.command, until: "the column went") { _ in !self.element("editor.table.cell.0.3").exists }
        assertValidGFM(noteText(), columns: 3, rows: 4)
        pressUndoKeys(.command, until: "the row went") { _ in !self.element("editor.table.cell.3.0").exists }
        assertValidGFM(noteText(), columns: 3, rows: 3)
        pressUndoKeys([.command, .shift], until: "the row is back") { _ in self.element("editor.table.cell.3.0").exists }
        assertValidGFM(noteText(), columns: 3, rows: 4)
    }

    func testUndoOfTheInsertionTakesTheGridAway() throws {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        pressUndoKeys(.command, until: "the table went") { !$0.contains("|") }
        XCTAssertFalse(element("editor.table").exists)
        XCTAssertTrue(hasKeyboardFocus(note), "the note has the focus back")
    }
    #endif

    // MARK: - right to left

    func testAHebrewTableRunsRightToLeft() {
        launch(["-BNScreen", "table", "-BNHebrew"])
        waitFor("editor.table", timeout: 20)
        let first = waitFor("editor.table.cell.0.0")
        let second = waitFor("editor.table.cell.0.1")
        XCTAssertEqual(first.value as? String, "פריט")
        XCTAssertGreaterThan(first.frame.minX, second.frame.minX, "the first column is on the right")
        press(waitFor("editor.table.cell.1.1"))
        waitForFocus("editor.table.cell.1.1")
        let columnHandle = waitFor("editor.table.columnHandle")
        let whole = NSPredicate { _, _ in columnHandle.isHittable }
        expectation(for: whole, evaluatedWith: columnHandle)
        waitForExpectations(timeout: 5)
        app.typeText("0")
        waitForNoteText("the digit in the file") { $0.contains("| לינה | 9000 | שני לילות |") }
        picture("table-grid-rtl")
    }

    func testTypingHebrewInANewTableTurnsItRightToLeft() {
        newNoteWithATable()
        waitForFocus("editor.table.cell.0.0")
        XCTAssertLessThan(element("editor.table.cell.0.0").frame.minX, element("editor.table.cell.0.1").frame.minX, "left to right, with no text yet")
        app.typeText("שלום")
        waitForNoteText("the Hebrew in the file") { $0.contains("שלום") }
        let first = element("editor.table.cell.0.0"), second = element("editor.table.cell.0.1")
        XCTAssertGreaterThan(first.frame.minX, second.frame.minX, "the columns turned around")
    }
}
