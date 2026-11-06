import Foundation

/// One paragraph of Markdown source, taken apart: what kind of block it is and which ranges are syntax and which are
/// text. Pure, and it never changes a byte: the editor uses it to decide what each stretch of the file looks like.
/// Positions are UTF-16 offsets from the paragraph's start, the text views' own unit. Works line by line, so emphasis
/// does not run across a line break. Follows CommonMark's rules for which marks pair up, in a small form.
public enum MarkdownInline {
    public struct Span: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case bold, italic, strikethrough, code
            case wikiLink(target: String)
            case link(url: String)
            /// No marks, so nothing to hide.
            case bareURL
        }

        public var kind: Kind
        public var open: NSRange
        public var content: NSRange
        public var close: NSRange

        /// The marks and the text together.
        public var whole: NSRange { NSRange(location: open.location, length: NSMaxRange(close) - open.location) }
    }

    public enum Block: Sendable, Equatable {
        case plain
        case heading(Int)
        case bullet(level: Int)
        /// `box`: the offset of the one character between the brackets.
        case task(done: Bool, level: Int, box: Int)
        /// `marker`: the number and what follows it, which stay on screen.
        case numbered(marker: NSRange, level: Int)
        case quote
        case rule
        /// A ``` or ~~~ line.
        case fence
        /// A line between fences. Nothing in it is Markdown.
        case code
    }

    public struct Line: Sendable, Equatable {
        public var block: Block
        /// The block's own syntax, with any indent: `# `, `  - [ ] `, `> `. Shown as a glyph or a look instead. Of a numbered
        /// line, only its indent: the number stays.
        public var marker: NSRange?
        public var spans: [Span]
        /// Backslashes that make the next character plain.
        public var escapes: [NSRange]
        /// Where the text begins: behind the marker and any direction mark.
        public var textStart = 0
        /// The direction mark at this line's start, if it has one. Invisible, and no syntax: never among `marks`.
        public var directionMark: Int?
        /// A heading inside a list item or a quote, as in `- [ ] # a`: its marker, behind the block's own, and its level.
        public var innerHeadingMarker: NSRange?
        public var innerHeadingLevel: Int?

        /// A marker in front of the text, which what is typed must stay behind.
        public var hasBlockMarker: Bool {
            if case .numbered = block { return true }
            return marker != nil
        }

        /// The heading level this line's text reads at. 0 is body text.
        public var headingLevel: Int {
            if case let .heading(level) = block { return level }
            return innerHeadingLevel ?? 0
        }

        /// Everything that is syntax and not text.
        public var marks: [NSRange] {
            var out: [NSRange] = []
            if let marker, marker.length > 0 { out.append(marker) }
            if let innerHeadingMarker { out.append(innerHeadingMarker) }
            for span in spans {
                if span.open.length > 0 { out.append(span.open) }
                if span.close.length > 0 { out.append(span.close) }
            }
            out.append(contentsOf: escapes)
            return out.sorted { $0.location < $1.location }
        }
    }

    public static func line(_ paragraph: String, fence: FencedCode.Role = .none) -> Line {
        line(units: Array(paragraph.utf16), fence: fence)
    }

    public static func line(units u: [UInt16], fence: FencedCode.Role = .none) -> Line {
        switch fence {
        case .opening, .closing:
            return Line(block: .fence, marker: NSRange(location: 0, length: u.count), spans: [], escapes: [], textStart: u.count)
        case .inside:
            return Line(block: .code, marker: nil, spans: [], escapes: [])
        case .none:
            break
        }
        if isRule(u) { return Line(block: .rule, marker: NSRange(location: 0, length: u.count), spans: [], escapes: [], textStart: u.count) }

        let parsed = MarkdownLine(u)
        var block = Block.plain
        var marker: NSRange?
        if let found = parsed.marker {
            let upTo = NSRange(location: 0, length: found.range.upperBound)
            let width = MarkdownLine.width(u, upTo: parsed.indentEnd)
            let level = width / 2
            switch found.kind {
            case let .heading(n):
                block = .heading(n)
                marker = upTo
            case .bullet:
                block = .bullet(level: level)
                marker = upTo
            case let .task(done, box):
                block = .task(done: done, level: level, box: box)
                marker = upTo
            case .quote:
                block = .quote
                marker = upTo
            case .numbered:
                // The number is what a reader needs to see, so it stays. Nested, they are 3 apart: as far as `1. ` goes.
                block = .numbered(marker: NSRange(location: found.range.lowerBound, length: found.range.count), level: (width + 2) / 3)
                if parsed.indentEnd > 0 { marker = NSRange(location: 0, length: parsed.indentEnd) }
            }
        }
        var scanner = SpanScanner(u, from: parsed.contentStart)
        scanner.run()
        return Line(block: block, marker: marker, spans: scanner.spans.sorted { $0.whole.location < $1.whole.location }, escapes: scanner.escapes,
                    textStart: parsed.contentStart, directionMark: parsed.mark,
                    innerHeadingMarker: parsed.innerHeading.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) },
                    innerHeadingLevel: parsed.innerHeading?.level)
    }

    /// A table cell's text: inline marks and nothing else. A cell can't hold a heading or a list, so `# a` and `- a` in
    /// one say just that.
    public static func inline(units u: [UInt16]) -> Line {
        var scanner = SpanScanner(u, from: 0)
        scanner.run()
        return Line(block: .plain, marker: nil, spans: scanner.spans.sorted { $0.whole.location < $1.whole.location }, escapes: scanner.escapes)
    }

    /// The text of one line with its syntax gone: what a reader sees. For naming a note from its first line.
    public static func plainText(_ paragraph: String) -> String {
        let units = Array(paragraph.utf16)
        var keep = [Bool](repeating: true, count: units.count)
        for mark in line(units: units).marks {
            for i in mark.location..<NSMaxRange(mark) { keep[i] = false }
        }
        return String(decoding: units.indices.filter { keep[$0] }.map { units[$0] }, as: UTF16.self)
    }

    private static func isRule(_ u: [UInt16]) -> Bool {
        var i = 0
        while i < u.count, i < 3, u[i] == 0x20 { i += 1 }
        guard u.count == i + 3, let c = u.last, c == 0x2D || c == 0x2A || c == 0x5F else { return false } // - * _
        return u[i] == c && u[i + 1] == c
    }

}

