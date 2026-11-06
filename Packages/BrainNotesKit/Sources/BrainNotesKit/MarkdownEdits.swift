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

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }

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

    /// Adds `- [ ] ` at each paragraph's start, or removes the marker if all of them are tasks. A bullet or a number becomes
    /// a task. Toggling twice gives the same bytes back, except that a tick, a bullet and a number can't come back once removed.
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
            case .bullet?, .numbered?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), taskMarker))
            default:
                // Before any direction mark: a marker that isn't first on its line is not a marker.
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), taskMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Adds `- ` at each paragraph's start, or removes it if all of them are bullets. A task or a number becomes a bullet.
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
            case .task?, .numbered?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), bulletMarker))
            default:
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), bulletMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Makes each paragraph a heading of this level, or plain again if all of them already are. A list marker makes way:
    /// `# - [ ] a` would be a heading that reads "- [ ] a". A heading already inside a list item changes where it is, and
    /// the item stays. A direction mark stays behind the marker, as `toggleDirection` puts it.
    public static func toggleHeading(_ level: Int, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let level = min(max(level, 1), 6)
        let wanted = String(repeating: "#", count: level) + " "
        let all = chosen.allSatisfy { $0.line.marker?.kind == .heading(level) || $0.line.innerHeading?.level == level }
        var edits: [Change] = []
        for p in chosen {
            if let inner = p.line.innerHeading {
                if all {
                    edits.append(Change(absolute(inner.range, in: p.range), ""))
                } else if inner.level != level {
                    edits.append(Change(absolute(inner.range, in: p.range), wanted))
                }
            } else if let marker = p.line.marker {
                if all {
                    edits.append(Change(absolute(marker.range, in: p.range), ""))
                } else if marker.kind != .heading(level) {
                    edits.append(Change(absolute(marker.range, in: p.range), wanted))
                }
            } else {
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), wanted))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Body: takes any heading marker off, also one inside a list item. Lists and everything else stay.
    public static func removeHeading(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        var edits: [Change] = []
        for p in chosenParagraphs(of: ns, selection: selection) {
            if let inner = p.line.innerHeading {
                edits.append(Change(absolute(inner.range, in: p.range), ""))
            } else if let marker = p.line.marker, case .heading = marker.kind {
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

    /// Inserts a blank GFM pipe table, 3 by 3 (a header row and two body rows), at the selection. The caret lands in the
    /// first header cell. A blank line is added above when needed so the table is not glued to paragraph text before it
    /// (GitHub would then treat that text as the header), and below when text follows it, which would become a row.
    public static func insertTable(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let ending = lineEnding(in: text, at: selection.location)
        var table = MarkdownTable.blankMarkdown(columns: 3, rows: 3, lineEnding: ending)
        // First cell content starts after "| ".
        var caretInTable = 2
        if selection.location > 0 {
            let prev = ns.character(at: selection.location - 1)
            let afterBreak = prev == 0x0A || prev == 0x0D
            if !afterBreak {
                table = ending + ending + table
                caretInTable += 2 * (ending as NSString).length
            } else {
                // One break already: keep a blank line so a paragraph above does not swallow the header.
                let needBlank: Bool
                if selection.location >= 2 {
                    let earlier = ns.character(at: selection.location - 2)
                    needBlank = !(earlier == 0x0A || earlier == 0x0D)
                } else {
                    needBlank = true
                }
                if needBlank {
                    table = ending + table
                    caretInTable += (ending as NSString).length
                }
            }
        }
        table += ending
        let end = NSMaxRange(selection)
        if end < ns.length, ns.character(at: end) != 0x0A, ns.character(at: end) != 0x0D { table += ending }
        return Edit(
            range: selection,
            replacement: table,
            selection: NSRange(location: selection.location + caretInTable, length: 0)
        )
    }

    /// A tap on a checkbox: one byte, the character between the brackets. Nil if the paragraph at `location` is no task.
    /// The selection stays where it is.
    public static func toggleTick(in text: String, paragraphAt location: Int, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let paragraph = paragraphContents(of: ns, at: min(location, ns.length))
        guard let marker = MarkdownLine(units(of: ns, in: paragraph)).marker, case let .task(done, box) = marker.kind else { return nil }
        return edit(NSRange(location: paragraph.location + box, length: 1), done ? " " : "x", selection: clamped(selection, in: ns))
    }

    // MARK: lists

    /// Return. In a bullet, task or numbered item the new line continues the list: the same indent and marker, an open
    /// box for a task, the next number with the numbers after it moved on, and the item's direction after the marker:
    /// its own mark if it has one, else a right-to-left mark on a line that reads right to left, so an empty Hebrew item
    /// already starts on the right. On an item with no text Return ends the list instead: a nested item moves out one
    /// level, a top-level one loses its marker and leaves an empty line. Anywhere else, fenced code included, it is a
    /// plain line ending, the note's own kind. `fences` are the note's, if the editor keeps them; else worked out here.
    public static func newLine(in text: String, selection: NSRange, fences: FencedCode? = nil) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let ending = lineEnding(in: text, at: selection.location)
        let plain = Edit(range: selection, replacement: ending, selection: NSRange(location: selection.location + (ending as NSString).length, length: 0))
        let paragraph = paragraphContents(of: ns, at: selection.location)
        let u = units(of: ns, in: paragraph)
        let line = MarkdownLine(u)
        // A caret in front of the marker pushes the whole item down.
        guard let found = line.marker, let marker = ListMarker(line, u), selection.location >= paragraph.location + found.range.upperBound else { return plain }
        let fences = fences ?? FencedCode(text: ns)
        guard fences.role(ofParagraphAt: paragraph.location) == .none else { return plain }

        if selection.length == 0, u[line.contentStart...].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
            let rows = listRows(of: ns, from: paragraph.location, through: paragraph.location, fences: fences)
            let i = rows.firstIndex(where: { $0.range.location == paragraph.location })!
            if parent(of: i, in: rows) != nil { return shifted(rows, items: [i], deeper: false, selection: selection, in: ns) }
            return Edit(range: paragraph, replacement: "", selection: NSRange(location: paragraph.location, length: 0))
        }

        // Between the marker and its direction mark, the mark stays with the item above.
        let start = max(selection.location, paragraph.location + line.contentStart)
        let replaced = NSRange(location: start, length: max(NSMaxRange(selection), start) - start)
        var changes: [Change] = []
        var number = 0
        if case let .numbered(value, _) = marker.style {
            number = value + 1
            // A selection over several lines takes items with it: their numbers are left as they are.
            if NSMaxRange(selection) <= NSMaxRange(paragraph) {
                let rows = listRows(of: ns, from: paragraph.location, through: paragraph.location, fences: fences)
                let c = rows.firstIndex(where: { $0.range.location == paragraph.location })!
                var after = slots(rows)
                after.insert(Slot(indent: rows[c].indent, key: marker.key, number: nil, isBoundary: false), at: c + 1)
                var origin = rows.indices.map { Optional($0) }
                origin.insert(nil, at: c + 1)
                let values = numbers(old: slots(rows), new: after, origin: origin, seeds: [c + 1], moved: [c + 1])
                number = values[c + 1] ?? number
                changes = renumbering(rows, to: values, origin: origin)
            }
        }
        let mark: String
        if let m = line.mark {
            mark = String(decoding: [u[m]], as: UTF16.self)
        } else {
            mark = isRightToLeft(paragraph: String(decoding: u, as: UTF16.self)) ? rightToLeftMark : ""
        }
        let inserted = ending + String(decoding: u[..<line.indentEnd], as: UTF16.self) + marker.continuation(number: number) + mark
        let shift = changes.filter { $0.range.location < replaced.location }.reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
        changes.append(Change(replaced, inserted))
        var edit = combined(sorted(changes), in: ns, selection: selection)
        edit.selection = NSRange(location: replaced.location + shift + (inserted as NSString).length, length: 0)
        return edit
    }

    /// Tab. Each list item the selection touches nests under the item before it at its level, taking its own nested
    /// lines along: past that item's marker (`- ` or `12. `) in spaces, or one tab in a list indented with tabs. An item
    /// with nothing to nest under stays. Numbers follow: the item starts its new list or continues it, and the list it
    /// left closes up. Nil if no paragraph chosen is a list item, so that Tab can do what it does elsewhere.
    public static func indentListItems(in text: String, selection: NSRange, fences: FencedCode? = nil) -> Edit? {
        shiftListItems(in: text, selection: selection, fences: fences, deeper: true)
    }

    /// Shift-Tab. Each list item the selection touches moves out to its parent's indent, its nested lines along, and
    /// the numbers follow. A top-level item stays. Nil if no paragraph chosen is a list item.
    public static func outdentListItems(in text: String, selection: NSRange, fences: FencedCode? = nil) -> Edit? {
        shiftListItems(in: text, selection: selection, fences: fences, deeper: false)
    }

    /// Numbers each numbered list the selection touches from its first number on, as after a paste or a deleted line.
    /// A list numbered `1.` all through keeps that style. Nothing else changes.
    public static func renumberLists(in text: String, selection: NSRange, fences: FencedCode? = nil) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection).filter { ListMarker($0.line, $0.units)?.digits != nil }
        guard let first = chosen.first, let last = chosen.last else { return combined([], in: ns, selection: selection) }
        let fences = fences ?? FencedCode(text: ns)
        let rows = listRows(of: ns, from: first.range.location, through: last.range.location, fences: fences)
        let starts = Set(chosen.map(\.range.location))
        let seeds = Set(rows.indices.filter { rows[$0].marker != nil && starts.contains(rows[$0].range.location) })
        let origin = rows.indices.map { Optional($0) }
        let values = numbers(old: slots(rows), new: slots(rows), origin: origin, seeds: seeds, moved: [])
        return combined(sorted(renumbering(rows, to: values, origin: origin)), in: ns, selection: selection)
    }

    // MARK: line endings

    /// The line ending a new line should have at `location`: its own paragraph's, else the note's first. A note is never
    /// made to mix endings by typing in it, and is never normalized either.
    public static func lineEnding(in text: String, at location: Int) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return "\n" }
        var end = 0, contentsEnd = 0
        ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(location, ns.length), length: 0))
        if end > contentsEnd { return ns.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)) }
        let first = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n"))
        guard first.location != NSNotFound else { return "\n" }
        // To NSString these are two characters, whatever they are to Swift.
        let isCRLF = ns.character(at: first.location) == 0x0D && first.location + 1 < ns.length && ns.character(at: first.location + 1) == 0x0A
        return isCRLF ? "\r\n" : ns.substring(with: first)
    }

    // MARK: a caret in other text

    /// An offset kept from other text, made safe for this one: at most its end, and never inside a character. A caret
    /// inside an emoji's surrogate pair would split it at the next keystroke, and a lone half can't be saved: it comes
    /// back as U+FFFD. Nor between the two characters of a CRLF.
    public static func caret(at offset: Int, in text: String) -> Int {
        let ns = text as NSString
        let location = min(max(offset, 0), ns.length)
        guard location > 0, location < ns.length else { return location }
        if ns.character(at: location - 1) == 0x0D, ns.character(at: location) == 0x0A { return location - 1 }
        return ns.rangeOfComposedCharacterSequence(at: location).location
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

    struct Change {
        var range: NSRange
        var replacement: String
        init(_ range: NSRange, _ replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    struct Paragraph {
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

    static func clamped(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = min(range.location, ns.length)
        return NSRange(location: location, length: min(range.length, ns.length - location))
    }

    /// The paragraphs an action works on: each one the selection touches, not counting one it only reaches the very start
    /// of, as a triple tap does. Blank ones are left out if any other is chosen: nobody wants a task with no text.
    static func chosenParagraphs(of ns: NSString, selection: NSRange) -> [Paragraph] {
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

    static func nextParagraphStart(of ns: NSString, after contents: NSRange) -> Int? {
        var end = 0
        ns.getParagraphStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: contents.location, length: 0))
        return end > NSMaxRange(contents) && end <= ns.length ? end : nil
    }

    /// The paragraph at `location`, without its line ending.
    static func paragraphContents(of ns: NSString, at location: Int) -> NSRange {
        var start = 0
        var contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    static func units(of ns: NSString, in range: NSRange) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: range.length)
        ns.getCharacters(&buffer, range: range)
        return buffer
    }

    static func absolute(_ range: Range<Int>, in paragraph: NSRange) -> NSRange {
        NSRange(location: paragraph.location + range.lowerBound, length: range.count)
    }

    /// One replacement, with the selection following the text around it. A caret where text goes in ends up
    /// after it, so that what is typed next follows the marker.
    private static func edit(_ range: NSRange, _ replacement: String, selection: NSRange) -> Edit {
        combined([Change(range, replacement)], in: "", selection: selection)
    }

    /// Several changes in text order, as one replacement from the first to the last.
    static func combined(_ changes: [Change], in ns: NSString, selection: NSRange) -> Edit {
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
        #if !canImport(Darwin)
        // swift-corelibs-foundation has no `.byWords`. A word here is a run of letters, marks and digits, with an
        // apostrophe or a Hebrew geresh/gershayim kept when letters stand on both sides ("don't", צה״ל). The first
        // such run that touches the caret wins, as the enumeration below would pick it.
        let wordChars = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let joiners: Set<UInt16> = [0x27, 0x2019, 0x05F3, 0x05F4, 0x22]
        let lower = paragraph.location, upper = NSMaxRange(paragraph)
        func isWordChar(_ i: Int) -> Bool {
            guard i >= lower, i < upper else { return false }
            let c = ns.character(at: i)
            if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
            if joiners.contains(c) { return i > lower && i + 1 < upper && isLetter(i - 1) && isLetter(i + 1) }
            return Unicode.Scalar(c).map(wordChars.contains) ?? false
        }
        func isLetter(_ i: Int) -> Bool {
            let c = ns.character(at: i)
            return !joiners.contains(c) && (Unicode.Scalar(c).map(wordChars.contains) ?? false)
        }
        guard caret >= lower, caret <= upper else { return nil }
        var start: Int
        if isWordChar(caret - 1) { start = caret - 1 } else if isWordChar(caret) { start = caret } else { return nil }
        while isWordChar(start - 1) { start -= 1 }
        var end = start
        while isWordChar(end) { end += 1 }
        return NSRange(location: start, length: end - start)
        #else
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
        #endif
    }

    // MARK: list helpers

    /// A tab's width when indents are compared, as CommonMark counts it.
    private static let tabColumns = 4

    /// A list item's marker, as lists need it.
    fileprivate struct ListMarker {
        enum Style: Equatable {
            /// Its own bytes: `- `, `* ` or `+ `.
            case bullet(String)
            /// The bullet character in front of the box.
            case task(UInt16)
            case numbered(Int, delimiter: UInt16)
        }

        var style: Style
        /// The number's digits, in the paragraph.
        var digits: Range<Int>?
        /// How far a nested item's marker goes past this one's: past `- ` or `12. `.
        var width: Int
        /// Items of one key make one list: bullets and tasks together, numbers by their `.` or `)`.
        var key: UInt16

        init?(_ line: MarkdownLine, _ u: [UInt16]) {
            guard let marker = line.marker, !isThematicBreak(u[line.indentEnd...]) else { return nil }
            let r = marker.range
            switch marker.kind {
            case .bullet:
                style = .bullet(String(decoding: u[r], as: UTF16.self))
                digits = nil
                width = 2
                key = 0
            case .task:
                style = .task(u[r.lowerBound])
                digits = nil
                width = 2
                key = 0
            case .numbered:
                let d = r.lowerBound..<(r.upperBound - 2)
                var value = 0
                for i in d { value = value * 10 + Int(u[i] - 0x30) }
                style = .numbered(value, delimiter: u[r.upperBound - 2])
                digits = d
                width = r.count
                key = u[r.upperBound - 2]
            case .heading, .quote:
                return nil
            }
        }

        /// The marker of the item that follows this one.
        func continuation(number: Int) -> String {
            switch style {
            case let .bullet(text): text
            case let .task(bullet): String(decoding: [bullet], as: UTF16.self) + " [ ] "
            case let .numbered(_, delimiter): String(number) + String(decoding: [delimiter], as: UTF16.self) + " "
            }
        }
    }

    /// `---`, `***` or `___`, spaces between allowed: a thematic break, which `- - -` is too, though it starts like a
    /// bullet.
    fileprivate static func isThematicBreak(_ u: ArraySlice<UInt16>) -> Bool {
        guard let first = u.first, first == 0x2D || first == 0x2A || first == 0x5F else { return false }
        var count = 0
        for c in u {
            if c == first { count += 1 } else if c != 0x20 && c != 0x09 { return false }
        }
        return count >= 3
    }

    /// One paragraph of the stretch of note a list edit looks at.
    fileprivate struct ListRow {
        var range: NSRange
        var units: [UInt16]
        var line: MarkdownLine
        /// Nil for anything but a list item, and for a line of fenced code.
        var marker: ListMarker?
        /// The indent in columns.
        var indent: Int
        /// A blank line, a heading or fenced code: no list goes across it here.
        var isBoundary: Bool
        /// A quote or a thematic break. It ends the list unless it is indented into an item above it.
        var isBreak: Bool
    }

    private static func listRow(of ns: NSString, at location: Int, fences: FencedCode) -> ListRow {
        let range = paragraphContents(of: ns, at: location)
        let u = units(of: ns, in: range)
        let line = MarkdownLine(u)
        let fenced = fences.role(ofParagraphAt: range.location) != .none
        var heading = false
        if case .heading = line.marker?.kind { heading = true }
        let blank = u.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == MarkdownLine.rightToLeftMark || $0 == MarkdownLine.leftToRightMark }
        var indent = 0
        for c in u[..<line.indentEnd] { indent += c == 0x09 ? tabColumns : 1 }
        let rest = u[line.indentEnd...]
        let isBreak = !fenced && (rest.first == 0x3E || isThematicBreak(rest)) // >
        // At the left edge it can't be inside any item, so it ends the list whatever is above it.
        return ListRow(range: range, units: u, line: line, marker: fenced ? nil : ListMarker(line, u), indent: indent,
                       isBoundary: fenced || heading || blank || (isBreak && indent < 2), isBreak: isBreak)
    }

    /// A quote or a thematic break ends the list unless some item above it in this stretch has its text at or left
    /// of the break's indent, so that the break is inside that item.
    private static func markBreaks(_ rows: inout [ListRow]) {
        for i in rows.indices where rows[i].isBreak && !rows[i].isBoundary {
            var j = i - 1
            var inside = false
            while j >= 0, !rows[j].isBoundary {
                if let marker = rows[j].marker, rows[j].indent + marker.width <= rows[i].indent {
                    inside = true
                    break
                }
                j -= 1
            }
            if !inside { rows[i].isBoundary = true }
        }
    }

    /// The paragraphs from `first` through `last`, and around them up to the nearest boundary on each side: all a list
    /// edit can renumber. A blank line is a boundary, so a loose list's parts are numbered on their own.
    private static func listRows(of ns: NSString, from first: Int, through last: Int, fences: FencedCode) -> [ListRow] {
        var rows: [ListRow] = []
        var start = paragraphContents(of: ns, at: first).location
        while start > 0 {
            let row = listRow(of: ns, at: start - 1, fences: fences)
            if row.isBoundary { break }
            rows.append(row)
            start = row.range.location
        }
        rows.reverse()
        var row = listRow(of: ns, at: first, fences: fences)
        rows.append(row)
        while let next = nextParagraphStart(of: ns, after: row.range) {
            row = listRow(of: ns, at: next, fences: fences)
            if row.isBoundary, next > last { break }
            rows.append(row)
        }
        // Rows past a break that turns out to end the list stay in; everything that reads them stops at a boundary.
        markBreaks(&rows)
        return rows
    }

    /// The item before this one at its indent, if no shallower item comes between: the one it can nest under.
    private static func sibling(of i: Int, in rows: [ListRow]) -> Int? {
        var j = i - 1
        while j >= 0, !rows[j].isBoundary {
            if rows[j].marker != nil {
                if rows[j].indent < rows[i].indent { return nil }
                if rows[j].indent == rows[i].indent { return j }
            }
            j -= 1
        }
        return nil
    }

    /// The nearest item before this one with less indent.
    private static func parent(of i: Int, in rows: [ListRow]) -> Int? {
        var j = i - 1
        while j >= 0, !rows[j].isBoundary {
            if rows[j].marker != nil, rows[j].indent < rows[i].indent { return j }
            j -= 1
        }
        return nil
    }

    /// The last row of this item's nested lines: those after it with more indent.
    private static func subtreeEnd(of i: Int, in rows: [ListRow]) -> Int {
        var k = i
        while k + 1 < rows.count, !rows[k + 1].isBoundary, rows[k + 1].indent > rows[i].indent { k += 1 }
        return k
    }

    private static func shiftListItems(in text: String, selection: NSRange, fences: FencedCode?, deeper: Bool) -> Edit? {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let listed = chosenParagraphs(of: ns, selection: selection).filter { ListMarker($0.line, $0.units) != nil }
        guard !listed.isEmpty else { return nil }
        let fences = fences ?? FencedCode(text: ns)
        let chosen = listed.filter { fences.role(ofParagraphAt: $0.range.location) == .none }
        guard let first = chosen.first, let last = chosen.last else { return nil }
        let rows = listRows(of: ns, from: first.range.location, through: last.range.location, fences: fences)
        let starts = Set(chosen.map(\.range.location))
        return shifted(rows, items: rows.indices.filter { rows[$0].marker != nil && starts.contains(rows[$0].range.location) },
                       deeper: deeper, selection: selection, in: ns)
    }

    /// Moves these items, each with its nested lines, one level in or out, and renumbers the lists that changed.
    private static func shifted(_ rows: [ListRow], items: [Int], deeper: Bool, selection: NSRange, in ns: NSString) -> Edit {
        let usesTabs = rows.contains { $0.units[..<$0.line.indentEnd].contains(0x09) }
        var after = slots(rows)
        var changes: [Change] = []
        var moved = Set<Int>()
        // Rows already moved with an item above them.
        var covered = -1
        for i in items {
            guard i > covered else { continue }
            let end = subtreeEnd(of: i, in: rows)
            if deeper {
                guard let s = sibling(of: i, in: rows), let width = rows[s].marker?.width else { continue }
                let unit = usesTabs ? "\t" : String(repeating: " ", count: width)
                for k in i...end {
                    changes.append(Change(NSRange(location: rows[k].range.location + rows[k].line.indentEnd, length: 0), unit))
                    after[k].indent += usesTabs ? tabColumns : width
                }
            } else {
                let columns = rows[i].indent - (parent(of: i, in: rows).map { rows[$0].indent } ?? 0)
                guard columns > 0 else { continue }
                for k in i...end {
                    changes.append(removing(columns, from: rows[k]))
                    after[k].indent -= columns
                }
            }
            moved.insert(i)
            covered = end
        }
        let origin = rows.indices.map { Optional($0) }
        let values = numbers(old: slots(rows), new: after, origin: origin, seeds: moved, moved: moved)
        changes += renumbering(rows, to: values, origin: origin)
        return combined(sorted(changes), in: ns, selection: selection)
    }

    /// Takes this many columns off the end of a row's indent. A tab that is wider than what is left to take gives the
    /// difference back as spaces.
    private static func removing(_ columns: Int, from row: ListRow) -> Change {
        var i = row.line.indentEnd
        var removed = 0
        while i > 0, removed < columns {
            i -= 1
            removed += row.units[i] == 0x09 ? tabColumns : 1
        }
        return Change(NSRange(location: row.range.location + i, length: row.line.indentEnd - i), String(repeating: " ", count: max(removed - columns, 0)))
    }

    /// What numbering needs to know of a row.
    fileprivate struct Slot {
        var indent: Int
        var key: UInt16?
        var number: Int?
        var isBoundary: Bool
    }

    private static func slots(_ rows: [ListRow]) -> [Slot] {
        rows.map { row in
            var number: Int?
            if case let .numbered(value, _)? = row.marker?.style { number = value }
            return Slot(indent: row.indent, key: row.marker?.key, number: number, isBoundary: row.isBoundary)
        }
    }

    /// Which list each item is in: one id for the items at one indent under one parent, with one key and no boundary
    /// between them.
    private static func groups(_ slots: [Slot]) -> [Int?] {
        var out = [Int?](repeating: nil, count: slots.count)
        var stack: [(indent: Int, key: UInt16, id: Int)] = []
        var nextID = 0
        for (i, slot) in slots.enumerated() {
            if slot.isBoundary {
                stack.removeAll()
                continue
            }
            guard let key = slot.key else { continue }
            while let top = stack.last, top.indent > slot.indent { stack.removeLast() }
            if let top = stack.last, top.indent == slot.indent, top.key == key {
                out[i] = top.id
                continue
            }
            if let top = stack.last, top.indent == slot.indent { stack.removeLast() }
            stack.append((slot.indent, key, nextID))
            out[i] = nextID
            nextID += 1
        }
        return out
    }

    /// The numbers the numbered lists an edit touched should have, by index into `new`. `origin` maps each new row to its
    /// old one, nil for a row the edit adds. The lists of the `seeds`, before the edit and after it, are numbered from
    /// their first item's number on; a list whose first item changed place, or was not first before, starts at 1.
    /// Items `moved` don't decide that, nor whether a list keeps the style of `1.` on every item.
    private static func numbers(old: [Slot], new: [Slot], origin: [Int?], seeds: Set<Int>, moved: Set<Int>) -> [Int: Int] {
        let oldGroups = groups(old)
        let newGroups = groups(new)
        var left = Set<Int>()
        for n in seeds {
            if let o = origin[n], let g = oldGroups[o] { left.insert(g) }
        }
        var wanted = Set<Int>()
        for n in new.indices {
            guard let g = newGroups[n] else { continue }
            if seeds.contains(n) {
                wanted.insert(g)
            } else if let o = origin[n], let was = oldGroups[o], left.contains(was) {
                wanted.insert(g)
            }
        }
        var out: [Int: Int] = [:]
        for g in wanted {
            let members = new.indices.filter { newGroups[$0] == g }
            // Bullets have no numbers.
            guard let first = members.first, let key = new[first].key, key != 0 else { continue }
            var start = 1
            if let o = origin[first], !moved.contains(first), let was = oldGroups[o], old.indices.first(where: { oldGroups[$0] == was }) == o,
               let number = new[first].number {
                start = number
            }
            let kept = members.filter { origin[$0] != nil && !moved.contains($0) }.compactMap { new[$0].number }
            // `1.` on every item is a style; any other number twice is a slip.
            let allOnes = kept.count >= 2 && kept.allSatisfy { $0 == 1 }
            for (k, m) in members.enumerated() { out[m] = allOnes ? 1 : start + k }
        }
        return out
    }

    /// The changes to existing items' digits that give them these numbers.
    private static func renumbering(_ rows: [ListRow], to values: [Int: Int], origin: [Int?]) -> [Change] {
        var changes: [Change] = []
        for (n, value) in values {
            guard let o = origin[n], let marker = rows[o].marker, let digits = marker.digits,
                  case let .numbered(number, _) = marker.style, number != value else { continue }
            changes.append(Change(absolute(digits, in: rows[o].range), String(value)))
        }
        return changes
    }

    /// In text order; an insertion before a replacement at the same place.
    private static func sorted(_ changes: [Change]) -> [Change] {
        changes.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
    }
}
