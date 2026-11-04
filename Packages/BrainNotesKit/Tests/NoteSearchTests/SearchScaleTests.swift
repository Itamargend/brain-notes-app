import Foundation
import Testing
@testable import NoteSearch

/// 2,000 synthetic notes of about 2 KB, half Hebrew, half English: build the index, query it, change some
/// notes and query again. The budgets are generous on purpose: a debug build on a shared CPU only has to
/// stay in the right order of magnitude. Timings print as `SCALE`.
@Suite(.serialized) struct SearchScaleTests {
    /// A small fixed random generator, so every run indexes the same text.
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static let hebrewSyllables = ["של", "בר", "מו", "דב", "קר", "נת", "פא", "גל", "עמ", "רו", "תא", "זה", "חק",
                                  "סף", "צו", "יש", "אור", "כה", "לא", "נע", "שמ", "רח", "טב", "עצ", "פר"]
    static let finals = ["", "", "", "ם", "ן", "ך", "ף", "ץ", "ה", "ים", "ות"]
    static let prefixes = ["", "", "", "", "ה", "ו", "ב", "ל", "מ", "ש", "וה", "שב", "כש", "ומ"]
    static let englishSyllables = ["con", "ver", "sa", "tion", "plan", "et", "mar", "ket", "stra", "te", "gy",
                                   "de", "sign", "note", "book", "read", "ing", "pro", "ject", "time", "ly"]
    static let niqqud: [Character] = ["\u{05B8}", "\u{05B4}", "\u{05BC}", "\u{05B0}"]

    static func word(_ g: inout Generator) -> String {
        var w = ""
        if g.next(2) == 0 {
            w += prefixes[g.next(prefixes.count)]
            for _ in 0..<(2 + g.next(2)) { w += hebrewSyllables[g.next(hebrewSyllables.count)] }
            w += finals[g.next(finals.count)]
            if g.next(20) == 0 { w.insert(niqqud[g.next(niqqud.count)], at: w.index(after: w.startIndex)) }
        } else {
            for _ in 0..<(1 + g.next(3)) { w += englishSyllables[g.next(englishSyllables.count)] }
            if g.next(8) == 0 { w = w.capitalized }
        }
        return w
    }

    /// Note `n` mentions "בירושלים" when n is a multiple of 50 (40 notes) and "zephyr" when n % 100 == 7
    /// (20 notes). The syllables can't spell either: no syllable ends in י, none starts with ר after one,
    /// and there is no z.
    static func notes() -> [NoteSearchDocument] {
        var g = Generator(state: 42)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var out: [NoteSearchDocument] = []
        for n in 0..<2000 {
            let title = "Note \(n) " + word(&g) + " " + word(&g)
            var body = ""
            while body.utf8.count < 2048 { body += word(&g) + (g.next(12) == 0 ? ".\n" : " ") }
            if n % 50 == 0 { body += " נסענו בירושלים" }
            if n % 100 == 7 { body += " a zephyr passed" }
            out.append(NoteSearchDocument(id: "folder\(n % 40)/note-\(n).md", title: title, body: body,
                                          modified: base.addingTimeInterval(Double(n) * 60)))
        }
        return out
    }

    private func timed<T>(_ label: String, limit: Duration, _ body: () -> T) -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = body()
        let elapsed = clock.now - start
        print("SCALE \(label): \(elapsed)")
        #expect(elapsed < limit, "\(label) took \(elapsed)")
        return value
    }

    @Test func twoThousandNotes() {
        let notes = Self.notes()
        let bytes = notes.reduce(0) { $0 + $1.body.utf8.count }
        #expect(bytes > 2000 * 2048)
        #expect(bytes < 2000 * 2200)

        let index = NoteSearchIndex()
        timed("build 2,000 notes", limit: .seconds(30)) { index.upsert(notes) }
        #expect(index.count == 2000)

        let seeded = Set(notes.indices.filter { $0 % 50 == 0 }.map { notes[$0].id })
        let jerusalem = timed("query ירושלים", limit: .seconds(1)) { index.search("ירושלים", limit: 2000) }
        #expect(Set(jerusalem.map(\.id)) == seeded, "found through the ב in front")

        let zephyr = timed("query zephyr", limit: .seconds(1)) { index.search("zephyr") }
        #expect(zephyr.count == 20)
        #expect(zephyr.first?.id == "folder27/note-1907.md", "newest first among equals")

        // A spread of query shapes: one letter, two letters, prefixes, two words, nothing found.
        let queries = ["a", "ש", "של", "plan", "market strategy", "הבית", "שמור", "תיר", "Note 1999", "pro ject",
                       "לישרח", "notebook", "קר נת", "nothingmatchesthis", "בָּרָא", "ing", "zephyr נסענו"]
        var total = Duration.zero
        for q in queries {
            let clock = ContinuousClock()
            let start = clock.now
            let hits = index.search(q)
            let elapsed = clock.now - start
            total += elapsed
            print("SCALE query \(q): \(hits.count) hits, \(elapsed)")
            #expect(elapsed < .seconds(1), "\(q) took \(elapsed)")
        }
        #expect(total < .seconds(5), "\(queries.count) queries took \(total)")
        #expect(index.search("Note 1999").first?.id == "folder39/note-1999.md")
        #expect(index.search("nothingmatchesthis").isEmpty)

        // Incremental: change 100 notes and delete 100, then the index answers for the new text only.
        timed("change 100 and delete 100", limit: .seconds(3)) {
            for n in 0..<100 {
                var d = notes[n * 20]
                d.body += " kumquat"
                index.upsert(d)
                index.remove(id: notes[n * 20 + 1].id)
            }
        }
        #expect(index.count == 1900)
        let kumquat = timed("query after changes", limit: .seconds(1)) { index.search("kumquat", limit: 200) }
        #expect(kumquat.count == 100)
        #expect(index.search("zephyr").count == 20, "n % 100 == 7 is never n * 20 + 1")
    }
}
