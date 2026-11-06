import BrainNotesKit
import Foundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Tables in the editor, as in Notes: a table is always a real grid, and its pipes are never on screen. The note's text
// view keeps the table's source, byte for byte, hidden: its first line is as tall as the grid (`MarkdownStyler.hideTables`)
// and a native grid view sits there as a subview of the text view, scrolling with it. A cell edit is one replacement in
// that source, through the text view, so the file, the autosave, the sync and the merge see what they always saw.
//
// This file is what both platforms share: the sizes of a grid, and `TableOverlay`, which keeps the grids in step with the
// text and turns what happens in them into edits. The views are in `TableGridUIKit.swift` and `TableGridAppKit.swift`.

enum TableGridMetrics {
    static let cellPaddingX: CGFloat = 8
    static let cellPaddingY: CGFloat = 8
    static let minimumColumn: CGFloat = 76
    static let cornerRadius: CGFloat = 8
    /// Room above a grid for the column handle, which sits on its top edge.
    static let marginAbove: CGFloat = 14
    /// Room below a grid for the add-row button, which sits on its bottom edge, and air before the next line.
    static let marginBelow: CGFloat = 24
    /// What a handle and a plus button look like, and what can be pressed. Targets are at least 44 points.
    static let handleLong: CGFloat = 30
    static let handleShort: CGFloat = 18
    static let plusSize: CGFloat = 26
    static let target: CGFloat = 44
    /// How far a handle or a plus button overlaps the grid: less than a cell's padding, so that it never covers text.
    static let overlap: CGFloat = 6
    #if os(iOS)
    static let minimumRow: CGFloat = 44
    #else
    static let minimumRow: CGFloat = 30
    #endif
}

/// A cell of a grid: row 0 is the header.
struct GridCell: Hashable {
    var row: Int
    var column: Int
}

/// A cell of one of the note's tables.
struct TableCellAddress: Hashable {
    var table: Int
    var cell: GridCell
}

/// A grid's sizes. Columns come in the table's own order; the right-to-left mirroring is in the frames.
struct TableGridGeometry: Equatable {
    var columnWidths: [CGFloat] = []
    var rowHeights: [CGFloat] = []

    var totalWidth: CGFloat { columnWidths.reduce(0, +) }
    var totalHeight: CGFloat { rowHeights.reduce(0, +) }
    /// What the table's first line reserves in the text.
    var reservedHeight: CGFloat { TableGridMetrics.marginAbove + totalHeight + TableGridMetrics.marginBelow }

    /// A cell's frame, from the grid's own top left corner. In a right-to-left table the first column is on the right.
    func cellFrame(_ cell: GridCell, rightToLeft: Bool) -> CGRect {
        guard columnWidths.indices.contains(cell.column), rowHeights.indices.contains(cell.row) else { return .zero }
        let before = columnWidths[..<cell.column].reduce(0, +)
        let x = rightToLeft ? totalWidth - before - columnWidths[cell.column] : before
        return CGRect(x: x, y: rowHeights[..<cell.row].reduce(0, +), width: columnWidths[cell.column], height: rowHeights[cell.row])
    }

    /// The cell at a point, from the grid's own top left corner.
    func cell(at point: CGPoint, rightToLeft: Bool) -> GridCell? {
        guard point.x >= 0, point.y >= 0, point.x < totalWidth, point.y < totalHeight else { return nil }
        var y: CGFloat = 0
        guard let row = rowHeights.firstIndex(where: { y += $0; return point.y < y }) else { return nil }
        var x: CGFloat = 0
        let logical = rightToLeft ? totalWidth - point.x : point.x
        guard let column = columnWidths.firstIndex(where: { x += $0; return logical < x || (rightToLeft && logical <= x) }) else { return nil }
        return GridCell(row: row, column: column)
    }

    /// Column widths for what each column would like, in the room there is. If everything fits, what is left over is
    /// shared out evenly. If it doesn't, the narrow columns keep what they want and the wide ones share the rest, down to
    /// a width that still reads, and past that the grid scrolls sideways.
    static func columnWidths(ideal: [CGFloat], available: CGFloat, minimum: CGFloat = TableGridMetrics.minimumColumn) -> [CGFloat] {
        guard !ideal.isEmpty else { return [] }
        let count = CGFloat(ideal.count)
        let wanted = ideal.map { max($0, minimum) }
        let total = wanted.reduce(0, +)
        let widths: [CGFloat]
        if total <= available {
            let extra = (available - total) / count
            widths = wanted.map { $0 + extra }
        } else if minimum * count >= available {
            // No room for them all: it scrolls, and one long cell still doesn't push the others far away.
            let cap = max(minimum, available * 0.6)
            return wanted.map { ceil(min($0, cap)) }
        } else {
            var left = available
            var open = count
            var cap = available / count
            for width in wanted.sorted() {
                let share = left / open
                if width > share {
                    cap = share
                    break
                }
                cap = share
                left -= width
                open -= 1
            }
            widths = wanted.map { min($0, cap) }
        }
        // On whole points, for crisp lines, with the last one taking what rounding left over.
        var out = widths.map { floor($0) }
        out[out.count - 1] += max(available - out.reduce(0, +), 0)
        return out
    }
}

/// What a person can do to a table from its handles and menus.
enum TableCommand: String, CaseIterable {
    case addRowAbove, addRowBelow, addColumnBefore, addColumnAfter, deleteRow, deleteColumn, deleteTable, addLineAbove

