import Foundation

/// What a key does when it is more than text going in, as pure functions like the rest of `MarkdownEdits`.
extension MarkdownEdits {
    /// What replacing `range` with `replacement` should really do, as a text view asks before any edit. Nil: it should just
    /// do it. `text` is only read when the answer depends on it, so a letter typed into a long note costs nothing here.
    public static func typing(_ replacement: String, replacing range: NSRange, in text: @autoclosure () -> String) -> Edit? {
        let new = Array(replacement.utf16)
        if new == [0x0A] { return returnKey(in: text(), selection: range) }
        if new == [0x09] {
            // On a list item, Tab nests it. Anywhere else it is a tab.
            let edit = indent(in: text(), selection: range)
            return edit.changesNothing ? nil : edit
        }
        // Pasting a single http(s) URL onto selected words turns the selection into a clean link.
        if range.length > 0, !new.isEmpty, !new.contains(where: { $0 == 0x0A || $0 == 0x0D }),
           let linkEdit = smartPaste(replacement, replacing: range, in: text()) {
            return linkEdit
        }
        // A letter typed at a caret can't be about lines. Everything else needs a look at the note.
        let bringsLines = new.contains { $0 == 0x0A || $0 == 0x0D }
        guard bringsLines || range.length > 0 else { return nil }
        let ns = text() as NSString
        let range = clamped(range, in: ns)
        if new.isEmpty, let edit = removingMarker(before: range, in: ns) { return edit }
        if new.isEmpty, let edit = deletingAroundHiddenInlineMark(range, in: ns) { return edit }
        guard bringsLines || ns.substring(with: range).utf16.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return nil }
        return replacingLines(range, with: replacement, in: ns)
    }

    // MARK: Return

    /// Return breaks the line, but never a link or a pair of marks. Inside `[[a]]` it goes behind the link: the bar leaves
    /// the caret between the brackets, and pressing Return after typing the name must not leave `[[a` on one line and `]]`
    /// on the next. Inside `**a**` both halves stay bold. A list goes on, or ends if its item is empty: `returnInItem`. Keeps
    /// the note's line endings. Nil: an ordinary line break.
    static func returnKey(in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        guard selection.length == 0 else {
            // As if the selection went first.
            let after = ns.replacingCharacters(in: selection, with: "")
            guard let edit = returnKey(in: after, selection: NSRange(location: selection.location, length: 0)) else { return nil }
            return minimal(from: ns, to: edit.applied(to: after) as NSString, selection: edit.selection)
        }
        // A text view writes LF. A CRLF note's line break has to be written here.
        let isCRLF = Array(lineEnding(in: text, at: selection.location).utf8) == [0x0D, 0x0A]
        let ending = isCRLF ? "\r\n" : "\n"
        let ordinary = isCRLF ? inserting(ending, at: selection.location) : nil
        let paragraph = paragraphContents(of: ns, at: selection.location)
        let line = units(of: ns, in: paragraph)
        let block = MarkdownLine(line)
        let place = linePlace(forCaret: selection.location - paragraph.location, in: line)
        let inItem = block.marker.map { $0.kind.isListItem && place.at >= $0.range.upperBound } ?? false
        guard inItem || place.needsMore(thanCaret: selection.location - paragraph.location) else { return ordinary }
        // Nothing in fenced code is Markdown.
        guard FencedCode(text: ns).role(ofParagraphAt: paragraph.location) == .none else { return ordinary }
        if inItem { return returnInItem(Paragraph(range: paragraph, units: line, line: block), at: place, ending: ending, in: ns) }
        return inserting(place.closers + ending + place.openers, at: paragraph.location + place.at)
    }

    static func inserting(_ text: String, at location: Int) -> Edit {
        Edit(range: NSRange(location: location, length: 0), replacement: text, selection: NSRange(location: location + (text as NSString).length, length: 0))
    }

    /// Where a line break goes for a caret at this offset of a line, and the marks that keep each half whole around it.
    struct LinePlace {
        var at: Int
        var closers = ""
        var openers = ""

        func needsMore(thanCaret caret: Int) -> Bool { at != caret || !closers.isEmpty || !openers.isEmpty }
    }

    private static func linePlace(forCaret caret: Int, in u: [UInt16]) -> LinePlace {
        func text(_ range: NSRange) -> String { String(decoding: u[range.location..<NSMaxRange(range)], as: UTF16.self) }
        // `[[‸]]`, as the bar leaves it: no span yet, since a link with no name is none.
        if caret >= 2, caret + 2 <= u.count, u[caret - 2] == 0x5B, u[caret - 1] == 0x5B, u[caret] == 0x5D, u[caret + 1] == 0x5D {
            return LinePlace(at: caret + 2)
        }
        var at = caret
        let spans = MarkdownInline.line(units: u).spans
        func isLink(_ span: MarkdownInline.Span) -> Bool {
            switch span.kind {
            case .wikiLink, .link: true
            default: false
            }
        }
        if let link = spans.first(where: { isLink($0) && $0.whole.location < at && at < NSMaxRange($0.whole) }) {
            at = NSMaxRange(link.whole)
        }
        let emphasis = spans.filter {
            switch $0.kind {
            case .bold, .italic, .strikethrough, .underline, .highlight, .code: true
            default: false
            }
        }
        // Touching or inside a pair's marks: out of them, on that side, and out of any pair around it as well.
        var moved = true
        while moved {
            moved = false
            if let span = emphasis.first(where: { NSMaxRange($0.content) <= at && at < NSMaxRange($0.whole) }) {
                at = NSMaxRange(span.whole)
                moved = true
            } else if let span = emphasis.first(where: { $0.whole.location < at && at <= $0.content.location }) {
                at = span.whole.location
                moved = true
            }
        }
        // Inside the text of a pair: it closes on this line and opens again on the next, the innermost closing first.
        let around = emphasis.filter { $0.content.location < at && at < NSMaxRange($0.content) }.sorted { $0.whole.location < $1.whole.location }
        return LinePlace(at: at,
                         // A pair still open at the line's end has no closing mark to copy.
                         closers: around.reversed().map { $0.close.length > 0 ? text($0.close) : text($0.open) }.joined(),
                         openers: around.map { text($0.open) }.joined())
    }

    // MARK: Backspace across hidden inline delimiters

    /// Prevents a single-character Backspace from tearing half of a hidden `**`, `~~`, `<u>`, `<mark>`, `[[...]]`, or `[Title](url)`.
    static func deletingAroundHiddenInlineMark(_ range: NSRange, in ns: NSString) -> Edit? {
        guard range.length == 1 else { return nil }
        let paragraph = paragraphContents(of: ns, at: range.location)
        guard NSMaxRange(range) <= NSMaxRange(paragraph) else { return nil }
        guard FencedCode(text: ns).role(ofParagraphAt: paragraph.location) == .none else { return nil }
        let u = units(of: ns, in: paragraph)
        let parsed = MarkdownInline.line(units: u)
        let relDelete = range.location - paragraph.location

        // Outermost span whose closing delimiter or opening delimiter is hit by this 1-unit delete
        for span in parsed.spans {
            if case .bareURL = span.kind { continue }
            // 1. Backspace right after or inside `span.close` (e.g. `[Google](url)‸` or `**bold**‸`)
            if span.close.length > 0, span.close.location <= relDelete, relDelete < NSMaxRange(span.close) {
                let absWhole = NSRange(location: paragraph.location + span.whole.location, length: span.whole.length)
                let absContentEnd = paragraph.location + NSMaxRange(span.content)
                let contentStr = ns.substring(with: NSRange(location: paragraph.location + span.content.location, length: span.content.length))
                if contentStr.count <= 1 {
                    return Edit(range: absWhole, replacement: "", selection: NSRange(location: absWhole.location, length: 0))
                }
                let lastCharRange = ns.rangeOfComposedCharacterSequence(at: max(paragraph.location + span.content.location, absContentEnd - 1))
                let newEndCaret = absWhole.location + span.whole.length - lastCharRange.length
                return Edit(range: lastCharRange, replacement: "", selection: NSRange(location: newEndCaret, length: 0))
            }
            // 2. Backspace right after or inside `span.open` (e.g. `[‸Google](url)` or `**‸bold**`)
            if span.open.length > 0, span.open.location <= relDelete, relDelete < NSMaxRange(span.open) {
                let absOpen = NSRange(location: paragraph.location + span.open.location, length: span.open.length)
                let absClose = NSRange(location: paragraph.location + span.close.location, length: span.close.length)
                let absContent = NSRange(location: paragraph.location + span.content.location, length: span.content.length)
                let inner = ns.substring(with: absContent)
                let absWhole = NSRange(location: absOpen.location, length: NSMaxRange(absClose) - absOpen.location)
                // Unwrap the inline formatting / link cleanly at its leading edge (matching Apple Notes)
                return Edit(range: absWhole, replacement: inner, selection: NSRange(location: absWhole.location, length: 0))
            }
        }
        return nil
    }

    // MARK: one replacement

    /// The smallest single replacement from one text to the other, starting and ending between whole characters.
    static func minimal(from old: NSString, to new: NSString, selection: NSRange) -> Edit {
        let a = units(of: old, in: NSRange(location: 0, length: old.length))
        let b = units(of: new, in: NSRange(location: 0, length: new.length))
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        if prefix < a.count { prefix = min(prefix, old.rangeOfComposedCharacterSequence(at: prefix).location) }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, suffix < a.count {
            let character = old.rangeOfComposedCharacterSequence(at: a.count - suffix)
            if character.location < a.count - suffix { suffix = a.count - NSMaxRange(character) }
        }
        return Edit(range: NSRange(location: prefix, length: a.count - suffix - prefix),
                    replacement: String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self),
                    selection: selection)
    }
}
