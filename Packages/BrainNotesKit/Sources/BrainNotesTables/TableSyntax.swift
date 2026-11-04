// The byte-level rules for GFM pipe tables. Everything works on UTF-8 bytes: the marks that matter (pipe, backslash,
// colon, dash, space, tab, line ends) are ASCII, and no byte of a multi-byte character is ever ASCII, so cutting at
// them never splits a Hebrew letter or an emoji. No Foundation, so this builds the same on Linux.

enum TableSyntax {
    static let pipe: UInt8 = 0x7C
    static let backslash: UInt8 = 0x5C
    static let space: UInt8 = 0x20
    static let tab: UInt8 = 0x09
    static let colon: UInt8 = 0x3A
    static let dash: UInt8 = 0x2D
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let backtick: UInt8 = 0x60
    static let tilde: UInt8 = 0x7E
    static let hash: UInt8 = 0x23
    static let greaterThan: UInt8 = 0x3E

    typealias Bytes = ArraySlice<UInt8>

    static func string(_ b: Bytes) -> String { String(decoding: b, as: UTF8.self) }

    static func isSpaceOrTab(_ b: UInt8) -> Bool { b == space || b == tab }

    static func isBlank(_ b: Bytes) -> Bool { b.allSatisfy(isSpaceOrTab) }

    // MARK: lines

    /// One line: its bytes run from `start` to `bodyEnd`, then its ending (`\n`, `\r\n`, `\r` or nothing) up to `end`.
    struct LineSpan: Equatable {
        var start: Int
        var bodyEnd: Int
        var end: Int
    }

    static func lines(_ b: [UInt8], from first: Int = 0) -> [LineSpan] {
        var out: [LineSpan] = []
        var start = first
        var i = first
        while i < b.count {
            if b[i] == lf {
                out.append(LineSpan(start: start, bodyEnd: i, end: i + 1))
                i += 1
                start = i
            } else if b[i] == cr {
                let end = i + 1 < b.count && b[i + 1] == lf ? i + 2 : i + 1
                out.append(LineSpan(start: start, bodyEnd: i, end: end))
                i = end
                start = i
            } else {
                i += 1
            }
        }
        if start < b.count { out.append(LineSpan(start: start, bodyEnd: b.count, end: b.count)) }
        return out
    }

    // MARK: indent and other blocks

    /// The spaces and tabs a line starts with, counted in columns (a tab goes to the next multiple of 4), and the rest.
    /// `from` is the column the bytes start at, for tab stops; the count is of the indent only.
    static func indent(_ b: Bytes, from start: Int = 0) -> (columns: Int, end: Int) {
        var column = start
        var i = b.startIndex
        while i < b.endIndex, isSpaceOrTab(b[i]) {
            column = b[i] == tab ? column + 4 - column % 4 : column + 1
            i += 1
        }
        return (column - start, i)
    }