    var title: String {
        switch self {
        case .addRowAbove: "Add Row Above"
        case .addRowBelow: "Add Row Below"
        case .addColumnBefore: "Add Column Before"
        case .addColumnAfter: "Add Column After"
        case .deleteRow: "Delete Row"
        case .deleteColumn: "Delete Column"
        case .deleteTable: "Delete Table"
        case .addLineAbove: "Add Line Above Table"
        }
    }

    var symbol: String {
        switch self {
        case .addRowAbove: "arrow.up.to.line"
        case .addRowBelow: "arrow.down.to.line"
        case .addColumnBefore: "arrow.left.to.line"
        case .addColumnAfter: "arrow.right.to.line"
        case .deleteRow: "minus.rectangle"
        case .deleteColumn: "minus.rectangle.portrait"
        case .deleteTable: "trash"
        case .addLineAbove: "text.line.first.and.arrowtriangle.forward"
        }
    }

    var isDestructive: Bool { self == .deleteRow || self == .deleteColumn || self == .deleteTable }

    static let rowMenu: [TableCommand] = [.addRowAbove, .addRowBelow, .deleteRow, .deleteTable]
    static let columnMenu: [TableCommand] = [.addColumnBefore, .addColumnAfter, .deleteColumn, .deleteTable]
    static let cellMenu: [TableCommand] = [.addRowAbove, .addRowBelow, .addColumnBefore, .addColumnAfter, .deleteRow, .deleteColumn, .deleteTable]
}

/// Everything a grid view needs in order to look right.
struct TableGridState: Equatable {
    var table: MarkdownTable
    var geometry: TableGridGeometry
    var rightToLeft: Bool
    /// The cell being edited, if it is in this grid.
    var focus: GridCell?
    /// Where the note's text starts and how wide the text view is: the grid lines up with the text.
    var textLeft: CGFloat
    var width: CGFloat

    var isScrollable: Bool { textLeft * 2 + geometry.totalWidth > width + 0.5 }

    /// The row handle, on the table's leading edge, for a row of this frame in the scrolling content.
    func rowHandleFrame(forCell frame: CGRect, plate: CGRect) -> CGRect {
        let long = TableGridMetrics.handleLong, short = TableGridMetrics.handleShort, overlap = TableGridMetrics.overlap
        let x = rightToLeft ? plate.maxX - overlap : plate.minX + overlap - short
        return CGRect(x: x, y: frame.midY - long / 2, width: short, height: long)
    }

    /// The column handle, on the table's top edge.
    func columnHandleFrame(forCell frame: CGRect, plate: CGRect) -> CGRect {
        let long = TableGridMetrics.handleLong, short = TableGridMetrics.handleShort
        return CGRect(x: frame.midX - long / 2, y: plate.minY + TableGridMetrics.overlap - short, width: long, height: short)
    }

    /// The plus buttons, for a plate in the grid view's coordinates. They stay in sight when the grid scrolls sideways: on
    /// the table's edge, or the view's.
    func plusFrames(plate: CGRect) -> (addRow: CGRect, addColumn: CGRect) {
        let size = TableGridMetrics.plusSize, overlap = TableGridMetrics.overlap
        let minX = plate.minX < 0 ? size / 2 + 4 : plate.minX
        let maxX = plate.maxX > width ? width - size / 2 - 4 : plate.maxX
        let addRow = CGRect(x: (minX + maxX) / 2 - size / 2, y: plate.maxY - overlap, width: size, height: size)
        // A new column goes after the last one, which in a right-to-left table is on the left. Not past the view's edge.
        let x = rightToLeft ? max(minX - size + overlap, 0) : min(maxX - overlap, width - size)
        return (addRow, CGRect(x: x, y: plate.midY - size / 2, width: size, height: size))
    }
    /// The grid's top left corner in the grid view's scrolling content.
    var plateOrigin: CGPoint { CGPoint(x: textLeft, y: TableGridMetrics.marginAbove) }
    var contentWidth: CGFloat { max(width, textLeft * 2 + geometry.totalWidth) }

    /// How far up to show when bringing a cell into view: from the table's top edge, where its column handle is, if the
    /// cell still fits on screen that way, and otherwise from just above the cell.
    static func revealTop(cell: CGRect, plateTop: CGFloat, room: CGFloat) -> CGFloat {
        let fromTable = plateTop - TableGridMetrics.marginAbove
        let fits = cell.maxY + TableGridMetrics.marginBelow - fromTable <= room
        return fits ? fromTable : cell.minY - TableGridMetrics.marginAbove
    }

    /// What VoiceOver says for the whole grid.
    var label: String { "Table, \(table.gridColumnCount) columns, \(table.gridRowCount) rows" }

    /// What VoiceOver says for a cell: where it is. Its text is its value.
    func label(of cell: GridCell) -> String {
        let column = "column \(cell.column + 1)"
        if cell.row == 0 { return "Header, \(column)" }
        let header = table.gridText(row: 0, column: cell.column)
        return header.isEmpty ? "Row \(cell.row), \(column)" : "Row \(cell.row), \(column), \(header)"
    }

    static func identifier(of cell: GridCell) -> String { "editor.table.cell.\(cell.row).\(cell.column)" }
}

