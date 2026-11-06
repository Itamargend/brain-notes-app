#if os(iOS)
import BrainNotesKit
import UIKit

// The grid on iPhone. Plain labels show the cells, so a long table stays light, and one real text view, the cell editor,
// moves to the cell with the focus: it keeps the focus from cell to cell, so the keyboard never blinks, and it has the
// note's own glass bar as its accessory.

/// The undo stack is the note's, for a cell's edits go into the note. A shake, three fingers or Cmd-Z ask the first
/// responder's manager, so they come here and go on from here. What the editor registers for itself goes nowhere: its
/// own steps would point at a view that moves between cells.
final class TableCellUndoManager: UndoManager, @unchecked Sendable {
    weak var note: UndoManager?

    override init() {
        super.init()
        disableUndoRegistration()
    }

    override var canUndo: Bool { note?.canUndo ?? false }
    override var canRedo: Bool { note?.canRedo ?? false }
    override func undo() { note?.undo() }
    override func redo() { note?.redo() }
    override var undoActionName: String { note?.undoActionName ?? "" }
    override var redoActionName: String { note?.redoActionName ?? "" }
    override var undoMenuItemTitle: String { note?.undoMenuItemTitle ?? "" }
    override var redoMenuItemTitle: String { note?.redoMenuItemTitle ?? "" }
}

/// The text view that edits the cell with the focus.
final class TableCellEditor: UITextView {
    weak var overlay: TableOverlay?
    /// Lazy, like everything stored here: `UITextView(usingTextLayoutManager:)` makes this view without running Swift's
    /// initializers, so a plain stored value would still be nil, and accessibility asks for this at any time.
    private lazy var undoForwarder = TableCellUndoManager()

    override var undoManager: UndoManager? {
        undoForwarder.note = overlay?.textView?.undoManager
        return undoForwarder
    }

    func configure(overlay: TableOverlay) {
        self.overlay = overlay
        delegate = overlay
        isScrollEnabled = false
        backgroundColor = .clear
        isOpaque = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        dataDetectorTypes = []
        writingToolsBehavior = .limited
        returnKeyType = .next
        for edge in [topEdgeEffect, bottomEdgeEffect, leftEdgeEffect, rightEdgeEffect] { edge.isHidden = true }
    }

    var cellText: String {
        get { text ?? "" }
        set { text = newValue }
    }

