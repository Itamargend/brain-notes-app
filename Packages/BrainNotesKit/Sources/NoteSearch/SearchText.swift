import Foundation

/// How search sees text. Words are folded so that differences a reader doesn't notice never stop a match:
///
/// - Hebrew points and cantillation marks are dropped, so "שָׁלוֹם" is "שלום".
/// - Final letters become their base letter (ך ם ן ף ץ become כ מ נ פ צ), so a word typed halfway still
///   matches the whole word: "שלו" finds "שלום".
/// - Direction marks and other invisible format characters are dropped, also in the middle of a word.
/// - Latin and other cased scripts are lowercased and lose their accents, so "Café" is "cafe".
/// - Geresh and gershayim, and the quote marks people type in their place, are dropped when a letter
///   follows, so "צה״ל" and "צה"ל" are both "צהל" and "don't" is "dont".
///
/// Everything else that isn't a letter or a digit separates words. Ranges are UTF-16 offsets into the
/// original text, which is what NSRange, TextKit and `String.Index(utf16Offset:in:)` take.
public enum SearchText {
    /// One word as search sees it.
    public struct Word: Sendable, Equatable {
        /// The folded word.
        public var folded: String
        /// Where the word sits in the original text, as UTF-16 offsets.
        public var range: Range<Int>
    }

    /// The folded words of `text`, joined by single spaces.
    public static func normalize(_ text: String) -> String {
        words(in: text).map(\.folded).joined(separator: " ")
    }

    /// The words of `text`, folded, with their place in the original.
    public static func words(in text: String) -> [Word] {
        tokens(text, offsets: false).map { Word(folded: String(decoding: $0.bytes, as: UTF8.self), range: $0.start..<$0.end) }
    }

    // MARK: words

    /// One folded word. `bytes` is its UTF-8. With `offsets`, `starts[i]` and `ends[i]` are the UTF-16 span
    /// in the original text that folded scalar `i` came from, marks after it included.
    struct Token {
        var bytes: [UInt8]
        var scalars: Int
        var start: Int
        var end: Int
        var starts: [Int]
        var ends: [Int]

        /// The original UTF-16 range of folded scalars `lower..<lower + count`.
        func sourceRange(_ lower: Int, _ count: Int) -> Range<Int> {
            starts[lower]..<ends[lower + count - 1]
        }
    }

    enum ScalarKind { case letter, mark, invisible, joiner, separator }

    static func tokens(_ text: String, offsets: Bool) -> [Token] {
        var out: [Token] = []
        var bytes: [UInt8] = []
        var starts: [Int] = []
        var folded: [Unicode.Scalar] = []
        var cache: [UInt32: [Unicode.Scalar]] = [:]
        var scalars = 0
        var start = 0
        var end = 0
        var offset = 0
        var inWord = false
        var pendingJoiner = false

        func finish() {
            if inWord && !bytes.isEmpty {
                let ends = offsets ? spanEnds(starts, end: end) : []
                out.append(Token(bytes: bytes, scalars: scalars, start: start, end: end, starts: starts, ends: ends))
            }
            bytes.removeAll(keepingCapacity: true)
            starts.removeAll(keepingCapacity: true)
            scalars = 0
            inWord = false
            pendingJoiner = false
        }

        for u in text.unicodeScalars {
            let width = u.value > 0xFFFF ? 2 : 1
            switch kind(of: u) {
            case .letter:
                if !inWord {
                    inWord = true
                    start = offset
                }
                pendingJoiner = false
                fold(u, into: &folded, cache: &cache)
                for f in folded {
                    appendUTF8(f, to: &bytes)
                    scalars += 1
                    if offsets { starts.append(offset) }
                }
                end = offset + width
            case .mark:
                // A point or mark belongs to the letter before it; outside a word it is skipped.
                if inWord && !pendingJoiner { end = offset + width }
            case .invisible:
                // Neither part of the word nor a break in it, and not inside its range at the edges.
                break
            case .joiner:
                // Kept only if a letter comes next, and even then it is not part of the folded word.
                if inWord && !pendingJoiner { pendingJoiner = true } else { finish() }
            case .separator:
                finish()
            }
            offset += width
        }
        finish()
        return out
    }

    /// Where each folded scalar's source ends: at the next scalar that came from a different place, so
    /// points after a letter go with that letter. Scalars folded from one source share its whole span.
    static func spanEnds(_ starts: [Int], end: Int) -> [Int] {
        var ends = starts
        var i = starts.count - 1
        while i >= 0 {
            if i == starts.count - 1 {
                ends[i] = end
            } else if starts[i + 1] != starts[i] {
                ends[i] = starts[i + 1]
            } else {
                ends[i] = ends[i + 1]
            }
            i -= 1
        }
        return ends
    }

