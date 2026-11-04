import Foundation
import Testing
@testable import BrainNotesKit

/// Golden tests in one notation: `‸` marks the caret, or both ends of a selection. Text is compared as bytes,
/// since Swift's `==` calls canonically equivalent strings equal.
@Suite struct MarkdownEditsTests {
    typealias Action = @Sendable (String, NSRange) -> MarkdownEdits.Edit
    static let task: Action = { MarkdownEdits.toggleTask(in: $0, selection: $1) }
    static let bold: Action = { MarkdownEdits.toggleWrap("**", in: $0, selection: $1) }
    static let direction: Action = { MarkdownEdits.toggleDirection(in: $0, selection: $1) }

    private let rlm = "\u{200F}"
    private let lrm = "\u{200E}"

    private func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let parts = marked.components(separatedBy: "‸")
        precondition(parts.count == 2 || parts.count == 3, "one caret or two selection ends: \(marked)")
        let start = (parts[0] as NSString).length
        let length = parts.count == 3 ? (parts[1] as NSString).length : 0
        return (parts.joined(), NSRange(location: start, length: length))
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// One press gives exactly `after`.
    private func expectOnce(_ action: Action, _ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let start = parse(before)
        let goal = parse(after)
        let edit = action(start.text, start.selection)
        #expect(bytes(edit.applied(to: start.text)) == bytes(goal.text), "\(before) gave \(edit.applied(to: start.text))", sourceLocation: sourceLocation)
        #expect(edit.selection == goal.selection, "\(before): selection", sourceLocation: sourceLocation)
    }

    /// One press gives exactly `after`, and a second gives `before` back: bytes and selection.
    private func expectToggle(_ action: Action, _ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectOnce(action, before, after, sourceLocation: sourceLocation)
        expectOnce(action, after, before, sourceLocation: sourceLocation)
    }

    // MARK: checklist

    @Test func checklistInEnglishAndHebrew() {
        expectToggle(Self.task, "Buy‸ milk", "- [ ] Buy‸ milk")
        expectToggle(Self.task, "לקנות‸ חלב", "- [ ] לקנות‸ חלב")
        expectToggle(Self.task, "‸Buy milk", "- [ ] ‸Buy milk")
        expectToggle(Self.task, "‸לקנות חלב‸", "- [ ] ‸לקנות חלב‸")
    }

    @Test func checklistTouchesOnlyItsParagraph() {
        expectToggle(Self.task, "one\ntw‸o\nthree\n", "one\n- [ ] tw‸o\nthree\n")
        expectToggle(Self.task, "אחת\nשת‸יים\nשלוש\n", "אחת\n- [ ] שת‸יים\nשלוש\n")
        expectToggle(Self.task, "first\n‸", "first\n- [ ] ‸")
        expectToggle(Self.task, "‸", "- [ ] ‸")
        expectToggle(Self.task, "one\r\ntw‸o\r\nthree\r\n", "one\r\n- [ ] tw‸o\r\nthree\r\n")
    }

    @Test func checklistCountsOffsetsInUTF16() {
        expectToggle(Self.task, "🙂 ab‸c", "- [ ] 🙂 ab‸c")
        expectToggle(Self.task, "שָׁלוֹ‸ם", "- [ ] שָׁלוֹ‸ם")
    }

    @Test func checklistKeepsIndentHeadingAndDirectionMark() {
        expectToggle(Self.task, "  nes‸ted", "  - [ ] nes‸ted")
        expectToggle(Self.task, "# Ti‸tle", "- [ ] # Ti‸tle")
        expectToggle(Self.task, "12. i‸tem", "- [ ] 12. i‸tem")
        expectToggle(Self.task, "\(rlm)של‸ום", "- [ ] \(rlm)של‸ום")
    }

    /// The two cases that can't be the identity: a tick and a bullet are gone once removed.
    @Test func checklistOnATickOrABullet() {
        expectOnce(Self.task, "- [x] do‸ne", "do‸ne")
        expectOnce(Self.task, "- [X] do‸ne", "do‸ne")
        expectOnce(Self.task, "* [ ] o‸pen", "o‸pen")
        expectOnce(Self.task, "- [x] בו‸צע", "בו‸צע")
        expectOnce(Self.task, "- bul‸let", "- [ ] bul‸let")
        expectOnce(Self.task, "- ‸bullet", "- [ ] ‸bullet")
        expectOnce(Self.task, "* כדו‸ר", "- [ ] כדו‸ר")
        expectOnce(Self.task, "- [‸ ] open", "‸open")
        expectOnce(Self.task, "\(rlm)- [ ] x‸y", "\(rlm)x‸y")
    }

