/// One GFM pipe table, kept as the parts of each of its lines: indent, outer pipes, and per cell the padding before,
/// the content as written, and the padding after. A line nothing has touched writes back as its own bytes; an edit
/// rewrites only the lines it changes, and the table's other lines stay as they were.
///
/// Rows are taken as written, ragged ones included: a row may have fewer cells than the header (the rest read as
/// empty) or more (GitHub ignores those). Edits never even them out on their own.
public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable, CaseIterable {
        case none, left, center, right
    }

    public enum EditError: Error, Sendable, Equatable {
        case noSuchRow(Int)
        case noSuchColumn(Int)
        /// A table needs at least one column.
        case lastColumn
        /// A table needs its header row.
        case lastRow
        /// A new row was given more cells than the table has columns.
        case tooManyCells(Int)
    }

    public struct Cell: Sendable, Equatable {
        /// Spaces and tabs before the content.
        public internal(set) var leading: String
        /// The content as written in the file, escapes kept (`\|` stays `\|`).
        public internal(set) var raw: String
        /// Spaces and tabs after the content.
        public internal(set) var trailing: String

        init(leading: String, raw: String, trailing: String) {
            self.leading = leading
            self.raw = raw
            self.trailing = trailing
        }

        /// What the cell says: the content with `\|` read as `|`, the way GitHub reads it, inside backticks too.
        public var text: String { TableSyntax.unescape(raw) }

        /// Whether the cell's first strong character is right to left (Hebrew, Arabic), or it starts with an RLM.
        public var isRightToLeft: Bool { TableSyntax.isRightToLeft(text) }
    }

    public struct Row: Sendable, Equatable {
        /// Spaces and tabs before the row.
        public internal(set) var indent: String
        public internal(set) var leadingPipe: Bool
        public internal(set) var cells: [Cell]
        public internal(set) var trailingPipe: Bool
        /// Spaces and tabs after the closing pipe.
        public internal(set) var trail: String
        /// `\n`, `\r\n`, `\r`, or nothing for a last line with no line break.
        public internal(set) var lineEnding: String
        /// The line as read, without its ending, until an edit changes the row.
        var original: String?

        init(indent: String, leadingPipe: Bool, cells: [Cell], trailingPipe: Bool, trail: String, lineEnding: String, original: String?) {
            self.indent = indent
            self.leadingPipe = leadingPipe
            self.cells = cells
            self.trailingPipe = trailingPipe
            self.trail = trail
            self.lineEnding = lineEnding
            self.original = original
        }

        /// Whether the row still has the exact bytes it was read with.
        public var isUntouched: Bool { original != nil }

        /// What each cell says, as many as the row has.
        public var texts: [String] { cells.map(\.text) }
    }

    public internal(set) var header: Row
    public internal(set) var delimiter: Row
    public internal(set) var rows: [Row]
    /// The table's bytes as read, line endings included.
    public let source: String
    /// Whether an edit has changed anything. An unedited table writes back as `source`.
    public internal(set) var isEdited = false
    /// The header row continues a paragraph: the line above it is paragraph text.
    var continuesParagraph = false

    init(header: Row, delimiter: Row, rows: [Row], source: String) {
        self.header = header
        self.delimiter = delimiter
        self.rows = rows
        self.source = source
    }

    /// Reads a table that is the whole of `text` (a header row, a delimiter row, any body rows). Nil if it isn't one.
    public init?(parsing text: String) {
        let doc = TableDocument(parsing: text)
        guard doc.pieces.count == 1, case .table(let table)? = doc.pieces.first else { return nil }
        self = table
    }

    // MARK: reading

    /// The header's cell count: GitHub shows this many columns.
    public var columnCount: Int { header.cells.count }

    public var alignments: [Alignment] { delimiter.cells.map { TableSyntax.alignment(of: $0.raw) } }

    public var headerTexts: [String] { header.texts }

    /// What a body cell says, or "" where a short row has no such cell.
    public func text(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return "" }
        return rows[row].cells[column].text
    }

    /// The table's direction: that of the first header cell with a strong character, left to right if none has one.
    public var isRightToLeft: Bool { TableSyntax.isRightToLeft(header.cells.map(\.text).joined(separator: " ")) }

    /// The table as Markdown. Unedited, that is `source`, byte for byte.
    public var markdown: String {
        guard isEdited else { return source }
        var out = ""
        var headerRow = header
        var headerLine = Self.line(headerRow, kind: .header)
        if continuesParagraph && TableSyntax.isDelimiterRow(TableSyntax.parseRow(Array(headerLine.utf8)[...], lineEnding: "")) {
            // A header of only markers under a paragraph line would be that paragraph's delimiter row, and the
            // table would lose its header. A blank line keeps them apart; the header takes the delimiter row's
            // indent, since after a blank line 4 columns would make it code.
            out += header.lineEnding
            headerRow.indent = delimiter.indent
            headerRow.original = nil
            headerLine = Self.line(headerRow, kind: .header)
        }
        out += headerLine + header.lineEnding
        out += Self.line(delimiter, kind: .delimiter) + delimiter.lineEnding
        for row in rows {
            out += Self.line(row, kind: .body) + row.lineEnding
        }
        return out
    }

    // MARK: editing

    /// Sets what a header cell says.
    public mutating func setHeader(column: Int, to text: String) throws {
        guard header.cells.indices.contains(column) else { throw EditError.noSuchColumn(column) }
        let pad = padding(for: header)
        if header.setText(text, at: column, padding: pad) { isEdited = true }
    }

    /// Sets what a body cell says. A short row gets empty cells up to that column first; a column past the header's is
    /// allowed only where the row already has a cell there.
    public mutating func setCell(row: Int, column: Int, to text: String) throws {
        guard rows.indices.contains(row) else { throw EditError.noSuchRow(row) }
        guard column >= 0, column < max(columnCount, rows[row].cells.count) else { throw EditError.noSuchColumn(column) }
        let raw = TableSyntax.escape(text)
        let pad = padding(for: rows[row])
        if column >= rows[row].cells.count {
            // A missing cell already reads as empty.
            if raw.isEmpty { return }
            while rows[row].cells.count <= column { rows[row].appendEmptyCell(padding: pad) }
        }
        if rows[row].setText(text, at: column, padding: pad) { isEdited = true }
    }

    /// Inserts a body row at `index` (0 is right under the delimiter row, `rows.count` is after the last), with one
    /// cell per column, filled from `texts` and empty after that. It takes its indent and outer pipes from the row above
    /// (the first body row takes its indent from the delimiter row).
    public mutating func insertRow(at index: Int, texts: [String] = []) throws {
        guard index >= 0, index <= rows.count else { throw EditError.noSuchRow(index) }
        guard texts.count <= columnCount else { throw EditError.tooManyCells(texts.count) }
        let lastEnding = lastLineEnding
        let template = index > 0 ? rows[index - 1] : (rows.first ?? header)
        let pad = padding(for: template)
        // A header that continues a paragraph can be indented any amount; a body row that far in would be code.
        let indent = index == 0 && rows.isEmpty ? delimiter.indent : template.indent
        var row = Row(indent: indent, leadingPipe: template.leadingPipe, cells: [],
                      trailingPipe: template.trailingPipe, trail: "", lineEnding: header.lineEnding, original: nil)
        for column in 0..<columnCount {
            let raw = column < texts.count ? TableSyntax.escape(texts[column]) : ""
            let cell = row.newCell(raw: raw, at: column, of: columnCount, padding: pad)
            row.cells.append(cell)
        }
        rows.insert(row, at: index)
        settleLineEndings(last: lastEnding)
        isEdited = true
    }

    public mutating func removeRow(at index: Int) throws {
        guard rows.indices.contains(index) else { throw EditError.noSuchRow(index) }
        let lastEnding = lastLineEnding
        rows.remove(at: index)
        settleLineEndings(last: lastEnding)
        isEdited = true
    }

    /// Inserts a column at `index` (`columnCount` appends one). Body rows get an empty cell there; a short row that
    /// doesn't reach that column is left as it is, since its missing cells read as empty anyway.
    public mutating func insertColumn(at index: Int, header text: String = "", alignment: Alignment = .none) throws {
        let count = columnCount
        guard index >= 0, index <= count else { throw EditError.noSuchColumn(index) }
        let headerPadding = padding(for: header)
        header.insertCell(raw: TableSyntax.escape(text), at: index, padding: headerPadding)
        let delimiterPadding = Self.evidence(in: delimiter) ?? headerPadding
        delimiter.insertCell(raw: TableSyntax.marker(alignment), at: index, padding: delimiterPadding)
        for r in rows.indices where index < rows[r].cells.count || (index == rows[r].cells.count && index >= count) {
            let pad = padding(for: rows[r])
            rows[r].insertCell(raw: "", at: index, padding: pad)
        }
        isEdited = true
    }

    /// Removes a column from the header, the delimiter row and every body row that reaches it.
    public mutating func removeColumn(at index: Int) throws {
        guard index >= 0, index < columnCount else { throw EditError.noSuchColumn(index) }
        guard columnCount > 1 else { throw EditError.lastColumn }
        header.removeCell(at: index)
        delimiter.removeCell(at: index)
        for r in rows.indices where index < rows[r].cells.count {
            rows[r].removeCell(at: index)
        }
        isEdited = true
    }

    /// Sets a column's alignment. The delimiter cell keeps its width where it can, trading dashes for colons.
    public mutating func setAlignment(_ alignment: Alignment, column: Int) throws {
        guard delimiter.cells.indices.contains(column) else { throw EditError.noSuchColumn(column) }
        let old = delimiter.cells[column].raw
        guard TableSyntax.alignment(of: old) != alignment else { return }
        delimiter.cells[column].raw = TableSyntax.marker(alignment, width: old.utf8.count)
        delimiter.original = nil
        isEdited = true
    }

    // MARK: inside

    enum Kind { case header, delimiter, body }

    /// Spaces before and after the content, for a cell that has none of its own to keep.
    struct Padding: Equatable {
        var lead: String
        var trail: String
    }

    private var lastLineEnding: String { (rows.last ?? delimiter).lineEnding }

    /// Every line but the last ends with a line break; the last keeps the ending the table's last line had, so the
    /// text after the table (or the end of the file) meets it exactly as before.
    private mutating func settleLineEndings(last: String) {
        let eol = header.lineEnding.isEmpty ? "\n" : header.lineEnding
        if delimiter.lineEnding.isEmpty { delimiter.lineEnding = eol }
        for r in rows.indices where rows[r].lineEnding.isEmpty { rows[r].lineEnding = eol }
        if rows.isEmpty { delimiter.lineEnding = last } else { rows[rows.count - 1].lineEnding = last }
    }

    /// How this row pads its cells, else how the header does, else one space each side.
    func padding(for row: Row) -> Padding {
        Self.evidence(in: row) ?? Self.evidence(in: header) ?? Padding(lead: " ", trail: " ")
    }

    /// The padding of the first filled cell that has a pipe on that side. Nil if no cell says.
    static func evidence(in row: Row) -> Padding? {
        var lead: String?
        var trail: String?
        for (k, cell) in row.cells.enumerated() where !cell.raw.isEmpty {
            if lead == nil && (k > 0 || row.leadingPipe) { lead = cell.leading.isEmpty ? "" : " " }
            if trail == nil && (k < row.cells.count - 1 || row.trailingPipe) { trail = cell.trailing.isEmpty ? "" : " " }
        }
        if lead == nil && trail == nil { return nil }
        return Padding(lead: lead ?? " ", trail: trail ?? " ")
    }

    /// One line of an edited table, without its ending. A row nothing changed is its original bytes. A changed row
    /// is written from its parts, and then read back: if that reading would differ (a first cell that starts a list or
    /// a heading, an empty last cell taken for a closing pipe, a header that lost its last pipe, an empty first header
    /// cell whose spaces push the row to 4 columns of indent), the row is written again with pipes at both ends, which
    /// always reads back right.
    static func line(_ row: Row, kind: Kind) -> String {
        if let original = row.original { return original }
        let plain = parts(row, forcePipes: false)
        if readsBack(plain, as: row, kind: kind) { return plain }
        return parts(row, forcePipes: true)
    }

    static func parts(_ row: Row, forcePipes: Bool) -> String {
        let leadingPipe = row.leadingPipe || forcePipes
        let trailingPipe = row.trailingPipe || forcePipes
        var out = row.indent
        if leadingPipe { out += "|" }
        for (k, cell) in row.cells.enumerated() {
            if k > 0 { out += "|" }
            var leading = cell.leading
            if k == 0 && !row.leadingPipe && forcePipes && leading.isEmpty { leading = " " }
            out += leading + cell.raw
            var trailing = cell.trailing
            let isLast = k == row.cells.count - 1
            if isLast && !row.trailingPipe && forcePipes && trailing.isEmpty { trailing = " " }
            // A backslash right before a pipe would hide the pipe.
            if (!isLast || trailingPipe) && trailing.isEmpty && cell.raw.utf8.last == TableSyntax.backslash { trailing = " " }
            out += trailing
        }
        if trailingPipe { out += "|" + (row.trailingPipe ? row.trail : "") }
        return out
    }

    static func readsBack(_ line: String, as row: Row, kind: Kind) -> Bool {
        let bytes = Array(line.utf8)[...]
        if TableSyntax.isBlank(bytes) { return false }
        let (columns, at) = TableSyntax.indent(bytes)
        // Padding that ran into the indent could make any row code, which ends the table.
        if columns > 3 || TableSyntax.startsBlock(bytes[at...]) || TableSyntax.isLonePipe(bytes[at...]) { return false }
        let parsed = TableSyntax.parseRow(bytes, lineEnding: "")
        // A header or delimiter row needs a pipe.
        if kind != .body && parsed.pipes == 0 { return false }
        guard parsed.row.cells.count == row.cells.count else { return false }
        for (a, b) in zip(parsed.row.cells, row.cells) where !a.raw.utf8.elementsEqual(b.raw.utf8) { return false }
        return true
    }
}

