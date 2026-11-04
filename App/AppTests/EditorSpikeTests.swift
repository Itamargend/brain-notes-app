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

    func testBarActionsAreTheKitsEdits() {
        let selection = NSRange(location: 2, length: 0)
        XCTAssertEqual(EditorAction.checklist.edit(in: "שלום", selection: selection), MarkdownEdits.toggleTask(in: "שלום", selection: selection))
        XCTAssertEqual(EditorAction.bold.edit(in: "שלום", selection: selection), MarkdownEdits.toggleWrap("**", in: "שלום", selection: selection))
        XCTAssertEqual(EditorAction.direction.edit(in: "שלום", selection: selection), MarkdownEdits.toggleDirection(in: "שלום", selection: selection))
    }
}
