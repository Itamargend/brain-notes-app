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

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { BlockView(block: $0, onTapText: onTapText) }
        }
    }
}

struct BlockView: View {
    let block: MarkdownBlock
    let onTapText: () -> Void

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
            TablePreview(table: table)
                .onTapGesture(perform: onTapText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.tableLabel(table))
                .environment(\.layoutDirection, table.isRightToLeft ? .rightToLeft : .leftToRight)
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


/// A GFM table in the note viewer: a grid of cells, as Notes would show it. Tapping starts editing; the bytes stay
/// the pipe Markdown until then.
struct TablePreview: View {
    let table: MarkdownTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(texts: table.headerTexts, alignments: table.alignments, header: true)
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, _ in
                row(
                    texts: (0..<table.columnCount).map { table.text(row: index, column: $0) },
                    alignments: table.alignments,
                    header: false
                )
                if index + 1 < table.rows.count {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func row(texts: [String], alignments: [MarkdownTable.Alignment], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(texts.enumerated()), id: \.offset) { i, text in
                let alignment = alignments.indices.contains(i) ? alignments[i] : .none
                Text(NoteText.inlineMarkdown(text))
                    .font(header ? .subheadline.weight(.semibold) : .body)
                    .frame(maxWidth: .infinity, alignment: Self.frameAlignment(alignment))
                    .multilineTextAlignment(Self.textAlignment(alignment))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(header ? Color.white.opacity(0.08) : Color.clear)
                if i + 1 < texts.count {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1)
                }
            }
        }
    }

    private static func frameAlignment(_ a: MarkdownTable.Alignment) -> Alignment {
        switch a {
        case .none, .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private static func textAlignment(_ a: MarkdownTable.Alignment) -> TextAlignment {
        switch a {
        case .none, .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}


#if os(iOS)

/// TextKit 2 text view. The delegate only fires on real edits, so opening a note can never change it.
struct MarkdownTextView: UIViewRepresentable {
    let text: String
    let externalRevision: Int
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeUIView(context: Context) -> UITextView {
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
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
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
        private nonisolated(unsafe) var voiceOverObserver: NSObjectProtocol?
        /// Text size and Bold Text. The styling sets its fonts itself, so `adjustsFontForContentSizeCategory` alone
        /// can't follow them: bold and heading fonts made from a text style's font lose that style.
        private nonisolated(unsafe) var textSizeObservers: [NSObjectProtocol] = []
        private nonisolated(unsafe) var keyboardObserver: NSObjectProtocol?

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
            if covered > 0, view.isFirstResponder { view.scrollRangeToVisible(view.selectedRange) }
        }

        /// The user changed the text size or Bold Text: every paragraph again, with fonts of the new size. Only
        /// attributes change, never a character, so nothing is saved. A composition still running is left alone.
        func textSizeChanged(in view: UITextView) {
            guard view.markedTextRange == nil, let preview else { return }
            preview.restyleAll()
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange.location)
        }

        func reloaded(_ view: UITextView) {
            guard let preview else { return }
            preview.reload(selection: view.selectedRange, focused: view.isFirstResponder)
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange.location)
        }

        func attach(to view: EditorTextView) {
            view.coordinator = self
            let preview = LivePreview(storage: view.textStorage, layoutManager: view.textLayoutManager, hidesMarks: !UIAccessibility.isVoiceOverRunning)
            self.preview = preview
            preview.reload(selection: view.selectedRange, focused: view.isFirstResponder)
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
            if let edit = MarkdownEdits.typing(text, replacing: range, in: textView.text) {
                apply(edit, in: textView)
                return false
            }
            return true
        }

        /// A bar button. The edit goes through the text view as typing does: one undo step, and
        /// `textViewDidChange` styles it and saves it. A composition still running waits: its text isn't final.
        func perform(_ action: EditorAction, in textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            apply(action.edit(in: textView.text, selection: textView.selectedRange), in: textView)
        }

        func apply(_ edit: MarkdownEdits.Edit, in textView: UITextView) {
            guard !edit.changesNothing,
                  let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
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
        }

        func textViewDidChange(_ textView: UITextView) {
            refresh(textView)
            onEdit(textView.text)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
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
        coordinator?.apply(MarkdownEdits.typing("", replacing: selectedRange, in: text) ?? plain, in: self)
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
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        guard let view = scroll.documentView as? EditorTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.backgroundColor = .black
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
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
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
        private var voiceOverObservation: NSKeyValueObservation?
        private var isApplying = false

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func reloaded(_ view: NSTextView) {
            guard let preview else { return }
            preview.reload(selection: view.selectedRange(), focused: view.window?.firstResponder === view)
            view.typingAttributes = preview.typingAttributes(at: view.selectedRange().location)
        }

        func attach(to view: EditorTextView) {
            guard let storage = view.textStorage else { return }
            view.coordinator = self
            let preview = LivePreview(storage: storage, layoutManager: view.textLayoutManager, hidesMarks: !NSWorkspace.shared.isVoiceOverEnabled)
            self.preview = preview
            preview.reload(selection: view.selectedRange(), focused: view.window?.firstResponder === view)
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
            if let edit = MarkdownEdits.typing(text, replacing: range, in: textView.string) {
                apply(edit, in: textView)
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
            guard !view.hasMarkedText() else { return }
            apply(action.edit(in: view.string, selection: view.selectedRange()), in: view)
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
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            refresh(view)
            onEdit(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
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

    override func mouseDown(with event: NSEvent) {
        pressOnBox = nil
        let plain = event.clickCount == 1 && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        if plain, let paragraph = taskParagraph(at: convert(event.locationInWindow, from: nil)) {
            pressOnBox = (paragraph, event)
            return
        }
        super.mouseDown(with: event)
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


