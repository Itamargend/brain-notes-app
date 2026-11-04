import Foundation
import Testing
@testable import NoteSearch

/// An index over notes given as (id, title, body), all without dates unless set.
func makeIndex(_ notes: [(String, String, String)], dates: [String: Date] = [:]) -> NoteSearchIndex {
    let index = NoteSearchIndex()
    index.upsert(notes.map { NoteSearchDocument(id: $0.0, title: $0.1, body: $0.2, modified: dates[$0.0]) })
    return index
}

/// The text each range covers.
func covered(_ ranges: [Range<Int>], in text: String) -> [String] {
    NoteSearchResult.indexRanges(ranges, in: text).map { String(text[$0]) }
}

@Suite struct EnglishSearchTests {
    @Test func wordsAreFoundInTitleAndBody() {
        let i = makeIndex([("a", "Lentil soup", "Cook the onions first."), ("b", "Bread", "Flour, water, salt.")])
        #expect(i.search("soup").map(\.id) == ["a"])
        #expect(i.search("onions").map(\.id) == ["a"])
        #expect(i.search("salt").map(\.id) == ["b"])
        #expect(i.search("nothinghere").isEmpty)
    }

    @Test func caseAndAccentsDoNotMatter() {
        let i = makeIndex([("a", "Café menu", ""), ("b", "", "cafe\u{301} table"), ("c", "", "LENTILS")])
        #expect(Set(i.search("CAFE").map(\.id)) == ["a", "b"])
        #expect(Set(i.search("café").map(\.id)) == ["a", "b"])
        #expect(i.search("lentils").map(\.id) == ["c"])
    }

    @Test func aWordBeingTypedFindsWholeWords() {
        let i = makeIndex([("a", "", "Cook the onions first.")])
        #expect(i.search("o").map(\.id) == ["a"])
        #expect(i.search("oni").map(\.id) == ["a"])
        #expect(i.search("onionsx").isEmpty)
    }

    @Test func insideAWordNeedsThreeLetters() {
        let i = makeIndex([("a", "", "explanation")])
        #expect(i.search("lan").map(\.id) == ["a"])
        #expect(i.search("la").isEmpty)
        #expect(i.search("x").isEmpty)
    }

    @Test func everyWordIsRequired() {
        let i = makeIndex([("a", "", "alpha beta"), ("b", "", "alpha gamma"), ("c", "Beta", "alpha")])
        #expect(Set(i.search("alpha beta").map(\.id)) == ["a", "c"])
        #expect(i.search("alpha beta gamma").isEmpty)
        #expect(i.search("beta   ALPHA,").count == 2)
    }

    @Test func aRepeatedQueryWordCountsOnce() {
        let i = makeIndex([("a", "", "alpha")])
        #expect(i.search("alpha alpha").map(\.score) == i.search("alpha").map(\.score))
    }

    @Test func emptyAndPunctuationQueriesFindNothing() {
        let i = makeIndex([("a", "x", "y")])
        #expect(i.search("").isEmpty)
        #expect(i.search("   ").isEmpty)
        #expect(i.search("\"*(").isEmpty)
        #expect(i.search("—…!").isEmpty)
    }

    @Test func limitIsRespected() {
        let i = makeIndex((0..<30).map { ("n\($0)", "", "common word") })
        #expect(i.search("common", limit: 7).count == 7)
        #expect(i.search("common").count == 30)
        #expect(i.search("common", limit: 0).isEmpty)
    }
}

@Suite struct RankingTests {
    @Test func titleBeatsBody() {
        let i = makeIndex([("body", "Notes", "garden"), ("title", "Garden", "notes")])
        #expect(i.search("garden").map(\.id) == ["title", "body"])
    }

    @Test func titleBeatsBodyEvenForAWeakerKindOfMatch() {
        let i = makeIndex([("body", "x", "plan"), ("title", "Explanation", "x")])
        #expect(i.search("plan").map(\.id) == ["title", "body"])
    }