// MARK: - one line's block syntax

/// `<indent><mark?><block marker?><mark?><heading marker?><mark?><text>`, in offsets from the paragraph's start. Shared by
/// the styling and the edit actions, so that what the bar writes and what the editor sees as a marker can't disagree.
struct MarkdownLine {
    enum Kind: Equatable {
        case task(done: Bool, box: Int)
        case bullet
        case heading(Int)
        case quote
        case numbered

        var isHeading: Bool {
            if case .heading = self { return true }
            return false
        }
    }

    static let rightToLeftMark: UInt16 = 0x200F
    static let leftToRightMark: UInt16 = 0x200E

    var indentEnd = 0
    /// A mark in front of the block marker. This app doesn't write that form, but a note can have it.
    var leadingMark: Int?
    var marker: (range: Range<Int>, kind: Kind)?
    var trailingMark: Int?
    /// A heading inside a list item or a quote: `- [ ] # a`.
    var innerHeading: (range: Range<Int>, level: Int)?
    var contentStart = 0

    var mark: Int? { leadingMark ?? trailingMark }

    /// Columns of indent. A tab counts for a level.
    static func width(_ u: [UInt16], upTo end: Int) -> Int {
        var width = 0
        for i in 0..<end { width += u[i] == 0x09 ? 2 : 1 }
        return width
    }

    init(_ u: [UInt16]) {
        func isMark(_ i: Int) -> Bool {
            i < u.count && (u[i] == Self.rightToLeftMark || u[i] == Self.leftToRightMark)
        }
        var i = 0
        while i < u.count, u[i] == 0x20 || u[i] == 0x09 { i += 1 }
        indentEnd = i
        if isMark(i) {
            leadingMark = i
            i += 1
        }
        if let found = Self.marker(in: u, at: i) {
            marker = found
            i = found.range.upperBound
        }
        if isMark(i) {
            trailingMark = i
            i += 1
        }
        if let marker, !marker.kind.isHeading, let inner = Self.heading(in: u, at: i) {
            innerHeading = inner
            i = inner.range.upperBound
            if trailingMark == nil, isMark(i) {
                trailingMark = i
                i += 1
            }
        }
        contentStart = i
    }

