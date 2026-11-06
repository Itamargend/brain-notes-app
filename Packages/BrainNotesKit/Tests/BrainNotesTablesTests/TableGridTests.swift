import Testing
@testable import BrainNotesTables

/// The table as the editor's grid sees it: row 0 is the header, and there are as many columns as the widest row needs.
/// Golden tests take the exact bytes after each edit. A line the edit has no reason to touch keeps its bytes.
@Suite struct TableGridTests {
    private let small = "| a | b |\n|---|:-:|\n| 1 | 2 |\n"
    private let ragged = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |\n"

    private func expectGridEdit(_ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation,
                                _ change: (inout MarkdownTable) throws -> Void) throws {
        let got = try edited(before, change)
        #expect(bytes(got) == bytes(after), "\(before.debugDescription) gave \(got.debugDescription)", sourceLocation: sourceLocation)
        // What was written reads back as the model says.
        var model = try #require(MarkdownTable(parsing: before), sourceLocation: sourceLocation)
        try change(&model)
        let reread = try #require(MarkdownTable(parsing: got), sourceLocation: sourceLocation)
        #expect(reread.gridRowCount == model.gridRowCount, sourceLocation: sourceLocation)
        #expect(reread.gridColumnCount == model.gridColumnCount, sourceLocation: sourceLocation)
        for r in 0..<reread.gridRowCount {
            for c in 0..<reread.gridColumnCount {
                #expect(reread.gridText(row: r, column: c) == model.gridText(row: r, column: c), sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: reading

    @Test func theGridCountsTheHeaderAsARow() throws {
        let table = try #require(MarkdownTable(parsing: small))
        #expect(table.gridRowCount == 2)
        #expect(table.gridColumnCount == 2)
        #expect(table.gridText(row: 0, column: 0) == "a")
        #expect(table.gridText(row: 1, column: 1) == "2")
        #expect(table.gridAlignment(column: 1) == .center)
        #expect(table.isRectangular)
    }

    @Test func outsideTheGridIsEmpty() throws {
        let table = try #require(MarkdownTable(parsing: small))
        #expect(table.gridText(row: 5, column: 0) == "")
        #expect(table.gridText(row: 0, column: 9) == "")
        #expect(table.gridText(row: 1, column: -1) == "")
        #expect(table.gridAlignment(column: 9) == .none)
    }

    @Test func aRowWiderThanTheHeaderWidensTheGridSoNoTextIsUnseen() throws {
        let table = try #require(MarkdownTable(parsing: ragged))
        #expect(table.columnCount == 3, "as GitHub reads it")
        #expect(table.gridColumnCount == 4, "as the grid shows it")
        #expect(table.gridText(row: 2, column: 3) == "4")
        #expect(table.gridText(row: 1, column: 1) == "", "a short row's missing cells read as empty")
        #expect(table.gridText(row: 0, column: 3) == "", "no header for that column yet")
        #expect(!table.isRectangular)
    }

    @Test func anUnescapedPipeInACellIsWhatMakesThatColumn() throws {
        let table = try #require(MarkdownTable(parsing: "| cmd | what |\n|---|---|\n| a|b | or |\n"))
        #expect(table.gridColumnCount == 3)
        #expect((0..<3).map { table.gridText(row: 1, column: $0) } == ["a", "b", "or"], "all of it is on screen")
    }

    // MARK: normalizing

    @Test func normalizingAWellFormedTableChangesNothing() throws {
        for text in [small, "| x   | y |\n| :-- | --: |\n| 1   | 2 |", "a | b\n--- | ---\n1 | 2\n"] {
            var table = try #require(MarkdownTable(parsing: text))
            table.normalizeShape()
            #expect(!table.isEdited)
            #expect(bytes(table.markdown) == bytes(text))
        }
    }

    @Test func normalizingEvensOutARaggedTableAndLosesNoText() throws {
        try expectGridEdit(ragged, "| a | b | c | |\n|---|---|---|---|\n| 1 | | | |\n| 1 | 2 | 3 | 4 |\n") { $0.normalizeShape() }
        var table = try #require(MarkdownTable(parsing: ragged))
        table.normalizeShape()
        #expect(table.isRectangular)
        // What GitHub ignored before is a real column now.
        let reread = try #require(MarkdownTable(parsing: table.markdown))
        #expect(reread.columnCount == 4)
        #expect(reread.text(row: 1, column: 3) == "4")
    }

    @Test func aShortRowOfATableWithoutOuterPipesStaysAReadableRow() throws {
        let text = "a | b\n--- | ---\n1\n2 | 3\n"
        var table = try #require(MarkdownTable(parsing: text))
        table.normalizeShape()
        let reread = try #require(MarkdownTable(parsing: table.markdown))
        #expect(reread.isRectangular)
        #expect(reread.rows.map(\.texts) == [["1", ""], ["2", "3"]])
    }

    @Test func aRowThatIsAlreadyRightKeepsItsBytesWhenAnotherIsEvened() throws {
        let text = "| a  |  b  |\n|--|--|\n|  1  |   2   |\n| 3 |\n"
        let got = try edited(text) { $0.normalizeShape() }
        #expect(got.contains("|  1  |   2   |\n"))
        #expect(got.hasPrefix("| a  |  b  |\n|--|--|\n"))
    }

    // MARK: cells

    @Test func settingACellWritesOnlyItsLine() throws {
        try expectGridEdit(small, "| A | b |\n|---|:-:|\n| 1 | 2 |\n") { try $0.setGridText(row: 0, column: 0, to: "A") }
        try expectGridEdit(small, "| a | b |\n|---|:-:|\n| 1 | two |\n") { try $0.setGridText(row: 1, column: 1, to: "two") }
    }

    @Test func aWideTableKeepsItsPaddingOnTheLinesAnEditDoesNotTouch() throws {
        let aligned = "| Date  | Pace |\n|-------|------|\n| 1 Nov | 5:41 |\n| 3 Nov | 5:55 |\n"
        let got = try edited(aligned) { try $0.setGridText(row: 2, column: 1, to: "5:50") }
        #expect(got == "| Date  | Pace |\n|-------|------|\n| 1 Nov | 5:41 |\n| 3 Nov | 5:50 |\n")
    }

    @Test func aPipeInACellIsEscapedInTheFileAndAPipeOnScreen() throws {
        try expectGridEdit(small, "| a | b |\n|---|:-:|\n| x\\|y | 2 |\n") { try $0.setGridText(row: 1, column: 0, to: "x|y") }
        var table = try #require(MarkdownTable(parsing: small))
        try table.setGridText(row: 1, column: 0, to: "x|y")
        #expect(table.gridText(row: 1, column: 0) == "x|y")
        let reread = try #require(MarkdownTable(parsing: table.markdown))
        #expect(reread.gridColumnCount == 2, "the pipe made no new column")
        #expect(reread.gridText(row: 1, column: 0) == "x|y")
    }

    @Test func aCellIsOneLineWithNoSpacesAtItsEnds() throws {
        try expectGridEdit(small, "| a | b |\n|---|:-:|\n| x y | 2 |\n") { try $0.setGridText(row: 1, column: 0, to: "  x\ny  ") }
        #expect(MarkdownTable.cellText(forTyped: "  x\r\ny  ") == "x y")
        #expect(MarkdownTable.cellText(forTyped: "a|b") == "a|b")
        #expect(MarkdownTable.cellText(forTyped: "   ") == "")
        for separator in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            #expect(MarkdownTable.cellText(forTyped: "a\(separator)b") == "a b", "\(separator.debugDescription)")
        }
        // What is left has no line break a text view knows of.
        let flat = MarkdownTable.cellText(forTyped: "a\u{2028}b\u{85}c\u{0B}d")
        #expect(flat == "a b c d")
    }

    @Test func typingTheSameTextChangesNothing() throws {
        var table = try #require(MarkdownTable(parsing: small))
        try table.setGridText(row: 1, column: 0, to: "1 ")
        #expect(!table.isEdited)
        #expect(bytes(table.markdown) == bytes(small))
    }

    @Test func aCellPastTheHeaderBecomesARealColumnWhenEdited() throws {
        try expectGridEdit(ragged, "| a | b | c | |\n|---|---|---|---|\n| 1 | | | |\n| 1 | 2 | 3 | four |\n") {
            try $0.setGridText(row: 2, column: 3, to: "four")
        }
    }

    @Test func aMissingCellOfAShortRowCanBeFilled() throws {
        try expectGridEdit(ragged, "| a | b | c | |\n|---|---|---|---|\n| 1 | | x | |\n| 1 | 2 | 3 | 4 |\n") {
            try $0.setGridText(row: 1, column: 2, to: "x")
        }
    }

    @Test func hebrewCellsStayWhole() throws {
        let text = "| פריט | עלות |\n|---|---|\n| לינה | 900 |\n"
        try expectGridEdit(text, "| פריט | עלות |\n|---|---|\n| לינה | תשע מאות 🏕️ |\n") {
            try $0.setGridText(row: 1, column: 1, to: "תשע מאות 🏕️")
        }
    }

    // MARK: rows

    @Test func addingRowsAnywhereBelowTheHeader() throws {
        try expectGridEdit(small, "| a | b |\n|---|:-:|\n| 1 | 2 |\n| | |\n") { try $0.insertGridRow(at: 2) }
        try expectGridEdit(small, "| a | b |\n|---|:-:|\n| | |\n| 1 | 2 |\n") { try $0.insertGridRow(at: 1) }
    }

    @Test func aRowAboveTheHeaderMovesTheHeaderDown() throws {
        try expectGridEdit(small, "|  |  |\n|---|:-:|\n| a | b |\n| 1 | 2 |\n") { try $0.insertGridRow(at: 0) }
    }

    @Test func aNewRowOfARaggedTableIsNotRagged() throws {
        var table = try #require(MarkdownTable(parsing: ragged))
        try table.insertGridRow(at: 3)
        #expect(table.isRectangular)
        #expect(table.rows.count == 3)
    }

    @Test func deletingARowTakesItsLine() throws {
        try expectGridEdit("| a |\n|---|\n| 1 |\n| 2 |\n", "| a |\n|---|\n| 2 |\n") { try $0.removeGridRow(at: 1) }
        try expectGridEdit("| a |\n|---|\n| 1 |\n| 2 |", "| a |\n|---|\n| 1 |") { try $0.removeGridRow(at: 2) }
    }

    @Test func deletingTheHeaderPromotesTheFirstRow() throws {
        try expectGridEdit("| a | b |\n|---|:-:|\n| 1 | x\\|y |\n| 3 | 4 |\n", "| 1 | x\\|y |\n|---|:-:|\n| 3 | 4 |\n") { try $0.removeGridRow(at: 0) }
    }

    @Test func deletingTheHeaderKeepsCellsPastItsColumns() throws {
        // The row that becomes the header had four cells: all four are still there.
        var table = try #require(MarkdownTable(parsing: "| a | b |\n|---|---|\n| 1 | 2 | 3 | 4 |\n| x | y |\n"))
        try table.removeGridRow(at: 0)
        let reread = try #require(MarkdownTable(parsing: table.markdown))
        #expect(reread.headerTexts == ["1", "2", "3", "4"])
        #expect(reread.rows.map(\.texts) == [["x", "y", "", ""]])
    }

    @Test func theLastRowCantGo() throws {
        var table = try #require(MarkdownTable(parsing: "| a |\n|---|\n"))
        #expect(throws: MarkdownTable.EditError.lastRow) { try table.removeGridRow(at: 0) }
        #expect(!table.isEdited)
    }

    @Test func rowsKeepTheNotesLineEndings() throws {
        try expectGridEdit("| a |\r\n|---|\r\n| 1 |\r\n", "| a |\r\n|---|\r\n| 1 |\r\n| |\r\n") { try $0.insertGridRow(at: 2) }
        try expectGridEdit("| a |\r\n|---|\r\n| 1 |", "| a |\r\n|---|\r\n| 1 |\r\n| |") { try $0.insertGridRow(at: 2) }
    }

    // MARK: columns

    @Test func addingColumnsAnywhere() throws {
        try expectGridEdit(small, "| | a | b |\n|---|---|:-:|\n| | 1 | 2 |\n") { try $0.insertGridColumn(at: 0) }
        try expectGridEdit(small, "| a | | b |\n|---|---|:-:|\n| 1 | | 2 |\n") { try $0.insertGridColumn(at: 1) }
        try expectGridEdit(small, "| a | b | |\n|---|:-:|---|\n| 1 | 2 | |\n") { try $0.insertGridColumn(at: 2) }
    }

    @Test func deletingAColumnTakesItEverywhereAndKeepsTheOtherAlignments() throws {
        try expectGridEdit(small, "| b |\n|:-:|\n| 2 |\n") { try $0.removeGridColumn(at: 0) }
        try expectGridEdit(small, "| a |\n|---|\n| 1 |\n") { try $0.removeGridColumn(at: 1) }
    }

    @Test func theLastColumnCantGo() throws {
        var table = try #require(MarkdownTable(parsing: "| a |\n|---|\n| 1 |\n"))
        #expect(throws: MarkdownTable.EditError.lastColumn) { try table.removeGridColumn(at: 0) }
    }

    @Test func aColumnOfARaggedTableIsAColumnOfEveryRow() throws {
        var table = try #require(MarkdownTable(parsing: ragged))
        try table.insertGridColumn(at: 1)
        #expect(table.isRectangular)
        #expect(table.gridColumnCount == 5)
        #expect(table.gridText(row: 2, column: 4) == "4")
        try table.removeGridColumn(at: 1)
        #expect(table.gridColumnCount == 4)
        #expect(table.gridText(row: 2, column: 3) == "4")
    }

    @Test func badPositionsAreRefused() throws {
        var table = try #require(MarkdownTable(parsing: small))
        #expect(throws: MarkdownTable.EditError.noSuchRow(2)) { try table.setGridText(row: 2, column: 0, to: "x") }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(2)) { try table.setGridText(row: 0, column: 2, to: "x") }
        #expect(throws: MarkdownTable.EditError.noSuchRow(3)) { try table.insertGridRow(at: 3) }
        #expect(throws: MarkdownTable.EditError.noSuchRow(2)) { try table.removeGridRow(at: 2) }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(3)) { try table.insertGridColumn(at: 3) }
        #expect(throws: MarkdownTable.EditError.noSuchColumn(2)) { try table.removeGridColumn(at: 2) }
        #expect(bytes(table.markdown) == bytes(small))
    }

    // MARK: direction

    @Test func aTableIsAsRightToLeftAsItsTextSays() throws {
        func stated(_ text: String) throws -> Bool? { try #require(MarkdownTable(parsing: text)).statedRightToLeft }
        #expect(try stated("| פריט | a |\n|---|---|\n") == true)
        #expect(try stated("| a | פריט |\n|---|---|\n") == false)
        #expect(try stated("|  |  |\n|---|---|\n| לינה |  |\n") == true, "an empty header goes by the body")
        #expect(try stated("| 12 | 3 |\n|---|---|\n| לינה | a |\n") == true, "digits say nothing")
        #expect(try stated("|  |  |\n|---|---|\n|  |  |\n") == nil, "no text, no direction")
        #expect(try stated("| \u{200F}a |\n|---|\n") == true, "a mark in the header says so")
    }

    @Test func aCellHasItsOwnDirection() {
        #expect(MarkdownTable.statedRightToLeft(ofText: "שלום") == true)
        #expect(MarkdownTable.statedRightToLeft(ofText: "hello") == false)
        #expect(MarkdownTable.statedRightToLeft(ofText: "5.2") == nil)
        #expect(MarkdownTable.statedRightToLeft(ofText: "") == nil)
    }

    @Test func aRightToLeftTableRoundTripsAndEditsLikeAnyOther() throws {
        let text = "| פריט | עלות | הערות |\n|---|---|---|\n| לינה | 900 | שני לילות |\n"
        #expect(bytes(TableDocument(parsing: text).markdown) == bytes(text))
        try expectGridEdit(text, "| פריט | עלות | | הערות |\n|---|---|---|---|\n| לינה | 900 | | שני לילות |\n") { try $0.insertGridColumn(at: 2) }
        try expectGridEdit(text, "| פריט | עלות | הערות |\n|---|---|---|\n| לינה | 900 | שני לילות |\n| | | |\n") { try $0.insertGridRow(at: 2) }
    }

    // MARK: new tables

    @Test func aBlankTableIsATable() throws {
        let text = MarkdownTable.blankMarkdown(columns: 3, rows: 3)
        #expect(text == "|   |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |")
        let table = try #require(MarkdownTable(parsing: text))
        #expect(table.gridRowCount == 3)
        #expect(table.gridColumnCount == 3)
        #expect(table.isRectangular)
        #expect(table.statedRightToLeft == nil)
        #expect(MarkdownTable.blankMarkdown(columns: 2, rows: 2, lineEnding: "\r\n") == "|   |   |\r\n|---|---|\r\n|   |   |")
    }

    @Test func fillingABlankTableGivesTidyLines() throws {
        let text = MarkdownTable.blankMarkdown(columns: 2, rows: 2) + "\n"
        let got = try edited(text) {
            try $0.setGridText(row: 0, column: 0, to: "Name")
            try $0.setGridText(row: 1, column: 1, to: "3")
        }
        #expect(got == "| Name |   |\n|---|---|\n|   | 3 |\n")
    }

    // MARK: what isn't a table

    @Test func malformedTablesStayText() {
        for text in ["| a | b |\n|---|\n| 1 | 2 |\n", "| a |\n| b |\n", "|---|---|\n", "| a | b |\n", "a | b\n--- ---\n", "```\n| a |\n|---|\n```\n"] {
            let doc = TableDocument(parsing: text)
            #expect(doc.tables.isEmpty, "\(text.debugDescription)")
            #expect(bytes(doc.markdown) == bytes(text), "no text is lost")
        }
    }

    @Test func textAroundAMalformedRowIsKept() throws {
        let text = "| a |\n|---|\n| 1 |\n|\nafter\n"
        let doc = TableDocument(parsing: text)
        #expect(doc.tables.count == 1)
        #expect(doc.tables[0].rows.count == 1, "a lone pipe ends the table")
        #expect(bytes(doc.markdown) == bytes(text))
    }

    // MARK: anything goes

    /// Random grid edits to tables of every shape: every byte around the table stays, the result reads back as the model,
    /// no table appears or goes, and no cell's text is lost unless its row or column was deleted.
    @Test(arguments: [0, 1, 2, 3] as [UInt64])
    func randomGridEditsReadBackAsTheyShould(seed: UInt64) throws {
        var r = SeededRandom(seed: seed &+ 7000)
        var checked = 0
        for n in 0..<400 {
            let note = RandomNotes.note(&r)
            var doc = TableDocument(parsing: note)
            guard !doc.tables.isEmpty else { continue }
            let index = r.int(doc.tables.count)
            let range = doc.utf16Range(ofTable: index)
            let units = Array(note.utf16)
            var log: [String] = []
            try doc.updateTable(at: index) { table in
                for _ in 0..<(1 + r.int(5)) { log.append(Self.randomEdit(&table, &r)) }
            }
            let context = "seed \(seed) note \(n): \(log)"
            let out = Array(doc.markdown.utf16)
            let tail = units.count - range.upperBound
            #expect(out[..<range.lowerBound].elementsEqual(units[..<range.lowerBound]), "\(context)")
            #expect(out[(out.count - tail)...].elementsEqual(units[range.upperBound...]), "\(context)")
            let again = TableDocument(parsing: doc.markdown)
            #expect(again.tables.count == doc.tables.count, "\(context)")
            guard again.tables.indices.contains(index) else { continue }
            let model = doc.tables[index], reread = again.tables[index]
            #expect(reread.gridRowCount == model.gridRowCount, "\(context)")
            #expect(reread.gridColumnCount == model.gridColumnCount, "\(context)")
            for row in 0..<reread.gridRowCount {
                for column in 0..<reread.gridColumnCount {
                    #expect(reread.gridText(row: row, column: column) == model.gridText(row: row, column: column), "\(context)")
                }
            }
            checked += 1
        }
        #expect(checked > 50)
    }

    private static func randomEdit(_ table: inout MarkdownTable, _ r: inout SeededRandom) -> String {
        let row = r.int(table.gridRowCount), column = r.int(table.gridColumnCount)
        do {
            switch r.int(6) {
            case 0:
                let text = RandomNotes.cellText(&r)
                try table.setGridText(row: row, column: column, to: text)
                return "set \(row).\(column) \(text.debugDescription)"
            case 1:
                try table.insertGridRow(at: r.int(table.gridRowCount + 1))
                return "row+"
            case 2:
                if table.gridRowCount > 1 { try table.removeGridRow(at: row) }
                return "row- \(row)"
            case 3:
                try table.insertGridColumn(at: r.int(table.gridColumnCount + 1))
                return "col+"
            case 4:
                if table.gridColumnCount > 1 { try table.removeGridColumn(at: column) }
                return "col- \(column)"
            default:
                table.normalizeShape()
                return "normalize"
            }
        } catch {
            Issue.record("\(error)")
            return "failed"
        }
    }
}
