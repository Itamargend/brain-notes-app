// DRAFT, not in any target. Moves to App/Sources/ when the intent is wired up in Xcode (docs/plan/add-to-brain.md,
// "App wiring"). Nothing here has been compiled: the App Intents API needs Xcode and the iOS 26 / macOS 26 SDKs.

import AppIntents
import BrainNotesKit
import Foundation

/// Add to Brain: text, a link or a quick thought becomes a note in `_inbox/`, queued for the next push.
/// Runs in the app's own process; see "Process" in docs/plan/add-to-brain.md for why it is not an extension.
struct AddToBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Brain"
    static let description = IntentDescription(
        "Saves text or a link as a new note in your Inbox. It syncs to GitHub the next time Brain Notes pushes.",
        categoryName: "Capture"
    )
    /// The capture is written in the background; nothing on screen needs to change.
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String?

    @Parameter(title: "Link")
    var link: URL?

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Source", default: .shortcut)
    var source: CaptureSourceAppEnum

    @Dependency
    private var app: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Brain") {
            \.$link
            \.$title
        }
        // `source` stays out of the summary: a share-sheet shortcut sets it, nobody else needs to see it.
    }

    /// On the main actor, where `AppModel` lives. The disk work inside `BrainSession.capture` runs detached.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        var text = text ?? ""
        if text.allSatisfy(\.isWhitespace), link == nil, (title ?? "").allSatisfy(\.isWhitespace) {
            // Run from Siri or the Action button with nothing to go on: ask.
            text = try await $text.requestValue("What should go in your brain?")
        }
        let capture = Capture(text: text, url: link, title: title, source: source.kitValue)
        do {
            let path = try await app.capture(capture)
            let saved = (try? app.session?.store.read(path)) ?? nil
            let noteTitle = saved.map { NoteText.title(of: $0, path: path) } ?? NoteText.fileStem(path)
            return .result(value: noteTitle, dialog: "Added to your Inbox")
        } catch let problem as CaptureProblem {
            throw AddToBrainError(problem)
        }
    }
}

/// `Capture.Source` for Shortcuts. Raw values match the kit's, which are the note's `source:` values.
enum CaptureSourceAppEnum: String, AppEnum {
    case share
    case shortcut
    case quickNote = "quick-note"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    static let caseDisplayRepresentations: [CaptureSourceAppEnum: DisplayRepresentation] = [
        .share: "Share sheet",
        .shortcut: "Shortcut",
        .quickNote: "Quick note",
    ]

    var kitValue: Capture.Source { Capture.Source(rawValue: rawValue) ?? .shortcut }
}

/// What the person sees when a capture is refused. Never the secret's kind, never the text.
enum AddToBrainError: Error, CustomLocalizedStringResourceConvertible {
    case empty, tooLarge, secret, sampleNotes, notSignedIn, couldNotSave

    init(_ problem: CaptureProblem) {
        switch problem {
        case .empty: self = .empty
        case .tooLarge: self = .tooLarge
        case .secret: self = .secret
        case .sampleNotes: self = .sampleNotes
        case .noFreeName: self = .couldNotSave
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: "Nothing to add. Share some text or a link."
        case .tooLarge: "That's over 1 MB, too large for one note."
        case .secret: "This looks like it holds a password or key, so it wasn't added."
        case .sampleNotes: "You're using the sample notes. Connect GitHub to add to your brain."
        case .notSignedIn: "Open Brain Notes and sign in first."
        case .couldNotSave: "Couldn't save. Try again."
        }
    }
}

struct BrainNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToBrainIntent(),
            phrases: [
                "Add to Brain in \(.applicationName)",
                "Save to \(.applicationName)",
                "Capture in \(.applicationName)",
            ],
            shortTitle: "Add to Brain",
            systemImageName: "tray.and.arrow.down"
        )
    }
}

// MARK: - AppModel side (sketch, goes into App/Sources/AppModel.swift)

extension AppModel {
    /// The live session's capture. A launch the intent started is still `.loading` for a moment: wait for it,
    /// then refuse anything but a signed-in live session. Sample notes are refused by the kit.
    func capture(_ capture: Capture) async throws -> String {
        // Bounded: a launch stuck in `.loading` must not hold the intent until the system kills it.
        let deadline = ContinuousClock.now + .seconds(10)
        while phase == .loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard phase == .ready, let session else { throw AddToBrainError.notSignedIn }
        do {
            let path = try await session.capture(capture)
            await reloadLists()
            return path
        } catch let problem as CaptureProblem {
            throw problem
        } catch {
            // Disk full, device locked before the first unlock: nothing was written, and the text is still in the
            // app it came from.
            throw AddToBrainError.couldNotSave
        }
    }
}

// MARK: - BrainNotesApp.init (sketch)
//
//     init() {
//         let model = AppModel()
//         _app = State(initialValue: model)
//         AppDependencyManager.shared.add { model }
//         ... existing init ...
//     }
