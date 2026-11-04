import Foundation

/// The keyboard bar's actions as pure functions: from the text and the selection to one replacement and the
/// selection after it. Positions are UTF-16 offsets, the text views' own unit. Only the marks an action is
/// about change; every other byte stays, line endings included. An action works on the paragraph where the
/// selection starts, using the same idea of a paragraph as `NSString` and so the styler.
public enum MarkdownEdits {
    public struct Edit: Sendable, Equatable {
        /// What to replace, in the text before the edit.
        public var range: NSRange
        public var replacement: String
        /// The selection after the edit.
        public var selection: NSRange

        func applied(to text: String) -> String {
            (text as NSString).replacingCharacters(in: range, with: replacement)
        }
    }

    public static let rightToLeftMark = "\u{200F}"
    public static let leftToRightMark = "\u{200E}"
    private static let taskMarker = "- [ ] "

    // MARK: actions

    /// Adds `- [ ] ` at the paragraph's start, or removes a task marker that is there. A bullet becomes a task.
    /// Toggling twice gives the same bytes back, except that a tick and a bullet can't come back once removed.
    public static func toggleTask(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let paragraph = paragraphContents(of: ns, at: selection.location)
        let line = Line(units(of: ns, in: paragraph))
        let range: NSRange
        let replacement: String
        switch line.marker?.kind {
        case .task?:
            range = absolute(line.marker!.range, in: paragraph)
            replacement = ""
        case .bullet?:
            range = absolute(line.marker!.range, in: paragraph)
            replacement = taskMarker
        default:
            // Before any direction mark: a marker that isn't first on its line is not a marker.
            range = NSRange(location: paragraph.location + line.indentEnd, length: 0)
            replacement = taskMarker
        }
        return edit(range, replacement, selection: selection)
    }

    /// Every tap flips the paragraph's direction: a mark that goes against the text comes off, otherwise one
    /// goes in. The mark sits after any block marker (`# `, `- [ ] `, `> `, `1. `): in front of it, the line
    /// would stop being a heading or a list item, on GitHub and in this app's own note view.
    /// Toggling twice gives the same bytes back, unless the paragraph started with a mark that said what its
    /// text already says: that one flips, then comes off.
    public static func toggleDirection(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let paragraph = paragraphContents(of: ns, at: selection.location)
        let utf16 = units(of: ns, in: paragraph)
        let line = Line(utf16)
        let natural = NoteText.isRightToLeft(String(decoding: utf16[line.contentStart...], as: UTF16.self))
        let opposite = natural ? leftToRightMark : rightToLeftMark
        guard let mark = line.mark else {
            return edit(NSRange(location: paragraph.location + line.contentStart, length: 0), opposite, selection: selection)
        }
        let saysRightToLeft = utf16[mark] == Line.rightToLeftMark
        return edit(NSRange(location: paragraph.location + mark, length: 1), saysRightToLeft == natural ? opposite : "", selection: selection)
    }

    /// Wraps the selection in `mark` or takes the marks off, whether they are selected too or just outside it.
    /// With only a caret: inside a marked span it takes that span's marks off, on a word it wraps the word,
    /// anywhere else it inserts both marks with the caret between them. White space at the selection's ends
    /// stays outside the marks: `**word **` is not bold, and a triple tap selects the line ending too.
    /// Tested with `**`. A single `*` would also need to not take half of a `**` for its own.
    public static func toggleWrap(_ mark: String, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let size = (mark as NSString).length
        let marks = Array(mark.utf16)
        func hasMark(at i: Int) -> Bool {
            guard i >= 0, i + size <= ns.length else { return false }
            return marks.indices.allSatisfy { ns.character(at: i + $0) == marks[$0] }
        }

        let chosen = trimmingWhiteSpace(selection, in: ns)
        if chosen.length > 0 {
            let start = chosen.location
            let end = NSMaxRange(chosen)
            if chosen.length >= 2 * size, hasMark(at: start), hasMark(at: end - size) {
                let inner = ns.substring(with: NSRange(location: start + size, length: chosen.length - 2 * size))
                // `**a** and **b**` starts and ends with marks, but they aren't one pair.
                if !inner.contains(mark) {
                    return Edit(range: chosen, replacement: inner,
                                selection: NSRange(location: start, length: (inner as NSString).length))
                }
            }
            let selected = ns.substring(with: chosen)
            if hasMark(at: start - size), hasMark(at: end) {
                return Edit(range: NSRange(location: start - size, length: chosen.length + 2 * size), replacement: selected,
                            selection: NSRange(location: start - size, length: chosen.length))
            }
            return Edit(range: chosen, replacement: mark + selected + mark,
                        selection: NSRange(location: start + size, length: chosen.length))
        }

        let caret = selection.location
        let paragraph = paragraphContents(of: ns, at: caret)
        if let (open, close) = markedSpan(around: caret, in: paragraph, size: size, hasMark: hasMark) {
            let inner = ns.substring(with: NSRange(location: open + size, length: close - open - size))
            let after = min(max(caret - size, open), open + (inner as NSString).length)
            return Edit(range: NSRange(location: open, length: close + size - open), replacement: inner,
                        selection: NSRange(location: after, length: 0))
        }
        if let word = word(touching: caret, in: paragraph, of: ns) {
            return Edit(range: word, replacement: mark + ns.substring(with: word) + mark,
                        selection: NSRange(location: caret + size, length: 0))
        }
        return Edit(range: NSRange(location: caret, length: 0), replacement: mark + mark,
                    selection: NSRange(location: caret + size, length: 0))
    }

