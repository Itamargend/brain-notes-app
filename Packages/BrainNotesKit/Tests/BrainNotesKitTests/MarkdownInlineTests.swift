import Foundation
import Testing
@testable import BrainNotesKit

/// What the scanner calls text and what it calls syntax, written out as the two strings a reader of each range would see.
@Suite struct MarkdownInlineTests {
    private func marks(_ line: String) -> [String] {
        let ns = line as NSString
        return MarkdownInline.line(line).marks.map { ns.substring(with: $0) }
    }

    private func spans(_ line: String) -> [String] {
        let ns = line as NSString
        return MarkdownInline.line(line).spans.map { span in
            let name: String
            switch span.kind {
            case .bold: name = "bold"
            case .italic: name = "italic"
            case .strikethrough: name = "strike"
            case .code: name = "code"
            case let .wikiLink(target): name = "wiki(\(target))"
            case let .link(url): name = "link(\(url))"
            case .bareURL: name = "url"
            }
            return "\(name):\(ns.substring(with: span.content))"
        }
    }

    // MARK: spans

    @Test func boldItalicAndCodeInEnglishAndHebrew() {
        #expect(spans("a **bold** b") == ["bold:bold"])
        #expect(marks("a **bold** b") == ["**", "**"])
        #expect(spans("מילה **מודגשת** כאן") == ["bold:מודגשת"])
        #expect(spans("a *it* b") == ["italic:it"])
        #expect(spans("מילה *נטויה* כאן") == ["italic:נטויה"])
        #expect(spans("a `code` b") == ["code:code"])
        #expect(marks("a `code` b") == ["`", "`"])
        #expect(spans("קוד `let x` כאן") == ["code:let x"])
        #expect(spans("__bold__ and _it_") == ["bold:bold", "italic:it"])
        #expect(spans("~~gone~~") == ["strike:gone"])
    }

    @Test func boldAndItalicNest() {
        let ns = "***both***" as NSString
        let line = MarkdownInline.line(ns as String)
        #expect(line.spans.count == 2)
        let italic = line.spans.first { $0.kind == .italic }
        let bold = line.spans.first { $0.kind == .bold }
        #expect(italic.map { ns.substring(with: $0.content) } == "**both**")
        #expect(bold.map { ns.substring(with: $0.content) } == "both")
        #expect(italic?.whole == NSRange(location: 0, length: ns.length))
        #expect(spans("**a *b* c**").sorted() == ["bold:a *b* c", "italic:b"])
    }

    @Test func marksThatPairWithNothingAreText() {
        #expect(spans("2 * 3 * 4").isEmpty)
        #expect(spans("** not bold **").isEmpty)
        #expect(spans("close only**").isEmpty)
        #expect(spans("****").isEmpty)
        #expect(spans("* * *").isEmpty)
        #expect(spans("snake_case_name").isEmpty, "an underscore inside a word")
        #expect(spans("~one~").isEmpty, "only a double tilde")
        #expect(spans("a ` b").isEmpty)
    }

    /// `**Shana` with no pair, as the phone showed it raw in a task. It is bold to the line's end, and its mark hides.
    @Test func boldStillOpenReadsAsBoldToTheLineEnd() {
        #expect(spans("**open only") == ["bold:open only"])
        #expect(marks("**open only") == ["**"])
        #expect(spans("a **b") == ["bold:b"])
        #expect(spans("**מודגש פתוח") == ["bold:מודגש פתוח"])
        #expect(spans("**a** and **b").sorted() == ["bold:a", "bold:b"])
        #expect(spans("(**b") == ["bold:b"])
        let open = MarkdownInline.line("**a b")
        #expect(open.spans.first?.close == NSRange(location: 5, length: 0), "no closing mark, so nothing to hide there")
        #expect(open.spans.first?.whole == NSRange(location: 0, length: 5))
    }

    /// What must stay as it is: arithmetic, a lone star or underscore, and marks inside what isn't Markdown.
    @Test func onlyAnOpeningPairOfStarsStaysOpen() {
        #expect(spans("2**n").isEmpty)
        #expect(spans("a**b").isEmpty)
        #expect(spans("2 ** 3").isEmpty)
        #expect(spans("*one").isEmpty)
        #expect(spans("__one").isEmpty)
        #expect(spans("***one").isEmpty)
        #expect(spans("~~one").isEmpty)
        #expect(spans("`**a`") == ["code:**a"])
        #expect(spans("[[**a]]") == ["wiki(**a):**a"])
    }

