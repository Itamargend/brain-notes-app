import BrainNotesKit
import Testing

/// Which way a paragraph runs, for lines the RTL audit found worth pinning: Markdown around the first Hebrew word,
/// and characters with no direction of their own in front of it.
@Suite struct DirectionAuditTests {
    @Test(arguments: [
        "[[שלום]] world", // a wiki link's brackets are not letters
        "**שלום** world",
        "~~מחוק~~ text",
        "> ציטוט",
        "- **שלום**",
        "1) שלום",
        "2024: סיכום שנה", // a year is not a letter
        "😀 שלום",
        "    שלום",
        "#שלום", // not a heading without the space, but still Hebrew first
        "مرحبا",
    ])
    func rightToLeft(_ paragraph: String) {
        #expect(MarkdownEdits.isRightToLeft(paragraph: paragraph), "\(paragraph)")
        let blocks = MarkdownBlock.parse(paragraph).map { $0.isRightToLeft }
        #expect(blocks == [true], "\(paragraph)")
    }

    @Test(arguments: ["> quote", "- [x] hello", "", "hello שלום"])
    func leftToRight(_ paragraph: String) {
        #expect(!MarkdownEdits.isRightToLeft(paragraph: paragraph), "\(paragraph)")
    }
}
