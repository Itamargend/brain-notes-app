import Testing
@testable import BrainNotesTables

/// The running log fixture: front matter, a five-column log with aligned padding, Hebrew notes, an escaped pipe, a pipe
/// escaped inside code, an empty cell, a row with no closing pipe, a short row, a second table in Hebrew with no outer
/// pipes, a table-shaped block in a fence and one in indented code, and no line break at the end.
@Suite struct RunningLogTests {
    private static let logLines = [
        "| date       | distance km |    time | pace | notes                         |",
        "|:-----------|------------:|--------:|:----:|-------------------------------|",
        "| 2026-09-01 |        5.20 | 0:27:44 | 5:20 | easy, legs heavy              |",
        "| 2026-09-03 |       10.00 | 0:52:10 | 5:13 | ריצה טובה בפארק הירקון        |",
        "| 2026-09-05 |        3.10 | 0:14:30 | 4:41 | intervals 6x400 \\| hot        |",
        "| 2026-09-07 |       21.10 | 1:58:02 | 5:35 | חצי מרתון, שיא אישי! PB `5\\|35` |",
        "| 2026-09-09 |        6.00 | 0:33:00 | 5:30 |                               |",
        "| 2026-09-11 |        8.40 | 0:44:06 | 5:15 | שיעול קל, recovery run",
        "| 2026-09-12 | 4.00 |",
    ]
    private static let logTable = logLines.map { $0 + "\n" }.joined()
    private static let weeklyTable = "שבוע | ק\"מ | הערות\n:---: | ---: | ---\n36 | 39.50 | שבוע טוב\n37 | 18.40 | taper 🏃\n"

    /// The fixture after `change` to table `index`, which must equal the fixture with `old` replaced by `new` (by bytes).
    private func expectChange(table index: Int = 0, _ old: String, _ new: String, sourceLocation: SourceLocation = #_sourceLocation,
                              _ change: (inout MarkdownTable) throws -> Void) throws {
        let log = try runningLog()
        let want = try #require(replacingFirst(old, with: new, in: log), "fixture lacks \(old)", sourceLocation: sourceLocation)
        let got = try edited(log, table: index, change)
        #expect(bytes(got) == bytes(want), sourceLocation: sourceLocation)
    }

    // MARK: reading

    @Test func roundTripsByteForByte() throws {
        let log = try runningLog()
        #expect(bytes(TableDocument(parsing: log).markdown) == bytes(log))
        #expect(bytes(log).last == UInt8(ascii: "."), "the fixture ends without a line break")
    }

    @Test(arguments: ["\r\n", "\r"])
    func roundTripsWithOtherLineEndings(eol: String) throws {
        let original = try runningLog()
        let log = String(decoding: bytes(original).flatMap { (b: UInt8) -> [UInt8] in b == 0x0A ? Array(eol.utf8) : [b] }, as: UTF8.self)
        let doc = TableDocument(parsing: log)
        #expect(doc.tables.count == 2)
        #expect(doc.tables.first?.header.lineEnding == eol)
        #expect(bytes(doc.markdown) == bytes(log))
    }

    @Test func findsBothTablesAndNothingElse() throws {
        let doc = TableDocument(parsing: try runningLog())
        #expect(doc.tables.count == 2)
        #expect(bytes(doc.tables[0].source) == bytes(Self.logTable))
        #expect(bytes(doc.tables[1].source) == bytes(Self.weeklyTable))
    }

    @Test func theLogTable() throws {
        let table = try #require(TableDocument(parsing: try runningLog()).tables.first)
        #expect(table.headerTexts == ["date", "distance km", "time", "pace", "notes"])
        #expect(table.alignments == [.left, .right, .right, .center, .none])
        #expect(!table.isRightToLeft)
        #expect(table.rows.count == 7)
        #expect(table.rows[0].texts == ["2026-09-01", "5.20", "0:27:44", "5:20", "easy, legs heavy"])
        #expect(table.text(row: 1, column: 4) == "ריצה טובה בפארק הירקון")
        #expect(table.rows[1].cells[4].isRightToLeft)
        #expect(table.text(row: 2, column: 4) == "intervals 6x400 | hot")
        #expect(table.text(row: 3, column: 4) == "חצי מרתון, שיא אישי! PB `5|35`")
        #expect(table.text(row: 4, column: 4) == "")
        #expect(!table.rows[5].trailingPipe)
        #expect(table.text(row: 5, column: 4) == "שיעול קל, recovery run")
        #expect(table.rows[6].cells.count == 2)
        #expect(table.text(row: 6, column: 4) == "")
        // Padding is kept, not part of the text.
        #expect(table.rows[0].cells[1].leading == "        ")
        #expect(table.rows[0].cells[4].trailing == "              ")
    }

    @Test func theHebrewTable() throws {
        let table = TableDocument(parsing: try runningLog()).tables[1]
        #expect(table.isRightToLeft)
        #expect(table.headerTexts == ["שבוע", "ק\"מ", "הערות"])
        #expect(table.alignments == [.center, .right, .none])
        #expect(!table.header.leadingPipe && !table.header.trailingPipe)
        #expect(table.rows.map(\.texts) == [["36", "39.50", "שבוע טוב"], ["37", "18.40", "taper 🏃"]])
        #expect(table.rows[1].cells.map(\.isRightToLeft) == [false, false, false])
    }

    // MARK: editing: only the changed lines change

    @Test func editANote() throws {
        try expectChange(
            "| 5:13 | ריצה טובה בפארק הירקון        |",
            "| 5:13 | ריצה טובה, 10K        |"
        ) { try $0.setCell(row: 1, column: 4, to: "ריצה טובה, 10K") }
    }