    @Test func codeIsOpaque() {
        #expect(spans("`**not bold**`") == ["code:**not bold**"])
        #expect(marks("`**not bold**`") == ["`", "`"])
        #expect(spans("`*a` **b**").sorted() == ["bold:b", "code:*a"])
        #expect(spans("``a ` b``") == ["code:a ` b"])
        #expect(spans("`[[x]]`") == ["code:[[x]]"])
    }

    @Test func escapesAreSyntaxToo() {
        #expect(spans("\\*not italic\\*").isEmpty)
        #expect(marks("\\*a\\*") == ["\\", "\\"])
        #expect(spans("\\\\ a").isEmpty)
        #expect(marks("a \\z") == [], "only before punctuation")
    }

    @Test func links() {
        #expect(spans("see [[Other note]]") == ["wiki(Other note):Other note"])
        #expect(marks("see [[Other note]]") == ["[[", "]]"])
        #expect(spans("[[פתק אחר]]") == ["wiki(פתק אחר):פתק אחר"])
        #expect(spans("[[a|shown]]") == ["wiki(a):shown"])
        #expect(marks("[[a|shown]]") == ["[[a|", "]]"])
        #expect(spans("[[]]").isEmpty)
        #expect(spans("[[a").isEmpty)
        #expect(spans("[text](https://example.com/a_b)") == ["link(https://example.com/a_b):text"])
        #expect(marks("[text](https://example.com)") == ["[", "](https://example.com)"])
        #expect(spans("[**b**](u)").sorted() == ["bold:b", "link(u):**b**"])
        #expect(spans("[t](a(b)c)") == ["link(a(b)c):t"])
        #expect(spans("[t](u \"title\")") == ["link(u):t"])
        #expect(spans("[no link] here").isEmpty)
        #expect(spans("![alt](pic.png)").isEmpty, "an image is left as written")
    }

    @Test func bareURLs() {
        #expect(spans("go to https://example.com/a?b=1 now") == ["url:https://example.com/a?b=1"])
        #expect(marks("go to https://example.com now") == [], "nothing to hide")
        #expect(spans("(https://example.com/a_(b))") == ["url:https://example.com/a_(b)"])
        #expect(spans("see http://a.b.") == ["url:http://a.b"])
        #expect(spans("see http://a.b, then") == ["url:http://a.b"])
        #expect(spans("**https://a.b**").sorted() == ["bold:https://a.b", "url:https://a.b"])
        #expect(spans("ראו https://a.b כאן") == ["url:https://a.b"])
        #expect(spans("xhttp://a.b").isEmpty)
        #expect(spans("http://").isEmpty)
        #expect(spans("HTTPS://A.B") == ["url:HTTPS://A.B"])
    }

    // MARK: blocks

    @Test func blocksAndTheirMarkers() {
        #expect(MarkdownInline.line("# Title").block == .heading(1))
        #expect(marks("# Title") == ["# "])
        #expect(MarkdownInline.line("### כותרת").block == .heading(3))
        #expect(MarkdownInline.line("####### seven").block == .plain)
        #expect(MarkdownInline.line("#tag").block == .plain)
        #expect(MarkdownInline.line("- item").block == .bullet(level: 0))
        #expect(marks("- item") == ["- "])
        #expect(MarkdownInline.line("    * item").block == .bullet(level: 2))
        #expect(marks("    * item") == ["    * "])
        #expect(MarkdownInline.line("\t- item").block == .bullet(level: 1))
        #expect(MarkdownInline.line("> said").block == .quote)
        #expect(marks("> said") == ["> "])
        #expect(MarkdownInline.line("---").block == .rule)
        #expect(marks("---") == ["---"])
        #expect(MarkdownInline.line("***").block == .rule)
        #expect(MarkdownInline.line("-- -").block == .plain)
    }