    @Test func exactBeatsPrefix() {
        let i = makeIndex([("prefix", "", "planet"), ("exact", "", "plan")])
        #expect(i.search("plan").map(\.id) == ["exact", "prefix"])
    }

    @Test func wordStartBeatsInfix() {
        let i = makeIndex([("infix", "", "explanation"), ("start", "", "planet")])
        #expect(i.search("plan").map(\.id) == ["start", "infix"])
    }

    @Test func newerFirstThenUndatedThenTitle() {
        let d = Date(timeIntervalSince1970: 1_000_000)
        let i = makeIndex([("old", "B", "word"), ("new", "C", "word"), ("none-z", "Z", "word"), ("none-a", "A", "word")],
                          dates: ["old": d, "new": d.addingTimeInterval(60)])
        #expect(i.search("word").map(\.id) == ["new", "old", "none-a", "none-z"])
    }

    @Test func relevanceComesBeforeRecency() {
        let d = Date(timeIntervalSince1970: 1_000_000)
        let i = makeIndex([("old-exact", "", "plan"), ("new-prefix", "", "planet")],
                          dates: ["old-exact": d, "new-prefix": d.addingTimeInterval(1_000)])
        #expect(i.search("plan").map(\.id) == ["old-exact", "new-prefix"])
    }

    @Test func scoresAddUpOverWords() {
        let i = makeIndex([("both-title", "alpha beta", ""), ("one-title", "alpha", "beta"), ("body", "", "alpha beta")])
        #expect(i.search("alpha beta").map(\.id) == ["both-title", "one-title", "body"])
    }

    @Test func sameScoreSameDateFallsBackToTitleThenId() {
        let i = makeIndex([("2", "Same", "word"), ("1", "Same", "word"), ("0", "Other", "word")])
        #expect(i.search("word").map(\.id) == ["0", "1", "2"])
    }
}

@Suite struct HebrewSearchTests {
    @Test func plainHebrew() {
        let i = makeIndex([("a", "מתכון חומוס", "להשרות את הגרגירים לילה שלם"), ("b", "רשימת קניות", "חלב, ביצים, לחם")])
        #expect(i.search("חומוס").map(\.id) == ["a"])
        #expect(i.search("ביצים").map(\.id) == ["b"])
        #expect(i.search("חומוס לילה").map(\.id) == ["a"])
        #expect(i.search("חומוס חלב").isEmpty)
    }

    @Test func pointsOnEitherSide() {
        let i = makeIndex([("pointed", "", "שָׁלוֹם עוֹלָם"), ("plain", "", "שלום לכולם")])
        #expect(Set(i.search("שלום").map(\.id)) == ["pointed", "plain"])
        #expect(Set(i.search("שָׁלוֹם").map(\.id)) == ["pointed", "plain"])
        #expect(i.search("עולם").map(\.id) == ["pointed"])
    }

    @Test func cantillationOnEitherSide() {
        let pointed = "\u{05D1}\u{05BC}\u{05B0}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05C1}\u{05B4}\u{0596}\u{05D9}\u{05EA}"
        let i = makeIndex([("a", "", pointed + " ברא")])
        #expect(i.search("בראשית").map(\.id) == ["a"])
        #expect(i.search(pointed).map(\.id) == ["a"])
    }

    @Test func finalLettersMatchWhileTyping() {
        let i = makeIndex([("a", "", "שלום"), ("b", "", "ארץ ישראל")])
        #expect(i.search("שלו").map(\.id) == ["a"])
        #expect(i.search("שלומ").map(\.id) == ["a"], "a word typed with מ in the middle form")
        #expect(i.search("ארצ").map(\.id) == ["b"])
    }

    @Test func directionMarksAreInvisible() {
        let i = makeIndex([("a", "\u{200F}רשימה\u{200E}", "קנ\u{200F}יות")])
        #expect(i.search("רשימה").map(\.id) == ["a"])
        #expect(i.search("קניות").map(\.id) == ["a"])
        #expect(i.search("\u{200F}קניות").map(\.id) == ["a"])
    }