/// One step on the undo stack for a table: the text before and after, and which cell had the focus. A run of typing in one
/// cell is one step, as typing in the note is, so this stays open while it goes on.
@MainActor
final class TableUndoStep {
    let start: Int
    let before: String
    var after: String
    let focusBefore: TableCellAddress?
    var focusAfter: TableCellAddress?

    init(start: Int, before: String, after: String, focusBefore: TableCellAddress?, focusAfter: TableCellAddress?) {
        self.start = start
        self.before = before
        self.after = after
        self.focusBefore = focusBefore
        self.focusAfter = focusAfter
    }
}

/// What undo steps are registered on. No state: only an identity, to take them all off again.
final class TableUndoTarget: Sendable {}

/// The cell with the focus, before a sync replaces the note's text.
struct ReloadFocus {
    var address: TableCellAddress
    var source: String
    var tableCount: Int
}

/// Where the focus goes from a cell.
enum TableMove {
    /// Return and Tab: on through the cells, adding a row at the very end.
    case next
    case previous
    case up, down
    /// By what is on screen: in a right-to-left table, left is forward.
    case left, right
}

/// Where the caret goes in a cell that takes the focus.
enum TableCaret {
    case start, end
    /// Where the finger or the pointer came down, in the editor's own coordinates.
    case point(CGPoint)
}

/// One editor's grids. It sees the text through `LivePreview`, which looks for the tables as the text changes, and it is the
/// only one that writes a table.
@MainActor
final class TableOverlay: NSObject {
    private(set) weak var textView: EditorTextView?
    let preview: LivePreview
    /// Called when a cell takes or loses the focus.
    var focusChanged: (() -> Void)?

    private(set) var grids: [TableGridView] = []
    private(set) var focus: TableCellAddress?
    /// While a table has the focus its columns keep their widths, or the whole grid would shift under each keystroke.
    private var frozen: (table: Int, widths: [CGFloat])?
    /// The open run of typing.
    private var run: TableUndoStep?
    /// The note is being changed from here, and what it says about that isn't news.
    private(set) var isApplying = false
    /// A cell's editor is giving up the focus. UIKit hands it to the view around the editor, the note's text view, if that
    /// will take it, and then the keyboard stays. A cell that ends doesn't mean that.
    var isEditorResigning = false
    private var isLayingOut = false
    private var isLoadingEditor = false
    private var knownTextWidth: CGFloat = 0
    /// The note's selection as it last settled: where a caret arriving in a table came from.
    private var lastSelection: NSRange?
    /// What undo steps hang on, kept alive by the steps themselves: a manager doesn't keep its targets.
    private let undoTarget = TableUndoTarget()
    private weak var undoManagerInUse: UndoManager?

    private var painter = MarkdownStyler.CellPainter()
    private var measured: [MeasureKey: CGSize] = [:]
    /// The last size of each grid. Layout asks at every tick of a scroll.
    private var knownGeometry: [Int: (key: GeometryKey, geometry: TableGridGeometry)] = [:]

    private struct MeasureKey: Hashable {
        var text: String
        var isHeader: Bool
        var showsMarks: Bool
        /// 0 for the width it would like on one line.
        var width: CGFloat
    }

    private struct GeometryKey: Equatable {
        var table: MarkdownTable
        var focused: GridCell?
        var frozen: [CGFloat]?
        var available: CGFloat
    }

    var spans: [MarkdownStyler.TableSpan] { preview.context.tables }
    var tableRanges: [NSRange] { spans.map(\.range) }
    var kitSpans: [TableEdits.Span] { spans.map { TableEdits.Span(range: $0.range, table: $0.table) } }
    var hasFocus: Bool { focus != nil }

    init(textView: EditorTextView, preview: LivePreview) {
        self.textView = textView
        self.preview = preview
        super.init()
        preview.tableHeight = { [weak self] table, index in
            self?.geometry(of: table, index: index).reservedHeight ?? MarkdownStyler.estimatedTableHeight(table)
        }
    }

    /// Steps this editor left on the window's undo stack can't outlive it: they would have nothing to work on.
    isolated deinit {
        undoManagerInUse?.removeAllActions(withTarget: undoTarget)
    }

    // MARK: sizes

    private var textWidth: CGFloat {
        guard let container = textView?.noteContainer else { return 320 }
        let width = container.size.width - 2 * container.lineFragmentPadding
        return width > 1 && width < 100_000 ? width : 320
    }