    // MARK: bold

    @Test func boldWrapsAndUnwrapsASelection() {
        expectToggle(Self.bold, "a ‸bold‸ word", "a **‸bold‸** word")
        expectToggle(Self.bold, "מילה ‸מודגשת‸ כאן", "מילה **‸מודגשת‸** כאן")
        expectToggle(Self.bold, "‸one\ntwo‸", "**‸one\ntwo‸**")
        expectToggle(Self.bold, "🙂 ‸ab‸", "🙂 **‸ab‸**")
        expectToggle(Self.bold, "שורה ‸mixed עברית‸ כאן", "שורה **‸mixed עברית‸** כאן")
    }

    @Test func boldUnwrapsWhenTheMarksAreSelectedToo() {
        expectOnce(Self.bold, "a ‸**bold**‸ word", "a ‸bold‸ word")
        expectOnce(Self.bold, "‸**מודגש**‸", "‸מודגש‸")
        expectOnce(Self.bold, "‸**a** and **b**‸", "**‸**a** and **b**‸**")
    }

    /// A triple tap selects the line ending, and `**word\n**` would not be bold.
    @Test func boldKeepsWhiteSpaceOutsideTheMarks() {
        expectOnce(Self.bold, "‸one line\n‸two\n", "**‸one line‸**\ntwo\n")
        expectOnce(Self.bold, "**‸one line‸**\ntwo\n", "‸one line‸\ntwo\n")
        expectOnce(Self.bold, "‸שורה אחת\r\n‸שתיים\r\n", "**‸שורה אחת‸**\r\nשתיים\r\n")
        expectOnce(Self.bold, "a‸ word ‸b", "a **‸word‸** b")
        expectOnce(Self.bold, "one ‸ ‸two", "one **‸** two")
    }

    @Test func boldOnACaret() {
        expectToggle(Self.bold, "a bo‸ld word", "a **bo‸ld** word")
        expectToggle(Self.bold, "מי‸לה", "**מי‸לה**")
        expectToggle(Self.bold, "word‸", "**word‸**")
        expectToggle(Self.bold, "ג'ינ‸ס", "**ג'ינ‸ס**")
        expectToggle(Self.bold, "‸", "**‸**")
        expectToggle(Self.bold, "one ‸ two", "one **‸** two")
        expectToggle(Self.bold, "line\n‸", "line\n**‸**")
    }

    @Test func boldOnACaretFindsItsOwnSpan() {
        expectToggle(Self.bold, "**a** b c‸d", "**a** b **c‸d**")
        expectToggle(Self.bold, "**a** b‸ **c**", "**a** **b‸** **c**")
        expectOnce(Self.bold, "**abc**‸ tail", "abc‸ tail")
        expectOnce(Self.bold, "‸**abc** tail", "‸abc tail")
        expectOnce(Self.bold, "*‸*abc** tail", "‸abc tail")
        expectOnce(Self.bold, "**abc*‸* tail", "abc‸ tail")
        // Marks on the next line are not this line's.
        expectOnce(Self.bold, "**a\nb‸ **c** d", "**a\n**b‸** **c** d")
    }

    // MARK: direction

    @Test func directionInEnglishAndHebrew() {
        expectToggle(Self.direction, "Hel‸lo", "\(rlm)Hel‸lo")
        expectToggle(Self.direction, "של‸ום", "\(lrm)של‸ום")
        expectToggle(Self.direction, "‸Hello", "\(rlm)‸Hello")
        expectToggle(Self.direction, "‸שלום‸", "\(lrm)‸שלום‸")
        expectToggle(Self.direction, "2026 של‸ום", "\(lrm)2026 של‸ום")
        expectToggle(Self.direction, "Hello של‸ום", "\(rlm)Hello של‸ום")
    }

