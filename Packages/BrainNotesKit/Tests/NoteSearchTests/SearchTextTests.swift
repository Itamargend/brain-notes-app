import Testing
@testable import NoteSearch

@Suite struct SearchTextTests {
    private func n(_ s: String) -> String { SearchText.normalize(s) }

    // MARK: Hebrew

    @Test func pointsAreDropped() {
        #expect(n("שָׁלוֹם") == n("שלום"))
        #expect(n("\u{05E9}\u{05C1}\u{05B8}\u{05DC}\u{05D5}\u{05B9}\u{05DD}") == "שלומ")
        // Dagesh, shva, sin dot, rafe, qamats qatan.
        #expect(n("\u{05D1}\u{05BC}\u{05B0}\u{05E9}\u{05C2}\u{05BF}\u{05DB}\u{05C7}") == "בשכ")
    }

    @Test func cantillationIsDropped() {
        // בְּרֵאשִׁ֖ית with a tipcha.
        let bereshit = "\u{05D1}\u{05BC}\u{05B0}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05C1}\u{05B4}\u{0596}\u{05D9}\u{05EA}"
        #expect(n(bereshit) == "בראשית")
        // Etnachta and sof pasuq: the first is a mark, the second ends the verse like a full stop.
        #expect(n("\u{05D0}\u{05E8}\u{0591}\u{05E5}\u{05C3}\u{05D5}") == "ארצ ו")
    }

    @Test func finalLettersFoldToBase() {
        #expect(n("ך ם ן ף ץ") == "כ מ נ פ צ")
        #expect(n("שלום") == n("שלומ"))
        #expect(n("ארץ") == "ארצ")
        #expect(n("כנף") == "כנפ")
        #expect(n("דרך") == "דרכ")
        #expect(n("גן") == "גנ")
    }

    @Test func directionMarksAreDropped() {
        #expect(n("\u{200F}שלום\u{200E}") == "שלומ")
        #expect(n("של\u{200F}ום") == "שלומ", "a mark inside a word does not split it")
        #expect(n("\u{2067}abc\u{2069} \u{202B}def\u{202C}") == "abc def")
        #expect(n("\u{061C}x\u{200D}y\u{FEFF}") == "xy")
        #expect(n("\u{200F}\u{200E}").isEmpty)
    }

    @Test func maqafAndPunctuationSplitWords() {
        #expect(n("בית־ספר") == "בית ספר")
        #expect(n("שלום, עולם! (בדיקה)") == "שלומ עולמ בדיקה")
        #expect(n("א.ב") == "א ב")
    }

    @Test func gereshAndGershayimJoin() {
        #expect(n("צה״ל") == "צהל")
        #expect(n("צה\"ל") == "צהל")
        #expect(n("צה”ל") == "צהל")
        #expect(n("ג׳ירפה") == "גירפה")
        #expect(n("ג'ירפה") == "גירפה")
        // Not followed by a letter: they end the word.
        #expect(n("\"ציטוט\"") == "ציטוט")
        #expect(n("ש׳ ב") == "ש ב")
    }

    @Test func presentationFormsFold() {
        // שׁ and וֹ as single presentation-form characters.
        #expect(n("\u{FB2A}לו\u{FB4B}ם") == n("שלוום"))
    }

    // MARK: Latin and others

    @Test func latinIsCaseFolded() {
        #expect(n("Hello WORLD") == "hello world")
        #expect(n("iPhone") == "iphone")
    }

    @Test func accentsAreDropped() {
        #expect(n("Caf\u{E9}") == "cafe")
        #expect(n("Cafe\u{301}") == "cafe")
        #expect(n("ÉCOLE Ñandú") == "ecole nandu")
    }

    @Test func otherCasedScripts() {
        #expect(n("ΣΟΦΙΑ") == n("σοφια"))
        #expect(n("МОСКВА") == "москва")
    }

    @Test func apostrophesJoinEnglishWords() {
        #expect(n("don't") == "dont")
        #expect(n("Itamar’s notes") == "itamars notes")
        #expect(n("'quoted' word'") == "quoted word")
    }

