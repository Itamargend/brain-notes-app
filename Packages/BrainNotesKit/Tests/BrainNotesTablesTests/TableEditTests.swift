import Testing
@testable import BrainNotesTables

/// Golden tests for each edit: the exact bytes after it. A line the edit doesn't touch keeps its bytes.
@Suite struct TableEditTests {
    private let small = "| a | b |\n|---|:-:|\n| 1 | 2 |\n"
    private let bare = "a | b\n--- | ---\n1 | 2"
    private let tight = "|a|b|\n|-|-|\n|1|2|\n"
    private let ragged = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |\n"

    private func expectEdit(_ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation,
                            _ change: (inout MarkdownTable) throws -> Void) throws {
        let got = try edited(before, change)
        #expect(bytes(got) == bytes(after), "\(before) gave \(got)", sourceLocation: sourceLocation)
        // What was written reads back as the same table.
        var model = try #require(MarkdownTable(parsing: before), sourceLocation: sourceLocation)
        try change(&model)
        let reread = try #require(MarkdownTable(parsing: got), sourceLocation: sourceLocation)
        #expect(reread.shown == model.shown, sourceLocation: sourceLocation)
    }

    // MARK: cells

    @Test func setACell() throws {
        try expectEdit(small, "| a | b |\n|---|:-:|\n| 1 | two |\n") { try $0.setCell(row: 0, column: 1, to: "two") }
        try expectEdit(small, "| A | b |\n|---|:-:|\n| 1 | 2 |\n") { try $0.setHeader(column: 0, to: "A") }
        try expectEdit(tight, "|a|b|\n|-|-|\n|1|x y|\n") { try $0.setCell(row: 0, column: 1, to: "  x\ny  ") }
    }

    @Test func settingTheSameTextChangesNothing() throws {
        var table = try #require(MarkdownTable(parsing: small))
        try table.setCell(row: 0, column: 0, to: "1")
        try table.setHeader(column: 1, to: " b ")
        #expect(!table.isEdited)
        #expect(table.rows[0].isUntouched)
    }

    @Test func aPipeInNewTextIsEscaped() throws {
        let text = "| code | note |\n|---|---|\n| `a\\|b` | x \\| y |\n"
        try expectEdit(text, "| code | note |\n|---|---|\n| `x\\|y` and a\\|b | x \\| y |\n") {
            try $0.setCell(row: 0, column: 0, to: "`x|y` and a|b")
        }
        // A backslash typed before a pipe stays a backslash, and the pipe stays in the cell.
        try expectEdit(text, "| code | note |\n|---|---|\n| `a\\|b` | a\\\\|b |\n") {
            try $0.setCell(row: 0, column: 1, to: "a\\|b")
        }
        var table = try #require(MarkdownTable(parsing: text))
        try table.setCell(row: 0, column: 1, to: "a\\|b")
        #expect(table.text(row: 0, column: 1) == "a\\|b")
    }

    @Test func aCellEndingInABackslashKeepsItsPipe() throws {
        try expectEdit(tight, "|a|b|\n|-|-|\n|1|C:\\ |\n") { try $0.setCell(row: 0, column: 1, to: "C:\\") }
    }

    @Test func anEmptyCellTakesTheRowsPadding() throws {
        try expectEdit("| a | b |\n|---|---|\n|   | 2 |\n", "| a | b |\n|---|---|\n| x | 2 |\n") {
            try $0.setCell(row: 0, column: 0, to: "x")
        }
    }

    // MARK: rows that would read differently

    @Test func aFirstCellThatStartsABlockGetsPipes() throws {
        try expectEdit(bare, "a | b\n--- | ---\n| # x | 2 |") { try $0.setCell(row: 0, column: 0, to: "# x") }
        try expectEdit(bare, "a | b\n--- | ---\n| - li | 2 |") { try $0.setCell(row: 0, column: 0, to: "- li") }
        try expectEdit(bare, "a | b\n--- | ---\n|  | 2 |") { try $0.setCell(row: 0, column: 0, to: "") }
    }

    @Test func anEmptyLastCellGetsPipes() throws {
        try expectEdit(bare, "a | b\n--- | ---\n| 1 |  |") { try $0.setCell(row: 0, column: 1, to: "") }
    }

    @Test func anEmptiedHeaderCellDoesNotTurnTheRowIntoCode() throws {
        let text = "   a  | b\n   ---|---\n"
        let got = try edited(text) { try $0.setHeader(column: 0, to: "") }
        #expect(bytes(got) == bytes("   |   | b |\n   ---|---\n"))
        #expect(TableDocument(parsing: got).tables.first?.headerTexts == ["", "b"])
    }

    // MARK: rows

    @Test func insertRows() throws {
        try expectEdit(small, "| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |\n") { try $0.insertRow(at: 1, texts: ["3", "4"]) }
        try expectEdit(small, "| a | b |\n|---|:-:|\n| x | |\n| 1 | 2 |\n") { try $0.insertRow(at: 0, texts: ["x"]) }
        try expectEdit(tight, "|a|b|\n|-|-|\n|1|2|\n|x|y|\n") { try $0.insertRow(at: 1, texts: ["x", "y"]) }
        try expectEdit(bare, "a | b\n--- | ---\n1 | 2\n3 | 4") { try $0.insertRow(at: 1, texts: ["3", "4"]) }
    }

    @Test func removeRows() throws {
        try expectEdit(small, "| a | b |\n|---|:-:|\n") { try $0.removeRow(at: 0) }
        try expectEdit("| a |\n|---|\n| 1 |\n| 2 |", "| a |\n|---|\n| 1 |") { try $0.removeRow(at: 1) }
        try expectEdit("| a |\n|---|\n| 1 |\n| 2 |", "| a |\n|---|\n| 2 |") { try $0.removeRow(at: 0) }
    }

