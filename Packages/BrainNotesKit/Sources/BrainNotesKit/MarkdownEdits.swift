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
    private static let dashedMarker = "+ "
    private static let quoteMarker = "> "

    public enum BlockStyle: Sendable, Equatable {
        case title
        case heading
        case subheading
        case body
        case monostyled
        case bullet
        case dashed
        case numbered
        case quote
    }

    public struct ActiveFormat: Sendable, Equatable {
        public var block: BlockStyle = .body
        public var isTask = false
        public var isBold = false
        public var isItalic = false
        public var isUnderline = false
        public var isStrikethrough = false
        public var highlight: HighlightColor?
        public var link: LinkMatch?

        public init(
            block: BlockStyle = .body,
            isTask: Bool = false,
            isBold: Bool = false,
            isItalic: Bool = false,
            isUnderline: Bool = false,
            isStrikethrough: Bool = false,
            highlight: HighlightColor? = nil,
            link: LinkMatch? = nil
        ) {
            self.block = block
            self.isTask = isTask
            self.isBold = isBold
            self.isItalic = isItalic
            self.isUnderline = isUnderline
            self.isStrikethrough = isStrikethrough
            self.highlight = highlight
            self.link = link
        }
    }

    public struct LinkMatch: Sendable, Equatable {
        public var wholeRange: NSRange
        public var title: String
        public var destination: String
        public var isWiki: Bool

        public init(wholeRange: NSRange, title: String, destination: String, isWiki: Bool) {
            self.wholeRange = wholeRange
            self.title = title
            self.destination = destination
            self.isWiki = isWiki
        }
    }

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

    /// Adds `- ` at each paragraph's start, or removes it if all of them are round bullets. A dashed item, task or number becomes `- `.
    public static func toggleBullet(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let all = chosen.allSatisfy { p in
            guard let m = p.line.marker, m.kind == .bullet else { return false }
            return p.units[m.range.lowerBound] != 0x2B
        }
        var edits: [Change] = []
        for p in chosen {
            switch p.line.marker?.kind {
            case .bullet?:
                let isDash = p.units[p.line.marker!.range.lowerBound] == 0x2B
                if all {
                    edits.append(Change(absolute(p.line.marker!.range, in: p.range), ""))
                } else if isDash {
                    edits.append(Change(absolute(p.line.marker!.range, in: p.range), bulletMarker))
                }
            case .task?, .numbered?, .quote?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), bulletMarker))
            default:
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), bulletMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Adds `+ ` (rendered as Apple Notes en-dash `–`) at each paragraph's start, or removes it if all of them are dashed items.
    public static func toggleDashed(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let all = chosen.allSatisfy { p in
            guard let m = p.line.marker, m.kind == .bullet else { return false }
            return p.units[m.range.lowerBound] == 0x2B
        }
        var edits: [Change] = []
        for p in chosen {
            switch p.line.marker?.kind {
            case .bullet?:
                let isDash = p.units[p.line.marker!.range.lowerBound] == 0x2B
                if all {
                    edits.append(Change(absolute(p.line.marker!.range, in: p.range), ""))
                } else if !isDash {
                    edits.append(Change(absolute(p.line.marker!.range, in: p.range), dashedMarker))
                }
            case .task?, .numbered?, .quote?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), dashedMarker))
            default:
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), dashedMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Adds `> ` (Block Quote) at each paragraph's start, or removes it if all of them are quotes.
    public static func toggleQuote(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        let all = chosen.allSatisfy { $0.line.marker?.kind == .quote }
        var edits: [Change] = []
        for p in chosen {
            switch p.line.marker?.kind {
            case .quote?:
                if all { edits.append(Change(absolute(p.line.marker!.range, in: p.range), "")) }
            case .bullet?, .task?, .numbered?, .heading?:
                edits.append(Change(absolute(p.line.marker!.range, in: p.range), quoteMarker))
            case nil:
                edits.append(Change(NSRange(location: p.range.location + p.line.indentEnd, length: 0), quoteMarker))
            }
        }
        return combined(edits, in: ns, selection: selection)
    }

    /// Wraps or unwraps selected paragraph(s) in a fenced monospaced block (`Monostyled`).
    public static func toggleMonostyled(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let fences = FencedCode(text: ns)
        if let block = fences.blocks.first(where: { block in
            let end = block.closing.map(NSMaxRange) ?? ns.length
            return block.opening.location <= selection.location && selection.location <= end
        }) {
            var changes: [Change] = [Change(block.opening, "")]
            if let closing = block.closing {
                changes.append(Change(closing, ""))
            }
            return combined(sorted(changes), in: ns, selection: selection)
        }
        let ending = lineEnding(in: text, at: selection.location)
        let chosen = chosenParagraphs(of: ns, selection: selection)
        guard let first = chosen.first, let last = chosen.last else {
            let emptyBlock = "```" + ending + ending + "```"
            return Edit(range: selection, replacement: emptyBlock, selection: NSRange(location: selection.location + 3 + (ending as NSString).length, length: 0))
        }
        let blockStart = first.range.location
        let blockEnd = NSMaxRange(last.range)
        let inner = ns.substring(with: NSRange(location: blockStart, length: blockEnd - blockStart))
        let openLine = "```" + ending
        let closeLine = ending + "```"
        let openLen = (openLine as NSString).length
        let newSel: NSRange
        if selection.length > 0 {
            newSel = NSRange(location: max(blockStart, selection.location) + openLen, length: min(selection.length, (inner as NSString).length))
        } else {
            newSel = NSRange(location: min(max(selection.location, blockStart), blockEnd) + openLen, length: 0)
        }
        return Edit(range: NSRange(location: blockStart, length: blockEnd - blockStart), replacement: openLine + inner + closeLine, selection: newSel)
    }

    /// Apple Notes `Body`: clears heading, list, quote, or monostyled block formatting back to plain body text.
    public static func setBody(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let fences = FencedCode(text: ns)
        if fences.role(ofParagraphAt: selection.location) != .none {
            return toggleMonostyled(in: text, selection: selection)
        }
        var edits: [Change] = []
        for p in chosenParagraphs(of: ns, selection: selection) {
            if let inner = p.line.innerHeading, let outer = p.line.marker {
                edits.append(Change(NSRange(location: p.range.location + outer.range.lowerBound, length: inner.range.upperBound - outer.range.lowerBound), ""))
            } else if let inner = p.line.innerHeading {
                edits.append(Change(absolute(inner.range, in: p.range), ""))
            } else if let marker = p.line.marker {
                edits.append(Change(absolute(marker.range, in: p.range), ""))
            }
        }
        let result = combined(edits, in: ns, selection: selection)
        return numbering(after: result, in: ns, restartBelow: true)
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
        let fences = FencedCode(text: ns)
        let role = fences.role(ofParagraphAt: paragraph.location)
        let mono = fences.isMonostyled(at: paragraph.location)
        let spans = MarkdownInline.line(units: units(of: ns, in: paragraph), fence: role, monostyled: mono).spans.map { span -> MarkdownInline.Span in
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

    /// Toggles `**`, `*`, `~~`, or `` ` `` per paragraph without ever wrapping block prefixes (`- [ ] `, `- `, `1. `, `# `, `> `)
    /// or spanning across line breaks in the WYSIWYG editor.
    public static func toggleInlineWrap(_ mark: String, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let fences = FencedCode(text: ns)
        let paragraphs = chosenParagraphs(of: ns, selection: selection).filter { p in
            let role = fences.role(ofParagraphAt: p.range.location)
            let mono = fences.isMonostyled(at: p.range.location)
            guard role == .none || mono else { return false }
            return MarkdownInline.line(units: p.units, fence: role, monostyled: mono).block != .rule
        }
        guard let first = paragraphs.first else {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        }
        let firstRole = fences.role(ofParagraphAt: first.range.location)
        let firstMono = fences.isMonostyled(at: first.range.location)
        let firstParsed = MarkdownInline.line(units: first.units, fence: firstRole, monostyled: firstMono)
        let firstContentStart = first.range.location + firstParsed.textStart

        if selection.length == 0 {
            let safeCaret = max(selection.location, firstContentStart)
            return toggleWrap(mark, in: text, selection: NSRange(location: safeCaret, length: 0))
        }

        if paragraphs.count == 1 {
            let contentRange = NSRange(location: firstContentStart, length: max(0, NSMaxRange(first.range) - firstContentStart))
            let clampedSel = NSIntersectionRange(selection, contentRange)
            if clampedSel.length > 0 {
                return toggleWrap(mark, in: text, selection: clampedSel)
            }
            return toggleWrap(mark, in: text, selection: NSRange(location: firstContentStart, length: 0))
        }

        guard let kind = spanKind(of: mark) else {
            return toggleWrap(mark, in: text, selection: selection)
        }

        struct SliceTarget {
            var slice: NSRange
            var existing: MarkdownInline.Span?
        }

        var targets: [SliceTarget] = []
        for p in paragraphs {
            let role = fences.role(ofParagraphAt: p.range.location)
            let mono = fences.isMonostyled(at: p.range.location)
            let parsed = MarkdownInline.line(units: p.units, fence: role, monostyled: mono)
            let contentStart = p.range.location + parsed.textStart
            let contentRange = NSRange(location: contentStart, length: max(0, NSMaxRange(p.range) - contentStart))
            let inter = NSIntersectionRange(selection, contentRange)
            let slice = trimmingWhiteSpace(inter, in: ns)
            guard slice.length > 0 else { continue }
            let spans = shiftedSpans(of: parsed, by: p.range.location).filter { $0.kind == kind }
            let match = spans.first { span in
                span.whole.location <= slice.location && NSMaxRange(slice) <= NSMaxRange(span.whole) &&
                    NSIntersectionRange(slice, span.content).length > 0
            }
            targets.append(SliceTarget(slice: slice, existing: match))
        }

        guard !targets.isEmpty else {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        }

        let allWrapped = targets.allSatisfy { $0.existing != nil }
        var changes: [Change] = []
        for target in targets {
            if allWrapped, let span = target.existing {
                changes.append(Change(span.whole, ns.substring(with: span.content)))
            } else if target.existing == nil {
                changes.append(Change(target.slice, mark + ns.substring(with: target.slice) + mark))
            }
        }
        return combined(changes, in: ns, selection: selection)
    }

    /// Toggles `<u>text</u>` underline around selection, caret span, or word touching caret, keeping block prefixes intact.
    public static func toggleUnderline(in text: String, selection: NSRange) -> Edit {
        togglePairedTag(
            openMark: "<u>",
            closeMark: "</u>",
            switchOnly: false,
            matches: {
                if case .underline = $0 { return true }
                return false
            },
            alreadyMatchesTarget: {
                if case .underline = $0 { return true }
                return false
            },
            in: text,
            selection: selection
        )
    }

    /// Toggles highlight (`==text==` for mint, `<mark data-color="...">text</mark>` for other colors) per paragraph,
    /// never wrapping block markers (`- [ ] `, `- `, `1. `, `# `, `> `) or line breaks.
    /// If already highlighted in a different color, switches to `color` without unwrapping first.
    public static func toggleHighlight(color: HighlightColor = .mint, in text: String, selection: NSRange, switchColorOnly: Bool = false) -> Edit {
        let ns = text as NSString
        let safeSel = clamped(selection, in: ns)
        let inMono = FencedCode(text: ns).isMonostyled(at: safeSel.location)
        let useTag = color != .mint || inMono
        let openMark = useTag ? "<mark data-color=\"\(color.rawValue)\">" : "=="
        let closeMark = useTag ? "</mark>" : "=="
        return togglePairedTag(
            openMark: openMark,
            closeMark: closeMark,
            switchOnly: switchColorOnly,
            matches: {
                if case .highlight = $0 { return true }
                return false
            },
            alreadyMatchesTarget: {
                if case let .highlight(c) = $0 { return c == color }
                return false
            },
            in: text,
            selection: selection
        )
    }

    private static func shiftedSpans(of parsed: MarkdownInline.Line, by offset: Int) -> [MarkdownInline.Span] {
        parsed.spans.map { span in
            var s = span
            s.open.location += offset
            s.content.location += offset
            s.close.location += offset
            return s
        }
    }

    private static func togglePairedTag(
        openMark: String,
        closeMark: String,
        switchOnly: Bool,
        matches: (MarkdownInline.Span.Kind) -> Bool,
        alreadyMatchesTarget: (MarkdownInline.Span.Kind) -> Bool,
        in text: String,
        selection: NSRange
    ) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let openLen = (openMark as NSString).length
        let closeLen = (closeMark as NSString).length
        let fences = FencedCode(text: ns)
        let paragraphs = chosenParagraphs(of: ns, selection: selection).filter { p in
            let role = fences.role(ofParagraphAt: p.range.location)
            let mono = fences.isMonostyled(at: p.range.location)
            guard role == .none || mono else { return false }
            return MarkdownInline.line(units: p.units, fence: role, monostyled: mono).block != .rule
        }
        guard let first = paragraphs.first else {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        }

        if selection.length > 0 {
            struct ParagraphTarget {
                var slice: NSRange
                var enclosing: MarkdownInline.Span?
                var innerSpans: [MarkdownInline.Span]
            }

            var targets: [ParagraphTarget] = []
            for p in paragraphs {
                let role = fences.role(ofParagraphAt: p.range.location)
                let mono = fences.isMonostyled(at: p.range.location)
                let parsed = MarkdownInline.line(units: p.units, fence: role, monostyled: mono)
                let contentStart = p.range.location + parsed.textStart
                let contentRange = NSRange(location: contentStart, length: max(0, NSMaxRange(p.range) - contentStart))
                let inter = NSIntersectionRange(selection, contentRange)
                let slice = trimmingWhiteSpace(inter, in: ns)
                guard slice.length > 0 else { continue }
                let matching = shiftedSpans(of: parsed, by: p.range.location).filter { matches($0.kind) }
                let enclosing = matching.first { span in
                    span.whole.location <= slice.location && NSMaxRange(slice) <= NSMaxRange(span.whole) &&
                        NSIntersectionRange(slice, span.content).length > 0
                }
                let inner = matching.filter { span in
                    slice.location <= span.whole.location && NSMaxRange(span.whole) <= NSMaxRange(slice)
                }
                targets.append(ParagraphTarget(slice: slice, enclosing: enclosing, innerSpans: inner))
            }

            if !targets.isEmpty {
                let allEnclosed = targets.allSatisfy { $0.enclosing != nil }
                let allExactTarget = allEnclosed && targets.allSatisfy { target in
                    guard let span = target.enclosing else { return false }
                    return alreadyMatchesTarget(span.kind)
                }

                if switchOnly, !targets.contains(where: { $0.enclosing != nil || !$0.innerSpans.isEmpty }) {
                    return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
                }

                if targets.count == 1, let target = targets.first {
                    if let span = target.enclosing {
                        let innerText = ns.substring(with: span.content)
                        if alreadyMatchesTarget(span.kind) {
                            if switchOnly {
                                return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
                            }
                            return Edit(
                                range: span.whole,
                                replacement: innerText,
                                selection: NSRange(location: span.whole.location, length: span.content.length)
                            )
                        }
                        return Edit(
                            range: span.whole,
                            replacement: openMark + innerText + closeMark,
                            selection: NSRange(location: span.whole.location + openLen, length: span.content.length)
                        )
                    }
                    let stripped = strippingSpans(target.innerSpans, inside: target.slice, of: ns)
                    let strippedLen = (stripped as NSString).length
                    return Edit(
                        range: target.slice,
                        replacement: openMark + stripped + closeMark,
                        selection: NSRange(location: target.slice.location + openLen, length: strippedLen)
                    )
                }

                var changes: [Change] = []
                for target in targets {
                    if allExactTarget {
                        if switchOnly { continue }
                        if let span = target.enclosing {
                            changes.append(Change(span.whole, ns.substring(with: span.content)))
                        }
                    } else if let span = target.enclosing {
                        if !alreadyMatchesTarget(span.kind) {
                            let innerText = ns.substring(with: span.content)
                            changes.append(Change(span.whole, openMark + innerText + closeMark))
                        }
                    } else if !switchOnly {
                        let stripped = strippingSpans(target.innerSpans, inside: target.slice, of: ns)
                        changes.append(Change(target.slice, openMark + stripped + closeMark))
                    } else {
                        for span in target.innerSpans where !alreadyMatchesTarget(span.kind) {
                            let innerText = ns.substring(with: span.content)
                            changes.append(Change(span.whole, openMark + innerText + closeMark))
                        }
                    }
                }
                return combined(changes, in: ns, selection: selection)
            }
        }

        // Caret path (or selection restricted entirely to a hidden block marker): clamp strictly behind block prefix.
        let firstRole = fences.role(ofParagraphAt: first.range.location)
        let firstMono = fences.isMonostyled(at: first.range.location)
        let parsed = MarkdownInline.line(units: first.units, fence: firstRole, monostyled: firstMono)
        let contentStart = first.range.location + parsed.textStart
        let contentRange = NSRange(location: contentStart, length: max(0, NSMaxRange(first.range) - contentStart))
        let caret = max(selection.location, contentStart)
        let matching = shiftedSpans(of: parsed, by: first.range.location).filter { matches($0.kind) }

        if let span = matching.filter({ $0.whole.location <= caret && caret <= NSMaxRange($0.whole) }).min(by: { $0.whole.length < $1.whole.length }) {
            let innerText = ns.substring(with: span.content)
            let relOffset = min(max(caret - span.whole.location - span.open.length, 0), span.content.length)
            if !alreadyMatchesTarget(span.kind) {
                return Edit(
                    range: span.whole,
                    replacement: openMark + innerText + closeMark,
                    selection: NSRange(location: span.whole.location + openLen + relOffset, length: 0)
                )
            }
            if switchOnly {
                return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
            }
            return Edit(
                range: span.whole,
                replacement: innerText,
                selection: NSRange(location: span.whole.location + relOffset, length: 0)
            )
        }

        if switchOnly {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        }

        if caret >= openLen, caret + closeLen <= ns.length,
           ns.substring(with: NSRange(location: caret - openLen, length: openLen)) == openMark,
           ns.substring(with: NSRange(location: caret, length: closeLen)) == closeMark {
            return Edit(range: NSRange(location: caret - openLen, length: openLen + closeLen), replacement: "", selection: NSRange(location: caret - openLen, length: 0))
        }

        if let word = word(touching: caret, in: contentRange, of: ns) {
            return Edit(
                range: word,
                replacement: openMark + ns.substring(with: word) + closeMark,
                selection: NSRange(location: caret + openLen, length: 0)
            )
        }

        return Edit(
            range: NSRange(location: caret, length: 0),
            replacement: openMark + closeMark,
            selection: NSRange(location: caret + openLen, length: 0)
        )
    }

    private static func strippingSpans(_ spans: [MarkdownInline.Span], inside slice: NSRange, of ns: NSString) -> String {
        guard !spans.isEmpty else { return ns.substring(with: slice) }
        var drops: [NSRange] = []
        for span in spans {
            if span.open.length > 0 { drops.append(span.open) }
            if span.close.length > 0 { drops.append(span.close) }
        }
        drops.sort { $0.location < $1.location }
        var out = ""
        var cursor = slice.location
        for drop in drops {
            if drop.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: drop.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(drop))
        }
        if cursor < NSMaxRange(slice) {
            out += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(slice) - cursor))
        }
        return out
    }

    /// Inspects active block & inline formatting at `selection` to drive the `Aa` popover checkmarks and pills.
    public static func activeFormat(in text: String, selection: NSRange) -> ActiveFormat {
        let ns = text as NSString
        guard ns.length > 0 else { return ActiveFormat() }
        let selection = clamped(selection, in: ns)
        let fences = FencedCode(text: ns)
        let role = fences.role(ofParagraphAt: selection.location)
        let mono = fences.isMonostyled(at: selection.location)
        if role != .none, !mono {
            return ActiveFormat(block: .monostyled)
        }
        let paragraph = paragraphContents(of: ns, at: selection.location)
        let u = units(of: ns, in: paragraph)
        let parsed = MarkdownInline.line(units: u, fence: role, monostyled: mono)
        var out = ActiveFormat()

        if mono {
            out.block = .monostyled
        } else {
            switch parsed.block {
            case let .heading(level):
                out.block = level == 1 ? .title : level == 2 ? .heading : .subheading
            case .bullet:
                out.block = parsed.isDashedBullet ? .dashed : .bullet
            case .numbered:
                out.block = .numbered
            case .quote:
                out.block = .quote
            case .task:
                out.isTask = true
                if let inner = parsed.innerHeadingLevel {
                    out.block = inner == 1 ? .title : inner == 2 ? .heading : .subheading
                } else {
                    out.block = .body
                }
            case .plain, .rule, .fence, .code:
                out.block = .body
            }
        }

        let probe = selection.location - paragraph.location
        for span in parsed.spans {
            let hits: Bool
            if selection.length > 0 {
                let relSel = NSRange(location: max(0, selection.location - paragraph.location), length: selection.length)
                hits = NSIntersectionRange(span.whole, relSel).length > 0
            } else {
                hits = span.whole.location <= probe && probe <= NSMaxRange(span.whole)
            }
            guard hits else { continue }
            switch span.kind {
            case .bold: out.isBold = true
            case .italic: out.isItalic = true
            case .underline: out.isUnderline = true
            case .strikethrough: out.isStrikethrough = true
            case let .highlight(c): out.highlight = c
            case let .wikiLink(target):
                let absWhole = NSRange(location: paragraph.location + span.whole.location, length: span.whole.length)
                let absContent = NSRange(location: paragraph.location + span.content.location, length: span.content.length)
                out.link = LinkMatch(wholeRange: absWhole, title: ns.substring(with: absContent), destination: target, isWiki: true)
            case let .link(url):
                let absWhole = NSRange(location: paragraph.location + span.whole.location, length: span.whole.length)
                let absContent = NSRange(location: paragraph.location + span.content.location, length: span.content.length)
                out.link = LinkMatch(wholeRange: absWhole, title: ns.substring(with: absContent), destination: url, isWiki: false)
            case .code, .bareURL:
                break
            }
        }
        return out
    }

    /// Inserts a new link or updates an existing `LinkMatch` without exposing raw Markdown syntax.
    public static func applyLink(
        destination: String,
        title: String,
        isWiki: Bool,
        replacing existing: LinkMatch? = nil,
        inTableCell: Bool = false,
        in text: String,
        selection: NSRange
    ) -> Edit {
        let ns = text as NSString
        let cleanDest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDest.isEmpty else {
            return Edit(range: NSRange(location: min(selection.location, ns.length), length: 0), replacement: "", selection: selection)
        }
        let formatted: String
        let contentOffset: Int
        let visibleTitle: String
        if isWiki {
            let safeTarget = cleanDest.hasSuffix(".md") ? String(cleanDest.dropLast(3)) : cleanDest
            visibleTitle = cleanTitle.isEmpty ? (safeTarget.split(separator: "/").last.map(String.init) ?? safeTarget) : cleanTitle
            if visibleTitle == safeTarget {
                formatted = "[[\(safeTarget)]]"
                contentOffset = 2
            } else {
                let sep = inTableCell ? "\\|" : "|"
                formatted = "[[\(safeTarget)\(sep)\(visibleTitle)]]"
                contentOffset = 2 + (safeTarget as NSString).length + (sep as NSString).length
            }
        } else {
            let safeTitle = cleanTitle.isEmpty ? cleanDest : cleanTitle.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            visibleTitle = safeTitle
            let escapedURL = cleanDest
                .replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            formatted = "[\(safeTitle)](\(escapedURL))"
            contentOffset = 1
        }
        let targetRange: NSRange
        if let existing, NSMaxRange(existing.wholeRange) <= ns.length {
            targetRange = existing.wholeRange
        } else {
            let sel = clamped(selection, in: ns)
            targetRange = sel.length > 0 ? trimmingWhiteSpace(sel, in: ns) : sel
        }
        let caretAfter = targetRange.location + contentOffset + (visibleTitle as NSString).length
        return Edit(range: targetRange, replacement: formatted, selection: NSRange(location: caretAfter, length: 0))
    }

    /// Unwraps `[Title](url)` or `[[target|Title]]` back to plain `Title`.
    public static func removeLink(_ match: LinkMatch, in text: String) -> Edit {
        let ns = text as NSString
        guard NSMaxRange(match.wholeRange) <= ns.length else {
            return Edit(range: NSRange(location: 0, length: 0), replacement: "", selection: NSRange(location: 0, length: 0))
        }
        return Edit(
            range: match.wholeRange,
            replacement: match.title,
            selection: NSRange(location: match.wholeRange.location + (match.title as NSString).length, length: 0)
        )
    }

    /// Pasting a single `http(s)://` URL over selected text wraps the selected text into `[selected](url)` automatically.
    public static func smartPaste(_ pasted: String, replacing range: NSRange, in text: String) -> Edit? {
        let ns = text as NSString
        let range = clamped(range, in: ns)
        guard range.length > 0 else { return nil }
        let chosen = trimmingWhiteSpace(range, in: ns)
        guard chosen.length > 0 else { return nil }
        let paragraph = paragraphContents(of: ns, at: chosen.location)
        guard NSMaxRange(chosen) <= NSMaxRange(paragraph) else { return nil }
        let trimmedPaste = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPaste.contains(where: \.isWhitespace),
              let safeURL = PathPolicy.safeExternalURL(trimmedPaste),
              let scheme = safeURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        let selectedWords = ns.substring(with: chosen)
        guard !selectedWords.contains("["), !selectedWords.contains("]") else { return nil }
        return applyLink(destination: safeURL.absoluteString, title: selectedWords, isWiki: false, in: text, selection: chosen)
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

    /// Moves a newly checked task (`- [x]`) and any nested child lines directly below the last unchecked task (`- [ ]`)
    /// at the same indentation level in that contiguous checklist block, matching Apple Notes auto-sorting.
    /// Returns `nil` when no unchecked task sits below it.
    public static func sortCheckedTaskToBottom(in text: String, paragraphAt location: Int, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let safeLoc = min(max(location, 0), ns.length)
        let fences = FencedCode(text: ns)
        guard fences.role(ofParagraphAt: safeLoc) == .none else { return nil }
        let p = paragraph(at: safeLoc, in: ns)
        guard let marker = p.line.marker, case .task(done: true, _) = marker.kind else { return nil }

        let baseWidth = p.width
        var subtreeLastContentsEnd = NSMaxRange(p.range)
        var cursor = nextParagraphStart(of: ns, after: p.range)
        while let at = cursor {
            let child = paragraph(at: at, in: ns)
            guard isInList(child, fences), child.width > baseWidth else { break }
            subtreeLastContentsEnd = NSMaxRange(child.range)
            cursor = nextParagraphStart(of: ns, after: child.range)
        }

        var lastUncheckedEnd: Int?
        while let at = cursor {
            let q = paragraph(at: at, in: ns)
            guard isInList(q, fences), q.width >= baseWidth else { break }
            if q.width > baseWidth {
                cursor = nextParagraphStart(of: ns, after: q.range)
                continue
            }
            guard let qMarker = q.line.marker, case let .task(done, _) = qMarker.kind else { break }
            var qSubtreeEnd = NSMaxRange(q.range)
            var sub = nextParagraphStart(of: ns, after: q.range)
            while let subAt = sub {
                let subP = paragraph(at: subAt, in: ns)
                guard isInList(subP, fences), subP.width > baseWidth else { break }
                qSubtreeEnd = NSMaxRange(subP.range)
                sub = nextParagraphStart(of: ns, after: subP.range)
            }
            if !done {
                lastUncheckedEnd = qSubtreeEnd
            }
            cursor = sub
        }

        guard let targetContentsEnd = lastUncheckedEnd, targetContentsEnd > subtreeLastContentsEnd else { return nil }
        var movedEnd = 0
        ns.getParagraphStart(nil, end: &movedEnd, contentsEnd: nil, for: NSRange(location: max(p.range.location, subtreeLastContentsEnd - 1), length: 0))
        guard movedEnd <= targetContentsEnd else { return nil }

        let movedStart = p.range.location
        let sep = ns.substring(with: NSRange(location: subtreeLastContentsEnd, length: movedEnd - subtreeLastContentsEnd))
        let movedContent = ns.substring(with: NSRange(location: movedStart, length: subtreeLastContentsEnd - movedStart))
        let betweenContent = ns.substring(with: NSRange(location: movedEnd, length: targetContentsEnd - movedEnd))
        let replacement = betweenContent + sep + movedContent

        let sel = clamped(selection, in: ns)
        let movedShift = (betweenContent as NSString).length + (sep as NSString).length
        let upShift = (movedContent as NSString).length + (sep as NSString).length
        func mapOffset(_ offset: Int) -> Int {
            if offset < movedStart || offset > targetContentsEnd { return offset }
            if offset <= subtreeLastContentsEnd { return offset + movedShift }
            if offset >= movedEnd { return offset - upShift }
            return movedStart + (betweenContent as NSString).length
        }
        let newStart = mapOffset(sel.location)
        let newEnd = max(newStart, mapOffset(NSMaxRange(sel)))
        return Edit(
            range: NSRange(location: movedStart, length: targetContentsEnd - movedStart),
            replacement: replacement,
            selection: NSRange(location: newStart, length: newEnd - newStart)
        )
    }

    /// Moves the touched paragraph(s) one paragraph up or down (`Move Up` / `Move Down` in the keyboard pill),
    /// preserving line endings, moving the selection with the line(s), and renumbering adjacent numbered lists.
    public static func moveLines(in text: String, selection: NSRange, up: Bool) -> Edit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        let noChange = Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        guard ns.length > 0 else { return noChange }

        var firstStart = 0, firstEnd = 0, firstContentsEnd = 0
        ns.getParagraphStart(&firstStart, end: &firstEnd, contentsEnd: &firstContentsEnd, for: NSRange(location: selection.location, length: 0))
        let lastProbe = selection.length > 0 ? max(firstStart, NSMaxRange(selection) - 1) : selection.location
        var lastStart = 0, lastEnd = 0, lastContentsEnd = 0
        ns.getParagraphStart(&lastStart, end: &lastEnd, contentsEnd: &lastContentsEnd, for: NSRange(location: lastProbe, length: 0))

        if up {
            guard firstStart > 0 else { return noChange }
            var prevStart = 0, prevEnd = 0, prevContentsEnd = 0
            ns.getParagraphStart(&prevStart, end: &prevEnd, contentsEnd: &prevContentsEnd, for: NSRange(location: firstStart - 1, length: 0))
            let sep = ns.substring(with: NSRange(location: prevContentsEnd, length: prevEnd - prevContentsEnd))
            let prevContent = ns.substring(with: NSRange(location: prevStart, length: prevContentsEnd - prevStart))
            let movedContent = ns.substring(with: NSRange(location: firstStart, length: lastContentsEnd - firstStart))
            let delta = prevStart - firstStart
            let newSel = NSRange(location: max(prevStart, selection.location + delta), length: selection.length)
            let rawEdit = Edit(
                range: NSRange(location: prevStart, length: lastContentsEnd - prevStart),
                replacement: movedContent + sep + prevContent,
                selection: newSel
            )
            return numbering(after: rawEdit, in: ns, rootStart: firstNumberGoing(in: rawEdit.range, of: ns), restartBelow: true)
        } else {
            guard lastEnd > lastContentsEnd, lastEnd < ns.length else { return noChange }
            var nextStart = 0, nextEnd = 0, nextContentsEnd = 0
            ns.getParagraphStart(&nextStart, end: &nextEnd, contentsEnd: &nextContentsEnd, for: NSRange(location: lastEnd, length: 0))
            let sep = ns.substring(with: NSRange(location: lastContentsEnd, length: lastEnd - lastContentsEnd))
            let movedContent = ns.substring(with: NSRange(location: firstStart, length: lastContentsEnd - firstStart))
            let nextContent = ns.substring(with: NSRange(location: nextStart, length: nextContentsEnd - nextStart))
            let delta = (nextContent as NSString).length + (sep as NSString).length
            let newSel = NSRange(location: selection.location + delta, length: selection.length)
            let rawEdit = Edit(
                range: NSRange(location: firstStart, length: nextContentsEnd - firstStart),
                replacement: nextContent + sep + movedContent,
                selection: newSel
            )
            return numbering(after: rawEdit, in: ns, rootStart: firstNumberGoing(in: rawEdit.range, of: ns), restartBelow: true)
        }
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
    /// text's. Block markers and inline formatting tags (`<mark...>`, `<u>`) don't count, so `- [x] שלום` and
    /// `<mark data-color="orange">שלום</mark>` both read right to left.
    public static func isRightToLeft(paragraph: String) -> Bool {
        let utf16 = Array(paragraph.utf16)
        let line = MarkdownLine(utf16)
        if let mark = line.mark {
            return utf16[mark] == MarkdownLine.rightToLeftMark
        }
        let parsed = MarkdownInline.line(units: utf16)
        if parsed.marks.isEmpty {
            return NoteText.isRightToLeft(String(decoding: utf16[(line.marker?.range.upperBound ?? 0)...], as: UTF16.self))
        }
        var keep = [Bool](repeating: true, count: utf16.count)
        for m in parsed.marks {
            for idx in m.location..<NSMaxRange(m) { keep[idx] = false }
        }
        let visible = utf16.indices.filter { keep[$0] }.map { utf16[$0] }
        return NoteText.isRightToLeft(String(decoding: visible, as: UTF16.self))
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
    static func isThematicBreak(_ u: ArraySlice<UInt16>) -> Bool {
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
