import BrainNotesKit
import Foundation
import SwiftUI

/// Live bridge between the native `UITextView` / `NSTextView` coordinator and SwiftUI formatting popovers & link sheets.
@MainActor @Observable
final class EditorBridge {
    struct LinkDraft: Identifiable, Equatable {
        let id = UUID()
        var existing: MarkdownEdits.LinkMatch?
        var initialTitle: String
        var initialDestination: String
    }

    var activeFormat = MarkdownEdits.ActiveFormat()
    var selectedText = ""
    var selectedHighlightColor: HighlightColor = .mint
    var showFormatPopover = false
    var linkDraft: LinkDraft?
    var isKeyboardActive = false
    var restoreKeyboardAfterSheet = false

    @ObservationIgnored var applyAction: ((EditorAction) -> Void)?
    @ObservationIgnored var applyHighlight: ((HighlightColor, Bool) -> Void)?
    @ObservationIgnored var applyLink: ((String, String, Bool, NSRange?) -> Void)?
    @ObservationIgnored var removeLink: ((NSRange) -> Void)?
    @ObservationIgnored var dismissKeyboard: (() -> Void)?
    @ObservationIgnored var restoreKeyboardIfNeeded: (() -> Void)?
    @ObservationIgnored var onOpenLinkDestination: ((MarkdownEdits.LinkMatch) -> Void)?

    func presentLinkEditor(for match: MarkdownEdits.LinkMatch? = nil) {
        let target = match ?? activeFormat.link
        if let target {
            linkDraft = LinkDraft(
                existing: target,
                initialTitle: target.title,
                initialDestination: target.destination
            )
        } else {
            let trimmedSelection = selectedText
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            linkDraft = LinkDraft(
                existing: nil,
                initialTitle: trimmedSelection,
                initialDestination: ""
            )
        }
    }
}

extension HighlightColor {
    var swiftUIColor: Color {
        switch self {
        case .mint: Color(red: 0.18, green: 0.85, blue: 0.76)
        case .purple: Color(red: 0.72, green: 0.40, blue: 0.96)
        case .pink: Color(red: 0.98, green: 0.32, blue: 0.62)
        case .orange: Color(red: 1.00, green: 0.58, blue: 0.16)
        case .amber: Color(red: 0.96, green: 0.78, blue: 0.20)
        }
    }
}

/// The editor's text actions, on the iPhone's bar and in the Mac's Format menu and toolbar. A list, so a test can check
/// every symbol: a wrong name is an invisible button.
enum EditorAction: String, CaseIterable {
    case title, heading, subheading, body, monostyled
    case bold, italic, underline, strikethrough, highlight, code
    case checklist, bullet, dashed, numbered, quote, indent, outdent, link, table, direction

    var symbol: String {
        switch self {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat.size.smaller"
        case .body: "text.alignleft"
        case .monostyled: "curlybraces"
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .checklist: "checklist"
        case .bullet: "list.bullet"
        case .dashed: "list.dash"
        case .numbered: "list.number"
        case .quote: "text.quote"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        case .link: "link"
        case .table: "tablecells"
        case .direction: "arrow.left.arrow.right"
        }
    }

    var label: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .monostyled: "Monostyled"
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Code"
        case .checklist: "Checklist"
        case .bullet: "Bulleted List"
        case .dashed: "Dashed List"
        case .numbered: "Numbered List"
        case .quote: "Block Quote"
        case .indent: "Indent"
        case .outdent: "Outdent"
        case .link: "Add Link…"
        case .table: "Table"
        case .direction: "Switch Between Right to Left and Left to Right"
        }
    }

    func edit(in text: String, selection: NSRange) -> MarkdownEdits.Edit {
        switch self {
        case .title: MarkdownEdits.toggleHeading(1, in: text, selection: selection)
        case .heading: MarkdownEdits.toggleHeading(2, in: text, selection: selection)
        case .subheading: MarkdownEdits.toggleHeading(3, in: text, selection: selection)
        case .body: MarkdownEdits.setBody(in: text, selection: selection)
        case .monostyled: MarkdownEdits.toggleMonostyled(in: text, selection: selection)
        case .bold: MarkdownEdits.toggleInlineWrap("**", in: text, selection: selection)
        case .italic: MarkdownEdits.toggleInlineWrap("*", in: text, selection: selection)
        case .underline: MarkdownEdits.toggleUnderline(in: text, selection: selection)
        case .strikethrough: MarkdownEdits.toggleInlineWrap("~~", in: text, selection: selection)
        case .highlight: MarkdownEdits.toggleHighlight(color: .mint, in: text, selection: selection)
        case .code: MarkdownEdits.toggleInlineWrap("`", in: text, selection: selection)
        case .checklist: MarkdownEdits.toggleTask(in: text, selection: selection)
        case .bullet: MarkdownEdits.toggleBullet(in: text, selection: selection)
        case .dashed: MarkdownEdits.toggleDashed(in: text, selection: selection)
        case .numbered: MarkdownEdits.toggleNumbered(in: text, selection: selection)
        case .quote: MarkdownEdits.toggleQuote(in: text, selection: selection)
        case .indent: MarkdownEdits.indent(in: text, selection: selection)
        case .outdent: MarkdownEdits.outdent(in: text, selection: selection)
        case .link: MarkdownEdits.insertWikiLink(in: text, selection: selection)
        case .table: MarkdownEdits.insertTable(in: text, selection: selection)
        case .direction: MarkdownEdits.toggleDirection(in: text, selection: selection)
        }
    }
}

