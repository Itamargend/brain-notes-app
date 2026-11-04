// Standard library only: this folder is what the package builds on Linux (see Package.swift).

/// One `[[wiki link]]` in a note: where it is and what it names. Offsets are UTF-8 bytes from the note's start, the
/// unit the files and Git use, so an edit made from them leaves every other byte as it was.
public struct WikiLink: Sendable, Hashable {
    /// `[[` to `]]`. An embed's `!` is not in it.
    public var range: Range<Int>
    /// The note's name as written: no `#heading`, no `|alias`, no `.md`, and no spaces or direction marks around it.
    /// Empty for `[[#Heading]]`, a link into the same note. Can hold a folder path: `[[Projects/Plan]]`.
    public var name: String
    /// Where `name` is. A rename replaces exactly these bytes.
    public var nameRange: Range<Int>
    /// After the first `#`, as written: `Heading`, `^block`, or `H1#H2`.
    public var heading: String?
    /// After the first `|`, as written.
    public var alias: String?
    /// `![[...]]`.
    public var isEmbed: Bool
    /// The line it is on, from 0. `\r\n` is one line break.
    public var line: Int

    public init(range: Range<Int>, name: String, nameRange: Range<Int>, heading: String?, alias: String?, isEmbed: Bool, line: Int) {
        self.range = range
        self.name = name
        self.nameRange = nameRange
        self.heading = heading
        self.alias = alias
        self.isEmbed = isEmbed
        self.line = line
    }
}

/// One replacement in a note's text, in UTF-8 byte offsets of the text before any edit.
public struct TextEdit: Sendable, Hashable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// Applies edits that don't overlap, in any order. Bytes outside their ranges come through unchanged: line
    /// endings, a byte-order mark, the Unicode form of every other name.
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var at = 0
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            precondition(edit.range.lowerBound >= at && edit.range.upperBound <= bytes.count, "overlapping or out-of-range edit")
            out.append(contentsOf: bytes[at..<edit.range.lowerBound])
            out.append(contentsOf: edit.replacement.utf8)
            at = edit.range.upperBound
        }
        out.append(contentsOf: bytes[at...])
        return String(decoding: out, as: UTF8.self)
    }
}

/// Finds the wiki links in a note. Pure, and it reads the note the way the editor's styler does (`MarkdownInline`,
/// `FencedCode`): a link the editor shows as a link is found here, and nothing else is.
///
/// - Same link rule: `[[`, then anything but `[` or `]` up to `]]`, all on one line. The first `|` starts the alias,
///   and the part before it and the part after it must both have text.
/// - Not in code: a fenced block (up to three spaces, then ``` or ~~~, closed by the same three characters, or open
///   to the end of the note), its fence lines, or an inline code span.
/// - Not escaped (`\[[x]]`), and not inside a bare URL, a `[text](url)` destination or an image.
///
/// One addition: in a table a link is written `[[Note\|alias]]`, so a `\` right before the pipe is not part of the name.
public enum WikiLinks {
    public static func parse(_ text: String) -> [WikiLink] {
        var scalars: [Unicode.Scalar] = []
        var offsets: [Int] = []
        scalars.reserveCapacity(text.utf8.count)
        offsets.reserveCapacity(text.utf8.count + 1)
        var offset = 0
        for scalar in text.unicodeScalars {
            scalars.append(scalar)
            offsets.append(offset)
            offset += utf8Width(scalar)
        }
        offsets.append(offset)

        var links: [WikiLink] = []
        var fence: Unicode.Scalar?
        var line = 0
        var start = 0
        while true {
            var end = start
            while end < scalars.count, !isLineBreak(scalars[end]) { end += 1 }
            if let mark = fenceMark(scalars, start, end, closing: fence != nil) {
                if fence == nil {
                    fence = mark
                } else if mark == fence {
                    fence = nil
                }
            } else if fence == nil {
                var scanner = LineScanner(s: scalars, offsets: offsets, start: start, end: end, line: line)
                scanner.run()
                links.append(contentsOf: scanner.links)
            }
            if end == scalars.count { break }
            let crlf = scalars[end] == "\r" && end + 1 < scalars.count && scalars[end + 1] == "\n"
            start = end + (crlf ? 2 : 1)
            line += 1
        }
        return links
    }

