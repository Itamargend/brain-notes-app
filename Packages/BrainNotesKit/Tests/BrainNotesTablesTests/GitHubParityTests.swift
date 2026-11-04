import Testing
@testable import BrainNotesTables

/// Where a table is, as GitHub sees it. Every expected value here was checked against cmark-gfm itself (the parser
/// GitHub renders with, through its Python binding `cmarkgfm`), not worked out by hand. A wrong answer either way is
/// a bug: a table the kit misses can't be edited as a grid, and a table GitHub doesn't show is worse, since the
/// editor would offer a grid for text that renders as a paragraph.
@Suite struct GitHubParityTests {
    /// Per table: columns and body rows.
    private func shape(_ text: String) -> [[Int]] {
        TableDocument(parsing: text).tables.map { [$0.columnCount, $0.rows.count] }
    }

    @Test(arguments: [
        // A lone pipe, spaces or not after it, is a row of no cells: it ends the table, and can't head one.
        ("| a |\n|---|\n|\nafter\n", [[1, 0]]),
        ("| a |\n|---|\n| 1 |\n|  \nafter\n", [[1, 1]]),
        ("| a |\n|---|\n| 1 |\n\t|\t\n", [[1, 1]]),
        ("|\n|---|\n", []),
        ("| \n|---|\n", []),
        ("  |\n|---|\n", []),
        // A row indented 4 columns is indented code, so the table ends before it.
        ("| a |\n|---|\n| 1 |\n    indented\n", [[1, 1]]),
        ("| a |\n|---|\n| 1 |\n\tindented\n", [[1, 1]]),
        // Lines right under a list item or a quote continue its paragraph: no table there.
        ("- item\n| a | b |\n|---|---|\n", []),
        ("> q\n| a |\n|---|\n", []),
        ("1. item\n| a |\n|---|\n| 1 |\n", []),
        // After a blank line, or indented into the item, a table is a table again.
        ("- item\n\n| a |\n|---|\n", [[1, 0]]),
        ("- item\n\n    | a | b |\n    |---|---|\n    | 1 | 2 |\n", [[2, 1]]),
        ("- item\n  | a |\n  |---|\n", [[1, 0]]),
        // An item or quote with no paragraph in it has nothing to continue.
        ("- # h\na|b\n-|-\n", [[2, 0]]),
        ("> \na|b\n-|-\n", [[2, 0]]),
        ("- \na|b\n-|-\n", [[2, 0]]),
        // A paragraph gets one try: a delimiter-looking line that made no table means none later in it.
        ("x\n-|-\n-|-\n", []),
        ("x\n|-|-|\na|b\n-|-\n", []),
        ("x\n:|-\na|b\n-|-\n", [[2, 0]]), // `:|-` is no delimiter row, so no try was used
        // A heading's underline ends the paragraph, and with it the try.
        ("x\n===\na|b\n-|-\n", [[2, 0]]),
        ("x\n---\n| a |\n|---|\n", [[1, 0]]),
        // Neither row needs a pipe, as long as one of them has one or the delimiter has a colon.
        ("a\n|---|\n", [[1, 0]]),
        ("x\n:-:\n", [[1, 0]]),
        ("x\n---:\n", [[1, 0]]),
        // A header that continues a paragraph may be indented any amount.
        ("intro\n    a | b\n--|--\n", [[2, 0]]),
        // List items: an empty one is closed by a blank line; one numbered from 2 can't break a paragraph.
        ("1. \n  \n\n    a|b\n     --- |--\n", []),
        ("x\n2. y\na|b\n-|-\n", [[2, 0]]),
        ("*   x\n1. \n\n    a|b\n     --- |--\n", []),
        // A delimiter row that starts a list item is the list item.
        ("a|b\n- | -\n", []),
    ])
    func asGitHubReadsIt(text: String, tables: [[Int]]) {
        #expect(shape(text) == tables, "\(text)")
        #expect(bytes(TableDocument(parsing: text).markdown) == bytes(text))
    }