/// What the iPhone's bar holds, in order. Apart from the view, so that a test on any platform can read it.
enum EditorBar {
    /// The Aa popover actions, by section.
    static let styleMenu: [[EditorAction]] = [
        [.title, .heading, .subheading, .body, .monostyled],
        [.bold, .italic, .underline, .strikethrough, .highlight, .code],
        [.bullet, .dashed, .numbered, .quote],
        [.indent, .outdent],
    ]
    /// The streamlined Apple Notes buttons next to Aa.
    static let buttons: [EditorAction] = [.checklist, .table, .link, .direction]
}

// MARK: - Apple Notes `Aa` Format Popover

struct FormatPopoverView: View {
    @Bindable var bridge: EditorBridge
    var perform: (EditorAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            inlineBar
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)

            Divider()
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                styleRow(.title, block: .title) {
                    Text("Title").font(.system(size: 22, weight: .bold))
                }
                styleRow(.heading, block: .heading) {
                    Text("Heading").font(.system(size: 17, weight: .bold))
                }
                styleRow(.subheading, block: .subheading) {
                    Text("Subheading").font(.system(size: 15, weight: .bold))
                }
                styleRow(.body, block: .body) {
                    Text("Body").font(.system(size: 15, weight: .regular))
                }
                styleRow(.monostyled, block: .monostyled) {
                    Text("Monostyled").font(.system(size: 14, weight: .regular, design: .monospaced))
                }
                styleRow(.bullet, block: .bullet) {
                    Text("•  Bulleted List").font(.system(size: 15, weight: .regular))
                }
                styleRow(.dashed, block: .dashed) {
                    Text("–  Dashed List").font(.system(size: 15, weight: .regular))
                }
                styleRow(.numbered, block: .numbered) {
                    Text("1. Numbered List").font(.system(size: 15, weight: .regular))
                }
            }
            .padding(.horizontal, 6)

            Divider()
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                styleRow(.quote, block: .quote) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary)
                            .frame(width: 2.5, height: 15)
                        Text("Block Quote")
                            .font(.system(size: 15, weight: .regular))
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 232)
        .animation(.snappy(duration: 0.16), value: bridge.activeFormat)
        .accessibilityIdentifier("editor.formatPopover")
    }

    private var inlineBar: some View {
        HStack(spacing: 4) {
            inlineToggle(isActive: bridge.activeFormat.isBold, label: "Bold", id: "format.bold") {
                perform(.bold)
            } content: {
                Text("B").font(.system(size: 17, weight: .bold))
            }

            inlineToggle(isActive: bridge.activeFormat.isItalic, label: "Italic", id: "format.italic") {
                perform(.italic)
            } content: {
                Text("I").font(.system(size: 17, weight: .regular, design: .serif)).italic()
            }

            inlineToggle(isActive: bridge.activeFormat.isUnderline, label: "Underline", id: "format.underline") {
                perform(.underline)
            } content: {
                Text("U").font(.system(size: 16, weight: .regular)).underline()
            }

            inlineToggle(isActive: bridge.activeFormat.isStrikethrough, label: "Strikethrough", id: "format.strikethrough") {
                perform(.strikethrough)
            } content: {
                Text("S").font(.system(size: 16, weight: .regular)).strikethrough()
            }

            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 22)
                .padding(.horizontal, 4)

            inlineToggle(isActive: bridge.activeFormat.highlight != nil, label: "Highlight", id: "format.highlight") {
                let color = bridge.activeFormat.highlight ?? bridge.selectedHighlightColor
                if let apply = bridge.applyHighlight {
                    apply(color, false)
                } else {
                    perform(.highlight)
                }
            } content: {
                VStack(spacing: 2) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 14, weight: .medium))
                    Capsule()
                        .fill((bridge.activeFormat.highlight ?? bridge.selectedHighlightColor).swiftUIColor)
                        .frame(width: 16, height: 2)
                }
            }

            Menu {
                ForEach(HighlightColor.allCases, id: \.self) { color in
                    Button {
                        bridge.selectedHighlightColor = color
                        bridge.applyHighlight?(color, bridge.activeFormat.highlight != nil)
                    } label: {
                        if (bridge.activeFormat.highlight ?? bridge.selectedHighlightColor) == color {
                            Label(color.label, systemImage: "checkmark")
                        } else {
                            Text(color.label)
                        }
                    }
                }
            } label: {
                Circle()
                    .fill((bridge.activeFormat.highlight ?? bridge.selectedHighlightColor).swiftUIColor)
                    .frame(width: 11, height: 11)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Highlight Color")
            .accessibilityIdentifier("format.highlightColor")
        }
    }

    private func inlineToggle<Content: View>(
        isActive: Bool,
        label: String,
        id: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.24) : Color.clear)
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func styleRow<Content: View>(
        _ action: EditorAction,
        block: MarkdownEdits.BlockStyle,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCurrent = bridge.activeFormat.block == block
        return Button {
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 16)
                content()
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("format.style.\(action.rawValue)")
    }
}