    /// The same paragraph breaks as `NSString`'s `.byParagraphs`, which the editor uses: `\n`, `\r` and U+2029.
    /// U+2028 (line separator) and U+0085 (next line) end a line but not a paragraph, so a link can span them,
    /// as it does in the editor.
    static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0A, 0x0D, 0x2029: return true
        default: return false
        }
    }

    /// The fence character, if this line is a fence line. An opening line is indented by at most three spaces, a
    /// closing one by any number, as in `FencedCode`.
    private static func fenceMark(_ s: [Unicode.Scalar], _ start: Int, _ end: Int, closing: Bool) -> Unicode.Scalar? {
        var i = start
        while i < end, s[i] == " " { i += 1 }
        guard closing || i - start <= 3, i + 3 <= end else { return nil }
        let c = s[i]
        guard c == "`" || c == "~", s[i + 1] == c, s[i + 2] == c else { return nil }
        return c
    }

    static func utf8Width(_ s: Unicode.Scalar) -> Int {
        switch s.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x10000: return 3
        default: return 4
        }
    }

    /// Spaces, and the invisible direction marks a Hebrew keyboard can leave at a name's ends.
    static func isPadding(_ c: Unicode.Scalar) -> Bool {
        c.properties.isWhitespace || isDirectionControl(c)
    }

    static func isDirectionControl(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}

// MARK: - one line

/// Walks one line like the editor's span scanner, keeping only what decides where a wiki link can be: escapes, code
/// spans, links, images and bare URLs. Emphasis never hides a link, so it is not followed here.
private struct LineScanner {
    let s: [Unicode.Scalar]
    let offsets: [Int]
    let start: Int
    let end: Int
    let line: Int
    var links: [WikiLink] = []
    /// The `](url)` ahead of a link whose text is being scanned.
    private var jumps: [Int: Int] = [:]

    init(s: [Unicode.Scalar], offsets: [Int], start: Int, end: Int, line: Int) {
        self.s = s
        self.offsets = offsets
        self.start = start
        self.end = end
        self.line = line
    }

    mutating func run() {
        var i = start
        while i < end {
            if let next = jumps[i] {
                i = next
                continue
            }
            switch s[i] {
            case "\\":
                i += i + 1 < end && isASCIIPunctuation(s[i + 1]) ? 2 : 1
            case "`":
                i = codeSpan(at: i)
            case "[":
                i = i + 1 < end && s[i + 1] == "[" ? wikiLink(at: i) : link(at: i)
            case "!":
                i = image(at: i)
            case "h", "H":
                i = bareURL(at: i)
            default:
                i += 1
            }
        }
    }

    // MARK: code

    private func codeSpan(at i: Int) -> Int {
        let size = run(of: "`", at: i)
        var j = i + size
        while j < end {
            guard s[j] == "`" else {
                j += 1
                continue
            }
            let closing = run(of: "`", at: j)
            if closing == size, j > i + size { return j + size }
            j += closing
        }
        return i + size
    }

    private func run(of char: Unicode.Scalar, at i: Int) -> Int {
        var n = 0
        while i + n < end, s[i + n] == char { n += 1 }
        return n
    }

    // MARK: links

