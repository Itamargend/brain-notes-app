import BrainNotesKit
import Foundation
import SwiftUI

/// The editor's text actions, on the iPhone's bar and in the Mac's Format menu and toolbar. A list, so a test can check
/// every symbol: a wrong name is an invisible button.
enum EditorAction: String, CaseIterable {
    case title, heading, subheading, body
    case bold, italic, code
    case checklist, bullet, link, direction

    var symbol: String {
        switch self {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat.size.smaller"
        case .body: "text.alignleft"
        case .bold: "bold"
        case .italic: "italic"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .checklist: "checklist"
        case .bullet: "list.bullet"
        case .link: "link"
        case .direction: "arrow.left.arrow.right"
        }
    }

    var label: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .bold: "Bold"
        case .italic: "Italic"
        case .code: "Code"
        case .checklist: "Checklist"
        case .bullet: "Bulleted List"
        case .link: "Link to a Note"
        case .direction: "Switch Between Right to Left and Left to Right"
        }
    }

    func edit(in text: String, selection: NSRange) -> MarkdownEdits.Edit {
        switch self {
        case .title: MarkdownEdits.toggleHeading(1, in: text, selection: selection)
        case .heading: MarkdownEdits.toggleHeading(2, in: text, selection: selection)
        case .subheading: MarkdownEdits.toggleHeading(3, in: text, selection: selection)
        case .body: MarkdownEdits.removeHeading(in: text, selection: selection)
        case .bold: MarkdownEdits.toggleWrap("**", in: text, selection: selection)
        case .italic: MarkdownEdits.toggleWrap("*", in: text, selection: selection)
        case .code: MarkdownEdits.toggleWrap("`", in: text, selection: selection)
        case .checklist: MarkdownEdits.toggleTask(in: text, selection: selection)
        case .bullet: MarkdownEdits.toggleBullet(in: text, selection: selection)
        case .link: MarkdownEdits.insertWikiLink(in: text, selection: selection)
        case .direction: MarkdownEdits.toggleDirection(in: text, selection: selection)
        }
    }
}

#if os(iOS)
import UIKit

/// The row above the keyboard: one solid bar across the whole width, attached to the keyboard, with Done inside it. Not
/// a `UIToolbar`: on iOS 26 that draws its items as floating glass pills over the keyboard. The actions scroll if the
/// screen is narrow; Done stays put. Targets are at least 44 points.
@MainActor
final class EditorKeyboardBar: UIView {
    static let height: CGFloat = 48
    static let targetSize: CGFloat = 44

    private(set) var doneButton: UIButton!
    private(set) var formatButton: UIButton!
    private(set) var buttons: [EditorAction: UIButton] = [:]
    let scroller = UIScrollView()

    init(textView: UITextView, coordinator: MarkdownTextView.Coordinator) {
        // The system sets the real width. A view with no width logs constraint conflicts as an accessory view.
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground
        accessibilityIdentifier = "editor.bar"

        let hairline = UIView()
        hairline.backgroundColor = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        func press(_ action: EditorAction) -> UIAction {
            UIAction { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return }
                coordinator.perform(action, in: textView)
            }
        }
        func image(_ symbol: String) -> UIImage? {
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        }
        func button(symbol: String, label: String, identifier: String) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = image(symbol)
            configuration.baseForegroundColor = .label
            let b = UIButton(configuration: configuration)
            b.accessibilityLabel = label
            b.accessibilityIdentifier = identifier
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize).isActive = true
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize).isActive = true
            return b
        }

        func menuItem(_ action: EditorAction) -> UIAction {
            UIAction(title: action.label, image: UIImage(systemName: action.symbol)) { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return }
                coordinator.perform(action, in: textView)
            }
        }
        formatButton = button(symbol: "textformat", label: "Text Style", identifier: "editor.bar.format")
        formatButton.showsMenuAsPrimaryAction = true
        formatButton.menu = UIMenu(children: [
            UIMenu(options: .displayInline, children: [EditorAction.title, .heading, .subheading, .body].map(menuItem)),
            UIMenu(options: .displayInline, children: [EditorAction.bold, .italic, .code].map(menuItem)),
        ])

        let stack = UIStackView(arrangedSubviews: [formatButton])
        for action in [EditorAction.checklist, .bullet, .link, .direction] {
            let b = button(symbol: action.symbol, label: action.label, identifier: "editor.bar.\(action.rawValue)")
            b.addAction(press(action), for: .touchUpInside)
            buttons[action] = b
            stack.addArrangedSubview(b)
        }
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroller.showsHorizontalScrollIndicator = false
        // The bar is flat: no iOS 26 line or blur where the buttons could scroll under its edges.
        for edge in [scroller.topEdgeEffect, scroller.bottomEdgeEffect, scroller.leftEdgeEffect, scroller.rightEdgeEffect] {
            edge.isHidden = true
        }
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)
        addSubview(scroller)

        // Puts the keyboard away. The checkmark in the navigation bar is the one that leaves editing.
        var doneConfiguration = UIButton.Configuration.plain()
        doneConfiguration.title = "Done"
        doneConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var out = attributes
            out.font = .preferredFont(forTextStyle: .headline)
            return out
        }
        doneButton = UIButton(configuration: doneConfiguration, primaryAction: UIAction { [weak textView] _ in
            textView?.resignFirstResponder()
        })
        doneButton.accessibilityIdentifier = "editor.bar.done"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),

            doneButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.targetSize),

            scroller.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            scroller.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -4),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }
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

extension FocusedValues {
    var editorIsOpen: Bool? {
        get { self[EditorIsOpenKey.self] }
        set { self[EditorIsOpenKey.self] = newValue }
    }
}

/// The Mac's Format menu.
struct FormatCommands: Commands {
    @FocusedValue(\.editorIsOpen) private var editorIsOpen

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
            Divider()
            item(.bold).keyboardShortcut("b", modifiers: .command)
            item(.italic).keyboardShortcut("i", modifiers: .command)
            item(.code)
            Divider()
            item(.checklist).keyboardShortcut("l", modifiers: [.command, .shift])
            item(.bullet)
            item(.link)
            item(.direction)
        }
    }
}

/// The same actions in the window's toolbar.
struct EditorToolbarButtons: View {
    var body: some View {
        Menu {
            ForEach([EditorAction.title, .heading, .subheading, .body], id: \.self) { action in
                Button(action.label) { EditorActionSender.send(action) }
            }
        } label: {
            Label("Text Style", systemImage: "textformat")
        }
        .accessibilityIdentifier("editor.toolbar.style")
        ForEach([EditorAction.bold, .italic, .code, .checklist, .bullet, .link, .direction], id: \.self) { action in
            Button { EditorActionSender.send(action) } label: {
                Label(action.label, systemImage: action.symbol)
            }
            .help(action.label)
            .accessibilityIdentifier("editor.toolbar.\(action.rawValue)")
        }
    }
}
#endif
