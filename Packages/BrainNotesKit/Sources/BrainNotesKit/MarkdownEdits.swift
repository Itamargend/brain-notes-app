import Foundation

/// The editor's actions as pure functions: from the text and the selection to one replacement and the selection after
/// it. Positions are UTF-16 offsets, the text views' own unit. Only the marks an action is about change; every other
/// byte stays, line endings included. A block action works on every paragraph the selection touches, using the same idea
/// of a paragraph as `NSString` and so the styler. One replacement, so one undo step.
public enum MarkdownEdits {
    public struct Edit: Sendable, Equatable {
        /// What to replace, in the text before the edit.
        public var range: NSRange
        public var replacement: String
        /// The selection after the edit.
        public var selection: NSRange

        /// Nothing to do: the action already holds, as Body does on a line that is no heading.
        public var changesNothing: Bool { range.length == 0 && replacement.isEmpty }

        public func applied(to text: String) -> String {
            (text as NSString).replacingCharacters(in: range, with: replacement)
        }
    }

    public static let rightToLeftMark = "\u{200F}"
    public static let leftToRightMark = "\u{200E}"
    private static let taskMarker = "- [ ] "
    private static let bulletMarker = "- "

    // MARK: block actions

    /// Adds `- [ ] ` at each paragraph's start, or removes the marker if all of them are tasks. A bullet becomes a task.
    /// Toggling twice gives the same bytes back, except that a tick and a bullet can't come back once removed.
    public static func toggleTask(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let all = chosen.allSatisfy { if case .task = $0.line.marker?.kind { true } else { false } }
        var edits: [Change] = []
        for p in chosen {
            switch p.line.marker?.kind {
            case .task?:
                if all { edits.append(Change(absolute(p.line.marker!.range, in: p.range), "")) }
            case .bullet?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), taskMarker))
            default:
                // Before any direction mark: a marker that isn't first on its line is not a marker.
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), taskMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Adds `- ` at each paragraph's start, or removes it if all of them are bullets. A task becomes a bullet.
    public static func toggleBullet(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let all = chosen.allSatisfy { $0.line.marker?.kind == .bullet }
        var edits: [Change] = []
        for p in chosen {
            switch p.line.marker?.kind {
            case .bullet?:
                if all { edits.append(Change(absolute(p.line.marker!.range, in: p.range), "")) }
            case .task?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), bulletMarker))
            default:
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), bulletMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Makes each paragraph a heading of this level, or plain again if all of them already are. A list marker makes way:
    /// `# - [ ] a` would be a heading that reads "- [ ] a". A direction mark stays behind the marker, as `toggleDirection` puts it.
    public static func toggleHeading(_ level: Int, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let wanted = String(repeating: "#", count: min(max(level, 1), 6)) + " "
        let kind = MarkdownLine.Kind.heading(min(max(level, 1), 6))
        let all = chosen.allSatisfy { $0.line.marker?.kind == kind }
        var edits: [Change] = []
        for p in chosen {
            if let marker = p.line.marker {
                if all {
                    edits.append(Change(absolute(marker.range, in: p.range), ""))
                } else if marker.kind != kind {
                    edits.append(Change(absolute(marker.range, in: p.range), wanted))
                }
            } else {
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), wanted))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Body: takes any heading marker off. Lists and everything else stay.
    public static func removeHeading(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        var edits: [Change] = []
        for p in chosenParagraphs(of: ns, selection: selection) {
            if let marker = p.line.marker, case .heading = marker.kind {
                edits.append(Change(absolute(marker.range, in: p.range), ""))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Every tap flips the direction of the paragraph where the selection starts, and the others follow it: a mark that
    /// goes against the text comes off, otherwise one goes in. The mark sits after any block marker (`# `, `- [ ] `, `> `,
    /// `1. `): in front of it, the line would stop being a heading or a list item, on GitHub and in this app's own note
    /// view. Toggling twice gives the same bytes back, unless a paragraph started with a mark that said what its text
    /// already says: that one flips, then comes off.
    public static func toggleDirection(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        guard let first = chosen.first else { return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection) }
        let target = !isRightToLeft(paragraph: String(decoding: first.units, as: UTF16.self))
        var edits: [Change] = []
        for p in chosen where isRightToLeft(paragraph: String(decoding: p.units, as: UTF16.self)) != target {
            let natural = NoteText.isRightToLeft(String(decoding: p.units[p.line.contentStart...], as: UTF16.self))
            let opposite = natural ? leftToRightMark : rightToLeftMark
            if let mark = p.line.mark {
                let saysRightToLeft = p.units[mark] == MarkdownLine.rightToLeftMark
                edits.append(Change(NSRange(location: p.range.location + mark, length: 1), saysRightToLeft == natural ? opposite : ""))
            } else {
                edits.append(Change(NSRange(location: p.range.location + p.line.contentStart, length: 0), opposite))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    // MARK: inline actions

    /// Wraps the selection in `mark` or takes the marks off, whether they are selected too or just outside it. `**`, `*`
    /// and `` ` ``. With only a caret: inside a span of that kind it takes the span's marks off, on a word it wraps the
    /// word, anywhere else it inserts both marks with the caret between them. White space at the selection's ends stays
    /// outside the marks: `**word **` is not bold, and a triple tap selects the line ending too. Marks inside a code span
    /// are text, and a span of code is wrapped whole, since marks inside it would be text too.
    public static func toggleWrap(_ mark: String, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let size = (mark as NSString).length
        let marks = Array(mark.utf16)
        func hasMark(at i: Int) -> Bool {
            guard i >= 0, i + size <= ns.length else { return false }
            return marks.indices.allSatisfy { ns.character(at: i + $0) == marks[$0] }
        }
        /// How many of the mark's character stand together, going forward or back from a position.
        func run(from i: Int, forward: Bool) -> Int {
            var n = 0
            var j = forward ? i : i - 1
            while j >= 0, j < ns.length, ns.character(at: j) == marks[0] {
                n += 1
                j += forward ? 1 : -1
            }
            return n
        }
        /// A run this many long can hold this mark: `*` must not take half of a `**`, while `***` holds either.
        func holdsMark(_ count: Int) -> Bool { size == 1 ? count % 2 == 1 : count >= size }

        let paragraph = paragraphContents(of: ns, at: selection.location)
        let spans = MarkdownInline.line(units: units(of: ns, in: paragraph)).spans.map { span -> MarkdownInline.Span in
            var s = span
            s.open.location += paragraph.location
            s.content.location += paragraph.location
            s.close.location += paragraph.location
            return s
        }
        let kind = spanKind(of: mark)
        let ofKind = spans.filter { $0.kind == kind }
        let code = kind == .code ? nil : spans.filter { $0.kind == .code }

        func unwrap(_ span: MarkdownInline.Span, selection after: NSRange) -> Edit {
            Edit(range: span.whole, replacement: ns.substring(with: span.content), selection: after)
        }

        var chosen = trimmingWhiteSpace(selection, in: ns)
        if chosen.length > 0 {
            if let span = ofKind.first(where: { $0.whole == chosen }) {
                return unwrap(span, selection: NSRange(location: span.whole.location, length: span.content.length))
            }
            if let span = ofKind.first(where: { $0.content == chosen }) {
                return unwrap(span, selection: NSRange(location: span.whole.location, length: span.content.length))
            }
            let start = chosen.location
            let end = NSMaxRange(chosen)
            // Marks that no span explains, as around a selection of several lines.
            if chosen.length >= 2 * size, hasMark(at: start), hasMark(at: end - size), holdsMark(run(from: start, forward: true)), holdsMark(run(from: end, forward: false)) {
                let inner = ns.substring(with: NSRange(location: start + size, length: chosen.length - 2 * size))
                // `**a** and **b**` starts and ends with marks, but they aren't one pair.
                if !inner.contains(mark) {
                    return Edit(range: chosen, replacement: inner,
                                selection: NSRange(location: start, length: (inner as NSString).length))
                }
            }
            if hasMark(at: start - size), hasMark(at: end), holdsMark(run(from: start, forward: false)), holdsMark(run(from: end, forward: true)) {
                return Edit(range: NSRange(location: start - size, length: chosen.length + 2 * size), replacement: ns.substring(with: chosen),
                            selection: NSRange(location: start - size, length: chosen.length))
            }
            if let span = code?.first(where: { $0.whole.location <= chosen.location && NSMaxRange(chosen) <= NSMaxRange($0.whole) }) {
                chosen = span.whole
            }
            return Edit(range: chosen, replacement: mark + ns.substring(with: chosen) + mark,
                        selection: NSRange(location: chosen.location + size, length: chosen.length))
        }

        let caret = selection.location
        // The innermost span of this kind around the caret, touching its marks counts.
        if let span = ofKind.filter({ $0.whole.location <= caret && caret <= NSMaxRange($0.whole) }).min(by: { $0.whole.length < $1.whole.length }) {
            let after = min(max(caret - span.open.length, span.whole.location), span.whole.location + span.content.length)
            return unwrap(span, selection: NSRange(location: after, length: 0))
        }
        // Both marks with nothing between, as this action leaves them. No span, since `****` pairs with nothing.
        let before = run(from: caret, forward: false), after = run(from: caret, forward: true)
        if before == after, holdsMark(before), hasMark(at: caret - size), hasMark(at: caret) {
            return Edit(range: NSRange(location: caret - size, length: 2 * size), replacement: "", selection: NSRange(location: caret - size, length: 0))
        }
        if let span = code?.first(where: { $0.whole.location < caret && caret < NSMaxRange($0.whole) }) {
            return Edit(range: span.whole, replacement: mark + ns.substring(with: span.whole) + mark,
                        selection: NSRange(location: caret + size, length: 0))
        }
        if let word = word(touching: caret, in: paragraph, of: ns) {
            return Edit(range: word, replacement: mark + ns.substring(with: word) + mark,
                        selection: NSRange(location: caret + size, length: 0))
        }
        return Edit(range: NSRange(location: caret, length: 0), replacement: mark + mark,
                    selection: NSRange(location: caret + size, length: 0))
    }

    /// `[[]]` with the caret inside. A selection on one line becomes the link's text, and stays selected.
    public static func insertWikiLink(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = trimmingWhiteSpace(selection, in: ns)
        if chosen.length > 0, NSMaxRange(chosen) <= NSMaxRange(paragraphContents(of: ns, at: chosen.location)) {
            return Edit(range: chosen, replacement: "[[" + ns.substring(with: chosen) + "]]", selection: NSRange(location: chosen.location + 2, length: chosen.length))
        }
        return Edit(range: NSRange(location: selection.location, length: 0), replacement: "[[]]", selection: NSRange(location: selection.location + 2, length: 0))
    }

    /// A tap on a checkbox: one byte, the character between the brackets. Nil if the paragraph at `location` is no task.
    /// The selection stays where it is.
    public static func toggleTick(in text: String, paragraphAt location: Int, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let paragraph = paragraphContents(of: ns, at: min(location, ns.length))
        guard let marker = MarkdownLine(units(of: ns, in: paragraph)).marker, case let .task(done, box) = marker.kind else { return nil }
        return edit(NSRange(location: paragraph.location + box, length: 1), done ? " " : "x", selection: clamped(selection, in: ns))
    }

    // MARK: direction

    /// The direction of one paragraph of Markdown source: its first direction mark if it has one, else its
    /// text's. Block markers don't count, so the `x` in `- [x] שלום` doesn't make that line left to right.
    public static func isRightToLeft(paragraph: String) -> Bool {
        let utf16 = Array(paragraph.utf16)
        let line = MarkdownLine(utf16)
        return NoteText.isRightToLeft(String(decoding: utf16[(line.leadingMark ?? line.marker?.range.upperBound ?? 0)...], as: UTF16.self))
    }

    // MARK: helpers

    private struct Change {
        var range: NSRange
        var replacement: String
        init(_ range: NSRange, _ replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    private struct Paragraph {
        var range: NSRange
        var units: [UInt16]
        var line: MarkdownLine
    }

    private static func spanKind(of mark: String) -> MarkdownInline.Span.Kind? {
        switch mark {
        case "**": .bold
        case "*": .italic
        case "`": .code
        case "~~": .strikethrough
        default: nil
        }
    }

    private static func clamped(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = min(range.location, ns.length)
        return NSRange(location: location, length: min(range.length, ns.length - location))
    }

    /// The paragraphs an action works on: each one the selection touches, not counting one it only reaches the very start
    /// of, as a triple tap does. Blank ones are left out if any other is chosen: nobody wants a task with no text.
    private static func chosenParagraphs(of ns: NSString, selection: NSRange) -> [Paragraph] {
        func paragraph(at location: Int) -> Paragraph {
            let range = paragraphContents(of: ns, at: location)
            let u = units(of: ns, in: range)
            return Paragraph(range: range, units: u, line: MarkdownLine(u))
        }
        let first = paragraph(at: selection.location)
        guard selection.length > 0 else { return [first] }
        var all = [first]
        let lastPosition = NSMaxRange(selection) - 1
        var next = nextParagraphStart(of: ns, after: first.range)
        while let start = next, start <= lastPosition {
            let p = paragraph(at: start)
            all.append(p)
            next = nextParagraphStart(of: ns, after: p.range)
        }
        let withText = all.filter { p in
            !p.units.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == MarkdownLine.rightToLeftMark || $0 == MarkdownLine.leftToRightMark }
        }
        return withText.isEmpty ? [first] : withText
    }

    private static func nextParagraphStart(of ns: NSString, after contents: NSRange) -> Int? {
        var end = 0
        ns.getParagraphStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: contents.location, length: 0))
        return end > NSMaxRange(contents) && end <= ns.length ? end : nil
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
        combined([Change(range, replacement)], in: "", selection: selection)
    }

    /// Several changes in text order, as one replacement from the first to the last.
    private static func combined(_ changes: [Change], in ns: NSString, selection: NSRange) -> Edit {
        func moved(_ p: Int) -> Int {
            var shift = 0
            for change in changes {
                let size = (change.replacement as NSString).length
                if change.range.length == 0 {
                    if p >= change.range.location { shift += size }
                } else if p <= change.range.location {
                    break
                } else if p >= NSMaxRange(change.range) {
                    shift += size - change.range.length
                } else {
                    return change.range.location + shift + size
                }
            }
            return p + shift
        }
        let start = moved(selection.location)
        let after = NSRange(location: start, length: moved(NSMaxRange(selection)) - start)
        guard let first = changes.first, let last = changes.last else {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        }
        if changes.count == 1 { return Edit(range: first.range, replacement: first.replacement, selection: after) }
        var out = ""
        var cursor = first.range.location
        for change in changes {
            out += ns.substring(with: NSRange(location: cursor, length: change.range.location - cursor))
            out += change.replacement
            cursor = NSMaxRange(change.range)
        }
        return Edit(range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), replacement: out, selection: after)
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