    private mutating func wikiLink(at i: Int) -> Int {
        var j = i + 2
        var pipe: Int?
        while j + 1 < end {
            let c = s[j]
            if c == "]", s[j + 1] == "]" { break }
            if c == "[" || c == "]" { return i + 1 }
            if c == "|", pipe == nil { pipe = j }
            j += 1
        }
        guard j + 1 < end, j > i + 2 else { return i + 1 }
        let targetEnd = pipe ?? j
        let contentStart = pipe.map { $0 + 1 } ?? i + 2
        guard targetEnd > i + 2, j > contentStart else { return i + 1 }

        // `[[Note\|alias]]` in a table: the backslash belongs to the table.
        var rawEnd = targetEnd
        if pipe != nil, s[rawEnd - 1] == "\\" { rawEnd -= 1 }
        var nameEnd = rawEnd
        var heading: String?
        if let hash = (i + 2..<rawEnd).first(where: { s[$0] == "#" }) {
            nameEnd = hash
            heading = string(hash + 1..<rawEnd)
        }
        var nameStart = i + 2
        while nameStart < nameEnd, WikiLinks.isPadding(s[nameStart]) { nameStart += 1 }
        while nameEnd > nameStart, WikiLinks.isPadding(s[nameEnd - 1]) { nameEnd -= 1 }
        if nameEnd - nameStart > 3, hasMarkdownExtension(endingAt: nameEnd) { nameEnd -= 3 }

        let bang = i > start && s[i - 1] == "!" && !(i - 2 >= start && s[i - 2] == "\\")
        links.append(WikiLink(range: offsets[i]..<offsets[j + 2],
                              name: string(nameStart..<nameEnd),
                              nameRange: offsets[nameStart]..<offsets[nameEnd],
                              heading: heading,
                              alias: pipe.map { string($0 + 1..<j) },
                              isEmbed: bang,
                              line: line))
        return j + 2
    }

    private func hasMarkdownExtension(endingAt e: Int) -> Bool {
        s[e - 3] == "." && (s[e - 2] == "m" || s[e - 2] == "M") && (s[e - 1] == "d" || s[e - 1] == "D")
    }

    /// `[text](url)`: the text is scanned on, since a wiki link can sit in it; the destination is skipped.
    private mutating func link(at i: Int) -> Int {
        guard let (close, after) = linkTail(from: i) else { return i + 1 }
        jumps[close] = after
        return i + 1
    }

    private func image(at i: Int) -> Int {
        guard i + 1 < end, s[i + 1] == "[", let (_, after) = linkTail(from: i + 1) else { return i + 1 }
        return after
    }

    /// From the `[`: the `]` and the end of `(...)`. No nested brackets in the text.
    private func linkTail(from i: Int) -> (close: Int, end: Int)? {
        var j = i + 1
        while j < end, s[j] != "]" {
            if s[j] == "[" { return nil }
            if s[j] == "\\" { j += 1 }
            j += 1
        }
        guard j > i + 1, j + 1 < end, s[j + 1] == "(" else { return nil }
        var depth = 1
        var k = j + 2
        while k < end {
            if s[k] == "(" {
                depth += 1
            } else if s[k] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            k += 1
        }
        guard k < end, depth == 0 else { return nil }
        return (j, k + 1)
    }

    private func bareURL(at i: Int) -> Int {
        if i > start, isWordCharacter(s[i - 1]) { return i + 1 }
        let schemes: [[Unicode.Scalar]] = [Array("http://".unicodeScalars), Array("https://".unicodeScalars)]
        guard let scheme = schemes.first(where: { scheme in
            i + scheme.count <= end && scheme.indices.allSatisfy { lower(s[i + $0]) == scheme[$0] }
        }) else { return i + 1 }
        var e = i + scheme.count
        while e < end, !s[e].properties.isWhitespace, s[e] != "<", s[e] != ">" { e += 1 }
        while e > i + scheme.count {
            let c = s[e - 1]
            if ".,;:!?'\"*_~".unicodeScalars.contains(c) {
                e -= 1
            } else if c == ")", s[i..<e].filter({ $0 == ")" }).count > s[i..<e].filter({ $0 == "(" }).count {
                e -= 1
            } else {
                break
            }
        }
        return e > i + scheme.count ? e : i + 1
    }

    // MARK: characters

    private func string(_ r: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[r])
        return String(view)
    }

    private func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (0x41...0x5A).contains(c.value) ? Unicode.Scalar(c.value + 32)! : c
    }

    private func isASCIIPunctuation(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (0x21...0x2F).contains(v) || (0x3A...0x40).contains(v) || (0x5B...0x60).contains(v) || (0x7B...0x7E).contains(v)
    }

    /// As the editor sees it: it reads UTF-16, where half of a character outside the BMP counts as a word character.
    private func isWordCharacter(_ c: Unicode.Scalar) -> Bool {
        c.value > 0xFFFF || c.properties.isAlphabetic || (0x30...0x39).contains(c.value)
    }
}
