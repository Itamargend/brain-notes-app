import Testing
@testable import BrainNotesTables

let tableSeeds: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7]

/// Property tests over seeded random notes. A failing seed is printed, and replays the same note and edits.
@Suite struct TableRoundTripTests {
    static let notesPerSeed = 400

    /// Any note, table-shaped or not, reads and writes back byte for byte.
    @Test(arguments: tableSeeds)
    func everyNoteRoundTrips(seed: UInt64) {
        var r = SeededRandom(seed: seed)
        for n in 0..<Self.notesPerSeed {
            let note = RandomNotes.note(&r)
            let doc = TableDocument(parsing: note)
            #expect(bytes(doc.markdown) == bytes(note), "seed \(seed) note \(n)")
            // Each piece is a cut of the note, and an unedited table is its source.
            for piece in doc.pieces {
                if case .table(let t) = piece { #expect(!t.isEdited && t.rows.allSatisfy(\.isUntouched)) }
            }
        }
    }

    /// Random edits to one table: every byte before and after it stays, the table reads back as the model says, and
    /// the note still has as many tables.
    @Test(arguments: tableSeeds)
    func randomEditsStayInsideTheirTable(seed: UInt64) throws {
        var r = SeededRandom(seed: seed &+ 1000)
        var checked = 0
        for n in 0..<Self.notesPerSeed {
            let note = RandomNotes.note(&r)
            var doc = TableDocument(parsing: note)
            guard !doc.tables.isEmpty else { continue }
            let index = r.int(doc.tables.count)
            let range = doc.utf16Range(ofTable: index)
            let units = Array(note.utf16)
            var log: [String] = []
            try doc.updateTable(at: index) { table in
                for _ in 0..<(1 + r.int(6)) { log.append(Self.randomEdit(&table, &r)) }
            }
            let out = doc.markdown
            let outUnits = Array(out.utf16)
            let context = "seed \(seed) note \(n): \(log)"

            // Every byte before and after the table is the same.
            let tail = units.count - range.upperBound
            #expect(outUnits.count >= range.lowerBound + tail, "\(context)")
            guard outUnits.count >= range.lowerBound + tail else { continue }
            #expect(outUnits[..<range.lowerBound].elementsEqual(units[..<range.lowerBound]), "\(context)")
            #expect(outUnits[(outUnits.count - tail)...].elementsEqual(units[range.upperBound...]), "\(context)")

            // The new note reads back as the edited table, with every other table as it was.
            let table = doc.tables[index]
            if table.headerLooksLikeDelimiter { continue } // see the plan doc: such a header can join the line above
            let again = TableDocument(parsing: out)
            #expect(again.tables.count == doc.tables.count, "\(context)")
            guard again.tables.count == doc.tables.count else { continue }
            #expect(again.tables[index].shown == table.shown, "\(context)")
            for k in doc.tables.indices where k != index {
                #expect(bytes(again.tables[k].source) == bytes(doc.tables[k].source), "\(context)")
            }
            checked += 1
        }
        #expect(checked > Self.notesPerSeed / 8, "seed \(seed): too few notes had tables")
    }

    /// Writing a text and reading it back gives the text, with line breaks as spaces and the ends trimmed.
    @Test(arguments: tableSeeds)
    func cellTextRoundTrips(seed: UInt64) throws {
        var r = SeededRandom(seed: seed &+ 2000)
        let pieces = ["a", "|", "\\", " ", "ש", "`", "\t", "\n", "\r\n", "\u{200F}", "🏃", ":", "-"]
        for _ in 0..<500 {
            var text = ""
            for _ in 0..<r.int(10) { text += r.pick(pieces) }
            var table = try #require(MarkdownTable(parsing: "| a | b |\n|---|---|\n| 1 | 2 |\n"))
            let column = r.int(2)
            try table.setCell(row: 0, column: column, to: text)
            let expected = TableSyntax.escape(text) // also checked below as the inverse of unescape
            #expect(bytes(table.rows[0].cells[column].raw) == bytes(expected))
            let reread = try #require(MarkdownTable(parsing: table.markdown), "\(text.debugDescription)")
            #expect(bytes(reread.text(row: 0, column: column)) == bytes(Self.normalized(text)), "\(text.debugDescription)")
            #expect(reread.rows[0].cells.count == 2, "\(text.debugDescription)")
            #expect(bytes(TableSyntax.escape(TableSyntax.unescape(expected))) == bytes(expected))
        }
    }

    // MARK: helpers

    /// One random edit, as a line for the failure message. Refusals are part of the run.
    static func randomEdit(_ table: inout MarkdownTable, _ r: inout SeededRandom) -> String {
        let alignments = MarkdownTable.Alignment.allCases
        let text = RandomNotes.cellText(&r) + r.pick(["", "|z", " ", "\n2"])
        do {
            switch r.int(6) {
            case 0:
                let row = r.int(table.rows.count + 1) - 1
                let column = r.int(table.columnCount + 1)
                if row < 0 { try table.setHeader(column: column, to: text) } else { try table.setCell(row: row, column: column, to: text) }
                return "set \(row) \(column) \(text.debugDescription)"
            case 1:
                let at = r.int(table.rows.count + 1)
                var texts: [String] = []
                for _ in 0..<r.int(table.columnCount + 1) { texts.append(RandomNotes.cellText(&r)) }
                try table.insertRow(at: at, texts: texts)
                return "insertRow \(at) \(texts)"
            case 2:
                let at = r.int(table.rows.count + 1)
                try table.removeRow(at: at)
                return "removeRow \(at)"
            case 3:
                let at = r.int(table.columnCount + 1)
                let alignment = r.pick(alignments)
                try table.insertColumn(at: at, header: text, alignment: alignment)
                return "insertColumn \(at) \(text.debugDescription) \(alignment)"
            case 4:
                let at = r.int(table.columnCount)
                try table.removeColumn(at: at)
                return "removeColumn \(at)"
            default:
                let at = r.int(table.columnCount)
                let alignment = r.pick(alignments)
                try table.setAlignment(alignment, column: at)
                return "align \(at) \(alignment)"
            }
        } catch {
            return "refused: \(error)"
        }
    }

    /// What a cell shows for a typed text: line breaks as spaces, spaces and tabs trimmed from the ends.
    static func normalized(_ text: String) -> String {
        var b: [UInt8] = []
        let input = bytes(text)
        var i = 0
        while i < input.count {
            if input[i] == 0x0D || input[i] == 0x0A {
                b.append(0x20)
                i += input[i] == 0x0D && i + 1 < input.count && input[i + 1] == 0x0A ? 2 : 1
            } else {
                b.append(input[i])
                i += 1
            }
        }
        while let first = b.first, first == 0x20 || first == 0x09 { b.removeFirst() }
        while let last = b.last, last == 0x20 || last == 0x09 { b.removeLast() }
        return String(decoding: b, as: UTF8.self)
    }
}
