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
    static let bullet: Action = { MarkdownEdits.toggleBullet(in: $0, selection: $1) }
    static let italic: Action = { MarkdownEdits.toggleWrap("*", in: $0, selection: $1) }
    static let code: Action = { MarkdownEdits.toggleWrap("`", in: $0, selection: $1) }
    static let link: Action = { MarkdownEdits.insertWikiLink(in: $0, selection: $1) }
    static let numbered: Action = { MarkdownEdits.toggleNumbered(in: $0, selection: $1) }
    static let indent: Action = { MarkdownEdits.indent(in: $0, selection: $1) }
    static let outdent: Action = { MarkdownEdits.outdent(in: $0, selection: $1) }
    static let body: Action = { MarkdownEdits.removeHeading(in: $0, selection: $1) }
    static func heading(_ level: Int) -> Action { { MarkdownEdits.toggleHeading(level, in: $0, selection: $1) } }

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

    /// One action gives exactly `after`, and the other gives `before` back: bytes and selection.
    private func expectToggleWith(_ action: Action, _ back: Action, _ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectOnce(action, before, after, sourceLocation: sourceLocation)
        expectOnce(back, after, before, sourceLocation: sourceLocation)
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

    // MARK: italic and code

    @Test func italicInEnglishAndHebrew() {
        expectToggle(Self.italic, "a ‸word‸ here", "a *‸word‸* here")
        expectToggle(Self.italic, "מילה ‸נטויה‸ כאן", "מילה *‸נטויה‸* כאן")
        expectToggle(Self.italic, "wo‸rd", "*wo‸rd*")
        expectToggle(Self.italic, "מי‸לה", "*מי‸לה*")
        expectToggle(Self.italic, "‸", "*‸*")
        expectOnce(Self.italic, "a ‸*word*‸ here", "a ‸word‸ here")
    }

    /// The reason a single `*` needs care: it must never take half of a `**`.
    @Test func italicDoesNotTakeHalfOfABold() {
        expectToggle(Self.italic, "**wo‸rd**", "***wo‸rd***")
        expectToggle(Self.italic, "**‸word‸**", "***‸word‸***")
        expectToggle(Self.italic, "**‸**", "***‸***")
        expectToggle(Self.bold, "*wo‸rd*", "***wo‸rd***")
        expectToggle(Self.bold, "*‸word‸*", "***‸word‸***")
        expectOnce(Self.italic, "‸**bold**‸", "*‸**bold**‸*")
        expectOnce(Self.bold, "***wo‸rd***", "*wo‸rd*")
        expectOnce(Self.italic, "***wo‸rd***", "**wo‸rd**")
    }

    @Test func codeInEnglishAndHebrew() {
        expectToggle(Self.code, "use ‸let‸ here", "use `‸let‸` here")
        expectToggle(Self.code, "קוד ‸מילה‸ כאן", "קוד `‸מילה‸` כאן")
        expectToggle(Self.code, "ab‸c", "`ab‸c`")
        expectToggle(Self.code, "‸", "`‸`")
    }

    /// Marks inside code are text: they pair with nothing, and a span of code takes marks around it, not inside it.
    @Test func codeSpansAreOneThing() {
        expectOnce(Self.bold, "`**a` b‸ **c**", "`**a` **b‸** **c**")
        expectOnce(Self.bold, "`**a**` wo‸rd", "`**a**` **wo‸rd**")
        expectToggle(Self.bold, "`co‸de`", "**`co‸de`**")
        expectToggle(Self.italic, "`co‸de`", "*`co‸de`*")
        expectOnce(Self.bold, "`a ‸b‸ c`", "**‸`a b c`‸**")
        expectOnce(Self.code, "`co‸de`", "co‸de")
        expectOnce(Self.code, "`‸code‸`", "‸code‸")
    }

    // MARK: bullets

    @Test func bulletInEnglishAndHebrew() {
        expectToggle(Self.bullet, "Buy‸ milk", "- Buy‸ milk")
        expectToggle(Self.bullet, "לקנות‸ חלב", "- לקנות‸ חלב")
        expectToggle(Self.bullet, "‸", "- ‸")
        expectToggle(Self.bullet, "one\ntw‸o\nthree\n", "one\n- tw‸o\nthree\n")
        expectToggle(Self.bullet, "a\r\nb‸c\r\n", "a\r\n- b‸c\r\n")
        expectToggle(Self.bullet, "  nes‸ted", "  - nes‸ted")
        expectToggle(Self.bullet, "\(rlm)של‸ום", "- \(rlm)של‸ום")
    }

    @Test func bulletAndTaskTurnIntoEachOther() {
        expectOnce(Self.bullet, "- [ ] ta‸sk", "- ta‸sk")
        expectOnce(Self.bullet, "- [x] בוצ‸ע", "- בוצ‸ע")
        expectOnce(Self.bullet, "* bul‸let", "bul‸let")
        expectOnce(Self.task, "- ta‸sk", "- [ ] ta‸sk")
    }

    /// With a number button on the bar, a number is one more kind of list: it makes way, as a bullet does.
    @Test func aNumberTurnsIntoABulletOrATask() {
        expectOnce(Self.task, "12. i‸tem", "- [ ] i‸tem")
        expectOnce(Self.bullet, "12. i‸tem", "- i‸tem")
        expectOnce(Self.bullet, "1. פרי‸ט", "- פרי‸ט")
        expectOnce(Self.bullet, "  1. nes‸ted", "  - nes‸ted")
        expectOnce(Self.task, "1. \(rlm)i‸tem", "- [ ] \(rlm)i‸tem")
        // The two others keep their numbers. Only the number actions put numbers right.
        expectOnce(Self.bullet, "1. a\n2. b‸\n3. c\n", "1. a\n- b‸\n3. c\n")
    }

    // MARK: headings

    @Test func headingsInEnglishAndHebrew() {
        expectToggle(Self.heading(1), "Ti‸tle", "# Ti‸tle")
        expectToggle(Self.heading(1), "כות‸רת", "# כות‸רת")
        expectToggle(Self.heading(2), "Head‸ing", "## Head‸ing")
        expectToggle(Self.heading(2), "כות‸רת", "## כות‸רת")
        expectToggle(Self.heading(3), "Sub‸heading", "### Sub‸heading")
        expectToggle(Self.heading(3), "כות‸רת", "### כות‸רת")
        expectToggle(Self.heading(1), "‸", "# ‸")
        expectToggle(Self.heading(2), "a\nb‸c\nd\n", "a\n## b‸c\nd\n")
        expectToggle(Self.heading(1), "a\r\nb‸c\r\n", "a\r\n# b‸c\r\n")
    }

    @Test func aHeadingChangesLevelAndListMarkersMakeWay() {
        expectOnce(Self.heading(1), "## Ti‸tle", "# Ti‸tle")
        expectOnce(Self.heading(3), "# כות‸רת", "### כות‸רת")
        expectOnce(Self.heading(1), "- [ ] ta‸sk", "# ta‸sk")
        expectOnce(Self.heading(1), "- [x] בוצ‸ע", "# בוצ‸ע")
        expectOnce(Self.heading(2), "- bul‸let", "## bul‸let")
        expectOnce(Self.heading(2), "12. i‸tem", "## i‸tem")
    }

    /// Keep the direction mark placement: after the marker, or the line stops being a heading.
    @Test func aHeadingKeepsTheDirectionMarkBehindIt() {
        expectToggle(Self.heading(1), "\(rlm)Ti‸tle", "# \(rlm)Ti‸tle")
        expectOnce(Self.heading(2), "# \(rlm)Ti‸tle", "## \(rlm)Ti‸tle")
        expectOnce(Self.direction, "## Ti‸tle", "## \(rlm)Ti‸tle")
        expectOnce(Self.heading(1), "- [ ] \(lrm)של‸ום", "# \(lrm)של‸ום")
    }

    @Test func bodyTakesOnlyAHeadingOff() {
        expectOnce(Self.body, "# Ti‸tle", "Ti‸tle")
        expectOnce(Self.body, "### כות‸רת", "כות‸רת")
        expectOnce(Self.body, "## \(rlm)Ti‸tle", "\(rlm)Ti‸tle")
        expectOnce(Self.body, "pl‸ain", "pl‸ain")
        expectOnce(Self.body, "- bul‸let", "- bul‸let")
        #expect(MarkdownEdits.removeHeading(in: "plain", selection: NSRange(location: 2, length: 0)).changesNothing)
    }

    /// A heading inside a task is changed where it is, and the task stays. Title on a task with no heading in it still
    /// replaces the marker, above.
    @Test func aHeadingInsideATaskChangesWhereItIs() {
        expectOnce(Self.heading(1), "- [ ] # Sh‸ana", "- [ ] Sh‸ana")
        expectOnce(Self.heading(2), "- [ ] # Sh‸ana", "- [ ] ## Sh‸ana")
        expectOnce(Self.heading(1), "- [x] ### ש‸נה", "- [x] # ש‸נה")
        expectOnce(Self.heading(3), "- ## Sh‸ana", "- ### Sh‸ana")
        expectOnce(Self.body, "- [ ] # Sh‸ana", "- [ ] Sh‸ana")
        expectOnce(Self.body, "- ## ש‸נה", "- ש‸נה")
        expectOnce(Self.body, "- [ ] # \(rlm)a‸b", "- [ ] \(rlm)a‸b")
        expectOnce(Self.heading(1), "‸# a\n- [ ] # b‸", "‸a\n- [ ] b‸")
        expectOnce(Self.heading(1), "‸## a\n- [ ] ## b‸", "‸# a\n- [ ] # b‸")
    }

    @Test func aTaskWithAHeadingInItIsStillATask() {
        expectToggle(Self.direction, "- [ ] # ab‸c", "- [ ] # \(rlm)ab‸c")
        expectOnce(Self.task, "- [ ] # Sh‸ana", "# Sh‸ana")
        expectOnce(Self.bullet, "- [ ] # Sh‸ana", "- # Sh‸ana")
        #expect(bytes(tick("- [ ] # a", at: 0) ?? "") == bytes("- [x] # a"))
    }

    /// A tap on Bold where bold is still open takes its one mark off, as it would take a pair.
    @Test func boldOnABoldStillOpen() {
        expectOnce(Self.bold, "- [ ] # **Sha‸na", "- [ ] # Sha‸na")
        expectOnce(Self.bold, "**Sha‸na", "Sha‸na")
        expectOnce(Self.bold, "**‸Shana‸", "‸Shana‸")
    }

    // MARK: numbered lists

    @Test func numberedInEnglishAndHebrew() {
        expectToggle(Self.numbered, "Buy‸ milk", "1. Buy‸ milk")
        expectToggle(Self.numbered, "לקנות‸ חלב", "1. לקנות‸ חלב")
        expectToggle(Self.numbered, "‸", "1. ‸")
        expectToggle(Self.numbered, "one\ntw‸o\nthree\n", "one\n1. tw‸o\nthree\n")
        expectToggle(Self.numbered, "a\r\nb‸c\r\n", "a\r\n1. b‸c\r\n")
        expectToggle(Self.numbered, "  nes‸ted", "  1. nes‸ted")
        expectToggle(Self.numbered, "\(rlm)של‸ום", "1. \(rlm)של‸ום")
        expectToggle(Self.numbered, "# Ti‸tle", "1. # Ti‸tle")
        expectToggle(Self.numbered, "🙂 ab‸c", "1. 🙂 ab‸c")
    }

    @Test func numberedNumbersEachLineInTurn() {
        expectOnce(Self.numbered, "‸one\ntwo\nthree‸\n", "1. ‸one\n2. two\n3. three‸\n")
        expectOnce(Self.numbered, "א‸חת\nשתיים\nשל‸וש\n", "1. א‸חת\n2. שתיים\n3. של‸וש\n")
        expectOnce(Self.numbered, "‸a\n\nb‸\n", "1. ‸a\n\n1. b‸\n")
        expectOnce(Self.numbered, "1. ‸a\n2. b‸\n", "‸a\nb‸\n")
        expectOnce(Self.numbered, "‸a\r\nb‸\r\n", "1. ‸a\r\n2. b‸\r\n")
    }

    @Test func aBulletOrATaskBecomesANumber() {
        expectOnce(Self.numbered, "- bul‸let", "1. bul‸let")
        expectOnce(Self.numbered, "- [ ] ta‸sk", "1. ta‸sk")
        expectOnce(Self.numbered, "- [x] בוצ‸ע", "1. בוצ‸ע")
        expectOnce(Self.numbered, "* ‸a\n- [ ] b‸\n", "1. ‸a\n2. b‸\n")
        expectOnce(Self.numbered, "1. ‸a\nb‸\n", "1. ‸a\n2. b‸\n")
    }

    /// A line turned into a number joins the list around it, and what follows goes on from it.
    @Test func numberedJoinsTheListAroundIt() {
        expectOnce(Self.numbered, "1. a\nb‸\n", "1. a\n2. b‸\n")
        expectOnce(Self.numbered, "5. a\n‸", "5. a\n6. ‸")
        expectOnce(Self.numbered, "a‸\n1. b\n2. c\n", "1. a‸\n2. b\n3. c\n")
        expectOnce(Self.numbered, "1. a\nb‸\n2. c\n", "1. a\n2. b‸\n3. c\n")
        expectOnce(Self.numbered, "a\n\nb‸\n", "a\n\n1. b‸\n")
    }

    /// A line leaving a list cuts it in two, and the part below starts again.
    @Test func leavingANumberedListStartsWhatFollowsAgain() {
        expectOnce(Self.numbered, "1. a\n2. b‸\n3. c\n4. d\n", "1. a\nb‸\n1. c\n2. d\n")
        expectOnce(Self.numbered, "1. a‸\n2. b\n", "a‸\n1. b\n")
        expectOnce(Self.numbered, "1. a\n2. b‸\n", "1. a\nb‸\n")
        // Nested, it stays inside the item above it, and the rest of that level starts again.
        expectOnce(Self.numbered, "1. a\n   1. x‸\n   2. y\n2. b\n", "1. a\n   x‸\n   1. y\n2. b\n")
    }

    // MARK: Return in a list

    @Test func returnContinuesAList() {
        expectReturn("- a‸", "- a\n- ‸")
        expectReturn("- ‸a", "- \n- ‸a")
        expectReturn("* a‸", "* a\n* ‸")
        expectReturn("+ a‸", "+ a\n+ ‸")
        expectReturn("- [ ] a‸", "- [ ] a\n- [ ] ‸")
        expectReturn("- [x] a‸", "- [x] a\n- [ ] ‸")
        expectReturn("* [X] a‸", "* [X] a\n* [ ] ‸")
        expectReturn("1. a‸", "1. a\n2. ‸")
        expectReturn("9. a‸", "9. a\n10. ‸")
        expectReturn("1) a‸", "1) a\n2) ‸")
        expectReturn("- מילה‸", "- מילה\n- ‸")
        expectReturn("1. פריט‸", "1. פריט\n2. ‸")
        expectReturn("- [ ] משימה‸", "- [ ] משימה\n- [ ] ‸")
        expectReturn("  - nested‸", "  - nested\n  - ‸")
        expectReturn("\t- nested‸", "\t- nested\n\t- ‸")
        expectReturn("   1. nested‸", "   1. nested\n   2. ‸")
        expectReturn("- a‸\n- b\n", "- a\n- ‸\n- b\n")
    }

    @Test func returnSplitsAnItemAtTheCaret() {
        expectReturn("- ab‸cd", "- ab\n- ‸cd")
        expectReturn("1. ab‸cd\n2. e\n", "1. ab\n2. ‸cd\n3. e\n")
        expectReturn("- [x] ab‸cd", "- [x] ab\n- [ ] ‸cd")
        expectReturn("- **ab‸cd** e", "- **ab**\n- **‸cd** e")
        expectReturn("- **abcd‸** e", "- **abcd**\n- ‸ e")
        expectReturn("- [[ab‸cd]] e", "- [[abcd]]\n- ‸ e")
        expectReturn("1. [[sisi‸]]", "1. [[sisi]]\n2. ‸")
        expectReturn("- [ ] [[‸]]", "- [ ] [[]]\n- [ ] ‸")
    }

    /// The new item carries a direction someone chose, behind its marker, where the direction action puts it.
    @Test func returnCarriesADirectionMark() {
        expectReturn("- [ ] \(rlm)ab‸", "- [ ] \(rlm)ab\n- [ ] \(rlm)‸")
        expectReturn("1. \(lrm)של‸ום", "1. \(lrm)של\n2. \(lrm)‸ום")
        expectReturn("- [ ] ‸\(rlm)ab", "- [ ] \(rlm)\n- [ ] \(rlm)‸ab")
    }

    /// A heading in an item ends with that item. The next one is ordinary text.
    @Test func returnAfterAHeadingInAnItem() {
        expectReturn("- [ ] # Shana‸", "- [ ] # Shana\n- [ ] ‸")
        expectReturn("- [ ] # **Shana**‸", "- [ ] # **Shana**\n- [ ] ‸")
        expectReturn("- [ ] # **Shana‸**", "- [ ] # **Shana**\n- [ ] ‸")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        expectReturn("- ‸", "‸")
        expectReturn("- [ ] ‸", "‸")
        expectReturn("- [x] ‸", "‸")
        expectReturn("1. ‸", "‸")
        expectReturn("a\n- ‸", "a\n‸")
        expectReturn("- a\n- ‸\n", "- a\n‸\n")
        expectReturn("- [ ] \(rlm)‸", "‸")
        expectReturn("- [ ]   ‸", "‸")
        expectReturn("- [ ] # ‸", "‸")
        expectReturn("- a\r\n- ‸\r\n", "- a\r\n‸\r\n")
        // The caret anywhere behind the marker.
        expectReturn("- [ ] ‸\(rlm)", "‸")
        // A list item with text isn't empty, and a caret in the marker is only a line break.
        expectReturn("- ‸a", "- \n- ‸a")
        expectReturn("-‸ a", "-\n‸ a")
        expectReturn("‸- a", "\n‸- a")
    }

    /// One level out first, as in Notes. What was nested under it goes along.
    @Test func returnOnAnEmptyNestedItemOutdentsIt() {
        expectReturn("- a\n  - ‸", "- a\n- ‸")
        expectReturn("- a\n  - [ ] ‸\n", "- a\n- [ ] ‸\n")
        expectReturn("- a\n  - b\n    - ‸", "- a\n  - b\n  - ‸")
        expectReturn("1. a\n   1. ‸", "1. a\n2. ‸")
        expectReturn("1. a\n   1. ‸\n2. b\n", "1. a\n2. ‸\n3. b\n")
        expectReturn("1. a\n   1. x\n   2. ‸\n2. b\n", "1. a\n   1. x\n2. ‸\n3. b\n")
        expectReturn("- a\n  - ‸\n    - c\n", "- a\n- ‸\n  - c\n")
    }

    @Test func returnOnAnEmptyItemStartsWhatFollowsAgain() {
        expectReturn("1. a\n2. ‸\n3. b\n4. c\n", "1. a\n‸\n1. b\n2. c\n")
        expectReturn("1. ‸\n2. b\n", "‸\n1. b\n")
        expectReturn("- a\n- ‸\n- b\n", "- a\n‸\n- b\n")
    }

    /// Renumbering: the rest of the list follows, and what is nested keeps its own numbers.
    @Test func returnRenumbersWhatFollows() {
        expectReturn("1. a‸\n2. b\n3. c\n", "1. a\n2. ‸\n3. b\n4. c\n")
        expectReturn("1. a\n2. b‸\n3. c\n", "1. a\n2. b\n3. ‸\n4. c\n")
        expectReturn("9. a‸\n10. b\n", "9. a\n10. ‸\n11. b\n")
        expectReturn("1. a‸\n   1. x\n   2. y\n2. b\n", "1. a\n2. ‸\n   1. x\n   2. y\n3. b\n")
        expectReturn("1. a\n   1. x‸\n   2. y\n2. b\n", "1. a\n   1. x\n   2. ‸\n   3. y\n2. b\n")
        expectReturn("1. a‸\r\n2. b\r\n", "1. a\r\n2. ‸\r\n3. b\r\n")
        expectReturn("1. א‸\n2. ב\n", "1. א\n2. ‸\n3. ב\n")
    }

    /// Two columns in is nested, as this editor draws it, whatever the number above it has grown to. To Markdown, `  1. x`
    /// under `1. a` and `   1. x` under `10. a` would be the same list, and a number reaching 10 would flatten what is under it.
    @Test func whatIsNestedDoesNotDependOnHowLongANumberIs() {
        expectReturn("1. a‸\n  1. x\n  2. y\n2. b\n", "1. a\n2. ‸\n  1. x\n  2. y\n3. b\n")
        expectReturn("9. a‸\n   1. x\n10. b\n", "9. a\n10. ‸\n   1. x\n11. b\n")
        expectReturn("8. a‸\n9. b\n   1. x\n   2. y\n10. c\n", "8. a\n9. ‸\n10. b\n   1. x\n   2. y\n11. c\n")
        expectOnce(Self.indent, "10. a\n   1. x‸\n", "10. a\n      1. x‸\n")
        expectOnce(Self.indent, "1. a\n2. b\n   1. x\n   2. y‸\n", "1. a\n2. b\n   1. x\n      1. y‸\n")
    }

    /// Where a list starts is someone's choice. A blank line is the end of a list, so two lists stay two.
    @Test func whatRenumberingLeavesAlone() {
        expectReturn("5. a‸\n6. b\n", "5. a\n6. ‸\n7. b\n")
        expectReturn("1. a‸\n\n1. b\n", "1. a\n2. ‸\n\n1. b\n")
        expectReturn("1. a‸\n   \n1. b\n", "1. a\n2. ‸\n   \n1. b\n")
        expectReturn("1. a‸\nplain\n1. b\n", "1. a\n2. ‸\nplain\n1. b\n")
        expectReturn("1. a‸\n- b\n1. c\n", "1. a\n2. ‸\n- b\n1. c\n")
        expectReturn("1. a‸\n1) b\n", "1. a\n2. ‸\n1) b\n")
        expectReturn("1. a‸\n```\n1. b\n```\n", "1. a\n2. ‸\n```\n1. b\n```\n")
        // Bytes in other lines don't move when a bullet goes on.
        expectReturn("- a‸\n1. b\n1. c\n", "- a\n- ‸\n1. b\n1. c\n")
    }

    /// An indented line of text goes with its item, and doesn't end the list.
    @Test func renumberingGoesPastTheTextOfAnItem() {
        expectReturn("1. a‸\n   more of a\n2. b\n", "1. a\n2. ‸\n   more of a\n3. b\n")
        // One column in is the same list, as anyone would read it.
        expectReturn("1. a‸\n 2. b\n3. c\n", "1. a\n2. ‸\n 3. b\n4. c\n")
        // All ones, as people write them: it reads 1, 2, 3 on GitHub, and here from the first edit on.
        expectReturn("1. a‸\n1. b\n1. c\n", "1. a\n2. ‸\n3. b\n4. c\n")
    }

    @Test func returnInAListWithASelection() {
        expectReturn("- a‸b‸c", "- a\n- ‸c")
        expectReturn("1. a‸b\n2. c‸d\n3. e\n", "1. a\n2. ‸d\n3. e\n")
        expectReturn("1. a‸bc‸\n2. d\n", "1. a\n2. ‸\n3. d\n")
    }

    @Test func nothingInCodeIsAList() {
        expectReturn("```\n- a‸\n```\n", "```\n- a\n‸\n```\n")
        expectReturn("```\n- ‸\n```\n", "```\n- \n‸\n```\n")
        expectOnce(Self.indent, "```\n- a‸\n```\n", "```\n- a‸\n```\n")
        expectOnce(Self.outdent, "```\n  - a‸\n```\n", "```\n  - a‸\n```\n")
        #expect(MarkdownEdits.typing("\t", replacing: NSRange(location: 7, length: 0), in: "```\n- a\n```\n") == nil, "a tab")
    }

    // MARK: indent and outdent

    @Test func indentNestsUnderTheItemAbove() {
        expectOnce(Self.indent, "- a\n- b‸\n", "- a\n  - b‸\n")
        expectOnce(Self.indent, "- [ ] a\n- [ ] b‸\n", "- [ ] a\n  - [ ] b‸\n")
        expectOnce(Self.indent, "- א\n- ב‸\n", "- א\n  - ב‸\n")
        expectOnce(Self.indent, "- a\n  - b\n  - c‸\n", "- a\n  - b\n    - c‸\n")
        // As far in as the text of the item above starts: `1. ` is 3 wide, and 2 spaces would be the same list on GitHub.
        expectOnce(Self.indent, "1. a\n2. b‸\n", "1. a\n   1. b‸\n")
        expectOnce(Self.indent, "10. a\n11. b‸\n", "10. a\n    1. b‸\n")
        expectOnce(Self.indent, "1. a\n- b‸\n", "1. a\n   - b‸\n")
        expectOnce(Self.indent, "- a\n1. b‸\n", "- a\n  1. b‸\n")
        expectOnce(Self.indent, "- a\r\n- b‸\r\n", "- a\r\n  - b‸\r\n")
    }

    @Test func outdentGoesLevelWithTheItemAbove() {
        expectOnce(Self.outdent, "- a\n  - b‸\n", "- a\n- b‸\n")
        expectOnce(Self.outdent, "- a\n  - b\n    - c‸\n", "- a\n  - b\n  - c‸\n")
        expectOnce(Self.outdent, "1. a\n   1. b‸\n", "1. a\n2. b‸\n")
        expectOnce(Self.outdent, "- [ ] a\n  - [x] ב‸\n", "- [ ] a\n- [x] ב‸\n")
        expectOnce(Self.outdent, "- a‸\n", "- a‸\n")
        expectOnce(Self.outdent, "  - a‸\n", "- a‸\n")
        expectOnce(Self.outdent, "\t- a‸\n", "- a‸\n")
    }

    /// With nothing above to go under, it still goes in, as in Notes. Going out again gives back the same bytes.
    @Test func theFirstItemOfAListCanGoInToo() {
        expectToggleWith(Self.indent, Self.outdent, "- a‸\n", "  - a‸\n")
        expectToggleWith(Self.indent, Self.outdent, "1. a‸\n", "   1. a‸\n")
        expectToggleWith(Self.indent, Self.outdent, "- a\n  - b‸\n", "- a\n    - b‸\n")
    }

    @Test func indentAndOutdentAreEachOthersOpposite() {
        expectToggleWith(Self.indent, Self.outdent, "- a\n- b‸\n- c\n", "- a\n  - b‸\n- c\n")
        expectToggleWith(Self.indent, Self.outdent, "1. a\n2. b‸\n3. c\n", "1. a\n   1. b‸\n2. c\n")
        expectToggleWith(Self.indent, Self.outdent, "1. א\n2. ב‸\n", "1. א\n   1. ב‸\n")
    }

    /// What is nested under an item goes with it, so the shape of the list stays.
    @Test func whatIsNestedGoesAlong() {
        expectOnce(Self.indent, "- a\n- b‸\n  - c\n    - d\n- e\n", "- a\n  - b‸\n    - c\n      - d\n- e\n")
        expectOnce(Self.outdent, "- a\n  - b‸\n    - c\n- e\n", "- a\n- b‸\n  - c\n- e\n")
        expectOnce(Self.indent, "1. a\n2. b‸\n   1. c\n   2. d\n3. e\n", "1. a\n   1. b‸\n      1. c\n      2. d\n2. e\n")
        expectOnce(Self.indent, "- a\n- b‸\n  more of b\n- c\n", "- a\n  - b‸\n    more of b\n- c\n")
    }

    @Test func indentAndOutdentWorkOnEveryItemTheSelectionTouches() {
        expectOnce(Self.indent, "- a\n- ‸b\n- c‸\n", "- a\n  - ‸b\n  - c‸\n")
        expectOnce(Self.outdent, "- a\n  - ‸b\n  - c‸\n", "- a\n- ‸b\n- c‸\n")
        expectOnce(Self.indent, "1. a\n2. ‸b\n3. c‸\n4. d\n", "1. a\n   1. ‸b\n   2. c‸\n2. d\n")
        // Selected along with its parent, a nested item moves once.
        expectOnce(Self.indent, "- a\n- ‸b\n  - c‸\n", "- a\n  - ‸b\n    - c‸\n")
        // Other paragraphs in the selection stay as they are.
        expectOnce(Self.indent, "‸plain\n- a\n- b‸\n", "‸plain\n  - a\n  - b‸\n")
    }

    @Test func indentAndOutdentOnAnythingElseDoNothing() {
        #expect(MarkdownEdits.indent(in: "plain", selection: NSRange(location: 2, length: 0)).changesNothing)
        #expect(MarkdownEdits.outdent(in: "plain", selection: NSRange(location: 2, length: 0)).changesNothing)
        #expect(MarkdownEdits.indent(in: "# Title", selection: NSRange(location: 2, length: 0)).changesNothing)
        #expect(MarkdownEdits.indent(in: "> q", selection: NSRange(location: 2, length: 0)).changesNothing)
        #expect(MarkdownEdits.outdent(in: "- a", selection: NSRange(location: 2, length: 0)).changesNothing)
        #expect(MarkdownEdits.indent(in: "", selection: NSRange(location: 0, length: 0)).changesNothing)
    }

    /// Numbers follow where the items went, at both levels.
    @Test func indentAndOutdentRenumber() {
        expectOnce(Self.indent, "1. a\n   1. x\n2. b‸\n3. c\n", "1. a\n   1. x\n   2. b‸\n2. c\n")
        expectOnce(Self.outdent, "1. a\n   1. x‸\n   2. y\n   3. z\n2. b\n", "1. a\n2. x‸\n   1. y\n   2. z\n3. b\n")
        expectOnce(Self.outdent, "1. a\n   1. x\n   2. y‸\n   3. z\n2. b\n", "1. a\n   1. x\n2. y‸\n   1. z\n3. b\n")
        expectOnce(Self.indent, "5. a\n6. b‸\n7. c\n", "5. a\n   1. b‸\n6. c\n")
        expectOnce(Self.indent, "1. a\n2. b\n3. c‸\n", "1. a\n2. b\n   1. c‸\n")
    }

    @Test func tabIsIndentOnAListItem() {
        func tab(_ text: String, at location: Int) -> String? { MarkdownEdits.typing("\t", replacing: NSRange(location: location, length: 0), in: text)?.applied(to: text) }
        #expect(tab("- a\n- b", at: 7) == "- a\n  - b")
        #expect(tab("1. a\n2. b", at: 9) == "1. a\n   1. b")
        #expect(tab("plain", at: 2) == nil, "a tab, as anywhere")
        #expect(tab("# Title", at: 2) == nil)
        #expect(tab("", at: 0) == nil)
    }

    // MARK: Delete

    /// The Delete key, as a text view asks: one character, the one before the caret. Or as the text view would do it.
    private func expectDelete(_ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let start = parse(before)
        let goal = parse(after)
        let range = start.selection.length > 0 ? start.selection : NSRange(location: start.selection.location - 1, length: 1)
        let edit = MarkdownEdits.typing("", replacing: range, in: start.text)
            ?? MarkdownEdits.Edit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
        #expect(bytes(edit.applied(to: start.text)) == bytes(goal.text), "\(before) gave \(edit.applied(to: start.text).debugDescription)", sourceLocation: sourceLocation)
        #expect(edit.selection == goal.selection, "\(before): selection", sourceLocation: sourceLocation)
    }

    /// Return makes a marker, and Delete takes it back: a marker is one thing on screen.
    @Test func deleteBehindAMarkerTakesAllOfIt() {
        expectDelete("- ‸", "‸")
        expectDelete("- [ ] ‸", "‸")
        expectDelete("- [x] ‸ab", "‸ab")
        expectDelete("1. ‸ab", "‸ab")
        expectDelete("12. ‸ab", "‸ab")
        expectDelete("# ‸Title", "‸Title")
        expectDelete("### ‸כותרת", "‸כותרת")
        expectDelete("> ‸q", "‸q")
        expectDelete("x\n- ‸y\n", "x\n‸y\n")
        // The indent stays, and so does a direction someone chose, whichever side of it the caret is.
        expectDelete("  - ‸ab", "  ‸ab")
        expectDelete("- [ ] \(rlm)‸ab", "\(rlm)‸ab")
        expectDelete("- [ ] ‸\(rlm)ab", "‸\(rlm)ab")
        // A heading inside an item goes first, then the item's own marker.
        expectDelete("- [ ] # ‸Shana", "- [ ] ‸Shana")
        expectDelete("- [ ] # \(rlm)‸a", "- [ ] \(rlm)‸a")
        expectDelete("- [ ] ‸Shana", "‸Shana")
    }

    @Test func deleteAnywhereElseIsOneCharacter() {
        expectDelete("- a‸b", "- ‸b")
        expectDelete("- [ ‸] a", "- [‸] a")
        expectDelete("-‸ a", "‸ a")
        expectDelete("1‸. a", "‸. a")
        expectDelete("a‸", "‸")
        expectDelete("```\n- ‸a\n```\n", "```\n-‸a\n```\n")
        #expect(MarkdownEdits.typing("", replacing: NSRange(location: 0, length: 1), in: "ab") == nil, "the text view does it")
        #expect(MarkdownEdits.typing("", replacing: NSRange(location: 0, length: 1), in: "- a") == nil)
        #expect(MarkdownEdits.typing("", replacing: NSRange(location: 2, length: 1), in: "- a") == nil)
    }

    @Test func deleteAtAMarkerRenumbers() {
        expectDelete("1. a\n2. ‸b\n3. c\n", "1. a\n‸b\n1. c\n")
        expectDelete("1. ‸a\n2. b\n", "‸a\n1. b\n")
        expectDelete("1. a\n   1. ‸x\n   2. y\n2. b\n", "1. a\n   ‸x\n   1. y\n2. b\n")
    }

    /// Taking lines out of a list: the numbers close up, and a list whose first line went keeps its start.
    @Test func deletingLinesRenumbers() {
        expectDelete("1. a\n‸2. b\n‸3. c\n", "1. a\n‸2. c\n")
        expectDelete("‸1. a\n‸2. b\n3. c\n", "‸1. b\n2. c\n")
        expectDelete("‸5. a\n‸6. b\n7. c\n", "‸5. b\n6. c\n")
        expectDelete("1. a‸b\n2. c‸d\n3. e\n", "1. a‸d\n2. e\n")
        expectDelete("1. ab\n‸2. cd", "1. ab‸2. cd")
        expectDelete("1. ab\n‸2. cd\n3. e\n", "1. ab‸2. cd\n2. e\n")
        expectDelete("1. a\n‸plain\n‸1. b\n", "1. a\n‸2. b\n")
        expectDelete("x\n‸1. a\n‸2. b\n", "x\n‸1. b\n")
    }

    @Test func deletingLinesWithNoNumbersIsTheTextViews() {
        #expect(MarkdownEdits.typing("", replacing: NSRange(location: 1, length: 1), in: "a\nb") == nil)
        #expect(MarkdownEdits.typing("", replacing: NSRange(location: 3, length: 1), in: "- a\n- b") == nil)
        #expect(MarkdownEdits.typing("", replacing: NSRange(location: 4, length: 4), in: "1. a\n2. b") == nil, "the last line of a list")
    }

    /// A paste with line endings is an edit like that too, and it is what is around it that follows.
    @Test func pastingLinesRenumbers() {
        func paste(_ pasted: String, _ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let start = parse(before)
            let goal = parse(after)
            let edit = MarkdownEdits.typing(pasted, replacing: start.selection, in: start.text)
                ?? MarkdownEdits.Edit(range: start.selection, replacement: pasted, selection: NSRange(location: start.selection.location + (pasted as NSString).length, length: 0))
            #expect(bytes(edit.applied(to: start.text)) == bytes(goal.text), "\(before) gave \(edit.applied(to: start.text).debugDescription)", sourceLocation: sourceLocation)
            #expect(edit.selection == goal.selection, "\(before): selection", sourceLocation: sourceLocation)
        }
        paste("7. x\n8. y\n", "1. a\n‸2. b\n", "1. a\n2. x\n3. y\n‸4. b\n")
        paste("x", "1. a\n‸2. b‸\n3. c\n", "1. a\nx‸\n3. c\n")
        paste("x\ny", "ab‸cd", "abx\ny‸cd")
        paste("no lines", "1. a‸\n2. b\n", "1. ano lines‸\n2. b\n")
    }

    // MARK: Return

    /// Return as a text view would do it, or as `typing` says it should. Bytes and caret.
    private func expectReturn(_ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let start = parse(before)
        let goal = parse(after)
        let edit = MarkdownEdits.typing("\n", replacing: start.selection, in: start.text)
            ?? MarkdownEdits.Edit(range: start.selection, replacement: "\n", selection: NSRange(location: start.selection.location + 1, length: 0))
        #expect(bytes(edit.applied(to: start.text)) == bytes(goal.text), "\(before) gave \(edit.applied(to: start.text).debugDescription)", sourceLocation: sourceLocation)
        #expect(edit.selection == goal.selection, "\(before): selection", sourceLocation: sourceLocation)
    }

    /// What split `[[sisi]]` on the phone: the bar leaves the caret between the brackets, then a name and Return.
    @Test func returnGoesBehindALinkAndNeverSplitsIt() {
        expectReturn("[[sisi‸]]", "[[sisi]]\n‸")
        expectReturn("[[‸]]", "[[]]\n‸")
        expectReturn("[[si‸si]]", "[[sisi]]\n‸")
        expectReturn("[[שלום‸]]", "[[שלום]]\n‸")
        expectReturn("see [[si‸si]] and more", "see [[sisi]]\n‸ and more")
        expectReturn("ראו [[שלו‸ם]] וגם", "ראו [[שלום]]\n‸ וגם")
        expectReturn("[[a|sho‸wn]]", "[[a|shown]]\n‸")
        expectReturn("[‸[a]]", "[[a]]\n‸")
        expectReturn("[[a]‸]", "[[a]]\n‸")
        expectReturn("[te‸xt](https://a.b) x", "[text](https://a.b)\n‸ x")
        expectReturn("[text](https://a‸.b) x", "[text](https://a.b)\n‸ x")
        expectReturn("**[[a‸]]**", "**[[a]]**\n‸")
        expectReturn("x\r\n[[a‸]]\r\ny", "x\r\n[[a]]\r\n‸\r\ny")
    }

    @Test func returnAroundALinkIsAnOrdinaryLineBreak() {
        expectReturn("[[sisi]]‸", "[[sisi]]\n‸")
        expectReturn("‸[[sisi]]", "\n‸[[sisi]]")
        expectReturn("[[si‸si", "[[si\n‸si")
        expectReturn("si‸si]]", "si\n‸si]]")
        expectReturn("[[a‸\n]]", "[[a\n‸\n]]")
        expectReturn("https://exa‸mple.com", "https://exa\n‸mple.com")
        #expect(MarkdownEdits.typing("\n", replacing: NSRange(location: 2, length: 0), in: "plain") == nil, "the text view does it")
    }

    @Test func returnKeepsBothHalvesOfAPair() {
        expectReturn("**Shana‸**", "**Shana**\n‸")
        expectReturn("**Sha‸na**", "**Sha**\n**‸na**")
        expectReturn("**‸Shana**", "\n‸**Shana**")
        expectReturn("*‸*Shana**", "\n‸**Shana**")
        expectReturn("**Shana*‸*", "**Shana**\n‸")
        expectReturn("**מודג‸ש** כאן", "**מודג**\n**‸ש** כאן")
        expectReturn("*a‸b* c", "*a*\n*‸b* c")
        expectReturn("`co‸de`", "`co`\n`‸de`")
        expectReturn("~~a‸b~~", "~~a~~\n~~‸b~~")
        expectReturn("***a‸b***", "***a***\n***‸b***")
        expectReturn("**a *b‸c* d**", "**a *b***\n***‸c* d**")
        expectReturn("x\r\n**a‸b**\r\n", "x\r\n**a**\r\n**‸b**\r\n")
    }

    @Test func returnWithBoldStillOpen() {
        expectReturn("**Sha‸na", "**Sha**\n**‸na")
        expectReturn("**Shana‸", "**Shana\n‸")
        expectReturn("**‸Shana", "\n‸**Shana")
    }

    @Test func returnWithASelection() {
        expectReturn("[[a‸b‸c]]", "[[ac]]\n‸")
        expectReturn("**a‸b‸c**", "**a**\n**‸c**")
        expectReturn("x‸y‸z", "x\n‸z")
        expectReturn("x\r\ny‸z‸\r\n", "x\r\ny\r\n‸\r\n")
        // One replacement, starting and ending between whole characters: these emoji share their first half.
        let edit = MarkdownEdits.typing("\n", replacing: NSRange(location: 4, length: 2), in: "[[🙂😀😁]]")
        #expect(bytes(edit?.applied(to: "[[🙂😀😁]]") ?? "") == bytes("[[🙂😁]]\n"))
        #expect(edit?.range.location == 4)
        #expect(edit?.selection == NSRange(location: 9, length: 0))
    }

    /// Nothing in fenced code is Markdown, and a table is plain text until `.plan/F-tables.md`.
    @Test func returnInCodeAndInATableIsAnOrdinaryLineBreak() {
        expectReturn("```\n[[a‸]]\n```\n", "```\n[[a\n‸]]\n```\n")
        expectReturn("```\n**a‸b**\n```\n", "```\n**a\n‸b**\n```\n")
        expectReturn("| a‸ | b |\n|---|---|\n", "| a\n‸ | b |\n|---|---|\n")
    }

    @Test func whatIsNotReturnIsLeftToTheTextView() {
        var read = false
        func note() -> String {
            read = true
            return "[[a]]"
        }
        #expect(MarkdownEdits.typing("x", replacing: NSRange(location: 3, length: 0), in: note()) == nil)
        #expect(!read, "a letter typed into a long note doesn't even read it")
        #expect(MarkdownEdits.typing("\r\n", replacing: NSRange(location: 3, length: 0), in: "[[a]]") == nil)
    }

    /// Any text, any caret: a link that was whole is whole afterwards, every character is still there, and the caret is
    /// between characters on the new line.
    @Test func returnNeverLosesAnythingOrSplitsALink() {
        var generator = SeededGenerator(seed: 2026)
        let pieces = ["word", "מילה", " ", "🙂", "**", "*", "`", "~~", "[[", "]]", "[[link]]", "[[קישור]]", "[a](u)", "- [ ] ", "# ", "\u{200F}", "```\n", "\n", "\r\n"]
        func links(_ text: String) -> [String] {
            var out: [String] = []
            for line in NoteText.lines(text) {
                for span in MarkdownInline.line(line).spans {
                    if case let .wikiLink(target) = span.kind { out.append(target) }
                }
            }
            return out
        }
        for _ in 0..<1_500 {
            var text = ""
            for _ in 0..<Int.random(in: 0...9, using: &generator) { text += pieces.randomElement(using: &generator)! }
            let ns = text as NSString
            var offsets = [0]
            for index in text.indices.dropFirst() { offsets.append(text.utf16.distance(from: text.startIndex, to: index)) }
            offsets.append(ns.length)
            let caret = NSRange(location: offsets.randomElement(using: &generator)!, length: 0)
            let edit = MarkdownEdits.typing("\n", replacing: caret, in: text) ?? MarkdownEdits.Edit(range: caret, replacement: "\n", selection: NSRange(location: caret.location + 1, length: 0))
            let after = edit.applied(to: text)
            let afterNS = after as NSString
            #expect(NSMaxRange(edit.selection) <= afterNS.length, "\(text.debugDescription) \(caret)")
            #expect(MarkdownEdits.caret(at: edit.selection.location, in: after) == edit.selection.location, "\(text.debugDescription) \(caret)")
            #expect(after.filter(\.isLetter) == text.filter(\.isLetter), "no letter goes, and none comes: \(text.debugDescription) \(caret)")
            #expect(links(after).sorted() == links(text).sorted() || FencedCode(text: ns).role(ofParagraphAt: ns.paragraphRange(for: caret).location) != .none, "\(text.debugDescription) \(caret) gave \(after.debugDescription)")
        }
    }

    // MARK: several paragraphs

    @Test func blockActionsWorkOnEveryParagraphTheSelectionTouches() {
        expectToggle(Self.task, "‸one\ntwo\nthree‸\n", "- [ ] ‸one\n- [ ] two\n- [ ] three‸\n")
        expectToggle(Self.task, "א‸חת\nשתיים\nשל‸וש\n", "- [ ] א‸חת\n- [ ] שתיים\n- [ ] של‸וש\n")
        expectToggle(Self.bullet, "a‸a\r\nbb‸\r\n", "- a‸a\r\n- bb‸\r\n")
        expectToggle(Self.heading(2), "‸a\nb‸\n", "## ‸a\n## b‸\n")
        expectOnce(Self.body, "# ‸a\n## b‸\n", "‸a\nb‸\n")
    }

    /// A triple tap selects the line ending, which touches the start of the next line and no more of it.
    @Test func aSelectionEndingAtALineStartDoesNotTakeThatLine() {
        expectOnce(Self.task, "‸one\n‸two\n", "- [ ] ‸one\n‸two\n")
        expectOnce(Self.heading(1), "‸שורה\r\n‸שנייה\r\n", "# ‸שורה\r\n‸שנייה\r\n")
    }

    @Test func aMixedSelectionBecomesAllOneThing() {
        expectOnce(Self.task, "‸- [ ] a\nb‸\n", "‸- [ ] a\n- [ ] b‸\n")
        expectOnce(Self.task, "- [ ] a‸a\n- [x] b‸b\n", "a‸a\nb‸b\n")
        expectOnce(Self.bullet, "- a‸a\nb‸b\n", "- a‸a\n- b‸b\n")
        expectOnce(Self.heading(1), "# a‸a\nb‸b\n", "# a‸a\n# b‸b\n")
    }

    @Test func blankLinesInASelectionGetNoMarker() {
        expectOnce(Self.task, "‸one\n\ntwo‸\n", "- [ ] ‸one\n\n- [ ] two‸\n")
        expectOnce(Self.bullet, "‸a\n   \nb‸", "- ‸a\n   \n- b‸")
        expectOnce(Self.task, "‸\n‸\n", "- [ ] ‸\n‸\n")
    }

    /// The first paragraph flips, and the others end up the same way, whichever way they went.
    @Test func directionOnSeveralParagraphsMakesThemOneWay() {
        expectOnce(Self.direction, "‸one\ntwo‸\n", "\(rlm)‸one\n\(rlm)two‸\n")
        expectOnce(Self.direction, "\(rlm)‸one\n\(rlm)two‸\n", "‸one\ntwo‸\n")
        expectOnce(Self.direction, "‸אחת\nשתיים‸\n", "\(lrm)‸אחת\n\(lrm)שתיים‸\n")
        expectOnce(Self.direction, "‸one\nשתיים‸\n", "\(rlm)‸one\nשתיים‸\n")
        expectOnce(Self.direction, "‸# one\n- [ ] two‸\n", "‸# \(rlm)one\n- [ ] \(rlm)two‸\n")
    }

    // MARK: wiki link

    @Test func wikiLinkInsertsWithTheCaretInside() {
        expectOnce(Self.link, "see ‸", "see [[‸]]")
        expectOnce(Self.link, "ראו ‸", "ראו [[‸]]")
        expectOnce(Self.link, "‸", "[[‸]]")
        expectOnce(Self.link, "see ‸Notes‸ there", "see [[‸Notes‸]] there")
        expectOnce(Self.link, "ראו ‸פתקים‸ שם", "ראו [[‸פתקים‸]] שם")
        expectOnce(Self.link, "‸line\n‸next", "[[‸line‸]]\nnext")
        // Over two lines it would be no link: the caret version goes where the selection starts.
        expectOnce(Self.link, "‸one\ntwo‸", "[[‸]]one\ntwo")
    }

    // MARK: line endings

    @Test func aNewLineMatchesTheNote() {
        #expect(MarkdownEdits.lineEnding(in: "", at: 0) == "\n")
        #expect(MarkdownEdits.lineEnding(in: "no ending", at: 3) == "\n")
        #expect(bytes(MarkdownEdits.lineEnding(in: "a\nb\n", at: 1)) == [0x0A])
        #expect(bytes(MarkdownEdits.lineEnding(in: "a\r\nb\r\n", at: 1)) == [0x0D, 0x0A])
        // On a last line with no ending of its own, the note's first ending decides.
        #expect(bytes(MarkdownEdits.lineEnding(in: "a\r\nlast", at: 5)) == [0x0D, 0x0A])
        #expect(bytes(MarkdownEdits.lineEnding(in: "שורה\r\nאחרונה", at: 8)) == [0x0D, 0x0A])
        #expect(bytes(MarkdownEdits.lineEnding(in: "a\r\n", at: 3)) == [0x0D, 0x0A])
        // A note that mixes them: each line keeps its own.
        #expect(bytes(MarkdownEdits.lineEnding(in: "a\nb\r\nc", at: 2)) == [0x0D, 0x0A])
        #expect(bytes(MarkdownEdits.lineEnding(in: "a\nb\r\nc", at: 0)) == [0x0A])
    }

    // MARK: a caret kept from other text

    @Test func aKeptCaretLandsBetweenCharacters() {
        #expect(MarkdownEdits.caret(at: 2, in: "a🙂b") == 1, "not inside the emoji's two units")
        #expect(MarkdownEdits.caret(at: 1, in: "a🙂b") == 1)
        #expect(MarkdownEdits.caret(at: 3, in: "a🙂b") == 3)
        #expect(MarkdownEdits.caret(at: 2, in: "a\r\nb") == 1, "nor inside a CRLF")
        #expect(MarkdownEdits.caret(at: 3, in: "a\r\nb") == 3)
        #expect(MarkdownEdits.caret(at: 99, in: "abc") == 3, "at most its end")
        #expect(MarkdownEdits.caret(at: -1, in: "abc") == 0)
        #expect(MarkdownEdits.caret(at: 0, in: "") == 0)
        #expect(MarkdownEdits.caret(at: 2, in: "שָׁלוֹם") == 0, "nor inside a letter and its points")
    }

    // MARK: ticking a box

    private func tick(_ text: String, at location: Int, selection: NSRange = NSRange(location: 0, length: 0)) -> String? {
        MarkdownEdits.toggleTick(in: text, paragraphAt: location, selection: selection)?.applied(to: text)
    }

    @Test func tickingChangesOneByteAndTwiceIsTheIdentity() throws {
        for (before, after) in [("- [ ] a", "- [x] a"), ("- [ ] משימה", "- [x] משימה"), ("* [ ] b", "* [x] b"), ("  - [ ] c\n", "  - [x] c\n"), ("- [ ] \(rlm)d\r\n", "- [x] \(rlm)d\r\n")] {
            #expect(bytes(tick(before, at: 0) ?? "") == bytes(after))
            #expect(bytes(tick(after, at: 0) ?? "") == bytes(before))
            let a = bytes(before), b = bytes(after)
            #expect(a.count == b.count, "same length, so nothing else in the file moves")
            #expect(zip(a, b).filter { $0 != $1 }.count == 1, "exactly one byte differs")
        }
        #expect(bytes(tick("- [X] a", at: 0) ?? "") == bytes("- [ ] a"))
    }

    @Test func tickingFindsTheParagraphAndLeavesTheSelection() throws {
        let text = "one\n- [ ] two\nthree"
        let at = (text as NSString).range(of: "two").location
        let edit = try #require(MarkdownEdits.toggleTick(in: text, paragraphAt: at, selection: NSRange(location: 1, length: 2)))
        #expect(bytes(edit.applied(to: text)) == bytes("one\n- [x] two\nthree"))
        #expect(edit.selection == NSRange(location: 1, length: 2))
        let later = try #require(MarkdownEdits.toggleTick(in: text, paragraphAt: at, selection: NSRange(location: 16, length: 1)))
        #expect(later.selection == NSRange(location: 16, length: 1))
    }

    @Test func tickingALineThatIsNoTaskDoesNothing() {
        #expect(tick("plain", at: 0) == nil)
        #expect(tick("- bullet", at: 0) == nil)
        #expect(tick("# - [ ] a", at: 0) == nil)
        #expect(tick("", at: 0) == nil)
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

    /// A new note is named from its first line, and the bar makes these lines one tap away.
    @Test func aFileNameHasNoMarkdownMarksInIt() {
        #expect(PathPolicy.fileName(fromFirstLine: "- [ ] Buy milk") == "Buy milk")
        #expect(PathPolicy.fileName(fromFirstLine: "- [x] לקנות חלב") == "לקנות חלב")
        #expect(PathPolicy.fileName(fromFirstLine: "- Buy milk") == "Buy milk")
        #expect(PathPolicy.fileName(fromFirstLine: "**Title**") == "Title")
        #expect(PathPolicy.fileName(fromFirstLine: "*Title* and `code`") == "Title and code")
        #expect(PathPolicy.fileName(fromFirstLine: "[[Other note]] thoughts") == "Other note thoughts")
        #expect(PathPolicy.fileName(fromFirstLine: "[a link](https://example.com/x)") == "a link")
        #expect(PathPolicy.fileName(fromFirstLine: "> quoted") == "quoted")
        #expect(PathPolicy.fileName(fromFirstLine: "# \u{200F}**כותרת**") == "כותרת")
        // Pressing Bold on an empty note writes `****` first. Marks with no text are no name.
        #expect(PathPolicy.fileName(fromFirstLine: "****") == "Untitled")
        #expect(PathPolicy.fileName(fromFirstLine: "**") == "Untitled")
        #expect(PathPolicy.fileName(fromFirstLine: "``") == "Untitled")
        #expect(PathPolicy.fileName(fromFirstLine: "---") == "Untitled")
    }

    // MARK: anything

    /// Random paragraphs in both scripts, with every line ending, at every position. Plain text is toggled by
    /// every action twice; marks already in the text may not come back as they were, but no byte outside the
    /// paragraphs the selection touches ever changes.
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

            for action in [Self.task, Self.bullet, Self.direction, Self.body, Self.heading(1), Self.heading(3)] {
                let edit = action(text, selection)
                let after = edit.applied(to: text) as NSString
                #expect(NSMaxRange(edit.selection) <= after.length, "\(text.debugDescription) \(selection)")
                let touched = ns.paragraphRange(for: selection)
                #expect(edit.range.location >= touched.location && NSMaxRange(edit.range) <= NSMaxRange(touched), "\(text.debugDescription) \(selection)")
                #expect(bytes(ns.substring(to: touched.location)) == bytes(after.substring(to: touched.location)))
                let tail = ns.length - NSMaxRange(touched)
                #expect(bytes(ns.substring(from: NSMaxRange(touched))) == bytes(after.substring(from: after.length - tail)))
            }
            for action in [Self.bold, Self.italic, Self.code, Self.link] {
                let wrapped = action(text, selection)
                #expect(NSMaxRange(wrapped.selection) <= (wrapped.applied(to: text) as NSString).length, "\(text.debugDescription) \(selection)")
            }

            // The same text with no marks in it comes back whole from two presses of anything.
            let plain = String(text.unicodeScalars.filter { !["*", "-", "#", "[", "]", "1", "x", "\u{200F}", "\u{200E}"].contains($0) }.map(Character.init))
            let caret = NSRange(location: min(selection.location, (plain as NSString).length), length: 0)
            let safe = isBetweenCharacters(caret.location, in: plain) ? caret : NSRange(location: 0, length: 0)
            for action in [Self.task, Self.bullet, Self.numbered, Self.bold, Self.italic, Self.code, Self.direction, Self.heading(1), Self.heading(2), Self.heading(3)] {
                let once = action(plain, safe)
                let middle = once.applied(to: plain)
                let twice = action(middle, once.selection)
                #expect(bytes(twice.applied(to: middle)) == bytes(plain), "\(plain.debugDescription) \(safe)")
            }
        }
    }

    /// Lists of any shape, any list action, any caret: nothing but markers and indent changes, each list's numbers read right
    /// afterwards, and only the list that was touched changes.
    @Test func listActionsKeepTheTextAndNumberTheirList() {
        var generator = SeededGenerator(seed: 1999)
        let markers = ["- ", "* ", "- [ ] ", "- [x] ", "1. ", "2. ", "1) ", "10. "]
        let indents = ["", "", "", "  ", "   ", "    ", "      "]
        let words = ["a", "bb", "מילה", "🙂", "**b**", "[[l]]", ""]
        let fillers = ["plain", "", "   more", "# Title", "```", "> q"]
        func letters(_ text: String) -> [Character] {
            // What a reader would call the words, in order: no markers, no space, no numbers.
            var out: [Character] = []
            for line in NoteText.lines(text) {
                let parsed = MarkdownInline.line(line)
                let u = Array(line.utf16)
                let body = String(decoding: u[min(parsed.textStart, u.count)...], as: UTF16.self)
                out += body.filter { !$0.isWhitespace }
            }
            return out
        }
        for _ in 0..<1_200 {
            var lines: [String] = []
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                if Int.random(in: 0..<4, using: &generator) == 0 {
                    lines.append(fillers.randomElement(using: &generator)!)
                } else {
                    lines.append(indents.randomElement(using: &generator)! + markers.randomElement(using: &generator)! + words.randomElement(using: &generator)!)
                }
            }
            let ending = Bool.random(using: &generator) ? "\n" : "\r\n"
            let text = lines.joined(separator: ending) + ending
            let ns = text as NSString
            var offsets = [0]
            for index in text.indices.dropFirst() { offsets.append(text.utf16.distance(from: text.startIndex, to: index)) }
            offsets.append(ns.length)
            let a = offsets.randomElement(using: &generator)!
            let b = Bool.random(using: &generator) ? a : offsets.randomElement(using: &generator)!
            let selection = NSRange(location: min(a, b), length: abs(a - b))
            let name = "\(text.debugDescription) \(selection)"

            for (action, label) in [(Self.indent, "indent"), (Self.outdent, "outdent")] {
                let edit = action(text, selection)
                let after = edit.applied(to: text)
                #expect(NSMaxRange(edit.selection) <= (after as NSString).length, "\(label) \(name)")
                #expect(letters(after) == letters(text), "\(label) \(name) gave \(after.debugDescription)")
                #expect(NoteText.lines(after).count == NoteText.lines(text).count, "\(label) \(name)")
                // The numbers it left need nothing more: a letter at the end of that line changes nothing else.
                let afterNS = after as NSString
                let lineEnd = NSMaxRange(MarkdownEdits.paragraphContents(of: afterNS, at: edit.selection.location))
                let letter = NSRange(location: lineEnd, length: 0)
                let once = MarkdownEdits.numbering(after: MarkdownEdits.Edit(range: letter, replacement: "z", selection: letter), in: afterNS)
                #expect(bytes(once.applied(to: after)) == bytes(afterNS.replacingCharacters(in: letter, with: "z")) || edit.changesNothing, "\(label) \(name) gave \(after.debugDescription)")
            }
            guard selection.length == 0 else { continue }
            let pressed = MarkdownEdits.typing("\n", replacing: selection, in: text)
                ?? MarkdownEdits.Edit(range: selection, replacement: "\n", selection: NSRange(location: selection.location + 1, length: 0))
            let after = pressed.applied(to: text)
            #expect(NSMaxRange(pressed.selection) <= (after as NSString).length, "\(name)")
            #expect(MarkdownEdits.caret(at: pressed.selection.location, in: after) == pressed.selection.location, "\(name)")
        }
    }

    /// Numbering twice is numbering once: what an action leaves needs nothing more.
    @Test func numberingIsStable() {
        for text in ["1. a\n2. b\n3. c\n", "1. a\n   1. x\n   2. y\n2. b\n", "5. a\n6. b\n", "1. a\n\n1. b\n", "- a\n  1. x\n  2. y\n- b\n"] {
            let at = NSRange(location: 1, length: 0)
            let once = MarkdownEdits.numbering(after: MarkdownEdits.Edit(range: at, replacement: "z", selection: at), in: text as NSString)
            #expect(bytes(once.applied(to: text)) == bytes((text as NSString).replacingCharacters(in: at, with: "z")), "\(text.debugDescription)")
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
