import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// What a grid edit, a caret or a keystroke next to a table does to the note's text. A table's source stays in the text,
/// hidden behind its grid, so nothing here may change it by accident.
@Suite struct TableEditsTests {
    private let note = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOutro\n"

    private func span(_ text: String, _ index: Int = 0) throws -> TableEdits.Span {
        let spans = TableEdits.spans(in: text)
        return try #require(spans.indices.contains(index) ? spans[index] : nil)
    }

    private func verdict(_ replacement: String, _ range: NSRange, in text: String) -> TableEdits.TypingVerdict {
        TableEdits.typing(replacement, replacing: range, in: text as NSString, spans: TableEdits.spans(in: text))
    }

    private func offset(of needle: String, in text: String) -> Int { (text as NSString).range(of: needle).location }

    // MARK: finding them

    @Test func spansAreInUTF16AndSkipWhatIsNoTable() throws {
        let text = "🏃 שלום\n\n| a |\n|---|\n\n```\n| x |\n|---|\n```\n\n| b |\n|---|\n"
        let spans = TableEdits.spans(in: text)
        #expect(spans.count == 2, "the one in code is code")
        let ns = text as NSString
        #expect(ns.substring(with: spans[0].range) == "| a |\n|---|\n")
        #expect(ns.substring(with: spans[1].range) == "| b |\n|---|\n")
    }

    @Test func aNoteWithoutMarksIsNotEvenRead() {
        #expect(!TableEdits.mayHoldTable("plain text\n- a list\n# a title: with a colon\n" as NSString))
        #expect(TableEdits.mayHoldTable("| a |" as NSString))
        #expect(TableEdits.mayHoldTable("x\n:-:\n" as NSString), "a delimiter row can do without pipes")
        #expect(TableEdits.mayHoldTable("x\n--:\n" as NSString))
    }

    @Test func aTableWithNoPipesIsFoundThroughTheGate() {
        let text = "x\n:-:\ny\n"
        #expect(TableEdits.mayHoldTable(text as NSString))
        #expect(TableEdits.spans(in: text).count == 1)
    }

    // MARK: grid edits

    @Test func aCellEditIsTheSmallestReplacement() throws {
        let found = try span(note)
        var table = found.table
        try table.setGridText(row: 1, column: 1, to: "two")
        let edit = try #require(TableEdits.edit(of: found, to: table))
        #expect(edit.applied(to: note) == "Intro\n\n| a | b |\n|---|---|\n| 1 | two |\n\nOutro\n")
        #expect(edit.replacement == "two")
        #expect(edit.range.length == 1)
    }

    @Test func noChangeIsNoEdit() throws {
        let found = try span(note)
        var table = found.table
        try table.setGridText(row: 1, column: 1, to: "2")
        #expect(TableEdits.edit(of: found, to: table) == nil)
        #expect(TableEdits.replacing("abc", with: "abc", at: 3) == nil)
    }

    @Test func aReplacementNeverSplitsACharacter() throws {
        let text = "| 🏃 |\n|---|\n"
        let found = try span(text)
        var table = found.table
        try table.setGridText(row: 0, column: 0, to: "🏊")
        let edit = try #require(TableEdits.edit(of: found, to: table))
        #expect(edit.applied(to: text) == "| 🏊 |\n|---|\n")
        #expect(edit.replacement == "🏊", "both halves of the pair")
    }

    @Test func aCRLFNoteStaysCRLFThroughAStructuralEdit() throws {
        let text = "x\r\n\r\n| a |\r\n|---|\r\n| 1 |\r\n\r\ny\r\n"
        let found = try span(text)
        var table = found.table
        try table.insertGridRow(at: 2)
        try table.insertGridColumn(at: 1)
        let edit = try #require(TableEdits.edit(of: found, to: table))
        let after = edit.applied(to: text)
        #expect(!after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(after.debugDescription)")
        #expect(TableEdits.spans(in: after).first?.table.gridRowCount == 3)
        #expect(after.hasSuffix("\r\n\r\ny\r\n"))
    }

