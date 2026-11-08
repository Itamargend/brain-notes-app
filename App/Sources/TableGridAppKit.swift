#if os(macOS)
import AppKit
import BrainNotesKit

// The grid on the Mac: the same design as on iPhone (`TableGridUIKit.swift`). Labels show the cells and one real text view,
// the cell editor, moves to the cell with the focus. A click focuses a cell, Tab and the arrows move between cells, and a
// right click has every table command.

/// The text view that edits the cell with the focus. It keeps no undo of its own: a cell's edits go into the note, and the
/// window's undo stack holds them there.
final class TableCellEditor: NSTextView {
    weak var overlay: TableOverlay?
    private var isConfigured = false

    func configure(overlay: TableOverlay) {
        guard !isConfigured else { return }
        isConfigured = true
        self.overlay = overlay
        delegate = overlay
        isRichText = false
        allowsUndo = false
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        writingToolsBehavior = .limited
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = true
    }

    var cellText: String {
        get { string }
        set { string = newValue }
    }

    var cellSelection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }

    var isComposing: Bool { hasMarkedText() }

    /// What is being composed becomes text as it stands.
    func endComposing() { unmarkText() }

    func beginEditingCell() { window?.makeFirstResponder(self) }

    func placeCaret(at point: CGPoint) {
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
    }

    /// Only attributes: the characters are the cell's.
    func applyLook(_ look: NSAttributedString, typing: [NSAttributedString.Key: Any]) {
        guard let storage = textStorage, storage.string == look.string else { return }
        storage.beginEditing()
        look.enumerateAttributes(in: NSRange(location: 0, length: look.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        typingAttributes = typing
    }

    /// An edit from the menu. It goes in as typing does, and comes back through `textDidChange`.
    func applyCellEdit(_ edit: MarkdownEdits.Edit) {
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
    }

    /// Going by what the caret touches: is it on the first line, or the last.
    func isCaretOnEdgeLine(top: Bool) -> Bool {
        let at = selectedRange()
        guard at.length == 0 else { return false }
        func lineTop(_ location: Int) -> CGFloat {
            firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil).midY
        }
        return abs(lineTop(at.location) - lineTop(top ? 0 : string.utf16.count)) < 1
    }

    func isCaretAtSide(left: Bool) -> Bool {
        let at = selectedRange()
        guard at.length == 0 else { return false }
        let rightToLeft = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection == .rightToLeft
        return left != rightToLeft ? at.location == 0 : at.location == string.utf16.count
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // After the window has moved on, so that the note can already be the first responder.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.overlay?.editorEnded(self)
            }
        }
        return resigned
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let items = (enclosingGrid?.tableMenuItems(TableCommand.cellMenu)) else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    private var enclosingGrid: TableGridView? {
        var view = superview
        while let current = view {
            if let grid = current as? TableGridView { return grid }
            view = current.superview
        }
        return nil
    }
}

extension TableOverlay: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text, !textView.hasMarkedText(), let editor = textView as? TableCellEditor else { return true }
        if text.contains(where: \.isNewline) {
            // A cell is one line, however much is pasted into it.
            let flat = MarkdownTable.cellText(forTyped: text)
            editor.applyCellEdit(MarkdownEdits.Edit(range: range, replacement: flat, selection: NSRange(location: range.location + (flat as NSString).length, length: 0)))
            return false
        }
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let editor = textView as? TableCellEditor, !editor.isComposing else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            move(.next)
        case #selector(NSResponder.insertBacktab(_:)):
            move(.previous)
        case #selector(NSResponder.moveUp(_:)):
            guard editor.isCaretOnEdgeLine(top: true) else { return false }
            move(.up)
        case #selector(NSResponder.moveDown(_:)):
            guard editor.isCaretOnEdgeLine(top: false) else { return false }
            move(.down)
        case #selector(NSResponder.moveLeft(_:)):
            guard editor.isCaretAtSide(left: true) else { return false }
            move(.left)
        case #selector(NSResponder.moveRight(_:)):
            guard editor.isCaretAtSide(left: false) else { return false }
            move(.right)
        case #selector(NSResponder.cancelOperation(_:)):
            leaveTable(above: false)
        default:
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        if let editor = notification.object as? TableCellEditor { editorChanged(editor) }
    }
}

