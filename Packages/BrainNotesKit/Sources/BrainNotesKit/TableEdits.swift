import Foundation

/// The note's tables as the editor deals with them, as pure functions like `MarkdownEdits`: where they are, what a grid
/// edit does to the note's text, and what a caret or a keystroke next to one may do. A table's source stays in the
/// note's text, hidden behind the grid, so a caret must never rest in it and nothing typed around it may change it.
/// Positions are UTF-16 offsets, the text views' own unit.
public enum TableEdits {
    /// One table and where it is.
    public struct Span: Sendable, Equatable {
        public var range: NSRange
        public var table: MarkdownTable

        public init(range: NSRange, table: MarkdownTable) {
            self.range = range
            self.table = table
        }
    }

    /// Whether a note can hold a table at all, without reading it: every delimiter row has a pipe, or a colon next to a
    /// dash. A note with neither pays for nothing else here.
    public static func mayHoldTable(_ ns: NSString) -> Bool {
        for mark in ["|", ":-", "-:"] where ns.range(of: mark).location != NSNotFound { return true }
        return false
    }

    /// Every table of a note, in order.
    public static func spans(in text: String) -> [Span] {
        var out: [Span] = []
        var start = 0
        for piece in TableDocument(parsing: text).pieces {
            let length = piece.markdown.utf16.count
            if case let .table(table) = piece {
                out.append(Span(range: NSRange(location: start, length: length), table: table))
            }
            start += length
        }
        return out
    }

    // MARK: grid edits

    /// The smallest replacement in the note that turns this table into `edited`. Nil if that changes nothing.
    public static func edit(of span: Span, to edited: MarkdownTable) -> MarkdownEdits.Edit? {
        replacing(span.table.markdown, with: edited.markdown, at: span.range.location)
    }

