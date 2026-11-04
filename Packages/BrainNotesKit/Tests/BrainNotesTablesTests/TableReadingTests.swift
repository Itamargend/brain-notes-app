import Testing
@testable import BrainNotesTables

/// What is a table and what isn't, and what each part of a row holds.
@Suite struct TableReadingTests {
    private func tableCount(_ text: String) -> Int { TableDocument(parsing: text).tables.count }

    private func roundTrips(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(bytes(TableDocument(parsing: text).markdown) == bytes(text), sourceLocation: sourceLocation)
    }

    @Test func aPlainTable() throws {
        let table = try #require(MarkdownTable(parsing: "| a | b |\n|---|:-:|\n| 1 | 2 |\n"))
        #expect(table.columnCount == 2)
        #expect(table.headerTexts == ["a", "b"])
        #expect(table.alignments == [.none, .center])
        #expect(table.rows.map(\.texts) == [["1", "2"]])
        #expect(!table.isEdited)
    }

    @Test func everyAlignment() throws {
        let table = try #require(MarkdownTable(parsing: "a|b|c|d\n---|:--|--:|:-:\n"))
        #expect(table.alignments == [.none, .left, .right, .center])
        #expect(table.rows.isEmpty)
    }

    @Test func aRowKeepsItsParts() throws {
        let table = try #require(MarkdownTable(parsing: "  |  a\t|b  |  \n  |---|---|\n"))
        let header = table.header
        #expect(header.indent == "  ")
        #expect(header.leadingPipe && header.trailingPipe)
        #expect(header.trail == "  ")
        #expect(header.cells.map(\.leading) == ["  ", ""])
        #expect(header.cells.map(\.raw) == ["a", "b"])
        #expect(header.cells.map(\.trailing) == ["\t", "  "])
        #expect(header.lineEnding == "\n")
    }

    @Test func outerPipesAreOptional() throws {
        let table = try #require(MarkdownTable(parsing: "a | b\n--- | ---\n1 | 2"))
        #expect(!table.header.leadingPipe && !table.header.trailingPipe)
        #expect(table.rows.map(\.texts) == [["1", "2"]])
        #expect(table.rows[0].lineEnding == "")
    }

    @Test func anEmptyCellKeepsItsSpacesInFront() throws {
        let table = try #require(MarkdownTable(parsing: "| a | b |\n|---|---|\n|   | 2 |\n"))
        let cell = table.rows[0].cells[0]
        #expect(cell.leading == "   " && cell.raw == "" && cell.trailing == "")
    }

    // MARK: pipes inside cells

    @Test func anEscapedPipeStaysInItsCell() throws {
        let table = try #require(MarkdownTable(parsing: "| a | b |\n|---|---|\n| x \\| y | z |\n"))
        #expect(table.rows[0].cells.map(\.raw) == ["x \\| y", "z"])
        #expect(table.text(row: 0, column: 0) == "x | y")
    }

    /// GitHub's scanner keeps a pipe after any backslash in the cell, even one that is itself escaped.
    @Test func aPipeAfterTwoBackslashesStillStays() throws {
        let table = try #require(MarkdownTable(parsing: "| a |\n|---|\n| x\\\\|y |\n"))
        #expect(table.rows[0].cells.map(\.raw) == ["x\\\\|y"])
        #expect(table.text(row: 0, column: 0) == "x\\|y")
    }

    /// As on GitHub, backticks don't protect a pipe: escape it, and it reads as a plain pipe inside the code too.
    @Test func pipesInInlineCode() throws {
        let split = try #require(MarkdownTable(parsing: "| a | b |\n|---|---|\n| `x|y` |\n"))
        #expect(split.rows[0].cells.map(\.raw) == ["`x", "y`"])
        let kept = try #require(MarkdownTable(parsing: "| a | b |\n|---|---|\n| `x\\|y` | 2 |\n"))
        #expect(kept.rows[0].texts == ["`x|y`", "2"])
    }

    // MARK: ragged rows

    @Test func raggedRowsAreKeptAsWritten() throws {
        let text = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |\nonly\n"
        let table = try #require(MarkdownTable(parsing: text))
        #expect(table.rows.map(\.cells.count) == [1, 4, 1])
        #expect(table.text(row: 0, column: 2) == "")
        #expect(table.text(row: 1, column: 3) == "4")
        #expect(table.text(row: 2, column: 0) == "only")
        #expect(table.text(row: 9, column: 0) == "")
        roundTrips(text)
    }

    // MARK: where a table ends

    @Test(arguments: [
        ("| a |\n|---|\n| 1 |\n\nafter\n", 1),
        ("| a |\n|---|\n| 1 |\n# heading\n", 1),
        ("| a |\n|---|\n| 1 |\n> quote\n", 1),
        ("| a |\n|---|\n| 1 |\n- item\n", 1),
        ("| a |\n|---|\n| 1 |\n1. item\n", 1),
        ("| a |\n|---|\n| 1 |\n```\ncode\n```\n", 1),
        ("| a |\n|---|\n| 1 |\n***\n", 1),
        ("| a |\n|---|\n| 1 |\nplain line\n| 2 |\n", 3),
        ("| a |\n|---|\n| 1 |\n    indented\n", 1), // indented code, as on GitHub
        ("| a |\n|---|\n", 0),
    ])
    func whereATableEnds(text: String, rows: Int) throws {
        let doc = TableDocument(parsing: text)
        let table = try #require(doc.tables.first)
        #expect(table.rows.count == rows)
        #expect(bytes(doc.markdown) == bytes(text))
    }