    static func kind(of u: Unicode.Scalar) -> ScalarKind {
        let v = u.value
        if v < 0x80 {
            switch v {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return .letter
            case 0x22, 0x27: return .joiner // " and ', typed for gershayim and geresh, and in "don't"
            default: return .separator
            }
        }
        switch v {
        case 0x05D0...0x05EA, 0x05EF...0x05F2: return .letter
        case 0x05BE, 0x05C0, 0x05C3, 0x05C6: return .separator // maqaf, paseq, sof pasuq, nun hafukha
        case 0x0591...0x05C7: return .mark // cantillation and points
        case 0x05F3, 0x05F4, 0x2019, 0x201D: return .joiner // geresh, gershayim, and curly quotes typed for them
        default: break
        }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return .letter
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return .mark
        case .format:
            // The direction marks (LRM, RLM, ALM, embeddings, isolates), zero-width joiners, BOM.
            return .invisible
        default:
            return .separator
        }
    }

    /// The folded form of one letter. ASCII and Hebrew are done by hand; anything else is lowercased and
    /// decomposed, and its marks dropped.
    static func fold(_ u: Unicode.Scalar, into out: inout [Unicode.Scalar], cache: inout [UInt32: [Unicode.Scalar]]) {
        out.removeAll(keepingCapacity: true)
        let v = u.value
        switch v {
        case 0x41...0x5A:
            out.append(Unicode.Scalar(UInt8(v + 0x20)))
        case 0..<0x80:
            out.append(u)
        case 0x05D0...0x05EA:
            out.append(baseLetter(u))
        default:
            if let known = cache[v] {
                out.append(contentsOf: known)
                return
            }
            for s in u.properties.lowercaseMapping.decomposedStringWithCanonicalMapping.unicodeScalars {
                switch s.properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark, .format: continue
                default: out.append(baseLetter(s))
                }
            }
            cache[v] = out
        }
    }

    /// ך ם ן ף ץ to כ מ נ פ צ. Each final letter sits just before its base letter in Unicode.
    static func baseLetter(_ u: Unicode.Scalar) -> Unicode.Scalar {
        switch u.value {
        case 0x05DA, 0x05DD, 0x05DF, 0x05E3, 0x05E5: return Unicode.Scalar(u.value + 1) ?? u
        default: return u
        }
    }

    static func appendUTF8(_ u: Unicode.Scalar, to bytes: inout [UInt8]) {
        if u.value < 0x80 {
            bytes.append(UInt8(u.value))
        } else {
            UTF8.encode(u) { bytes.append($0) }
        }
    }

    /// Scalars in UTF-8 `bytes[0..<end]`: every byte that doesn't continue a scalar starts one.
    static func scalarCount(_ bytes: [UInt8], upTo end: Int? = nil) -> Int {
        var n = 0
        for i in 0..<(end ?? bytes.count) where bytes[i] & 0xC0 != 0x80 { n += 1 }
        return n
    }

    // MARK: Hebrew prefix letters

    /// A word without its first one or two letters.
    struct Stem: Equatable {
        var bytes: [UInt8]
        /// How many letters came off the front.
        var stripped: Int
        var scalars: Int
    }

    /// ו ה ב ל מ ש כ, as the second UTF-8 byte after 0xD7.
    static let prefixLetters: Set<UInt8> = [0x95, 0x94, 0x91, 0x9C, 0x9E, 0xA9, 0x9B]
    /// ה, the article.
    static let article: UInt8 = 0x94

    /// Hebrew writes "and", "the", "in", "to", "from", "that" and "like" as a letter on the front of the
    /// next word, one or two of them: "ובבית" is "and in the house". These are the word without one, then
    /// two, such letters.
    ///
    /// Short words are where this goes wrong: "מים" less מ is "ים" and "כלב" less כ is "לב". So at least
    /// three letters must stay. The one exception is ה, the article, which is common before two-letter
    /// words ("הים", "הגן", "ההר") and rarely the first letter of one: after ה, two may stay.
    static func stems(_ bytes: [UInt8], scalars: Int) -> [Stem] {
        var out: [Stem] = []
        var at = 0
        var left = scalars
        for k in 1...2 {
            guard bytes.count >= at + 2, bytes[at] == 0xD7, prefixLetters.contains(bytes[at + 1]) else { break }
            let rest = left - 1
            guard rest >= 3 || (rest == 2 && bytes[at + 1] == article) else { break }
            at += 2
            left = rest
            out.append(Stem(bytes: Array(bytes[at...]), stripped: k, scalars: left))
        }
        return out
    }
}