    var cellSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }

    var isComposing: Bool { markedTextRange != nil }

    /// What is being composed becomes text as it stands.
    func endComposing() { unmarkText() }

    func beginEditingCell() {
        inputAccessoryView = overlay?.textView?.inputAccessoryView
        becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        overlay?.isEditorResigning = true
        defer { overlay?.isEditorResigning = false }
        return super.resignFirstResponder()
    }

    func placeCaret(at point: CGPoint) {
        layoutIfNeeded()
        if let position = closestPosition(to: point) { selectedTextRange = textRange(from: position, to: position) }
    }

    /// Only attributes: the characters are the cell's.
    func applyLook(_ look: NSAttributedString, typing: [NSAttributedString.Key: Any]) {
        guard textStorage.string == look.string else { return }
        let storage = textStorage
        storage.beginEditing()
        look.enumerateAttributes(in: NSRange(location: 0, length: look.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        typingAttributes = typing
    }

    /// An edit from the bar. It goes in as typing does, and comes back through `textViewDidChange`.
    func applyCellEdit(_ edit: MarkdownEdits.Edit) {
        guard let start = position(from: beginningOfDocument, offset: edit.range.location),
              let end = position(from: start, offset: edit.range.length),
              let range = textRange(from: start, to: end) else { return }
        replace(range, withText: edit.replacement)
        selectedRange = edit.selection
    }

    // MARK: keys

    override var keyCommands: [UIKeyCommand]? {
        func command(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let key = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
        return (super.keyCommands ?? []) + [
            command("\t", .shift, #selector(previousCell)),
            command(UIKeyCommand.inputEscape, [], #selector(leaveCell)),
            command(UIKeyCommand.inputUpArrow, [], #selector(cellAbove)),
            command(UIKeyCommand.inputDownArrow, [], #selector(cellBelow)),
            command(UIKeyCommand.inputLeftArrow, [], #selector(cellToTheLeft)),
            command(UIKeyCommand.inputRightArrow, [], #selector(cellToTheRight)),
        ]
    }

    /// An arrow only leaves the cell from its edge. Anywhere else this says no and the key moves the caret as usual.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(cellAbove): isCaretOnEdgeLine(top: true)
        case #selector(cellBelow): isCaretOnEdgeLine(top: false)
        case #selector(cellToTheLeft): isCaretAtSide(left: true)
        case #selector(cellToTheRight): isCaretAtSide(left: false)
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    private func isCaretOnEdgeLine(top: Bool) -> Bool {
        guard selectedRange.length == 0, let at = selectedTextRange?.start else { return false }
        let edge = top ? beginningOfDocument : endOfDocument
        return abs(caretRect(for: at).midY - caretRect(for: edge).midY) < 1
    }

    private func isCaretAtSide(left: Bool) -> Bool {
        guard selectedRange.length == 0 else { return false }
        let rightToLeft = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection == .rightToLeft
        // Left is the start of left-to-right text and the end of right-to-left text.
        return left != rightToLeft ? selectedRange.location == 0 : selectedRange.location == textStorage.length
    }

    @objc private func previousCell() { overlay?.move(.previous) }
    @objc private func leaveCell() { overlay?.leaveTable(above: false) }
    @objc private func cellAbove() { overlay?.move(.up) }
    @objc private func cellBelow() { overlay?.move(.down) }
    @objc private func cellToTheLeft() { overlay?.move(.left) }
    @objc private func cellToTheRight() { overlay?.move(.right) }
}

extension TableOverlay: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView.markedTextRange == nil else { return true }
        if text == "\n" || text == "\t" {
            move(.next)
            return false
        }
        if text.contains(where: \.isNewline), let editor = textView as? TableCellEditor {
            // A cell is one line, however much is pasted into it.
            let flat = MarkdownTable.cellText(forTyped: text)
            editor.applyCellEdit(MarkdownEdits.Edit(range: range, replacement: flat, selection: NSRange(location: range.location + (flat as NSString).length, length: 0)))
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        if let editor = textView as? TableCellEditor { editorChanged(editor) }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if let editor = textView as? TableCellEditor { editorEnded(editor) }
    }
}

/// A cell's text, from the top of the cell however tall its row is.
private final class TopAlignedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        let fitted = textRect(forBounds: rect, limitedToNumberOfLines: numberOfLines)
        super.drawText(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(fitted.height, rect.height)))
    }
}

/// One cell as it looks while another has the focus.
private final class TableCellView: UIView {
    let label = TopAlignedLabel()
    /// What the label was last given, so that an unchanged cell isn't painted again.
    var painted: String?
    weak var grid: TableGridView?
    var cell = GridCell(row: 0, column: 0)

    init() {
        super.init(frame: .zero)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        isAccessibilityElement = true
        accessibilityHint = "Double-tap to edit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func accessibilityActivate() -> Bool {
        grid?.activate(cell)
        return true
    }

    /// Asked for only by VoiceOver, so that a long table doesn't make them at every keystroke.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { grid?.commandsForVoiceOver(cell: cell) }
        set {}
    }
}

/// A round or capsule button that can be pressed a little outside what it draws. Targets are at least 44 points.
private final class TableGridButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let margin = TableGridMetrics.target
        let dx = min(bounds.width - margin, 0) / 2, dy = min(bounds.height - margin, 0) / 2
        return bounds.insetBy(dx: dx, dy: dy).contains(point)
    }

    convenience init(symbol: String, pointSize: CGFloat, label: String, identifier: String) {
        self.init(type: .custom)
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold))
        setImage(image?.withTintColor(.white, renderingMode: .alwaysOriginal), for: .normal)
        backgroundColor = .bnAccent
        accessibilityLabel = label
        accessibilityIdentifier = identifier
        isHidden = true
    }
}

