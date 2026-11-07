import BrainNotesKit
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias StorageEditActions = NSTextStorage.EditActions
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias StorageEditActions = NSTextStorageEditActions
#endif

/// The rendered note. Each block takes its own direction, so Hebrew and English lines each align to
/// their own side. No web views: the text is parsed by Foundation, raw HTML stays literal text,
/// and only http and https links are tappable.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let onTapText: () -> Void
    /// A tap on a table's cell starts editing that cell: its table among the note's tables, and the cell.
    var onTapCell: (TableCellAddress) -> Void = { _ in }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                BlockView(block: block, onTapText: onTapText, onTapCell: { cell in
                    onTapCell(TableCellAddress(table: tableIndex(of: block), cell: cell))
                })
            }
        }
    }

    private func tableIndex(of block: MarkdownBlock) -> Int {
        blocks.prefix(while: { $0.id != block.id }).filter {
            if case .table = $0.kind { return true }
            return false
        }.count
    }
}

struct BlockView: View {
    let block: MarkdownBlock
    let onTapText: () -> Void
    var onTapCell: (GridCell) -> Void = { _ in }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .paragraphDirection(rightToLeft: block.isRightToLeft)
    }

    /// A tap on text starts editing, but a block with a link keeps its taps for the link.
    @ViewBuilder private func tappable(_ text: Text, _ inline: AttributedString) -> some View {
        if inline.runs.contains(where: { $0.link != nil }) {
            text
        } else {
            text.onTapGesture(perform: onTapText)
        }
    }

    private var inline: AttributedString { NoteText.inlineMarkdown(block.text) }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case let .heading(level):
            let s = inline
            tappable(Text(s).font(Self.font(level: level)).fontWeight(level == 1 ? .bold : .semibold), s)
                .padding(.top, level == 1 ? 4 : 8)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            let s = inline
            tappable(Text(s), s)
        case let .bullet(indent):
            // VoiceOver would stop on the dot and say "bullet" before every item.
            row(indent: indent, marker: Text("•").foregroundStyle(.secondary).accessibilityHidden(true))
        case let .numbered(marker, indent):
            row(indent: indent, marker: Text(marker).foregroundStyle(.secondary).monospacedDigit())
        case let .task(done, indent):
            row(indent: indent, marker: Text(Image(systemName: done ? "checkmark.circle.fill" : "circle")).foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
                // One element: a label on a bare stack would land on the box and the text alike. The words are the
                // rendered ones, so VoiceOver says "Done: Buy milk", not the asterisks of "**Buy** milk".
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.taskLabel(done: done, inline: inline))
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3)
                let s = inline
                tappable(innerHeading(Text(s)).foregroundStyle(.secondary), s)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .onTapGesture(perform: onTapText)
                // Code reads left to right, even inside a Hebrew note.
                .environment(\.layoutDirection, .leftToRight)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let table):
            TablePreview(table: table, onTapCell: onTapCell)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.tableLabel(table))
                .accessibilityIdentifier("note.table")
                .environment(\.layoutDirection, (table.statedRightToLeft ?? false) ? .rightToLeft : .leftToRight)
        }
    }

    /// What VoiceOver says for a table in the viewer.
    static func tableLabel(_ table: MarkdownTable) -> String {
        let cols = table.columnCount
        let rows = table.rows.count
        let headers = table.headerTexts.joined(separator: ", ")
        return "Table, \(cols) columns, \(rows) rows. \(headers)"
    }

    private func row(indent: Int, marker: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            let s = inline
            tappable(innerHeading(Text(s)), s)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// What VoiceOver says for a task in the viewer.
    static func taskLabel(done: Bool, inline: AttributedString) -> String {
        (done ? "Done: " : "To do: ") + String(inline.characters)
    }

    /// A heading inside a list item or a quote, as in `- [ ] # a`.
    private func innerHeading(_ text: Text) -> Text {
        guard let level = block.innerHeadingLevel else { return text }
        return text.font(Self.font(level: level)).fontWeight(level == 1 ? .bold : .semibold)
    }

    private static func font(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}


/// A GFM table in the note viewer: a grid of cells, as Notes would show it, in the look of the editor's grid. A tap starts
/// editing that cell; the bytes stay the pipe Markdown.
struct TablePreview: View {
    let table: MarkdownTable
    var onTapCell: (GridCell) -> Void = { _ in }

    var body: some View {
        // Wider than the note scrolls sideways, as in the editor.
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid.frame(minWidth: 0) }
        }
    }

    private var columns: Int { table.gridColumnCount }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<table.gridRowCount, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(row: row, column: column)
                        if column + 1 < columns {
                            Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if row + 1 < table.gridRowCount { Divider() }
            }
        }
        .frame(minWidth: CGFloat(columns) * TableGridMetrics.minimumColumn, maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: TableGridMetrics.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: TableGridMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: TableGridMetrics.cornerRadius, style: .continuous))
    }

    private func cell(row: Int, column: Int) -> some View {
        let text = table.gridText(row: row, column: column)
        let alignment = Self.alignment(table.gridAlignment(column: column), text: text, tableRightToLeft: table.statedRightToLeft ?? false)
        return Text(NoteText.inlineMarkdown(text))
            .font(row == 0 ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(alignment.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
            .padding(.horizontal, TableGridMetrics.cellPaddingX)
            .padding(.vertical, TableGridMetrics.cellPaddingY)
            .frame(minHeight: TableGridMetrics.minimumRow)
            .background(row == 0 ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { onTapCell(GridCell(row: row, column: column)) }
    }

    /// As in the editor: a cell's text goes to its own side unless its column says otherwise. These are in terms of the
    /// layout direction, which is the table's, so a right-to-left table's leading is its right.
    private static func alignment(_ column: MarkdownTable.Alignment, text: String, tableRightToLeft: Bool) -> (frame: Alignment, text: TextAlignment) {
        switch column {
        case .none:
            let rightToLeft = MarkdownTable.statedRightToLeft(ofText: text) ?? tableRightToLeft
            return rightToLeft == tableRightToLeft ? (.topLeading, .leading) : (.topTrailing, .trailing)
        case .left: return (.topLeading, .leading)
        case .center: return (.top, .center)
        case .right: return (.topTrailing, .trailing)
        }
    }
}


#if os(iOS)

/// TextKit 2 text view. The delegate only fires on real edits, so opening a note can never change it.
struct MarkdownTextView: UIViewRepresentable {
    let text: String
    let externalRevision: Int
    /// A cell tapped in the note view: it opens with the focus. Nil: the note does, with its caret.
    var startCell: TableCellAddress?
    /// Unused on iPhone. The Mac passes a format tool pressed while reading.
    var startAction: EditorAction?
    var onDidApplyStartAction: () -> Void = {}
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeUIView(context: Context) -> EditorContainerView {
        let view = EditorTextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.typingAttributes = MarkdownStyler.typing
        view.adjustsFontForContentSizeCategory = true
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 80, right: 12)
        view.alwaysBounceVertical = true
        view.backgroundColor = .black
        view.dataDetectorTypes = []
        // In its panel, not in place: in place it would rewrite the text while the autosave and the styling carry on, and
        // hidden marks are text to it, so a half-done rewrite could reach the file.
        view.writingToolsBehavior = .limited
        view.text = text
        context.coordinator.attach(to: view)
        view.inputAccessoryView = EditorKeyboardBar(textView: view, coordinator: context.coordinator)
        context.coordinator.revision = externalRevision
        let startCell = startCell
        let startAction = startAction
        let applied = onDidApplyStartAction
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            if let startCell, let tables = coordinator?.tables, tables.spans.indices.contains(startCell.table) {
                view.layoutIfNeeded()
                tables.focusCell(startCell, caret: .end)
            } else {
                view.becomeFirstResponder()
                if let startAction, let coordinator {
                    coordinator.perform(startAction, in: view)
                    applied()
                }
            }
        }
        return EditorContainerView(textView: view)
    }

    func updateUIView(_ container: EditorContainerView, context: Context) {
        let view = container.textView
        context.coordinator.onEdit = onEdit
        guard context.coordinator.revision != externalRevision else { return }
        context.coordinator.revision = externalRevision
        let selection = view.selectedRange
        let offset = view.contentOffset
        view.text = text
        // The undo steps were for the old text. Replayed on this one, they would write wrong bytes.
        view.undoManager?.removeAllActions()
        view.selectedRange = NSRange(location: MarkdownEdits.caret(at: selection.location, in: text), length: 0)
        context.coordinator.reloaded(view)
        view.setContentOffset(offset, animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String) -> Void
        var revision = 0
        private(set) var preview: LivePreview?
        private(set) var tables: TableOverlay?
        private nonisolated(unsafe) var voiceOverObserver: NSObjectProtocol?
        /// Text size and Bold Text. The styling sets its fonts itself, so `adjustsFontForContentSizeCategory` alone
        /// can't follow them: bold and heading fonts made from a text style's font lose that style.
        private nonisolated(unsafe) var textSizeObservers: [NSObjectProtocol] = []
        private nonisolated(unsafe) var keyboardObserver: NSObjectProtocol?

        /// An edit of `apply` is running: what it does to the selection is on purpose.
        private var applyingEdit = false

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        deinit {
            if let voiceOverObserver { NotificationCenter.default.removeObserver(voiceOverObserver) }
            for observer in textSizeObservers { NotificationCenter.default.removeObserver(observer) }
            if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        }

        /// The note runs on under the keyboard and its bar, for their glass to show it through (`NoteScreen`). This is the
        /// room it makes for them, so that the caret and the note's last line can still come clear. The frame is in the
        /// screen's coordinates, as the notification gives it.
        func keyboardMoved(to frame: CGRect, in view: UITextView) {
            guard let screen = view.window?.windowScene?.screen else { return }
            let keyboard = view.convert(frame, from: screen.coordinateSpace)
            // A keyboard that floats, on an iPad, doesn't reach the bottom: the note goes on around it.
            let covered = keyboard.maxY < view.bounds.maxY ? 0 : max(0, view.bounds.maxY - keyboard.minY)
            let inset = max(0, covered - view.safeAreaInsets.bottom)
            view.contentInset.bottom = inset
            view.verticalScrollIndicatorInsets.bottom = inset
            guard covered > 0 else { return }
            if tables?.hasFocus == true {
                tables?.revealFocus()
            } else if view.isFirstResponder {
                view.scrollRangeToVisible(view.selectedRange)
            }
        }

        /// The user changed the text size or Bold Text: every paragraph again, with fonts of the new size. Only
        /// attributes change, never a character, so nothing is saved. A composition still running is left alone.
        func textSizeChanged(in view: UITextView) {
            guard view.markedTextRange == nil, let preview else { return }
            preview.restyleAll()
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange.location)
            tables?.fontsChanged()
        }

        func reloaded(_ view: UITextView) {
            guard let preview else { return }
            let focus = tables?.focusBeforeReload()
            preview.reload(selection: view.selectedRange, focused: view.isFirstResponder)
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange.location)
            tables?.tablesReloaded(from: focus)
            settleSelection(of: view)
        }

        /// The selection can't rest in a table's hidden text.
        private func settleSelection(of view: UITextView) {
            if let moved = tables?.settleSelection(view.selectedRange, isFirstResponder: view.isFirstResponder) { view.selectedRange = moved }
        }

        func attach(to view: EditorTextView) {
            view.coordinator = self
            let preview = LivePreview(storage: view.textStorage, layoutManager: view.textLayoutManager, hidesMarks: !UIAccessibility.isVoiceOverRunning)
            self.preview = preview
            let tables = TableOverlay(textView: view, preview: preview)
            tables.focusChanged = { [weak self, weak view] in
                guard let self, let view else { return }
                self.tableFocusChanged(in: view)
            }
            self.tables = tables
            preview.editWentUnannounced = { [weak self, weak view] in
                guard let self, let view, view.markedTextRange == nil else { return }
                self.textViewDidChange(view)
            }
            preview.reload(selection: view.selectedRange, focused: view.isFirstResponder)
            tables.tablesChanged()
            settleSelection(of: view)
            voiceOverObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak preview] _ in
                MainActor.assumeIsolated { preview?.setHidesMarks(!UIAccessibility.isVoiceOverRunning) }
            }
            textSizeObservers = [UIContentSizeCategory.didChangeNotification, UIAccessibility.boldTextStatusDidChangeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        guard let self, let view else { return }
                        self.textSizeChanged(in: view)
                    }
                }
            }
            keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self, weak view] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    guard let self, let view, let frame else { return }
                    self.keyboardMoved(to: frame, in: view)
                }
            }
            // With VoiceOver a checkbox has no glyph to find, so ticking is an action on the line.
            view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Tick or Untick This Task") { [weak self, weak view] _ in
                guard let self, let view else { return false }
                return MainActor.assumeIsolated { self.toggleTick(paragraphAt: view.selectedRange.location, in: view) }
            }]
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // A composition's text isn't final, and an undo or a redo puts back what was there.
            guard textView.markedTextRange == nil, textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true else { return true }
            if let tables, !tables.spans.isEmpty {
                switch TableEdits.typing(text, replacing: range, in: textView.textStorage.string as NSString, spans: tables.kitSpans) {
                case .allow:
                    break
                case let .edit(edit):
                    apply(edit, in: textView)
                    return false
                case let .enters(table, atStart):
                    tables.enter(table: table, atStart: atStart)
                    return false
                case let .moveCaret(location):
                    textView.selectedRange = NSRange(location: location, length: 0)
                    return false
                case .ignore:
                    return false
                }
            }
            if let edit = MarkdownEdits.typing(text, replacing: range, in: textView.text) {
                applyGuarded(edit, in: textView)
                return false
            }
            return true
        }

        /// An edit worked out from a key: `MarkdownEdits` may have made it more than what was asked about the table next
        /// to it, so it is asked about again.
        func applyGuarded(_ edit: MarkdownEdits.Edit, in textView: UITextView) {
            guard let safe = TableEdits.safeguarding(edit, in: textView.text, spans: tables?.kitSpans ?? []) else { return }
            apply(safe, in: textView)
        }

        /// A bar button. The edit goes through the text view as typing does: one undo step, and
        /// `textViewDidChange` styles it and saves it. A composition still running waits: its text isn't final.
        func perform(_ action: EditorAction, in textView: UITextView) {
            if let tables, tables.hasFocus { return tables.performInCell(action) }
            guard textView.markedTextRange == nil else { return }
            if action == .table { return insertTable(in: textView) }
            // Marks written into a table's hidden rows would break it, so a selection that holds one is left alone.
            if let tables, tables.selectionHoldsTable(textView.selectedRange) { return }
            let edit = action.edit(in: textView.text, selection: textView.selectedRange)
            guard let safe = TableEdits.safeguarding(edit, in: textView.text, spans: tables?.kitSpans ?? []) else { return }
            apply(safe, in: textView)
        }

        /// The bar's table button: a grid at once, with the caret in its first cell.
        private func insertTable(in textView: UITextView) {
            guard let tables else { return }
            let edit = EditorAction.table.edit(in: textView.text, selection: textView.selectedRange)
            apply(edit, in: textView)
            guard let index = tables.spans.firstIndex(where: { NSLocationInRange(edit.selection.location, $0.range) }) else { return }
            tables.focusCell(TableCellAddress(table: index, cell: GridCell(row: 0, column: 0)), caret: .start)
        }

        /// The bar's Done: puts the keyboard away, from the note or from a cell.
        func dismissKeyboard(from textView: UITextView) {
            if let tables, tables.hasFocus {
                tables.endFocus()
            } else {
                textView.resignFirstResponder()
            }
        }

        /// A cell took or lost the focus: the bar shows what can be done there.
        private func tableFocusChanged(in textView: UITextView) {
            guard let bar = textView.inputAccessoryView as? EditorKeyboardBar else { return }
            guard let tables, let focus = tables.focus, tables.grids.indices.contains(focus.table) else {
                return bar.showTableActions(nil)
            }
            bar.showTableActions(tables.grids[focus.table].menu(of: TableCommand.cellMenu))
        }

        func apply(_ edit: MarkdownEdits.Edit, in textView: UITextView) {
            guard !edit.changesNothing,
                  let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            // What it sets is meant, a place in a new table's source included: that table takes the focus right after this.
            applyingEdit = true
            defer { applyingEdit = false }
            textView.replace(range, withText: edit.replacement)
            textView.selectedRange = edit.selection
        }

        /// A tap on a checkbox: one byte. The caret stays where it is and the keyboard stays as it is.
        @discardableResult
        func toggleTick(paragraphAt location: Int, in textView: UITextView) -> Bool {
            guard textView.markedTextRange == nil, preview?.isInCode(location) != true,
                  let edit = MarkdownEdits.toggleTick(in: textView.text, paragraphAt: location, selection: textView.selectedRange) else { return false }
            apply(edit, in: textView)
            return true
        }

        private func refresh(_ textView: UITextView) {
            // Never restyle in the middle of a composition.
            guard textView.markedTextRange == nil, let preview else { return }
            preview.update(selection: textView.selectedRange, focused: textView.isFirstResponder)
            textView.typingAttributes = preview.typingAttributes(at: textView.selectedRange.location)
            if preview.takeTablesChange() { tables?.tablesChanged() }
        }

        func textViewDidChange(_ textView: UITextView) {
            refresh(textView)
            if tables?.isApplying != true, !applyingEdit { settleSelection(of: textView) }
            onEdit(textView.text)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // A grid writing to the table it shows has already put the selection where it goes.
            if tables?.isApplying == true { return }
            // An edit of `apply` means where it puts it, even in a new table's source: that table takes the focus next.
            if !applyingEdit, textView.markedTextRange == nil, preview?.isEditPending != true,
               let moved = tables?.settleSelection(textView.selectedRange, isFirstResponder: textView.isFirstResponder) {
                textView.selectedRange = moved
                return
            }
            if textView.markedTextRange == nil, let caret = preview?.caretBehindMarker(selection: textView.selectedRange, focused: textView.isFirstResponder) {
                // This comes straight back here, with the caret where it can stay.
                textView.selectedRange = NSRange(location: caret, length: 0)
                return
            }
            guard preview?.isEditPending == true else { return refresh(textView) }
            // Part of an edit: `textViewDidChange` comes next. If it doesn't, nothing must stay unstyled.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.preview?.isEditPending == true else { return }
                self.refresh(textView)
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) { refresh(textView) }
        func textViewDidEndEditing(_ textView: UITextView) { refresh(textView) }
    }
}