    @Test func directionTouchesOnlyItsParagraph() {
        expectToggle(Self.direction, "one\ntw‸o\nthree\n", "one\n\(rlm)tw‸o\nthree\n")
        expectToggle(Self.direction, "אחת\nשת‸יים\nשלוש\n", "אחת\n\(lrm)שת‸יים\nשלוש\n")
        expectToggle(Self.direction, "a\r\nb‸c\r\n", "a\r\n\(rlm)b‸c\r\n")
        expectToggle(Self.direction, "first\n‸", "first\n\(rlm)‸")
        expectToggle(Self.direction, "‸", "\(rlm)‸")
    }

    /// In front of a block marker, the mark would turn a heading or a list item into plain text.
    @Test func directionGoesAfterTheBlockMarker() {
        expectToggle(Self.direction, "# Ti‸tle", "# \(rlm)Ti‸tle")
        expectToggle(Self.direction, "### כות‸רת", "### \(lrm)כות‸רת")
        expectToggle(Self.direction, "- [ ] ab‸c", "- [ ] \(rlm)ab‸c")
        expectToggle(Self.direction, "- [x] של‸ום", "- [x] \(lrm)של‸ום")
        expectToggle(Self.direction, "- ab‸c", "- \(rlm)ab‸c")
        expectToggle(Self.direction, "12. ab‸c", "12. \(rlm)ab‸c")
        expectToggle(Self.direction, "> ab‸c", "> \(rlm)ab‸c")
        expectToggle(Self.direction, "  - ab‸c", "  - \(rlm)ab‸c")
        expectToggle(Self.direction, "‸# Title", "‸# \(rlm)Title")
        expectToggle(Self.direction, "- [ ] ‸", "- [ ] \(rlm)‸")
        // Not block markers.
        expectToggle(Self.direction, "#ta‸g", "\(rlm)#ta‸g")
        expectToggle(Self.direction, "1.5 li‸tres", "\(rlm)1.5 li‸tres")
        expectToggle(Self.direction, "**bo‸ld**", "\(rlm)**bo‸ld**")
    }

    @Test func aMarkThatSaysWhatItsTextSaysFlipsThenComesOff() {
        expectOnce(Self.direction, "\(rlm)של‸ום", "\(lrm)של‸ום")
        expectOnce(Self.direction, "\(lrm)של‸ום", "של‸ום")
        expectOnce(Self.direction, "\(lrm)Hel‸lo", "\(rlm)Hel‸lo")
        expectOnce(Self.direction, "\(lrm)# של‸ום", "# של‸ום")
    }

    /// The bytes that reach the file, written out.
    @Test func directionMarksAreTheseBytes() {
        let edit = MarkdownEdits.toggleDirection(in: "Hi", selection: NSRange(location: 0, length: 0))
        #expect(bytes(edit.applied(to: "Hi")) == [0xE2, 0x80, 0x8F, 0x48, 0x69])
        let hebrew = MarkdownEdits.toggleDirection(in: "ש", selection: NSRange(location: 1, length: 0))
        #expect(bytes(hebrew.applied(to: "ש")) == [0xE2, 0x80, 0x8E, 0xD7, 0xA9])
    }

    // MARK: what a paragraph's direction is

    @Test func theFirstStrongCharacterIncludesTheMarks() {
        #expect(NoteText.isRightToLeft("\u{200F}hello"))
        #expect(!NoteText.isRightToLeft("\u{200E}שלום"))
        #expect(NoteText.isRightToLeft("123 \u{200F}hello"))
        #expect(!NoteText.isRightToLeft("hello \u{200F}"))
    }

    @Test func aParagraphsDirectionSkipsItsBlockMarker() {
        #expect(MarkdownEdits.isRightToLeft(paragraph: "- [x] שלום"), "the x is not the first letter")
        #expect(MarkdownEdits.isRightToLeft(paragraph: "* [X] שלום"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "- [ ] שלום"))
        #expect(!MarkdownEdits.isRightToLeft(paragraph: "- [x] hello"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "# שלום"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "12. שלום"))
        #expect(!MarkdownEdits.isRightToLeft(paragraph: "hello שלום"))
        #expect(!MarkdownEdits.isRightToLeft(paragraph: ""))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "\u{200F}"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "\u{200F}hello"))
        #expect(!MarkdownEdits.isRightToLeft(paragraph: "\u{200E}שלום"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "- [ ] \u{200F}hello"))
        #expect(!MarkdownEdits.isRightToLeft(paragraph: "# \u{200E}שלום"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "\u{200F}- [x] hello"))
    }

