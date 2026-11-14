import AppKit
import BrainNotesKit
import SwiftUI
import XCTest
@testable import BrainNotes

/// The grid in a real window, on the real text view: what is on screen is a grid and never its pipes, and the bytes under it
/// are the file's, through typing, moving between cells, the menus and undo. The iPhone's touches are in
/// `BrainNotesTableUITests`; everything here that isn't a view is shared with it.
@MainActor
final class TableGridTests: XCTestCase {
    private var window: NSWindow!
    private var edits: [String] = []

    private let note = "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n\nDone.\n"

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        edits = []
    }

    private func editor(_ text: String, size: NSSize = NSSize(width: 460, height: 640), focused: Bool = true) async throws -> EditorTextView {
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // No open/close animation: see `ScreenWalkTests.makeWindow` (each one could strand a GCD thread).
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: MarkdownTextView(text: text, externalRevision: 0, onEdit: { [weak self] in self?.edits.append($0) }))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(120))
        let view = try XCTUnwrap(find(window.contentView))
        window.makeFirstResponder(focused ? view : nil)
        try await settle()
        return view
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    private func find(_ view: NSView?) -> EditorTextView? {
        guard let view else { return nil }
        if let found = view as? EditorTextView { return found }
        for sub in view.subviews {
            if let found = find(sub) { return found }
        }
        return nil
    }

    private func tables(_ view: EditorTextView) throws -> TableOverlay { try XCTUnwrap(view.coordinator?.tables) }

    private func grid(_ view: EditorTextView, _ index: Int = 0) throws -> TableGridView {
        let grids = try tables(view).grids
        XCTAssertGreaterThan(grids.count, index, "a grid for that table")
        return grids[index]
    }

    private func cellEditor(_ view: EditorTextView, _ index: Int = 0) throws -> TableCellEditor { try XCTUnwrap(try grid(view, index).editor) }

    private func focus(_ view: EditorTextView, row: Int, column: Int, table: Int = 0, caret: TableCaret = .end) async throws {
        try tables(view).focusCell(TableCellAddress(table: table, cell: GridCell(row: row, column: column)), caret: caret)
        try await settle()
    }

    private func find(_ identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for sub in root.subviews {
            if let found = find(identifier, in: sub) { return found }
        }
        return nil
    }

    private func assertBytes(_ view: NSTextView, _ expected: String, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8), "\(view.string.debugDescription) \(note)", file: file, line: line)
    }

    private func storage(_ view: NSTextView) throws -> NSTextStorage { try XCTUnwrap(view.textStorage) }

    /// What the event loop does after each real event: a test's run loop doesn't.
    private func endOfEvent() { _ = (UndoManager.self as AnyObject).perform(NSSelectorFromString("_endTopLevelGroupings")) }

    private func hiddenCharacters(_ view: NSTextView, in range: NSRange) throws -> Int {
        var count = 0
        try storage(view).enumerateAttribute(.bnHiddenMark, in: range) { value, found, _ in
            if value != nil { count += found.length }
        }
        return count
    }

    private func type(_ text: String, in editor: TableCellEditor) {
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    private func command(_ selector: Selector, in editor: TableCellEditor) {
        editor.doCommand(by: selector)
    }

    private func press(_ identifier: String, in view: NSView) throws {
        let button = try XCTUnwrap(find(identifier, in: view) as? NSButton, identifier)
        XCTAssertFalse(button.isHidden, identifier)
        button.performClick(nil)
    }

    private func picture(_ name: String) throws {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try FileManager.default.createDirectory(at: LivePreviewTests.shots, withIntermediateDirectories: true)
        try png.write(to: LivePreviewTests.shots.appendingPathComponent("\(name).png"))
    }

    // MARK: never the text form

    func testATableIsAGridAndItsSourceIsHiddenWithOrWithoutTheFocus() async throws {
        let view = try await editor(note, focused: false)
        assertBytes(view, note)
        XCTAssertEqual(edits, [], "opening a note writes nothing")
        let spans = try tables(view).spans
        XCTAssertEqual(spans.count, 1)
        let range = spans[0].range
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length, "every character of it")
        XCTAssertEqual(try storage(view).attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, NSColor.clear)
        XCTAssertFalse(try grid(view).isHidden)
        XCTAssertEqual((find("editor.table.cell.1.1", in: view))?.accessibilityValue() as? String, "5")

        // The note's own text keeps its look: only the table is hidden.
        let before = (note as NSString).range(of: "Done.")
        XCTAssertEqual(try hiddenCharacters(view, in: before), 0)

        // Focus anywhere, and a caret on either side of it, change nothing about that.
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (note as NSString).range(of: "Done.").location, length: 0))
        try await settle()
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length)
        try await focus(view, row: 1, column: 0)
        XCTAssertEqual(try hiddenCharacters(view, in: try tables(view).spans[0].range), range.length)
        assertBytes(view, note)
        XCTAssertEqual(edits, [], "looking at a table writes nothing")
    }

    func testTheSourceHasNoHeightOfItsOwnAndTheGridSitsWhereItWas() async throws {
        let view = try await editor(note, focused: false)
        let grid = try grid(view)
        let span = try tables(view).spans[0]
        // The line under the table starts right under the grid.
        let manager = try XCTUnwrap(view.textLayoutManager), content = try XCTUnwrap(manager.textContentManager)
        var below: CGRect?
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: (note as NSString).range(of: "Done.").location))
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            below = fragment.layoutFragmentFrame
            return false
        }
        let done = try XCTUnwrap(below).minY + view.textContainerOrigin.y
        XCTAssertGreaterThanOrEqual(done, grid.frame.maxY, "text goes on under the grid")
        XCTAssertLessThan(done - grid.frame.maxY, 40, "and right under it: one blank line and the hidden rows")
        XCTAssertEqual(grid.frame.height, span.height)
    }

    func testAScrolledGridStaysOverItsTable() async throws {
        let long = String(repeating: "A line of text to scroll past.\n", count: 80) + "\n| a | b |\n|---|---|\n| 1 | 2 |\n\n" + String(repeating: "More lines.\n", count: 80)
        let view = try await editor(long, focused: false)
        let scroller = try XCTUnwrap(view.enclosingScrollView)
        func placed() throws -> (grid: CGRect, fragment: CGRect?) {
            let span = try tables(view).spans[0]
            let manager = try XCTUnwrap(view.textLayoutManager), content = try XCTUnwrap(manager.textContentManager)
            let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: span.range.location))
            var frame: CGRect?
            manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                frame = fragment.layoutFragmentFrame
                return false
            }
            return (try grid(view).frame, frame)
        }
        let target = (long as NSString).range(of: "| a | b |")
        view.scrollRangeToVisible(target)
        scroller.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        var now = try placed()
        XCTAssertFalse(try grid(view).isHidden, "near what is on screen")
        XCTAssertEqual(now.grid.minY, try XCTUnwrap(now.fragment).minY + view.textContainerOrigin.y, accuracy: 0.5)
        XCTAssertTrue(view.visibleRect.intersects(now.grid), "\(view.visibleRect) \(now.grid)")
        scroller.documentView?.scroll(NSPoint(x: 0, y: 0))
        try await Task.sleep(for: .milliseconds(200))
        scroller.documentView?.scrollToVisible(now.grid)
        try await Task.sleep(for: .milliseconds(200))
        now = try placed()
        XCTAssertEqual(now.grid.minY, try XCTUnwrap(now.fragment).minY + view.textContainerOrigin.y, accuracy: 0.5)
        try picture("mac-table-after-scrolling")
    }

    func testSeveralTablesEachHaveAGridAndOthersStayAsText() async throws {
        let text = "| a |\n|---|\n\ntext | with a pipe\n\n```\n| in code |\n|---|\n```\n\n| b |\n|---|\n| 2 |\n"
        let view = try await editor(text, focused: false)
        XCTAssertEqual(try tables(view).grids.count, 2)
        XCTAssertEqual(try hiddenCharacters(view, in: (text as NSString).range(of: "text | with a pipe")), 0, "a pipe in a line is just that")
        XCTAssertEqual(try hiddenCharacters(view, in: (text as NSString).range(of: "| in code |")), 0, "nothing in code is a table")
        assertBytes(view, text)
    }

    func testAMalformedTableStaysTextAndLosesNothing() async throws {
        let text = "| a | b |\n|---|\n| 1 | 2 |\n"
        let view = try await editor(text, focused: false)
        XCTAssertEqual(try tables(view).grids.count, 0)
        XCTAssertEqual(try hiddenCharacters(view, in: NSRange(location: 0, length: (text as NSString).length)), 0)
        assertBytes(view, text)
        XCTAssertEqual(edits, [])
    }

    func testARaggedTableShowsAllItsCellsAndBecomesRectangularOnlyWhenEdited() async throws {
        let text = "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |\n"
        let view = try await editor(text, focused: false)
        XCTAssertEqual((find("editor.table.cell.2.2", in: view))?.accessibilityValue() as? String, "3", "what GitHub ignores is on screen")
        assertBytes(view, text)
        try await focus(view, row: 1, column: 0)
        assertBytes(view, text, "focus alone changes nothing")
        type("x", in: try cellEditor(view))
        assertBytes(view, "| a | b | |\n|---|---|---|\n| 1x | | |\n| 1 | 2 | 3 |\n", "valid and rectangular, and nothing lost")
    }

    func testVoiceOverStillGetsTheGridNotThePipes() async throws {
        let view = try await editor(note, focused: false)
        view.coordinator?.preview?.setHidesMarks(false)
        try await settle()
        let range = try tables(view).spans[0].range
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length)
        let cell = try XCTUnwrap(find("editor.table.cell.2.1", in: view))
        XCTAssertEqual(cell.accessibilityLabel(), "Row 2, column 2, Km")
        XCTAssertEqual(cell.accessibilityValue() as? String, "6")
        XCTAssertEqual(cell.accessibilityRole(), .cell)
        XCTAssertEqual(find("editor.table.cell.0.0", in: view)?.accessibilityLabel(), "Header, column 1")
        XCTAssertEqual(try grid(view).accessibilityLabel(), "Table, 2 columns, 3 rows")
        XCTAssertEqual(try grid(view).accessibilityIdentifier(), "editor.table")
    }

    // MARK: editing cells

    func testTypingInACellWritesTheFileAtOnce() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        let cell = try cellEditor(view)
        XCTAssertEqual(cell.string, "5")
        XCTAssertTrue(window.firstResponder === cell)
        XCTAssertEqual(cell.selectedRange().location, 1, "behind what is there")
        XCTAssertEqual(cell.accessibilityIdentifier(), "editor.table.cell.1.1")
        type(".5", in: cell)
        let expected = "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5.5 |\n| Tue | 6 |\n\nDone.\n"
        assertBytes(view, expected)
        XCTAssertEqual(edits.last, expected, "the autosave has it")
        try picture("mac-table-editing")
    }

    func testAPipeInACellIsEscapedInTheFileAndShownAsItself() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        cell.selectAll(nil)
        type("a|b", in: cell)
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| a\\|b | 5 |\n| Tue | 6 |\n\nDone.\n")
        XCTAssertEqual(cell.string, "a|b", "no backslash on screen")
        XCTAssertEqual(try tables(view).spans[0].table.gridColumnCount, 2, "the pipe made no new column")
        try await focus(view, row: 0, column: 0)
        XCTAssertEqual(find("editor.table.cell.1.0", in: view)?.accessibilityValue() as? String, "a|b")
    }

    func testAPasteOfSeveralLinesIsOneLineInACell() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        cell.selectAll(nil)
        // As a paste does: it asks first.
        if cell.shouldChangeText(in: cell.selectedRange(), replacementString: "one\ntwo\r\nthree") {
            cell.insertText("one\ntwo\r\nthree", replacementRange: cell.selectedRange())
        }
        XCTAssertEqual(cell.string, "one two three")
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| one two three | 5 |\n| Tue | 6 |\n\nDone.\n")
    }

    /// These are line breaks to a text view and not to GitHub. A paste of one once came straight back through the check.
    func testEveryKindOfLineSeparatorIsASpaceInACell() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        for separator in ["\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}"] {
            cell.selectAll(nil)
            let text = "a\(separator)b"
            if cell.shouldChangeText(in: cell.selectedRange(), replacementString: text) {
                cell.insertText(text, replacementRange: cell.selectedRange())
            }
            XCTAssertEqual(cell.string, "a b", separator.debugDescription)
        }
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| a b | 5 |\n| Tue | 6 |\n\nDone.\n")
    }

    /// Text being composed isn't in the file until it is final. Moving on makes it final, and nothing is lost.
    func testTextBeingComposedInACellIsKeptWhenTheFocusMoves() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        cell.setMarkedText("ab", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(cell.isComposing)
        assertBytes(view, note, "not in the file yet")
        try tables(view).move(.next)
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Monab | 5 |\n| Tue | 6 |\n\nDone.\n")
        XCTAssertEqual(cell.string, "5", "the editor is on the next cell")

        cell.setMarkedText("c", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        try tables(view).endFocus()
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Monab | 5c |\n| Tue | 6 |\n\nDone.\n", "and Done keeps it too")

        try await focus(view, row: 2, column: 0)
        cell.setMarkedText("d", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 3, length: 0))
        try tables(view).perform(.addRowBelow)
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Monab | 5c |\n| Tued | 6 |\n| | |\n\nDone.\n", "and a menu command")
    }

    func testSpacesWhileTypingAreKeptOnScreenAndTrimmedInTheFile() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        cell.selectAll(nil)
        type("New ", in: cell)
        XCTAssertEqual(cell.string, "New ", "the space stays, for the next word")
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| New | 5 |\n| Tue | 6 |\n\nDone.\n")
        type("word", in: cell)
        XCTAssertEqual(cell.string, "New word")
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| New word | 5 |\n| Tue | 6 |\n\nDone.\n")
    }

    func testBoldInACellKeepsItsMarksInTheFileAndShowsThemOnlyWhileEditing() async throws {
        let text = "| a |\n|---|\n| **strong** |\n"
        let view = try await editor(text, focused: false)
        try await focus(view, row: 1, column: 0)
        XCTAssertEqual(try cellEditor(view).string, "**strong**", "marks show while editing, as on a line in the note")
        try await focus(view, row: 0, column: 0)
        assertBytes(view, text)
    }

    func testTheBarsMarksWorkInACellAndItsBlocksDoNot() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        cell.selectAll(nil)
        view.performEditorAction(EditorActionSender(.bold))
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| **Mon** | 5 |\n| Tue | 6 |\n\nDone.\n")
        for action in [EditorAction.checklist, .bullet, .numbered, .title, .heading, .indent, .table] {
            let before = view.string
            view.performEditorAction(EditorActionSender(action))
            assertBytes(view, before, "\(action) has nothing to do in a cell")
        }
    }

    // MARK: moving between cells

    func testTabAndReturnGoOnThroughTheCellsAndShiftTabGoesBack() async throws {
        let view = try await editor(note)
        try await focus(view, row: 0, column: 0)
        let overlay = try tables(view)
        let cell = try cellEditor(view)
        func at(_ row: Int, _ column: Int, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(overlay.focus, TableCellAddress(table: 0, cell: GridCell(row: row, column: column)), file: file, line: line)
            XCTAssertTrue(window.firstResponder === cell, "the one editor keeps the focus", file: file, line: line)
        }
        command(#selector(NSResponder.insertTab(_:)), in: cell)
        at(0, 1)
        XCTAssertEqual(cell.string, "Km")
        command(#selector(NSResponder.insertNewline(_:)), in: cell)
        at(1, 0)
        XCTAssertEqual(cell.string, "Mon")
        command(#selector(NSResponder.insertBacktab(_:)), in: cell)
        at(0, 1)
        command(#selector(NSResponder.insertBacktab(_:)), in: cell)
        at(0, 0)
        command(#selector(NSResponder.insertBacktab(_:)), in: cell)
        at(0, 0)
        assertBytes(view, note, "going through writes nothing")
    }

    func testReturnAtTheLastCellAddsARowAndGoesToIt() async throws {
        let view = try await editor(note)
        try await focus(view, row: 2, column: 1)
        let cell = try cellEditor(view)
        command(#selector(NSResponder.insertNewline(_:)), in: cell)
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 3, column: 0))
        XCTAssertEqual(cell.string, "")
        type("Wed", in: cell)
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n| Wed | |\n\nDone.\n")
    }

    func testArrowsLeaveACellOnlyFromItsEdge() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0, caret: .start)
        let overlay = try tables(view)
        let cell = try cellEditor(view)
        // From inside the text, Right moves the caret.
        cell.setSelectedRange(NSRange(location: 1, length: 0))
        command(#selector(NSResponder.moveRight(_:)), in: cell)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 0))
        XCTAssertEqual(cell.selectedRange().location, 2)
        // From its end, to the next cell's start.
        cell.setSelectedRange(NSRange(location: 3, length: 0))
        command(#selector(NSResponder.moveRight(_:)), in: cell)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 1))
        XCTAssertEqual(cell.selectedRange().location, 0)
        // And back, to the end of the one before.
        command(#selector(NSResponder.moveLeft(_:)), in: cell)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 0))
        XCTAssertEqual(cell.selectedRange().location, 3)
        command(#selector(NSResponder.moveDown(_:)), in: cell)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 2, column: 0))
        XCTAssertEqual(cell.string, "Tue")
        command(#selector(NSResponder.moveUp(_:)), in: cell)
        command(#selector(NSResponder.moveUp(_:)), in: cell)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 0, column: 0))
        assertBytes(view, note)
    }

    func testArrowsLeaveTheTableAtItsEdgesAndComeBackIn() async throws {
        let view = try await editor(note)
        let overlay = try tables(view)
        try await focus(view, row: 2, column: 0)
        let cell = try cellEditor(view)
        command(#selector(NSResponder.moveDown(_:)), in: cell)
        try await settle()
        XCTAssertNil(overlay.focus)
        XCTAssertTrue(window.firstResponder === view, "the note has the focus again")
        let span = overlay.spans[0].range
        XCTAssertEqual(view.selectedRange().location, NSMaxRange(span), "on the line under the table")
        // Down then Up: back into the last cell.
        view.moveLeft(nil)
        try await settle()
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 2, column: 1), "from below, into the last cell")
        XCTAssertEqual(cell.selectedRange().location, 1, "behind its text")

        command(#selector(NSResponder.moveUp(_:)), in: cell)
        command(#selector(NSResponder.moveUp(_:)), in: cell)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 0, column: 1))
        command(#selector(NSResponder.moveUp(_:)), in: cell)
        try await settle()
        XCTAssertNil(overlay.focus)
        XCTAssertEqual(view.selectedRange().location, span.location - 1, "on the line above the table")
        view.moveRight(nil)
        try await settle()
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 0, column: 0), "from above, into the first cell")
        assertBytes(view, note)
    }

    func testEscapeLeavesTheTable() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        command(#selector(NSResponder.cancelOperation(_:)), in: try cellEditor(view))
        try await settle()
        XCTAssertNil(try tables(view).focus)
        XCTAssertTrue(window.firstResponder === view)
    }

    func testAClickOnTheNoteEndsTheFocus() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        window.makeFirstResponder(view)
        try await settle()
        XCTAssertNil(try tables(view).focus)
        XCTAssertTrue(try cellEditor(view).isHidden)
        let label = try XCTUnwrap(find("editor.table.cell.1.0", in: view))
        XCTAssertEqual(label.accessibilityValue() as? String, "Mon")
    }

    // MARK: the mouse

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testAClickOnACellGivesItTheFocusWithTheCaretWhereTheClickWas() async throws {
        let text = "| a long header here | b |\n|---|---|\n| some words in a cell | 2 |\n"
        let view = try await editor(text)
        let cell = try XCTUnwrap(find("editor.table.cell.1.0", in: view))
        // Found by a real hit test, from the window down.
        let inWindow = cell.convert(NSPoint(x: 12, y: cell.bounds.midY), to: nil)
        let hit = try XCTUnwrap(window.contentView?.hitTest(try XCTUnwrap(window.contentView?.superview?.convert(inWindow, from: nil)) ))
        XCTAssertTrue(hit === cell, "\(hit)")
        cell.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 12, y: cell.bounds.midY), in: cell))
        try await settle()
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 1, column: 0))
        let editorCell = try cellEditor(view)
        XCTAssertTrue(window.firstResponder === editorCell)
        XCTAssertLessThan(editorCell.selectedRange().location, 3, "near its start, where the click was")
        assertBytes(view, text)
    }

    func testARightClickOnACellHasEveryTableCommand() async throws {
        let view = try await editor(note)
        let cell = try XCTUnwrap(find("editor.table.cell.2.0", in: view))
        let menu = try XCTUnwrap(cell.menu(for: try mouseEvent(.rightMouseDown, at: NSPoint(x: 10, y: 10), in: cell)))
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 2, column: 0), "on the cell it was for")
        XCTAssertEqual(menu.items.map(\.title), TableCommand.cellMenu.map(\.title))
        let add = try XCTUnwrap(menu.items.first { $0.title == "Add Row Below" })
        _ = add.target?.perform(add.action, with: add)
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n| | |\n\nDone.\n")
    }

    func testARightClickInTheCellBeingEditedHasThemToo() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        let menu = try XCTUnwrap(cell.menu(for: try mouseEvent(.rightMouseDown, at: NSPoint(x: 2, y: 2), in: cell)))
        let titles = menu.items.map(\.title)
        for command in TableCommand.cellMenu { XCTAssertTrue(titles.contains(command.title), command.title) }
    }

    /// A wrong name is a menu item with no icon.
    func testEveryCommandsSymbolExists() {
        for command in TableCommand.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil), command.symbol)
        }
    }

    // MARK: a selection

    func testAGridShowsWhenItIsInTheSelection() async throws {
        let view = try await editor(note)
        XCTAssertFalse(try grid(view).isInSelection)
        view.setSelectedRange(NSRange(location: 0, length: (note as NSString).length))
        try await settle()
        XCTAssertTrue(try grid(view).isInSelection, "its source has nothing to highlight, so the grid does")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await settle()
        XCTAssertFalse(try grid(view).isInSelection)
    }

    // MARK: rows and columns

    func testAddingAndDeletingFromTheCommands() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let overlay = try tables(view)
        let log = "# Log\n\n"
        let done = "\nDone.\n"

        overlay.perform(.addRowBelow)
        assertBytes(view, log + "| Day | Km |\n|---|---|\n| Mon | 5 |\n| | |\n| Tue | 6 |\n" + done)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 2, column: 0), "on to the new row")
        overlay.perform(.deleteRow)
        assertBytes(view, log + "| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n" + done)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 2, column: 0))

        try await focus(view, row: 1, column: 0)
        overlay.perform(.addRowAbove)
        assertBytes(view, log + "| Day | Km |\n|---|---|\n| | |\n| Mon | 5 |\n| Tue | 6 |\n" + done)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 0), "on the new row, in the same place")
        overlay.perform(.deleteRow)

        overlay.perform(.addColumnAfter)
        assertBytes(view, log + "| Day | | Km |\n|---|---|---|\n| Mon | | 5 |\n| Tue | | 6 |\n" + done)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 1))
        overlay.perform(.deleteColumn)
        assertBytes(view, log + "| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n" + done)

        try await focus(view, row: 1, column: 1)
        overlay.perform(.addColumnBefore)
        assertBytes(view, log + "| Day | | Km |\n|---|---|---|\n| Mon | | 5 |\n| Tue | | 6 |\n" + done)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 1))
        overlay.perform(.deleteColumn)
        assertBytes(view, note)
    }

    func testAddingARowAboveTheHeaderKeepsAValidTable() async throws {
        let view = try await editor(note)
        try await focus(view, row: 0, column: 0)
        try tables(view).perform(.addRowAbove)
        assertBytes(view, "# Log\n\n|  |  |\n|---|---|\n| Day | Km |\n| Mon | 5 |\n| Tue | 6 |\n\nDone.\n")
        XCTAssertEqual(try tables(view).spans[0].table.gridRowCount, 4)
        XCTAssertEqual(try cellEditor(view).string, "", "the new header cell has the focus")
        try tables(view).perform(.deleteRow)
        assertBytes(view, note, "and deleting the header promotes the row under it")
    }

    func testThePlusButtonsAddAtTheEnd() async throws {
        let view = try await editor(note)
        XCTAssertTrue(try XCTUnwrap(find("editor.table.addRow", in: view)).isHidden, "only with a cell in focus")
        try await focus(view, row: 1, column: 0)
        try press("editor.table.addRow", in: view)
        try await settle()
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n| | |\n\nDone.\n")
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 3, column: 0))
        try press("editor.table.addColumn", in: view)
        try await settle()
        assertBytes(view, "# Log\n\n| Day | Km | |\n|---|---|---|\n| Mon | 5 | |\n| Tue | 6 | |\n| | | |\n\nDone.\n")
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 3, column: 2))
        XCTAssertNotNil(find("editor.table.cell.3.2", in: view) ?? find("editor.table.cell.0.2", in: view))
    }

    func testTheHandlesHaveMenusForTheirRowAndColumn() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        let grid = try grid(view)
        XCTAssertFalse(try XCTUnwrap(find("editor.table.rowHandle", in: view)).isHidden)
        XCTAssertFalse(try XCTUnwrap(find("editor.table.columnHandle", in: view)).isHidden)
        XCTAssertEqual(grid.menu(of: TableCommand.rowMenu).items.map(\.title), ["Add Row Above", "Add Row Below", "Delete Row", "Delete Table"])
        XCTAssertEqual(grid.menu(of: TableCommand.columnMenu).items.map(\.title), ["Add Column Before", "Add Column After", "Delete Column", "Delete Table"])
        let items = grid.menu(of: TableCommand.cellMenu).items
        XCTAssertEqual(items.count, TableCommand.cellMenu.count)
        // The menu item really does it.
        let add = try XCTUnwrap(items.first { $0.title == "Add Column After" })
        _ = add.target?.perform(add.action, with: add)
        XCTAssertEqual(try tables(view).spans[0].table.gridColumnCount, 3)
    }

    func testTheOnlyRowAndTheOnlyColumnCantBeDeleted() async throws {
        let view = try await editor("| a |\n|---|\n")
        try await focus(view, row: 0, column: 0)
        let overlay = try tables(view)
        XCTAssertFalse(overlay.isEnabled(.deleteRow))
        XCTAssertFalse(overlay.isEnabled(.deleteColumn))
        XCTAssertTrue(overlay.isEnabled(.deleteTable))
        overlay.perform(.deleteRow)
        overlay.perform(.deleteColumn)
        assertBytes(view, "| a |\n|---|\n")
    }

    func testDeletingTheTableLeavesTheNoteWithTheFocus() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        try tables(view).perform(.deleteTable)
        try await settle()
        assertBytes(view, "# Log\n\nDone.\n")
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(try tables(view).grids.count, 0)
        XCTAssertEqual(view.selectedRange().location, 7)
    }

    func testDeletingATableWithAnotherRightUnderItGoesIntoThatOne() async throws {
        let text = "| a |\n|---|\n\n| b |\n|---|\n"
        let view = try await editor(text)
        try await focus(view, row: 0, column: 0)
        try tables(view).perform(.deleteTable)
        try await settle()
        assertBytes(view, "| b |\n|---|\n")
        XCTAssertEqual(try tables(view).focus, TableCellAddress(table: 0, cell: GridCell(row: 0, column: 0)), "no caret in its hidden source")
        XCTAssertEqual(try cellEditor(view).string, "b")
    }

    func testDeletingATableWithAnotherUnderItAndTextAboveKeepsTheNotesFocus() async throws {
        let text = "Top\n\n| a |\n|---|\n\n| b |\n|---|\n"
        let view = try await editor(text)
        try await focus(view, row: 0, column: 0)
        try tables(view).perform(.deleteTable)
        try await settle()
        assertBytes(view, "Top\n\n| b |\n|---|\n")
        let overlay = try tables(view)
        XCTAssertFalse(NSLocationInRange(view.selectedRange().location, overlay.spans[0].range) && overlay.focus == nil, "no caret in its hidden source")
    }

    func testATableThatStartsTheNoteHasAWayToWriteAboveIt() async throws {
        let text = "| a |\n|---|\n"
        let view = try await editor(text)
        try await focus(view, row: 0, column: 0)
        let grid = try grid(view)
        let titles = grid.menu(of: TableCommand.rowMenu).items.map(\.title)
        XCTAssertEqual(titles.first, "Add Line Above Table")
        try tables(view).perform(.addLineAbove)
        try await settle()
        assertBytes(view, "\n| a |\n|---|\n")
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(view.selectedRange().location, 0)
        // Not when there is text above it: the line above is there to write on.
        let other = try await editor(note)
        try await focus(other, row: 0, column: 0)
        XCTAssertFalse(try self.grid(other).menu(of: TableCommand.rowMenu).items.map(\.title).contains("Add Line Above Table"))
    }

    // MARK: undo

    private func undoManager(_ view: NSTextView) throws -> UndoManager { try XCTUnwrap(view.undoManager) }

    func testARunOfTypingInACellIsOneUndoStep() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        let cell = try cellEditor(view)
        endOfEvent()
        for character in "0.5" {
            cell.insertText(String(character), replacementRange: cell.selectedRange())
            endOfEvent()
        }
        let typed = "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 50.5 |\n| Tue | 6 |\n\nDone.\n"
        assertBytes(view, typed)
        let undo = try undoManager(view)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        endOfEvent()
        assertBytes(view, note)
        XCTAssertEqual(cell.string, "5", "the cell on screen follows")
        XCTAssertEqual(edits.last, note, "and the autosave")
        XCTAssertTrue(window.firstResponder === cell, "the focus stays in the cell")
        undo.redo()
        endOfEvent()
        assertBytes(view, typed)
        XCTAssertEqual(cell.string, "50.5")
        undo.undo()
        endOfEvent()
        assertBytes(view, note)
    }

    func testMovingToAnotherCellStartsANewStep() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        let cell = try cellEditor(view)
        endOfEvent()
        type("a", in: cell)
        endOfEvent()
        command(#selector(NSResponder.insertNewline(_:)), in: cell)
        endOfEvent()
        type("b", in: cell)
        endOfEvent()
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5a |\n| Tueb | 6 |\n\nDone.\n")
        let undo = try undoManager(view)
        undo.undo()
        endOfEvent()
        assertBytes(view, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5a |\n| Tue | 6 |\n\nDone.\n")
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 2, column: 0))
        undo.undo()
        endOfEvent()
        assertBytes(view, note)
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 1, column: 1), "the focus goes back to where that edit was")
        XCTAssertEqual(cell.string, "5")
    }

    func testStructuralEditsUndoAndRedo() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let overlay = try tables(view)
        endOfEvent()
        overlay.perform(.addRowBelow)
        endOfEvent()
        overlay.perform(.addColumnAfter)
        endOfEvent()
        overlay.perform(.deleteRow)
        endOfEvent()
        let final = view.string
        let undo = try undoManager(view)
        undo.undo()
        endOfEvent()
        XCTAssertEqual(overlay.spans[0].table.gridRowCount, 4)
        undo.undo()
        endOfEvent()
        XCTAssertEqual(overlay.spans[0].table.gridColumnCount, 2)
        undo.undo()
        endOfEvent()
        assertBytes(view, note)
        XCTAssertEqual(overlay.focus?.cell, GridCell(row: 1, column: 0))
        undo.redo()
        endOfEvent()
        undo.redo()
        endOfEvent()
        undo.redo()
        endOfEvent()
        assertBytes(view, final)
    }

    func testDeletingATableUndoes() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        endOfEvent()
        try tables(view).perform(.deleteTable)
        endOfEvent()
        try await settle()
        assertBytes(view, "# Log\n\nDone.\n")
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, note)
        XCTAssertEqual(try tables(view).grids.count, 1)
        let range = try tables(view).spans[0].range
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length, "a grid again, not the text form")
    }

    /// An undo can bring a table back around the note's caret, or a table up to it. The next key mustn't be lost to that.
    func testAfterAnUndoTheCaretIsNeverInASourceAndTheNextKeyIsKept() async throws {
        let text = "| a |\n|---|\n"
        let view = try await editor(text)
        try await focus(view, row: 0, column: 0)
        endOfEvent()
        try tables(view).perform(.addLineAbove)
        endOfEvent()
        try await settle()
        XCTAssertEqual(view.selectedRange().location, 0)
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, text)
        XCTAssertEqual(view.selectedRange().location, (text as NSString).length, "under the table, not in it")
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertFalse(view.shouldChangeText(in: view.selectedRange(), replacementString: "x"))
        try await settle()
        assertBytes(view, text + "\nx", "the key went where the caret is")
        XCTAssertNil(try tables(view).focus)
    }

    /// Undo from the note, of an edit in a cell: the caret stays where it was in the text around the table.
    func testAnUndoFromTheNoteLeavesItsCaretWhereItWas() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        endOfEvent()
        type("7", in: try cellEditor(view))
        endOfEvent()
        window.makeFirstResponder(view)
        try await settle()
        let done = (view.string as NSString).range(of: "Done.").location
        view.setSelectedRange(NSRange(location: done + 2, length: 0))
        try await settle()
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, note)
        XCTAssertEqual(view.selectedRange().location, (note as NSString).range(of: "Done.").location + 2)
        XCTAssertTrue(window.firstResponder === view)
    }

    /// A manager doesn't keep its targets, and a note can be left with its steps still on the window's stack.
    func testUndoStepsGoWithTheEditor() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        endOfEvent()
        type("7", in: try cellEditor(view))
        endOfEvent()
        let manager = try undoManager(view)
        XCTAssertTrue(manager.canUndo)
        weak var overlay = try tables(view)
        window.contentView = NSView()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(overlay, "the editor is gone")
        XCTAssertFalse(manager.canUndo, "and its steps with it")
        manager.undo()
    }

    func testInsertingATableUndoesAsOneStepAndTheCaretGoesBack() async throws {
        let view = try await editor("Hello\n")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        try await settle()
        endOfEvent()
        view.performEditorAction(EditorActionSender(.table))
        endOfEvent()
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 1)
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, "Hello\n")
        XCTAssertEqual(try tables(view).grids.count, 0)
        XCTAssertNil(try tables(view).focus)
        XCTAssertTrue(window.firstResponder === view, "the note has the focus back")
        XCTAssertEqual(edits.last, "Hello\n", "the autosave has the undo, though the text view said nothing about it")
    }

    /// Undo while a cell has the focus can reach an edit made in the note. The text view that does it isn't the first
    /// responder then, and doesn't say so: what is on screen and in the file must still follow.
    func testUndoOfAnEditInTheNoteWhileACellHasTheFocus() async throws {
        let view = try await editor(note)
        view.setSelectedRange(NSRange(location: (note as NSString).range(of: "Done.").location, length: 0))
        try await settle()
        endOfEvent()
        view.insertText("Typed ", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
        endOfEvent()
        try await focus(view, row: 1, column: 0)
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, note)
        XCTAssertEqual(edits.last, note)
        XCTAssertNotNil(try tables(view).focus, "the cell keeps the focus")
        XCTAssertEqual(try tables(view).spans[0].table.gridText(row: 1, column: 0), "Mon")
    }

    func testUndoInTheNoteAcrossATableEditKeepsTheBytesRight() async throws {
        let view = try await editor(note)
        let done = (note as NSString).range(of: "Done.").location
        view.setSelectedRange(NSRange(location: done, length: 0))
        try await settle()
        endOfEvent()
        view.insertText("Before ", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
        endOfEvent()
        try await focus(view, row: 1, column: 1)
        endOfEvent()
        type("7", in: try cellEditor(view))
        endOfEvent()
        window.makeFirstResponder(view)
        try await settle()
        view.setSelectedRange(NSRange(location: 5, length: 0))
        endOfEvent()
        view.insertText(" more", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
        endOfEvent()
        XCTAssertEqual(view.string, "# Log more\n\n| Day | Km |\n|---|---|\n| Mon | 57 |\n| Tue | 6 |\n\nBefore Done.\n")
        let undo = try undoManager(view)
        undo.undo()
        endOfEvent()
        XCTAssertEqual(view.string, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 57 |\n| Tue | 6 |\n\nBefore Done.\n")
        undo.undo()
        endOfEvent()
        XCTAssertEqual(view.string, "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n\nBefore Done.\n")
        XCTAssertNil(try tables(view).focus, "an undo from the note leaves the focus on the note")
        undo.undo()
        endOfEvent()
        assertBytes(view, note)
        undo.redo()
        endOfEvent()
        undo.redo()
        endOfEvent()
        undo.redo()
        endOfEvent()
        XCTAssertEqual(view.string, "# Log more\n\n| Day | Km |\n|---|---|\n| Mon | 57 |\n| Tue | 6 |\n\nBefore Done.\n")
    }

    // MARK: inserting a table

    func testTheTableButtonInsertsAGridWithTheCaretInItsFirstCell() async throws {
        let view = try await editor("Hi\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        try await settle()
        view.performEditorAction(EditorActionSender(.table))
        try await settle()
        let overlay = try tables(view)
        XCTAssertEqual(overlay.grids.count, 1)
        XCTAssertEqual(overlay.focus, TableCellAddress(table: 0, cell: GridCell(row: 0, column: 0)))
        let cell = try cellEditor(view)
        XCTAssertTrue(window.firstResponder === cell)
        let table = overlay.spans[0].table
        XCTAssertEqual(table.gridRowCount, 3)
        XCTAssertEqual(table.gridColumnCount, 3)
        XCTAssertEqual(try hiddenCharacters(view, in: overlay.spans[0].range), overlay.spans[0].range.length)
        type("Name", in: cell)
        XCTAssertTrue(view.string.hasPrefix("Hi\n\n| Name |"), view.string)
        XCTAssertEqual(MarkdownTable(parsing: "| Name |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |\n")?.columnCount, 3)
        XCTAssertTrue(view.string.contains("| Name |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |\n"), view.string)
        try picture("mac-table-new")
    }

    // MARK: typing around a table

    func testTypingUnderATableKeepsItOutOfTheTable() async throws {
        let text = "| a |\n|---|\n| 1 |\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        try await settle()
        // As a keystroke does: through the delegate.
        XCTAssertFalse(view.shouldChangeText(in: view.selectedRange(), replacementString: "x"), "it does that itself")
        try await settle()
        assertBytes(view, "| a |\n|---|\n| 1 |\n\nx")
        XCTAssertEqual(try tables(view).spans[0].table.rows.count, 1, "and it is no row")
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).length)
    }

    func testDeletingAMarkerUnderATableKeepsItsTextOutOfTheTable() async throws {
        let text = "| a |\n|---|\n- [ ] x\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: (text as NSString).range(of: "x").location, length: 0))
        try await settle()
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, "| a |\n|---|\n\nx\n", "a blank line, so that it is no row")
        XCTAssertEqual(try tables(view).spans[0].table.rows.count, 0)
        XCTAssertFalse(NSLocationInRange(view.selectedRange().location, try tables(view).spans[0].range), "and no caret in the source")
    }

    func testGoingUnderATableThatEndsTheNoteGivesItALineToWriteOn() async throws {
        let text = "| a |\n|---|"
        let view = try await editor(text)
        try await focus(view, row: 0, column: 0)
        endOfEvent()
        command(#selector(NSResponder.cancelOperation(_:)), in: try cellEditor(view))
        try await settle()
        endOfEvent()
        assertBytes(view, text + "\n", "going there is asking for it")
        XCTAssertEqual(view.selectedRange().location, (text as NSString).length + 1)
        XCTAssertTrue(window.firstResponder === view)
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, text, "and it undoes")
    }

    func testOpeningATableThatEndsTheNoteWritesNothing() async throws {
        let text = "| a |\n|---|"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        try await settle()
        assertBytes(view, text, "no line ending just for looking")
        XCTAssertEqual(edits, [])
    }

    func testBackspaceUnderATableGoesIntoItsLastCellAndDeletesNothing() async throws {
        let text = "| a |\n|---|\n| 1 |\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        try await settle()
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, text)
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 1, column: 0))
        XCTAssertTrue(window.firstResponder === (try cellEditor(view)))
    }

    func testDeleteAtTheEndOfTheLineAboveCantJoinTheHeader() async throws {
        let text = "Hello\n| a |\n|---|\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        try await settle()
        view.deleteForward(nil)
        try await settle()
        assertBytes(view, text)
        XCTAssertEqual(view.selectedRange().location, 5)
    }

    func testBarActionsLeaveATableInASelectionAlone() async throws {
        let view = try await editor(note)
        view.setSelectedRange(NSRange(location: 0, length: (note as NSString).length))
        try await settle()
        for action in [EditorAction.bold, .checklist, .title, .bullet] {
            view.performEditorAction(EditorActionSender(action))
            assertBytes(view, note, "\(action)")
        }
    }

    func testABarActionOnTheLineUnderATableKeepsItOutOfTheTable() async throws {
        let text = "| a |\n|---|\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        try await settle()
        view.performEditorAction(EditorActionSender(.link))
        try await settle()
        assertBytes(view, "| a |\n|---|\n\n[[]]")
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).length - 2, "the caret between the brackets")
        XCTAssertEqual(try tables(view).spans[0].table.rows.count, 0)
    }

    func testASelectionOverATableCopiesItsSourceAndCanDeleteItWhole() async throws {
        let view = try await editor(note)
        let start = (note as NSString).range(of: "# Log").location
        let end = (note as NSString).range(of: "Done.").location
        view.setSelectedRange(NSRange(location: start, length: end - start))
        try await settle()
        XCTAssertEqual(view.selectedRange().length, end - start, "whole, so it may stay")
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, "Done.\n")
        XCTAssertEqual(try tables(view).grids.count, 0)
    }

    func testAnEndOfASelectionCantRestInATable() async throws {
        let view = try await editor(note)
        let table = try tables(view).spans[0].range
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await settle()
        view.setSelectedRange(NSRange(location: 0, length: table.location + 5))
        try await settle()
        XCTAssertEqual(NSMaxRange(view.selectedRange()), NSMaxRange(table), "on past it, the way it was going")
    }

    /// Key by key, as a person types it. `|---|-` is already a valid delimiter row, and turning it into a grid there would
    /// send the rest of the row somewhere else.
    private func typeInNote(_ text: String, in view: EditorTextView) async throws {
        for character in text {
            view.insertText(String(character), replacementRange: view.selectedRange())
            try await settle()
        }
    }

    func testATableTypedByHandStaysTextUntilItsLastLineIsDone() async throws {
        let view = try await editor("")
        try await typeInNote("| a | b |\n|---|-", in: view)
        XCTAssertEqual(try tables(view).grids.count, 0, "still being typed")
        try await typeInNote("--|", in: view)
        assertBytes(view, "| a | b |\n|---|---|")
        XCTAssertEqual(try tables(view).grids.count, 0, "the caret is still on it")
        XCTAssertEqual(try hiddenCharacters(view, in: NSRange(location: 0, length: 19)), 0, "and what is typed shows")

        // Return finishes it.
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 1)
        let range = try tables(view).spans[0].range
        XCTAssertEqual(range.length, 20)
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length, "no pipes on screen from here on")
        XCTAssertEqual(view.selectedRange().location, 20, "and the caret on the line under it")
        XCTAssertNil(try tables(view).focus)
        assertBytes(view, "| a | b |\n|---|---|\n")

        // What is typed next goes under the table, with a blank line so that it is no row.
        XCTAssertFalse(view.shouldChangeText(in: view.selectedRange(), replacementString: "x"))
        try await settle()
        assertBytes(view, "| a | b |\n|---|---|\n\nx")
    }

    func testATableTypedByHandBecomesAGridWhenTheCaretLeavesIt() async throws {
        let view = try await editor("Above\n\n")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        try await settle()
        try await typeInNote("| a |\n|---|", in: view)
        XCTAssertEqual(try tables(view).grids.count, 0)
        // Moving around on its lines is still typing it.
        view.setSelectedRange(NSRange(location: view.selectedRange().location - 2, length: 0))
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 0, "a typo can still be fixed")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 1, "the caret left")
        let range = try tables(view).spans[0].range
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length)
        XCTAssertEqual(view.selectedRange().location, 2, "and it stays where it went")
    }

    func testAPastedTableIsAGridAtOnce() async throws {
        let view = try await editor("Above\n\n")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        try await settle()
        view.insertText("| a |\n|---|\n| 1 |", replacementRange: view.selectedRange())
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 1, "a paste puts down a whole table")
        let range = try tables(view).spans[0].range
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length)
    }

    func testAnUndoBringingBackATableIsAGridAtOnce() async throws {
        let view = try await editor(note)
        let table = try tables(view).spans[0].range
        view.setSelectedRange(table)
        try await settle()
        endOfEvent()
        view.breakUndoCoalescing()
        view.deleteBackward(nil)
        view.breakUndoCoalescing()
        endOfEvent()
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 0)
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, note)
        XCTAssertEqual(try tables(view).grids.count, 1, "not text, wherever the undo left the caret")
        let range = try tables(view).spans[0].range
        XCTAssertEqual(try hiddenCharacters(view, in: range), range.length)
        XCTAssertFalse(NSLocationInRange(view.selectedRange().location, range) && view.selectedRange().length == 0, "and no caret in its source")
    }

    // MARK: several tables

    func testTheFocusMovesBetweenTablesAndEditsGoToTheRightOne() async throws {
        let text = "| a |\n|---|\n| 1 |\n\nBetween\n\n| b |\n|---|\n| 2 |\n"
        let view = try await editor(text)
        try await focus(view, row: 1, column: 0, table: 0)
        let first = try cellEditor(view, 0)
        type("x", in: first)
        try await focus(view, row: 1, column: 0, table: 1)
        try await settle()
        let second = try cellEditor(view, 1)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertTrue(first.isHidden)
        XCTAssertEqual(try tables(view).focus, TableCellAddress(table: 1, cell: GridCell(row: 1, column: 0)), "still there after the first has let go")
        type("y", in: second)
        assertBytes(view, "| a |\n|---|\n| 1x |\n\nBetween\n\n| b |\n|---|\n| 2y |\n")
        try tables(view).perform(.addRowBelow)
        assertBytes(view, "| a |\n|---|\n| 1x |\n\nBetween\n\n| b |\n|---|\n| 2y |\n| |\n")
    }

    func testUndoFollowsTheEditBackToItsTable() async throws {
        let text = "| a |\n|---|\n| 1 |\n\nBetween\n\n| b |\n|---|\n| 2 |\n"
        let view = try await editor(text)
        try await focus(view, row: 1, column: 0, table: 0)
        endOfEvent()
        type("x", in: try cellEditor(view, 0))
        endOfEvent()
        try await focus(view, row: 1, column: 0, table: 1)
        endOfEvent()
        try await settle()
        // Nothing typed in the second: the undo reaches the first table, and the focus goes there.
        try undoManager(view).undo()
        endOfEvent()
        try await settle()
        assertBytes(view, text)
        XCTAssertEqual(try tables(view).focus, TableCellAddress(table: 0, cell: GridCell(row: 1, column: 0)))
        XCTAssertTrue(window.firstResponder === (try cellEditor(view, 0)))
        XCTAssertEqual(try cellEditor(view, 0).string, "1")
    }

    func testTextAboveATableMovingDoesNotDisturbTheGrid() async throws {
        let view = try await editor(note)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        try await settle()
        view.insertText(" and more", replacementRange: view.selectedRange())
        try await settle()
        let span = try tables(view).spans[0]
        XCTAssertEqual((view.string as NSString).substring(with: span.range), "| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n")
        XCTAssertEqual(try hiddenCharacters(view, in: span.range), span.range.length)
        XCTAssertEqual(try hiddenCharacters(view, in: NSRange(location: 2, length: 3)), 0, "and the title isn't hidden")
        try await focus(view, row: 1, column: 0)
        type("!", in: try cellEditor(view))
        assertBytes(view, "# Log and more\n\n| Day | Km |\n|---|---|\n| Mon! | 5 |\n| Tue | 6 |\n\nDone.\n", "written at the table's new place")
    }

    // MARK: a sync

    func testASyncChangingTheNoteUpdatesTheGridAndTheCellBeingEdited() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        let coordinator = try XCTUnwrap(view.coordinator)
        let changed = note.replacingOccurrences(of: "| Mon | 5 |", with: "| Mon | 9 |").replacingOccurrences(of: "| Tue | 6 |", with: "| Tue | 8 |\n| Wed | 7 |")
        view.string = changed
        view.undoManager?.removeAllActions()
        coordinator.reloaded(view)
        try await settle()
        assertBytes(view, changed)
        XCTAssertEqual(try tables(view).spans[0].table.gridRowCount, 4)
        XCTAssertEqual(try cellEditor(view).string, "9", "what GitHub says now")
        XCTAssertNotNil(find("editor.table.cell.3.1", in: view))
        // A sync that takes the table away takes the focus with it, and nothing crashes.
        view.string = "No table now.\n"
        coordinator.reloaded(view)
        try await settle()
        XCTAssertEqual(try tables(view).grids.count, 0)
        XCTAssertNil(try tables(view).focus)
    }

    func testASyncEndsTheRunOfTypingSoWhatComesNextCanBeUndone() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        let cell = try cellEditor(view)
        endOfEvent()
        type("7", in: cell)
        endOfEvent()
        // The note comes back from a sync: its undo steps go, as `updateNSView` does it.
        let synced = view.string
        view.string = synced
        view.undoManager?.removeAllActions()
        try XCTUnwrap(view.coordinator).reloaded(view)
        try await settle()
        endOfEvent()
        type("8", in: cell)
        endOfEvent()
        assertBytes(view, synced.replacingOccurrences(of: "| Mon | 57 |", with: "| Mon | 578 |"))
        try undoManager(view).undo()
        endOfEvent()
        assertBytes(view, synced, "what was typed after the sync has its own step")
    }

    func testASyncAddingATableAboveKeepsTheFocusOnTheSameTable() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 1)
        XCTAssertEqual(try cellEditor(view).string, "5")
        let changed = "| new | table |\n|---|---|\n| x | y |\n\n" + note
        view.string = changed
        try XCTUnwrap(view.coordinator).reloaded(view)
        try await settle()
        XCTAssertEqual(try tables(view).focus, TableCellAddress(table: 1, cell: GridCell(row: 1, column: 1)), "the table it was on, not the one now at its place")
        let cell = try cellEditor(view, 1)
        XCTAssertTrue(window.firstResponder === cell)
        XCTAssertEqual(cell.string, "5")
        type("7", in: cell)
        assertBytes(view, changed.replacingOccurrences(of: "| Mon | 5 |", with: "| Mon | 57 |"))
    }

    func testASyncThatChangesTablesPastRecognitionLeavesTheFocusOnTheNote() async throws {
        let view = try await editor("| a |\n|---|\n\n| b |\n|---|\n")
        try await focus(view, row: 0, column: 0, table: 1)
        let changed = "| c |\n|---|\n"
        view.string = changed
        try XCTUnwrap(view.coordinator).reloaded(view)
        try await settle()
        XCTAssertNil(try tables(view).focus, "not on some other table")
        XCTAssertTrue(window.firstResponder === view)
        assertBytes(view, changed)
    }

    // MARK: direction

    func testAHebrewTableRunsRightToLeft() async throws {
        let text = "| פריט | עלות |\n|---|---|\n| לינה | 900 |\n| Hotel | x |\n"
        let view = try await editor(text, focused: false)
        let span = try tables(view).spans[0]
        XCTAssertTrue(span.rightToLeft)
        let first = try XCTUnwrap(find("editor.table.cell.0.0", in: view))
        let second = try XCTUnwrap(find("editor.table.cell.0.1", in: view))
        XCTAssertGreaterThan(first.frame.minX, second.frame.minX, "the first column is on the right")
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        let style = try XCTUnwrap(cell.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(style.alignment, .right)
        // In a Hebrew table, Tab still goes on in reading order, which is to the left on screen.
        command(#selector(NSResponder.insertTab(_:)), in: cell)
        XCTAssertEqual(try tables(view).focus?.cell, GridCell(row: 1, column: 1))
        XCTAssertLessThan(cell.frame.minX, first.frame.minX)
        // English in a Hebrew table reads left to right, in its own cell.
        try await focus(view, row: 2, column: 0)
        let english = try XCTUnwrap(cell.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(english.baseWritingDirection, .leftToRight)
        try await focus(view, row: 1, column: 0)
        try picture("mac-table-hebrew")
    }

    func testAnEmptyTableTakesTheDirectionOfTheLineAbove() async throws {
        let view = try await editor("שורה בעברית\n\n|   |   |\n|---|---|\n", focused: false)
        XCTAssertTrue(try tables(view).spans[0].rightToLeft)
        let english = try await editor("An English line\n\n|   |   |\n|---|---|\n", focused: false)
        XCTAssertFalse(try tables(english).spans[0].rightToLeft)
    }

    func testAlignmentInACellFollowsItsColumn() throws {
        let painter = MarkdownStyler.CellPainter()
        func alignment(_ text: String, _ column: MarkdownTable.Alignment, rtl: Bool) -> NSTextAlignment {
            painter.paragraph(text: text, alignment: column, tableRightToLeft: rtl).alignment
        }
        XCTAssertEqual(alignment("a", .none, rtl: false), .left)
        XCTAssertEqual(alignment("שלום", .none, rtl: false), .right, "a cell's text goes to its own side")
        XCTAssertEqual(alignment("", .none, rtl: true), .right, "an empty cell goes by the table")
        XCTAssertEqual(alignment("a", .center, rtl: true), .center)
        XCTAssertEqual(alignment("a", .right, rtl: false), .right)
        XCTAssertEqual(alignment("a", .left, rtl: true), .right, "by the table's direction, as in the note view")
    }

    // MARK: sizes

    func testColumnWidths() {
        // Everything fits: what is left over goes round evenly, and the whole width is used.
        XCTAssertEqual(TableGridGeometry.columnWidths(ideal: [80, 100], available: 300).reduce(0, +), 300)
        XCTAssertEqual(TableGridGeometry.columnWidths(ideal: [0, 0, 0], available: 300), [100, 100, 100])
        // Doesn't fit: the short column keeps its width, the long ones share the rest.
        let shared = TableGridGeometry.columnWidths(ideal: [80, 500, 500], available: 400)
        XCTAssertEqual(shared[0], 80)
        XCTAssertEqual(shared.reduce(0, +), 400)
        XCTAssertEqual(shared[1], 160)
        // Too many to fit even at their narrowest: it scrolls, at widths that still read.
        let wide = TableGridGeometry.columnWidths(ideal: [10, 900, 10, 10, 10, 10, 10, 10], available: 300)
        XCTAssertGreaterThan(wide.reduce(0, +), 300)
        XCTAssertEqual(wide[0], TableGridMetrics.minimumColumn)
        XCTAssertLessThanOrEqual(wide[1], 300 * 0.6 + 1, "one long cell doesn't push the others far away")
    }

    func testACellComesIntoViewWithItsTablesTopEdgeIfThatFits() {
        let cell = CGRect(x: 0, y: 200, width: 50, height: 40)
        let fromTable = 100 - TableGridMetrics.marginAbove
        XCTAssertEqual(TableGridState.revealTop(cell: cell, plateTop: 100, room: 300), fromTable, "the column handle shows too")
        XCTAssertEqual(TableGridState.revealTop(cell: cell, plateTop: 100, room: 100), 200 - TableGridMetrics.marginAbove, "the cell comes first")
    }

    func testFramesMirrorInARightToLeftTable() {
        let geometry = TableGridGeometry(columnWidths: [100, 50, 70], rowHeights: [40, 60])
        let cell = GridCell(row: 1, column: 1)
        XCTAssertEqual(geometry.cellFrame(cell, rightToLeft: false), CGRect(x: 100, y: 40, width: 50, height: 60))
        XCTAssertEqual(geometry.cellFrame(cell, rightToLeft: true), CGRect(x: 70, y: 40, width: 50, height: 60))
        XCTAssertEqual(geometry.cellFrame(GridCell(row: 0, column: 0), rightToLeft: true).maxX, 220, "the first column is at the right edge")
        for rtl in [false, true] {
            for row in 0..<2 {
                for column in 0..<3 {
                    let found = GridCell(row: row, column: column)
                    let frame = geometry.cellFrame(found, rightToLeft: rtl)
                    XCTAssertEqual(geometry.cell(at: CGPoint(x: frame.midX, y: frame.midY), rightToLeft: rtl), found)
                    XCTAssertEqual(geometry.cell(at: CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5), rightToLeft: rtl), found)
                }
            }
        }
        XCTAssertNil(geometry.cell(at: CGPoint(x: -1, y: 5), rightToLeft: false))
        XCTAssertNil(geometry.cell(at: CGPoint(x: 5, y: 101), rightToLeft: true))
        XCTAssertNil(geometry.cellFrame(GridCell(row: 9, column: 0), rightToLeft: false).isEmpty ? nil : 1)
    }

    func testALongCellWrapsAndItsRowGrows() async throws {
        let long = String(repeating: "long words here ", count: 12)
        let text = "| a | b |\n|---|---|\n| \(long)| x |\n| y | z |\n"
        let view = try await editor(text, focused: false)
        let geometry = try grid(view)
        let span = try tables(view).spans[0]
        XCTAssertEqual(geometry.frame.height, span.height)
        let tall = try XCTUnwrap(find("editor.table.cell.1.0", in: view)).frame.height
        let short = try XCTUnwrap(find("editor.table.cell.2.0", in: view)).frame.height
        XCTAssertGreaterThan(tall, short * 1.5)
    }

    func testTypingARowTallerPushesTheTextBelowDown() async throws {
        let view = try await editor(note, size: NSSize(width: 360, height: 640))
        let before = try grid(view).frame.height
        try await focus(view, row: 1, column: 0)
        type(String(repeating: "more words ", count: 12), in: try cellEditor(view))
        try await settle()
        let after = try grid(view).frame.height
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(after, try tables(view).spans[0].height)
    }

    func testColumnsKeepTheirWidthsWhileATableHasTheFocusAndSettleAfter() async throws {
        let view = try await editor(note)
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        let overlay = try tables(view)
        let span = overlay.spans[0]
        let widths = overlay.geometry(of: span.table, index: 0).columnWidths
        type("a much longer text than it had", in: cell)
        let typing = overlay.spans[0]
        XCTAssertEqual(overlay.geometry(of: typing.table, index: 0).columnWidths, widths, "no shifting under the fingers")
        window.makeFirstResponder(view)
        try await settle()
        let after = overlay.geometry(of: overlay.spans[0].table, index: 0).columnWidths
        XCTAssertGreaterThan(after[0], widths[0], "room for it, now that nobody is typing")
    }

    func testAWideTableScrollsSideways() async throws {
        let header = (1...10).map { "Column \($0)" }.joined(separator: " | ")
        let row = (1...10).map { "value \($0)" }.joined(separator: " | ")
        let text = "| \(header) |\n|" + String(repeating: "---|", count: 10) + "\n| \(row) |\n"
        let view = try await editor(text, size: NSSize(width: 420, height: 400))
        let overlay = try tables(view)
        let span = overlay.spans[0]
        let geometry = overlay.geometry(of: span.table, index: 0)
        XCTAssertGreaterThan(geometry.totalWidth, 420)
        XCTAssertEqual(try grid(view).frame.width, view.bounds.width, "the grid itself stays as wide as the note")
        try await focus(view, row: 1, column: 9)
        XCTAssertEqual(try cellEditor(view).string, "value 10")
        try picture("mac-table-wide")
    }

    // MARK: speed

    /// The largest note there is, with a table in it: typing in the note and in a cell, a debug build on this Mac.
    func testALongNoteWithATableStaysQuick() async throws {
        let body = StyleTiming.syntheticNote()
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\n" + body
        let view = try await editor(text, focused: false)
        let clock = ContinuousClock()
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        try await focus(view, row: 1, column: 0)
        let cell = try cellEditor(view)
        var times: [Double] = []
        for _ in 0..<7 {
            let time = clock.measure { cell.insertText("x", replacementRange: cell.selectedRange()) }
            times.append(ms(time))
        }
        times.sort()
        let median = times[times.count / 2]
        try? "A keystroke in a cell of a 271 KB note: median \(median) ms\n".write(to: LivePreviewTests.shots.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("editor-table-timing.txt"), atomically: true, encoding: .utf8)
        // Debug build, sharing the machine with the other tests: this only catches something far off.
        XCTAssertLessThan(median, 250)
    }

    func testANoteWithoutTablesPaysNothing() throws {
        // The gate: no pipe and no colon-dash, no parse.
        let note = StyleTiming.syntheticNote(targetBytes: 50_000)
        XCTAssertFalse(TableEdits.mayHoldTable(note as NSString))
    }
}