    @Test func tasksKnowTheirBox() {
        #expect(MarkdownInline.line("- [ ] open").block == .task(done: false, level: 0, box: 3))
        #expect(MarkdownInline.line("- [x] done").block == .task(done: true, level: 0, box: 3))
        #expect(MarkdownInline.line("* [X] done").block == .task(done: true, level: 0, box: 3))
        #expect(MarkdownInline.line("  - [ ] nested").block == .task(done: false, level: 1, box: 5))
        #expect(marks("  - [ ] nested **b**") == ["  - [ ] ", "**", "**"])
        #expect(MarkdownInline.line("- [ ]").block == .bullet(level: 0), "no text space: a bullet reading [ ]")
    }

    /// A number is what a reader needs to see, so it stays.
    @Test func numbersAreNotHidden() {
        let line = MarkdownInline.line("12. item **b**")
        #expect(line.block == .numbered(marker: NSRange(location: 0, length: 4), level: 0))
        #expect(marks("12. item **b**") == ["**", "**"])
        #expect(line.textStart == 4)
        #expect(line.hasBlockMarker)
        #expect(!MarkdownInline.line("plain").hasBlockMarker)
    }

    /// Only the indent is syntax, and each level is as far as `1. ` goes, under a number or a bullet.
    @Test func aNestedNumberHidesItsIndentAndKnowsItsLevel() {
        #expect(MarkdownInline.line("   1. a").block == .numbered(marker: NSRange(location: 3, length: 3), level: 1))
        #expect(marks("   1. a") == ["   "])
        #expect(MarkdownInline.line("  1. a").block == .numbered(marker: NSRange(location: 2, length: 3), level: 1), "under a bullet")
        #expect(MarkdownInline.line("      1. a").block == .numbered(marker: NSRange(location: 6, length: 3), level: 2))
        #expect(MarkdownInline.line("     1. a").block == .numbered(marker: NSRange(location: 5, length: 3), level: 2))
        #expect(MarkdownInline.line("   - a").block == .bullet(level: 1), "a bullet under a number")
        #expect(MarkdownInline.line("     - a").block == .bullet(level: 2))
        #expect(MarkdownInline.line("1) a").block == .numbered(marker: NSRange(location: 0, length: 3), level: 0))
        #expect(MarkdownInline.line("1.a").block == .plain)
        #expect(MarkdownInline.line("1.5 litres").block == .plain)
    }

    /// Keep the direction mark placement: after the marker. It is not syntax, so it never counts as a mark.
    @Test func directionMarksStayOutOfTheMarks() {
        let rlm = "\u{200F}"
        #expect(MarkdownInline.line("# \(rlm)Title").block == .heading(1))
        #expect(marks("# \(rlm)Title") == ["# "])
        #expect(MarkdownInline.line("- [ ] \(rlm)Task").block == .task(done: false, level: 0, box: 3))
        #expect(marks("- [ ] \(rlm)**a**") == ["- [ ] ", "**", "**"])
        #expect(spans("\(rlm)**a**") == ["bold:a"])
    }

    @Test func aLineKnowsWhereItsTextStarts() {
        let rlm = "\u{200F}"
        func start(_ line: String) -> Int { MarkdownInline.line(line).textStart }
        func mark(_ line: String) -> Int? { MarkdownInline.line(line).directionMark }
        #expect(start("plain") == 0)
        #expect(start("# Title") == 2)
        #expect(start("# \(rlm)Title") == 3)
        #expect(mark("# \(rlm)Title") == 2)
        #expect(start("- [ ] \(rlm)Task") == 7)
        #expect(start("  - x") == 4)
        #expect(start("\(rlm)plain") == 1)
        #expect(mark("\(rlm)plain") == 0)
        #expect(mark("plain") == nil)
        #expect(start("---") == 3, "a rule has no text")
        #expect(MarkdownInline.line("```swift", fence: .opening).textStart == 8)
    }