    private func size(of text: String, isHeader: Bool, showsMarks: Bool, width: CGFloat) -> CGSize {
        let key = MeasureKey(text: text, isHeader: isHeader, showsMarks: showsMarks, width: width)
        if let known = measured[key] { return known }
        if measured.count > 20_000 { measured.removeAll() }
        let painted = painter.text(text, isHeader: isHeader, showsMarks: showsMarks, alignment: .none, tableRightToLeft: false)
        let bounds = CGSize(width: width > 0 ? width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        var size = painted.boundingRect(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        size.width = ceil(size.width)
        size.height = max(ceil(size.height), ceil(painter.lineHeight))
        measured[key] = size
        return size
    }

    func geometry(of table: MarkdownTable, index: Int) -> TableGridGeometry {
        let rows = table.gridRowCount
        let columns = table.gridColumnCount
        let padX = TableGridMetrics.cellPaddingX, padY = TableGridMetrics.cellPaddingY
        let focused = focus?.table == index ? focus?.cell : nil
        let available = textWidth
        let keptWidths = focused != nil && frozen?.table == index && frozen?.widths.count == columns ? frozen?.widths : nil
        let key = GeometryKey(table: table, focused: focused, frozen: keptWidths, available: available)
        if let known = knownGeometry[index], known.key == key {
            if focused != nil { frozen = (index, known.geometry.columnWidths) }
            return known.geometry
        }
        func cell(_ r: Int, _ c: Int) -> (text: String, isHeader: Bool, showsMarks: Bool) {
            (table.gridText(row: r, column: c), r == 0, focused == GridCell(row: r, column: c))
        }
        var widths: [CGFloat]
        if let keptWidths {
            widths = keptWidths
        } else {
            var ideal = [CGFloat](repeating: 0, count: columns)
            for r in 0..<rows {
                for c in 0..<columns {
                    let found = cell(r, c)
                    // Without its marks, always: a cell taking the focus doesn't move the columns.
                    ideal[c] = max(ideal[c], size(of: found.text, isHeader: found.isHeader, showsMarks: false, width: 0).width + 2 * padX + 1)
                }
            }
            widths = TableGridGeometry.columnWidths(ideal: ideal, available: available)
        }
        if focused != nil { frozen = (index, widths) }
        var heights = [CGFloat](repeating: TableGridMetrics.minimumRow, count: rows)
        for r in 0..<rows {
            for c in 0..<columns {
                let found = cell(r, c)
                let text = size(of: found.text, isHeader: found.isHeader, showsMarks: found.showsMarks, width: widths[c] - 2 * padX)
                heights[r] = max(heights[r], text.height + 2 * padY)
            }
        }
        let geometry = TableGridGeometry(columnWidths: widths, rowHeights: heights)
        knownGeometry[index] = (key, geometry)
        return geometry
    }

    private func state(of index: Int) -> TableGridState? {
        guard spans.indices.contains(index), let view = textView else { return nil }
        let span = spans[index]
        return TableGridState(table: span.table,
                              geometry: geometry(of: span.table, index: index),
                              rightToLeft: span.rightToLeft,
                              focus: focus?.table == index ? focus?.cell : nil,
                              textLeft: view.textLeftEdge,
                              width: view.bounds.width)
    }

    // MARK: keeping up with the text

    /// The note's text changed, or was loaded. Call after `LivePreview` has seen it.
    func tablesChanged() {
        let count = spans.count
        while grids.count > count { grids.removeLast().removeFromSuperview() }
        while grids.count < count {
            guard let view = textView else { return }
            let grid = TableGridView(overlay: self, index: grids.count)
            view.addGridView(grid)
            grids.append(grid)
        }
        if let focus {
            if focus.table >= count {
                loseFocus()
            } else {
                let table = spans[focus.table].table
                let cell = GridCell(row: min(focus.cell.row, table.gridRowCount - 1), column: min(focus.cell.column, table.gridColumnCount - 1))
                self.focus = TableCellAddress(table: focus.table, cell: cell)
                syncEditor()
            }
        }
        layoutGrids()
        textView?.gridsNeedLayout()
    }

    /// The cell with the focus, by what its table said, for before the note's whole text is replaced from outside.
    func focusBeforeReload() -> ReloadFocus? {
        guard let focus, spans.indices.contains(focus.table) else { return nil }
        return ReloadFocus(address: focus, source: spans[focus.table].table.source, tableCount: spans.count)
    }

    /// The whole text was replaced, by a sync. Undo steps went with the old text, so typing starts a new one. The focus stays
    /// with its table: found by what it says, or at the same place if there are as many tables as before, and otherwise it
    /// goes back to the note rather than to some other table.
    func tablesReloaded(from was: ReloadFocus?) {
        closeRun()
        lastSelection = nil
        guard let was else { return tablesChanged() }
        let fresh = spans
        let same = fresh.indices.filter { fresh[$0].table.source.utf8.elementsEqual(was.source.utf8) }
        let found = same.min { abs($0 - was.address.table) < abs($1 - was.address.table) }
        let target = found ?? (fresh.count == was.tableCount ? was.address.table : nil)
        if target == was.address.table { return tablesChanged() }
        focus = nil
        frozen = nil
        if grids.indices.contains(was.address.table) { grids[was.address.table].hideEditor() }
        tablesChanged()
        focusChanged?()
        if let target {
            focusCell(TableCellAddress(table: target, cell: was.address.cell), caret: .end)
        } else {
            textView?.focusNote()
        }
    }

    /// Puts each grid near what is on screen over its table's first line. Grids further away wait until they get near.
    func layoutGrids() {
        guard !isLayingOut, let view = textView, let manager = view.textLayoutManager, let content = manager.textContentManager else { return }
        // With no width yet there is nothing to lay out against, and asking would lay out the whole note for nothing.
        guard !spans.isEmpty, view.bounds.width > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let width = textWidth
        if abs(width - knownTextWidth) > 0.5 {
            let isFirst = knownTextWidth == 0
            knownTextWidth = width
            frozen = nil
            // Not from inside a layout pass, and at once if nothing has been laid out for the old width yet.
            if isFirst {
                preview.refreshTableHeights()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.preview.refreshTableHeights()
                    self?.textView?.gridsNeedLayout()
                }
            }
        }
        let start = content.documentRange.location
        // Before the first layout there is no viewport: only the note's start can be on screen.
        var visible = 0..<20_000
        if let viewport = manager.textViewportLayoutController.viewportRange {
            let from = content.offset(from: start, to: viewport.location)
            let to = content.offset(from: start, to: viewport.endLocation)
            visible = (from - 2_000)..<(to + 2_000)
        }
        for index in spans.indices where index < grids.count {
            let span = spans[index]
            let grid = grids[index]
            grid.index = index
            let isNear = span.range.location < visible.upperBound && NSMaxRange(span.range) > visible.lowerBound
            guard isNear || focus?.table == index, let location = content.location(start, offsetBy: span.range.location) else {
                grid.isHidden = true
                continue
            }
            var fragment: CGRect?
            manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { found in
                fragment = found.layoutFragmentFrame
                return false
            }
            guard let fragment, let state = state(of: index) else { continue }
            grid.isHidden = false
            grid.frame = CGRect(x: 0, y: view.textTopEdge + fragment.minY, width: view.bounds.width, height: state.geometry.reservedHeight)
            grid.render(state, painter: painter)
        }
    }

    /// The text size or Bold Text changed: everything is measured again.
    func fontsChanged() {
        painter = MarkdownStyler.CellPainter()
        measured.removeAll()
        knownGeometry.removeAll()
        frozen = nil
        for grid in grids { grid.forgetText() }
        preview.refreshTableHeights()
        layoutGrids()
        textView?.gridsNeedLayout()
    }

    // MARK: the caret on the note

    /// What the note's selection has to do now that it has changed. Nil: nothing. Otherwise it moved, and this call comes
    /// back, or a cell took the focus.
    func settleSelection(_ selection: NSRange, isFirstResponder: Bool) -> NSRange? {
        guard !isApplying, !spans.isEmpty else {
            if !isApplying { lastSelection = selection }
            return nil
        }
        switch TableEdits.caret(selection, previous: lastSelection, tables: tableRanges) {
        case .stays:
            lastSelection = selection
            showSelection(selection)
            return nil
        case let .moves(range):
            return range
        case let .enters(table, atStart):
            guard isFirstResponder else {
                return NSRange(location: NSMaxRange(spans[table].range), length: 0)
            }
            enter(table: table, atStart: atStart)
            return nil
        }
    }

    /// A selection that holds a table holds all of it, and the grid shows it: its source has nothing to highlight.
    private func showSelection(_ selection: NSRange) {
        for (index, span) in spans.enumerated() where index < grids.count {
            grids[index].isInSelection = selection.length > 0 && TableEdits.touches(selection, tables: [span.range])
        }
    }

    /// Into a table from outside it, by the keyboard.
    func enter(table index: Int, atStart: Bool) {
        guard spans.indices.contains(index) else { return }
        let table = spans[index].table
        let cell = atStart ? GridCell(row: 0, column: 0) : GridCell(row: table.gridRowCount - 1, column: table.gridColumnCount - 1)
        focusCell(TableCellAddress(table: index, cell: cell), caret: atStart ? .start : .end)
    }

    // MARK: the focus

    /// The cell's editor takes the focus, showing that cell's text.
    func focusCell(_ address: TableCellAddress, caret: TableCaret) {
        guard spans.indices.contains(address.table) else { return }
        finishComposition()
        closeRun()
        let previous = focus
        if let previous, previous.table != address.table, grids.indices.contains(previous.table) {
            grids[previous.table].hideEditor()
        }
        focus = address
        if previous?.table != address.table { frozen = nil }
        let index = address.table
        preview.refreshTableHeights()
        layoutGrids()
        grids[index].isHidden = false
        guard let editor = grids[index].showEditor(at: address.cell) else { return }
        loadEditor(editor, cell: address.cell)
        editor.beginEditingCell()
        place(caret, in: editor)
        moveNoteSelectionOutOfTable(index)
        focusChanged?()
        revealFocus()
    }

    /// The note's selection stays somewhere it may rest, for when the note has the focus again.
    private func moveNoteSelectionOutOfTable(_ index: Int) {
        guard let view = textView, spans.indices.contains(index), TableEdits.touches(view.noteSelection, tables: [spans[index].range]) else { return }
        isApplying = true
        defer { isApplying = false }
        let after = NSRange(location: NSMaxRange(spans[index].range), length: 0)
        view.setNoteSelection(after)
        lastSelection = after
    }

    private func place(_ caret: TableCaret, in editor: TableCellEditor) {
        switch caret {
        case .start: editor.cellSelection = NSRange(location: 0, length: 0)
        case .end: editor.cellSelection = NSRange(location: (editor.cellText as NSString).length, length: 0)
        case let .point(point): editor.placeCaret(at: point)
        }
    }

    /// The editor shows the model's text for this cell.
    private func loadEditor(_ editor: TableCellEditor, cell: GridCell) {
        guard let focus, spans.indices.contains(focus.table) else { return }
        let span = spans[focus.table]
        isLoadingEditor = true
        defer { isLoadingEditor = false }
        editor.cellText = span.table.gridText(row: cell.row, column: cell.column)
        styleEditor(editor, cell: cell)
    }

    private func styleEditor(_ editor: TableCellEditor, cell: GridCell) {
        guard let focus, spans.indices.contains(focus.table) else { return }
        let span = spans[focus.table]
        let text = editor.cellText
        let isHeader = cell.row == 0
        let alignment = span.table.gridAlignment(column: cell.column)
        let paragraph = painter.paragraph(text: text, alignment: alignment, tableRightToLeft: span.rightToLeft)
        editor.applyLook(painter.text(text, isHeader: isHeader, showsMarks: true, alignment: alignment, tableRightToLeft: span.rightToLeft),
                         typing: painter.attributes(isHeader: isHeader, paragraph: paragraph))
    }

    /// Text still being composed isn't in the file yet, and the editor is about to show something else.
    private func finishComposition() {
        guard let focus, grids.indices.contains(focus.table), let editor = grids[focus.table].editor, editor.isComposing else { return }
        editor.endComposing()
        editorChanged(editor)
    }

    /// After an undo or a sync: the editor can't be saying anything but what the file says.
    private func syncEditor() {
        guard let focus, grids.indices.contains(focus.table), let editor = grids[focus.table].showEditor(at: focus.cell), !editor.isComposing else { return }
        let model = spans[focus.table].table.gridText(row: focus.cell.row, column: focus.cell.column)
        if MarkdownTable.cellText(forTyped: editor.cellText) != MarkdownTable.cellText(forTyped: model) {
            let caret = min(editor.cellSelection.location, (model as NSString).length)
            loadEditor(editor, cell: focus.cell)
            editor.cellSelection = NSRange(location: caret, length: 0)
        }
    }

    /// The focus left the cell. The columns are free again, so the grid may settle into new widths.
    func endFocus() {
        guard let ended = focus else { return }
        finishComposition()
        closeRun()
        focus = nil
        frozen = nil
        if grids.indices.contains(ended.table) { grids[ended.table].hideEditor() }
        preview.refreshTableHeights()
        layoutGrids()
        textView?.gridsNeedLayout()
        focusChanged?()
    }

    /// The table with the focus is gone, as after undoing its insertion. The note takes the focus back.
    private func loseFocus() {
        let wasEditing = focus != nil
        focus = nil
        frozen = nil
        closeRun()
        focusChanged?()
        guard wasEditing, let view = textView else { return }
        view.focusNote()
    }

    /// The editor gave up the focus, by a tap on the note or by Done.
    func editorEnded(_ editor: TableCellEditor) {
        guard let focus, grids.indices.contains(focus.table), grids[focus.table].editor === editor else { return }
        endFocus()
    }

    /// Scrolls the cell with the focus into view, as the note does for its caret.
    func revealFocus() {
        guard let focus, grids.indices.contains(focus.table) else { return }
        grids[focus.table].reveal(focus.cell)
    }

    func move(_ move: TableMove) {
        guard let focus, spans.indices.contains(focus.table) else { return }
        let span = spans[focus.table]
        let rows = span.table.gridRowCount, columns = span.table.gridColumnCount
        let r = focus.cell.row, c = focus.cell.column
        func go(_ row: Int, _ column: Int, _ caret: TableCaret = .end) {
            focusCell(TableCellAddress(table: focus.table, cell: GridCell(row: row, column: column)), caret: caret)
        }
        switch move {
        case .next:
            if c + 1 < columns {
                go(r, c + 1)
            } else if r + 1 < rows {
                go(r + 1, 0)
            } else {
                perform(.addRowBelow, keeping: GridCell(row: rows, column: 0))
            }
        case .previous:
            if c > 0 {
                go(r, c - 1)
            } else if r > 0 {
                go(r - 1, columns - 1)
            }
        case .up:
            if r > 0 { go(r - 1, c) } else { leaveTable(above: true) }
        case .down:
            if r + 1 < rows { go(r + 1, c) } else { leaveTable(above: false) }
        case .left, .right:
            let forward = (move == .right) != span.rightToLeft
            if forward {
                if c + 1 < columns {
                    go(r, c + 1, .start)
                } else if r + 1 < rows {
                    go(r + 1, 0, .start)
                } else {
                    leaveTable(above: false)
                }
            } else {
                if c > 0 {
                    go(r, c - 1)
                } else if r > 0 {
                    go(r - 1, columns - 1)
                } else {
                    leaveTable(above: true)
                }
            }
        }
    }

    /// Out of the table onto the line above or below. A table that starts the note has no line above it.
    func leaveTable(above: Bool) {
        guard let focus, spans.indices.contains(focus.table), let view = textView else { return }
        let range = spans[focus.table].range
        if above, range.location == 0 { return }
        let text = view.noteText
        var caret = above ? MarkdownEdits.caret(at: range.location - 1, in: text) : NSMaxRange(range)
        endFocus()
        if !above { caret = addLineUnderLastTable(at: caret) ?? caret }
        lastSelection = NSRange(location: caret, length: 0)
        view.focusNote(caret: caret)
    }

    /// A caret under a table whose last line has no ending has no line to sit on. Asked for by a person, by going there, it
    /// gets one: one line ending, its own undo step. The caret's new place, or nil if there was no need.
    @discardableResult
    func addLineUnderLastTable(at caret: Int) -> Int? {
        guard focus == nil, caretLineUnderLastTable(at: caret) != nil, let view = textView else { return nil }
        let ending = MarkdownEdits.lineEnding(in: view.noteText, at: caret)
        closeRun()
        let step = TableUndoStep(start: caret, before: "", after: ending, focusBefore: nil, focusAfter: nil)
        register(step, undoing: true)
        write(MarkdownEdits.Edit(range: NSRange(location: caret, length: 0), replacement: ending, selection: NSRange(location: caret + (ending as NSString).length, length: 0)))
        let after = caret + (ending as NSString).length
        lastSelection = NSRange(location: after, length: 0)
        view.setNoteSelection(NSRange(location: after, length: 0))
        return after
    }

    // MARK: edits

    /// Typing reached the editor: the file follows at once, so that the autosave has it as it has any other typing.
    func editorChanged(_ editor: TableCellEditor) {
        guard !isLoadingEditor, !editor.isComposing, let focus, grids.indices.contains(focus.table), grids[focus.table].editor === editor else { return }
        let text = editor.cellText
        let cell = focus.cell
        apply(table: focus.table, focusAfter: cell, coalescing: true) { try $0.setGridText(row: cell.row, column: cell.column, to: text) }
        styleEditor(editor, cell: cell)
        revealFocus()
    }

    func isEnabled(_ command: TableCommand) -> Bool {
        guard let focus, spans.indices.contains(focus.table) else { return false }
        let table = spans[focus.table].table
        switch command {
        case .deleteRow: return table.gridRowCount > 1
        case .deleteColumn: return table.gridColumnCount > 1
        default: return true
        }
    }

    /// A handle, a menu item or a plus button.
    func perform(_ command: TableCommand, keeping: GridCell? = nil) {
        finishComposition()
        guard let focus, spans.indices.contains(focus.table), isEnabled(command) else { return }
        let index = focus.table
        let table = spans[index].table
        let r = focus.cell.row, c = focus.cell.column
        switch command {
        case .addRowAbove:
            edit(index, GridCell(row: r, column: c)) { try $0.insertGridRow(at: r) }
        case .addRowBelow:
            edit(index, keeping ?? GridCell(row: r + 1, column: c)) { try $0.insertGridRow(at: r + 1) }
        case .addColumnBefore:
            edit(index, GridCell(row: r, column: c)) { try $0.insertGridColumn(at: c) }
        case .addColumnAfter:
            edit(index, GridCell(row: r, column: c + 1)) { try $0.insertGridColumn(at: c + 1) }
        case .deleteRow:
            edit(index, GridCell(row: min(r, table.gridRowCount - 2), column: c)) { try $0.removeGridRow(at: r) }
        case .deleteColumn:
            edit(index, GridCell(row: r, column: min(c, table.gridColumnCount - 2))) { try $0.removeGridColumn(at: c) }
        case .deleteTable:
            deleteTable(index)
        case .addLineAbove:
            addLineAbove(index)
        }
    }

    /// A new column or row for the plus buttons: at the end, wherever the focus is.
    func addRowAtEnd() {
        finishComposition()
        guard let focus, spans.indices.contains(focus.table) else { return }
        let rows = spans[focus.table].table.gridRowCount
        edit(focus.table, GridCell(row: rows, column: focus.cell.column)) { try $0.insertGridRow(at: rows) }
    }

    func addColumnAtEnd() {
        finishComposition()
        guard let focus, spans.indices.contains(focus.table) else { return }
        let columns = spans[focus.table].table.gridColumnCount
        edit(focus.table, GridCell(row: focus.cell.row, column: columns)) { try $0.insertGridColumn(at: columns) }
    }

    /// A change to a table's shape, its own undo step, with the focus going to `cell`.
    private func edit(_ index: Int, _ cell: GridCell, _ change: (inout MarkdownTable) throws -> Void) {
        closeRun()
        frozen = nil
        apply(table: index, focusAfter: cell, coalescing: false, change)
        guard let focus, let editor = grids[focus.table].showEditor(at: focus.cell) else { return }
        loadEditor(editor, cell: focus.cell)
        editor.cellSelection = NSRange(location: (editor.cellText as NSString).length, length: 0)
        focusChanged?()
        revealFocus()
    }

    private func apply(table index: Int, focusAfter: GridCell, coalescing: Bool, _ change: (inout MarkdownTable) throws -> Void) {
        guard spans.indices.contains(index) else { return }
        let span = spans[index]
        var edited = span.table
        guard (try? change(&edited)) != nil else { return }
        let old = span.table.markdown, new = edited.markdown
        guard let replacement = TableEdits.replacing(old, with: new, at: span.range.location) else { return }
        // Never over anything but what this table was read from: if that isn't what is there, nothing is written.
        guard let ns = textView?.noteText as NSString?, NSMaxRange(span.range) <= ns.length,
              ns.substring(with: span.range).utf8.elementsEqual(old.utf8) else { return }
        let target = TableCellAddress(table: index, cell: focusAfter)
        if coalescing, let run, run.start == span.range.location, run.focusAfter == target {
            run.after = new
        } else {
            closeRun()
            let step = TableUndoStep(start: span.range.location, before: old, after: new, focusBefore: focus, focusAfter: target)
            register(step, undoing: true)
            if coalescing { run = step }
        }
        focus = target
        write(replacement)
    }

    private func closeRun() { run = nil }

    /// Takes a table out, its own undo step. The note has the focus after it, where the table was.
    private func deleteTable(_ index: Int) {
        guard let view = textView else { return }
        let span = kitSpans[index]
        let text = view.noteText
        let removal = TableEdits.deletingTable(span, in: text)
        closeRun()
        let step = TableUndoStep(start: removal.range.location, before: (text as NSString).substring(with: removal.range), after: "", focusBefore: focus, focusAfter: nil)
        register(step, undoing: true)
        focus = nil
        frozen = nil
        if grids.indices.contains(index) { grids[index].hideEditor() }
        write(removal)
        focusChanged?()
        lastSelection = removal.selection
        // With another table right after this one, the place it left is that table's first line.
        if let next = spans.firstIndex(where: { $0.range.location == removal.selection.location }) {
            enter(table: next, atStart: true)
        } else {
            view.focusNote(caret: removal.selection.location)
        }
    }

    /// A blank line above a table that starts the note, with the caret on it.
    private func addLineAbove(_ index: Int) {
        guard let view = textView else { return }
        let insertion = TableEdits.addingLine(above: kitSpans[index], in: view.noteText)
        closeRun()
        let step = TableUndoStep(start: insertion.range.location, before: "", after: insertion.replacement, focusBefore: focus, focusAfter: nil)
        register(step, undoing: true)
        focus = nil
        frozen = nil
        if grids.indices.contains(index) { grids[index].hideEditor() }
        write(insertion)
        focusChanged?()
        lastSelection = insertion.selection
        view.focusNote(caret: insertion.selection.location)
    }

    /// One replacement in the note, with no undo step of the text view's own: the steps are `TableUndoStep`s, so that a run
    /// of typing in a cell is one step, as typing in the note is.
    private func write(_ edit: MarkdownEdits.Edit) {
        guard let view = textView else { return }
        let before = view.noteSelection
        isApplying = true
        let manager = view.undoManager
        view.willWriteTable()
        manager?.disableUndoRegistration()
        view.writeTable(edit)
        manager?.enableUndoRegistration()
        // The note's selection goes along with the text, and a text view that wrote this may have moved it.
        let after: NSRange
        if let focus, spans.indices.contains(focus.table) {
            // Nothing has the note's caret while a cell has the focus.
            after = NSRange(location: NSMaxRange(spans[focus.table].range), length: 0)
        } else if NSMaxRange(before) <= edit.range.location {
            after = before
        } else if before.location >= NSMaxRange(edit.range) {
            after = NSRange(location: before.location + (edit.replacement as NSString).length - edit.range.length, length: before.length)
        } else {
            after = NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0)
        }
        view.setNoteSelection(after)
        isApplying = false
        // And it never stays in hidden text: an undo can bring a table back around it, or a table up to it.
        if focus == nil, let moved = settleSelection(after, isFirstResponder: false) { view.setNoteSelection(moved) }
    }