    @Test func acronymsWithGershayimOrQuotes() {
        let i = makeIndex([("a", "", "שירות בצה״ל"), ("b", "", "המסמך של צה\"ל")])
        #expect(Set(i.search("צה\"ל").map(\.id)) == ["a", "b"])
        #expect(Set(i.search("צהל").map(\.id)) == ["a", "b"])
        #expect(Set(i.search("צה״ל").map(\.id)) == ["a", "b"])
    }

    @Test func prefixLettersOnTheNotesWord() {
        let i = makeIndex([
            ("article", "", "הבית הישן"),
            ("and-in", "", "ובבית שלנו"),
            ("from-the", "", "יצאנו מהבית"),
            ("plain", "", "בית קפה"),
        ])
        #expect(Set(i.search("בית").map(\.id)) == ["article", "and-in", "from-the", "plain"])
        #expect(i.search("בית").first?.id == "plain", "the word itself first")
    }

    @Test func prefixLettersOnTheQuery() {
        let i = makeIndex([("plain", "", "בית קפה"), ("other", "", "ספר")])
        #expect(i.search("הבית").map(\.id) == ["plain"])
        #expect(i.search("ובבית").map(\.id) == ["plain"])
        #expect(i.search("והספר").map(\.id) == ["other"])
    }

    @Test func notOnBothSides() {
        // "שלום" less ש is "לום", and "הלום" less ה is "לום": not the same word.
        let i = makeIndex([("a", "", "הלום קרב"), ("b", "", "לבית")])
        #expect(i.search("שלום").isEmpty)
        #expect(i.search("בבית").isEmpty)
    }

    @Test func prefixLettersAndTyping() {
        let i = makeIndex([("a", "", "להשרות את הגרגירים")])
        #expect(i.search("גרגירים").map(\.id) == ["a"])
        #expect(i.search("גרגיר").map(\.id) == ["a"])
        #expect(i.search("הגרגי").map(\.id) == ["a"])
        #expect(i.search("השרות").map(\.id) == ["a"], "ל off להשרות")
    }

    @Test func shortWordsDoNotExplode() {
        let i = makeIndex([
            ("water", "", "מים"), ("husband", "", "בעל"), ("dog", "", "כלב"), ("white", "", "לבן"),
            ("defence", "", "הגנה"), ("put", "", "שים"),
        ])
        #expect(i.search("ים").isEmpty, "מים and שים are not the sea")
        #expect(i.search("על").isEmpty, "בעל is not 'on'")
        #expect(i.search("לב").map(\.id) == ["white"], "the start of לבן, as when typing; כלב is not a heart")
        #expect(i.search("בן").isEmpty, "לבן is not a son")
        #expect(i.search("גן").isEmpty, "הגנה is not a garden")
    }

    @Test func theArticleBeforeATwoLetterWord() {
        let i = makeIndex([
            ("sea", "", "ירדנו אל הים"), ("from-sea", "", "חזרנו מהים"),
            ("in-garden", "", "בגן"), ("and-the-garden", "", "והגן"),
        ])
        #expect(Set(i.search("ים").map(\.id)) == ["sea", "from-sea"])
        #expect(i.search("הים").count == 2)
        #expect(i.search("גן").map(\.id) == ["and-the-garden"], "after ה two letters may stay, after ב not")
    }

    @Test func rankingInHebrew() {
        let i = makeIndex([
            ("infix", "", "ספרבית"),
            ("prefix", "", "ביתן"),
            ("stripped", "", "הבית"),
            ("exact", "", "בית"),
            ("title", "בית", ""),
        ])
        #expect(i.search("בית").map(\.id) == ["title", "exact", "stripped", "prefix", "infix"])
    }