/// The real text view of the editor, with what plain `UITextView` can't do for Live Preview.
final class EditorTextView: UITextView {
    weak var coordinator: MarkdownTextView.Coordinator?

    /// A button wins a single tap over the recognizers of the view it is in (UIGestureRecognizer's documentation), so a tap
    /// on a checkbox neither moves the caret nor brings up the keyboard. It has no look of its own: it goes where the
    /// finger lands, when that is a checkbox.
    private(set) lazy var boxTarget: TaskBoxTarget = {
        let target = TaskBoxTarget(frame: .zero)
        target.isAccessibilityElement = false
        target.addAction(UIAction { [weak self, weak target] _ in
            guard let self, let target else { return }
            self.coordinator?.toggleTick(paragraphAt: target.paragraph, in: self)
        }, for: .touchUpInside)
        addSubview(target)
        return target
    }()

    /// The paragraph whose checkbox is under a point of this view.
    func taskParagraph(at point: CGPoint) -> Int? {
        coordinator?.preview?.taskParagraph(atContainerPoint: CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top))
    }

    /// The grids sit over their tables' first lines, wherever scrolling or new layout puts them.
    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.tables?.layoutGrids()
    }

    override var canBecomeFirstResponder: Bool {
        coordinator?.tables?.isEditorResigning != true && super.canBecomeFirstResponder
    }

    /// At the very end of a note whose last line is a table's, the caret has only that hidden line to sit on, with no
    /// height: it shows where what is typed will go, under the grid.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        guard let y = coordinator?.tables?.caretLineUnderLastTable(at: offset(from: beginningOfDocument, to: position)) else { return rect }
        let height = PlatformFont.preferredFont(forTextStyle: .body).lineHeight
        let x = coordinator?.tables?.spans.last?.rightToLeft == true ? bounds.width - textLeftEdge - rect.width : textLeftEdge
        return CGRect(x: x, y: y, width: max(rect.width, 2), height: height)
    }

    /// VoiceOver reads the note's text from here, and a table in it is its grid, a neighbour of this view.
    override var accessibilityValue: String? {
        get {
            guard UIAccessibility.isVoiceOverRunning, let ranges = coordinator?.tables?.tableRanges, !ranges.isEmpty else { return super.accessibilityValue }
            var text = (self.text ?? "") as NSString
            for range in ranges.reversed() where NSMaxRange(range) <= text.length {
                text = text.replacingCharacters(in: range, with: "Table.\n") as NSString
            }
            return text as String
        }
        set { super.accessibilityValue = newValue }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.point(inside: point, with: event), let paragraph = taskParagraph(at: point) {
            boxTarget.paragraph = paragraph
            boxTarget.frame = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            return boxTarget
        }
        return super.hitTest(point, with: event)
    }

    /// A drag that starts on a checkbox is still a scroll.
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view === boxTarget ? true : super.touchesShouldCancel(in: view)
    }

    /// The text view's own tap recognizers too, in case the rule above doesn't reach them: a tap on a checkbox places no caret.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer is UITapGestureRecognizer, taskParagraph(at: recognizer.location(in: self)) != nil { return false }
        // A press on a grid is the grid's: it places no caret in the hidden text. A drag on one still scrolls the note.
        if recognizer !== panGestureRecognizer, let tables = coordinator?.tables {
            let point = recognizer.location(in: self)
            if tables.grids.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return false }
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    /// Tab on a list item goes through the text view's delegate like any key. Its opposite is no text, so it comes here.
    override var keyCommands: [UIKeyCommand]? {
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentFromKeyboard))
        outdent.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [outdent]
    }

    @objc private func outdentFromKeyboard() {
        coordinator?.perform(.outdent, in: self)
    }

    /// Copy gives the Markdown source, plain, marks and all: never the look, with its hidden characters.
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        UIPasteboard.general.string = (text as NSString).substring(with: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        copy(sender)
        // As a delete would: lines cut out of a list renumber it.
        let plain = MarkdownEdits.Edit(range: selectedRange, replacement: "", selection: NSRange(location: selectedRange.location, length: 0))
        coordinator?.applyGuarded(MarkdownEdits.typing("", replacing: selectedRange, in: text) ?? plain, in: self)
    }
}