    /// Why the mark goes after the block marker: the note view still sees a heading and a task, each with the
    /// direction the mark asks for, and a file name made from the first line has no invisible character in it.
    @Test func theNoteViewAndFileNamesReadTheMarkedLines() {
        let blocks = MarkdownBlock.parse("# \u{200F}Title\n- [ ] \u{200F}Task\n\u{200E}שלום\n")
        #expect(blocks.map(\.kind) == [.heading(1), .task(done: false, indent: 0), .paragraph])
        #expect(blocks.map(\.isRightToLeft) == [true, true, false])
        #expect(PathPolicy.fileName(fromFirstLine: "# \u{200F}Title") == "Title")
        #expect(PathPolicy.fileName(fromFirstLine: "\u{200F}שלום") == "שלום")
    }

    // MARK: anything

    /// Random paragraphs in both scripts, with every line ending, at every position. Plain text is toggled by
    /// every action twice; marks already in the text may not come back as they were, but no byte outside the
    /// paragraph ever changes.
    @Test func noEditEverLeavesItsParagraph() {
        var generator = SeededGenerator(seed: 271)
        let pieces = ["word", "מילה", " ", "  ", "🙂", "שָׁלוֹם", "**", "- [ ] ", "- [x] ", "# ", "\u{200F}", "\u{200E}", "1. ", "x", "."]
        let endings = ["\n", "\r\n", "\n\n"]
        for _ in 0..<400 {
            var paragraphs: [String] = []
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                var line = ""
                for _ in 0..<Int.random(in: 0...6, using: &generator) { line += pieces.randomElement(using: &generator)! }
                paragraphs.append(line)
            }
            let ending = endings.randomElement(using: &generator)!
            let text = paragraphs.joined(separator: ending)
            let ns = text as NSString
            // Selections only fall between whole characters, as the text views' do.
            var offsets = [0]
            for index in text.indices.dropFirst() { offsets.append(text.utf16.distance(from: text.startIndex, to: index)) }
            offsets.append(ns.length)
            let a = offsets.randomElement(using: &generator)!
            let b = Bool.random(using: &generator) ? a : offsets.randomElement(using: &generator)!
            let selection = NSRange(location: min(a, b), length: abs(a - b))

            for action in [Self.task, Self.direction] {
                let edit = action(text, selection)
                let after = edit.applied(to: text) as NSString
                #expect(NSMaxRange(edit.selection) <= after.length, "\(text.debugDescription) \(selection)")
                let touched = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))
                #expect(edit.range.location >= touched.location && NSMaxRange(edit.range) <= NSMaxRange(touched), "\(text.debugDescription) \(selection)")
                #expect(bytes(ns.substring(to: touched.location)) == bytes(after.substring(to: touched.location)))
                let tail = ns.length - NSMaxRange(touched)
                #expect(bytes(ns.substring(from: NSMaxRange(touched))) == bytes(after.substring(from: after.length - tail)))
            }
            let wrapped = Self.bold(text, selection)
            #expect(NSMaxRange(wrapped.selection) <= (wrapped.applied(to: text) as NSString).length, "\(text.debugDescription) \(selection)")

            // The same text with no marks in it comes back whole from two presses of anything.
            let plain = String(text.unicodeScalars.filter { !["*", "-", "#", "[", "]", "1", "x", "\u{200F}", "\u{200E}"].contains($0) }.map(Character.init))
            let caret = NSRange(location: min(selection.location, (plain as NSString).length), length: 0)
            let safe = isBetweenCharacters(caret.location, in: plain) ? caret : NSRange(location: 0, length: 0)
            for action in [Self.task, Self.bold, Self.direction] {
                let once = action(plain, safe)
                let middle = once.applied(to: plain)
                let twice = action(middle, once.selection)
                #expect(bytes(twice.applied(to: middle)) == bytes(plain), "\(plain.debugDescription) \(safe)")
            }
        }
    }

    private func isBetweenCharacters(_ offset: Int, in text: String) -> Bool {
        let index = String.Index(utf16Offset: offset, in: text)
        return text.indices.contains(index) || index == text.endIndex
    }
}

/// A small fixed-seed generator: the same run every time, so a failure can be read and repeated.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