#if os(iOS)
/// Native iPhone Apple Notes 4-row Format card (`Format` + `×`, horizontal style strip, `[B|I|U|S]` + `[Highlight|Color]`,
/// `[Bullet|Dashed|Numbered]` + `[Outdent|Indent]` + `[Quote]`).
struct PhoneFormatSheetView: View {
    @Bindable var bridge: EditorBridge
    var perform: (EditorAction) -> Void

    private static let cellSurface = Color.white.opacity(0.09)
    private static let dividerInk = Color.white.opacity(0.11)
    private static let activeFill = Color.accentColor.opacity(0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
                .padding(.horizontal, 20)
                .padding(.top, 16)

            styleStrip

            inlineCapsuleRow
                .padding(.horizontal, 16)

            blockCapsuleRow
                .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea())
        .animation(.snappy(duration: 0.16), value: bridge.activeFormat)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.formatPopover")
    }

    private var headerRow: some View {
        HStack {
            Text("Format")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                bridge.showFormatPopover = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Format")
            .accessibilityIdentifier("format.close")
        }
    }

    private var styleStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 6) {
                    stylePill(.title, block: .title) {
                        Text("Title").font(.system(size: 23, weight: .bold))
                    }
                    stylePill(.heading, block: .heading) {
                        Text("Heading").font(.system(size: 19, weight: .bold))
                    }
                    stylePill(.subheading, block: .subheading) {
                        Text("Subheading").font(.system(size: 16, weight: .semibold))
                    }
                    stylePill(.body, block: .body) {
                        Text("Body").font(.system(size: 16, weight: .regular))
                    }
                    stylePill(.monostyled, block: .monostyled) {
                        Text("Monostyled").font(.system(size: 15, weight: .regular, design: .monospaced))
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                proxy.scrollTo(bridge.activeFormat.block, anchor: .center)
            }
            .onChange(of: bridge.activeFormat.block) { _, newBlock in
                withAnimation(.snappy(duration: 0.18)) {
                    proxy.scrollTo(newBlock, anchor: .center)
                }
            }
        }
    }

    private func stylePill<LabelContent: View>(
        _ action: EditorAction,
        block: MarkdownEdits.BlockStyle,
        @ViewBuilder content: () -> LabelContent
    ) -> some View {
        let isCurrent = bridge.activeFormat.block == block
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            perform(action)
        } label: {
            content()
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(block)
        .accessibilityIdentifier("format.style.\(action.rawValue)")
    }

    private var inlineCapsuleRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                segmentedButton(isActive: bridge.activeFormat.isBold, label: "Bold", id: "format.bold") {
                    perform(.bold)
                } content: {
                    Text("B").font(.system(size: 18, weight: .bold))
                }
                hairline
                segmentedButton(isActive: bridge.activeFormat.isItalic, label: "Italic", id: "format.italic") {
                    perform(.italic)
                } content: {
                    Text("I").font(.system(size: 18, weight: .regular, design: .serif)).italic()
                }
                hairline
                segmentedButton(isActive: bridge.activeFormat.isUnderline, label: "Underline", id: "format.underline") {
                    perform(.underline)
                } content: {
                    Image(systemName: "underline").font(.system(size: 16, weight: .medium))
                }
                hairline
                segmentedButton(isActive: bridge.activeFormat.isStrikethrough, label: "Strikethrough", id: "format.strikethrough") {
                    perform(.strikethrough)
                } content: {
                    Image(systemName: "strikethrough").font(.system(size: 16, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule(style: .continuous).fill(Self.cellSurface))
            .clipShape(Capsule(style: .continuous))

            HStack(spacing: 0) {
                segmentedButton(isActive: bridge.activeFormat.highlight != nil, label: "Highlight", id: "format.highlight") {
                    let color = bridge.activeFormat.highlight ?? bridge.selectedHighlightColor
                    if let apply = bridge.applyHighlight {
                        apply(color, false)
                    } else {
                        perform(.highlight)
                    }
                } content: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 16, weight: .medium))
                }
                hairline
                Menu {
                    ForEach(HighlightColor.allCases, id: \.self) { color in
                        Button {
                            bridge.selectedHighlightColor = color
                            bridge.applyHighlight?(color, bridge.activeFormat.highlight != nil)
                        } label: {
                            if (bridge.activeFormat.highlight ?? bridge.selectedHighlightColor) == color {
                                Label(color.label, systemImage: "checkmark")
                            } else {
                                Text(color.label)
                            }
                        }
                    }
                } label: {
                    Circle()
                        .fill((bridge.activeFormat.highlight ?? bridge.selectedHighlightColor).swiftUIColor)
                        .frame(width: 16, height: 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Highlight Color")
                .accessibilityIdentifier("format.highlightColor")
            }
            .frame(width: 108, height: 46)
            .background(Capsule(style: .continuous).fill(Self.cellSurface))
            .clipShape(Capsule(style: .continuous))
        }
    }

    private var blockCapsuleRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                segmentedButton(isActive: bridge.activeFormat.block == .bullet, label: "Bulleted List", id: "format.style.bullet") {
                    perform(.bullet)
                } content: {
                    Image(systemName: "list.bullet").font(.system(size: 16, weight: .medium))
                }
                hairline
                segmentedButton(isActive: bridge.activeFormat.block == .dashed, label: "Dashed List", id: "format.style.dashed") {
                    perform(.dashed)
                } content: {
                    Image(systemName: "list.dash").font(.system(size: 16, weight: .medium))
                }
                hairline
                segmentedButton(isActive: bridge.activeFormat.block == .numbered, label: "Numbered List", id: "format.style.numbered") {
                    perform(.numbered)
                } content: {
                    Image(systemName: "list.number").font(.system(size: 16, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule(style: .continuous).fill(Self.cellSurface))
            .clipShape(Capsule(style: .continuous))

            HStack(spacing: 0) {
                segmentedButton(isActive: false, label: "Outdent", id: "format.outdent") {
                    perform(.outdent)
                } content: {
                    Image(systemName: "decrease.indent").font(.system(size: 16, weight: .medium))
                }
                hairline
                segmentedButton(isActive: false, label: "Indent", id: "format.indent") {
                    perform(.indent)
                } content: {
                    Image(systemName: "increase.indent").font(.system(size: 16, weight: .medium))
                }
            }
            .frame(width: 104, height: 46)
            .background(Capsule(style: .continuous).fill(Self.cellSurface))
            .clipShape(Capsule(style: .continuous))

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                perform(.quote)
            } label: {
                HStack(spacing: 3.5) {
                    Capsule()
                        .frame(width: 2.2, height: 15)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .frame(width: 11, height: 15)
                }
                .foregroundStyle(bridge.activeFormat.block == .quote ? Color.accentColor : Color.white)
                .frame(width: 48, height: 46)
                .background(
                    Capsule(style: .continuous)
                        .fill(bridge.activeFormat.block == .quote ? Self.activeFill : Self.cellSurface)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Block Quote")
            .accessibilityIdentifier("format.style.quote")
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Self.dividerInk)
            .frame(width: 1, height: 24)
    }

    private func segmentedButton<Content: View>(
        isActive: Bool,
        label: String,
        id: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            content()
                .foregroundStyle(isActive ? Color.accentColor : Color.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isActive ? Self.activeFill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
#endif

// MARK: - Native Apple Notes Link Sheet

struct LinkEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let draft: EditorBridge.LinkDraft
    let currentNotePath: String?
    let onApply: (_ destination: String, _ title: String, _ isWiki: Bool, _ replacing: NSRange?) -> Void
    let onRemove: (_ range: NSRange) -> Void

    @State private var destination: String
    @State private var title: String
    @State private var selectedNote: IndexedNote?
    @State private var suggestions: [IndexedNote] = []
    @State private var errorMessage: String?
    @FocusState private var focusedField: LinkField?

    private enum LinkField: Hashable {
        case destination
        case title
    }

    private var canCommit: Bool {
        selectedNote != nil || !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        draft: EditorBridge.LinkDraft,
        currentNotePath: String?,
        onApply: @escaping (_ destination: String, _ title: String, _ isWiki: Bool, _ replacing: NSRange?) -> Void,
        onRemove: @escaping (_ range: NSRange) -> Void
    ) {
        self.draft = draft
        self.currentNotePath = currentNotePath
        self.onApply = onApply
        self.onRemove = onRemove
        _destination = State(initialValue: draft.initialDestination)
        _title = State(initialValue: draft.initialTitle)
    }

    var body: some View {
        #if os(iOS)
        phoneBody
        #else
        macBody
        #endif
    }

    #if os(iOS)
    private static let cardFill = Color.white.opacity(0.08)

    private var phoneBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.11)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("link.cancel")

                Spacer()

                Text(draft.existing == nil ? "Add Link" : "Edit Link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    Task { await commit() }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canCommit ? Color.white : Color.white.opacity(0.28))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(canCommit ? Color.accentColor : Color.white.opacity(0.09))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .accessibilityLabel(draft.existing == nil ? "Add Link" : "Done")
                .accessibilityIdentifier("link.save")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Link To")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        if let picked = selectedNote {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(picked.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    let folder = SearchIndex.folder(of: picked.path)
                                    if !folder.isEmpty {
                                        Text(folder)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button {
                                    withAnimation(.snappy(duration: 0.16)) {
                                        selectedNote = nil
                                        destination = ""
                                        focusedField = .destination
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.secondary)
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear selected note")
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                            )
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: looksLikeExternalURL(destination) ? "globe" : "magnifyingglass")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                TextField("URL or note title", text: $destination)
                                    .textFieldStyle(.plain)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .submitLabel(.done)
                                    .focused($focusedField, equals: .destination)
                                    .onSubmit {
                                        if canCommit { Task { await commit() } }
                                    }
                                    .onChange(of: destination) { _, newValue in
                                        if newValue != selectedNote?.title {
                                            selectedNote = nil
                                        }
                                        errorMessage = nil
                                    }
                                    .accessibilityIdentifier("link.destination")

                                if !destination.isEmpty {
                                    Button {
                                        destination = ""
                                        errorMessage = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 17))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Clear destination")
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Self.cardFill)
                            )
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.leading, 4)
                        }
                    }

                    if selectedNote == nil, !suggestions.isEmpty, !looksLikeExternalURL(destination) {
                        let visibleNotes = Array(suggestions.prefix(3))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Notes" : "Matching Notes")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        focusedField = nil
                                        selectSuggestion(note)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "doc.text")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 20)
                                            Text(note.title)
                                                .font(.subheadline)
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            let folder = SearchIndex.folder(of: note.path)
                                            if !folder.isEmpty {
                                                Text(folder)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Image(systemName: "arrow.up.left")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 42)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("link.suggestion.\(note.path)")

                                    if index + 1 < visibleNotes.count {
                                        Divider()
                                            .overlay(Color.white.opacity(0.08))
                                            .padding(.leading, 44)
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Self.cardFill)
                            )
                        }
                        .transition(.opacity)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        HStack(spacing: 10) {
                            Image(systemName: "character.cursor.ibeam")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            TextField("Optional display text", text: $title)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .foregroundStyle(.white)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .title)
                                .onSubmit {
                                    if canCommit { Task { await commit() } }
                                }
                                .accessibilityIdentifier("link.title")

                            if !title.isEmpty {
                                Button {
                                    title = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear name")
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Self.cardFill)
                        )

                        Text("Optional. Defaults to the note title or website domain.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }

                    if let existing = draft.existing {
                        Button(role: .destructive) {
                            onRemove(existing.wholeRange)
                            dismiss()
                        } label: {
                            Text("Remove Link")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.red.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("link.remove")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea())
        .animation(.snappy(duration: 0.18), value: selectedNote?.path)
        .task(id: destination) {
            await loadSuggestions()
        }
        .onAppear {
            if draft.existing == nil && destination.isEmpty {
                focusedField = .destination
            }
        }
    }
    #else
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existing == nil ? "Add Link" : "Edit Link")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Link To")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let picked = selectedNote {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(picked.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            let folder = SearchIndex.folder(of: picked.path)
                            if !folder.isEmpty {
                                Text(folder)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        Button {
                            withAnimation(.snappy(duration: 0.16)) {
                                selectedNote = nil
                                destination = ""
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear selected note")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    TextField("Website URL or note title", text: $destination)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: destination) { _, newValue in
                            if newValue != selectedNote?.title {
                                selectedNote = nil
                            }
                            errorMessage = nil
                        }
                        .accessibilityIdentifier("link.destination")
                }
            }

            if selectedNote == nil, !suggestions.isEmpty, !looksLikeExternalURL(destination) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions.prefix(5)) { note in
                            Button {
                                selectSuggestion(note)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(note.title)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        let folder = SearchIndex.folder(of: note.path)
                                        if !folder.isEmpty {
                                            Text(folder)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("link.suggestion.\(note.path)")
                        }
                    }
                    .padding(3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Optional display text", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("link.title")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if let existing = draft.existing {
                    Button("Remove Link", role: .destructive) {
                        onRemove(existing.wholeRange)
                        dismiss()
                    }
                    .accessibilityIdentifier("link.remove")
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(draft.existing == nil ? "Add Link" : "Done") {
                    Task { await commit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("link.save")
            }
        }
        .padding(18)
        .frame(minWidth: 320, idealWidth: 360)
        .animation(.snappy(duration: 0.18), value: selectedNote?.path)
        .task(id: destination) {
            await loadSuggestions()
        }
    }
    #endif

    private func selectSuggestion(_ note: IndexedNote) {
        selectedNote = note
        destination = note.title
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = note.title
        }
        errorMessage = nil
    }

    private func looksLikeExternalURL(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    private func loadSuggestions() async {
        guard selectedNote == nil else {
            suggestions = []
            return
        }
        guard let store = app.session?.store else {
            suggestions = []
            return
        }
        let q = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !looksLikeExternalURL(q) else {
            suggestions = []
            return
        }
        if q.isEmpty {
            let candidates = (app.pinnedNotes + app.rootNotes).filter { $0.path != currentNotePath }
            var seen = Set<String>()
            suggestions = candidates.filter { seen.insert($0.path).inserted }
            return
        }
        let hits = await store.index.search(q)
        var resolved: [IndexedNote] = []
        for hit in hits.prefix(6) where hit.path != currentNotePath {
            if let note = await store.index.note(path: hit.path) {
                resolved.append(note)
            }
        }
        suggestions = resolved
    }

    private func commit() async {
        let rawDest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedNote != nil || !rawDest.isEmpty else { return }

        if let store = app.session?.store, selectedNote != nil || !looksLikeExternalURL(rawDest) {
            let paths = await store.index.allPaths()
            let resolver = LinkResolver(paths: paths)
            let targetPath = selectedNote?.path ?? resolver.resolve(rawDest, from: currentNotePath)
            if let targetPath, PathPolicy.isVisible(targetPath), !FolderPlaceholder.isPlaceholder(targetPath) {
                let fetchedTitle = selectedNote == nil ? (await store.index.note(path: targetPath))?.title : nil
                let noteTitle = selectedNote?.title ?? fetchedTitle ?? rawDest
                let display = rawTitle.isEmpty ? noteTitle : rawTitle
                if let wikiName = resolver.shortestName(for: targetPath, from: currentNotePath) {
                    onApply(wikiName, display, true, draft.existing?.wholeRange)
                } else {
                    onApply(targetPath, display, false, draft.existing?.wholeRange)
                }
                dismiss()
                return
            }
        }

        let candidateURL: String
        if !rawDest.contains(":"), rawDest.contains("."), !rawDest.contains(" ") {
            candidateURL = "https://" + rawDest
        } else {
            candidateURL = rawDest
        }

        guard let safe = PathPolicy.safeExternalURL(candidateURL) else {
            errorMessage = "Enter a valid https:// or mailto: link, or choose a note."
            return
        }
        let display = rawTitle.isEmpty ? (safe.host ?? safe.absoluteString) : rawTitle
        onApply(safe.absoluteString, display, false, draft.existing?.wholeRange)
        dismiss()
    }
}

