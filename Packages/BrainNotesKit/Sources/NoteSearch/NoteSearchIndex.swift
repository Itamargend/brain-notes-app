import Foundation

/// One note as search sees it. `body` is whatever text the caller wants searched (usually the note without
/// its frontmatter); every body range in a result is a UTF-16 offset into exactly this string.
public struct NoteSearchDocument: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var modified: Date?

    public init(id: String, title: String, body: String, modified: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.modified = modified
    }
}

/// One note that matched. All ranges are UTF-16 offsets, sorted and not overlapping: use them as NSRange
/// for TextKit, or turn them into `String.Index` ranges with `indexRanges(_:in:)`.
public struct NoteSearchResult: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Matches in `title`.
    public var titleMatches: [Range<Int>]
    /// About 160 UTF-16 units of the body around its best match, line breaks shown as spaces, with "…"
    /// where it was cut. The start of the body when only the title matched.
    public var snippet: String
    /// Matches in `snippet`.
    public var snippetMatches: [Range<Int>]
    /// Matches in the document's whole `body`, to scroll to or mark in the note itself.
    public var bodyMatches: [Range<Int>]
    public var modified: Date?
    /// Higher is better. Only the order matters; the scale may change.
    public var score: Int

    /// UTF-16 offset ranges as `String.Index` ranges in `text`.
    public static func indexRanges(_ ranges: [Range<Int>], in text: String) -> [Range<String.Index>] {
        ranges.map { String.Index(utf16Offset: $0.lowerBound, in: text)..<String.Index(utf16Offset: $0.upperBound, in: text) }
    }
}

