import Foundation
import Testing
@testable import BrainNotesKit

/// `WikiLinks` (standard library only, so it runs on Linux) and the editor's styler (`MarkdownInline`, `FencedCode`)
/// must agree on which text is a link: a link the editor shows is a backlink and gets renamed, and nothing else does.
/// Here, not in `Links/`, because the styler needs Foundation's `NSString`.
@Suite struct LinksEditorAgreementTests {
    /// Each wiki link the editor shows, as its text from `[[` to `]]`.
    private func editorLinks(_ text: String) -> [String] {
        let ns = text as NSString
        let fences = FencedCode(text: ns)
        var out: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            let line = ns.substring(with: paragraph) as NSString
            let styled = MarkdownInline.line(line as String, fence: fences.role(ofParagraphAt: paragraph.location))
            for span in styled.spans {
                if case .wikiLink = span.kind { out.append(line.substring(with: span.whole)) }
            }
        }
        return out
    }

    private func kitLinks(_ text: String) -> [String] {
        WikiLinks.parse(text).map { utf8Slice(text, $0.range) }
    }

    @Test func handPickedCases() {
        let cases = [
            "see [[Other note]] and [[פתק אחר]].", "[[a|b]] [[a#h|b]] [[#h]] ![[e]]", "- [ ] [[task]]", "- [x](u) [[y]]",
            "`[[x]]` [[y]]", "``a `[[x]]` b`` [[y]]", "a ` [[y]]", "\\[[x]] \\![[y]]", "[[a [b] c]]", "[[|a]] [[a|]] [[]]",
            "https://e.com/[[x]] [[y]]", "x https://e.com/[[x]]. [[y]]", "[t](https://e/[[x]]) [[y]]", "![a](b/[[x]]) [[y]]",
            "[see [[x]]](url)", "| [[Note\\|alias]] | b |", "[[\u{200F}שלום\u{200F}]]", "😀 [[x]] 😀https://e/[[y]]",
            "before [[a]]\n```swift\n[[b]]\n```\n[[c]]", "~~~\n[[x]]\n```\n~~~\n[[y]]", "   ```\n[[x]]\n      ```\n[[y]]",
            "    ```\n[[x]]", "```\r\n[[x]]\r\n```\r\n[[y]]", "```[[x]]```\n[[y]]", "[[a\u{2028}b]] [[c]]\u{2029}[[d]]",
            "[[a\u{0085}b]] ```\u{2028}[[c]]", "```\u{0085}x\n[[y]]",
            "**[[bold link]]** _[[it]]_", "# [[h]]\n> [[q]]\n1. [[n]]",
        ]
        for text in cases {
            #expect(kitLinks(text) == editorLinks(text), "\(text.debugDescription)")
        }
    }

    @Test(arguments: 0..<300) func randomText(seed: Int) {
        var rng = LinksGenerator(seed: UInt64(seed) &+ 7)
        let pieces = ["[[", "]]", "[", "]", "|", "#", "!", "\\", "`", "``", "(", ")", "https://e.org/", "h", "a", "פתק", " ",
                      "\n", "\r\n", "\r", "```\n", "~~~\n", "   ```\n", "    ```\n", "- [ ] ", "* ", "\u{200F}", ".md", "😀", "\u{2028}", "\u{0085}", "\u{2029}"]
        let text = (0..<Int.random(in: 1...40, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
        #expect(kitLinks(text) == editorLinks(text), "\(text.debugDescription)")
    }
}