    private static func heading(in u: [UInt16], at i: Int) -> (range: Range<Int>, level: Int)? {
        var level = 0
        while i + level < u.count, u[i + level] == 0x23 { level += 1 } // #
        guard (1...6).contains(level), i + level < u.count, u[i + level] == 0x20 || u[i + level] == 0x09 else { return nil }
        return (i..<(i + level + 1), level)
    }

    private static func marker(in u: [UInt16], at i: Int) -> (range: Range<Int>, kind: Kind)? {
        func at(_ offset: Int) -> UInt16? { i + offset < u.count ? u[i + offset] : nil }
        let space: UInt16 = 0x20
        switch at(0) {
        case 0x2D?, 0x2A?, 0x2B?: // - * +
            guard at(1) == space else { return nil }
            let tick = at(3)
            if at(2) == 0x5B, tick == space || tick == 0x78 || tick == 0x58, at(4) == 0x5D, at(5) == space { // [ ], [x], [X]
                return (i..<(i + 6), .task(done: tick != space, box: i + 3))
            }
            return (i..<(i + 2), .bullet)
        case 0x23?: // #
            return heading(in: u, at: i).map { ($0.range, .heading($0.level)) }
        case 0x3E?: // >
            return at(1) == space ? (i..<(i + 2), .quote) : nil
        default:
            var digits = 0
            while let d = at(digits), (0x30...0x39).contains(d) { digits += 1 }
            guard (1...9).contains(digits), at(digits) == 0x2E || at(digits) == 0x29, at(digits + 1) == space else { return nil } // . )
            return (i..<(i + digits + 2), .numbered)
        }
    }
}

// MARK: - inline syntax

private struct SpanScanner {
    let u: [UInt16]
    let start: Int
    var spans: [MarkdownInline.Span] = []
    var escapes: [NSRange] = []
    private var delimiters: [Delimiter] = []
    /// The `](url)` ahead of a link whose text is being scanned.
    private var jumps: [Int: Int] = [:]

    private struct Delimiter {
        let char: UInt16
        var location: Int
        var count: Int
        let originalCount: Int
        let canOpen: Bool
        let canClose: Bool
    }

    init(_ units: [UInt16], from start: Int) {
        u = units
        self.start = start
    }

    mutating func run() {
        var i = start
        while i < u.count {
            if let next = jumps[i] {
                i = next
                continue
            }
            switch u[i] {
            case 0x5C: // \
                if i + 1 < u.count, isASCIIPunctuation(u[i + 1]) {
                    escapes.append(NSRange(location: i, length: 1))
                    i += 2
                } else {
                    i += 1
                }
            case 0x60: // `
                i = codeSpan(at: i)
            case 0x5B: // [
                i = i + 1 < u.count && u[i + 1] == 0x5B ? wikiLink(at: i) : link(at: i)
            case 0x21: // !
                i = image(at: i)
            case 0x68, 0x48: // h H
                i = bareURL(at: i)
            case 0x2A, 0x5F, 0x7E: // * _ ~
                i = delimiterRun(at: i)
            default:
                i += 1
            }
        }
        pairDelimiters()
    }

    // MARK: code

    private mutating func codeSpan(at i: Int) -> Int {
        let size = run(of: 0x60, at: i)
        var j = i + size
        while j < u.count {
            guard u[j] == 0x60 else {
                j += 1
                continue
            }
            let closing = run(of: 0x60, at: j)
            if closing == size, j > i + size {
                spans.append(.init(kind: .code,
                                   open: NSRange(location: i, length: size),
                                   content: NSRange(location: i + size, length: j - i - size),
                                   close: NSRange(location: j, length: size)))
                return j + size
            }
            j += closing
        }
        return i + size
    }

    private func run(of char: UInt16, at i: Int) -> Int {
        var n = 0
        while i + n < u.count, u[i + n] == char { n += 1 }
        return n
    }

    // MARK: links