    @Test func fillAShortRow() throws {
        try expectChange("| 2026-09-12 | 4.00 |\n", "| 2026-09-12 | 4.00 | | | קצר |\n") {
            try $0.setCell(row: 6, column: 4, to: "קצר")
        }
    }

    @Test func addARun() throws {
        try expectChange(
            "| 2026-09-12 | 4.00 |\n",
            "| 2026-09-12 | 4.00 |\n| 2026-09-14 | 12.00 | 1:03:00 | 5:15 | long run בשבת |\n"
        ) { try $0.insertRow(at: 7, texts: ["2026-09-14", "12.00", "1:03:00", "5:15", "long run בשבת"]) }
    }

    @Test func removeARun() throws {
        try expectChange(Self.logLines[7] + "\n", "") { try $0.removeRow(at: 5) }
    }

    @Test func alignTheNotesLeftKeepingTheWidth() throws {
        try expectChange(
            ":----:|-------------------------------|\n",
            ":----:|:------------------------------|\n"
        ) { try $0.setAlignment(.left, column: 4) }
    }

    @Test func addAHeartRateColumn() throws {
        let after = [
            "| date       | distance km |    time | pace | HR | notes                         |",
            "|:-----------|------------:|--------:|:----:|--:|-------------------------------|",
            "| 2026-09-01 |        5.20 | 0:27:44 | 5:20 | | easy, legs heavy              |",
            "| 2026-09-03 |       10.00 | 0:52:10 | 5:13 | | ריצה טובה בפארק הירקון        |",
            "| 2026-09-05 |        3.10 | 0:14:30 | 4:41 | | intervals 6x400 \\| hot        |",
            "| 2026-09-07 |       21.10 | 1:58:02 | 5:35 | | חצי מרתון, שיא אישי! PB `5\\|35` |",
            "| 2026-09-09 |        6.00 | 0:33:00 | 5:30 | |                               |",
            "| 2026-09-11 |        8.40 | 0:44:06 | 5:15 | | שיעול קל, recovery run",
            "| 2026-09-12 | 4.00 |", // too short to reach the new column, so untouched
        ].map { $0 + "\n" }.joined()
        try expectChange(Self.logTable, after) { try $0.insertColumn(at: 4, header: "HR", alignment: .right) }
    }

    @Test func dropTheDistanceColumn() throws {
        let after = [
            "| date       |    time | pace | notes                         |",
            "|:-----------|--------:|:----:|-------------------------------|",
            "| 2026-09-01 | 0:27:44 | 5:20 | easy, legs heavy              |",
            "| 2026-09-03 | 0:52:10 | 5:13 | ריצה טובה בפארק הירקון        |",
            "| 2026-09-05 | 0:14:30 | 4:41 | intervals 6x400 \\| hot        |",
            "| 2026-09-07 | 1:58:02 | 5:35 | חצי מרתון, שיא אישי! PB `5\\|35` |",
            "| 2026-09-09 | 0:33:00 | 5:30 |                               |",
            "| 2026-09-11 | 0:44:06 | 5:15 | שיעול קל, recovery run",
            "| 2026-09-12 |",
        ].map { $0 + "\n" }.joined()
        try expectChange(Self.logTable, after) { try $0.removeColumn(at: 1) }
    }

    @Test func editTheHebrewTable() throws {
        try expectChange(table: 1, "37 | 18.40 | taper 🏃\n", "37 | 18.40 | taper \\| מנוחה\n") {
            try $0.setCell(row: 1, column: 2, to: "taper | מנוחה")
        }
        try expectChange(table: 1, "37 | 18.40 | taper 🏃\n", "37 | 18.40 | taper 🏃\n38 | 42.00 | שבוע עמוס\n") {
            try $0.insertRow(at: 2, texts: ["38", "42.00", "שבוע עמוס"])
        }
        // A new empty first cell in a row with no outer pipes needs them, or the row would start with one.
        let after = "שנה | שבוע | ק\"מ | הערות\n:-: | :---: | ---: | ---\n| | 36 | 39.50 | שבוע טוב |\n| | 37 | 18.40 | taper 🏃 |\n"
        try expectChange(table: 1, Self.weeklyTable, after) { try $0.insertColumn(at: 0, header: "שנה", alignment: .center) }
    }

    /// Any one cell edit changes exactly one line of the file, and every other byte stays.
    @Test func everyCellEditChangesOneLine() throws {
        let log = try runningLog()
        let lines = Self.lines(log)
        let table = try #require(TableDocument(parsing: log).tables.first)
        for row in -1..<table.rows.count {
            for column in 0..<table.columnCount {
                let got = try edited(log) { t in
                    if row < 0 { try t.setHeader(column: column, to: "חדש new") } else { try t.setCell(row: row, column: column, to: "חדש new") }
                }
                let changed = zip(lines, Self.lines(got)).filter { !$0.0.elementsEqual($0.1) }
                #expect(Self.lines(got).count == lines.count, "row \(row) column \(column)")
                #expect(changed.count == 1, "row \(row) column \(column): \(changed.count) lines changed")
            }
        }
    }

    @Test func editingOneTableLeavesTheOtherAndAllTextAlone() throws {
        let log = try runningLog()
        var doc = TableDocument(parsing: log)
        let before = doc.pieces
        try doc.updateTable(at: 1) { try $0.setCell(row: 0, column: 0, to: "35") }
        #expect(doc.pieces.count == before.count)
        for (k, (old, new)) in zip(before, doc.pieces).enumerated() where k != 3 {
            #expect(bytes(old.markdown) == bytes(new.markdown), "piece \(k)")
        }
        #expect(doc.tables[0] == TableDocument(parsing: log).tables[0])
    }

    private static func lines(_ s: String) -> [[UInt8]] {
        bytes(s).split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
    }
}