    private func register(_ step: TableUndoStep, undoing: Bool) {
        guard let manager = textView?.undoManager else { return }
        undoManagerInUse = manager
        let target = undoTarget
        manager.registerUndo(withTarget: target) { [weak self, target] _ in
            withExtendedLifetime(target) {
                MainActor.assumeIsolated { self?.swap(step, undoing: undoing) }
            }
        }
        manager.setActionName("Table Edit")
    }

    /// An undo or a redo. If the text isn't what the step left, as it must be, nothing is written over it.
    private func swap(_ step: TableUndoStep, undoing: Bool) {
        guard let view = textView else { return }
        closeRun()
        let from = undoing ? step.after : step.before
        let to = undoing ? step.before : step.after
        let ns = view.noteText as NSString
        let range = NSRange(location: step.start, length: (from as NSString).length)
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range).utf8.elementsEqual(from.utf8) else { return }
        register(step, undoing: !undoing)
        guard let replacement = TableEdits.replacing(from, with: to, at: step.start) else { return }
        // Only if a cell has the focus now: an undo from the note leaves the focus on the note.
        let wanted = focus == nil ? nil : (undoing ? step.focusBefore : step.focusAfter)
        let hadFocus = focus != nil
        if wanted?.table == focus?.table {
            focus = wanted
            frozen = nil
        } else if let focus {
            self.focus = nil
            frozen = nil
            if grids.indices.contains(focus.table) { grids[focus.table].hideEditor() }
        }
        write(replacement)
        if hadFocus {
            if let wanted {
                if focus == nil { focusCell(wanted, caret: .end) }
            } else {
                lastSelection = NSRange(location: step.start, length: 0)
                view.focusNote(caret: step.start)
            }
        }
        focusChanged?()
    }

    /// With the caret at the very end of a note whose last line is a table's, with no line ending: the top of the line it
    /// will start when something is typed. That place has no line yet to draw a caret on.
    func caretLineUnderLastTable(at offset: Int) -> CGFloat? {
        guard let view = textView, let last = spans.last, offset == NSMaxRange(last.range), grids.count == spans.count else { return nil }
        let ns = view.noteText as NSString
        guard offset == ns.length, offset > 0, ns.character(at: offset - 1) != 0x0A, ns.character(at: offset - 1) != 0x0D else { return nil }
        return grids[spans.count - 1].frame.maxY
    }

    // MARK: the bar and the menu, while a cell has the focus

    /// A cell holds one line of inline text: bold, italic, code, a link and a direction mark work in it, and nothing that
    /// makes a block does.
    func performInCell(_ action: EditorAction) {
        guard let focus, grids.indices.contains(focus.table), let editor = grids[focus.table].editor, !editor.isComposing else { return }
        switch action {
        case .bold, .italic, .code, .link, .direction:
            let edit = action.edit(in: editor.cellText, selection: editor.cellSelection)
            guard !edit.changesNothing else { return }
            editor.applyCellEdit(edit)
        default:
            break
        }
    }

    /// The note's own bar and menu actions don't take a selection that holds a table: they would write marks into its rows.
    func selectionHoldsTable(_ selection: NSRange) -> Bool {
        TableEdits.touches(selection, tables: tableRanges)
    }
}