final class TaskBoxTarget: UIButton {
    var paragraph = 0

    /// Found only by the text view's own hit test, when a checkbox is under the finger right now. Otherwise, sitting where
    /// the last tap left it, it would catch the next tap nearby and flip that old task again.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

#else

/// The same on Mac.
struct MarkdownTextView: NSViewRepresentable {
    let text: String
    let externalRevision: Int
    /// A cell clicked in the note view: it opens with the focus. Nil: the note does, with its caret.
    var startCell: TableCellAddress?
    /// A format tool pressed while reading. Applied once the editor is the first responder.
    var startAction: EditorAction?
    var onDidApplyStartAction: () -> Void = {}
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = MacNotesPalette.editor
        guard let view = scroll.documentView as? EditorTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.backgroundColor = MacNotesPalette.editor
        view.drawsBackground = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        // In its panel, not in place: in place it would rewrite the text while the autosave and the styling carry on, and
        // hidden marks are text to it, so a half-done rewrite could reach the file.
        view.writingToolsBehavior = .limited
        view.textContainerInset = NSSize(width: 12, height: 8)
        view.typingAttributes = MarkdownStyler.typing
        view.string = text
        view.setAccessibilityIdentifier("note.editor.text")
        context.coordinator.attach(to: view)
        context.coordinator.revision = externalRevision
        let startCell = startCell
        let startAction = startAction
        let applied = onDidApplyStartAction
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            if let startCell, let tables = coordinator?.tables, tables.spans.indices.contains(startCell.table) {
                tables.focusCell(startCell, caret: .end)
            } else {
                view.window?.makeFirstResponder(view)
                if let startAction, let coordinator {
                    coordinator.perform(startAction, in: view)
                    applied()
                }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onEdit = onEdit
        guard context.coordinator.revision != externalRevision, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.revision = externalRevision
        let selection = view.selectedRange()
        view.string = text
        // The undo steps were for the old text. Replayed on this one, they would write wrong bytes.
        view.undoManager?.removeAllActions()
        view.setSelectedRange(NSRange(location: MarkdownEdits.caret(at: selection.location, in: text), length: 0))
        context.coordinator.reloaded(view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (String) -> Void
        var revision = 0
        private(set) var preview: LivePreview?
        private(set) var tables: TableOverlay?
        private var voiceOverObservation: NSKeyValueObservation?
        private var isApplying = false

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func reloaded(_ view: NSTextView) {
            guard let preview else { return }
            let focus = tables?.focusBeforeReload()
            preview.reload(selection: view.selectedRange(), focused: view.window?.firstResponder === view)
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange().location)
            tables?.tablesReloaded(from: focus)
            settleSelection(of: view)
        }

        /// The selection can't rest in a table's hidden text.
        private func settleSelection(of view: NSTextView) {
            if let moved = tables?.settleSelection(view.selectedRange(), isFirstResponder: view.window?.firstResponder === view) { view.setSelectedRange(moved) }
        }

        func attach(to view: EditorTextView) {
            guard let storage = view.textStorage else { return }
            view.coordinator = self
            let preview = LivePreview(storage: storage, layoutManager: view.textLayoutManager, hidesMarks: !NSWorkspace.shared.isVoiceOverEnabled)
            self.preview = preview
            let tables = TableOverlay(textView: view, preview: preview)
            self.tables = tables
            preview.editWentUnannounced = { [weak self, weak view] in
                guard let self, let view, !view.hasMarkedText() else { return }
                self.textChanged(in: view)
            }
            preview.reload(selection: view.selectedRange(), focused: view.window?.firstResponder === view)
            tables.tablesChanged()
            settleSelection(of: view)
            voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak preview] workspace, _ in
                let enabled = workspace.isVoiceOverEnabled
                DispatchQueue.main.async { preview?.setHidesMarks(!enabled) }
            }
            // With VoiceOver a checkbox has no glyph to find, so ticking is an action on the line.
            view.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Tick or Untick This Task") { [weak self, weak view] in
                guard let self, let view else { return false }
                return MainActor.assumeIsolated { self.toggleTick(paragraphAt: view.selectedRange().location, in: view) }
            }])
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            // `apply` comes back through here, and it has decided already. A composition's text isn't final.
            guard !isApplying, let text, !textView.hasMarkedText() else { return true }
            if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true { return true }
            if let tables, !tables.spans.isEmpty {
                switch TableEdits.typing(text, replacing: range, in: textView.string as NSString, spans: tables.kitSpans) {
                case .allow:
                    break
                case let .edit(edit):
                    apply(edit, in: textView)
                    return false
                case let .enters(table, atStart):
                    tables.enter(table: table, atStart: atStart)
                    return false
                case let .moveCaret(location):
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                    return false
                case .ignore:
                    return false
                }
            }
            if let edit = MarkdownEdits.typing(text, replacing: range, in: textView.string) {
                // `MarkdownEdits` may have made it more than what was asked about the table next to it.
                if let safe = TableEdits.safeguarding(edit, in: textView.string, spans: tables?.kitSpans ?? []) { apply(safe, in: textView) }
                return false
            }
            return true
        }

        /// Tab on a list item goes through `shouldChangeTextIn` like any key. Its opposite is no text, so it comes here.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertBacktab(_:)), !textView.hasMarkedText() else { return false }
            let edit = EditorAction.outdent.edit(in: textView.string, selection: textView.selectedRange())
            guard !edit.changesNothing else { return false }
            apply(edit, in: textView)
            return true
        }

        /// A menu item or a toolbar button. The edit goes through the text view as typing does. A composition still
        /// running waits: its text isn't final.
        func perform(_ action: EditorAction, in view: NSTextView) {
            if let tables, tables.hasFocus { return tables.performInCell(action) }
            guard !view.hasMarkedText() else { return }
            if action == .table { return insertTable(in: view) }
            // Marks written into a table's hidden rows would break it, so a selection that holds one is left alone.
            if let tables, tables.selectionHoldsTable(view.selectedRange()) { return }
            let edit = action.edit(in: view.string, selection: view.selectedRange())
            guard let safe = TableEdits.safeguarding(edit, in: view.string, spans: tables?.kitSpans ?? []) else { return }
            apply(safe, in: view)
        }

        /// The table button: a grid at once, with the caret in its first cell.
        private func insertTable(in view: NSTextView) {
            guard let tables else { return }
            let edit = EditorAction.table.edit(in: view.string, selection: view.selectedRange())
            apply(edit, in: view)
            guard let index = tables.spans.firstIndex(where: { NSLocationInRange(edit.selection.location, $0.range) }) else { return }
            tables.focusCell(TableCellAddress(table: index, cell: GridCell(row: 0, column: 0)), caret: .start)
        }

        /// A table's edit, through the same checks as `apply` but its own undo.
        func writingTable(_ write: () -> Void) {
            isApplying = true
            defer { isApplying = false }
            write()
        }

        /// One undo step of its own, not merged with the typing around it.
        func apply(_ edit: MarkdownEdits.Edit, in view: NSTextView) {
            guard !edit.changesNothing else { return }
            isApplying = true
            defer { isApplying = false }
            view.breakUndoCoalescing()
            view.insertText(edit.replacement, replacementRange: edit.range)
            view.setSelectedRange(edit.selection)
            view.breakUndoCoalescing()
        }

        /// A click on a checkbox: one byte. The caret stays where it is.
        @discardableResult
        func toggleTick(paragraphAt location: Int, in view: NSTextView) -> Bool {
            guard !view.hasMarkedText(), preview?.isInCode(location) != true,
                  let edit = MarkdownEdits.toggleTick(in: view.string, paragraphAt: location, selection: view.selectedRange()) else { return false }
            apply(edit, in: view)
            return true
        }

        func refresh(_ view: NSTextView) {
            // Never restyle in the middle of a composition.
            guard !view.hasMarkedText(), let preview else { return }
            preview.update(selection: view.selectedRange(), focused: view.window?.firstResponder === view)
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange().location)
            if preview.takeTablesChange() { tables?.tablesChanged() }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            textChanged(in: view)
        }

        private func textChanged(in view: NSTextView) {
            refresh(view)
            if tables?.isApplying != true, !isApplying { settleSelection(of: view) }
            onEdit(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // A grid writing to the table it shows has already put the selection where it goes.
            if tables?.isApplying == true { return }
            // An edit of `apply` means where it puts it, even in a new table's source: that table takes the focus next.
            if !isApplying, !view.hasMarkedText(), preview?.isEditPending != true,
               let moved = tables?.settleSelection(view.selectedRange(), isFirstResponder: view.window?.firstResponder === view) {
                view.setSelectedRange(moved)
                return
            }
            if !view.hasMarkedText(), let caret = preview?.caretBehindMarker(selection: view.selectedRange(), focused: view.window?.firstResponder === view) {
                // This comes straight back here, with the caret where it can stay.
                view.setSelectedRange(NSRange(location: caret, length: 0))
                return
            }
            guard preview?.isEditPending == true else { return refresh(view) }
            // Part of an edit: `textDidChange` comes next. If it doesn't, nothing must stay unstyled.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.preview?.isEditPending == true else { return }
                self.refresh(view)
            }
        }
    }
}