    @Test func mixedHebrewAndEnglish() {
        let i = makeIndex([("a", "פגישה עם Dana", "agenda: תקציב Q3"), ("b", "Dana", "lunch")])
        #expect(i.search("dana תקציב").map(\.id) == ["a"])
        #expect(i.search("q3").map(\.id) == ["a"])
        #expect(i.search("Dana").map(\.id) == ["b", "a"])
    }
}

@Suite struct HighlightTests {
    @Test func titleMatches() throws {
        let hit = try #require(makeIndex([("a", "Lentil soup", "")]).search("soup").first)
        #expect(hit.titleMatches == [7..<11])
        #expect(covered(hit.titleMatches, in: hit.title) == ["soup"])
    }

    @Test func aPrefixMatchMarksOnlyWhatWasTyped() throws {
        let hit = try #require(makeIndex([("a", "", "the onions")]).search("oni").first)
        #expect(covered(hit.snippetMatches, in: hit.snippet) == ["oni"])
        #expect(hit.bodyMatches == [4..<7])
    }

    @Test func infixIsMarkedWhereItIs() throws {
        let hit = try #require(makeIndex([("a", "", "Lentil")]).search("ntil").first)
        #expect(hit.bodyMatches == [2..<6])
    }

    @Test func pointsStayWithTheirLetters() throws {
        let body = "\u{05E9}\u{05C1}\u{05B8}\u{05DC}\u{05D5}\u{05B9}\u{05DD} \u{05E2}\u{05D5}\u{05B9}\u{05DC}\u{05B8}\u{05DD}"
        let hit = try #require(makeIndex([("a", "", body)]).search("שלו").first)
        #expect(hit.snippet == body)
        #expect(hit.snippetMatches == [0..<6], "ends after the holam, not between ו and its point")
        let whole = try #require(makeIndex([("a", "", body)]).search("שלום").first)
        #expect(whole.bodyMatches == [0..<7])
    }

    @Test func strippedMatchesMarkTheWordWithoutItsPrefix() throws {
        let hit = try #require(makeIndex([("a", "", "ובבית שלנו")]).search("בית").first)
        #expect(covered(hit.bodyMatches, in: "ובבית שלנו") == ["בית"])
        let fromQuery = try #require(makeIndex([("a", "", "בית קפה")]).search("ובבית").first)
        #expect(covered(fromQuery.bodyMatches, in: "בית קפה") == ["בית"])
    }

    @Test func directionMarksAroundAWordAreNotMarked() throws {
        let body = "x \u{200F}שלום\u{200E} y"
        let hit = try #require(makeIndex([("a", "", body)]).search("שלום").first)
        #expect(covered(hit.bodyMatches, in: body) == ["שלום"])
    }

    @Test func everyMatchOfEveryWord() throws {
        let body = "alpha beta alpha gamma"
        let hit = try #require(makeIndex([("a", "", body)]).search("alpha gam").first)
        #expect(covered(hit.bodyMatches, in: body) == ["alpha", "alpha", "gam"])
    }

    @Test func overlappingMatchesMerge() throws {
        let hit = try #require(makeIndex([("a", "", "planet")]).search("plan plane").first)
        #expect(hit.bodyMatches == [0..<5])
    }

    @Test func rangesWorkAsNSRange() throws {
        let body = "😀 שלום world"
        let hit = try #require(makeIndex([("a", "", body)]).search("world").first)
        let r = try #require(hit.bodyMatches.first)
        #expect((body as NSString).substring(with: NSRange(location: r.lowerBound, length: r.count)) == "world")
    }
}

@Suite struct SnippetTests {
    private func filler(_ n: Int) -> String {
        (0..<n).map { "filler\($0)" }.joined(separator: " ")
    }

    @Test func aShortBodyIsTheSnippet() throws {
        let hit = try #require(makeIndex([("a", "", "one two three")]).search("two").first)
        #expect(hit.snippet == "one two three")
        #expect(covered(hit.snippetMatches, in: hit.snippet) == ["two"])
    }