    // MARK: direction

    /// The direction of one paragraph of Markdown source: its first direction mark if it has one, else its
    /// text's. Block markers don't count, so the `x` in `- [x] שלום` doesn't make that line left to right.
    public static func isRightToLeft(paragraph: String) -> Bool {
        let utf16 = Array(paragraph.utf16)
        let line = Line(utf16)
        return NoteText.isRightToLeft(String(decoding: utf16[(line.leadingMark ?? line.marker?.range.upperBound ?? 0)...], as: UTF16.self))
    }

    // MARK: one line, taken apart

    /// `<indent><mark?><block marker?><mark?><text>`, in offsets from the paragraph's start.
    private struct Line {
        enum Kind { case task, bullet, other }

        static let rightToLeftMark: UInt16 = 0x200F
        static let leftToRightMark: UInt16 = 0x200E

        var indentEnd = 0
        /// A mark in front of the block marker. This app doesn't write that form, but a note can have it.
        var leadingMark: Int?
        var marker: (range: Range<Int>, kind: Kind)?
        var trailingMark: Int?
        var contentStart = 0

        var mark: Int? { leadingMark ?? trailingMark }

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
            contentStart = i
        }

        private static func marker(in u: [UInt16], at i: Int) -> (range: Range<Int>, kind: Kind)? {
            func at(_ offset: Int) -> UInt16? { i + offset < u.count ? u[i + offset] : nil }
            let space: UInt16 = 0x20
            switch at(0) {
            case 0x2D?, 0x2A?, 0x2B?: // - * +
                guard at(1) == space else { return nil }
                let tick = at(3)
                if at(2) == 0x5B, tick == space || tick == 0x78 || tick == 0x58, at(4) == 0x5D, at(5) == space { // [ ], [x], [X]
                    return (i..<(i + 6), .task)
                }
                return (i..<(i + 2), .bullet)
            case 0x23?: // #
                var level = 1
                while at(level) == 0x23 { level += 1 }
                guard level <= 6, at(level) == space || at(level) == 0x09 else { return nil }
                return (i..<(i + level + 1), .other)
            case 0x3E?: // >
                return at(1) == space ? (i..<(i + 2), .other) : nil
            default:
                var digits = 0
                while let d = at(digits), (0x30...0x39).contains(d) { digits += 1 }
                guard (1...9).contains(digits), at(digits) == 0x2E || at(digits) == 0x29, at(digits + 1) == space else { return nil } // . )
                return (i..<(i + digits + 2), .other)
            }
        }
    }

    // MARK: helpers

    private static func clamped(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = min(range.location, ns.length)
        return NSRange(location: location, length: min(range.length, ns.length - location))
    }

    /// The paragraph at `location`, without its line ending.
    private static func paragraphContents(of ns: NSString, at location: Int) -> NSRange {
        var start = 0
        var contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    private static func units(of ns: NSString, in range: NSRange) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: range.length)
        ns.getCharacters(&buffer, range: range)
        return buffer
    }

    private static func absolute(_ range: Range<Int>, in paragraph: NSRange) -> NSRange {
        NSRange(location: paragraph.location + range.lowerBound, length: range.count)
    }

    /// One replacement, with the selection following the text around it. A caret where text goes in ends up
    /// after it, so that what is typed next follows the marker.
    private static func edit(_ range: NSRange, _ replacement: String, selection: NSRange) -> Edit {
        let size = (replacement as NSString).length
        func moved(_ p: Int) -> Int {
            if range.length == 0 { return p >= range.location ? p + size : p }
            if p <= range.location { return p }
            if p >= NSMaxRange(range) { return p + size - range.length }
            return range.location + size
        }
        let start = moved(selection.location)
        return Edit(range: range, replacement: replacement, selection: NSRange(location: start, length: moved(NSMaxRange(selection)) - start))
    }

    private static func trimmingWhiteSpace(_ range: NSRange, in ns: NSString) -> NSRange {
        let white = CharacterSet.whitespacesAndNewlines
        func isWhite(_ i: Int) -> Bool { Unicode.Scalar(ns.character(at: i)).map(white.contains) ?? false }
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhite(start) { start += 1 }
        while end > start, isWhite(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The pair of marks whose span holds the caret, touching the marks included. Marks pair up in order within
    /// the paragraph: first with second, third with fourth.
    private static func markedSpan(around caret: Int, in paragraph: NSRange, size: Int, hasMark: (Int) -> Bool) -> (open: Int, close: Int)? {
        var open: Int?
        var i = paragraph.location
        while i + size <= NSMaxRange(paragraph) {
            guard hasMark(i) else {
                i += 1
                continue
            }
            if let start = open {
                if start <= caret, caret <= i + size { return (start, i) }
                open = nil
            } else {
                open = i
            }
            i += size
        }
        return nil
    }

    private static func word(touching caret: Int, in paragraph: NSRange, of ns: NSString) -> NSRange? {
        var found: NSRange?
        ns.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, word, _, stop in
            if word.location > caret {
                stop.pointee = true
            } else if caret <= NSMaxRange(word) {
                found = word
                stop.pointee = true
            }
        }
        return found
    }
}