/// The real text view of the editor, with what plain `NSTextView` can't do for Live Preview.
final class EditorTextView: NSTextView {
    weak var coordinator: MarkdownTextView.Coordinator?

    /// The paragraph whose checkbox is under a point of this view.
    func taskParagraph(at point: NSPoint) -> Int? {
        coordinator?.preview?.taskParagraph(atContainerPoint: CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y))
    }

    /// A press on a checkbox, waiting to see whether it is a click or the start of a selection.
    private var pressOnBox: (paragraph: Int, down: NSEvent)?

    /// The grids sit over their tables' first lines, wherever scrolling or new layout puts them.
    override func layout() {
        super.layout()
        coordinator?.tables?.layoutGrids()
    }

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        coordinator?.tables?.layoutGrids()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator?.tables?.layoutGrids()
    }

    /// The grids are this view's children to a screen reader too.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + (coordinator?.tables?.grids.filter { !$0.isHidden } ?? [])
    }

    override func mouseDown(with event: NSEvent) {
        pressOnBox = nil
        let plain = event.clickCount == 1 && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        if plain, let paragraph = taskParagraph(at: convert(event.locationInWindow, from: nil)) {
            pressOnBox = (paragraph, event)
            return
        }
        super.mouseDown(with: event)
        // A click under a table that ends the note, with no line ending, is a click for a line to write on.
        let selection = selectedRange()
        if selection.length == 0, window?.firstResponder === self { coordinator?.tables?.addLineUnderLastTable(at: selection.location) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressOnBox else { return super.mouseDragged(with: event) }
        // A selection after all: the text view's own tracking takes it from the press.
        pressOnBox = nil
        super.mouseDown(with: press.down)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press = pressOnBox else { return super.mouseUp(with: event) }
        pressOnBox = nil
        coordinator?.toggleTick(paragraphAt: press.paragraph, in: self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // The window's first responder changes after this returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.refresh(self)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.refresh(self)
        }
        return resigned
    }

    /// From the Format menu and the toolbar, through the responder chain.
    @objc func performEditorAction(_ sender: Any?) {
        guard let action = (sender as? EditorActionSender)?.action else { return }
        coordinator?.perform(action, in: self)
    }
}

#endif