    private mutating func wikiLink(at i: Int) -> Int {
        var j = i + 2
        var pipe: Int?
        while j + 1 < u.count {
            let c = u[j]
            if c == 0x5D, u[j + 1] == 0x5D { break }
            if c == 0x5B || c == 0x5D { return i + 1 }
            if c == 0x7C, pipe == nil { pipe = j } // |
            j += 1
        }
        guard j + 1 < u.count, j > i + 2 else { return i + 1 }
        let targetEnd = pipe ?? j
        let contentStart = pipe.map { $0 + 1 } ?? i + 2
        guard targetEnd > i + 2, j > contentStart else { return i + 1 }
        let target = String(decoding: u[(i + 2)..<targetEnd], as: UTF16.self)
        spans.append(.init(kind: .wikiLink(target: target),
                           open: NSRange(location: i, length: contentStart - i),
                           content: NSRange(location: contentStart, length: j - contentStart),
                           close: NSRange(location: j, length: 2)))
        return j + 2
    }

    /// `[text](url)`. The text is scanned on from here, since it can hold emphasis.
    private mutating func link(at i: Int) -> Int {
        guard let (close, end, url) = linkTail(from: i) else { return i + 1 }
        spans.append(.init(kind: .link(url: url),
                           open: NSRange(location: i, length: 1),
                           content: NSRange(location: i + 1, length: close - i - 1),
                           close: NSRange(location: close, length: end - close)))
        jumps[close] = end
        return i + 1
    }

    /// An image isn't drawn here, so it stays as written.
    private mutating func image(at i: Int) -> Int {
        guard i + 1 < u.count, u[i + 1] == 0x5B, let (_, end, _) = linkTail(from: i + 1) else { return i + 1 }
        return end
    }

    /// From the `[`: the `]`, the end of `(...)` and the destination. No nested brackets in the text.
    private func linkTail(from i: Int) -> (close: Int, end: Int, url: String)? {
        var j = i + 1
        while j < u.count, u[j] != 0x5D {
            if u[j] == 0x5B { return nil }
            if u[j] == 0x5C { j += 1 }
            j += 1
        }
        guard j > i + 1, j + 1 < u.count, u[j + 1] == 0x28 else { return nil }
        var depth = 1
        var k = j + 2
        var urlEnd: Int?
        while k < u.count {
            let c = u[k]
            if c == 0x28 {
                depth += 1
            } else if c == 0x29 {
                depth -= 1
                if depth == 0 { break }
            } else if c == 0x20, urlEnd == nil {
                urlEnd = k
            }
            k += 1
        }
        guard k < u.count, depth == 0 else { return nil }
        return (j, k + 1, String(decoding: u[(j + 2)..<(urlEnd ?? k)], as: UTF16.self))
    }

    private mutating func bareURL(at i: Int) -> Int {
        if i > start, isWordCharacter(u[i - 1]) { return i + 1 }
        let schemes = [Array("http://".utf16), Array("https://".utf16)]
        guard let scheme = schemes.first(where: { s in
            i + s.count <= u.count && s.indices.allSatisfy { lower(u[i + $0]) == s[$0] }
        }) else { return i + 1 }
        var end = i + scheme.count
        while end < u.count, !isWhiteSpace(u[end]), u[end] != 0x3C, u[end] != 0x3E { end += 1 } // < >
        // Trailing punctuation belongs to the sentence, and marks to whatever they close.
        while end > i + scheme.count {
            let c = u[end - 1]
            if ".,;:!?'\"*_~".utf16.contains(c) {
                end -= 1
            } else if c == 0x29, u[i..<end].filter({ $0 == 0x29 }).count > u[i..<end].filter({ $0 == 0x28 }).count {
                end -= 1
            } else {
                break
            }
        }
        guard end > i + scheme.count else { return i + 1 }
        spans.append(.init(kind: .bareURL,
                           open: NSRange(location: i, length: 0),
                           content: NSRange(location: i, length: end - i),
                           close: NSRange(location: end, length: 0)))
        return end
    }

    // MARK: emphasis

