import Foundation

extension MarkdownLine.Kind {
    var isListItem: Bool {
        switch self {
        case .task, .bullet, .numbered: true
        case .heading, .quote: false
        }
    }
}

extension MarkdownEdits.Paragraph {
    var isItem: Bool { line.marker?.kind.isListItem == true }

    /// Columns of indent.
    var width: Int { MarkdownLine.width(units, upTo: line.indentEnd) }

    /// What the marker itself takes: `- ` for a task too, whose `[ ] ` is part of its text to Markdown.
    var markerWidth: Int {
        guard let marker = line.marker else { return 0 }
        if case .numbered = marker.kind { return marker.range.count }
        return 2
    }

    /// Where this item's text starts: how far in to write what is nested under it, so that GitHub nests it too.
    var column: Int { width + markerWidth }

    var numberRange: Range<Int>? {
        guard let marker = line.marker, marker.kind == .numbered else { return nil }
        return marker.range.lowerBound..<(marker.range.upperBound - 2)
    }

    var number: Int? { numberRange.flatMap { Int(String(decoding: units[$0], as: UTF16.self)) } }

    /// `.` or `)`. Another one is another list, to Markdown.
    var delimiter: UInt16? { numberRange.map { units[$0.upperBound] } }

    var isBlank: Bool { units.allSatisfy(MarkdownEdits.isBlankUnit) }
}

/// Lists, as the editor's actions see them. A list is the lines that follow each other: a blank line ends it, and so does a
/// line of plain text that isn't indented. A number is only ever changed by an action on a list: rendering, and typing in
/// the text of an item, leave every number as the file has it.
///
/// What is nested is what is at least 2 columns further in than the item above. Markdown's own rule, its text's column, moves
/// when a number gets a digit, so `10. a` would turn a `   1. x` under it into its sibling, number 11. Reading it this way
/// also keeps the 2 space lists people write by hand as they look here. What `indent` writes is the exact column.
extension MarkdownEdits {
    private static let numberMarker = "1. "
    private static let nestingWidth = 2

    static func isBlankUnit(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == MarkdownLine.rightToLeftMark || unit == MarkdownLine.leftToRightMark
    }

    static func paragraph(at location: Int, in ns: NSString) -> Paragraph {
        let range = paragraphContents(of: ns, at: location)
        let u = units(of: ns, in: range)
        return Paragraph(range: range, units: u, line: MarkdownLine(u))
    }

    // MARK: the number button

