import AppKit
import BrainNotesKit
import XCTest
@testable import BrainNotes

/// The numbers for the editor spike's go or no-go, and what makes the bar's direction button visible.
/// The screen itself is in `ScreenWalkTests`.
@MainActor
final class EditorSpikeTests: XCTestCase {
    /// `.logs/editor-spike-timing.txt` in this repo (git-ignored): the numbers from the last run.
    private static let timingFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".logs/editor-spike-timing.txt")

    /// On this Mac, in a debug build. The phone's own numbers are on the `-BNScreen editor-spike` screen.
    func testStylingA271KBNoteStaysWithinTheBudgets() throws {
        let note = StyleTiming.syntheticNote()
        XCTAssertEqual(Double(note.utf8.count), 271_000, accuracy: 1_000)
        let result = try XCTUnwrap(StyleTiming.measure(text: note, fullPasses: 7, paragraphSamples: 400))
        let attachment = XCTAttachment(string: result.summary)
        attachment.name = "style timing"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? result.summary.write(to: Self.timingFile, atomically: true, encoding: .utf8)
        XCTAssertLessThan(result.firstFull, 150)
        XCTAssertLessThan(result.medianFull, 150)
        XCTAssertLessThan(result.medianParagraph, 2)
    }

    /// Return in a list reads the whole note, for its fences and to write one replacement. A keystroke's worth, in a debug
    /// build, on the longest note there is. Only Return in a list and edits that add or take away lines pay for this.
    func testReturnInAListOfALongNoteStaysWithinTheBudget() throws {
        let note = "1. a\n2. b\n3. c\n" + StyleTiming.syntheticNote()
        let caret = NSRange(location: 4, length: 0)
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<15 {
            let time = clock.measure { XCTAssertNotNil(MarkdownEdits.typing("\n", replacing: caret, in: note)) }
            times.append(Double(time.components.attoseconds) / 1e15 + Double(time.components.seconds) * 1000)
        }
        times.sort()
        let line = "Return in a numbered list on a 271 KB note: median \(times[times.count / 2]) ms, worst \(times.last ?? 0) ms\n"
        try? line.write(to: Self.timingFile.deletingLastPathComponent().appendingPathComponent("editor-return-timing.txt"), atomically: true, encoding: .utf8)
        XCTAssertLessThan(times[times.count / 2], 50, line)
    }

    func testStylingNeverChangesTheText() throws {
        let note = StyleTiming.syntheticNote(targetBytes: 20_000) + "\r\nCRLF line\r\n\u{200F}marked\n\u{200E}שלום"
        let storage = NSTextStorage(string: note)
        MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(Array(storage.string.utf8), Array(note.utf8))
    }

    private func direction(of paragraph: String) throws -> NSWritingDirection {
        let storage = NSTextStorage(string: paragraph + "\n")
        MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length))
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, style.baseWritingDirection == .rightToLeft ? .right : .left)
        return style.baseWritingDirection
    }

    func testTheEditorHonoursDirectionMarksAndIgnoresBlockMarkers() throws {
        XCTAssertEqual(try direction(of: "Hello"), .leftToRight)
        XCTAssertEqual(try direction(of: "\u{200F}Hello"), .rightToLeft)
        XCTAssertEqual(try direction(of: "שלום"), .rightToLeft)
        XCTAssertEqual(try direction(of: "\u{200E}שלום"), .leftToRight)
        XCTAssertEqual(try direction(of: "# \u{200F}Title"), .rightToLeft)
        XCTAssertEqual(try direction(of: "- [ ] \u{200F}Task"), .rightToLeft)
        XCTAssertEqual(try direction(of: "- [x] משימה"), .rightToLeft, "the x is not a letter of the text")
    }

    /// A wrong symbol name gives a button with nothing on it. The names are shared with the phone.
    func testEveryBarSymbolExists() {
        for action in EditorAction.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), action.symbol)
        }
    }

    /// The phone's bar is built from this list, and its views only exist on iOS: `.plan/editor-spike-harness/` checks those
    /// on real UIKit. Every action can be reached there, once, and the Mac's menu has them all (`ScreenWalkTests`).
    func testTheBarHoldsEveryActionOnce() {
        let onTheBar = EditorBar.styleMenu.flatMap { $0 } + EditorBar.buttons
        XCTAssertEqual(onTheBar.count, Set(onTheBar).count, "nothing twice")
        XCTAssertEqual(Set(onTheBar), Set(EditorAction.allCases), "nothing missing")
    }

    /// The phone's bar only compiles for iOS and these tests run on a Mac, so this reads its source. The real one is checked
    /// on real UIKit by `.plan/editor-spike-harness/`, which is not in the repo. This much is: dark clear glass, from the
    /// system, with white tools, the scroller kept clear (and no global scroll-view black proxy to cover it), as the keyboard's accessory,
    /// and the note running on under it, so that there is text for the glass to show.
    func testThePhonesBarIsMadeOfSystemGlass() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let bar = try String(contentsOf: sources.appendingPathComponent("EditorToolbar.swift"), encoding: .utf8)
        for needle in ["UIGlassEffect(style: .clear)", "effect.tintColor = Self.glassTint", "UIColor(white: 1, alpha: 0.08)",
                       "toolInk = UIColor.white", "withTintColor(Self.toolInk, renderingMode: .alwaysOriginal)", "doneConfiguration.baseForegroundColor = Self.toolInk",
                       "overrideUserInterfaceStyle = .dark", "capsule.backgroundColor = .secondarySystemBackground",
                       "scroller.backgroundColor = .clear", "scroller.isOpaque = false", "UIGlassContainerEffect()", "isInteractive = true",
                       "capsule.cornerConfiguration = .capsule()", "capsule.backgroundColor = nil",
                       "useMaterial(reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)", "        followReduceTransparency()\n",
                       "#selector(followReduceTransparency), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification", "backgroundColor = .clear"] {
            XCTAssertTrue(bar.contains(needle), needle)
        }
        XCTAssertFalse(bar.contains("UIGlassEffect(style: .regular)"), "regular glass is a heavy frost: the note barely shows through")
        XCTAssertFalse(bar.contains("overrideUserInterfaceStyle = .light"), "white tools on a white frost")
        XCTAssertFalse(bar.contains("BN_SOLID_PILL"), "an opaque capture fill is not the bar")
        XCTAssertFalse(bar.contains("UIToolbar("), "its height wouldn't be ours")
        let chrome = try String(contentsOf: sources.appendingPathComponent("BrainChrome.swift"), encoding: .utf8)
        XCTAssertFalse(chrome.contains("UIScrollView.appearance().backgroundColor = black"), "no global scroll-view black proxy; the bar's scroller stays clear on its own")
        let views = try String(contentsOf: sources.appendingPathComponent("MarkdownViews.swift"), encoding: .utf8)
        XCTAssertTrue(views.contains("view.inputAccessoryView = EditorKeyboardBar("), "on every note")
        let screen = try String(contentsOf: sources.appendingPathComponent("NoteScreen.swift"), encoding: .utf8)
        XCTAssertTrue(screen.contains(".ignoresSafeArea(.keyboard, edges: .bottom)"), "the note goes on behind the bar, or the glass only has black to show")
        XCTAssertTrue(views.contains("UIResponder.keyboardWillChangeFrameNotification"), "and it makes room for the keyboard itself")
    }

    /// The Folders search field is SwiftUI's `.searchable`, on iOS only, so this reads the source too. A global
    /// `UIScrollView` black appearance proxy painted an opaque black plate inside the search field's liquid-glass capsule,
    /// and opting the field out with `whenContainedInInstancesOf: [UISearchTextField.self]` did not reach its private
    /// scroll views. So there is no global scroll-view proxy: lists stay black through the table and collection proxies,
    /// and nothing restyles the search field or replaces it.
    func testTheSearchFieldKeepsItsGlassWhileTyping() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let chrome = try String(contentsOf: sources.appendingPathComponent("BrainChrome.swift"), encoding: .utf8)
        XCTAssertFalse(chrome.contains("UIScrollView.appearance().backgroundColor = black"), "the global proxy is the plate in the glass")
        XCTAssertFalse(chrome.contains("UIScrollView.appearance(whenContainedInInstancesOf:"), "the containment opt-out did not work; nothing to opt out of now")
        XCTAssertTrue(chrome.contains("UITableView.appearance().backgroundColor = black"), "lists stay true black")
        XCTAssertTrue(chrome.contains("UICollectionView.appearance().backgroundColor = black"), "lists stay true black")
        XCTAssertFalse(chrome.contains("UISearchTextField.appearance("), "no fill of our own on the field: the capsule is the system's glass")
        XCTAssertFalse(chrome.contains("UISearchBar.appearance("), "nor on the bar around it")
        let home = try String(contentsOf: sources.appendingPathComponent("FoldersView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains(".searchable(text: $query, prompt: \"Search\")"), "still the system's search field")
        for custom in ["UISearchBar", "UISearchController", "TextField(\"Search\""] {
            XCTAssertFalse(home.contains(custom), "no search UI of our own: \(custom)")
        }
    }

    func testTheNumberedListButtonIsNextToTheBulletedOne() throws {
        let bullet = try XCTUnwrap(EditorBar.buttons.firstIndex(of: .bullet))
        XCTAssertEqual(EditorBar.buttons[bullet + 1], .numbered)
    }

    func testTheTextStylesMenuIsTheFourStylesThenTheMarks() {
        XCTAssertEqual(EditorBar.styleMenu.first, [.title, .heading, .subheading, .body])
        XCTAssertEqual(EditorBar.styleMenu.last, [.indent, .outdent])
        XCTAssertEqual(EditorAction.title.edit(in: "a", selection: NSRange(location: 0, length: 0)).applied(to: "a"), "# a")
        XCTAssertEqual(EditorAction.heading.edit(in: "a", selection: NSRange(location: 0, length: 0)).applied(to: "a"), "## a")
        XCTAssertEqual(EditorAction.subheading.edit(in: "a", selection: NSRange(location: 0, length: 0)).applied(to: "a"), "### a")
        XCTAssertEqual(EditorAction.body.edit(in: "# a", selection: NSRange(location: 2, length: 0)).applied(to: "# a"), "a")
    }

    func testBarActionsAreTheKitsEdits() {
        let selection = NSRange(location: 2, length: 0)
        XCTAssertEqual(EditorAction.checklist.edit(in: "שלום", selection: selection), MarkdownEdits.toggleTask(in: "שלום", selection: selection))
        XCTAssertEqual(EditorAction.bold.edit(in: "שלום", selection: selection), MarkdownEdits.toggleWrap("**", in: "שלום", selection: selection))
        XCTAssertEqual(EditorAction.direction.edit(in: "שלום", selection: selection), MarkdownEdits.toggleDirection(in: "שלום", selection: selection))
        XCTAssertEqual(EditorAction.numbered.edit(in: "שלום", selection: selection), MarkdownEdits.toggleNumbered(in: "שלום", selection: selection))
        XCTAssertEqual(EditorAction.indent.edit(in: "- a\n- b", selection: NSRange(location: 6, length: 0)), MarkdownEdits.indent(in: "- a\n- b", selection: NSRange(location: 6, length: 0)))
        XCTAssertEqual(EditorAction.outdent.edit(in: "  - a", selection: selection), MarkdownEdits.outdent(in: "  - a", selection: selection))
        XCTAssertEqual(EditorAction.table.edit(in: "a", selection: NSRange(location: 1, length: 0)), MarkdownEdits.insertTable(in: "a", selection: NSRange(location: 1, length: 0)))
    }

    func testTheTableButtonSitsBetweenLinkAndDirection() throws {
        let link = try XCTUnwrap(EditorBar.buttons.firstIndex(of: .link))
        XCTAssertEqual(EditorBar.buttons[link + 1], .table)
        XCTAssertEqual(EditorBar.buttons[link + 2], .direction)
    }
}