    private mutating func delimiterRun(at i: Int) -> Int {
        let char = u[i]
        let count = run(of: char, at: i)
        // `~~` only: a single tilde is plain text.
        if char == 0x7E, count != 2 { return i + count }
        let before = i > start ? u[i - 1] : 0x20
        let after = i + count < u.count ? u[i + count] : 0x20
        let beforeWhite = isWhiteSpace(before), afterWhite = isWhiteSpace(after)
        let beforePunctuation = isPunctuation(before), afterPunctuation = isPunctuation(after)
        let left = !afterWhite && (!afterPunctuation || beforeWhite || beforePunctuation)
        let right = !beforeWhite && (!beforePunctuation || afterWhite || afterPunctuation)
        let canOpen: Bool, canClose: Bool
        if char == 0x5F { // _ inside a word is just an underscore.
            canOpen = left && (!right || beforePunctuation)
            canClose = right && (!left || afterPunctuation)
        } else {
            canOpen = left
            canClose = right
        }
        if canOpen || canClose {
            delimiters.append(Delimiter(char: char, location: i, count: count, originalCount: count, canOpen: canOpen, canClose: canClose))
        }
        return i + count
    }

    private mutating func pairDelimiters() {
        var closer = 0
        while closer < delimiters.count {
            guard delimiters[closer].canClose, delimiters[closer].count > 0 else {
                closer += 1
                continue
            }
            var opener = closer - 1
            var found: Int?
            while opener >= 0 {
                if delimiters[opener].char == delimiters[closer].char, delimiters[opener].canOpen, delimiters[opener].count > 0, !breaksRuleOfThree(opener, closer) {
                    found = opener
                    break
                }
                opener -= 1
            }
            guard let found else {
                closer += 1
                continue
            }
            let use = delimiters[found].count >= 2 && delimiters[closer].count >= 2 ? 2 : 1
            let openAt = delimiters[found].location + delimiters[found].count - use
            let closeAt = delimiters[closer].location
            let kind: MarkdownInline.Span.Kind = delimiters[closer].char == 0x7E ? .strikethrough : use == 2 ? .bold : .italic
            spans.append(.init(kind: kind,
                               open: NSRange(location: openAt, length: use),
                               content: NSRange(location: openAt + use, length: closeAt - openAt - use),
                               close: NSRange(location: closeAt, length: use)))
            delimiters[found].count -= use
            delimiters[closer].count -= use
            delimiters[closer].location += use
            // Marks between a pair can't pair with anything outside it.
            for between in (found + 1)..<closer { delimiters[between].count = 0 }
            if delimiters[closer].count == 0 { closer += 1 }
        }
        // Bold still open at the line's end, as in `**Shana`: while it is being typed, or when its pair went to another
        // line. It reads as bold to the end of the line, with the mark hidden like any other. Not `2**n`, which can close
        // as well as open, and only ever bold: a lone `*` or `_` in front of a word is too often just that character.
        for delimiter in delimiters where delimiter.char == 0x2A && delimiter.originalCount == 2 && delimiter.count == 2 && delimiter.canOpen && !delimiter.canClose {
            spans.append(.init(kind: .bold,
                               open: NSRange(location: delimiter.location, length: 2),
                               content: NSRange(location: delimiter.location + 2, length: u.count - delimiter.location - 2),
                               close: NSRange(location: u.count, length: 0)))
        }
    }

    private func breaksRuleOfThree(_ a: Int, _ b: Int) -> Bool {
        let opener = delimiters[a], closer = delimiters[b]
        guard opener.canClose || closer.canOpen else { return false }
        return (opener.originalCount + closer.originalCount) % 3 == 0 && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
    }

    // MARK: characters

    private func lower(_ c: UInt16) -> UInt16 { (0x41...0x5A).contains(c) ? c + 32 : c }

    private func isASCIIPunctuation(_ c: UInt16) -> Bool {
        (0x21...0x2F).contains(c) || (0x3A...0x40).contains(c) || (0x5B...0x60).contains(c) || (0x7B...0x7E).contains(c)
    }

    private func isWhiteSpace(_ c: UInt16) -> Bool {
        Unicode.Scalar(c)?.properties.isWhitespace ?? false
    }

