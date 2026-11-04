import AppKit
import BrainNotesKit
import SwiftUI
import XCTest
@testable import BrainNotes

/// Live Preview on the real text view, in a real window. What the plan asks of it: the look changes and the bytes never do.
@MainActor
final class LivePreviewTests: XCTestCase {
    private var window: NSWindow!
    private var edits: [String] = []

    /// `.logs/shots/editor/` in this repo (git-ignored).
    static let shots = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".logs/shots/editor", isDirectory: true)

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        edits = []
    }

    /// The real representable in a window, with the note open, as `NoteScreen` makes it.
    private func editor(_ text: String, size: NSSize = NSSize(width: 460, height: 640), dark: Bool = false, focused: Bool = true) async throws -> EditorTextView {
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: MarkdownTextView(text: text, externalRevision: 0, onEdit: { [weak self] in self?.edits.append($0) }))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(120))
        let view = try XCTUnwrap(find(window.contentView))
        window.makeFirstResponder(focused ? view : nil)
        try await settle()
        return view
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    private func find(_ view: NSView?) -> EditorTextView? {
        guard let view else { return nil }
        if let found = view as? EditorTextView { return found }
        for sub in view.subviews {
            if let found = find(sub) { return found }
        }
        return nil
    }

    private func bitmap() throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func picture(_ name: String) throws {
        let png = try XCTUnwrap(try bitmap().representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        try png.write(to: Self.shots.appendingPathComponent("\(name).png"))
    }

    private func storage(_ view: NSTextView) throws -> NSTextStorage { try XCTUnwrap(view.textStorage) }

    /// The stretches of text hidden right now, in order.
    private func hidden(_ view: NSTextView) throws -> [String] {
        let s = try storage(view)
        var out: [String] = []
        s.enumerateAttribute(.bnHiddenMark, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            if value != nil { out.append((s.string as NSString).substring(with: range)) }
        }
        return out
    }

    private func range(of needle: String, in view: NSTextView) -> NSRange { (view.string as NSString).range(of: needle) }

    private func caret(_ view: NSTextView, at needle: String, offset: Int = 0) async throws {
        view.setSelectedRange(NSRange(location: range(of: needle, in: view).location + offset, length: 0))
        try await settle()
    }

    private func font(_ view: NSTextView, at needle: String) throws -> NSFont {
        try XCTUnwrap(try storage(view).attribute(.font, at: range(of: needle, in: view).location, effectiveRange: nil) as? NSFont)
    }

    private func assertBytes(_ view: NSTextView, _ expected: String, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8), "\(view.string.debugDescription) \(note)", file: file, line: line)
    }

    static let sample = """
    # A title with **bold**

    A paragraph with **bold**, *italic*, `code`, a [[wiki link]], [a link](https://example.com) and https://example.org.

    פסקה בעברית עם **מילים מודגשות** ו-*נטויות* באמצע, ואחריה SwiftUI.

    ## רשימת משימות

    - [ ] לבדוק את הסמן
    - [x] משימה שבוצעה
    - [ ] Check the caret
    - [x] A task that is done
    - A bullet
      - A nested bullet
    - כדור בעברית

    > A quote that goes on long enough to wrap around to a second line in this window, to see the bar.

    1. First
    2. Second
       1. Nested
    3. Third

    1. פריט ראשון
    2. פריט שני

    ---

    ```swift
    let **not** = "bold"
    ```

    The end.

    """

    // MARK: what is hidden

    func testWithNoFocusEveryMarkIsHidden() async throws {
        let view = try await editor(Self.sample, focused: false)
        assertBytes(view, Self.sample)
        let marks = try hidden(view)
        for mark in ["# ", "**", "*", "`", "[[", "]]", "[", "](https://example.com)", "## ", "- [ ] ", "- [x] ", "- ", "  - ", "> ", "---", "```swift", "```"] {
            XCTAssertTrue(marks.contains(mark), "\(mark) is hidden: \(marks)")
        }
        XCTAssertFalse(marks.contains("1. "), "a number is what a reader needs")
        XCTAssertFalse(marks.joined().contains("https://example.org"), "a bare URL is text")
        XCTAssertFalse(marks.joined().contains("not"), "nothing inside code is syntax")
        try picture("mac-live-preview-light")
    }

    func testHiddenMarksTakeNoRoomAndDrawNothing() async throws {
        let view = try await editor("A **bold** word\nA bold word\n", focused: false)
        let s = try storage(view)
        let marked = s.attributedSubstring(from: NSRange(location: 0, length: 15)).size().width
        let plain = s.attributedSubstring(from: NSRange(location: 16, length: 11)).size().width
        // The bold word is wider than the plain one, so this is the marks' share and no more.
        let bold = s.attributedSubstring(from: range(of: "bold", in: view)).size().width
        let regular = s.attributedSubstring(from: NSRange(location: 18, length: 4)).size().width
        XCTAssertEqual(marked - plain, bold - regular, accuracy: 0.2, "four marks take no room")
        let attributes = s.attributes(at: 2, effectiveRange: nil)
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, NSColor.clear)
        XCTAssertLessThan((attributes[.font] as? NSFont)?.pointSize ?? 99, 0.1)
    }

    func testTheParagraphHoldingTheCaretShowsItsMarksAndOnlyIt() async throws {
        let text = "# Title\nA **bold** line\nAnother *italic* line\n"
        let view = try await editor(text)
        try await caret(view, at: "bold")
        XCTAssertEqual(try hidden(view), ["# ", "*", "*"], "the caret's line shows its marks")
        XCTAssertEqual(try storage(view).attribute(.bnHiddenMark, at: range(of: "**", in: view).location, effectiveRange: nil) as? Bool, nil)
        let dim = try storage(view).attribute(.foregroundColor, at: range(of: "**", in: view).location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(dim, NSColor.tertiaryLabelColor, "dimmed, as the slice asks")

        try await caret(view, at: "italic")
        XCTAssertEqual(try hidden(view), ["# ", "**", "**"], "the marks hide behind the caret and show ahead of it")

        try await caret(view, at: "Title")
        XCTAssertEqual(try hidden(view), ["**", "**", "*", "*"])
        assertBytes(view, text)
    }

    func testASelectionShowsTheMarksOfEveryParagraphItTouches() async throws {
        let text = "**one** a\n**two** b\n**three** c\n**four** d\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: range(of: "two", in: view).location, length: range(of: "three", in: view).location - range(of: "two", in: view).location + 2))
        try await settle()
        XCTAssertEqual(try hidden(view), ["**", "**", "**", "**"], "the first and last lines, four marks; the middle two show")
        XCTAssertNil(try storage(view).attribute(.bnHiddenMark, at: range(of: "two", in: view).location - 1, effectiveRange: nil))
        XCTAssertNil(try storage(view).attribute(.bnHiddenMark, at: range(of: "three", in: view).location - 1, effectiveRange: nil))

        // A triple tap reaches the start of the next line, and that line stays as it was.
        view.setSelectedRange((view.string as NSString).paragraphRange(for: range(of: "two", in: view)))
        try await settle()
        XCTAssertNil(try storage(view).attribute(.bnHiddenMark, at: range(of: "two", in: view).location - 1, effectiveRange: nil))
        XCTAssertNotNil(try storage(view).attribute(.bnHiddenMark, at: range(of: "three", in: view).location - 1, effectiveRange: nil))
    }

    /// A hidden marker takes no room, so a tap at a line's start can land in front of it. Typing there would end the heading.
    func testACaretArrivingInAHiddenMarkerGoesBehindIt() async throws {
        let text = "intro\n# Title\n- [ ] Task\n  - Nested\n> Quote\n---\n1. One\n"
        let view = try await editor(text)
        try await caret(view, at: "intro")
        for (needle, marker) in [("Title", "# "), ("Task", "- [ ] "), ("Nested", "  - "), ("Quote", "> ")] {
            try await caret(view, at: "intro")
            let start = range(of: needle, in: view).location - (marker as NSString).length
            view.setSelectedRange(NSRange(location: start, length: 0))
            try await settle()
            XCTAssertEqual(view.selectedRange(), NSRange(location: range(of: needle, in: view).location, length: 0), marker)
            view.insertText("x", replacementRange: view.selectedRange())
            try await settle()
            XCTAssertTrue(view.string.contains(marker + "x" + needle), "what is typed goes in the text: \(marker)")
            view.undoManager?.undo()
            try await settle()
            assertBytes(view, text)
        }
        // With the marks showing, the caret can go into them.
        try await caret(view, at: "Title")
        let marker = range(of: "# Title", in: view).location
        view.setSelectedRange(NSRange(location: marker, length: 0))
        try await settle()
        XCTAssertEqual(view.selectedRange().location, marker, "a line that shows its marks lets the caret in")
        // A rule is all marker: behind it, at the end of the line.
        try await caret(view, at: "intro")
        let rule = range(of: "---", in: view).location
        view.setSelectedRange(NSRange(location: rule, length: 0))
        try await settle()
        XCTAssertEqual(view.selectedRange().location, rule + 3)
        // What is typed in front of a number would end the list too. A selection is left alone.
        try await caret(view, at: "intro")
        let number = range(of: "1. One", in: view).location
        view.setSelectedRange(NSRange(location: number, length: 0))
        try await settle()
        XCTAssertEqual(view.selectedRange().location, number + 3)
        try await caret(view, at: "intro")
        let heading = range(of: "# Title", in: view).location
        view.setSelectedRange(NSRange(location: heading, length: 4))
        try await settle()
        XCTAssertEqual(view.selectedRange(), NSRange(location: heading, length: 4))
        assertBytes(view, text)
    }

    /// A direction mark takes no room either. A letter typed in front of it would flip the line and strand the mark.
    func testACaretArrivingGoesBehindADirectionMarkToo() async throws {
        let rlm = "\u{200F}"
        let text = "intro\n# \(rlm)Title\n\(rlm)plain\n1. \(rlm)one\n"
        let view = try await editor(text)
        func arrive(at location: Int) async throws -> Int {
            try await caret(view, at: "intro")
            view.setSelectedRange(NSRange(location: location, length: 0))
            try await settle()
            return view.selectedRange().location
        }
        let heading = range(of: "# ", in: view).location
        var landed = try await arrive(at: heading)
        XCTAssertEqual(landed, heading + 3, "behind the marker and the mark")
        landed = try await arrive(at: heading + 2)
        XCTAssertEqual(landed, heading + 3, "between them too")
        let plain = (view.string as NSString).range(of: "\(rlm)plain", options: .literal).location
        landed = try await arrive(at: plain)
        XCTAssertEqual(landed, plain + 1)
        let number = range(of: "1. ", in: view).location
        landed = try await arrive(at: number)
        XCTAssertEqual(landed, number + 4, "behind the number and the mark")
        landed = try await arrive(at: number + 3)
        XCTAssertEqual(landed, number + 4, "and not in front of the mark behind it")

        _ = try await arrive(at: heading)
        view.insertText("x", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "intro\n# \(rlm)xTitle\n\(rlm)plain\n1. \(rlm)one\n")
        let direction = (try storage(view).attribute(.paragraphStyle, at: range(of: "xTitle", in: view).location, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection
        XCTAssertEqual(direction, .rightToLeft, "the line kept its direction")
    }

    /// In VoiceOver every mark is text with a caret stop: nothing moves the caret on its own.
    func testVoiceOverKeepsEveryCaretStop() async throws {
        let view = try await editor("intro\n# Title\n")
        view.coordinator?.preview?.setHidesMarks(false)
        try await caret(view, at: "intro")
        let start = range(of: "# Title", in: view).location
        view.setSelectedRange(NSRange(location: start, length: 0))
        try await settle()
        XCTAssertEqual(view.selectedRange().location, start)
    }

    func testLosingTheFocusHidesTheCaretLineToo() async throws {
        let view = try await editor("**a** b\n")
        try await caret(view, at: "a")
        XCTAssertEqual(try hidden(view), [])
        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertEqual(try hidden(view), ["**", "**"])
        window.makeFirstResponder(view)
        try await settle()
        XCTAssertEqual(try hidden(view), [])
    }

    func testTheFontsFollowTheSpans() async throws {
        let view = try await editor("plain **bold** *italic* `code` ***both*** ~~gone~~\n# Head *it*\n", focused: false)
        XCTAssertFalse(try font(view, at: "plain").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(view, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(view, at: "italic").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(try font(view, at: "code").isFixedPitch)
        let both = try font(view, at: "both").fontDescriptor.symbolicTraits
        XCTAssertTrue(both.contains(.bold) && both.contains(.italic))
        XCTAssertNotNil(try storage(view).attribute(.strikethroughStyle, at: range(of: "gone", in: view).location, effectiveRange: nil))
        XCTAssertGreaterThan(try font(view, at: "Head").pointSize, try font(view, at: "plain").pointSize)
        XCTAssertTrue(try font(view, at: "it").fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testLinksAreInTheAccentColourAndWikiLinksKnowTheirTarget() async throws {
        let view = try await editor("[[Note|shown]] and [text](u) and https://a.b\n", focused: false)
        let accent = NSColor(named: "AccentColor")
        for needle in ["shown", "text", "https://a.b"] {
            XCTAssertEqual(try storage(view).attribute(.foregroundColor, at: range(of: needle, in: view).location, effectiveRange: nil) as? NSColor, accent, needle)
        }
        XCTAssertEqual(try storage(view).attribute(.bnWikiTarget, at: range(of: "shown", in: view).location, effectiveRange: nil) as? String, "Note")
    }

    // MARK: what the second phone test showed

    /// `- [ ] # **Shana`, written out raw on the phone. The heading and the bold are hidden and styled inside a task.
    func testAHeadingAndBoldInsideATaskAreHiddenAndStyled() async throws {
        let text = "- [ ] # **Shana\nnext line\n"
        let view = try await editor(text, focused: false)
        XCTAssertEqual(try hidden(view), ["- [ ] # **"], "the task's marker, the heading's and the bold's, all touching")
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let shana = try font(view, at: "Shana")
        XCTAssertGreaterThan(shana.pointSize, body, "a title's size")
        XCTAssertTrue(shana.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(try storage(view).attribute(.bnLineDecoration, at: range(of: "Shana", in: view).location, effectiveRange: nil) as? LineDecoration,
                       LineDecoration(kind: .checkbox(done: false), rightToLeft: false, lead: 0), "and it is still a checkbox")
        assertBytes(view, text)
        try picture("mac-task-with-heading")

        // On the caret's line every mark shows, dimmed, and the text keeps its look.
        window.makeFirstResponder(view)
        try await caret(view, at: "Shana", offset: 2)
        XCTAssertEqual(try hidden(view), [])
        for mark in ["- [ ] ", "# ", "**"] {
            let color = try storage(view).attribute(.foregroundColor, at: range(of: mark, in: view).location, effectiveRange: nil) as? NSColor
            XCTAssertEqual(color, NSColor.tertiaryLabelColor, mark)
        }
        XCTAssertGreaterThan(try font(view, at: "Shana").pointSize, body)
        XCTAssertGreaterThan((view.typingAttributes[.font] as? NSFont)?.pointSize ?? 0, body, "what is typed here reads at the same size")

        // A tick still changes the one byte.
        try await caret(view, at: "next")
        try click(view, at: try checkboxCenter(view, of: "Shana"))
        try await settle()
        assertBytes(view, "- [x] # **Shana\nnext line\n")
    }

    func testEveryKindOfItemShowsItsHeadingAndInlineMarksHidden() async throws {
        let text = "- [x] ## *it* **bo**\n- ### `co`\n> # q\n- [ ] #tag\n- [ ] # שנה **טובה**\n"
        let view = try await editor(text, focused: false)
        let marks = try hidden(view)
        for mark in ["- [x] ## *", "*", "**", "- ### `", "`", "> # ", "- [ ] ", "- [ ] # "] {
            XCTAssertTrue(marks.contains(mark), "\(mark) in \(marks)")
        }
        XCTAssertFalse(marks.joined().contains("#tag"), "a tag is text")
        XCTAssertTrue(view.string.contains("#tag"))
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        XCTAssertGreaterThan(try font(view, at: "it").pointSize, body)
        XCTAssertTrue(try font(view, at: "it").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertGreaterThan(try font(view, at: "bo**").pointSize, body)
        XCTAssertGreaterThan(try font(view, at: "q").pointSize, body)
        XCTAssertEqual(try font(view, at: "#tag").pointSize, body)
        let hebrew = try XCTUnwrap(try storage(view).attribute(.paragraphStyle, at: range(of: "שנה", in: view).location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(hebrew.baseWritingDirection, .rightToLeft)
        XCTAssertGreaterThan(try font(view, at: "שנה").pointSize, body)
        assertBytes(view, text)
    }

    /// A caret arriving at such a line goes behind every block marker it has, so typing doesn't end the task or the heading.
    func testACaretArrivingGoesBehindAHeadingInsideATask() async throws {
        let rlm = "\u{200F}"
        let text = "intro\n- [ ] # Shana\n- [ ] \(rlm)# Marked\n"
        let view = try await editor(text)
        func arrive(at location: Int) async throws -> Int {
            try await caret(view, at: "intro")
            view.setSelectedRange(NSRange(location: location, length: 0))
            try await settle()
            return view.selectedRange().location
        }
        let task = range(of: "- [ ] # Shana", in: view).location
        let shana = range(of: "Shana", in: view).location
        for offset in 0..<8 {
            let landed = try await arrive(at: task + offset)
            XCTAssertEqual(landed, shana, "from offset \(offset)")
        }
        let marked = range(of: "Marked", in: view).location
        let landed = try await arrive(at: range(of: "- [ ] \(rlm)#", in: view).location)
        XCTAssertEqual(landed, marked)
        view.insertText("x", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "intro\n- [ ] # Shana\n- [ ] \(rlm)# xMarked\n")
    }

    /// The characters of one line of the laid out text, by the fragments TextKit made.
    private func lineFragments(_ view: NSTextView, holding needle: String) throws -> [NSRange] {
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        let at = range(of: needle, in: view).location
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: at))
        let fragment = try XCTUnwrap(manager.textLayoutFragment(for: location))
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return fragment.textLineFragments.map { NSRange(location: $0.characterRange.location + start, length: $0.characterRange.length) }
    }

    /// `[[sisi]]` is one link on one line, with its marks showing or hidden, also where the window is narrow.
    func testAWikiLinkStaysOnOneLine() async throws {
        let view = try await editor("[[sisi]]\nnext\n", focused: false)
        XCTAssertEqual(try lineFragments(view, holding: "sisi").filter { $0.length > 0 }.count, 1)
        XCTAssertEqual(try hidden(view), ["[[", "]]"])
        XCTAssertEqual(try storage(view).attribute(.bnWikiTarget, at: range(of: "sisi", in: view).location, effectiveRange: nil) as? String, "sisi")
        window.makeFirstResponder(view)
        try await caret(view, at: "sisi", offset: 2)
        XCTAssertEqual(try lineFragments(view, holding: "sisi").filter { $0.length > 0 }.count, 1, "with its marks showing")

        // Where a line has to wrap, it wraps in front of the link and not inside it.
        for width in stride(from: CGFloat(150), through: 420, by: 18) {
            let wrapped = try await editor("some words to wrap a line near a [[sisi]] and more words after it\n", size: NSSize(width: width, height: 300), focused: false)
            let link = wrapped.string.range(of: "[[sisi]]").map { NSRange($0, in: wrapped.string) }
            let holding = try lineFragments(wrapped, holding: "sisi").filter { NSIntersectionRange($0, try XCTUnwrap(link)).length > 0 }
            XCTAssertEqual(holding.count, 1, "at width \(width): \(holding)")
        }
    }

    /// The bar leaves the caret inside `[[]]`, and pressing Return after the name is what split it on the phone.
    func testReturnAfterTypingALinkNameKeepsItOneLink() async throws {
        let view = try await editor("first\n")
        try await caret(view, at: "first", offset: 5)
        view.insertText("\n", replacementRange: view.selectedRange())
        view.coordinator?.perform(.link, in: view)
        try await settle()
        assertBytes(view, "first\n[[]]\n")
        view.insertText("sisi", replacementRange: view.selectedRange())
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "first\n[[sisi]]\n\n")
        XCTAssertEqual(view.selectedRange().location, ("first\n[[sisi]]\n" as NSString).length, "on the new line")
        XCTAssertEqual(try storage(view).attribute(.bnWikiTarget, at: range(of: "sisi", in: view).location, effectiveRange: nil) as? String, "sisi")
        XCTAssertEqual(try hidden(view), ["[[", "]]"], "and the caret has left it")
        XCTAssertEqual(edits.last.map { Array($0.utf8) }, Array("first\n[[sisi]]\n\n".utf8), "the autosave has it")
    }

    /// What the phone's note holds: a line break inside the brackets, written before this fix. Rendering can't join two
    /// lines of the file, and no byte moves.
    func testALinkAlreadySplitInTheFileStaysAsItIs() async throws {
        let text = "[[sisi\n]]\n"
        let view = try await editor(text, focused: false)
        XCTAssertEqual(try hidden(view), [], "two lines of plain text, which is what the phone drew")
        XCTAssertNil(try storage(view).attribute(.bnWikiTarget, at: range(of: "sisi", in: view).location, effectiveRange: nil))
        assertBytes(view, text)
    }

    func testReturnInsideBoldKeepsBothHalvesBoldAndIsOneUndoStep() async throws {
        let view = try await editor("**Shana tova**\n")
        try await caret(view, at: "tova")
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "**Shana **\n**tova**\n")
        XCTAssertEqual(view.selectedRange().location, range(of: "tova", in: view).location)
        XCTAssertTrue(try font(view, at: "tova").fontDescriptor.symbolicTraits.contains(.bold))
        undo.undo()
        try await settle()
        assertBytes(view, "**Shana tova**\n")
        undo.redo()
        try await settle()
        assertBytes(view, "**Shana **\n**tova**\n")
    }

    /// Return in fenced code writes a line break and nothing else, as the kit's tests say.
    func testReturnInCodeIsJustALineBreak() async throws {
        let view = try await editor("```\n[[a]]\n```\n")
        try await caret(view, at: "a]]", offset: 1)
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "```\n[[a\n]]\n```\n")
    }

    /// The running log from the phone's screenshot. Tables come with `.plan/F-tables.md`. Until then they stay plain text:
    /// pipes showing, nothing hidden, nothing drawn, the file's bytes untouched, and Return an ordinary line break.
    func testATableStaysPlainText() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo-brain/health/running-log.md")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        XCTAssertTrue(text.contains("|------|----------|"), "the fixture has its table")
        let view = try await editor(text, focused: false)
        assertBytes(view, text)
        XCTAssertEqual(try hidden(view), ["# "], "only the title's mark")
        let s = try storage(view)
        var drawn = 0
        s.enumerateAttribute(.bnLineDecoration, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if value != nil { drawn += 1 }
        }
        XCTAssertEqual(drawn, 0, "no rule, no grid")
        XCTAssertEqual(try font(view, at: "| Date").pointSize, NSFont.preferredFont(forTextStyle: .body).pointSize)
        window.makeFirstResponder(view)
        try await caret(view, at: "tempo", offset: 2)
        assertBytes(view, text)
        XCTAssertEqual(edits, [], "nothing reached the autosave")
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, text.replacingOccurrences(of: "tempo", with: "te\nmpo"))
    }

    // MARK: lists

    private func paragraphStyle(_ view: NSTextView, at needle: String) throws -> NSParagraphStyle {
        try XCTUnwrap(try storage(view).attribute(.paragraphStyle, at: range(of: needle, in: view).location, effectiveRange: nil) as? NSParagraphStyle)
    }

    /// What the event loop does after each real event: a test's run loop doesn't.
    private func endOfEvent() { _ = (UndoManager.self as AnyObject).perform(NSSelectorFromString("_endTopLevelGroupings")) }

    func testANumberedListKeepsItsNumbersAndHangsItsLines() async throws {
        let text = "1. First, long enough to wrap around to a second line in a window this wide, which takes some words\n2. Second\n   1. Nested\n      1. Deeper\n10. Tenth\n"
        let view = try await editor(text, focused: false)
        XCTAssertEqual(try hidden(view), ["   ", "      "], "numbers stay, and only their indent goes")
        let first = try paragraphStyle(view, at: "First")
        XCTAssertEqual(first.firstLineHeadIndent, 0)
        XCTAssertGreaterThanOrEqual(first.headIndent, LivePreviewMetrics.markerSlot, "wrapped lines hang under the text")
        let nested = try paragraphStyle(view, at: "Nested")
        XCTAssertEqual(nested.firstLineHeadIndent, LivePreviewMetrics.levelIndent, "one level in")
        XCTAssertEqual(nested.headIndent, first.headIndent + LivePreviewMetrics.levelIndent)
        XCTAssertEqual(try paragraphStyle(view, at: "Deeper").firstLineHeadIndent, 2 * LivePreviewMetrics.levelIndent)
        XCTAssertEqual(try storage(view).attribute(.foregroundColor, at: range(of: "2.", in: view).location, effectiveRange: nil) as? NSColor, NSColor.secondaryLabelColor)

        // The text of `1.` and `10.` starts in the same place: the space takes up the difference.
        let s = try storage(view)
        func width(_ marker: String) -> CGFloat { s.attributedSubstring(from: range(of: marker, in: view)).size().width }
        XCTAssertEqual(width("1. F"), width("10. T"), accuracy: 12, "both have the F and the T in them")
        XCTAssertEqual(width("2. "), width("10. "), accuracy: 1)
        XCTAssertEqual(width("2. "), first.headIndent, accuracy: 1)
        XCTAssertNil(s.attribute(.kern, at: range(of: "1. F", in: view).location, effectiveRange: nil), "the number itself is as it is")
        XCTAssertNotNil(s.attribute(.kern, at: range(of: "1. F", in: view).location + 2, effectiveRange: nil))
        assertBytes(view, text)
        try picture("mac-numbered-list")

        // On the caret's line the indent shows as what it is, and the number doesn't move away from the text.
        window.makeFirstResponder(view)
        try await caret(view, at: "Nested")
        XCTAssertEqual(try hidden(view), ["      "])
        XCTAssertEqual(try paragraphStyle(view, at: "Nested").firstLineHeadIndent, 0)
        assertBytes(view, text)
    }

    func testAHebrewNumberedListRunsRightToLeft() async throws {
        let view = try await editor("1. פריט ראשון\n2. פריט שני\n   1. פריט פנימי\n", focused: false)
        let style = try paragraphStyle(view, at: "ראשון")
        XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(style.alignment, .right)
        XCTAssertGreaterThan(style.headIndent, 0)
        XCTAssertEqual(try paragraphStyle(view, at: "פנימי").firstLineHeadIndent, LivePreviewMetrics.levelIndent)
        try picture("mac-numbered-list-hebrew")
    }

    /// Return makes the next item, again and again, and on an empty one the list ends. Through the real text view.
    func testReturnGoesOnWithAListAndEndsIt() async throws {
        for (marker, next, text) in [("- ", "- ", "Bullet"), ("- [ ] ", "- [ ] ", "Task"), ("- [x] ", "- [ ] ", "Done"), ("1. ", "2. ", "One"), ("- ", "- ", "כדור"), ("1. ", "2. ", "פריט")] {
            let view = try await editor(marker + text + "\n")
            try await caret(view, at: text, offset: (text as NSString).length)
            view.insertText("\n", replacementRange: view.selectedRange())
            try await settle()
            assertBytes(view, marker + text + "\n" + next + "\n")
            let caretAt = ((marker + text + "\n" + next) as NSString).length
            XCTAssertEqual(view.selectedRange(), NSRange(location: caretAt, length: 0), "behind the new marker")
            XCTAssertEqual(edits.last.map { Array($0.utf8) }, Array(view.string.utf8), "the autosave has it")
            view.insertText("x", replacementRange: view.selectedRange())
            try await settle()
            XCTAssertTrue(view.string.hasSuffix(next + "x\n"), "what is typed goes in the item")
            view.undoManager?.removeAllActions()
            view.insertText("\n", replacementRange: view.selectedRange())
            try await settle()
            // An empty one: the list ends, and the line stays.
            view.insertText("\n", replacementRange: view.selectedRange())
            try await settle()
            XCTAssertTrue(view.string.hasSuffix(next + "x\n\n"), view.string.debugDescription)
            XCTAssertEqual(view.selectedRange().location, (view.string as NSString).length - 1, "on the line that stayed")
            window.orderOut(nil)
        }
    }

    func testReturnRenumbersAndIsOneUndoStep() async throws {
        let text = "1. a\n2. b\n3. c\n"
        let view = try await editor(text)
        try await caret(view, at: "a", offset: 1)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.insertText("\n", replacementRange: view.selectedRange())
        endOfEvent()
        try await settle()
        assertBytes(view, "1. a\n2. \n3. b\n4. c\n")
        XCTAssertEqual(view.selectedRange().location, ("1. a\n2. " as NSString).length)
        undo.undo()
        endOfEvent()
        try await settle()
        assertBytes(view, text, "one step, and it isn't taken for a new edit")
        undo.redo()
        endOfEvent()
        try await settle()
        assertBytes(view, "1. a\n2. \n3. b\n4. c\n")
        XCTAssertEqual(edits.last.map { Array($0.utf8) }, Array(view.string.utf8), "the autosave follows")
    }

    /// Undo puts back text with line endings in it, which looks like an edit a list has to follow. It isn't.
    func testUndoOfDeletedLinesLeavesTheNumbersAsTheyWere() async throws {
        let text = "1. a\n2. b\n3. c\n"
        let view = try await editor(text)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        let line = (view.string as NSString).paragraphRange(for: range(of: "b", in: view))
        view.insertText("", replacementRange: line)
        endOfEvent()
        try await settle()
        assertBytes(view, "1. a\n2. c\n", "the numbers close up")
        undo.undo()
        endOfEvent()
        try await settle()
        assertBytes(view, text)
    }

    /// Undo puts back the numbers the file had, even if they were never in order. If it were taken for a new edit, it would
    /// put them in order: there is nothing else to tell these apart, since numbers in order come out the same either way.
    func testUndoPutsBackNumbersThatWereNotInOrder() async throws {
        let text = "1. a\n1. b\n1. c\n"
        let view = try await editor(text)
        try await caret(view, at: "a", offset: 1)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.insertText("\n", replacementRange: view.selectedRange())
        endOfEvent()
        try await settle()
        assertBytes(view, "1. a\n2. \n3. b\n4. c\n")
        undo.undo()
        endOfEvent()
        try await settle()
        assertBytes(view, text)
        undo.redo()
        endOfEvent()
        try await settle()
        assertBytes(view, "1. a\n2. \n3. b\n4. c\n")
    }

    /// Writing an edit comes back through the delegate on a Mac, with what was just decided. Asked again, it would think the
    /// first item of a list had gone, and give the rest of this one its old start.
    func testAnEditIsDecidedOnce() async throws {
        let view = try await editor("3. a\n4. b\n")
        try await caret(view, at: "a")
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, "a\n1. b\n")
    }

    func testTabAndShiftTabNestAListItem() async throws {
        let view = try await editor("1. a\n2. b\n3. c\n")
        try await caret(view, at: "b", offset: 1)
        view.insertTab(nil)
        try await settle()
        assertBytes(view, "1. a\n   1. b\n2. c\n")
        XCTAssertEqual(view.selectedRange().location, range(of: "b", in: view).location + 1, "the caret stays with its letter")
        view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        try await settle()
        assertBytes(view, "1. a\n2. b\n3. c\n")
        XCTAssertEqual(edits.last.map { Array($0.utf8) }, Array("1. a\n2. b\n3. c\n".utf8))

        // On anything else, a tab is a tab.
        let plain = try await editor("plain\n")
        try await caret(plain, at: "plain", offset: 5)
        plain.insertTab(nil)
        try await settle()
        assertBytes(plain, "plain\t\n")
        plain.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        try await settle()
        assertBytes(plain, "plain\t\n")
    }

    /// As the phone asks for them: from the Aa menu, through the action.
    func testIndentAndOutdentAreActions() async throws {
        let view = try await editor("- a\n- b\n  - c\n")
        try await caret(view, at: "b", offset: 1)
        view.coordinator?.perform(.indent, in: view)
        try await settle()
        assertBytes(view, "- a\n  - b\n    - c\n")
        view.coordinator?.perform(.outdent, in: view)
        try await settle()
        assertBytes(view, "- a\n- b\n  - c\n")
        XCTAssertEqual(try storage(view).attribute(.bnHiddenMark, at: range(of: "c", in: view).location - 1, effectiveRange: nil) as? Bool, true, "styled again, a level in")
    }

    func testDeleteBehindAMarkerTakesTheMarkerInOneGo() async throws {
        let view = try await editor("- [ ] a\n1. b\n2. c\n3. d\n")
        try await caret(view, at: "a")
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, "a\n1. b\n2. c\n3. d\n")
        XCTAssertEqual(view.selectedRange().location, 0)
        try await caret(view, at: "c")
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, "a\n1. b\nc\n1. d\n", "and what follows starts again")
        view.deleteBackward(nil)
        try await settle()
        assertBytes(view, "a\n1. bc\n2. d\n", "the next one is an ordinary delete, and the list closes up")
    }

    /// A new item in a Hebrew list starts on the right, with no mark written to the file for it.
    func testANewItemInAHebrewListStartsOnTheRight() async throws {
        let view = try await editor("- [ ] משימה\n")
        try await caret(view, at: "משימה", offset: 5)
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "- [ ] משימה\n- [ ] \n")
        let start = range(of: "\n- [ ] \n", in: view).location + 1
        let shown = try XCTUnwrap(try storage(view).attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(shown.baseWritingDirection, .rightToLeft)
        XCTAssertEqual((view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection, .rightToLeft, "what is typed next too")
        XCTAssertEqual(view.selectedRange().location, start + 6)

        // Its checkbox is on the right too, where a tap finds it.
        window.makeFirstResponder(nil)
        try await settle()
        let decoration = try XCTUnwrap(try storage(view).attribute(.bnLineDecoration, at: start, effectiveRange: nil) as? LineDecoration)
        XCTAssertTrue(decoration.rightToLeft)
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: start))
        let fragment = try XCTUnwrap(manager.textLayoutFragment(for: location) as? MarkdownLayoutFragment)
        let slot = fragment.markerSlot(lead: 0, rightToLeft: true).offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        let center = NSPoint(x: slot.midX + view.textContainerOrigin.x, y: slot.midY + view.textContainerOrigin.y)
        XCTAssertGreaterThan(center.x, view.bounds.midX)
        XCTAssertNotNil(view.taskParagraph(at: center))
        assertBytes(view, "- [ ] משימה\n- [ ] \n")

        // An English list stays on the left, a mark someone chose wins, and an item with text has its own direction.
        let english = try await editor("- [ ] Task\n- [ ] \n", focused: false)
        XCTAssertEqual(try XCTUnwrap(try storage(english).attribute(.paragraphStyle, at: 11, effectiveRange: nil) as? NSParagraphStyle).baseWritingDirection, .leftToRight)
        let marked = try await editor("- [ ] משימה\n- [ ] \u{200E}\n", focused: false)
        XCTAssertEqual(try XCTUnwrap(try storage(marked).attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle).baseWritingDirection, .leftToRight)
        let several = try await editor("- [ ] משימה\n- [ ] \n- [ ] \n", focused: false)
        let third = (several.string as NSString).length - 7
        XCTAssertEqual(try XCTUnwrap(try storage(several).attribute(.paragraphStyle, at: third, effectiveRange: nil) as? NSParagraphStyle).baseWritingDirection, .rightToLeft, "through empty ones")
    }

    /// Return during a composition belongs to the input method: the text isn't final, so no list action reads it.
    func testACompositionKeepsItsReturn() async throws {
        let view = try await editor("- a\n")
        try await caret(view, at: "a", offset: 1)
        view.setMarkedText("ש", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        let during = view.string
        let answer = view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange(), replacementString: "\n")
        XCTAssertEqual(answer, true, "the text view goes on as it would")
        assertBytes(view, during, "and nothing was written")
        view.unmarkText()
        view.didChangeText()
    }

    func testAPasteOfNumberedLinesTakesItsPlaceInTheList() async throws {
        let view = try await editor("1. a\n2. b\n")
        // In front of the second line's number, where a caret arriving from another line wouldn't stay.
        view.insertText("7. x\n8. y\n", replacementRange: NSRange(location: 5, length: 0))
        try await settle()
        assertBytes(view, "1. a\n2. x\n3. y\n4. b\n")
        XCTAssertEqual(view.selectedRange().location, ("1. a\n2. x\n3. y\n4. " as NSString).length, "a caret arriving on a list's line goes behind its number")
    }

    /// A marker's and a number's restyle reach every line the edit changed, not only the caret's.
    func testRenumberedLinesAreStyledAsWhatTheyNowAre() async throws {
        let view = try await editor("9. a\n10. b\n")
        try await caret(view, at: "a", offset: 1)
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "9. a\n10. \n11. b\n")
        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertEqual(try storage(view).attribute(.foregroundColor, at: range(of: "11.", in: view).location, effectiveRange: nil) as? NSColor, NSColor.secondaryLabelColor)
        XCTAssertEqual(try storage(view).attribute(.foregroundColor, at: range(of: "b", in: view).location, effectiveRange: nil) as? NSColor, NSColor.labelColor)
    }

    // MARK: one source of truth

    /// The whole point: opening, moving the caret, selecting, losing focus and being restyled write nothing.
    func testRenderingAloneNeverChangesTheBytes() async throws {
        let notes = [Self.sample, "line one\r\nline **two**\r\n- [ ] three\r\n", "\u{FEFF}bom and\u{200F} marks **x**\n", "no ending **at the end**", "- [ ] ", "   "]
        for note in notes {
            let view = try await editor(note)
            let length = (view.string as NSString).length
            for location in stride(from: 0, through: length, by: max(1, length / 17)) {
                view.setSelectedRange(NSRange(location: location, length: 0))
                assertBytes(view, note)
            }
            view.setSelectedRange(NSRange(location: 0, length: length))
            window.makeFirstResponder(nil)
            window.makeFirstResponder(view)
            view.coordinator?.preview?.setHidesMarks(false)
            view.coordinator?.preview?.setHidesMarks(true)
            view.coordinator?.preview?.restyleAll()
            try await settle()
            assertBytes(view, note)
            XCTAssertEqual(edits, [], "nothing reached the autosave")
            window.orderOut(nil)
        }
    }

    func testRandomNotesKeepTheirBytes() async throws {
        var random = SystemRandomNumberGenerator()
        let pieces = ["**", "*", "_", "`", "```\n", "~~~\n", "[[", "]]", "(", ")", "[", "]", "# ", "- ", "- [ ] ", "- [x] ", "> ", "1. ", "---\n", "\n", "\r\n", " ", "word", "מילה", "🙂", "\u{200F}", "\u{200E}", "https://a.b"]
        for _ in 0..<60 {
            var note = ""
            for _ in 0..<Int.random(in: 0...30, using: &random) { note += pieces.randomElement(using: &random)! }
            let storage = NSTextStorage(string: note)
            var context = MarkdownStyler.Context()
            context.fences = FencedCode(text: note as NSString)
            MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length), context: context)
            context.revealed = (note as NSString).paragraphRange(for: NSRange(location: (note as NSString).length / 2, length: 0))
            MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length), context: context)
            context.hidesMarks = false
            MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length), context: context)
            XCTAssertEqual(Array(storage.string.utf8), Array(note.utf8), note.debugDescription)
        }
    }

    func testTypingGoesThroughAndTheBytesAreJustWhatWasTyped() async throws {
        let view = try await editor("**a** b\n")
        try await caret(view, at: "b", offset: 1)
        view.insertText(" שלום", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "**a** b שלום\n")
        XCTAssertEqual(edits.last.map { Array($0.utf8) }, Array("**a** b שלום\n".utf8))
    }

    /// Bold is bold from its opening mark on, and the marks hide when the caret leaves.
    func testASpanComesAliveAsItIsTyped() async throws {
        let view = try await editor("x\nnext\n")
        try await caret(view, at: "x", offset: 1)
        view.insertText(" **bo", replacementRange: view.selectedRange())
        XCTAssertTrue(try font(view, at: "bo").fontDescriptor.symbolicTraits.contains(.bold))
        view.insertText("ld**", replacementRange: view.selectedRange())
        XCTAssertTrue(try font(view, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(try hidden(view), [], "the caret is still on the line")
        try await caret(view, at: "next")
        XCTAssertEqual(try hidden(view), ["**", "**"])
        assertBytes(view, "x **bold**\nnext\n")
    }

    /// What is typed next to a mark is neither dim nor hidden, also during a composition, when nothing is restyled.
    func testTypingAttributesAreThePlainLook() async throws {
        let view = try await editor("**a**\n# Title\n")
        try await caret(view, at: "a", offset: 2)
        XCTAssertNotEqual(view.typingAttributes[.foregroundColor] as? NSColor, NSColor.tertiaryLabelColor)
        XCTAssertEqual(view.typingAttributes[.foregroundColor] as? NSColor, NSColor.labelColor)
        XCTAssertGreaterThan((view.typingAttributes[.font] as? NSFont)?.pointSize ?? 0, 1)
        XCTAssertNil(view.typingAttributes[.bnHiddenMark])
        try await caret(view, at: "Title")
        XCTAssertGreaterThan((view.typingAttributes[.font] as? NSFont)?.pointSize ?? 0, NSFont.preferredFont(forTextStyle: .body).pointSize, "a heading's size")
    }

    func testACompositionIsNeverRestyledUntilItEnds() async throws {
        let view = try await editor("**a** b\n**c**\n")
        try await caret(view, at: "b", offset: 1)
        view.setMarkedText("ש", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        let during = try storage(view).attributes(at: range(of: "ש", in: view).location, effectiveRange: nil)
        XCTAssertNil(during[.bnHiddenMark])
        XCTAssertGreaterThan((during[.font] as? NSFont)?.pointSize ?? 0, 1, "a composition is visible")
        try await settle()
        let preview = try XCTUnwrap(view.coordinator?.preview)
        XCTAssertTrue(preview.isEditPending, "its text isn't final, so nothing has been styled for it")
        view.setSelectedRange(view.selectedRange())
        XCTAssertTrue(preview.isEditPending, "nor by a selection change while it runs")

        view.unmarkText()
        view.didChangeText()
        try await settle()
        XCTAssertFalse(preview.isEditPending, "styled once it ends")
        XCTAssertTrue(view.string.contains("ש"))
    }

    // MARK: undo

    func testUndoAndRedoKeepTheBytesAndTheLook() async throws {
        let view = try await editor("**a** one\ntwo\n")
        try await caret(view, at: "one", offset: 1)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.coordinator?.perform(.checklist, in: view)
        try await settle()
        assertBytes(view, "- [ ] **a** one\ntwo\n")
        undo.undo()
        try await settle()
        assertBytes(view, "**a** one\ntwo\n")
        XCTAssertNil(try storage(view).attribute(.bnLineDecoration, at: 0, effectiveRange: nil))
        undo.redo()
        try await settle()
        assertBytes(view, "- [ ] **a** one\ntwo\n")
        XCTAssertEqual(edits.last.map { Array($0.utf8) }, Array("- [ ] **a** one\ntwo\n".utf8), "undo and redo reach the autosave")
        // Restyled by what the storage saw, with no help from a delegate method that undo does not call.
        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertEqual(try hidden(view), ["- [ ] **", "**"], "the marker and the bold mark touch")
    }

    /// Each action is one undo step of its own, not merged with the typing before or after it. A text view keeps one undo
    /// step open across keystrokes that follow each other, so this uses an action that writes right at the caret, as a
    /// keystroke would.
    func testAnActionIsOneUndoStep() async throws {
        let view = try await editor("word\n")
        try await caret(view, at: "word", offset: 4)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        // What the event loop does after each real event: a test's run loop doesn't.
        func endOfEvent() { _ = (UndoManager.self as AnyObject).perform(NSSelectorFromString("_endTopLevelGroupings")) }
        view.insertText("s", replacementRange: view.selectedRange())
        endOfEvent()
        view.insertText("s", replacementRange: view.selectedRange())
        endOfEvent()
        view.coordinator?.perform(.link, in: view)
        endOfEvent()
        view.insertText("t", replacementRange: view.selectedRange())
        endOfEvent()
        assertBytes(view, "wordss[[t]]\n")
        undo.undo()
        assertBytes(view, "wordss[[]]\n", "the typing after it")
        undo.undo()
        assertBytes(view, "wordss\n", "the action alone")
        undo.undo()
        assertBytes(view, "word\n", "the typing before it")
    }

    /// An action's caret is where the action says: between the brackets of a link, not after what it wrote.
    func testAnActionLeavesTheSelectionWhereItSays() async throws {
        let view = try await editor("see  there\n")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.coordinator?.perform(.link, in: view)
        try await settle()
        assertBytes(view, "see [[]] there\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
    }

    // MARK: copy

    /// Copy gives the Markdown source, as plain text. Hidden marks are in it, and no look at all.
    func testCopyGivesTheMarkdownSource() async throws {
        let view = try await editor("# Title\nA **bold** [[link]] line\n- [x] done\n")
        XCTAssertFalse(view.isRichText)
        view.selectAll(nil)
        try await settle()
        XCTAssertEqual(view.writablePasteboardTypes, [NSPasteboard.PasteboardType("NSStringPboardType")], "plain text and nothing else")
        let board = NSPasteboard(name: NSPasteboard.Name("bn-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string).map { Array($0.utf8) }, Array("# Title\nA **bold** [[link]] line\n- [x] done\n".utf8))

        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertFalse(try hidden(view).isEmpty, "the same with marks hidden")
        view.setSelectedRange(NSRange(location: 0, length: 7))
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "# Title")
    }

    // MARK: the checkbox

    /// The middle of the drawn checkbox of the paragraph holding `needle`, in the view's coordinates.
    private func checkboxCenter(_ view: EditorTextView, of needle: String, rightToLeft: Bool = false) throws -> NSPoint {
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: range(of: needle, in: view).location))
        manager.ensureLayout(for: content.documentRange)
        let fragment = try XCTUnwrap(manager.textLayoutFragment(for: location) as? MarkdownLayoutFragment)
        let slot = fragment.markerSlot(lead: 0, rightToLeft: rightToLeft).offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        return NSPoint(x: slot.midX + view.textContainerOrigin.x, y: slot.midY + view.textContainerOrigin.y)
    }

    /// Only on a checkbox: anywhere else `mouseDown` starts AppKit's own tracking loop, which waits for a real mouse.
    private func click(_ view: EditorTextView, at point: NSPoint, file: StaticString = #filePath, line: UInt = #line) throws {
        guard view.taskParagraph(at: point) != nil else {
            return XCTFail("no checkbox at \(point)", file: file, line: line)
        }
        view.mouseDown(with: try mouse(.leftMouseDown, view, at: point))
        view.mouseUp(with: try mouse(.leftMouseUp, view, at: point))
    }

    private func mouse(_ type: NSEvent.EventType, _ view: NSView, at point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    /// Anything but a plain click goes to the text view, whose tracking waits for a release: this one is queued first.
    private func pressThatIsNoClick(_ view: EditorTextView, at point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws {
        NSApp.postEvent(try mouse(.leftMouseUp, view, at: point, flags: flags, clicks: clicks), atStart: false)
        view.mouseDown(with: try mouse(.leftMouseDown, view, at: point, flags: flags, clicks: clicks))
    }

    func testClickingACheckboxChangesOneByteAndNotTheCaret() async throws {
        let text = "intro\n- [ ] open\n- [x] done\nend\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        try await settle()
        try click(view, at: try checkboxCenter(view, of: "open"))
        try await settle()
        assertBytes(view, "intro\n- [x] open\n- [x] done\nend\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0), "the caret stays")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(Array(view.string.utf8).count, Array(text.utf8).count, "same length: nothing else in the file moves")

        try click(view, at: try checkboxCenter(view, of: "done"))
        try await settle()
        assertBytes(view, "intro\n- [x] open\n- [ ] done\nend\n")

        try click(view, at: try checkboxCenter(view, of: "open"))
        try await settle()
        assertBytes(view, "intro\n- [ ] open\n- [ ] done\nend\n")
        XCTAssertEqual(try storage(view).attribute(.bnLineDecoration, at: range(of: "open", in: view).location, effectiveRange: nil) as? LineDecoration,
                       LineDecoration(kind: .checkbox(done: false), rightToLeft: false, lead: 0), "and it looks ticked or not at once")
    }

    /// Starting a selection in the margin, shift-clicking and double-clicking change no byte.
    func testOnlyAPlainClickTicks() async throws {
        let text = "intro\n- [ ] open\nend\n"
        let view = try await editor(text)
        let center = try checkboxCenter(view, of: "open")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        try await settle()

        try pressThatIsNoClick(view, at: center, flags: .shift)
        try await settle()
        assertBytes(view, text, "shift-click")
        XCTAssertGreaterThan(view.selectedRange().length, 0, "a shift-click extends the selection, as anywhere")

        view.setSelectedRange(NSRange(location: 2, length: 0))
        try await settle()
        try pressThatIsNoClick(view, at: center, flags: .command)
        try await settle()
        assertBytes(view, text, "command-click")

        try pressThatIsNoClick(view, at: center, clicks: 2)
        try await settle()
        assertBytes(view, text, "the second click of a double click")

        // A press that turns into a drag starts a selection, and ticks nothing.
        view.setSelectedRange(NSRange(location: 2, length: 0))
        try await settle()
        view.mouseDown(with: try mouse(.leftMouseDown, view, at: center))
        assertBytes(view, text, "nothing yet on the press")
        NSApp.postEvent(try mouse(.leftMouseUp, view, at: center), atStart: false)
        view.mouseDragged(with: try mouse(.leftMouseDragged, view, at: NSPoint(x: center.x + 40, y: center.y)))
        try await settle()
        assertBytes(view, text, "a drag")

        // The click still works after all of that, once.
        try click(view, at: center)
        try await settle()
        assertBytes(view, "intro\n- [x] open\nend\n")
    }

    /// The margin left of a nested item is a margin, not its checkbox.
    func testTheCheckboxIsTheCheckboxNotTheWholeMargin() async throws {
        let view = try await editor("- [ ] a\n      - [ ] nested\n", focused: false)
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        let top = try checkboxCenter(view, of: "a")
        XCTAssertNotNil(view.taskParagraph(at: NSPoint(x: top.x - 13, y: top.y)), "a little outside the glyph still counts")
        XCTAssertNil(view.taskParagraph(at: NSPoint(x: top.x + 60, y: top.y)), "the text doesn't")
        let nestedY = try checkboxCenter(view, of: "nested").y
        // Level 3: its slot starts 60 points in.
        XCTAssertNil(view.taskParagraph(at: NSPoint(x: top.x, y: nestedY)), "under the top level's box is this line's margin")
        XCTAssertNotNil(view.taskParagraph(at: NSPoint(x: top.x + 60, y: nestedY)), "and its own box is further in")
    }

    func testAHebrewCheckboxIsOnTheRightAndTicks() async throws {
        let text = "פתיח\n- [ ] משימה\n"
        let view = try await editor(text)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        try await settle()
        let center = try checkboxCenter(view, of: "משימה", rightToLeft: true)
        XCTAssertGreaterThan(center.x, view.bounds.midX, "on the right side")
        XCTAssertNil(view.taskParagraph(at: NSPoint(x: view.bounds.width - center.x, y: center.y)), "the left side is just text")
        try click(view, at: center)
        try await settle()
        assertBytes(view, "פתיח\n- [x] משימה\n")
    }

    /// A tap is on the checkbox only if the glyph is really there: this looks at the pixels.
    func testTheGlyphIsDrawnWhereATapFindsIt() async throws {
        let view = try await editor("first\n- [x] Latin done\n- [x] משימה\n", focused: false)
        let rep = try bitmap()
        let scale = CGFloat(rep.pixelsWide) / view.window!.contentView!.bounds.width
        func isAccent(_ point: NSPoint) -> Bool {
            let content = window.contentView!
            let inContent = view.convert(point, to: content)
            let fromTop = content.isFlipped ? inContent.y : content.bounds.height - inContent.y
            guard let color = rep.colorAt(x: Int(inContent.x * scale), y: Int(fromTop * scale))?.usingColorSpace(.deviceRGB) else { return false }
            return color.blueComponent > color.redComponent + 0.15
        }
        func someAccent(around center: NSPoint) -> Bool {
            for dx in stride(from: -8.0, through: 8.0, by: 2.0) {
                for dy in stride(from: -5.0, through: 5.0, by: 2.0) where isAccent(NSPoint(x: center.x + dx, y: center.y + dy)) { return true }
            }
            return false
        }
        XCTAssertTrue(someAccent(around: try checkboxCenter(view, of: "Latin")), "the ticked circle, on the left")
        let hebrew = try checkboxCenter(view, of: "משימה", rightToLeft: true)
        XCTAssertTrue(someAccent(around: hebrew), "the ticked circle, on the right")
        XCTAssertFalse(someAccent(around: NSPoint(x: view.bounds.width - hebrew.x, y: hebrew.y)), "and not on the other side")
    }

    func testATapOnTheTextOrAnotherLineIsNoTick() async throws {
        let view = try await editor("- [ ] open task\nplain line\n- bullet\n```\n- [ ] in code\n```\n", focused: false)
        let center = try checkboxCenter(view, of: "open")
        XCTAssertNotNil(view.taskParagraph(at: center))
        XCTAssertNil(view.taskParagraph(at: NSPoint(x: center.x + 60, y: center.y)), "the task's own text")
        XCTAssertNil(view.taskParagraph(at: try checkboxCenter(view, of: "plain")))
        XCTAssertNil(view.taskParagraph(at: try checkboxCenter(view, of: "bullet")))
        XCTAssertNil(view.taskParagraph(at: try checkboxCenter(view, of: "in code")), "in a code block it is only text")
    }

    /// With the marks showing on the caret's line, the box is still where the marks are.
    func testTheCheckboxWorksOnTheCaretLineToo() async throws {
        let view = try await editor("- [ ] open\nend\n")
        try await caret(view, at: "open", offset: 2)
        XCTAssertEqual(try hidden(view), [])
        let center = try checkboxCenter(view, of: "open")
        try click(view, at: center)
        try await settle()
        assertBytes(view, "- [x] open\nend\n")
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).range(of: "open").location + 2)
    }

    // MARK: fences

    func testCodeIsOneBlockAndEditingAFenceMovesIt() async throws {
        let text = "before **b**\n```\n**code** line\n```\nafter **a**\n"
        let view = try await editor(text, focused: false)
        XCTAssertTrue(try font(view, at: "code").isFixedPitch)
        XCTAssertFalse(try hidden(view).contains("**code**"), "marks in code aren't marks")
        XCTAssertEqual(try hidden(view), ["**", "**", "```", "```", "**", "**"])
        window.makeFirstResponder(view)

        // Delete the closing fence: the code now runs to the end of the note.
        let closing = (view.string as NSString).range(of: "```\nafter")
        view.insertText("", replacementRange: NSRange(location: closing.location, length: 4))
        try await settle()
        assertBytes(view, "before **b**\n```\n**code** line\nafter **a**\n")
        XCTAssertTrue(try font(view, at: "after").isFixedPitch, "all the way down")
        XCTAssertNil(try storage(view).attribute(.bnHiddenMark, at: range(of: "after", in: view).location + 6, effectiveRange: nil))

        // And type it back: what follows is Markdown again.
        view.insertText("```\n", replacementRange: NSRange(location: range(of: "after", in: view).location, length: 0))
        try await settle()
        XCTAssertFalse(try font(view, at: "after").isFixedPitch)
        assertBytes(view, text)
    }

    func testCodeReadsLeftToRightInAHebrewNote() async throws {
        let view = try await editor("שלום\n```\nשורה בקוד\n```\n", focused: false)
        let style = try XCTUnwrap(try storage(view).attribute(.paragraphStyle, at: range(of: "שורה", in: view).location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.baseWritingDirection, .leftToRight)
    }

    // MARK: direction

    func testDirectionComesFromTheTextNotTheHiddenMarks() async throws {
        let view = try await editor("- [x] משימה\n# כותרת\n**מודגש** ועוד\n- [ ] Task\n", focused: false)
        func direction(_ needle: String) throws -> NSWritingDirection {
            try XCTUnwrap(try storage(view).attribute(.paragraphStyle, at: range(of: needle, in: view).location, effectiveRange: nil) as? NSParagraphStyle).baseWritingDirection
        }
        XCTAssertEqual(try direction("משימה"), .rightToLeft)
        XCTAssertEqual(try direction("כותרת"), .rightToLeft)
        XCTAssertEqual(try direction("מודגש"), .rightToLeft)
        XCTAssertEqual(try direction("Task"), .leftToRight)
    }

    /// Keep the direction mark placement: after the `# ` or `- [ ] `, where the line stays a heading or a task.
    func testTheDirectionActionKeepsTheMarkBehindTheMarker() async throws {
        let view = try await editor("# Title\n- [ ] Task\n")
        try await caret(view, at: "Title")
        view.coordinator?.perform(.direction, in: view)
        try await settle()
        assertBytes(view, "# \u{200F}Title\n- [ ] Task\n")
        try await caret(view, at: "Task")
        view.coordinator?.perform(.direction, in: view)
        try await settle()
        assertBytes(view, "# \u{200F}Title\n- [ ] \u{200F}Task\n")
        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertEqual(try hidden(view), ["# ", "- [ ] "], "both are still what they were")
    }

    // MARK: line endings

    func testACRLFNoteStaysCRLF() async throws {
        let text = "one **b**\r\ntwo\r\n"
        let view = try await editor(text)
        assertBytes(view, text)
        try await caret(view, at: "two", offset: 3)
        view.insertText("!", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "one **b**\r\ntwo!\r\n")
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "one **b**\r\ntwo!\r\n\r\n")
        XCTAssertEqual(view.selectedRange().location, ("one **b**\r\ntwo!\r\n" as NSString).length, "after the whole ending")
    }

    func testAnLFNoteStaysLF() async throws {
        let view = try await editor("one\ntwo")
        try await caret(view, at: "two", offset: 3)
        view.insertText("\n", replacementRange: view.selectedRange())
        try await settle()
        assertBytes(view, "one\ntwo\n")
    }

    // MARK: VoiceOver

    /// With VoiceOver on, nothing is hidden: what it reads and where the caret stops are what is on screen.
    func testVoiceOverGetsEveryMarkOnScreen() async throws {
        let text = "# T\n**a** b\n- [ ] c\n"
        let view = try await editor(text, focused: false)
        XCTAssertFalse(try hidden(view).isEmpty)
        let preview = try XCTUnwrap(view.coordinator?.preview)
        preview.setHidesMarks(false)
        XCTAssertEqual(try hidden(view), [])
        XCTAssertNil(try storage(view).attribute(.bnLineDecoration, at: range(of: "c", in: view).location, effectiveRange: nil), "no drawn checkbox: the source says it")
        assertBytes(view, text)
        window.makeFirstResponder(view)
        try await caret(view, at: "a")
        XCTAssertEqual(try hidden(view), [], "and moving the caret changes nothing")
        preview.setHidesMarks(true)
        XCTAssertFalse(try hidden(view).isEmpty)
    }

    /// With nothing hidden there is no caret line to restyle, so a line ending must see to both halves itself. Pasted, since
    /// Return keeps a pair whole.
    func testALineEndingRestylesBothHalvesWithVoiceOverOn() async throws {
        let view = try await editor("*slanted text* end\n")
        view.coordinator?.preview?.setHidesMarks(false)
        XCTAssertTrue(try font(view, at: "text").fontDescriptor.symbolicTraits.contains(.italic))
        view.setSelectedRange(NSRange(location: range(of: "text", in: view).location, length: 0))
        view.insertText("x\n", replacementRange: view.selectedRange())
        try await settle()
        XCTAssertFalse(try font(view, at: "slanted").fontDescriptor.symbolicTraits.contains(.italic), "the marks no longer pair, on either line")
        XCTAssertFalse(try font(view, at: "text").fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testVoiceOverCanTickATaskFromTheLine() async throws {
        let view = try await editor("- [ ] c\nd\n")
        try await caret(view, at: "c")
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Tick or Untick This Task"])
        XCTAssertEqual(actions[0].handler?(), true)
        try await settle()
        assertBytes(view, "- [x] c\nd\n")
        try await caret(view, at: "d")
        XCTAssertEqual(actions[0].handler?(), false, "not a task")
        assertBytes(view, "- [x] c\nd\n")
    }

    func testATaskInACodeBlockIsOnlyText() async throws {
        let text = "```\n- [ ] c\n```\n"
        let view = try await editor(text)
        try await caret(view, at: "c")
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        XCTAssertEqual(actions[0].handler?(), false)
        assertBytes(view, text)
    }

    /// Writing Tools in place would rewrite the text while the autosave and the styling carry on.
    func testWritingToolsStayInTheirPanel() async throws {
        let view = try await editor("text\n")
        XCTAssertEqual(view.writingToolsBehavior, .limited)
    }

    // MARK: the machinery stays TextKit 2

    func testTheEditorStaysOnTextKit2() async throws {
        let view = try await editor(Self.sample)
        XCTAssertNotNil(view.textLayoutManager)
        view.coordinator?.perform(.checklist, in: view)
        try await settle()
        XCTAssertNotNil(view.textLayoutManager, "nothing in the slice fell back to TextKit 1")
        let manager = try XCTUnwrap(view.textLayoutManager)
        XCTAssertTrue(manager.delegate is MarkdownFragmentProvider)
        var plainFragments = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            if !(fragment is MarkdownLayoutFragment) { plainFragments += 1 }
            return true
        }
        XCTAssertEqual(plainFragments, 0)
    }

    // MARK: speed

    /// A keystroke or a caret move: at most two paragraphs styled, whatever the note's size.
    func testAKeystrokeAndACaretMoveStayWithinTheBudget() async throws {
        let note = StyleTiming.syntheticNote()
        let view = try await editor(note, size: NSSize(width: 460, height: 400))
        let preview = try XCTUnwrap(view.coordinator?.preview)
        let length = (view.string as NSString).length
        let clock = ContinuousClock()
        var moves: [Double] = []
        for i in 0..<200 {
            let at = NSRange(location: length * i / 200, length: 0)
            let time = clock.measure { preview.update(selection: at, focused: true) }
            moves.append(Double(time.components.attoseconds) / 1e15 + Double(time.components.seconds) * 1000)
        }
        moves.sort()
        let median = moves[moves.count / 2]
        let line = "caret move on a 271 KB note: median \(median) ms, worst \(moves.last ?? 0) ms\n"
        try? line.write(to: Self.shots.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("editor-caret-timing.txt"), atomically: true, encoding: .utf8)
        XCTAssertLessThan(median, 2, line)
    }
}