    // MARK: deleting a table

    @Test func deletingATableClosesUpWhatIsAroundIt() throws {
        func deleted(_ text: String) throws -> (String, Int) {
            let edit = TableEdits.deletingTable(try span(text), in: text)
            return (edit.applied(to: text), edit.selection.location)
        }
        #expect(try deleted(note) == ("Intro\n\nOutro\n", 7), "one blank line stays")
        #expect(try deleted("| a |\n|---|\n\nOutro\n") == ("Outro\n", 0), "no blank line at the top")
        #expect(try deleted("Intro\n| a |\n|---|\n\nOutro\n") == ("Intro\n\nOutro\n", 6))
        #expect(try deleted("| a |\n|---|\n") == ("", 0))
        #expect(try deleted("Intro\n\n| a |\n|---|") == ("Intro\n\n", 7))
    }

    @Test func aLineAboveATableThatStartsTheNote() throws {
        let text = "| a |\n|---|\n"
        let edit = TableEdits.addingLine(above: try span(text), in: text)
        #expect(edit.applied(to: text) == "\n| a |\n|---|\n")
        #expect(edit.selection.location == 0, "the caret is on the new line, above the table")
        #expect(TableEdits.spans(in: edit.applied(to: text)).count == 1)
    }

    // MARK: the caret

    private let tables = [NSRange(location: 10, length: 20), NSRange(location: 40, length: 10)]

    private func caret(_ location: Int, length: Int = 0, from previous: NSRange? = nil) -> TableEdits.CaretVerdict {
        TableEdits.caret(NSRange(location: location, length: length), previous: previous, tables: tables)
    }

    @Test func aCaretOutsideATableStays() {
        #expect(caret(5) == .stays)
        #expect(caret(9) == .stays)
        #expect(caret(30) == .stays, "the end of a table belongs to what follows")
        #expect(caret(35) == .stays)
    }

    @Test func aCaretArrivingFromAboveGoesIntoTheFirstCell() {
        #expect(caret(10, from: NSRange(location: 9, length: 0)) == .enters(table: 0, atStart: true))
        #expect(caret(12, from: NSRange(location: 5, length: 0)) == .enters(table: 0, atStart: true))
    }

    @Test func aCaretArrivingFromBelowGoesIntoTheLastCell() {
        #expect(caret(29, from: NSRange(location: 30, length: 0)) == .enters(table: 0, atStart: false))
        #expect(caret(45, from: NSRange(location: 55, length: 0)) == .enters(table: 1, atStart: false))
    }

    @Test func aCaretFromNowhereGoesBelowTheTable() {
        #expect(caret(15) == .moves(NSRange(location: 30, length: 0)))
        #expect(caret(10) == .moves(NSRange(location: 30, length: 0)))
        #expect(caret(15, from: NSRange(location: 12, length: 0)) == .moves(NSRange(location: 30, length: 0)), "from inside: out of it")
    }

    @Test func aSelectionTakesATableWhole() {
        // Dragged down into a table: past it.
        #expect(caret(5, length: 10, from: NSRange(location: 5, length: 3)) == .moves(NSRange(location: 5, length: 25)))
        // Dragged back up into it: before it.
        #expect(caret(5, length: 20, from: NSRange(location: 5, length: 25)) == .moves(NSRange(location: 5, length: 5)))
        // Its start, going up: before it.
        #expect(caret(15, length: 20, from: NSRange(location: 35, length: 0)) == .moves(NSRange(location: 10, length: 25)))
        // Its start, coming back down: past it.
        #expect(caret(15, length: 20, from: NSRange(location: 10, length: 25)) == .moves(NSRange(location: 30, length: 5)))
        // Whole already.
        #expect(caret(5, length: 30) == .stays)
        #expect(caret(10, length: 20) == .stays)
        // Two ends in two tables.
        #expect(caret(20, length: 25) == .moves(NSRange(location: 10, length: 40)))
    }