    private func isPunctuation(_ c: UInt16) -> Bool {
        if c < 0x80 { return isASCIIPunctuation(c) }
        guard let scalar = Unicode.Scalar(c) else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private func isWordCharacter(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        return scalar.properties.isAlphabetic || (0x30...0x39).contains(c)
    }
}

// MARK: - fenced code

/// Which lines of a note are fenced code. This takes state across paragraphs, so it is worked out for the whole note on
/// load and again only when an edit touches a fence line. Same rule as the note view: up to three spaces, then ``` or
/// ~~~; the same three characters close it; an unclosed fence runs to the end of the note.
public struct FencedCode: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case none, opening, inside, closing
    }

    public struct Block: Sendable, Equatable {
        /// Paragraph ranges, line endings included.
        public var opening: NSRange
        public var closing: NSRange?
    }

    public private(set) var blocks: [Block] = []

    public init() {}

    public init(text: NSString) {
        var found: [Block] = []
        var open: (range: NSRange, mark: [UInt16])?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, paragraph, enclosing, _ in
            guard let mark = Self.fenceMark(text, paragraph: paragraph, isClosing: open != nil) else { return }
            if let current = open {
                guard mark == current.mark else { return }
                found.append(Block(opening: current.range, closing: enclosing))
                open = nil
            } else {
                open = (enclosing, mark)
            }
        }
        if let open { found.append(Block(opening: open.range, closing: nil)) }
        blocks = found
    }

    public func role(ofParagraphAt location: Int) -> Role {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let block = blocks[mid]
            if location < block.opening.location {
                high = mid - 1
            } else if let closing = block.closing, location >= NSMaxRange(closing) {
                low = mid + 1
            } else if location < NSMaxRange(block.opening) {
                return .opening
            } else if let closing = block.closing, location >= closing.location {
                return .closing
            } else {
                return .inside
            }
        }
        return .none
    }

    /// True if any paragraph touching `range` looks like a fence line, the one right after it included: a line ending
    /// typed into a line can leave a fence at the start of the next.
    public static func hasFenceLine(_ text: NSString, in range: NSRange) -> Bool {
        var found = false
        let reach = NSRange(location: range.location, length: min(range.length + 1, text.length - range.location))
        let lines = text.paragraphRange(for: reach)
        #if canImport(Darwin)
        text.enumerateSubstrings(in: lines, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, stop in
            if fenceMark(text, paragraph: paragraph, isClosing: true) != nil {
                found = true
                stop.pointee = true
            }
        }
        #else
        // swift-corelibs-foundation's `.byParagraphs` enumeration ignores its range and walks the whole string, so
        // off Apple the paragraphs are stepped through by hand.
        var at = lines.location
        while at < NSMaxRange(lines), !found {
            var end = 0, contentsEnd = 0
            text.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
            let paragraph = NSRange(location: at, length: contentsEnd - at)
            if fenceMark(text, paragraph: paragraph, isClosing: true) != nil { found = true }
            at = max(end, at + 1)
        }
        #endif
        return found
    }

    /// Keeps the offsets right after an edit: `edited` is the new text's range, `delta` the change in length. True if it
    /// touched a fence line, so that the note must be scanned again.
    public mutating func textChanged(edited: NSRange, delta: Int) -> Bool {
        let oldEnd = NSMaxRange(edited) - delta
        var touched = false
        func mapped(_ r: NSRange) -> NSRange {
            if NSMaxRange(r) <= edited.location, !(NSMaxRange(r) == edited.location && r.length == 0) { return r }
            if r.location >= oldEnd { return NSRange(location: r.location + delta, length: r.length) }
            let start = min(r.location, edited.location)
            return NSRange(location: start, length: max(NSMaxRange(r) + delta, NSMaxRange(edited)) - start)
        }
        func touches(_ r: NSRange) -> Bool { r.location <= oldEnd && edited.location < NSMaxRange(r) }
        for i in blocks.indices {
            if touches(blocks[i].opening) { touched = true }
            if let closing = blocks[i].closing, touches(closing) { touched = true }
            blocks[i].opening = mapped(blocks[i].opening)
            blocks[i].closing = blocks[i].closing.map(mapped)
        }
        return touched
    }

    /// The fence's three characters, if this paragraph is a fence line. A closing line can be indented any amount, as
    /// in the note view; an opening one by at most three spaces.
    private static func fenceMark(_ text: NSString, paragraph: NSRange, isClosing: Bool) -> [UInt16]? {
        var i = paragraph.location
        let end = NSMaxRange(paragraph)
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard isClosing || i - paragraph.location <= 3, i + 3 <= end else { return nil }
        let c = text.character(at: i)
        guard c == 0x60 || c == 0x7E, text.character(at: i + 1) == c, text.character(at: i + 2) == c else { return nil }
        return [c, c, c]
    }
}