    @Test func aParagraphLineAboveStaysText() throws {
        let doc = TableDocument(parsing: "intro\n| a |\n|---|\n")
        #expect(doc.pieces.count == 2)
        guard case .text(let intro) = doc.pieces[0] else { Issue.record("not text"); return }
        #expect(intro == "intro\n")
        #expect(doc.tables.first?.headerTexts == ["a"])
    }

    // MARK: what isn't a table

    @Test(arguments: [
        "a\n---\n", // a heading
        "a | b\n--- ---\n", // no pipe in the delimiter row
        "| a | b |\n|---|\n", // cell counts differ
        "| a |\n| b |\n", // no delimiter row
        "| a |\n|-x-|\n", // not a delimiter row
        "| a |\n| : |\n", // a colon is no dash
        "    | a |\n    |---|\n", // indented code
        "| a |\n    |---|\n", // delimiter indented as code
        "```\n| a |\n|---|\n```\n", // inside a fence
        "~~~~\n| a |\n|---|\n~~~\n| b |\n|---|\n", // ~~~ doesn't close ~~~~
        "> | a |\n> |---|\n", // inside a quote
        "# | a |\n|---|\n", // a heading is no header row
        "---\ntitle: x\n| a |\n|---|\n---\n", // front matter
        "\n\n", "", "|", "||\n||\n",
    ])
    func notATable(text: String) {
        #expect(tableCount(text) == 0, "\(text)")
        roundTrips(text)
    }

    @Test func afterAFenceClosesTablesCountAgain() {
        let text = "```swift\nlet x = \"| a |\"\n```\n| a |\n|---|\n"
        #expect(tableCount(text) == 1)
        roundTrips(text)
    }

    @Test func aByteOrderMarkStaysAndTheTableIsStillFound() throws {
        let text = "\u{FEFF}| a |\n|---|\n| 1 |"
        let doc = TableDocument(parsing: text)
        #expect(doc.tables.count == 1)
        guard case .text(let bom) = doc.pieces[0] else { Issue.record("BOM not kept as text"); return }
        #expect(bytes(bom) == [0xEF, 0xBB, 0xBF])
        #expect(bytes(doc.markdown) == bytes(text))
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func everyLineEnding(eol: String) throws {
        let text = ["| a | b |", "|---|---|", "| 1 | 2 |", "", "after"].joined(separator: eol) + eol
        let doc = TableDocument(parsing: text)
        let table = try #require(doc.tables.first)
        #expect(table.rows.count == 1)
        #expect(table.header.lineEnding == eol)
        #expect(bytes(doc.markdown) == bytes(text))
    }

    @Test func twoTablesAndTheTextBetween() {
        let text = "# Log\n\n| a |\n|---|\n| 1 |\n\nmiddle\n\nx | y\n--|--\n3 | 4\n"
        let doc = TableDocument(parsing: text)
        #expect(doc.tables.count == 2)
        #expect(doc.pieces.count == 4)
        #expect(bytes(doc.markdown) == bytes(text))
    }

    // MARK: direction

    @Test func hebrewAndMixedDirections() throws {
        let text = "| תאריך | הערות |\n|---|---|\n| 2026-09-01 | ריצה טובה |\n| 10K | 10K ריצה |\n| \u{200F}10K | ריצה 10K |\n"
        let table = try #require(MarkdownTable(parsing: text))
        #expect(table.isRightToLeft)
        #expect(table.header.cells.map(\.isRightToLeft) == [true, true])
        #expect(table.rows[0].cells.map(\.isRightToLeft) == [false, true]) // a date has no strong character
        #expect(table.rows[1].cells.map(\.isRightToLeft) == [false, false])
        #expect(table.rows[2].cells.map(\.isRightToLeft) == [true, true])
        #expect(bytes(table.markdown) == bytes(text))
    }

    @Test func directionMarksAreContentNotPadding() throws {
        let table = try #require(MarkdownTable(parsing: "| a |\n|---|\n| \u{200F} x \u{200E} |\n"))
        let cell = table.rows[0].cells[0]
        #expect(bytes(cell.raw) == bytes("\u{200F} x \u{200E}"))
        #expect(cell.leading == " " && cell.trailing == " ")
    }

    // MARK: offsets for the editor

    @Test func utf16RangesFindTheTables() throws {
        let text = "שלום 👋\n\n| a |\n|---|\n| ב |\n\nend"
        let doc = TableDocument(parsing: text)
        let range = doc.utf16Range(ofTable: 0)
        let units = Array(text.utf16)
        #expect(Array(units[range]) == Array("| a |\n|---|\n| ב |\n".utf16))
        #expect(doc.tableIndex(atUTF16Offset: range.lowerBound) == 0)
        #expect(doc.tableIndex(atUTF16Offset: range.upperBound - 1) == 0)
        #expect(doc.tableIndex(atUTF16Offset: range.lowerBound - 1) == nil)
        #expect(doc.tableIndex(atUTF16Offset: range.upperBound) == nil)
    }

    @Test func parsingATableAloneNeedsTheWholeText() {
        #expect(MarkdownTable(parsing: "| a |\n|---|\n\nmore") == nil)
        #expect(MarkdownTable(parsing: "plain") == nil)
        #expect(MarkdownTable(parsing: "| a |\n|---|") != nil)
    }
}