/// Search across all notes, in memory. Add every note once, then keep it current with `upsert` and
/// `remove` as notes are added, changed and deleted; a rename is a remove and an upsert.
///
/// A query is split into words like the text is (see `SearchText`), and every word must match in the
/// title or the body. A word matches, best first:
///
/// 1. exactly: "בית" finds "בית";
/// 2. without Hebrew prefix letters on the note's word or the query's: "בית" finds "ובבית", "הבית" finds "בית";
/// 3. at the start of a word: "plan" finds "planet";
/// 4. at the start of a word once prefix letters are off, for three letters or more: "גרגיר" finds "הגרגירים";
/// 5. inside a word, for three letters or more: "plan" finds "explanation".
///
/// A match in the title beats any match in the body. Notes then rank by the sum over the query's words,
/// then newest first, notes without a date last, then by title.
///
/// Safe to use from any thread. Searching 2,000 notes of 2 KB takes milliseconds in a release build.
public final class NoteSearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var slotOf: [String: Int] = [:]
    private var docs: [Stored?] = []
    private var freeSlots: [Int] = []
    private var termIDs: [[UInt8]: Int] = [:]
    private var terms: [TermEntry] = []
    private var deadTerms = 0

    private struct Stored {
        var document: NoteSearchDocument
        /// Term id to field bits.
        var terms: [Int: UInt8]
    }

    private struct TermEntry {
        var term: Term
        /// Slot to field bits.
        var postings: [Int: UInt8]
    }

    /// One document, split into words outside the lock.
    private struct Prepared {
        var document: NoteSearchDocument
        var fields: [[UInt8]: UInt8]
    }

    static let titleField: UInt8 = 1
    static let bodyField: UInt8 = 2
    /// Dead terms are dropped once there are this many and they are half the table.
    static let compactAfter = 4096

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return slotOf.count
    }

    public func contains(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return slotOf[id] != nil
    }

    // MARK: write

    /// Add a note, or replace the one with the same id. Saving the same text again costs one comparison.
    public func upsert(_ document: NoteSearchDocument) {
        upsert([document])
    }

    /// Add or replace many notes. Splitting into words happens before the lock is taken.
    public func upsert(_ documents: [NoteSearchDocument]) {
        let prepared = documents.map(Self.prepare)
        lock.lock()
        defer { lock.unlock() }
        for p in prepared { apply(p) }
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slotOf.removeValue(forKey: id) else { return }
        clear(slot)
        freeSlots.append(slot)
        compactIfNeeded()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        slotOf = [:]
        docs = []
        freeSlots = []
        termIDs = [:]
        terms = []
        deadTerms = 0
    }

    private static func prepare(_ document: NoteSearchDocument) -> Prepared {
        var fields: [[UInt8]: UInt8] = [:]
        for t in SearchText.tokens(document.title, offsets: false) { fields[t.bytes, default: 0] |= titleField }
        for t in SearchText.tokens(document.body, offsets: false) { fields[t.bytes, default: 0] |= bodyField }
        return Prepared(document: document, fields: fields)
    }

    private func apply(_ p: Prepared) {
        let slot: Int
        if let known = slotOf[p.document.id] {
            if docs[known]?.document == p.document { return }
            clear(known)
            slot = known
        } else if let free = freeSlots.popLast() {
            slot = free
        } else {
            slot = docs.count
            docs.append(nil)
        }
        slotOf[p.document.id] = slot
        var map: [Int: UInt8] = [:]
        map.reserveCapacity(p.fields.count)
        for (bytes, fields) in p.fields {
            let id: Int
            if let known = termIDs[bytes] {
                id = known
                if terms[id].postings.isEmpty { deadTerms -= 1 }
            } else {
                id = terms.count
                terms.append(TermEntry(term: Term(bytes: bytes), postings: [:]))
                termIDs[bytes] = id
            }
            terms[id].postings[slot] = fields
            map[id] = fields
        }
        docs[slot] = Stored(document: p.document, terms: map)
        compactIfNeeded()
    }

    private func clear(_ slot: Int) {
        guard let stored = docs[slot] else { return }
        for id in stored.terms.keys {
            terms[id].postings[slot] = nil
            if terms[id].postings.isEmpty { deadTerms += 1 }
        }
        docs[slot] = nil
    }

    /// Words no note uses any more stay in the table until there are many, then the table is rebuilt.
    private func compactIfNeeded() {
        guard deadTerms >= Self.compactAfter, deadTerms * 2 >= terms.count else { return }
        var newID = [Int](repeating: -1, count: terms.count)
        var kept: [TermEntry] = []
        kept.reserveCapacity(terms.count - deadTerms)
        for i in terms.indices where !terms[i].postings.isEmpty {
            newID[i] = kept.count
            kept.append(terms[i])
        }
        terms = kept
        termIDs = [:]
        termIDs.reserveCapacity(kept.count)
        for i in kept.indices { termIDs[kept[i].term.bytes] = i }
        for slot in docs.indices {
            guard let stored = docs[slot] else { continue }
            var map: [Int: UInt8] = [:]
            map.reserveCapacity(stored.terms.count)
            for (old, fields) in stored.terms { map[newID[old]] = fields }
            docs[slot]?.terms = map
        }
        deadTerms = 0
    }

    // MARK: search

    public func search(_ query: String, limit: Int = 50) -> [NoteSearchResult] {
        let words = Self.queryWords(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }

        // Score per slot: the sum over words of each word's best tier; 0 means out.
        var totals = [Int](repeating: 0, count: docs.count)
        var best = [Int](repeating: 0, count: docs.count)
        for (w, word) in words.enumerated() {
            for i in best.indices { best[i] = 0 }
            for t in terms.indices where !terms[t].postings.isEmpty {
                guard let m = Self.match(terms[t].term, word) else { continue }
                for (slot, fields) in terms[t].postings {
                    if w > 0 && totals[slot] == 0 { continue }
                    let tier = Self.tier(m.kind, fields: fields)
                    if tier > best[slot] { best[slot] = tier }
                }
            }
            var any = false
            for i in totals.indices {
                if best[i] == 0 || (w > 0 && totals[i] == 0) {
                    totals[i] = 0
                } else {
                    totals[i] += best[i]
                    any = true
                }
            }
            if !any { return [] }
        }

        struct Ranked { var slot: Int; var score: Int; var modified: Date?; var title: String; var id: String }
        var ranked: [Ranked] = []
        for slot in totals.indices where totals[slot] > 0 {
            guard let d = docs[slot]?.document else { continue }
            ranked.append(Ranked(slot: slot, score: totals[slot], modified: d.modified, title: d.title, id: d.id))
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            switch (a.modified, b.modified) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.title != b.title { return a.title < b.title }
            return a.id < b.id
        }
        return ranked.prefix(limit).compactMap { r in
            docs[r.slot].map { Self.result($0.document, words: words, score: r.score) }
        }
    }

    /// Title tiers sit above every body tier.
    static func tier(_ kind: MatchKind, fields: UInt8) -> Int {
        fields & titleField != 0 ? kind.rawValue + 10 : kind.rawValue
    }

    static func queryWords(_ query: String) -> [Term] {
        var seen = Set<[UInt8]>()
        var out: [Term] = []
        for t in SearchText.tokens(query, offsets: false) where seen.insert(t.bytes).inserted {
            out.append(Term(bytes: t.bytes))
        }
        return out
    }

    // MARK: matching

    /// A folded word with its prefix-free stems, for the note's words and the query's alike.
    struct Term {
        var bytes: [UInt8]
        var scalars: Int
        var stems: [SearchText.Stem]

        init(bytes: [UInt8]) {
            self.bytes = bytes
            scalars = SearchText.scalarCount(bytes)
            stems = SearchText.stems(bytes, scalars: scalars)
        }
    }

    enum MatchKind: Int, Comparable {
        case infix = 1, strippedPrefix, prefix, strippedExact, exact
        static func < (a: MatchKind, b: MatchKind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Which folded scalars of the note's word matched, and how.
    struct Match: Equatable {
        var kind: MatchKind
        var start: Int
        var length: Int
    }

    /// Partial matches (a stem's start, or inside a word) need this many letters typed.
    static let partialMinimum = 3

    /// The best way `query` matches the note's word `term`, or nil. Prefix letters come off one side
    /// only: off both, "שלום" (less ש) would find "הלום" (less ה).
    static func match(_ term: Term, _ query: Term) -> Match? {
        let t = term.bytes, q = query.bytes
        if t == q { return Match(kind: .exact, start: 0, length: term.scalars) }
        for s in term.stems where s.bytes == q {
            return Match(kind: .strippedExact, start: s.stripped, length: s.scalars)
        }
        for s in query.stems where s.bytes == t {
            return Match(kind: .strippedExact, start: 0, length: term.scalars)
        }
        if hasPrefix(t, q) { return Match(kind: .prefix, start: 0, length: query.scalars) }
        if query.scalars >= partialMinimum {
            for s in term.stems where hasPrefix(s.bytes, q) {
                return Match(kind: .strippedPrefix, start: s.stripped, length: query.scalars)
            }
        }
        for s in query.stems where s.scalars >= partialMinimum && hasPrefix(t, s.bytes) {
            return Match(kind: .strippedPrefix, start: 0, length: s.scalars)
        }
        if query.scalars >= partialMinimum, let at = find(q, in: t) {
            return Match(kind: .infix, start: SearchText.scalarCount(t, upTo: at), length: query.scalars)
        }
        return nil
    }

    static func hasPrefix(_ a: [UInt8], _ p: [UInt8]) -> Bool {
        guard a.count > p.count else { return false }
        for i in p.indices where a[i] != p[i] { return false }
        return true
    }

    /// First byte offset after 0 where `needle` sits in `hay`. UTF-8 never matches mid-scalar.
    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count > needle.count else { return nil }
        let first = needle[0]
        var i = 1
        while i + needle.count <= hay.count {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: results

    /// Ranges of every match in `text`, and the kind of the best one with its range.
    static func matches(in text: String, words: [Term]) -> (ranges: [Range<Int>], best: (kind: MatchKind, range: Range<Int>)?) {
        var ranges: [Range<Int>] = []
        var best: (kind: MatchKind, range: Range<Int>)?
        for token in SearchText.tokens(text, offsets: true) {
            let term = Term(bytes: token.bytes)
            for word in words {
                guard let m = match(term, word) else { continue }
                let r = token.sourceRange(m.start, m.length)
                ranges.append(r)
                if best == nil || m.kind > best!.kind { best = (m.kind, r) }
            }
        }
        return (merged(ranges), best)
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func result(_ d: NoteSearchDocument, words: [Term], score: Int) -> NoteSearchResult {
        let title = matches(in: d.title, words: words)
        let body = matches(in: d.body, words: words)
        let (snippet, inSnippet) = Snippet.make(d.body, around: body.best?.range, matches: body.ranges)
        return NoteSearchResult(id: d.id, title: d.title, titleMatches: title.ranges, snippet: snippet,
                                snippetMatches: inSnippet, bodyMatches: body.ranges, modified: d.modified, score: score)
    }
}

/// A short piece of the body around a match, cut at spaces, never inside a letter and its points.
enum Snippet {
    static let width = 160
    static let lead = 50
    static let snap = 20
    static let ellipsis = "…"

    static func make(_ body: String, around anchor: Range<Int>?, matches: [Range<Int>]) -> (String, [Range<Int>]) {
        let units = Array(body.utf16)
        let n = units.count
        guard n > 0 else { return ("", []) }
        var lo = 0
        var hi = min(n, width)
        if let a = anchor {
            lo = max(0, a.lowerBound - lead)
            hi = min(n, max(lo + width, a.upperBound))
            if hi - lo < width { lo = max(0, hi - width) }
        }
        let keepFrom = anchor?.lowerBound ?? n
        let keepTo = anchor?.upperBound ?? 0
        // Start just after a space when one is near, and never on a point or the second half of a pair.
        if lo > 0 {
            var i = lo
            while i < min(lo + snap, keepFrom) && !isSpace(units[i]) { i += 1 }
            if i < min(lo + snap, keepFrom) { lo = i + 1 }
            while lo < n && lo < keepFrom && continuesPrevious(units[lo]) { lo += 1 }
        }
        // End at a space when one is near, and keep the points of the last letter.
        if hi < n {
            var i = hi - 1
            while i > max(hi - snap, keepTo) && !isSpace(units[i]) { i -= 1 }
            if i > max(hi - snap, keepTo) { hi = i }
            while hi < n && continuesPrevious(units[hi]) { hi += 1 }
        }
        while lo < hi && lo < keepFrom && isSpace(units[lo]) { lo += 1 }
        while hi > lo && hi > keepTo && isSpace(units[hi - 1]) { hi -= 1 }

        let head = lo > 0 ? ellipsis : ""
        let tail = hi < n ? ellipsis : ""
        let shown: [UInt16] = units[lo..<hi].map { (u: UInt16) -> UInt16 in
            u == 0x0A || u == 0x0D || u == 0x09 ? 0x20 : u
        }
        let text = head + String(decoding: shown, as: UTF16.self) + tail
        let shift = head.utf16.count - lo
        let ranges = matches.filter { $0.lowerBound >= lo && $0.upperBound <= hi }
            .map { ($0.lowerBound + shift)..<($0.upperBound + shift) }
        return (text, ranges)
    }

    static func isSpace(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x0A || u == 0x0D || u == 0x09 || u == 0xA0
    }

    /// A unit that belongs with the one before it: a low surrogate, a combining mark, a joiner.
    static func continuesPrevious(_ u: UInt16) -> Bool {
        switch u {
        case 0xDC00...0xDFFF, 0x0300...0x036F, 0x200C, 0x200D, 0x20D0...0x20FF, 0xFE00...0xFE0F: return true
        case 0x05BE, 0x05C0, 0x05C3, 0x05C6: return false
        case 0x0591...0x05C7: return true
        default: return false
        }
    }
}
