/// A note cut into its GFM pipe tables and the text between them. Joining the pieces gives the note back byte for
/// byte, and an edit to one table rewrites only that table: every byte before and after it stays.
///
/// What counts as a table, as on GitHub (cmark-gfm): a paragraph line as the header row, then a delimiter row
/// (`---`, `:--`, `--:`, `:-:`) with the same number of cells and at most 3 spaces of indent; then body rows until a blank line, the end
/// of the note, a line indented 4 columns or more (indented code), a line that is a lone `|` (no cells, to GitHub), or a
/// line that starts another block (a quote, a heading, a fence, a thematic break, a list item).
/// Nothing inside a fenced code block or a front matter block is a table. Tables inside quotes or list items are
/// left as text.
public struct TableDocument: Sendable, Equatable {
    public enum Piece: Sendable, Equatable {
        case text(String)
        case table(MarkdownTable)

        /// The piece as Markdown: text as it is, a table as its `markdown`.
        public var markdown: String {
            switch self {
            case .text(let s): return s
            case .table(let t): return t.markdown
            }
        }
    }

    public private(set) var pieces: [Piece]

    public init(parsing text: String) {
        pieces = Self.cut(Array(text.utf8))
    }

    /// The tables, in order.
    public var tables: [MarkdownTable] {
        pieces.compactMap { piece -> MarkdownTable? in
            if case .table(let t) = piece { return t }
            return nil
        }
    }

    /// The whole note. With no edits, exactly the text it was read from.
    public var markdown: String {
        var out = ""
        for piece in pieces { out += piece.markdown }
        return out
    }

    /// Changes the table at `index` (an index into `tables`). Only that piece changes.
    public mutating func updateTable(at index: Int, _ change: (inout MarkdownTable) throws -> Void) rethrows {
        let slot = pieceIndex(ofTable: index)
        guard case .table(var table) = pieces[slot] else { preconditionFailure("piece \(slot) is not a table") }
        try change(&table)
        pieces[slot] = .table(table)
    }

    /// Where the table at `index` is in `markdown`, in UTF-16 offsets, the unit of the editor's text views. Replacing
    /// that range in the old text with the table's new `markdown` is the whole edit, as one change.
    public func utf16Range(ofTable index: Int) -> Range<Int> {
        let slot = pieceIndex(ofTable: index)
        var start = 0
        for piece in pieces[..<slot] { start += piece.markdown.utf16.count }
        return start..<(start + pieces[slot].markdown.utf16.count)
    }

    /// The table (as an index into `tables`) whose text holds this UTF-16 offset, if any. An offset at a table's very
    /// end, after its last line break, belongs to what follows.
    public func tableIndex(atUTF16Offset offset: Int) -> Int? {
        var start = 0
        var seen = 0
        for piece in pieces {
            let length = piece.markdown.utf16.count
            if case .table = piece {
                if offset >= start && offset < start + length { return seen }
                seen += 1
            }
            start += length
        }
        return nil
    }

    private func pieceIndex(ofTable index: Int) -> Int {
        var seen = 0
        for (slot, piece) in pieces.enumerated() {
            if case .table = piece {
                if seen == index { return slot }
                seen += 1
            }
        }
        preconditionFailure("no table \(index); there are \(seen)")
    }

    // MARK: reading

    /// What the line before held, as far as the next line cares.
    enum LastText { case none, paragraph, quote }

    /// Line by line, as cmark-gfm (GitHub's parser) finds tables: a table starts where a paragraph line is followed by
    /// a delimiter row, with indents counted from the list item the lines are in. A paragraph gets one try: once a
    /// delimiter-looking line under it didn't make a table, none starts later in that paragraph. A line that continues
    /// a quote's or a list item's paragraph lazily (less indented than the item's text) is part of that paragraph, so
    /// no table starts there.
    static func cut(_ b: [UInt8]) -> [Piece] {
        typealias S = TableSyntax
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let first = b.starts(with: bom) ? 3 : 0
        let spans = S.lines(b, from: first)
        var pieces: [Piece] = []
        var textStart = 0
        var fence: S.Fence?
        // The text columns of the open list items, outermost first.
        var items: [Int] = []
        var last = LastText.none
        // The paragraph above already had its try at a table.
        var tried = false
        // The innermost item is empty so far: a blank line closes it.
        var emptyItem = false
        var i = frontMatterEnd(b, spans)
        while i < spans.count {
            let body = b[spans[i].start..<spans[i].bodyEnd]
            let (columns, at) = S.indent(body)
            let rest = body[at...]
            if let open = fence {
                // A line left of the fence's list item closes the item, and the fence with it.
                if S.isBlank(body) || columns >= open.base {
                    if S.closesFence(body, mark: open.mark, count: open.count, base: open.base) { fence = nil }
                    i += 1
                    continue
                }
                fence = nil
            }
            if S.isBlank(body) {
                // List items stay open over blank lines, but for one with nothing in it yet.
                if emptyItem, let top = items.last, columns < top { items.removeLast() }
                emptyItem = false
                last = .none
                tried = false
                i += 1
                continue
            }
            emptyItem = false
            // A line that leaves the quote or item a paragraph is in may start any block; only within the paragraph's
            // own container can't an empty item or a list from 2 interrupt it.
            let startsBlock = S.startsBlock(rest)
            if last == .quote {
                if !(columns <= 3 && startsBlock) {
                    i += 1
                    continue
                }
                last = .none
            }
            if let top = items.last, columns < top {
                let outer = items.last(where: { $0 <= columns }) ?? 0
                if last == .paragraph && !(startsBlock && columns - outer <= 3) {
                    // Continues the item's paragraph lazily; GitHub may still try a table under it, and then not later.
                    if !tried, i + 1 < spans.count, delimiterTry(i + 1, in: b, spans, base: top) { tried = true }
                    i += 1
                    continue
                }
                while let top = items.last, columns < top { items.removeLast() }
                last = .none
                tried = false
            }
            let base = items.last ?? 0
            if last == .paragraph && columns - base <= 3 && S.isSetextUnderline(rest) {
                // The paragraph above is a heading now.
                last = .none
                tried = false
                i += 1
                continue
            }
            if columns - base <= 3 && S.startsBlock(rest) && (last != .paragraph || S.interruptsParagraph(rest)) {
                let opened = S.opening(rest, columns: columns)
                items += opened.items
                fence = opened.fence
                last = opened.text
                emptyItem = opened.isEmptyItem
                tried = false
                // An item's own first line can head a table on GitHub. Not here, but it uses up the try.
                if last == .paragraph, let top = items.last, i + 1 < spans.count, delimiterTry(i + 1, in: b, spans, base: top) {
                    tried = true
                }
                i += 1
                continue
            }
            if last != .paragraph && columns - base > 3 {
                // Indented code.
                i += 1
                continue
            }
            if last != .paragraph { tried = false }
            if !tried, i + 1 < spans.count, delimiterTry(i + 1, in: b, spans, base: base) {
                if let found = tableStarting(at: i, in: b, spans, base: base, continuing: last == .paragraph) {
                    if textStart < spans[i].start { pieces.append(.text(S.string(b[textStart..<spans[i].start]))) }
                    pieces.append(.table(found.table))
                    textStart = spans[found.next - 1].end
                    i = found.next
                    last = .none
                    tried = false
                    continue
                }
                tried = true
            }
            last = .paragraph
            i += 1
        }
        if textStart < b.count { pieces.append(.text(S.string(b[textStart...]))) }
        return pieces
    }