    @Test func aSelectionTouchesATableOnlyIfItHoldsSomeOfIt() {
        #expect(TableEdits.touches(NSRange(location: 5, length: 10), tables: tables))
        #expect(TableEdits.touches(NSRange(location: 12, length: 0), tables: tables), "a caret in one")
        #expect(!TableEdits.touches(NSRange(location: 5, length: 5), tables: tables), "right up to it")
        #expect(!TableEdits.touches(NSRange(location: 30, length: 10), tables: tables), "from its end to the next")
    }

    // MARK: typing next to a table

    @Test func textFarFromATableIsLeftAlone() {
        #expect(verdict("x", NSRange(location: 2, length: 0), in: note) == .allow)
        #expect(verdict("", NSRange(location: 2, length: 2), in: note) == .allow)
        let outro = offset(of: "Outro", in: note)
        #expect(verdict("x", NSRange(location: outro + 2, length: 0), in: note) == .allow)
        #expect(verdict("x", NSRange(location: 0, length: 0), in: "no tables") == .allow)
    }

    @Test func typingOnTheLineUnderATableLeavesABlankLineSoItIsNoRow() throws {
        let text = "| a |\n|---|\n"
        let end = (text as NSString).length
        guard case let .edit(edit) = verdict("x", NSRange(location: end, length: 0), in: text) else {
            Issue.record("expected an edit")
            return
        }
        let after = edit.applied(to: text)
        #expect(after == "| a |\n|---|\n\nx")
        #expect(edit.selection.location == (after as NSString).length, "the caret is behind the letter")
        #expect(TableEdits.spans(in: after).first?.table.rows.isEmpty == true, "and it is no row")
    }

    @Test func typingUnderATableWithNoLastLineEndingGivesItOne() throws {
        let text = "| a |\n|---|"
        let end = (text as NSString).length
        guard case let .edit(edit) = verdict("x", NSRange(location: end, length: 0), in: text) else {
            Issue.record("expected an edit")
            return
        }
        #expect(edit.applied(to: text) == "| a |\n|---|\n\nx")
        #expect(verdict("\n", NSRange(location: end, length: 0), in: text) == .allow, "a line break is what it needs")
    }

    @Test func aLineUnderATableThatStartsABlockCanStayThere() {
        let text = "| a |\n|---|\n"
        let end = (text as NSString).length
        #expect(verdict("# ", NSRange(location: end, length: 0), in: text) == .allow)
        #expect(verdict("- ", NSRange(location: end, length: 0), in: text) == .allow)
        #expect(verdict("\n", NSRange(location: end, length: 0), in: text) == .allow)
    }

    @Test func aBlockUnderATableThatStopsBeingOneGetsItsBlankLine() throws {
        let text = "| a |\n|---|\n-"
        let end = (text as NSString).length
        guard case let .edit(edit) = verdict("x", NSRange(location: end, length: 0), in: text) else {
            Issue.record("expected an edit")
            return
        }
        let after = edit.applied(to: text)
        #expect(after == "| a |\n|---|\n\n-x")
        #expect(edit.selection.location == (after as NSString).length)
        #expect(TableEdits.spans(in: after).first?.table.rows.isEmpty == true)
    }

    @Test func theBlankLineUnderATableCantBeTakenAway() {
        let outro = offset(of: "Outro", in: note)
        // Backspace at the start of the text below: the caret goes up to the blank line, and nothing is deleted.
        #expect(verdict("", NSRange(location: outro - 1, length: 1), in: note) == .moveCaret(outro - 1))
    }

    @Test func backspaceOnTheLineUnderATableGoesIntoItsLastCell() {
        let text = "| a |\n|---|\n| 1 |\n"
        let end = (text as NSString).length
        #expect(verdict("", NSRange(location: end - 1, length: 1), in: text) == .enters(table: 0, atStart: false))
        let crlf = "| a |\r\n|---|\r\n| 1 |\r\n"
        let crlfEnd = (crlf as NSString).length
        #expect(verdict("", NSRange(location: crlfEnd - 2, length: 2), in: crlf) == .enters(table: 0, atStart: false))
    }

