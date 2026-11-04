import BrainNotesKit
import Foundation

/// The keyboard bar's text actions. A list, so a test can check every symbol: a wrong name is an invisible button.
enum EditorAction: CaseIterable {
    case checklist, bold, direction

    var symbol: String {
        switch self {
        case .checklist: "checklist"
        case .bold: "bold"
        case .direction: "arrow.left.arrow.right"
        }
    }

    var label: String {
        switch self {
        case .checklist: "Checklist"
        case .bold: "Bold"
        case .direction: "Switch between right to left and left to right"
        }
    }

    func edit(in text: String, selection: NSRange) -> MarkdownEdits.Edit {
        switch self {
        case .checklist: MarkdownEdits.toggleTask(in: text, selection: selection)
        case .bold: MarkdownEdits.toggleWrap("**", in: text, selection: selection)
        case .direction: MarkdownEdits.toggleDirection(in: text, selection: selection)
        }
    }
}

#if os(iOS)
import UIKit

/// The row above the keyboard.
@MainActor
enum EditorKeyboardBar {
    static func make(for textView: UITextView, coordinator: MarkdownTextView.Coordinator) -> UIToolbar {
        // A toolbar with no width logs constraint conflicts as an accessory view. The system sets the real width.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        var items = EditorAction.allCases.map { action -> UIBarButtonItem in
            let item = UIBarButtonItem(image: UIImage(systemName: action.symbol), primaryAction: UIAction { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return }
                coordinator.perform(action, in: textView)
            })
            item.accessibilityLabel = action.label
            return item
        }
        items.append(.flexibleSpace())
        // Puts the keyboard away. The Done in the navigation bar is the one that leaves editing.
        items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak textView] _ in
            textView?.resignFirstResponder()
        }))
        bar.items = items
        bar.sizeToFit()
        return bar
    }
}
#endif
