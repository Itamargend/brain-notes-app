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
        #expect(table.rows.count == 1)
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

    @Test func insertTableIsThreeColumnsWithOneBodyRow() {
        let edit = MarkdownEdits.insertTable(in: "", selection: NSRange(location: 0, length: 0))
        let table = TableDocument(parsing: edit.applied(to: "")).tables[0]
        #expect(table.columnCount == 3)
        #expect(table.rows.count == 1)
        #expect(table.headerTexts == ["", "", ""])
        #expect(table.text(row: 0, column: 0) == "")
    }
}