    @Test func aCaretSomehowInATableGoesIntoACellAndWritesNothing() {
        let start = offset(of: "| a", in: note)
        #expect(verdict("x", NSRange(location: start, length: 0), in: note) == .enters(table: 0, atStart: true))
        #expect(verdict("x", NSRange(location: start + 4, length: 0), in: note) == .enters(table: 0, atStart: true))
    }

    @Test func aPartOfATableIsNeverReplaced() {
        let start = offset(of: "| a", in: note)
        #expect(verdict("x", NSRange(location: start - 2, length: 4), in: note) == .ignore)
        #expect(verdict("", NSRange(location: start + 3, length: 2), in: note) == .ignore)
        let outro = offset(of: "Outro", in: note)
        #expect(verdict("", NSRange(location: outro - 3, length: 5), in: note) == .ignore, "from inside it to past it")
    }

    @Test func aWholeTableCanBeReplaced() throws {
        let found = try span(note)
        #expect(verdict("", found.range, in: note) == .allow)
        #expect(verdict("x", NSRange(location: 0, length: (note as NSString).length), in: note) == .allow)
    }

    @Test func aLineCantBeJoinedOntoTheHeader() throws {
        let text = "Hello\n| a |\n|---|\n"
        // Delete at the end of Hello: the caret stays where it is.
        #expect(verdict("", NSRange(location: 5, length: 1), in: text) == .moveCaret(5))
        // A selection up to the header, with text left in front of it, keeps a line break.
        guard case let .edit(edit) = verdict("y", NSRange(location: 2, length: 4), in: text) else {
            Issue.record("expected an edit")
            return
        }
        #expect(edit.applied(to: text) == "Hey\n| a |\n|---|\n")
        #expect(edit.selection.location == 3)
    }

    @Test func aListItemRightAboveATableWouldSwallowItSoItGetsABlankLine() throws {
        // On GitHub a table right under a list item's text is more of that text.
        let text = "x\n| a |\n|---|\n"
        guard case let .edit(edit) = verdict("- ", NSRange(location: 0, length: 0), in: text) else {
            Issue.record("expected an edit")
            return
        }
        #expect(edit.applied(to: text) == "- x\n\n| a |\n|---|\n")
        #expect(edit.selection.location == 2, "the caret goes on behind the marker")
        #expect(TableEdits.spans(in: edit.applied(to: text)).count == 1)
        // And taking away the blank line that keeps a list off a table is not on.
        let list = "- x\n\n| a |\n|---|\n"
        #expect(verdict("", NSRange(location: 3, length: 1), in: list) == .moveCaret(3))
    }

    @Test func aBlankLineAboveATableCanGo() {
        let text = "Hello\n\n| a |\n|---|\n"
        #expect(verdict("", NSRange(location: 6, length: 1), in: text) == .allow)
        #expect(verdict("", NSRange(location: 5, length: 1), in: text) == .allow)
    }

    @Test func typingOnTheBlankLineAboveATableIsFine() throws {
        let text = "Hello\n\n| a |\n|---|\n"
        #expect(verdict("x", NSRange(location: 6, length: 0), in: text) == .allow)
        // That line continues into the table's header on GitHub, and the table stays a table.
        #expect(TableEdits.spans(in: "Hello\nx\n| a |\n|---|\n").count == 1)
    }

    @Test func twoTablesCantMerge() {
        let text = "| a |\n|---|\n\n| b |\n|---|\n"
        let blank = offset(of: "\n| b", in: text)
        #expect(verdict("", NSRange(location: blank, length: 1), in: text) == .moveCaret(blank))
    }