    /// Whether line `k`, under a paragraph line in the list item whose text starts at column `base` (0 outside any),
    /// makes GitHub try a table: it looks like a delimiter row and starts no other block. If the try fails, that
    /// paragraph gets no other.
    static func delimiterTry(_ k: Int, in b: [UInt8], _ spans: [TableSyntax.LineSpan], base: Int) -> Bool {
        typealias S = TableSyntax
        let line = b[spans[k].start..<spans[k].bodyEnd]
        let (columns, at) = S.indent(line)
        guard columns >= base, columns - base <= 3, !S.startsBlock(line[at...]) else { return false }
        return S.isDelimiterRow(S.parseRow(line, lineEnding: ""))
    }

    /// The line after a front matter block (`---` on the first line, up to the next `---` or `...`), or 0 if none.
    static func frontMatterEnd(_ b: [UInt8], _ spans: [TableSyntax.LineSpan]) -> Int {
        func trimmed(_ span: TableSyntax.LineSpan) -> ArraySlice<UInt8> {
            var line = b[span.start..<span.bodyEnd]
            while let last = line.last, TableSyntax.isSpaceOrTab(last) { line = line.dropLast() }
            return line
        }
        guard let firstLine = spans.first, trimmed(firstLine).elementsEqual("---".utf8) else { return 0 }
        for k in spans.indices.dropFirst() {
            let line = trimmed(spans[k])
            if line.elementsEqual("---".utf8) || line.elementsEqual("...".utf8) { return k + 1 }
        }
        return 0
    }

    /// A table whose header row is line `i` and delimiter row line `i + 1`, and the line after its last row. Indents
    /// count from `base`, the text column of the list item the table is in. A header that continues a paragraph may
    /// have any indent; one that starts it, at most 3 columns.
    static func tableStarting(at i: Int, in b: [UInt8], _ spans: [TableSyntax.LineSpan], base: Int = 0, continuing: Bool = false)
        -> (table: MarkdownTable, next: Int)? {
        typealias S = TableSyntax
        guard i + 1 < spans.count else { return nil }
        func body(_ k: Int) -> ArraySlice<UInt8> { b[spans[k].start..<spans[k].bodyEnd] }
        func ending(_ k: Int) -> String { S.string(b[spans[k].bodyEnd..<spans[k].end]) }

        let headerLine = body(i)
        let (headerColumns, headerAt) = S.indent(headerLine)
        guard headerColumns >= base, headerColumns - base <= 3 || continuing, !S.isBlank(headerLine),
              headerColumns - base > 3 || !S.startsBlock(headerLine[headerAt...]),
              !S.isLonePipe(headerLine[headerAt...]) else { return nil }
        let delimiterLine = body(i + 1)
        let (delimiterColumns, delimiterAt) = S.indent(delimiterLine)
        guard delimiterColumns >= base, delimiterColumns - base <= 3, !S.startsBlock(delimiterLine[delimiterAt...]) else { return nil }
        let header = S.parseRow(headerLine, lineEnding: ending(i))
        let delimiter = S.parseRow(delimiterLine, lineEnding: ending(i + 1))
        guard S.isDelimiterRow(delimiter), header.row.cells.count == delimiter.row.cells.count else { return nil }

        var rows: [MarkdownTable.Row] = []
        var k = i + 2
        while k < spans.count {
            let line = body(k)
            if S.isBlank(line) { break }
            let (columns, at) = S.indent(line)
            // Left of the list item closes it; 4 columns past it starts indented code. Either ends the table.
            if columns < base || columns - base > 3 || S.startsBlock(line[at...]) || S.isLonePipe(line[at...]) { break }
            rows.append(S.parseRow(line, lineEnding: ending(k)).row)
            k += 1
        }
        let source = S.string(b[spans[i].start..<spans[k - 1].end])
        var table = MarkdownTable(header: header.row, delimiter: delimiter.row, rows: rows, source: source)
        table.continuesParagraph = continuing
        return (table: table, next: k)
    }
}