extension MarkdownTable.Row {
    /// A cell for this row at `column` of `count`. No padding against a missing outer pipe; an empty cell gets one space.
    func newCell(raw: String, at column: Int, of count: Int, padding: MarkdownTable.Padding) -> MarkdownTable.Cell {
        if raw.isEmpty {
            let open = (column == 0 && !leadingPipe) || (column == count - 1 && !trailingPipe)
            return MarkdownTable.Cell(leading: open || (padding.lead.isEmpty && padding.trail.isEmpty) ? "" : " ", raw: "", trailing: "")
        }
        return MarkdownTable.Cell(
            leading: column == 0 && !leadingPipe ? "" : padding.lead,
            raw: raw,
            trailing: column == count - 1 && !trailingPipe ? "" : padding.trail
        )
    }

    /// Sets a cell's text. False if it already said exactly that, and then nothing changes.
    mutating func setText(_ text: String, at column: Int, padding: MarkdownTable.Padding) -> Bool {
        let raw = TableSyntax.escape(text)
        var cell = cells[column]
        if cell.raw.utf8.elementsEqual(raw.utf8) { return false }
        if cell.raw.isEmpty {
            // An empty cell's spaces say little about where the content goes, so it takes the row's padding.
            cell = newCell(raw: raw, at: column, of: cells.count, padding: padding)
        } else {
            cell.raw = raw
        }
        cells[column] = cell
        original = nil
        return true
    }

    mutating func appendEmptyCell(padding: MarkdownTable.Padding) {
        insertCell(raw: "", at: cells.count, padding: padding)
    }

    mutating func insertCell(raw: String, at column: Int, padding: MarkdownTable.Padding) {
        let cell = newCell(raw: raw, at: column, of: cells.count + 1, padding: padding)
        if !cells.isEmpty {
            // The cell that was first or last now has a pipe on that side, so it gets padding there.
            if column == 0 && !leadingPipe && cells[0].leading.isEmpty { cells[0].leading = padding.lead }
            if column == cells.count && !trailingPipe && cells[cells.count - 1].trailing.isEmpty {
                cells[cells.count - 1].trailing = padding.trail
            }
        }
        cells.insert(cell, at: column)
        original = nil
    }

    mutating func removeCell(at column: Int) {
        cells.remove(at: column)
        if cells.isEmpty {
            cells = [MarkdownTable.Cell(leading: "", raw: "", trailing: "")]
        } else {
            // The new first or last cell has no pipe on that side any more, so no padding there.
            if column == 0 && !leadingPipe { cells[0].leading = "" }
            if column == cells.count && !trailingPipe { cells[cells.count - 1].trailing = "" }
        }
        original = nil
    }
}
