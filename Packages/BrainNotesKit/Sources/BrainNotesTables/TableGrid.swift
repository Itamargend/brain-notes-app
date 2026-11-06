// The table as the editor's grid shows it: row 0 is the header row, row 1 the first body row, and there are as many
// columns as the widest row needs, so a cell a ragged row has past the header is on screen and can't be lost. Everything
// here is built on `MarkdownTable`'s own edits, so a well-formed table still changes one line for one cell.

extension MarkdownTable {
    /// The header row and the body rows.
    public var gridRowCount: Int { rows.count + 1 }

    /// The header's columns, and more if a body row has more cells than that.
    public var gridColumnCount: Int { rows.reduce(columnCount) { max($0, $1.cells.count) } }

    /// Every row has exactly one cell per column of the header.
    public var isRectangular: Bool { rows.allSatisfy { $0.cells.count == columnCount } }

    /// What a grid cell says, or "" where its row has no such cell.
    public func gridText(row: Int, column: Int) -> String {
        guard column >= 0 else { return "" }
        if row == 0 { return header.cells.indices.contains(column) ? header.cells[column].text : "" }
        return text(row: row - 1, column: column)
    }

    /// A column's alignment. A column past the header's has none.
    public func gridAlignment(column: Int) -> Alignment {
        let all = alignments
        return all.indices.contains(column) ? all[column] : .none
    }

    /// The direction the table's own text gives it: that of the header, else of the body, in reading order. Nil if no
    /// cell has a strong character yet, as in a table just inserted.
    public var statedRightToLeft: Bool? {
        if let stated = TableSyntax.strongDirection(header.cells.map(\.text).joined(separator: " ")) { return stated }
        for row in rows {
            if let stated = TableSyntax.strongDirection(row.cells.map(\.text).joined(separator: " ")) { return stated }
        }
        return nil
    }

    /// The direction of one cell's text, nil if it has no strong character yet.
    public static func statedRightToLeft(ofText text: String) -> Bool? { TableSyntax.strongDirection(text) }

    /// What a cell would say after being set to this text: one line, no spaces at the ends.
    public static func cellText(forTyped text: String) -> String {
        TableSyntax.unescape(TableSyntax.escape(text))
    }

    /// Makes a ragged table rectangular, and changes nothing about any other. A row with more cells than the header gives
    /// the header and the delimiter row what they are missing, so that what GitHub ignores becomes a real column and no
    /// text goes unseen. A short row gets the empty cells it reads as anyway. Rows that are already right keep their bytes.
    public mutating func normalizeShape() {
        let width = gridColumnCount
        if columnCount < width {
            let headerPadding = padding(for: header)
            let delimiterPadding = Self.evidence(in: delimiter) ?? headerPadding
            while header.cells.count < width {
                header.insertCell(raw: "", at: header.cells.count, padding: headerPadding)
                delimiter.insertCell(raw: TableSyntax.marker(.none), at: delimiter.cells.count, padding: delimiterPadding)
            }
            isEdited = true
        }
        for r in rows.indices where rows[r].cells.count < width {
            let pad = padding(for: rows[r])
            while rows[r].cells.count < width { rows[r].appendEmptyCell(padding: pad) }
            isEdited = true
        }
    }

    /// Sets what a grid cell says.
    public mutating func setGridText(row: Int, column: Int, to text: String) throws {
        guard row >= 0, row < gridRowCount else { throw EditError.noSuchRow(row) }
        guard column >= 0, column < gridColumnCount else { throw EditError.noSuchColumn(column) }
        normalizeShape()
        if row == 0 {
            try setHeader(column: column, to: text)
        } else {
            try setCell(row: row - 1, column: column, to: text)
        }
    }

    /// Inserts an empty row at `index` of the grid. Above the header (0), the new row is the header and the old header
    /// moves down to be the first body row, since a table has to have a header row.
    public mutating func insertGridRow(at index: Int) throws {
        guard index >= 0, index <= gridRowCount else { throw EditError.noSuchRow(index) }
        normalizeShape()
        guard index == 0 else { return try insertRow(at: index - 1) }
        let moved = headerTexts
        try insertRow(at: 0, texts: moved)
        for column in moved.indices { try setHeader(column: column, to: "") }
    }

    /// Removes a row of the grid. Taking out the header promotes the first body row to it. The last row can't go: a
    /// table has to have a header row, and deleting that is deleting the table.
    public mutating func removeGridRow(at index: Int) throws {
        guard index >= 0, index < gridRowCount else { throw EditError.noSuchRow(index) }
        guard gridRowCount > 1 else { throw EditError.lastRow }
        guard index == 0 else { return try removeRow(at: index - 1) }
        normalizeShape()
        let promoted = rows[0].texts
        for column in promoted.indices { try setHeader(column: column, to: promoted[column]) }
        try removeRow(at: 0)
    }

    /// Inserts an empty column at `index` of the grid, in every row.
    public mutating func insertGridColumn(at index: Int) throws {
        guard index >= 0, index <= gridColumnCount else { throw EditError.noSuchColumn(index) }
        normalizeShape()
        try insertColumn(at: index)
    }

    /// Removes a column of the grid, from every row. The last one can't go.
    public mutating func removeGridColumn(at index: Int) throws {
        guard index >= 0, index < gridColumnCount else { throw EditError.noSuchColumn(index) }
        normalizeShape()
        try removeColumn(at: index)
    }

    /// A new, empty table's Markdown, as many lines as `rows` counts the header among them, with no line ending after
    /// the last.
    public static func blankMarkdown(columns: Int, rows: Int, lineEnding: String = "\n") -> String {
        let width = max(columns, 1)
        let empty = "|" + String(repeating: "   |", count: width)
        let delimiter = "|" + String(repeating: "---|", count: width)
        var lines = [empty, delimiter]
        lines += Array(repeating: empty, count: max(rows, 1) - 1)
        return lines.joined(separator: lineEnding)
    }
}
