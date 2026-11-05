import Testing
@testable import BrainNotesKit

/// What counts as a wiki link, what each part is, and where it is in bytes.
@Suite struct WikiLinksTests {
    /// Each link written back as `!name#heading|alias`, so a test reads like the note.
    private func links(_ text: String) -> [String] {
        WikiLinks.parse(text).map { link in
            var out = link.isEmbed ? "!" : ""
            out += link.name
            if let heading = link.heading { out += "#" + heading }
            if let alias = link.alias { out += "|" + alias }
            return out
        }
    }

    // MARK: parts

    @Test func namesInEnglishAndHebrew() {
        #expect(links("see [[Other note]] and [[פתק אחר]].") == ["Other note", "פתק אחר"])
        #expect(links("[[a]][[b]]") == ["a", "b"])
        #expect(links("- [ ] call about [[Kela]]") == ["Kela"])
        #expect(links("# [[Heading link]]") == ["Heading link"])
        #expect(links("> quoted [[q]]") == ["q"])
    }

    @Test func aliasesAndHeadings() {
        #expect(links("[[Note|shown text]]") == ["Note|shown text"])
        #expect(links("[[Note#Heading]]") == ["Note#Heading"])
        #expect(links("[[Note#Heading|shown]]") == ["Note#Heading|shown"])
        #expect(links("[[Note#^block-1]]") == ["Note#^block-1"])
        #expect(links("[[Note#Top#Sub]]") == ["Note#Top#Sub"], "only the first # splits")
        #expect(links("[[a|b|c]]") == ["a|b|c"], "only the first | splits")
        #expect(links("[[#Local heading]]") == ["#Local heading"], "a link into the same note has no name")
        #expect(WikiLinks.parse("[[#Local]]").first?.name == "")
    }

    @Test func hebrewPartsAndDirectionMarks() {
        #expect(links("ראו [[פרויקטים/מגן#רקע|כאן]] בבקשה") == ["פרויקטים/מגן#רקע|כאן"])
        // A Hebrew keyboard can leave direction marks at a name's ends; they are not part of the name.
        let marked = "[[\u{200F}שלום\u{200F}]]"
        let link = WikiLinks.parse(marked)[0]
        #expect(link.name == "שלום")
        #expect(utf8Slice(marked, link.nameRange) == "שלום")
        // Points stay exactly as written.
        #expect(links("[[בַּיִת]]") == ["בַּיִת"])
    }

    @Test func spacesAndExtensionAreNotInTheName() {
        let text = "[[  Note.md  |x]]"
        let link = WikiLinks.parse(text)[0]
        #expect(link.name == "Note")
        #expect(utf8Slice(text, link.nameRange) == "Note")
        #expect(links("[[Note.MD]]") == ["Note"])
        #expect(links("[[Plan.md#Goals]]") == ["Plan#Goals"])
        #expect(links("[[.md]]") == [".md"], "an extension with no name stays the name")
        #expect(links("[[notes.mdx]]") == ["notes.mdx"])
    }

    @Test func embeds() {
        let text = "![[Diagram]] and \\![[Plain]]"
        let found = WikiLinks.parse(text)
        #expect(found.map(\.isEmbed) == [true, false])
        #expect(utf8Slice(text, found[0].range) == "[[Diagram]]", "the ! is not in the range")
    }

    @Test func tableEscapedPipe() {
        let text = "| [[Note\\|alias]] | other |"
        let link = WikiLinks.parse(text)[0]
        #expect(link.name == "Note")
        #expect(link.alias == "alias")
        #expect(utf8Slice(text, link.nameRange) == "Note")
        #expect(utf8Slice(text, link.range) == "[[Note\\|alias]]")
    }

    // MARK: not links

    @Test func brokenOrEmptyLinksAreText() {
        for text in ["[[]]", "[[a", "[[a]", "[[a] ]", "[[a [b] c]]", "[[|alias]]", "[[a|]]", "[[a\nb]]", "[[a\r\nb]]",
                     "[ [a]]", "\\[[x]]"] {
            #expect(links(text).isEmpty, "\(text.debugDescription)")
        }
    }

    @Test func lineAndNextLineSeparatorsDoNotEndAParagraph() {
        // NSString's `.byParagraphs` (the editor) breaks at LF, CR, CRLF and U+2029 only.
        #expect(links("[[a\u{2028}b]]") == ["a\u{2028}b"])
        #expect(links("[[a\u{0085}b]]") == ["a\u{0085}b"])
        #expect(links("[[a\u{2029}b]]").isEmpty)
    }