    /// What the phone showed raw: a heading and bold inside a task.
    @Test func aHeadingInsideAListItemIsSyntaxToo() {
        let line = MarkdownInline.line("- [ ] # **Shana")
        #expect(line.block == .task(done: false, level: 0, box: 3))
        #expect(line.headingLevel == 1)
        #expect(marks("- [ ] # **Shana") == ["- [ ] ", "# ", "**"])
        #expect(spans("- [ ] # **Shana") == ["bold:Shana"])
        #expect(line.textStart == 8, "behind both markers")
        #expect(marks("- [x] ## *it*") == ["- [x] ", "## ", "*", "*"])
        #expect(MarkdownInline.line("- [x] ## a").headingLevel == 2)
        #expect(MarkdownInline.line("- ### a").headingLevel == 3)
        #expect(MarkdownInline.line("  - # a").block == .bullet(level: 1))
        #expect(MarkdownInline.line("> # a").headingLevel == 1)
        #expect(MarkdownInline.line("1. # a").headingLevel == 1)
        #expect(marks("- [ ] # כותרת") == ["- [ ] ", "# "])
        #expect(MarkdownInline.plainText("- [ ] # **Shana") == "Shana")
    }

    @Test func whatIsNotAHeadingInsideAnItem() {
        #expect(MarkdownInline.line("- [ ] a").headingLevel == 0)
        #expect(MarkdownInline.line("- [ ] #tag").headingLevel == 0)
        #expect(marks("- [ ] #tag") == ["- [ ] "])
        #expect(MarkdownInline.line("- [ ] ####### a").headingLevel == 0)
        #expect(MarkdownInline.line("# a").headingLevel == 1, "a heading's own level")
        #expect(marks("# # a") == ["# "], "no heading in a heading")
        #expect(MarkdownInline.line("plain # a").headingLevel == 0)
    }

    /// Keep the direction mark placement: behind the markers, and a mark between them breaks nothing.
    @Test func directionMarksAroundAHeadingInsideAnItem() {
        let rlm = "\u{200F}"
        let behind = MarkdownInline.line("- [ ] # \(rlm)a")
        #expect(behind.headingLevel == 1)
        #expect(behind.textStart == 9)
        #expect(behind.directionMark == 8)
        let between = MarkdownInline.line("- [ ] \(rlm)# a")
        #expect(between.headingLevel == 1)
        #expect(between.textStart == 9)
        #expect(between.directionMark == 6)
        #expect(marks("- [ ] \(rlm)# a") == ["- [ ] ", "# "])
        #expect(MarkdownEdits.isRightToLeft(paragraph: "- [ ] # \(rlm)a"))
        #expect(MarkdownEdits.isRightToLeft(paragraph: "- [ ] # שנה"))
        #expect(!MarkdownEdits.isRightToLeft(paragraph: "- [x] # a"))
    }

    /// The note view, the title and the file name read the same line the same way.
    @Test func theNoteViewReadsAHeadingInsideAnItem() throws {
        let blocks = MarkdownBlock.parse("- [ ] # **Shana\n- ## b\n1. ### c\n> # d\n- [ ] #tag\n- [ ] e\n- [ ] #\n")
        #expect(blocks.map(\.innerHeadingLevel) == [1, 2, 3, 1, nil, nil, nil])
        #expect(blocks.map(\.text) == ["**Shana", "b", "c", "d", "#tag", "e", "#"])
        #expect(blocks[0].kind == .task(done: false, indent: 0))
        #expect(MarkdownBlock.parse("- [ ] # \u{200F}a\n").first?.isRightToLeft == true)
        let bold = NoteText.inlineMarkdown("**Shana")
        #expect(String(bold.characters) == "Shana")
        #expect(bold.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(String(NoteText.inlineMarkdown("**Shana  ").characters) == "Shana")
        #expect(String(NoteText.inlineMarkdown("2**n").characters) == "2**n", "not a pair")
        #expect(String(NoteText.inlineMarkdown("**a** b").characters) == "a b")
        #expect(NoteText.title(of: "- [ ] # **Shana\n", path: "a.md") == "Shana")
        #expect(PathPolicy.fileName(fromFirstLine: "- [ ] # **Shana") == "Shana")
    }