    @Test func aLongBodyIsCutAroundTheMatch() throws {
        let body = filler(60) + " needle " + filler(60)
        let hit = try #require(makeIndex([("a", "", body)]).search("needle").first)
        #expect(hit.snippet.hasPrefix("…"))
        #expect(hit.snippet.hasSuffix("…"))
        #expect(hit.snippet.utf16.count <= 200)
        #expect(covered(hit.snippetMatches, in: hit.snippet) == ["needle"])
        // Cut between words.
        let inner = hit.snippet.dropFirst().dropLast()
        #expect(inner.hasPrefix("filler"))
        #expect(inner.last?.isNumber == true)
    }

    @Test func theBestMatchIsChosenNotTheFirst() throws {
        let body = "planet " + filler(80) + " plan " + filler(10)
        let hit = try #require(makeIndex([("a", "", body)]).search("plan").first)
        #expect(hit.snippet.hasPrefix("…"))
        #expect(covered(hit.snippetMatches, in: hit.snippet) == ["plan"])
        #expect(hit.bodyMatches.count == 2)
    }

    @Test func aTitleOnlyMatchShowsTheStartOfTheBody() throws {
        let hit = try #require(makeIndex([("a", "Needle", filler(80))]).search("needle").first)
        #expect(hit.snippet.hasPrefix("filler0 filler1"))
        #expect(hit.snippet.hasSuffix("…"))
        #expect(hit.snippetMatches.isEmpty)
        #expect(hit.titleMatches == [0..<6])
    }

    @Test func lineBreaksShowAsSpaces() throws {
        let hit = try #require(makeIndex([("a", "", "first line\nsecond\r\nthird")]).search("second").first)
        #expect(hit.snippet == "first line second  third")
        #expect(covered(hit.snippetMatches, in: hit.snippet) == ["second"])
    }

    @Test func neverCutsAPairOrAPoint() throws {
        // No spaces to cut at: emoji and pointed letters all the way.
        let pointed = String(repeating: "\u{05E9}\u{05C1}\u{05B8}", count: 60)
        let emoji = String(repeating: "😀", count: 60)
        for body in [emoji + " מילה " + emoji, pointed + " מילה " + pointed] {
            let hit = try #require(makeIndex([("a", "", body)]).search("מילה").first)
            #expect(!hit.snippet.contains("\u{FFFD}"))
            #expect(hit.snippet.unicodeScalars.first?.properties.generalCategory != .nonspacingMark)
            let afterEllipsis = hit.snippet.unicodeScalars.dropFirst().first
            #expect(afterEllipsis?.properties.generalCategory != .nonspacingMark)
            #expect(covered(hit.snippetMatches, in: hit.snippet) == ["מילה"])
        }
    }

    @Test func hebrewSnippet() throws {
        let body = String(repeating: "שורה ארוכה בעברית ", count: 12) + "ובירושלים פגשנו " + String(repeating: "עוד מילים ", count: 20)
        let hit = try #require(makeIndex([("a", "", body)]).search("ירושלים").first)
        #expect(covered(hit.snippetMatches, in: hit.snippet) == ["ירושלים"])
        #expect(hit.snippet.hasPrefix("…"))
    }
}

@Suite struct IncrementalTests {
    @Test func addChangeDelete() {
        let i = NoteSearchIndex()
        i.upsert(NoteSearchDocument(id: "a", title: "One", body: "first"))
        #expect(i.count == 1)
        #expect(i.search("first").map(\.id) == ["a"])

        i.upsert(NoteSearchDocument(id: "a", title: "Two", body: "second"))
        #expect(i.count == 1)
        #expect(i.search("first").isEmpty)
        #expect(i.search("one").isEmpty)
        #expect(i.search("second").map(\.id) == ["a"])
        #expect(i.search("two").first?.title == "Two")

        i.remove(id: "a")
        #expect(i.count == 0)
        #expect(!i.contains(id: "a"))
        #expect(i.search("second").isEmpty)
        i.remove(id: "a")
        #expect(i.count == 0)
    }