    /// Adds `1. ` at each paragraph's start, numbered in turn, or removes the marker if all of them are numbered. A bullet or
    /// a task becomes a number. What follows in the list is numbered on from there, and if the paragraph leaves a list,
    /// what comes after it starts again at 1.
    public static func toggleNumbered(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let all = chosen.allSatisfy { $0.line.marker?.kind == .numbered }
        var changes: [Change] = []
        for p in chosen {
            switch p.line.marker?.kind {
            case .numbered?:
                if all { changes.append(Change(absolute(p.line.marker!.range, in: p.range), "")) }
            case .bullet?, .task?:
                changes.append(Change(absolute(p.line.marker!.range, in: p.range), numberMarker))
            default:
                changes.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), numberMarker))
            }
        }
        return numbering(after: combined(changes, in: ns, selection: selection), in: ns, restartBelow: all)
    }

    // MARK: indent and outdent

    /// Nests each list item the selection touches one level deeper, under the item above it: as far in as that item's text
    /// starts, or Markdown would call it the same list. What is nested under an item goes with it. Other paragraphs stay.
    public static func indent(in text: String, selection: NSRange) -> Edit {
        shifting(text, selection: selection) { p, ns, fences in
            let above = itemAbove(p, in: ns, fences: fences) { $0.width <= p.width }
            if let above, p.width < above.width + nestingWidth { return above.column }
            return p.width + p.markerWidth
        }
    }

    /// Takes each list item the selection touches one level out, level with the item it was nested under.
    public static func outdent(in text: String, selection: NSRange) -> Edit {
        shifting(text, selection: selection) { p, ns, fences in
            outdentTarget(of: p, in: ns, fences: fences)
        }
    }

    private static func outdentTarget(of p: Paragraph, in ns: NSString, fences: FencedCode) -> Int {
        guard let above = itemAbove(p, in: ns, fences: fences, where: { $0.width < p.width }) else { return max(0, p.width - p.markerWidth) }
        return p.width > above.column ? above.column : above.width
    }

    private static func shifting(_ text: String, selection: NSRange, to target: (Paragraph, NSString, FencedCode) -> Int) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let fences = FencedCode(text: ns)
        var changes: [Change] = []
        var movedUpTo = 0
        for p in chosenParagraphs(of: ns, selection: selection) where p.isItem && fences.role(ofParagraphAt: p.range.location) == .none && p.range.location >= movedUpTo {
            let goal = target(p, ns, fences)
            guard goal != p.width else { continue }
            let moved = reindentingWithWhatIsNested(p, to: goal, in: ns, fences: fences)
            changes += moved.changes
            movedUpTo = moved.end
        }
        return numbering(after: combined(changes, in: ns, selection: selection), in: ns)
    }

    /// An item's new indent, and the same move for what is nested under it. `end`: where the last of them ends.
    private static func reindentingWithWhatIsNested(_ p: Paragraph, to goal: Int, in ns: NSString, fences: FencedCode) -> (changes: [Change], end: Int) {
        var changes = [reindenting(p, to: goal)]
        var end = NSMaxRange(p.range)
        let width = p.width
        var next = nextParagraphStart(of: ns, after: p.range)
        while let start = next {
            let q = paragraph(at: start, in: ns)
            guard isInList(q, fences), q.width > width else { break }
            changes.append(reindenting(q, to: q.width + goal - width))
            end = NSMaxRange(q.range)
            next = nextParagraphStart(of: ns, after: q.range)
        }
        return (changes, end)
    }

    private static func reindenting(_ p: Paragraph, to width: Int) -> Change {
        Change(NSRange(location: p.range.location, length: p.line.indentEnd), String(repeating: " ", count: width))
    }

    /// In a list: an item, or an indented line that goes with the item above it.
    private static func isInList(_ p: Paragraph, _ fences: FencedCode) -> Bool {
        guard fences.role(ofParagraphAt: p.range.location) == .none, !p.isBlank else { return false }
        return p.isItem || p.line.indentEnd > 0
    }

    /// The nearest item above this one in its list that `test` accepts.
    private static func itemAbove(_ p: Paragraph, in ns: NSString, fences: FencedCode, where test: (Paragraph) -> Bool) -> Paragraph? {
        var start = p.range.location
        while start > 0 {
            var previous = 0
            ns.getParagraphStart(&previous, end: nil, contentsEnd: nil, for: NSRange(location: start - 1, length: 0))
            let q = paragraph(at: previous, in: ns)
            guard isInList(q, fences) else { return nil }
            if q.isItem, test(q) { return q }
            start = previous
        }
        return nil
    }

    // MARK: Return in a list item

    /// `at` is behind the item's marker. With text, the item goes on: a new one of the same kind, its number the next, a task
    /// unticked, carrying a direction mark if this one has one, with what was behind the caret. With no text, the list ends
    /// here: one level out if it is nested, or the marker goes and the line stays, with what follows starting again at 1.
    static func returnInItem(_ p: Paragraph, at place: LinePlace, ending: String, in ns: NSString) -> Edit {
        let item = p.line
        guard let marker = item.marker else { return inserting(ending, at: p.range.location + place.at) }
        if p.units[item.contentStart...].allSatisfy(isBlankUnit) {
            let caret = NSRange(location: p.range.location + item.contentStart, length: 0)
            if item.indentEnd > 0 {
                let fences = FencedCode(text: ns)
                let moved = reindentingWithWhatIsNested(p, to: outdentTarget(of: p, in: ns, fences: fences), in: ns, fences: fences)
                return numbering(after: combined(moved.changes, in: ns, selection: caret), in: ns)
            }
            let edit = combined([Change(p.range, "")], in: ns, selection: caret)
            return marker.kind == .numbered ? numbering(after: edit, in: ns, restartBelow: true) : edit
        }
        var next: String
        switch marker.kind {
        case .numbered:
            next = "\((p.number ?? 0) + 1)" + String(decoding: [p.delimiter ?? 0x2E], as: UTF16.self) + " "
        case .task:
            next = String(decoding: [p.units[marker.range.lowerBound]], as: UTF16.self) + " [ ] "
        default:
            next = String(decoding: p.units[marker.range], as: UTF16.self)
        }
        if let mark = item.mark { next += String(decoding: [p.units[mark]], as: UTF16.self) }
        let indent = String(decoding: p.units[0..<item.indentEnd], as: UTF16.self)
        let edit = inserting(place.closers + ending + indent + next + place.openers, at: p.range.location + max(place.at, item.contentStart))
        return marker.kind == .numbered ? numbering(after: edit, in: ns) : edit
    }

    // MARK: Delete right behind a marker

    /// Delete with the caret right behind a block marker takes the whole marker off, as it takes one character anywhere
    /// else: `-` left on its own is no bullet, and a marker is one thing on screen. A heading inside an item goes first, then
    /// the item's own. The indent and any direction mark stay. Nil: `range` is anything else.
    static func removingMarker(before range: NSRange, in ns: NSString) -> Edit? {
        guard range.length == 1 else { return nil }
        let p = paragraph(at: range.location, in: ns)
        guard NSMaxRange(range) <= NSMaxRange(p.range), let marker = p.line.marker else { return nil }
        let end = NSMaxRange(range) - p.range.location
        let target: Range<Int>
        if let inner = p.line.innerHeading, end == inner.range.upperBound || end == p.line.contentStart {
            target = inner.range
        } else if end == marker.range.upperBound || (p.line.innerHeading == nil && end == p.line.contentStart) {
            target = marker.range
        } else {
            return nil
        }
        guard FencedCode(text: ns).role(ofParagraphAt: p.range.location) == .none else { return nil }
        let edit = combined([Change(absolute(target, in: p.range), "")], in: ns, selection: NSRange(location: NSMaxRange(range), length: 0))
        guard marker.kind == .numbered, target == marker.range else { return edit }
        return numbering(after: edit, in: ns, restartBelow: true)
    }

    // MARK: an edit that adds or takes away lines

    /// `replacement` in place of `range`, when a line ending is involved, with the numbers of the list around it put right. A
    /// list whose first item went keeps its first number. Nil: no number needs to change, so the text view can do it.
    static func replacingLines(_ range: NSRange, with replacement: String, in ns: NSString) -> Edit? {
        let edit = Edit(range: range, replacement: replacement, selection: NSRange(location: range.location + (replacement as NSString).length, length: 0))
        let result = numbering(after: edit, in: ns, rootStart: firstNumberGoing(in: range, of: ns))
        return result == edit ? nil : result
    }

    /// The number the list starts with, if the edit takes that first item away.
    private static func firstNumberGoing(in range: NSRange, of ns: NSString) -> Int? {
        let fences = FencedCode(text: ns)
        var p = paragraph(at: range.location, in: ns)
        guard isInList(p, fences) else { return nil }
        while let above = itemAbove(p, in: ns, fences: fences, where: { _ in true }) { p = above }
        return p.range.location >= range.location ? p.number : nil
    }

    // MARK: numbering

    /// `edit` as one replacement with the numbers of each list it touched put right. `rootStart`: what the first list's top
    /// level starts with, if not its own first number. `restartBelow`: what comes after the edit, if it is a list of its own
    /// now, starts again at 1.
    static func numbering(after edit: Edit, in ns: NSString, rootStart: Int? = nil, restartBelow: Bool = false) -> Edit {
        guard !edit.changesNothing else { return edit }
        let after = ns.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        let fences = FencedCode(text: after)
        let end = edit.range.location + (edit.replacement as NSString).length
        var changes: [Change] = []
        var location = edit.range.location
        var start = rootStart
        while location <= end {
            let list = renumbering(after, fences, around: location, rootStart: start)
            start = nil
            changes += list.changes
            location = list.end
        }
        if restartBelow, let next = nextParagraphStart(of: after, after: paragraphContents(of: after, at: end)), next >= location {
            changes += renumbering(after, fences, around: next, rootStart: 1).changes
        }
        guard !changes.isEmpty else { return edit }
        let numbered = combined(changes, in: after, selection: edit.selection)
        return minimal(from: ns, to: numbered.applied(to: after as String) as NSString, selection: numbered.selection)
    }

    /// A list that is open at some level, as the lines are read from the top.
    private struct OpenList {
        var width: Int
        var delimiter: UInt16?
        var next: Int
    }

    /// The changes that give the list around `location` its numbers, and the first offset after it. A top level keeps the
    /// number it starts with. A nested list starts at 1. Each item is one more than the one before it at its level.
    private static func renumbering(_ ns: NSString, _ fences: FencedCode, around location: Int, rootStart: Int?) -> (changes: [Change], end: Int) {
        let here = paragraph(at: min(location, ns.length), in: ns)
        guard isInList(here, fences) else { return ([], nextParagraphStart(of: ns, after: here.range) ?? ns.length + 1) }
        var start = here.range.location
        while start > 0 {
            var previous = 0
            ns.getParagraphStart(&previous, end: nil, contentsEnd: nil, for: NSRange(location: start - 1, length: 0))
            guard isInList(paragraph(at: previous, in: ns), fences) else { break }
            start = previous
        }
        var rootStart = rootStart
        var open: [OpenList] = []
        var changes: [Change] = []
        var next: Int? = start
        while let at = next {
            let p = paragraph(at: at, in: ns)
            guard isInList(p, fences) else { return (changes, at) }
            next = nextParagraphStart(of: ns, after: p.range)
            guard p.isItem else { continue }
            let width = p.width
            while let top = open.last, width < top.width { open.removeLast() }
            let sibling = open.last.flatMap { width < $0.width + nestingWidth ? $0 : nil }
            if sibling != nil { open.removeLast() }
            var value = p.number
            if p.number != nil {
                if let sibling, sibling.delimiter == p.delimiter {
                    value = sibling.next
                } else if !open.isEmpty {
                    value = 1
                } else if let first = rootStart {
                    value = first
                    rootStart = nil
                }
            }
            if let range = p.numberRange, let value, value != p.number {
                changes.append(Change(absolute(range, in: p.range), String(value)))
            }
            open.append(OpenList(width: sibling?.width ?? width, delimiter: p.delimiter, next: (value ?? 0) + 1))
        }
        return (changes, ns.length + 1)
    }
}