/// One cell as it looks while another has the focus.
private final class TableCellView: NSView {
    let label = NSTextField(labelWithString: "")
    var painted: String?
    /// With the event, for where the caret goes. With none, from VoiceOver.
    var press: ((NSEvent?) -> Void)?
    var menuForPress: ((NSEvent) -> NSMenu?)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.drawsBackground = false
        label.isBezeled = false
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// All of a press is the cell's, its label included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { press?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { menuForPress?(event) }

    override func accessibilityPerformPress() -> Bool {
        press?(nil)
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

/// A round or capsule button, a little easier to hit than it looks.
private final class TableGridButton: NSButton {
    var showMenu: (() -> NSMenu?)?

    convenience init(symbol: String, label: String, identifier: String) {
        self.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        contentTintColor = .white
        layer?.backgroundColor = PlatformColor.bnAccent.cgColor
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        isHidden = true
    }

    /// A handle opens its menu right from the press.
    override func mouseDown(with event: NSEvent) {
        guard let menu = showMenu?() else { return super.mouseDown(with: event) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
}

/// The sideways scroller inside a grid. Scrolling up and down belongs to the note.
private final class TableGridScroller: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) || documentWidthFits {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private var documentWidthFits: Bool {
        (documentView?.frame.width ?? 0) <= contentView.bounds.width + 0.5
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One table's grid, a subview of the note's text view, over the table's first line.
final class TableGridView: NSView {
    private weak var overlay: TableOverlay?
    var index: Int

    private let scroller = TableGridScroller()
    private let content = FlippedView()
    private let plate = FlippedView()
    private var cells: [[TableCellView]] = []
    private let ring = NSView()
    private let rowHandle = TableGridButton(symbol: "ellipsis", label: "Row Options", identifier: "editor.table.rowHandle")
    private let columnHandle = TableGridButton(symbol: "ellipsis", label: "Column Options", identifier: "editor.table.columnHandle")
    private let addRow = TableGridButton(symbol: "plus", label: "Add Row", identifier: "editor.table.addRow")
    private let addColumn = TableGridButton(symbol: "plus", label: "Add Column", identifier: "editor.table.addColumn")
    private(set) var editor: TableCellEditor?
    private var state: TableGridState?

    override var isFlipped: Bool { true }

    var isEditing: Bool { window?.firstResponder === editor && editor != nil }

    /// In the note's selection, as a whole.
    var isInSelection = false {
        didSet {
            plate.layer?.borderWidth = isInSelection ? 2 : 0
            plate.layer?.borderColor = PlatformColor.bnAccent.cgColor
        }
    }

    init(overlay: TableOverlay, index: Int) {
        self.overlay = overlay
        self.index = index
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("editor.table")

        scroller.drawsBackground = false
        scroller.hasVerticalScroller = false
        scroller.hasHorizontalScroller = false
        scroller.verticalScrollElasticity = .none
        scroller.horizontalScrollElasticity = .none
        // Over the content, for a mouse too: a scroller that takes room would cover the last row.
        scroller.scrollerStyle = .overlay
        scroller.documentView = content
        addSubview(scroller)

        plate.wantsLayer = true
        plate.layer?.backgroundColor = plateColor.cgColor
        plate.layer?.cornerRadius = TableGridMetrics.cornerRadius
        plate.layer?.cornerCurve = .continuous
        plate.layer?.masksToBounds = true
        content.addSubview(plate)

        ring.wantsLayer = true
        ring.layer?.borderColor = PlatformColor.bnAccent.cgColor
        ring.layer?.borderWidth = 2
        ring.layer?.cornerRadius = 3
        ring.isHidden = true
        content.addSubview(ring)

        for handle in [rowHandle, columnHandle] {
            handle.layer?.cornerRadius = TableGridMetrics.handleShort / 2
            content.addSubview(handle)
        }
        rowHandle.showMenu = { [weak self] in self?.menu(of: TableCommand.rowMenu) }
        columnHandle.showMenu = { [weak self] in self?.menu(of: TableCommand.columnMenu) }
        for plus in [addRow, addColumn] {
            plus.layer?.cornerRadius = TableGridMetrics.plusSize / 2
            plus.target = self
            addSubview(plus)
        }
        addRow.action = #selector(addRowPressed)
        addColumn.action = #selector(addColumnPressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    @objc private func addRowPressed() { overlay?.addRowAtEnd() }
    @objc private func addColumnPressed() { overlay?.addColumnAtEnd() }

    // MARK: looks

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The frame around the cells. Dark keeps the old charcoal plate. Light is a gray rule on the white page.
    private var plateColor: NSColor {
        isDark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.86, alpha: 1)
    }

    private func cellFill(header: Bool) -> NSColor {
        if isDark {
            return header ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.10, alpha: 1)
        }
        return header ? NSColor(white: 0.94, alpha: 1) : .white
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        plate.layer?.backgroundColor = plateColor.cgColor
        for (row, rowCells) in cells.enumerated() {
            for cell in rowCells {
                cell.layer?.backgroundColor = cellFill(header: row == 0).cgColor
                cell.painted = nil
            }
        }
    }

    private func plateFrame(_ state: TableGridState) -> CGRect {
        CGRect(origin: state.plateOrigin, size: CGSize(width: state.geometry.totalWidth, height: state.geometry.totalHeight))
    }

    private func cellFrameInContent(_ cell: GridCell, _ state: TableGridState) -> CGRect {
        state.geometry.cellFrame(cell, rightToLeft: state.rightToLeft).offsetBy(dx: state.plateOrigin.x, dy: state.plateOrigin.y)
    }

    private func textFrame(in size: CGSize) -> CGRect {
        CGRect(x: TableGridMetrics.cellPaddingX, y: TableGridMetrics.cellPaddingY,
               width: max(size.width - 2 * TableGridMetrics.cellPaddingX, 1), height: max(size.height - 2 * TableGridMetrics.cellPaddingY, 1))
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
        setAccessibilityLabel(state.label)

        scroller.frame = bounds
        content.frame = CGRect(x: 0, y: 0, width: state.contentWidth, height: bounds.height)
        if state.isScrollable, wasRightToLeft != state.rightToLeft || wasScrollable != true {
            scroller.contentView.scroll(to: NSPoint(x: state.rightToLeft ? state.contentWidth - bounds.width : 0, y: 0))
            scroller.reflectScrolledClipView(scroller.contentView)
        } else if !state.isScrollable {
            scroller.contentView.scroll(to: .zero)
        }
        scroller.hasHorizontalScroller = state.isScrollable

        plate.frame = plateFrame(state)
        let rows = state.table.gridRowCount, columns = state.table.gridColumnCount
        while cells.count > rows { cells.removeLast().forEach { $0.removeFromSuperview() } }
        while cells.count < rows { cells.append([]) }
        let hairline = 1 / max(window?.backingScaleFactor ?? 2, 1)
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
                view.layer?.backgroundColor = cellFill(header: r == 0).cgColor
                // A label keeps 2 points of its own on each side, which a text view with no padding doesn't.
                view.label.frame = textFrame(in: view.bounds.size).insetBy(dx: -2, dy: 0)
                let text = state.table.gridText(row: r, column: c)
                let alignment = state.table.gridAlignment(column: c)
                let key = "\(isDark)\(r == 0)\(alignment)\(state.rightToLeft)|\(text)"
                if view.painted != key {
                    view.painted = key
                    view.label.attributedStringValue = painter.text(text, isHeader: r == 0, showsMarks: false, alignment: alignment, tableRightToLeft: state.rightToLeft)
                }
                let isFocused = state.focus == address
                view.label.isHidden = isFocused
                view.setAccessibilityIdentifier(isFocused ? nil : TableGridState.identifier(of: address))
                view.setAccessibilityLabel(state.label(of: address))
                view.setAccessibilityValue(text)
                view.setAccessibilityElement(!isFocused)
                view.press = { [weak self] event in self?.pressed(address, event: event) }
                view.menuForPress = { [weak self] event in
                    guard let self else { return nil }
                    self.pressed(address, event: event)
                    return self.menu(of: TableCommand.cellMenu)
                }
            }
        }

        if let focus = state.focus {
            placeEditor(on: focus, state)
            ring.frame = cellFrameInContent(focus, state).insetBy(dx: -0.5, dy: -0.5)
            ring.isHidden = false
            placeHandles(for: focus, state)
        } else {
            ring.isHidden = true
            rowHandle.isHidden = true
            columnHandle.isHidden = true
        }
        placePlusButtons(state)
    }

    private func placeHandles(for cell: GridCell, _ state: TableGridState) {
        let frame = cellFrameInContent(cell, state)
        let plate = plateFrame(state)
        rowHandle.frame = state.rowHandleFrame(forCell: frame, plate: plate)
        columnHandle.frame = state.columnHandleFrame(forCell: frame, plate: plate)
        rowHandle.isHidden = false
        columnHandle.isHidden = false
    }

    private func placePlusButtons(_ state: TableGridState) {
        let isFocused = state.focus != nil
        addRow.isHidden = !isFocused
        addColumn.isHidden = !isFocused
        guard isFocused else { return }
        let frames = state.plusFrames(plate: plateFrame(state).offsetBy(dx: -scroller.contentView.bounds.minX, dy: 0))
        addRow.frame = frames.addRow
        addColumn.frame = frames.addColumn
    }

    // MARK: the editor

    @discardableResult
    func showEditor(at cell: GridCell) -> TableCellEditor? {
        let editor = self.editor ?? makeEditor()
        if let state { placeEditor(on: cell, state) }
        return editor
    }

    private func makeEditor() -> TableCellEditor {
        let editor = TableCellEditor(frame: .zero)
        if let overlay { editor.configure(overlay: overlay) }
        content.addSubview(editor, positioned: .below, relativeTo: ring)
        self.editor = editor
        return editor
    }

    private func placeEditor(on cell: GridCell, _ state: TableGridState) {
        guard let editor else { return }
        let frame = cellFrameInContent(cell, state)
        editor.frame = textFrame(in: frame.size).offsetBy(dx: frame.minX, dy: frame.minY)
        editor.isHidden = false
        editor.setAccessibilityIdentifier(TableGridState.identifier(of: cell))
        editor.setAccessibilityLabel(state.label(of: cell))
    }

    func hideEditor() {
        guard let editor else { return }
        if window?.firstResponder === editor { window?.makeFirstResponder(overlay?.textView) }
        editor.isHidden = true
        editor.setAccessibilityIdentifier(nil)
    }

    func reveal(_ cell: GridCell) {
        guard let state, let note = overlay?.textView else { return }
        let frame = cellFrameInContent(cell, state)
        if state.isScrollable { content.scrollToVisible(frame.insetBy(dx: -state.textLeft, dy: 0)) }
        let inNote = content.convert(frame, to: note)
        let top = TableGridState.revealTop(cell: inNote, plateTop: content.convert(plateFrame(state), to: note).minY, room: note.visibleRect.height)
        note.scrollToVisible(CGRect(x: 0, y: top, width: 1, height: inNote.maxY + TableGridMetrics.marginBelow - top))
    }

    // MARK: presses and menus

    private func pressed(_ cell: GridCell, event: NSEvent?) {
        guard let state else { return }
        var caret = TableCaret.end
        if let event {
            let point = content.convert(event.locationInWindow, from: nil)
            let frame = cellFrameInContent(cell, state)
            caret = .point(CGPoint(x: point.x - frame.minX - TableGridMetrics.cellPaddingX, y: point.y - frame.minY - TableGridMetrics.cellPaddingY))
        }
        if state.focus != cell { overlay?.focusCell(TableCellAddress(table: index, cell: cell), caret: caret) }
    }

    func tableMenuItems(_ commands: [TableCommand]) -> [NSMenuItem] {
        var items = commands
        if let spans = overlay?.spans, spans.indices.contains(index), spans[index].range.location == 0 { items.insert(.addLineAbove, at: 0) }
        return items.map { command in
            let item = NSMenuItem(title: command.title, action: #selector(menuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.isEnabled = overlay?.isEnabled(command) == true
            item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
            return item
        }
    }

    func menu(of commands: [TableCommand]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in tableMenuItems(commands) { menu.addItem(item) }
        return menu
    }

    @objc private func menuPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let command = TableCommand(rawValue: raw) else { return }
        overlay?.perform(command)
    }
}

// MARK: - the note's text view

extension EditorTextView {
    var noteContainer: NSTextContainer? { textContainer }
    var textLeftEdge: CGFloat { textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) }
    var textTopEdge: CGFloat { textContainerOrigin.y }
    var noteText: String { string }
    var noteHasFocus: Bool { window?.firstResponder === self }

    func addGridView(_ grid: TableGridView) { addSubview(grid, positioned: .above, relativeTo: nil) }
    func gridsNeedLayout() { needsLayout = true }

    func focusNote(caret: Int? = nil) {
        if let caret { setSelectedRange(NSRange(location: caret, length: 0)) }
        window?.makeFirstResponder(self)
    }

    var noteSelection: NSRange { selectedRange() }
    func setNoteSelection(_ range: NSRange) { setSelectedRange(range) }
    func willWriteTable() { breakUndoCoalescing() }

    /// As any edit, through the checks a text view makes, and without moving what is on screen.
    func writeTable(_ edit: MarkdownEdits.Edit) {
        coordinator?.writingTable {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
        }
    }
}
#endif