    @Test func safeguardingKeepsTheEditsOwnSelection() throws {
        let text = "| a |\n|---|\n"
        let end = (text as NSString).length
        // A link with nothing selected: the caret goes between the brackets, behind the blank line this adds.
        let link = MarkdownEdits.Edit(range: NSRange(location: end, length: 0), replacement: "[[]]", selection: NSRange(location: end + 2, length: 0))
        let safe = try #require(TableEdits.safeguarding(link, in: text, spans: TableEdits.spans(in: text)))
        #expect(safe.applied(to: text) == "| a |\n|---|\n\n[[]]")
        #expect(safe.selection.location == end + 3)
        // Not next to a table: as it was.
        let far = MarkdownEdits.Edit(range: NSRange(location: 0, length: 0), replacement: "x", selection: NSRange(location: 1, length: 0))
        #expect(TableEdits.safeguarding(far, in: "plain", spans: []) == far)
        // Into a table: not at all.
        let inside = MarkdownEdits.Edit(range: NSRange(location: 2, length: 0), replacement: "**", selection: NSRange(location: 3, length: 0))
        #expect(TableEdits.safeguarding(inside, in: text, spans: TableEdits.spans(in: text)) == nil)
    }

    @Test func deletingAMarkerUnderATableKeepsItsTextOutOfTheTable() throws {
        // `- [ ] x` right under a table ends it. Without its marker `x` would be a row.
        let text = "| a |\n|---|\n- [ ] x\n"
        let start = offset(of: "- [ ]", in: text)
        let removal = MarkdownEdits.Edit(range: NSRange(location: start, length: 6), replacement: "", selection: NSRange(location: start, length: 0))
        let safe = try #require(TableEdits.safeguarding(removal, in: text, spans: TableEdits.spans(in: text)))
        let after = safe.applied(to: text)
        #expect(after == "| a |\n|---|\n\nx\n")
        #expect(safe.selection.location == start + 1, "the caret stays in front of the x")
        #expect(TableEdits.spans(in: after).first?.table.rows.isEmpty == true)
    }

    @Test func everyWayOfTypingNextToATableLeavesItAsItWas() throws {
        // Each place around a table, each kind of edit: if the verdict lets something through, the table's lines are the same.
        let bases = ["| a |\n|---|\n| 1 |\n", "| a |\n|---|\n| 1 |", "x\n\n| a |\n|---|\n| 1 |\n\ny\n", "x\n| a |\n|---|\n| 1 |\n# h\n", "| a |\n|---|\n\n| b |\n|---|\n"]
        for base in bases {
            let ns = base as NSString
            let before = TableEdits.spans(in: base)
            for location in 0...ns.length {
                for length in 0...min(2, ns.length - location) {
                    for replacement in ["", "x", "\n", "- ", "| z |", "x\ny"] {
                        let range = NSRange(location: location, length: length)
                        var after: String?
                        switch TableEdits.typing(replacement, replacing: range, in: ns, spans: before) {
                        case .allow: after = ns.replacingCharacters(in: range, with: replacement)
                        case let .edit(edit): after = edit.applied(to: base)
                        case .enters, .moveCaret, .ignore: break
                        }
                        guard let after else { continue }
                        // Tables may have been deleted whole by the edit; those that are left have the rows they had.
                        let context = "\(base.debugDescription) \(range) \(replacement.debugDescription) gave \(after.debugDescription)"
                        let left = TableEdits.spans(in: after).map { $0.table.source.trimmingCharacters(in: .newlines) }
                        for table in before where !(range.length > 0 && range.location <= table.range.location && NSMaxRange(table.range) <= NSMaxRange(range)) {
                            #expect(left.contains(table.table.source.trimmingCharacters(in: .newlines)), "\(context)")
                        }
                    }
                }
            }
        }
    }

    // MARK: cells' inline text

    @Test func aCellHasInlineMarksButNoBlocks() {
        func kinds(_ text: String) -> [MarkdownInline.Span.Kind] { MarkdownInline.inline(units: Array(text.utf16)).spans.map(\.kind) }
        #expect(kinds("**a** and *b*") == [.bold, .italic])
        #expect(kinds("[[link]]") == [.wikiLink(target: "link")])
        let heading = MarkdownInline.inline(units: Array("# a".utf16))
        #expect(heading.block == .plain)
        #expect(heading.marks.isEmpty, "the hash is what the cell says")
        let bullet = MarkdownInline.inline(units: Array("- **a**".utf16))
        #expect(bullet.block == .plain)
        #expect(bullet.marks.count == 2, "only the bold's marks")
    }

