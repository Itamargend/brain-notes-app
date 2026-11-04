/// A note cut into its GFM pipe tables and the text between them. Joining the pieces gives the note back byte for
/// byte, and an edit to one table rewrites only that table: every byte before and after it stays.
///
/// What counts as a table: a header row and a delimiter row (`---`, `:--`, `--:`, `:-:`), both with at least one
/// unescaped pipe, the same number of cells, and at most 3 spaces of indent; then body rows until a blank line, the end
/// of the note, or a line that starts another block (a quote, a heading, a fence, a thematic break, a list item).
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

    static func cut(_ b: [UInt8]) -> [Piece] {
        typealias S = TableSyntax
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let first = b.starts(with: bom) ? 3 : 0
        let spans = S.lines(b, from: first)
        var pieces: [Piece] = []
        var textStart = 0
        var fence: (mark: UInt8, count: Int)?
        var i = frontMatterEnd(b, spans)
        while i < spans.count {
            let body = b[spans[i].start..<spans[i].bodyEnd]
            if let open = fence {
                if S.closesFence(body, mark: open.mark, count: open.count) { fence = nil }
                i += 1
                continue
            }
            if let found = tableStarting(at: i, in: b, spans) {
                if textStart < spans[i].start { pieces.append(.text(S.string(b[textStart..<spans[i].start]))) }
                pieces.append(.table(found.table))
                textStart = spans[found.next - 1].end
                i = found.next
                continue
            }
            let (columns, at) = S.indent(body)
            if columns <= 3, let open = S.fenceOpening(body[at...]) { fence = open }
            i += 1
        }
        if textStart < b.count { pieces.append(.text(S.string(b[textStart...]))) }
        return pieces
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

    /// A table whose header row is line `i`, and the line after its last row.
    static func tableStarting(at i: Int, in b: [UInt8], _ spans: [TableSyntax.LineSpan]) -> (table: MarkdownTable, next: Int)? {
        typealias S = TableSyntax
        guard i + 1 < spans.count else { return nil }
        func body(_ k: Int) -> ArraySlice<UInt8> { b[spans[k].start..<spans[k].bodyEnd] }
        func ending(_ k: Int) -> String { S.string(b[spans[k].bodyEnd..<spans[k].end]) }

        let headerLine = body(i)
        let (headerColumns, headerAt) = S.indent(headerLine)
        guard headerColumns <= 3, !S.isBlank(headerLine), !S.startsBlock(headerLine[headerAt...]) else { return nil }
        let delimiterLine = body(i + 1)
        guard S.indent(delimiterLine).columns <= 3 else { return nil }
        let header = S.parseRow(headerLine, lineEnding: ending(i))
        let delimiter = S.parseRow(delimiterLine, lineEnding: ending(i + 1))
        guard header.pipes > 0, delimiter.pipes > 0,
              header.row.cells.count == delimiter.row.cells.count,
              delimiter.row.cells.allSatisfy({ S.isMarker($0.raw) })
        else { return nil }

        var rows: [MarkdownTable.Row] = []
        var k = i + 2
        while k < spans.count {
            let line = body(k)
            if S.isBlank(line) { break }
            let (columns, at) = S.indent(line)
            if columns <= 3 && S.startsBlock(line[at...]) { break }
            rows.append(S.parseRow(line, lineEnding: ending(k)).row)
            k += 1
        }
        let source = S.string(b[spans[i].start..<spans[k - 1].end])
        return (table: MarkdownTable(header: header.row, delimiter: delimiter.row, rows: rows, source: source), next: k)
    }
}