#if os(iOS)
import UIKit

/// The row above the keyboard, as in Notes on iOS 26: dark system-glass capsules with white tools, floating above the
/// keyboard with the note around and behind them. Aa and the actions in one, Done in another. A set gap keeps them off the
/// keyboard: the first phone test had a `UIToolbar`, whose glass pill overlapped it, and this bar's height is its own. With
/// Reduce Transparency on, the capsules are solid. The actions scroll inside their capsule if the screen is narrow; Done
/// stays put. Targets are at least 44 points.
///
/// The glass is the see-through kind, and it takes two things for the note to show in it. There has to be text behind it:
/// `NoteScreen` runs the editor on under this bar, and the coordinator keeps the caret clear of it. And nothing can be
/// painted over it: the app's true-black chrome paints every scroll view black, so this bar's scroller has to stay clear.
@MainActor
final class EditorKeyboardBar: UIView {
    static let capsuleHeight: CGFloat = 48
    static let gapAbove: CGFloat = 4
    static let gapBelow: CGFloat = 8
    static let height: CGFloat = gapAbove + capsuleHeight + gapBelow
    static let targetSize: CGFloat = 44
    private static let sideMargin: CGFloat = 12
    static let gapBetween: CGFloat = 8
    /// A faint white veil on the clear glass, so that over true black with no text behind it the capsule still has a body,
    /// as in Notes, and isn't only a rim. Much more and the note stops showing through.
    private static let glassTint = UIColor(white: 1, alpha: 0.08)
    /// Ink for the tools and Done: white, as in Notes. Set outright, so that note text passing behind the glass can't
    /// make the system flip them dark.
    private static let toolInk = UIColor.white

