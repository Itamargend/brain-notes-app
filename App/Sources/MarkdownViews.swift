import BrainNotesKit
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
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

private struct BlockView: View {
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
            row(indent: indent, marker: Text("•").foregroundStyle(.secondary))
        case let .numbered(marker, indent):
            row(indent: indent, marker: Text(marker).foregroundStyle(.secondary).monospacedDigit())
        case let .task(done, indent):
            row(indent: indent, marker: Text(Image(systemName: done ? "checkmark.circle.fill" : "circle")).foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
                .accessibilityLabel((done ? "Done: " : "To do: ") + block.text)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3)
                let s = inline
                tappable(Text(s).foregroundStyle(.secondary), s)
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
        }
    }

    private func row(indent: Int, marker: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            let s = inline
            tappable(Text(s), s)
        }
        .padding(.leading, CGFloat(indent) * 16)
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

/// Markdown attributes for the editor, one paragraph at a time. Only the look changes; the text is the
/// file's text, byte for byte, because the storage is never edited here.
enum MarkdownStyler {
    private static var bodyFont: PlatformFont { .preferredFont(forTextStyle: .body) }

    private static func font(for paragraph: String) -> PlatformFont {
        var level = 0
        var spaces = 0
        for c in paragraph {
            if c == " ", level == 0, spaces < 3 {
                spaces += 1
            } else if c == "#" {
                level += 1
            } else {
                if level > 0, level <= 6, c != " ", c != "\t", c != "\n", c != "\r" { level = 0 }
                break
            }
        }
        guard level >= 1, level <= 6 else { return bodyFont }
        let style: PlatformFont.TextStyle = level == 1 ? .title1 : level == 2 ? .title2 : level == 3 ? .title3 : .headline
        let base = PlatformFont.preferredFont(forTextStyle: style)
        #if os(iOS)
        if let d = base.fontDescriptor.withSymbolicTraits(.traitBold) { return UIFont(descriptor: d, size: 0) }
        return base
        #else
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        #endif
    }

    private static func attributes(for paragraph: String) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        let rtl = MarkdownEdits.isRightToLeft(paragraph: paragraph)
        // Explicit per paragraph: Hebrew aligns right and English left, whatever the system language is.
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.alignment = rtl ? .right : .left
        style.paragraphSpacing = 4
        #if os(iOS)
        let color = UIColor.label
        #else
        let color = NSColor.labelColor
        #endif
        return [.font: font(for: paragraph), .foregroundColor: color, .paragraphStyle: style]
    }

    /// Styles every paragraph touching `range`.
    static func style(_ storage: NSTextStorage, in range: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let clamped = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        let whole = ns.paragraphRange(for: clamped)
        storage.beginEditing()
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, enclosing, _ in
            storage.setAttributes(attributes(for: ns.substring(with: paragraph)), range: enclosing)
        }
        storage.endEditing()
    }

    /// Typing attributes for an empty note.
    static var typing: [NSAttributedString.Key: Any] { attributes(for: "") }
}

#if os(iOS)

/// TextKit 2 text view. The delegate only fires on real edits, so opening a note can never change it.
struct MarkdownTextView: UIViewRepresentable {
    let text: String
    let externalRevision: Int
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.typingAttributes = MarkdownStyler.typing
        view.adjustsFontForContentSizeCategory = true
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 80, right: 12)
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.text = text
        MarkdownStyler.style(view.textStorage, in: NSRange(location: 0, length: view.textStorage.length))
        view.inputAccessoryView = EditorKeyboardBar.make(for: view, coordinator: context.coordinator)
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
        MarkdownStyler.style(view.textStorage, in: NSRange(location: 0, length: view.textStorage.length))
        let length = view.textStorage.length
        view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        view.setContentOffset(offset, animated: false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String) -> Void
        var revision = 0
        private var edited = NSRange(location: 0, length: 0)

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            edited = NSRange(location: range.location, length: (text as NSString).length)
            return true
        }

        /// A bar button. The edit goes through the text view as typing does: one undo step, and
        /// `textViewDidChange` styles it and saves it. A composition still running waits: its text isn't final.
        func perform(_ action: EditorAction, in textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let edit = action.edit(in: textView.text, selection: textView.selectedRange)
            guard let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            // `replace` calls `textViewDidChange` but not `shouldChangeTextIn`, so what changed is noted here.
            edited = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
            textView.replace(range, withText: edit.replacement)
            textView.selectedRange = edit.selection
        }

        func textViewDidChange(_ textView: UITextView) {
            // Never restyle in the middle of a composition.
            if textView.markedTextRange == nil {
                MarkdownStyler.style(textView.textStorage, in: edited)
                let length = textView.textStorage.length
                if length > 0 {
                    let at = min(textView.selectedRange.location, length - 1)
                    textView.typingAttributes = textView.textStorage.attributes(at: at, effectiveRange: nil)
                }
            }
            onEdit(textView.text)
        }
    }
}

#else

/// The same on Mac.
struct MarkdownTextView: NSViewRepresentable {
    let text: String
    let externalRevision: Int
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 8)
        view.typingAttributes = MarkdownStyler.typing
        view.string = text
        if let storage = view.textStorage {
            MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length))
        }
        view.setAccessibilityIdentifier("note.editor.text")
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
        if let storage = view.textStorage {
            MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length))
            view.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (String) -> Void
        var revision = 0
        private var edited = NSRange(location: 0, length: 0)

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            edited = NSRange(location: range.location, length: ((text ?? "") as NSString).length)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if !view.hasMarkedText(), let storage = view.textStorage {
                MarkdownStyler.style(storage, in: edited)
                let length = storage.length
                if length > 0 {
                    let at = min(view.selectedRange().location, length - 1)
                    view.typingAttributes = storage.attributes(at: at, effectiveRange: nil)
                }
            }
            onEdit(view.string)
        }
    }
}

#endif