    /// Tables are `.plan/F-tables.md`'s. Until then they are ordinary text, and nothing here may take them for anything else.
    @Test func aTableRowIsOrdinaryText() {
        for row in ["| Date | Distance | Pace | Notes |", "|------|----------|------|-------|", "| 1 Nov | 5.2 km | 5:41 | easy, windy |"] {
            let line = MarkdownInline.line(row)
            #expect(line.block == .plain, "\(row)")
            #expect(line.marks.isEmpty, "\(row)")
            #expect(line.headingLevel == 0, "\(row)")
        }
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 | 2 |\n").map(\.kind) == [.paragraph], "rows join into one paragraph, pipes and all")
    }

    @Test func aMarkerAndItsTextDoNotOverlap() {
        #expect(spans("# **Title**") == ["bold:Title"])
        #expect(spans("- *a*") == ["italic:a"])
        #expect(spans("* * b") == [])
        #expect(MarkdownInline.line("* a").block == .bullet(level: 0))
    }

    @Test func fencedLinesAreNotMarkdown() {
        let inside = MarkdownInline.line("**not** `markdown`", fence: .inside)
        #expect(inside.block == .code)
        #expect(inside.spans.isEmpty)
        #expect(inside.marks.isEmpty)
        let opening = MarkdownInline.line("```swift", fence: .opening)
        #expect(opening.block == .fence)
        #expect(opening.marks == [NSRange(location: 0, length: 8)])
    }

    @Test func plainTextIsWhatAReaderSees() {
        #expect(MarkdownInline.plainText("# **Title** and *more*") == "Title and more")
        #expect(MarkdownInline.plainText("- [x] `code` [[a|b]] [c](d)") == "code b c")
        #expect(MarkdownInline.plainText("nothing here") == "nothing here")
        #expect(MarkdownInline.plainText("\\*escaped\\*") == "*escaped*")
    }

    /// Any input: ranges inside the line, marks never overlapping text.
    @Test func anythingGivesRangesInsideTheLine() {
        var generator = RepeatableGenerator(seed: 42)
        let pieces = ["*", "**", "***", "_", "__", "~~", "`", "``", "[", "]", "[[", "]]", "(", ")", "|", "!", "\\", "# ", "- ", "- [ ] ", "- [x] ", "> ",
                      "1. ", " ", "a", "מילה", "🙂", "https://a.b", "http://", "\u{200F}", "\u{200E}", "שָׁ"]
        for _ in 0..<3_000 {
            var line = ""
            for _ in 0..<Int.random(in: 0...12, using: &generator) { line += pieces.randomElement(using: &generator)! }
            let length = (line as NSString).length
            let parsed = MarkdownInline.line(line)
            for mark in parsed.marks {
                #expect(mark.location >= 0 && NSMaxRange(mark) <= length, "\(line.debugDescription)")
            }
            let sorted = parsed.marks
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                #expect(NSMaxRange(a) <= b.location, "marks overlap in \(line.debugDescription)")
            }
            for span in parsed.spans {
                #expect(span.open.location >= 0 && NSMaxRange(span.close) <= length, "\(line.debugDescription)")
                #expect(span.content.length >= 0, "\(line.debugDescription)")
                #expect(NSMaxRange(span.open) == span.content.location, "\(line.debugDescription)")
                #expect(NSMaxRange(span.content) == span.close.location, "\(line.debugDescription)")
            }
            // Never a crash on what the file names rely on.
            _ = MarkdownInline.plainText(line)
        }
    }
}