    /// The smallest replacement that turns `old`, which starts at `location` in the note, into `new`, with the selection
    /// where it ends. Nil if they are the same.
    public static func replacing(_ old: String, with new: String, at location: Int) -> MarkdownEdits.Edit? {
        guard !old.utf8.elementsEqual(new.utf8) else { return nil }
        var edit = MarkdownEdits.minimal(from: old as NSString, to: new as NSString, selection: NSRange(location: 0, length: 0))
        edit.range.location += location
        edit.selection = NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0)
        return edit
    }

    /// Takes a table out of the note. If that would leave two blank lines in a row, or one at the very top, the blank line
    /// under it goes too.
    public static func deletingTable(_ span: Span, in text: String) -> MarkdownEdits.Edit {
        let ns = text as NSString
        var range = span.range
        let end = NSMaxRange(range)
        let aboveIsClear = range.location == 0 || isBlankLine(before: range.location, in: ns)
        if aboveIsClear, end < ns.length, let blank = blankLine(at: end, in: ns) { range.length += blank.length }
        return MarkdownEdits.Edit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
    }

    /// A blank line above a table, with the caret on it. For a table that starts the note, which has no other way to
    /// write above it.
    public static func addingLine(above span: Span, in text: String) -> MarkdownEdits.Edit {
        let ending = MarkdownEdits.lineEnding(in: text, at: span.range.location)
        return MarkdownEdits.Edit(range: NSRange(location: span.range.location, length: 0), replacement: ending,
                                  selection: NSRange(location: span.range.location, length: 0))
    }

    // MARK: the caret

    public enum CaretVerdict: Sendable, Equatable {
        /// It may stay where it is.
        case stays
        /// The selection has to be this instead.
        case moves(NSRange)
        /// It came to this table from outside it: on into the first cell, or the last.
        case enters(table: Int, atStart: Bool)
    }

    /// Where a selection may be, given where it was. The grid takes the taps, so a caret reaches a table's hidden text only
    /// by the keyboard, or from code: arriving from above it goes on into the first cell, from below into the last, and
    /// with nowhere it came from, to the line below. A selection takes a table whole or not at all: an end that lands in
    /// one moves on past it the way it was going.
    public static func caret(_ selection: NSRange, previous: NSRange?, tables: [NSRange]) -> CaretVerdict {
        func table(holding location: Int) -> Int? {
            tables.firstIndex { $0.location <= location && location < NSMaxRange($0) }
        }
        if selection.length == 0 {
            guard let i = table(holding: selection.location) else { return .stays }
            if let previous {
                if NSMaxRange(previous) <= tables[i].location { return .enters(table: i, atStart: true) }
                if previous.location >= NSMaxRange(tables[i]) { return .enters(table: i, atStart: false) }
            }
            return .moves(NSRange(location: NSMaxRange(tables[i]), length: 0))
        }
        var start = selection.location
        var end = NSMaxRange(selection)
        if let i = table(holding: start), start > tables[i].location {
            let goingForward = previous.map { start > $0.location } ?? false
            start = goingForward ? NSMaxRange(tables[i]) : tables[i].location
        }
        if end > 0, let i = table(holding: end), end > tables[i].location {
            let goingBack = previous.map { end < NSMaxRange($0) } ?? false
            end = goingBack ? tables[i].location : NSMaxRange(tables[i])
        }
        let snapped = NSRange(location: min(start, end), length: abs(end - start))
        return snapped == selection ? .stays : .moves(snapped)
    }

    /// Whether a selection takes in any of a table's text.
    public static func touches(_ selection: NSRange, tables: [NSRange]) -> Bool {
        tables.contains { $0.location < NSMaxRange(selection) && selection.location < NSMaxRange($0) }
    }

    // MARK: typing next to a table

    public enum TypingVerdict: Sendable, Equatable {
        /// Nothing to do with a table.
        case allow
        /// Do this instead: it keeps the table what it was.
        case edit(MarkdownEdits.Edit)
        /// Backspace from the line below, or a caret somehow inside: into the table's first cell, or its last.
        case enters(table: Int, atStart: Bool)
        /// Stay on the note, with the caret here.
        case moveCaret(Int)
        /// Do nothing at all.
        case ignore
    }

    /// What a replacement in the note's text has to be so that no table changes because of it. Text can't go into a table
    /// from outside it: a line right under a table's last row would be another row of it on GitHub, so it gets a blank
    /// line, and a line can't be joined onto a header row.
    public static func typing(_ replacement: String, replacing range: NSRange, in ns: NSString, spans: [Span]) -> TypingVerdict {
        guarded(replacement, replacing: range, in: ns, spans: spans).verdict
    }

    /// An edit from a menu or the bar, made safe in the same way, with its own selection moved along. Nil if it can't be.
    public static func safeguarding(_ edit: MarkdownEdits.Edit, in text: String, spans: [Span]) -> MarkdownEdits.Edit? {
        let found = guarded(edit.replacement, replacing: edit.range, in: text as NSString, spans: spans)
        switch found.verdict {
        case .allow:
            return edit
        case let .edit(safe):
            return MarkdownEdits.Edit(range: safe.range, replacement: safe.replacement,
                                      selection: NSRange(location: edit.selection.location + found.shift, length: edit.selection.length))
        case .enters, .moveCaret, .ignore:
            return nil
        }
    }

    /// The verdict, and how much text it adds in front of the replacement. What it lets through is checked, not assumed:
    /// an edit near a table is tried out, and it stands only if every table it doesn't replace whole is still there, saying
    /// the same. If it isn't, a blank line under the table above, or over the table below, is what keeps them apart.
    private static func guarded(_ replacement: String, replacing range: NSRange, in ns: NSString, spans: [Span]) -> (verdict: TypingVerdict, shift: Int) {
        guard !spans.isEmpty else { return (.allow, 0) }
        let end = NSMaxRange(range)
        func isWhole(_ table: NSRange) -> Bool { range.length > 0 && range.location <= table.location && NSMaxRange(table) <= end }

        // Into a table's own text. Backspace on the line below reaches its last line ending.
        if let i = spans.firstIndex(where: { span in
            let table = span.range
            if isWhole(table) { return false }
            if range.length == 0 { return table.location <= range.location && range.location < NSMaxRange(table) }
            return range.location < NSMaxRange(table) && table.location < end
        }) {
            let isBackspace = replacement.isEmpty && end == NSMaxRange(spans[i].range) && isOnlyLineEnding(range, in: ns)
            if range.length == 0 || isBackspace { return (.enters(table: i, atStart: !isBackspace), 0) }
            // A selection takes tables whole, so this is not from a person.
            return (.ignore, 0)
        }

        // The tables an edit can reach without touching them: the one whose next line it is on, and the one under the
        // block of lines it is in, which that block runs into on GitHub.
        let above = spans.last { NSMaxRange($0.range) <= range.location }?.range
        let below = spans.first { $0.range.location >= end }?.range
        let isUnder = above.map { range.location <= lineEnd(at: NSMaxRange($0), in: ns) } ?? false
        let isOver = below.map { !hasBlankLine(from: end, to: $0.location, in: ns) } ?? false
        guard isUnder || isOver else { return (.allow, 0) }

        func holds(_ written: String, over replaced: NSRange) -> Bool {
            let after = TableEdits.spans(in: ns.replacingCharacters(in: replaced, with: written))
            let delta = (written as NSString).length - replaced.length
            for span in spans where !isWhole(span.range) {
                let location = NSMaxRange(span.range) <= replaced.location ? span.range.location : span.range.location + delta
                let lines = withoutLastLineEnding(span.table.source)
                guard after.contains(where: { $0.range.location == location && withoutLastLineEnding($0.table.source).utf8.elementsEqual(lines.utf8) }) else { return false }
            }
            return true
        }
        if holds(replacement, over: range) { return (.allow, 0) }
        // Deleting the one line ending that keeps them apart: the caret goes there, and it stays.
        if replacement.isEmpty, isOnlyLineEnding(range, in: ns) { return (.moveCaret(range.location), 0) }

        let ending = MarkdownEdits.lineEnding(in: ns as String, at: range.location)
        for (underIt, overIt) in [(true, false), (false, true), (true, true)] where (!underIt || isUnder) && (!overIt || isOver) {
            var start = range.location, stop = end
            var head = "", tail = "", shift = 0
            if underIt, let above {
                start = NSMaxRange(above)
                // A last line with no ending of its own needs one more.
                let prefix = start > 0 && isLineBreak(ns.character(at: start - 1)) ? ending : ending + ending
                shift = (prefix as NSString).length
                head = prefix + ns.substring(with: NSRange(location: start, length: range.location - start))
            }
            if overIt, let below {
                stop = below.location
                tail = ns.substring(with: NSRange(location: end, length: stop - end)) + ending
            }
            let replaced = NSRange(location: start, length: stop - start)
            guard holds(head + replacement + tail, over: replaced) else { continue }
            let caret = start + ((head + replacement) as NSString).length
            return (.edit(MarkdownEdits.Edit(range: replaced, replacement: head + replacement + tail, selection: NSRange(location: caret, length: 0))), shift)
        }
        return (.ignore, 0)
    }

    /// Whether a line with nothing on it stands between these offsets, going up from the second, which starts a line. Not
    /// one that starts at the first: an edit ending there can join it to the line above.
    private static func hasBlankLine(from start: Int, to location: Int, in ns: NSString) -> Bool {
        var at = location
        while at > start {
            var lineStart = 0, contentsEnd = 0
            ns.getParagraphStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: at - 1, length: 0))
            guard lineStart > start else { return false }
            let isBlank = (lineStart..<contentsEnd).allSatisfy {
                let unit = ns.character(at: $0)
                return unit == 0x20 || unit == 0x09
            }
            if isBlank { return true }
            at = lineStart
        }
        return false
    }

    private static func withoutLastLineEnding(_ text: String) -> String {
        var units = Array(text.utf16)
        if units.last == 0x0A { units.removeLast() }
        if units.last == 0x0D { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }

    /// One line ending and nothing else: `\n`, `\r` or `\r\n`.
    private static func isOnlyLineEnding(_ range: NSRange, in ns: NSString) -> Bool {
        guard range.length == 1 || range.length == 2, NSMaxRange(range) <= ns.length else { return false }
        let first = ns.character(at: range.location)
        if range.length == 1 { return isLineBreak(first) }
        return first == 0x0D && ns.character(at: range.location + 1) == 0x0A
    }

    /// Where the line at this offset ends, without its line ending.
    private static func lineEnd(at location: Int, in ns: NSString) -> Int {
        var contentsEnd = 0
        ns.getParagraphStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(location, ns.length), length: 0))
        return contentsEnd
    }

    /// The line above this offset, which starts a line, holds no text.
    private static func isBlankLine(before location: Int, in ns: NSString) -> Bool {
        guard location > 0 else { return true }
        var start = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location - 1, length: 0))
        return ns.substring(with: NSRange(location: start, length: contentsEnd - start)).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The line at this offset, line ending included, if it holds no text.
    private static func blankLine(at location: Int, in ns: NSString) -> NSRange? {
        var start = 0, end = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        guard ns.substring(with: NSRange(location: start, length: contentsEnd - start)).allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