    private(set) var doneButton: UIButton!
    private(set) var formatButton: UIButton!
    private(set) var buttons: [EditorAction: UIButton] = [:]
    let scroller = UIScrollView()
    /// Holds the capsules, so that the system renders their glass together.
    let glass = UIVisualEffectView(effect: nil)
    let actionsCapsule = UIVisualEffectView(effect: nil)
    let doneCapsule = UIVisualEffectView(effect: nil)

    init(textView: UITextView, coordinator: MarkdownTextView.Coordinator) {
        // The system sets the real width. A view with no width logs constraint conflicts as an accessory view.
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        isOpaque = false
        // Dark traits select the dark glass and a dark Aa menu, whatever the keyboard's window has.
        overrideUserInterfaceStyle = .dark
        accessibilityIdentifier = "editor.bar"
        // Bar buttons don't grow with the text size: a long press shows them large instead, as in the system's own bars.
        addInteraction(UILargeContentViewerInteraction())

        func press(_ action: EditorAction) -> UIAction {
            UIAction { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return }
                if action == .link, coordinator.bridge != nil {
                    coordinator.openLinkEditor(from: textView)
                } else {
                    coordinator.perform(action, in: textView)
                }
            }
        }
        func button(symbol: String, label: String, identifier: String) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            let symbolImage = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
            configuration.image = symbolImage?.withTintColor(Self.toolInk, renderingMode: .alwaysOriginal)
            configuration.baseForegroundColor = Self.toolInk
            // The target is the size. A button's own insets would take the row past a phone's width.
            configuration.contentInsets = .zero
            let b = UIButton(configuration: configuration)
            b.accessibilityLabel = label
            b.accessibilityIdentifier = identifier
            b.showsLargeContentViewer = true
            b.largeContentTitle = label
            b.largeContentImage = UIImage(systemName: symbol)
            b.scalesLargeContentImage = true
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize).isActive = true
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize).isActive = true
            return b
        }

        formatButton = button(symbol: "textformat", label: "Text Style", identifier: "editor.bar.format")
        formatButton.addAction(UIAction { [weak coordinator, weak textView] _ in
            guard let coordinator, let textView else { return }
            coordinator.openFormatPopover(from: textView)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [formatButton])
        for action in EditorBar.buttons {
            let b = button(symbol: action.symbol, label: action.label, identifier: "editor.bar.\(action.rawValue)")
            b.addAction(press(action), for: .touchUpInside)
            buttons[action] = b
            stack.addArrangedSubview(b)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroller.showsHorizontalScrollIndicator = false
        // No iOS 26 line or blur where the buttons could scroll under the capsule's ends.
        for edge in [scroller.topEdgeEffect, scroller.bottomEdgeEffect, scroller.leftEdgeEffect, scroller.rightEdgeEffect] {
            edge.isHidden = true
        }
        // This scroller sits in the tool capsule, so any opaque background (a UIScrollView appearance proxy included) is
        // a black plate over the glass and the tools draw on black. Keep it clear.
        scroller.backgroundColor = .clear
        scroller.isOpaque = false
        scroller.cornerConfiguration = .capsule()
        scroller.clipsToBounds = true
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        // Puts the keyboard away.
        var doneConfiguration = UIButton.Configuration.plain()
        doneConfiguration.title = "Done"
        doneConfiguration.baseForegroundColor = Self.toolInk
        doneConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var out = attributes
            out.font = .systemFont(ofSize: 17, weight: .semibold)
            return out
        }
        doneButton = UIButton(configuration: doneConfiguration, primaryAction: UIAction { [weak coordinator, weak textView] _ in
            guard let coordinator, let textView else { return }
            coordinator.dismissKeyboard(from: textView)
        })
        doneButton.accessibilityIdentifier = "editor.bar.done"
        doneButton.showsLargeContentViewer = true
        doneButton.largeContentTitle = "Done"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.overrideUserInterfaceStyle = .dark
        addSubview(glass)
        actionsCapsule.contentView.addSubview(scroller)
        doneCapsule.contentView.addSubview(doneButton)
        for capsule in [actionsCapsule, doneCapsule] {
            capsule.overrideUserInterfaceStyle = .dark
            capsule.translatesAutoresizingMaskIntoConstraints = false
            capsule.cornerConfiguration = .capsule()
            capsule.contentView.backgroundColor = .clear
            capsule.contentView.isOpaque = false
            glass.contentView.addSubview(capsule)
        }

        let inset = (Self.capsuleHeight - Self.targetSize) / 2
        let hugsItsButtons = scroller.frameLayoutGuide.widthAnchor.constraint(equalTo: stack.widthAnchor)
        hugsItsButtons.priority = .defaultHigh
        NSLayoutConstraint.activate([
            actionsCapsule.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Self.sideMargin),
            actionsCapsule.trailingAnchor.constraint(lessThanOrEqualTo: doneCapsule.leadingAnchor, constant: -Self.gapBetween),
            actionsCapsule.topAnchor.constraint(equalTo: topAnchor, constant: Self.gapAbove),
            actionsCapsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),

            doneCapsule.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Self.sideMargin),
            doneCapsule.topAnchor.constraint(equalTo: topAnchor, constant: Self.gapAbove),
            doneCapsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),

            doneButton.leadingAnchor.constraint(equalTo: doneCapsule.contentView.leadingAnchor),
            doneButton.trailingAnchor.constraint(equalTo: doneCapsule.contentView.trailingAnchor),
            doneButton.centerYAnchor.constraint(equalTo: doneCapsule.contentView.centerYAnchor),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize),

            scroller.leadingAnchor.constraint(equalTo: actionsCapsule.contentView.leadingAnchor, constant: inset),
            scroller.trailingAnchor.constraint(equalTo: actionsCapsule.contentView.trailingAnchor, constant: -inset),
            scroller.topAnchor.constraint(equalTo: actionsCapsule.contentView.topAnchor, constant: inset),
            scroller.bottomAnchor.constraint(equalTo: actionsCapsule.contentView.bottomAnchor, constant: -inset),

            stack.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            hugsItsButtons,
        ])

        followReduceTransparency()
        NotificationCenter.default.addObserver(self, selector: #selector(followReduceTransparency), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    /// While a table's cell has the focus: the table button opens what can be done to the table, and the buttons that make
    /// a block have nothing to do, for a cell holds one line of inline text. Nil goes back to the note's bar.
    func showTableActions(_ menu: UIMenu?) {
        let table = buttons[.table]
        table?.menu = menu
        table?.showsMenuAsPrimaryAction = menu != nil
        for action in [EditorAction.checklist, .bullet, .dashed, .numbered, .quote] {
            buttons[action]?.isEnabled = menu == nil
            buttons[action]?.alpha = menu == nil ? 1 : 0.35
        }
    }

    /// The system's glass, or solid capsules with Reduce Transparency on. Increase Contrast and Reduce Motion are the glass's
    /// own business: the system changes how it draws.
    func useMaterial(reduceTransparency: Bool) {
        if reduceTransparency {
            glass.effect = nil
        } else {
            let container = UIGlassContainerEffect()
            // Less than the gap between the capsules: they stay two.
            container.spacing = Self.gapBetween / 2
            glass.effect = container
        }
        for capsule in [actionsCapsule, doneCapsule] {
            if reduceTransparency {
                capsule.effect = nil
                // Only with the setting on: a dark solid under the white tools, set apart from the black note.
                capsule.backgroundColor = .secondarySystemBackground
            } else {
                // Clear is the system's most see-through glass. Regular is a heavier frost, which turns the text behind
                // it into a glow.
                let effect = UIGlassEffect(style: .clear)
                effect.isInteractive = true
                effect.tintColor = Self.glassTint
                capsule.effect = effect
                capsule.backgroundColor = nil
            }
        }
    }

    @objc private func followReduceTransparency() {
        useMaterial(reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
    }

    /// Only the capsules are the bar. A tap beside them belongs to the note behind it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let inGlass = convert(point, to: glass.contentView)
        guard actionsCapsule.frame.contains(inGlass) || doneCapsule.frame.contains(inGlass) else { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif

#if os(macOS)
import AppKit

/// Carries an action through the responder chain to the editor that has the focus.
final class EditorActionSender: NSObject {
    let action: EditorAction
    init(_ action: EditorAction) { self.action = action }

    @MainActor static func send(_ action: EditorAction) {
        NSApp.sendAction(#selector(EditorTextView.performEditorAction(_:)), to: nil, from: EditorActionSender(action))
    }
}

/// True while a note is open in the editor, so the Format menu can say whether it does anything.
struct EditorIsOpenKey: FocusedValueKey {
    typealias Value = Bool
}

struct EditorOpenLinkTriggerKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var editorIsOpen: Bool? {
        get { self[EditorIsOpenKey.self] }
        set { self[EditorIsOpenKey.self] = newValue }
    }

    var editorOpenLink: (() -> Void)? {
        get { self[EditorOpenLinkTriggerKey.self] }
        set { self[EditorOpenLinkTriggerKey.self] = newValue }
    }
}

/// The Mac's Format menu.
struct FormatCommands: Commands {
    @FocusedValue(\.editorIsOpen) private var editorIsOpen
    @FocusedValue(\.editorOpenLink) private var editorOpenLink

    private func item(_ action: EditorAction) -> some View {
        Button(action.label) { EditorActionSender.send(action) }
            .disabled(editorIsOpen != true)
    }

    var body: some Commands {
        CommandMenu("Format") {
            item(.title).keyboardShortcut("1", modifiers: .command)
            item(.heading).keyboardShortcut("2", modifiers: .command)
            item(.subheading).keyboardShortcut("3", modifiers: .command)
            item(.body)
            item(.monostyled)
            Divider()
            item(.bold).keyboardShortcut("b", modifiers: .command)
            item(.italic).keyboardShortcut("i", modifiers: .command)
            item(.underline).keyboardShortcut("u", modifiers: .command)
            item(.strikethrough)
            item(.highlight)
            item(.code)
            Divider()
            item(.checklist).keyboardShortcut("l", modifiers: [.command, .shift])
            item(.bullet)
            item(.dashed)
            item(.numbered)
            item(.quote)
            item(.indent).keyboardShortcut("]", modifiers: .command)
            item(.outdent).keyboardShortcut("[", modifiers: .command)
            Divider()
            Button("Add Link…") {
                if let editorOpenLink {
                    editorOpenLink()
                } else {
                    EditorActionSender.send(.link)
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(editorIsOpen != true)
            item(.table)
            item(.direction)
        }
    }
}

/// Streamlined Apple Notes actions in a `ToolbarItemGroup`: `[ Aa | Checklist | Table | Link ]`.
struct EditorToolbarButtons: View {
    @Bindable var bridge: EditorBridge
    var perform: (EditorAction) -> Void = { EditorActionSender.send($0) }

    var body: some View {
        Button {
            bridge.showFormatPopover.toggle()
        } label: {
            Label("Text Style", systemImage: "textformat")
        }
        .help("Format")
        .popover(isPresented: $bridge.showFormatPopover, arrowEdge: .bottom) {
            FormatPopoverView(bridge: bridge, perform: perform)
        }
        .accessibilityIdentifier("editor.toolbar.style")

        Button { perform(.checklist) } label: {
            Label(EditorAction.checklist.label, systemImage: EditorAction.checklist.symbol)
        }
        .help(EditorAction.checklist.label)
        .accessibilityIdentifier("editor.toolbar.checklist")

        Button { perform(.table) } label: {
            Label(EditorAction.table.label, systemImage: EditorAction.table.symbol)
        }
        .help(EditorAction.table.label)
        .accessibilityIdentifier("editor.toolbar.table")

        Button {
            bridge.presentLinkEditor()
        } label: {
            Label("Add Link", systemImage: EditorAction.link.symbol)
        }
        .help("Add Link (⌘K)")
        .accessibilityIdentifier("editor.toolbar.link")
    }
}
#endif