    // MARK: sync and search see plain Markdown

    @Test func aCellEditIsOneLineSoEditsOnTwoDevicesMerge() throws {
        let base = "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n| Wed | 7 |\n| Thu | 8 |\n"
        func edited(row: Int, to text: String) throws -> String {
            let found = try span(base)
            var table = found.table
            try table.setGridText(row: row, column: 1, to: text)
            return try #require(TableEdits.edit(of: found, to: table)).applied(to: base)
        }
        let mine = try edited(row: 1, to: "5.5")
        let theirs = try edited(row: 4, to: "8.5")
        func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }
        #expect(zip(lines(base), lines(mine)).filter { $0 != $1 }.count == 1, "one line")
        let merged = try mergeFile(base: base, mine: mine, theirs: theirs)
        #expect(merged.kind == .merged)
        #expect(merged.content == "# Log\n\n| Day | Km |\n|---|---|\n| Mon | 5.5 |\n| Tue | 6 |\n| Wed | 7 |\n| Thu | 8.5 |\n")
        #expect(TableEdits.spans(in: merged.content ?? "").first?.table.gridRowCount == 5)
    }

    @Test func aStructuralEditOnOneDeviceAndACellOnAnotherMerge() throws {
        let base = "| Day | Km |\n|---|---|\n| Mon | 5 |\n| Tue | 6 |\n| Wed | 7 |\n"
        let found = try span(base)
        var added = found.table
        try added.insertGridRow(at: added.gridRowCount)
        let mine = try #require(TableEdits.edit(of: found, to: added)).applied(to: base)
        var changed = found.table
        try changed.setGridText(row: 1, column: 1, to: "5.5")
        let theirs = try #require(TableEdits.edit(of: found, to: changed)).applied(to: base)
        let merged = try mergeFile(base: base, mine: mine, theirs: theirs)
        #expect(merged.kind == .merged)
        let table = try #require(TableEdits.spans(in: merged.content ?? "").first?.table)
        #expect(table.gridRowCount == 5)
        #expect(table.gridText(row: 1, column: 1) == "5.5")
    }

    @Test func aClashInATableLosesNothing() throws {
        let base = "| Day | Km |\n|---|---|\n| Mon | 5 |\n"
        let found = try span(base)
        var a = found.table, b = found.table
        try a.setGridText(row: 1, column: 1, to: "mine")
        try b.setGridText(row: 1, column: 1, to: "theirs")
        let mine = try #require(TableEdits.edit(of: found, to: a)).applied(to: base)
        let theirs = try #require(TableEdits.edit(of: found, to: b)).applied(to: base)
        let merged = try mergeFile(base: base, mine: mine, theirs: theirs)
        #expect(merged.kind == .conflict)
        #expect(merged.copy == mine, "mine goes to a conflict copy, whole")
        #expect(TableEdits.spans(in: merged.content ?? "").first?.table.gridText(row: 1, column: 1) == "theirs")
    }
}

/// The source stays plain Markdown, so what a cell says is found like any other text.
@Suite struct TableSearchTests {
    @Test func aCellsTextIsFoundInEnglishAndHebrew() async throws {
        let i = try SearchIndex(path: nil)
        var table = try #require(MarkdownTable(parsing: "|   |   |\n|---|---|\n|   |   |\n"))
        try table.setGridText(row: 0, column: 0, to: "Tempo")
        try table.setGridText(row: 1, column: 1, to: "גרגירים")
        try i.upsert(path: "a.md", text: "# Log\n\n" + table.markdown, modified: nil)
        #expect(await i.search("tempo").map(\.path) == ["a.md"])
        #expect(await i.search("גרגיר").map(\.path) == ["a.md"])
    }
}