    @Test func aNewRowUsesTheTablesLineEndings() throws {
        try expectEdit("| a |\r\n|---|\r\n| 1 |", "| a |\r\n|---|\r\n| 1 |\r\n| |") { try $0.insertRow(at: 1) }
        try expectEdit("| a |\r\n|---|\r\n| 1 |", "| a |\r\n|---|") { try $0.removeRow(at: 0) }
        try expectEdit("| a |\r|---|\r| 1 |\r", "| a |\r|---|\r| 0 |\r| 1 |\r") { try $0.insertRow(at: 0, texts: ["0"]) }
    }

    // MARK: columns

    @Test func insertColumns() throws {
        try expectEdit(small, "| a | b | c |\n|---|:-:|---|\n| 1 | 2 | |\n") { try $0.insertColumn(at: 2, header: "c") }
        try expectEdit(small, "| z | a | b |\n|:--|---|:-:|\n| | 1 | 2 |\n") {
            try $0.insertColumn(at: 0, header: "z", alignment: .left)
        }
        try expectEdit(tight, "|a|m|b|\n|-|---|-|\n|1||2|\n") { try $0.insertColumn(at: 1, header: "m") }
        try expectEdit(bare, "z | a | b\n--- | --- | ---\n| | 1 | 2 |") { try $0.insertColumn(at: 0, header: "z") }
        try expectEdit(bare, "a | b | z\n--- | --- | ---\n| 1 | 2 | |") { try $0.insertColumn(at: 2, header: "z") }
    }

    @Test func removeColumns() throws {
        try expectEdit(small, "| b |\n|:-:|\n| 2 |\n") { try $0.removeColumn(at: 0) }
        // One column left: the header and delimiter rows need a pipe to stay a table.
        try expectEdit(bare, "| b |\n| --- |\n2") { try $0.removeColumn(at: 0) }
        try expectEdit(bare, "| a |\n| --- |\n1") { try $0.removeColumn(at: 1) }
    }

    @Test func alignment() throws {
        try expectEdit(tight, "|a|b|\n|:-:|-|\n|1|2|\n") { try $0.setAlignment(.center, column: 0) }
        try expectEdit("| a |\n| :---: |\n", "| a |\n| ----- |\n") { try $0.setAlignment(.none, column: 0) }
        try expectEdit("| a |\n|-----|\n", "| a |\n|----:|\n") { try $0.setAlignment(.right, column: 0) }
        try expectEdit("| a |\n|-----|\n", "| a |\n|:----|\n") { try $0.setAlignment(.left, column: 0) }
        var table = try #require(MarkdownTable(parsing: small))
        try table.setAlignment(.center, column: 1)
        #expect(!table.isEdited)
    }

    // MARK: ragged rows

    @Test func raggedRowsUnderEdits() throws {
        try expectEdit(ragged, "| a | b | c |\n|---|---|---|\n| 1 | | x |\n| 1 | 2 | 3 | 4 |\n") {
            try $0.setCell(row: 0, column: 2, to: "x")
        }
        try expectEdit(ragged, "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | extra |\n") {
            try $0.setCell(row: 1, column: 3, to: "extra")
        }
        try expectEdit(ragged, "| a | n | b | c |\n|---|---|---|---|\n| 1 |\n| 1 | | 2 | 3 | 4 |\n") {
            try $0.insertColumn(at: 1, header: "n")
        }
        try expectEdit(ragged, "| a | b | c | d |\n|---|---|---|---|\n| 1 |\n| 1 | 2 | 3 | | 4 |\n") {
            try $0.insertColumn(at: 3, header: "d")
        }
        try expectEdit(ragged, "| b | c |\n|---|---|\n||\n| 2 | 3 | 4 |\n") { try $0.removeColumn(at: 0) }
        try expectEdit(ragged, "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 4 |\n") { try $0.removeColumn(at: 2) }
    }

    @Test func emptyTextInAMissingCellChangesNothing() throws {
        var table = try #require(MarkdownTable(parsing: ragged))
        try table.setCell(row: 0, column: 2, to: "  ")
        #expect(!table.isEdited)
    }

    // MARK: refusals

    @Test func badPositionsAreRefused() throws {
        var table = try #require(MarkdownTable(parsing: small))
        #expect(throws: MarkdownTable.EditError.noSuchRow(1)) { try table.setCell(row: 1, column: 0, to: "x") }
        #expect(throws: MarkdownTable.EditError.noSuchRow(-1)) { try table.setCell(row: -1, column: 0, to: "x") }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(2)) { try table.setCell(row: 0, column: 2, to: "x") }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(2)) { try table.setHeader(column: 2, to: "x") }
        #expect(throws: MarkdownTable.EditError.noSuchRow(2)) { try table.insertRow(at: 2) }
        #expect(throws: MarkdownTable.EditError.tooManyCells(3)) { try table.insertRow(at: 0, texts: ["1", "2", "3"]) }
        #expect(throws: MarkdownTable.EditError.noSuchRow(1)) { try table.removeRow(at: 1) }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(3)) { try table.insertColumn(at: 3) }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(2)) { try table.removeColumn(at: 2) }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(5)) { try table.setAlignment(.left, column: 5) }
        #expect(!table.isEdited)
        #expect(bytes(table.markdown) == bytes(small))

        var one = try #require(MarkdownTable(parsing: "| a |\n|---|\n| 1 |\n"))
        #expect(throws: MarkdownTable.EditError.lastColumn) { try one.removeColumn(at: 0) }
    }
}
