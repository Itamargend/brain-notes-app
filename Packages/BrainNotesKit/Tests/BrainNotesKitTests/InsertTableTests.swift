import Foundation
import Testing
@testable import BrainNotesKit

@Suite struct InsertTableTests {
    @Test func insertTableAtStartOfEmptyNote() {
        let edit = MarkdownEdits.insertTable(in: "", selection: NSRange(location: 0, length: 0))
        let text = edit.applied(to: "")
        #expect(TableDocument(parsing: text).tables.count == 1)
        let table = TableDocument(parsing: text).tables[0]
        #expect(table.columnCount == 3)
        #expect(table.gridRowCount == 3)
        #expect(edit.selection.location == 2)
        #expect(edit.selection.length == 0)
    }

    @Test func insertTableAfterParagraphAddsBlankLine() {
        let before = "Hello"
        let edit = MarkdownEdits.insertTable(in: before, selection: NSRange(location: 5, length: 0))
        let after = edit.applied(to: before)
        #expect(after.hasPrefix("Hello\n\n|"))
        #expect(TableDocument(parsing: after).tables.count == 1)
        // blank line (\n\n = 2) then "| " (2) → caret at 5+4 = 9
        #expect(edit.selection.location == 9)
    }

    @Test func insertTableOnBlankLineNeedsOnlyOneExtraBreak() {
        let before = "Hello\n"
        let edit = MarkdownEdits.insertTable(in: before, selection: NSRange(location: 6, length: 0))
        let after = edit.applied(to: before)
        #expect(after.hasPrefix("Hello\n\n|"))
        #expect(TableDocument(parsing: after).tables.count == 1)
    }

    @Test func insertTableReplacesSelection() {
        let before = "abc"
        let edit = MarkdownEdits.insertTable(in: before, selection: NSRange(location: 1, length: 1))
        let after = edit.applied(to: before)
        #expect(after.hasPrefix("a"))
        #expect(after.hasSuffix("c") || after.contains("c"))
        #expect(!after.contains("b") || after.range(of: "b") == nil)
        // selection "b" replaced: "a" + table + "c"
        #expect(after.first == "a")
        #expect(after.last == "c" || after.contains("c\n") || after.hasSuffix("c"))
        let doc = TableDocument(parsing: after)
        #expect(doc.tables.count == 1)
        #expect(after.contains("|---|---|---|"))
    }

    @Test func insertTableIsThreeByThree() {
        let edit = MarkdownEdits.insertTable(in: "", selection: NSRange(location: 0, length: 0))
        let table = TableDocument(parsing: edit.applied(to: "")).tables[0]
        #expect(table.columnCount == 3)
        #expect(table.rows.count == 2)
        #expect(table.isRectangular)
        #expect(table.headerTexts == ["", "", ""])
        #expect(table.text(row: 0, column: 0) == "")
    }

    /// A line right under a table's last row would be another row of it on GitHub.
    @Test func textAfterTheInsertionStaysOutOfTheTable() {
        for before in ["World", "Hello\nWorld"] {
            let at = (before as NSString).range(of: "World").location
            let edit = MarkdownEdits.insertTable(in: before, selection: NSRange(location: at, length: 0))
            let after = edit.applied(to: before)
            #expect(after.hasSuffix("\n\nWorld"), "\(after.debugDescription)")
            let table = TableDocument(parsing: after).tables[0]
            #expect(table.rows.count == 2, "\(after.debugDescription)")
        }
        let atLineEnd = MarkdownEdits.insertTable(in: "Hello\nWorld", selection: NSRange(location: 5, length: 0)).applied(to: "Hello\nWorld")
        #expect(atLineEnd.hasSuffix("|\n\nWorld"), "\(atLineEnd.debugDescription)")
        #expect(TableEdits.spans(in: atLineEnd)[0].table.rows.count == 2)
    }

    @Test func aTableAtTheEndOfTheNoteLeavesALineForTheCaret() {
        let after = MarkdownEdits.insertTable(in: "", selection: NSRange(location: 0, length: 0)).applied(to: "")
        #expect(after.hasSuffix("|\n"))
    }

    @Test func aCRLFNoteGetsACRLFTable() {
        let before = "Hello\r\n"
        let after = MarkdownEdits.insertTable(in: before, selection: NSRange(location: 7, length: 0)).applied(to: before)
        #expect(!after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(after.debugDescription)")
        #expect(TableEdits.spans(in: after).count == 1)
    }
}