/// One table's grid, a subview of the note's text view, over the table's first line. It takes all the touches on it but
/// vertical drags, which scroll the note. Drags sideways scroll the grid, if it is wider than the note.
final class TableGridView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private weak var overlay: TableOverlay?
    var index: Int

    private let scroller = UIScrollView()
    private let content = UIView()
    private let plate = UIView()
    private var cells: [[TableCellView]] = []
    private let ring = UIView()
    private let rowHandle = TableGridButton(symbol: "ellipsis", pointSize: 11, label: "Row Options", identifier: "editor.table.rowHandle")
    private let columnHandle = TableGridButton(symbol: "ellipsis", pointSize: 11, label: "Column Options", identifier: "editor.table.columnHandle")
    private let addRow = TableGridButton(symbol: "plus", pointSize: 12, label: "Add Row", identifier: "editor.table.addRow")
    private let addColumn = TableGridButton(symbol: "plus", pointSize: 12, label: "Add Column", identifier: "editor.table.addColumn")
    private(set) var editor: TableCellEditor?
    private var editorCell: GridCell?
    private var state: TableGridState?

    var isEditing: Bool { editor?.isFirstResponder == true }

    /// In the note's selection, as a whole.
    var isInSelection = false {
        didSet {
            plate.layer.borderWidth = isInSelection ? 2 : 0
            plate.layer.borderColor = UIColor.bnAccent.cgColor
        }
    }

    init(overlay: TableOverlay, index: Int) {
        self.overlay = overlay
        self.index = index
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .dark
        backgroundColor = .clear
        accessibilityIdentifier = "editor.table"
        accessibilityContainerType = .semanticGroup

        scroller.delegate = self
        // Clear, past the true-black scroll-view proxy, or it would paint over the note's own background for nothing.
        scroller.backgroundColor = .clear
        scroller.isOpaque = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        scroller.alwaysBounceVertical = false
        scroller.isDirectionalLockEnabled = true
        scroller.scrollsToTop = false
        scroller.contentInsetAdjustmentBehavior = .never
        for edge in [scroller.topEdgeEffect, scroller.bottomEdgeEffect, scroller.leftEdgeEffect, scroller.rightEdgeEffect] { edge.isHidden = true }
        addSubview(scroller)
        scroller.addSubview(content)

        plate.backgroundColor = UIColor(white: 0.28, alpha: 1)
        plate.layer.cornerRadius = TableGridMetrics.cornerRadius
        plate.layer.cornerCurve = .continuous
        plate.clipsToBounds = true
        content.addSubview(plate)

        ring.isUserInteractionEnabled = false
        ring.isHidden = true
        ring.layer.borderColor = UIColor.bnAccent.cgColor
        ring.layer.borderWidth = 2
        ring.layer.cornerRadius = 3
        content.addSubview(ring)

        for handle in [rowHandle, columnHandle] {
            handle.showsMenuAsPrimaryAction = true
            handle.preferredMenuElementOrder = .fixed
            handle.layer.cornerCurve = .continuous
            content.addSubview(handle)
        }
        for plus in [addRow, addColumn] {
            plus.layer.cornerRadius = TableGridMetrics.plusSize / 2
            addSubview(plus)
        }
        addRow.addAction(UIAction { [weak self] _ in self?.overlay?.addRowAtEnd() }, for: .touchUpInside)
        addColumn.addAction(UIAction { [weak self] _ in self?.overlay?.addColumnAtEnd() }, for: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        content.addGestureRecognizer(tap)
        content.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    // MARK: looks

    /// The plate's frame in the scrolling content.
    private func plateFrame(_ state: TableGridState) -> CGRect {
        CGRect(origin: state.plateOrigin, size: CGSize(width: state.geometry.totalWidth, height: state.geometry.totalHeight))
    }

    private func cellFrameInContent(_ cell: GridCell, _ state: TableGridState) -> CGRect {
        state.geometry.cellFrame(cell, rightToLeft: state.rightToLeft).offsetBy(dx: state.plateOrigin.x, dy: state.plateOrigin.y)
    }

    func forgetText() {
        state = nil
        for row in cells { for cell in row { cell.painted = nil } }
    }

    func render(_ state: TableGridState, painter: MarkdownStyler.CellPainter) {
        // Layout comes here at every tick of a scroll.
        if state == self.state, scroller.frame == bounds { return }
        let wasRightToLeft = self.state?.rightToLeft
        let wasScrollable = self.state?.isScrollable
        self.state = state
        accessibilityLabel = state.label

        scroller.frame = bounds
        let contentSize = CGSize(width: state.contentWidth, height: bounds.height)
        scroller.contentSize = contentSize
        content.frame = CGRect(origin: .zero, size: contentSize)
        scroller.isScrollEnabled = state.isScrollable
        // A wide right-to-left table starts at its first column, on the right.
        if state.isScrollable, wasRightToLeft != state.rightToLeft || wasScrollable != true {
            scroller.contentOffset.x = state.rightToLeft ? state.contentWidth - bounds.width : 0
        } else if !state.isScrollable, scroller.contentOffset.x != 0 {
            scroller.contentOffset.x = 0
        }

        plate.frame = plateFrame(state)
        let rows = state.table.gridRowCount, columns = state.table.gridColumnCount
        while cells.count > rows { cells.removeLast().forEach { $0.removeFromSuperview() } }
        while cells.count < rows { cells.append([]) }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        for r in 0..<rows {
            while cells[r].count > columns { cells[r].removeLast().removeFromSuperview() }
            while cells[r].count < columns {
                let cell = TableCellView()
                plate.addSubview(cell)
                cells[r].append(cell)
            }
            for c in 0..<columns {
                let address = GridCell(row: r, column: c)
                let view = cells[r][c]
                let frame = state.geometry.cellFrame(address, rightToLeft: state.rightToLeft)
                view.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width - hairline, height: frame.height - hairline)
                view.backgroundColor = r == 0 ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.1, alpha: 1)
                view.label.frame = textFrame(in: view.bounds.size)
                let text = state.table.gridText(row: r, column: c)
                let alignment = state.table.gridAlignment(column: c)
                let key = "\(r == 0)\(alignment)\(state.rightToLeft)|\(text)"
                if view.painted != key {
                    view.painted = key
                    view.label.attributedText = painter.text(text, isHeader: r == 0, showsMarks: false, alignment: alignment, tableRightToLeft: state.rightToLeft)
                }
                let isFocused = state.focus == address
                view.label.isHidden = isFocused
                view.isAccessibilityElement = !isFocused
                view.accessibilityIdentifier = isFocused ? nil : TableGridState.identifier(of: address)
                view.accessibilityLabel = state.label(of: address)
                view.accessibilityValue = text
                view.grid = self
                view.cell = address
            }
        }

        if let focus = state.focus {
            placeEditor(on: focus, state)
            let frame = cellFrameInContent(focus, state)
            ring.frame = frame.insetBy(dx: -0.5, dy: -0.5)
            ring.isHidden = false
            placeHandles(for: focus, state)
        } else {
            ring.isHidden = true
            rowHandle.isHidden = true
            columnHandle.isHidden = true
        }
        placePlusButtons(state)
    }

    private func textFrame(in size: CGSize) -> CGRect {
        CGRect(x: TableGridMetrics.cellPaddingX, y: TableGridMetrics.cellPaddingY,
               width: max(size.width - 2 * TableGridMetrics.cellPaddingX, 1), height: max(size.height - 2 * TableGridMetrics.cellPaddingY, 1))
    }

    private func placeHandles(for cell: GridCell, _ state: TableGridState) {
        let frame = cellFrameInContent(cell, state)
        let plate = plateFrame(state)
        let short = TableGridMetrics.handleShort
        rowHandle.frame = state.rowHandleFrame(forCell: frame, plate: plate)
        rowHandle.layer.cornerRadius = short / 2
        columnHandle.frame = state.columnHandleFrame(forCell: frame, plate: plate)
        columnHandle.layer.cornerRadius = short / 2
        rowHandle.isHidden = false
        columnHandle.isHidden = false
        rowHandle.menu = menu(of: TableCommand.rowMenu)
        columnHandle.menu = menu(of: TableCommand.columnMenu)
    }

    /// The plus buttons stay in sight when the grid scrolls sideways: on the edge of the table, or of the screen.
    private func placePlusButtons(_ state: TableGridState) {
        let isFocused = state.focus != nil
        addRow.isHidden = !isFocused
        addColumn.isHidden = !isFocused
        guard isFocused else { return }
        let frames = state.plusFrames(plate: plateFrame(state).offsetBy(dx: -scroller.contentOffset.x, dy: 0))
        addRow.frame = frames.addRow
        addColumn.frame = frames.addColumn
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let state { placePlusButtons(state) }
    }

    // MARK: the editor

    /// The editor over this cell. It is the one text view of this grid, made when first needed.
    @discardableResult
    func showEditor(at cell: GridCell) -> TableCellEditor? {
        let editor = self.editor ?? makeEditor()
        editorCell = cell
        if let state { placeEditor(on: cell, state) }
        return editor
    }

    private func makeEditor() -> TableCellEditor {
        let editor = TableCellEditor(usingTextLayoutManager: true)
        if let overlay { editor.configure(overlay: overlay) }
        content.addSubview(editor)
        content.bringSubviewToFront(ring)
        content.bringSubviewToFront(rowHandle)
        content.bringSubviewToFront(columnHandle)
        self.editor = editor
        return editor
    }

    private func placeEditor(on cell: GridCell, _ state: TableGridState) {
        guard let editor else { return }
        editorCell = cell
        let frame = cellFrameInContent(cell, state)
        editor.frame = textFrame(in: frame.size).offsetBy(dx: frame.minX, dy: frame.minY)
        editor.isHidden = false
        editor.accessibilityIdentifier = TableGridState.identifier(of: cell)
        editor.accessibilityLabel = state.label(of: cell)
        editor.accessibilityCustomActions = commandsForVoiceOver(cell: cell)
    }

    func hideEditor() {
        guard let editor else { return }
        editorCell = nil
        if editor.isFirstResponder { editor.resignFirstResponder() }
        editor.isHidden = true
        editor.accessibilityIdentifier = nil
    }

    /// Scrolls this cell into view, sideways in the grid and up and down in the note.
    func reveal(_ cell: GridCell) {
        guard let state, let note = overlay?.textView else { return }
        let frame = cellFrameInContent(cell, state)
        if state.isScrollable {
            scroller.scrollRectToVisible(frame.insetBy(dx: -state.textLeft, dy: 0), animated: true)
        }
        let inNote = content.convert(frame, to: note)
        // With the column handle on the table's top edge if that fits above the keyboard as well.
        let inset = note.adjustedContentInset
        let room = note.bounds.height - inset.top - inset.bottom
        let top = TableGridState.revealTop(cell: inNote, plateTop: content.convert(plateFrame(state), to: note).minY, room: room)
        note.scrollRectToVisible(CGRect(x: 0, y: top, width: 1, height: inNote.maxY + TableGridMetrics.marginBelow - top), animated: true)
    }

    // MARK: touches

    /// A touch on the editor or a button is theirs.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl) && !(touch.view?.isDescendant(of: editor ?? UIView()) ?? false)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let state else { return }
        let point = tap.location(in: content)
        let inPlate = CGPoint(x: point.x - state.plateOrigin.x, y: point.y - state.plateOrigin.y)
        guard let cell = state.geometry.cell(at: inPlate, rightToLeft: state.rightToLeft) else { return }
        let frame = cellFrameInContent(cell, state)
        let inText = CGPoint(x: point.x - frame.minX - TableGridMetrics.cellPaddingX, y: point.y - frame.minY - TableGridMetrics.cellPaddingY)
        overlay?.focusCell(TableCellAddress(table: index, cell: cell), caret: .point(inText))
    }

    func activate(_ cell: GridCell) {
        overlay?.focusCell(TableCellAddress(table: index, cell: cell), caret: .end)
    }

    // MARK: menus

    private func action(_ command: TableCommand) -> UIAction {
        var attributes: UIMenuElement.Attributes = command.isDestructive ? [.destructive] : []
        if overlay?.isEnabled(command) != true { attributes.insert(.disabled) }
        return UIAction(title: command.title, image: UIImage(systemName: command.symbol), attributes: attributes) { [weak self] _ in
            self?.overlay?.perform(command)
        }
    }

    /// A menu for the cell with the focus. A table that starts the note has one thing more: there is no other way to
    /// write above it.
    func menu(of commands: [TableCommand]) -> UIMenu {
        var items = commands
        if let spans = overlay?.spans, spans.indices.contains(index), spans[index].range.location == 0 { items.insert(.addLineAbove, at: 0) }
        return UIMenu(children: items.map(action))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let state else { return nil }
        let inPlate = CGPoint(x: location.x - state.plateOrigin.x, y: location.y - state.plateOrigin.y)
        // The focused cell's long press is the text's: selecting, and the loupe.
        guard let cell = state.geometry.cell(at: inPlate, rightToLeft: state.rightToLeft), cell != state.focus else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            self.overlay?.focusCell(TableCellAddress(table: self.index, cell: cell), caret: .end)
            return self.menu(of: TableCommand.cellMenu)
        }
    }

    /// The same things for VoiceOver, on the cell itself: the handles are only there for the cell with the focus.
    func commandsForVoiceOver(cell: GridCell) -> [UIAccessibilityCustomAction] {
        TableCommand.cellMenu.map { command in
            UIAccessibilityCustomAction(name: command.title) { [weak self] _ in
                guard let self else { return false }
                MainActor.assumeIsolated {
                    if self.overlay?.focus != TableCellAddress(table: self.index, cell: cell) {
                        self.overlay?.focusCell(TableCellAddress(table: self.index, cell: cell), caret: .end)
                    }
                    self.overlay?.perform(command)
                }
                return true
            }
        }
    }
}