    @Test func aRenameIsRemoveAndAdd() {
        let i = makeIndex([("old/name.md", "Name", "body text")])
        i.remove(id: "old/name.md")
        i.upsert(NoteSearchDocument(id: "new/name.md", title: "Name", body: "body text"))
        #expect(i.search("body").map(\.id) == ["new/name.md"])
    }

    @Test func otherNotesAreUntouched() {
        let i = makeIndex([("a", "", "shared alpha"), ("b", "", "shared beta")])
        i.upsert(NoteSearchDocument(id: "a", title: "", body: "shared gamma"))
        #expect(Set(i.search("shared").map(\.id)) == ["a", "b"])
        #expect(i.search("beta").map(\.id) == ["b"])
        i.remove(id: "b")
        #expect(i.search("shared").map(\.id) == ["a"])
    }

    @Test func aChangedDateChangesTheOrder() {
        let d = Date(timeIntervalSince1970: 1_000_000)
        let i = makeIndex([("a", "", "word"), ("b", "", "word")], dates: ["a": d, "b": d.addingTimeInterval(1)])
        #expect(i.search("word").map(\.id) == ["b", "a"])
        i.upsert(NoteSearchDocument(id: "a", title: "", body: "word", modified: d.addingTimeInterval(2)))
        #expect(i.search("word").map(\.id) == ["a", "b"])
    }

    @Test func removeAllEmpties() {
        let i = makeIndex([("a", "", "x y z"), ("b", "", "x")])
        i.removeAll()
        #expect(i.count == 0)
        #expect(i.search("x").isEmpty)
        i.upsert(NoteSearchDocument(id: "c", title: "", body: "x"))
        #expect(i.search("x").map(\.id) == ["c"])
    }

    @Test func slotsOfDeletedNotesAreReused() {
        let i = NoteSearchIndex()
        for round in 0..<5 {
            for n in 0..<20 { i.upsert(NoteSearchDocument(id: "r\(round)-\(n)", title: "", body: "round\(round) common")) }
            for n in 0..<20 where round < 4 { i.remove(id: "r\(round)-\(n)") }
        }
        #expect(i.count == 20)
        #expect(i.search("common").count == 20)
        #expect(i.search("round4").count == 20)
        #expect(i.search("round3").isEmpty)
    }

    /// Enough churn to make the index drop dead words from its table; search must not notice.
    @Test func compactionKeepsResultsRight() {
        let i = NoteSearchIndex()
        for n in 0..<50 { i.upsert(NoteSearchDocument(id: "keep\(n)", title: "Keep \(n)", body: "stable words here הבית")) }
        for round in 0..<6 {
            let body = (0..<1000).map { "w\(round)x\($0)" }.joined(separator: " ")
            i.upsert(NoteSearchDocument(id: "churn", title: "", body: body))
        }
        #expect(i.count == 51)
        #expect(i.search("stable").count == 50)
        #expect(i.search("בית").count == 50)
        #expect(i.search("keep 7").first?.id == "keep7")
        #expect(i.search("w5x999").map(\.id) == ["churn"])
        #expect(i.search("w0x1").isEmpty)
        i.remove(id: "churn")
        #expect(i.search("w5x").isEmpty)
    }

    @Test func manyThreadsAtOnce() async {
        let i = NoteSearchIndex()
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for n in 0..<100 {
                        i.upsert(NoteSearchDocument(id: "t\(t)-\(n)", title: "Task \(t)", body: "שלום body \(n)"))
                        _ = i.search("שלום")
                        if n % 3 == 0 { i.remove(id: "t\(t)-\(n)") }
                    }
                }
            }
        }
        #expect(i.count == 8 * 66)
        #expect(i.search("body").count == 8 * 66)
    }
}