    /// A fence opening: three or more backticks or tildes. A backtick fence's info text can't hold a backtick.
    static func fenceOpening(_ rest: Bytes) -> (mark: UInt8, count: Int)? {
        guard let mark = rest.first, mark == backtick || mark == tilde else { return nil }
        var count = 0
        for b in rest {
            if b == mark { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        if mark == backtick && rest.dropFirst(count).contains(backtick) { return nil }
        return (mark, count)
    }

    /// Whether this line closes a fence opened with `mark` repeated `count` times.
    static func closesFence(_ line: Bytes, mark: UInt8, count: Int, base: Int = 0) -> Bool {
        let (columns, at) = indent(line)
        guard columns >= base, columns - base <= 3 else { return false }
        let rest = line[at...]
        var run = 0
        for b in rest {
            if b == mark { run += 1 } else { break }
        }
        return run >= count && isBlank(rest.dropFirst(run))
    }

    /// Whether `rest` (a line after at most 3 columns of indent) starts some other block: a quote, a heading, a fence,
    /// a thematic break or a list item. Such a line ends a table and can't be its header row.
    static func startsBlock(_ rest: Bytes) -> Bool {
        guard let first = rest.first else { return false }
        func endsMarker(_ i: Int) -> Bool { i == rest.endIndex || isSpaceOrTab(rest[i]) }
        switch first {
        case greaterThan:
            return true
        case hash:
            var i = rest.startIndex
            while i < rest.endIndex, rest[i] == hash { i += 1 }
            return i - rest.startIndex <= 6 && endsMarker(i)
        case backtick, tilde:
            return fenceOpening(rest) != nil
        case dash, 0x2A, 0x2B, 0x5F: // - * + _
            if first != 0x5F && endsMarker(rest.startIndex + 1) { return true }
            if first == 0x2B { return false }
            let marks = rest.filter { !isSpaceOrTab($0) }
            return marks.count >= 3 && marks.allSatisfy { $0 == first }
        case 0x30...0x39:
            var i = rest.startIndex
            while i < rest.endIndex, (0x30...0x39).contains(rest[i]) { i += 1 }
            guard i - rest.startIndex <= 9, i < rest.endIndex, rest[i] == 0x2E || rest[i] == 0x29 else { return false }
            return endsMarker(i + 1)
        default:
            return false
        }
    }

    /// A line that is one pipe and nothing else but spaces: GitHub reads it as a row of no cells, so it can't be a
    /// header and it ends a table, and the line becomes text.
    static func isLonePipe(_ rest: Bytes) -> Bool {
        rest.first == pipe && isBlank(rest.dropFirst())
    }

    /// A list item's marker (`-`, `*`, `+`, or up to 9 digits and `.` or `)`) at the start of `rest`: where it ends, and
    /// its number. Nil if `rest` starts no item (a thematic break like `- - -` starts none).
    static func listMarker(_ rest: Bytes) -> (end: Int, number: Int?)? {
        guard let first = rest.first else { return nil }
        var i = rest.startIndex
        var number: Int?
        if first == dash || first == 0x2A || first == 0x2B {
            i += 1
        } else if (0x30...0x39).contains(first) {
            var n = 0
            while i < rest.endIndex, (0x30...0x39).contains(rest[i]), i - rest.startIndex < 9 {
                n = n * 10 + Int(rest[i] - 0x30)
                i += 1
            }
            guard i < rest.endIndex, rest[i] == 0x2E || rest[i] == 0x29 else { return nil }
            number = n
            i += 1
        } else {
            return nil
        }
        guard i == rest.endIndex || isSpaceOrTab(rest[i]) else { return nil }
        if number == nil {
            let marks = rest.filter { !isSpaceOrTab($0) }
            if marks.count >= 3 && marks.allSatisfy({ $0 == first }) { return nil }
        }
        return (i, number)
    }

    /// Whether a line that starts a block (see `startsBlock`) ends a paragraph above it. A list item does only if it
    /// has text and, when numbered, starts at 1; else the line just continues the paragraph.
    static func interruptsParagraph(_ rest: Bytes) -> Bool {
        guard let (end, number) = listMarker(rest) else { return true }
        if let number, number != 1 { return false }
        return !isBlank(rest[end...])
    }

    struct Fence {
        var mark: UInt8
        var count: Int
        /// The text column of the list item it is in, 0 outside any.
        var base: Int
    }

    /// What a line that starts a block opens (`rest` comes after its indent of `columns`): the text columns of the
    /// list items it starts, outermost first, a fence if it opens one, and what its own text is, for the next line.
    static func opening(_ rest: Bytes, columns: Int) -> (items: [Int], fence: Fence?, text: TableDocument.LastText, isEmptyItem: Bool) {
        var items: [Int] = []
        var rest = rest
        var column = columns
        while true {
            if let open = fenceOpening(rest) { return (items, Fence(mark: open.mark, count: open.count, base: items.last ?? 0), .none, false) }
            if rest.first == greaterThan {
                // `>` and the space after it: what follows is indented code from 4 more columns on.
                let content = rest.dropFirst()
                let (after, at) = indent(content, from: column + 1)
                if isBlank(content) || after > 4 { return (items, nil, .none, false) }
                if startsBlock(content[at...]) && opening(content[at...], columns: 0).text == .none { return (items, nil, .none, false) }
                return (items, nil, .quote, false)
            }
            guard let marker = listMarker(rest) else { return (items, nil, .none, false) }
            let markerColumns = column + (marker.end - rest.startIndex)
            let (spaces, k) = indent(rest[marker.end...], from: markerColumns)
            let content = rest[k...]
            // An empty item, or one whose text is indented code, has its text one column past the marker.
            if isBlank(content) || spaces > 4 {
                items.append(markerColumns + 1)
                return (items, nil, .none, isBlank(content))
            }
            column = markerColumns + spaces
            items.append(column)
            guard startsBlock(content) else { return (items, nil, .paragraph, false) }
            rest = content
        }
    }

    /// `===` or `---` under a paragraph makes it a heading.
    static func isSetextUnderline(_ rest: Bytes) -> Bool {
        guard let first = rest.first, first == 0x3D || first == dash else { return false }
        var i = rest.startIndex
        while i < rest.endIndex, rest[i] == first { i += 1 }
        return isBlank(rest[i...])
    }

    /// A delimiter row: every cell a marker. With no pipe it needs a colon, or it would be a heading's underline.
    static func isDelimiterRow(_ row: ParsedRow) -> Bool {
        guard !row.row.cells.isEmpty, row.row.cells.allSatisfy({ isMarker($0.raw) }) else { return false }
        return row.pipes > 0 || row.row.cells.contains { $0.raw.utf8.contains(colon) }
    }

    // MARK: rows

    struct ParsedRow {
        var row: MarkdownTable.Row
        /// Pipes that split cells, so not counting escaped ones.
        var pipes: Int
        var indentColumns: Int
    }

    /// Splits one line (without its ending) into indent, optional outer pipes and cells. A pipe right after a
    /// backslash stays in its cell, whatever comes before the backslash: GitHub's own scanner (cmark-gfm) does the
    /// same, and pipes inside backticks split cells there too unless escaped.
    static func parseRow(_ b: Bytes, lineEnding: String) -> ParsedRow {
        let (columns, at) = indent(b)
        var parts: [Bytes] = []
        var start = at
        var i = at
        while i < b.endIndex {
            if b[i] == pipe && !(i > b.startIndex && b[i - 1] == backslash) {
                parts.append(b[start..<i])
                start = i + 1
            }
            i += 1
        }
        parts.append(b[start..<b.endIndex])
        let pipes = parts.count - 1

        var leadingPipe = false
        var trailingPipe = false
        var trail: Bytes = []
        if pipes > 0 && parts[0].isEmpty {
            leadingPipe = true
            parts.removeFirst()
        }
        if parts.count >= 2, let last = parts.last, isBlank(last) {
            trailingPipe = true
            trail = last
            parts.removeLast()
        }
        let row = MarkdownTable.Row(
            indent: string(b[b.startIndex..<at]),
            leadingPipe: leadingPipe,
            cells: parts.map { cell($0) },
            trailingPipe: trailingPipe,
            trail: string(trail),
            lineEnding: lineEnding,
            original: string(b)
        )
        return ParsedRow(row: row, pipes: pipes, indentColumns: columns)
    }

    /// One cell's bytes as padding before, content, padding after. A cell of only spaces keeps them all in front.
    static func cell(_ p: Bytes) -> MarkdownTable.Cell {
        var s = p.startIndex
        var e = p.endIndex
        while s < e, isSpaceOrTab(p[s]) { s += 1 }
        while e > s, isSpaceOrTab(p[e - 1]) { e -= 1 }
        return MarkdownTable.Cell(leading: string(p[p.startIndex..<s]), raw: string(p[s..<e]), trailing: string(p[e..<p.endIndex]))
    }

    /// A delimiter cell: optional colon, one or more dashes, optional colon.
    static func isMarker(_ raw: String) -> Bool {
        var b = Array(raw.utf8)[...]
        if b.first == colon { b = b.dropFirst() }
        if b.last == colon { b = b.dropLast() }
        return !b.isEmpty && b.allSatisfy { $0 == dash }
    }

    static func alignment(of raw: String) -> MarkdownTable.Alignment {
        let b = Array(raw.utf8)
        switch (b.first == colon, b.last == colon) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    /// A delimiter cell for this alignment, as wide as `width` where it can be, so a lined-up table stays lined up.
    static func marker(_ alignment: MarkdownTable.Alignment, width: Int = 3) -> String {
        let colons = alignment == .center ? 2 : (alignment == .none ? 0 : 1)
        let dashes = String(repeating: "-", count: max(1, width - colons))
        switch alignment {
        case .none: return dashes
        case .left: return ":" + dashes
        case .right: return dashes + ":"
        case .center: return ":" + dashes + ":"
        }
    }

    // MARK: cell text

    /// What a cell says: its content with `\|` read as `|`. Every other escape is Markdown's and stays.
    static func unescape(_ raw: String) -> String {
        guard raw.utf8.contains(pipe) else { return raw }
        let b = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            if b[i] == backslash && i + 1 < b.count && b[i + 1] == pipe {
                out.append(pipe)
                i += 2
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The content to write for a text: line breaks become spaces (a row is one line), the ends are trimmed (GitHub
    /// trims them anyway), and every `|` is written `\|`. The exact inverse of `unescape` on what comes out.
    static func escape(_ text: String) -> String {
        var b: [UInt8] = []
        let input = Array(text.utf8)
        b.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let c = input[i]
            if c == cr || c == lf {
                b.append(space)
                i += c == cr && i + 1 < input.count && input[i + 1] == lf ? 2 : 1
                continue
            }
            if c == pipe { b.append(backslash) }
            b.append(c)
            i += 1
        }
        var s = 0
        var e = b.count
        while s < e, isSpaceOrTab(b[s]) { s += 1 }
        while e > s, isSpaceOrTab(b[e - 1]) { e -= 1 }
        return String(decoding: b[s..<e], as: UTF8.self)
    }

    // MARK: direction

    /// Unicode bidi rule P2, as `NoteText.isRightToLeft` in the kit: the direction of the first strong character.
    static func isRightToLeft(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x200F: return true // RLM
            case 0x200E: return false // LRM
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                if u.properties.isAlphabetic || u.properties.generalCategory == .otherLetter { return true }
            default:
                if u.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}