    @Test func digitsAreWordCharacters() {
        #expect(n("topic42 2026-11-04") == "topic42 2026 11 04")
        #expect(n("ב-2026") == "ב 2026")
    }

    @Test func symbolsAndEmojiSeparate() {
        #expect(n("a😀b") == "a b")
        #expect(n("**bold** _x_ [[link]] #tag") == "bold x link tag")
        #expect(n("").isEmpty)
        #expect(n("  \n\t ").isEmpty)
    }

    // MARK: ranges

    @Test func rangesPointIntoTheOriginal() {
        let text = "\u{200F}\u{05E9}\u{05C1}\u{05B8}\u{05DC}\u{05D5}\u{05B9}\u{05DD} world"
        let words = SearchText.words(in: text)
        #expect(words.map(\.folded) == ["שלומ", "world"])
        #expect(words.map(\.range) == [1..<8, 9..<14])
    }

    @Test func rangesCountSurrogatePairsAsTwo() {
        let text = "😀abc 𝒳yz"
        let words = SearchText.words(in: text)
        #expect(words.map(\.range) == [2..<5, 6..<10])
        #expect(words.map(\.folded) == ["abc", "𝒳yz"])
    }

    @Test func tokenSpansKeepPointsWithTheirLetter() throws {
        // ש + shin dot + qamats, ל, ו + holam, ם
        let text = "\u{05E9}\u{05C1}\u{05B8}\u{05DC}\u{05D5}\u{05B9}\u{05DD}"
        let token = try #require(SearchText.tokens(text, offsets: true).first)
        #expect(token.starts == [0, 3, 4, 6])
        #expect(token.ends == [3, 4, 6, 7])
        #expect(token.sourceRange(0, 3) == 0..<6)
        #expect(token.sourceRange(1, 2) == 3..<6)
    }

    @Test func aJoinerIsInsideTheRangeButNotTheWord() throws {
        let token = try #require(SearchText.tokens("x צה״ל.", offsets: true).last)
        #expect(String(decoding: token.bytes, as: UTF8.self) == "צהל")
        #expect(token.start == 2)
        #expect(token.end == 6)
    }

    // MARK: prefix letters

    private func stems(_ word: String) -> [String] {
        let bytes = Array(SearchText.normalize(word).utf8)
        return SearchText.stems(bytes, scalars: SearchText.scalarCount(bytes))
            .map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    /// Stems are folded, so "ים" comes back as "ימ".
    private func folded(_ words: [String]) -> [String] { words.map(n) }

    @Test func oneOrTwoPrefixLettersComeOff() {
        #expect(stems("הבית") == folded(["בית"]))
        #expect(stems("ובבית") == folded(["בבית", "בית"]))
        #expect(stems("שבירושלים") == folded(["בירושלים", "ירושלים"]))
        #expect(stems("כשהגענו") == folded(["שהגענו", "הגענו"]))
        #expect(stems("מהשוק") == folded(["השוק", "שוק"]))
    }

    @Test func atMostTwoComeOff() {
        #expect(stems("ושבהבית") == folded(["שבהבית", "בהבית"]))
    }

    @Test func threeLettersMustStay() {
        #expect(stems("בית").isEmpty, "ב then ית")
        #expect(stems("מים").isEmpty, "מ then ים")
        #expect(stems("כלב").isEmpty, "כ then לב")
        #expect(stems("בעל").isEmpty, "ב then על")
        #expect(stems("שמש").isEmpty, "ש then מש")
        #expect(stems("ולבן") == folded(["לבן"]), "not on to בן")
        #expect(stems("של").isEmpty)
        #expect(stems("ו").isEmpty)
    }

    @Test func afterTheArticleTwoMayStay() {
        #expect(stems("הים") == folded(["ים"]))
        #expect(stems("ההר") == folded(["הר"]))
        #expect(stems("מהים") == folded(["הים", "ים"]))
        #expect(stems("הם").isEmpty)
    }

    @Test func onlyHebrewPrefixLettersComeOff() {
        #expect(stems("דבר").isEmpty)
        #expect(stems("abcd").isEmpty)
        #expect(stems("ב2026") == folded(["2026"]))
    }
}
