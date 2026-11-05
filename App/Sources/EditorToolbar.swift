import BrainNotesKit
import Foundation
import SwiftUI

/// The editor's text actions, on the iPhone's bar and in the Mac's Format menu and toolbar. A list, so a test can check
/// every symbol: a wrong name is an invisible button.
enum EditorAction: String, CaseIterable {
    case title, heading, subheading, body
    case bold, italic, code
    case checklist, bullet, numbered, indent, outdent, link, table, direction

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
        case .numbered: "list.number"
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
        case .bold: "Bold"
        case .italic: "Italic"
        case .code: "Code"
        case .checklist: "Checklist"
        case .bullet: "Bulleted List"
        case .numbered: "Numbered List"
        case .indent: "Indent"
        case .outdent: "Outdent"
        case .link: "Link to a Note"
        case .table: "Table"
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
        case .numbered: MarkdownEdits.toggleNumbered(in: text, selection: selection)
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
    /// The Aa menu, by section.
    static let styleMenu: [[EditorAction]] = [[.title, .heading, .subheading, .body], [.bold, .italic, .code], [.indent, .outdent]]
    /// The buttons next to Aa.
    static let buttons: [EditorAction] = [.checklist, .bullet, .numbered, .link, .table, .direction]
}

#if os(iOS)
import UIKit

/// The row above the keyboard, as in Notes on iOS 26: capsules of the system's glass, floating above the keyboard with the
/// note around them. Aa and the actions in one, Done in another. A set gap keeps them off the keyboard: the first phone
/// test had a `UIToolbar`, whose glass pill overlapped it, and this bar's height is its own. With Reduce Transparency on,
/// the capsules are solid. The actions scroll inside their capsule if the screen is narrow; Done stays put. Targets are
/// at least 44 points.
@MainActor
final class EditorKeyboardBar: UIView {
    static let capsuleHeight: CGFloat = 48
    static let gapAbove: CGFloat = 4
    static let gapBelow: CGFloat = 8
    static let height: CGFloat = gapAbove + capsuleHeight + gapBelow
    static let targetSize: CGFloat = 44
    private static let sideMargin: CGFloat = 12
    static let gapBetween: CGFloat = 8

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
        accessibilityIdentifier = "editor.bar"
        // Bar buttons don't grow with the text size: a long press shows them large instead, as in the system's own bars.
        addInteraction(UILargeContentViewerInteraction())

        func press(_ action: EditorAction) -> UIAction {
            UIAction { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return }
                coordinator.perform(action, in: textView)
            }
        }
        func button(symbol: String, label: String, identifier: String) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
            configuration.baseForegroundColor = .label
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
        func menuItem(_ action: EditorAction) -> UIAction {
            UIAction(title: action.label, image: UIImage(systemName: action.symbol)) { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return }
                coordinator.perform(action, in: textView)
            }
        }

        formatButton = button(symbol: "textformat", label: "Text Style", identifier: "editor.bar.format")
        formatButton.showsMenuAsPrimaryAction = true
        // In reading order, with Title on top, wherever the menu opens.
        formatButton.preferredMenuElementOrder = .fixed
        formatButton.menu = UIMenu(children: EditorBar.styleMenu.map { UIMenu(options: .displayInline, children: $0.map(menuItem)) })

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
        scroller.cornerConfiguration = .capsule()
        scroller.clipsToBounds = true
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        // Puts the keyboard away. The checkmark in the navigation bar is the one that leaves editing.
        var doneConfiguration = UIButton.Configuration.plain()
        doneConfiguration.title = "Done"
        doneConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var out = attributes
            out.font = .systemFont(ofSize: 17, weight: .semibold)
            return out
        }
        doneButton = UIButton(configuration: doneConfiguration, primaryAction: UIAction { [weak textView] _ in
            textView?.resignFirstResponder()
        })
        doneButton.accessibilityIdentifier = "editor.bar.done"
        doneButton.showsLargeContentViewer = true
        doneButton.largeContentTitle = "Done"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        actionsCapsule.contentView.addSubview(scroller)
        doneCapsule.contentView.addSubview(doneButton)
        for capsule in [actionsCapsule, doneCapsule] {
            capsule.translatesAutoresizingMaskIntoConstraints = false
            capsule.cornerConfiguration = .capsule()
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
                capsule.backgroundColor = .secondarySystemBackground
            } else {
                let effect = UIGlassEffect(style: .regular)
                effect.isInteractive = true
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
            item(.numbered)
            item(.indent).keyboardShortcut("]", modifiers: .command)
            item(.outdent).keyboardShortcut("[", modifiers: .command)
            Divider()
            item(.link)
            item(.table)
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
        ForEach([EditorAction.bold, .italic, .code, .checklist, .bullet, .numbered, .link, .table, .direction], id: \.self) { action in
            Button { EditorActionSender.send(action) } label: {
                Label(action.label, systemImage: action.symbol)
            }
            .help(action.label)
            .accessibilityIdentifier("editor.toolbar.\(action.rawValue)")
        }
    }
}
#endif