    // MARK: the writer never makes a row GitHub doesn't read

    /// An emptied one-column row with one outer pipe would be a lone `|`: written with both pipes instead.
    @Test func anEmptiedCellIsNoLonePipe() throws {
        let text = "| a\n|--\n| x\n| y\n"
        let out = try edited(text) { try $0.setCell(row: 0, column: 0, to: "") }
        #expect(out == "| a\n|--\n|  |\n| y\n")
        #expect(shape(out) == [[1, 2]])
    }

    @Test func aNewEmptyRowIsNoLonePipe() throws {
        for text in ["| a\n|--\n| x\n", "a |\n--|\nx |\n"] {
            let out = try edited(text) { try $0.insertRow(at: 1) }
            #expect(shape(out) == [[1, 2]], "\(out)")
            #expect(!out.split(separator: "\n").contains("|"), "\(out)")
        }
    }

    /// A header that continues a paragraph can be indented 4 columns; a first body row must not copy that, or it
    /// would be code and the table would end above it.
    @Test func aFirstRowUnderAnIndentedHeaderIsNoCode() throws {
        let text = "intro\n    a | b\n--|--\n"
        let out = try edited(text) { try $0.insertRow(at: 0, texts: ["1", "2"]) }
        #expect(out == "intro\n    a | b\n--|--\n1 | 2\n")
        #expect(TableDocument(parsing: out).tables.first?.rows.map(\.texts) == [["1", "2"]])
    }

    /// A header of only markers right under a paragraph line would be that line's delimiter row on GitHub, and the
    /// table would lose its header. The edited table starts with a blank line instead; nothing before it changes.
    @Test(arguments: ["---", "-", ":-:", "--:"])
    func aHeaderOfMarkersUnderAParagraphKeepsItsTable(text: String) throws {
        let note = "Weekly runs:\n| Week |\n|---|\n| 1 |\n"
        let out = try edited(note) { try $0.setHeader(column: 0, to: text) }
        #expect(out == "Weekly runs:\n\n| \(text) |\n|---|\n| 1 |\n")
        let table = try #require(TableDocument(parsing: out).tables.first)
        #expect(table.headerTexts == [text])
        #expect(table.rows.map(\.texts) == [["1"]])
    }

    @Test func aHeaderOfMarkersUnderAParagraphLosesAnIndentThatWouldBeCode() throws {
        let note = "Weekly runs:\n    a | b\n --|--\n"
        let out = try edited(note) { table in
            try table.setHeader(column: 0, to: "-")
            try table.setHeader(column: 1, to: "-")
        }
        // `- | -` would be a list item, so the header gets both outer pipes too.
        #expect(out == "Weekly runs:\n\n | - | - |\n --|--\n")
        #expect(TableDocument(parsing: out).tables.first?.headerTexts == ["-", "-"])
    }

    /// Away from a paragraph, such a header is fine as it is, and nothing is added.
    @Test func aHeaderOfMarkersAfterABlankLineStaysPut() throws {
        let note = "Weekly runs:\n\n| Week |\n|---|\n"
        let out = try edited(note) { try $0.setHeader(column: 0, to: "---") }
        #expect(out == "Weekly runs:\n\n| --- |\n|---|\n")
        #expect(TableDocument(parsing: out).tables.first?.headerTexts == ["---"])
    }

    /// An edit to a table inside a list item keeps every row in the item.
    @Test func aTableInAListItemStaysInIt() throws {
        let text = "- item\n\n    | a | b |\n    |---|---|\n    | 1 | 2 |\n"
        let out = try edited(text) { table in
            try table.setCell(row: 0, column: 1, to: "two")
            try table.insertRow(at: 1, texts: ["3", "4"])
        }
        #expect(out == "- item\n\n    | a | b |\n    |---|---|\n    | 1 | two |\n    | 3 | 4 |\n")
        #expect(TableDocument(parsing: out).tables.first?.rows.map(\.texts) == [["1", "two"], ["3", "4"]])
    }
}