// MARK: - the note's text view

/// What `MarkdownTextView` hands SwiftUI: the note's text view and nothing else on screen. It is there for VoiceOver, which
/// stops at a text view as one element and so would never reach the grids inside it: here they are its neighbours.
final class EditorContainerView: UIView {
    let textView: EditorTextView

    init(textView: EditorTextView) {
        self.textView = textView
        super.init(frame: .zero)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.frame = bounds
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var accessibilityElements: [Any]? {
        get { [textView] + (textView.coordinator?.tables?.grids.filter { !$0.isHidden } ?? []) }
        set {}
    }
}

extension EditorTextView {
    var noteContainer: NSTextContainer? { textContainer }
    var textLeftEdge: CGFloat { textContainerInset.left + textContainer.lineFragmentPadding }
    var textTopEdge: CGFloat { textContainerInset.top }
    var noteText: String { text ?? "" }
    var noteHasFocus: Bool { isFirstResponder }

    func addGridView(_ grid: TableGridView) { addSubview(grid) }
    func gridsNeedLayout() { setNeedsLayout() }

    func focusNote(caret: Int? = nil) {
        if let caret { selectedRange = NSRange(location: caret, length: 0) }
        becomeFirstResponder()
    }

    var noteSelection: NSRange { selectedRange }
    func setNoteSelection(_ range: NSRange) { selectedRange = range }
    func willWriteTable() {}

    /// Through the text view, as any edit, and where the note is on screen stays where it is.
    func writeTable(_ edit: MarkdownEdits.Edit) {
        guard let start = position(from: beginningOfDocument, offset: edit.range.location),
              let end = position(from: start, offset: edit.range.length),
              let range = textRange(from: start, to: end) else { return }
        let offset = contentOffset
        replace(range, withText: edit.replacement)
        if contentOffset != offset { setContentOffset(offset, animated: false) }
    }
}
#endif