@Suite struct FencedCodeTests {
    private func roles(_ text: String) -> [FencedCode.Role] {
        let ns = text as NSString
        let fences = FencedCode(text: ns)
        var out: [FencedCode.Role] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            out.append(fences.role(ofParagraphAt: enclosing.location))
        }
        return out
    }

    @Test func rolesOfEachLine() {
        #expect(roles("a\n```\nb\n```\nc\n") == [.none, .opening, .inside, .closing, .none])
        #expect(roles("```swift\nb\n```") == [.opening, .inside, .closing])
        #expect(roles("~~~\nb\n~~~\n") == [.opening, .inside, .closing])
        #expect(roles("   ```\nb\n     ```\n") == [.opening, .inside, .closing], "the note view closes on any indent")
        #expect(roles("    ```\nb\n") == [.none, .none], "four spaces is no fence")
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(roles("a\n```\nb\nc\n") == [.none, .opening, .inside, .inside])
    }

    @Test func theMarkMustMatch() {
        #expect(roles("```\n~~~\n```\nb\n") == [.opening, .inside, .closing, .none])
        #expect(roles("```\na\n```\n```\nb\n```\n") == [.opening, .inside, .closing, .opening, .inside, .closing])
    }

    @Test func aFenceInCRLF() {
        #expect(roles("a\r\n```\r\nb\r\n```\r\nc\r\n") == [.none, .opening, .inside, .closing, .none])
    }

    @Test func noFences() {
        #expect(roles("just\ntext\n").allSatisfy { $0 == .none })
        #expect(FencedCode(text: "") == FencedCode())
    }

    /// The shortcut: an edit that touches no fence line keeps the map right by moving offsets, with no scan.
    @Test func editsAwayFromAFenceJustMoveIt() {
        let before = "a\n```\nb\n```\nc\n"
        var map = FencedCode(text: before as NSString)
        // Typed in `a`, in the code and in `c`.
        let first = map.textChanged(edited: NSRange(location: 0, length: 3), delta: 3)
        #expect(!first)
        let afterFirst = "xxxa\n```\nb\n```\nc\n" as NSString
        #expect(map == FencedCode(text: afterFirst))
        let inCode = afterFirst.range(of: "b").location
        let second = map.textChanged(edited: NSRange(location: inCode, length: 2), delta: 2)
        #expect(!second)
        let afterSecond = afterFirst.replacingCharacters(in: NSRange(location: inCode, length: 0), with: "yy") as NSString
        #expect(map == FencedCode(text: afterSecond))
        let tail = afterSecond.range(of: "c").location
        let third = map.textChanged(edited: NSRange(location: tail, length: 1), delta: 1)
        #expect(!third)
        #expect(map == FencedCode(text: afterSecond.replacingCharacters(in: NSRange(location: tail, length: 0), with: "z") as NSString))
    }

    @Test func anEditOnAFenceLineSaysSo() {
        let text = "a\n```\nb\n```\nc\n"
        var map = FencedCode(text: text as NSString)
        let opening = map.textChanged(edited: NSRange(location: 3, length: 1), delta: 1)
        #expect(opening, "typing in the opening line")
        map = FencedCode(text: text as NSString)
        let closing = map.textChanged(edited: NSRange(location: 8, length: 1), delta: 1)
        #expect(closing, "typing in the closing line")
        map = FencedCode(text: text as NSString)
        let deleted = map.textChanged(edited: NSRange(location: 2, length: 0), delta: -4)
        #expect(deleted, "a deleted fence line")
        #expect(FencedCode.hasFenceLine("a\n```\nb" as NSString, in: NSRange(location: 3, length: 0)))
        #expect(!FencedCode.hasFenceLine("a\n```\nb" as NSString, in: NSRange(location: 0, length: 1)))
    }

    /// Whatever the edit, the map after a rescan is the truth, and a rescan after a touching edit gives it.
    @Test func randomEditsNeverLeaveTheMapWrong() {
        var generator = RepeatableGenerator(seed: 7)
        let pieces = ["```\n", "~~~\n", "text\n", "\n", "a", "`", "   ```\n", "```swift\n", "\r\n"]
        for _ in 0..<1_500 {
            var text = ""
            for _ in 0..<Int.random(in: 0...8, using: &generator) { text += pieces.randomElement(using: &generator)! }
            var map = FencedCode(text: text as NSString)
            let ns = text as NSString
            let location = Int.random(in: 0...ns.length, using: &generator)
            let length = Int.random(in: 0...(ns.length - location), using: &generator)
            let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
            let inserted = pieces.randomElement(using: &generator)!
            let after = ns.replacingCharacters(in: range, with: inserted) as NSString
            let edited = NSRange(location: range.location, length: (inserted as NSString).length)
            let touched = map.textChanged(edited: edited, delta: edited.length - range.length)
            if !touched, !FencedCode.hasFenceLine(after, in: edited) {
                #expect(map == FencedCode(text: after), "\(text.debugDescription) with \(range) replaced by \(inserted.debugDescription)")
            }
        }
    }
}

/// The same run every time, so a failure can be read and repeated.
private struct RepeatableGenerator: RandomNumberGenerator {
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