    @Test func inlineCodeHidesLinks() {
        #expect(links("`[[x]]` [[y]]") == ["y"])
        #expect(links("``a `[[x]]` b`` [[y]]") == ["y"])
        #expect(links("a ` [[y]]") == ["y"], "a backtick that closes nothing is text")
        #expect(links("`a` [[y]] `b`") == ["y"])
        #expect(links("`code`\n[[next line]]") == ["next line"], "a code span ends with its line")
    }

    @Test func fencedCodeHidesLinks() {
        let text = """
            before [[a]]
            ```swift
            [[b]]
            ```
            ~~~
            [[c]]
            ~~~
               ```
            [[d]]
                  ```
            [[e]]
                ```
            [[f]]
            """
        #expect(links(text) == ["a", "e", "f"], "three spaces open a fence, four don't; a closing one can be indented")
        #expect(links("```\n~~~\n[[x]]\n```\n[[y]]") == ["y"], "only the opening's own characters close it")
        #expect(links("```\n[[x]]") == [], "an unclosed fence runs to the end")
        #expect(links("```\r\n[[x]]\r\n```\r\n[[y]]") == ["y"])
        #expect(links("```[[x]]```\n[[y]]") == [], "a fence line is code too, and this one stays open")
    }

    @Test func urlsAndLinkDestinationsHideLinks() {
        #expect(links("https://example.com/[[x]] [[y]]") == ["y"])
        #expect(links("[text](https://e.com/[[x]]) [[y]]") == ["y"])
        #expect(links("![alt](img/[[x]].png) [[y]]") == ["y"])
        #expect(links("[see [[x]]](url)") == ["x"], "the editor shows this one as a wiki link")
    }

    // MARK: positions

    @Test func offsetsAreUTF8Bytes() {
        let text = "אב [[גד|הו]]"
        let link = WikiLinks.parse(text)[0]
        #expect(link.range == 5..<18)
        #expect(link.nameRange == 7..<11)
        let emoji = "😀 [[x]]"
        #expect(WikiLinks.parse(emoji)[0].range == 5..<10)
    }

    /// `NSString`'s paragraphs, which the editor styles one at a time, do not end at U+2028 or U+0085, so neither
    /// does a link's line. Found by `LinksEditorAgreementTests` on its first run.
    @Test func lineAndNextLineSeparatorsAreNotParagraphBreaks() {
        let found = WikiLinks.parse("[[a\u{2028}b]] [[c]]\u{2029}[[d]]\u{85}[[e]]")
        #expect(found.map(\.name) == ["a\u{2028}b", "c", "d", "e"])
        #expect(found.map(\.line) == [0, 0, 1, 1])
        #expect(BacklinkIndex.lines(of: "x\u{2028}y\u{2029}z") == ["x\u{2028}y", "z"])
    }

    @Test func lineNumbersCountEveryKindOfBreak() {
        let text = "a\r\n[[x]]\r\n\r\n[[y]]\n[[z]]\r[[w]]\u{2029}[[v]]"
        #expect(WikiLinks.parse(text).map(\.line) == [1, 3, 4, 5, 6])
    }

    // MARK: edits

    @Test func editsChangeOnlyTheirBytes() {
        let text = "\u{FEFF}[[a]]\r\nשלום [[b]]\r\n"
        let found = WikiLinks.parse(text)
        let edited = TextEdit.apply([TextEdit(range: found[1].nameRange, replacement: "בית"),
                                     TextEdit(range: found[0].nameRange, replacement: "aa")], to: text)
        #expect(edited == "\u{FEFF}[[aa]]\r\nשלום [[בית]]\r\n")
        #expect(Array(edited.utf8).prefix(3) == [0xEF, 0xBB, 0xBF])
        #expect(TextEdit.apply([], to: text) == text)
    }

    @Test func decomposedTextKeepsItsForm() {
        // Swift calls these equal, so compare bytes: an edit elsewhere must not compose the é.
        let text = "Cafe\u{301} [[a]]"
        let edited = TextEdit.apply([TextEdit(range: WikiLinks.parse(text)[0].nameRange, replacement: "b")], to: text)
        #expect(Array(edited.utf8) == Array("Cafe\u{301} [[b]]".utf8))
    }
}

func utf8Slice(_ text: String, _ range: Range<Int>) -> String {
    String(decoding: Array(text.utf8)[range], as: UTF8.self)
}
