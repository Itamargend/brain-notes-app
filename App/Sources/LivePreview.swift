import BrainNotesKit
import Foundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Live Preview, as in Obsidian: the file stays plain Markdown, byte for byte, and only its look changes. Syntax marks
// are hidden everywhere except in the paragraphs holding the caret or the selection, where they show, dimmed, for
// editing. Nothing here edits the text: marks are attributes on characters that stay in the storage, so caret offsets,
// selection, copy (the source), undo, saving and the sync are the same as if every mark were on screen.

extension NSAttributedString.Key {
    /// On a syntax mark while it is hidden.
    static let bnHiddenMark = NSAttributedString.Key("bnHiddenMark")
    /// A wiki link's target, for links and backlinks later.
    static let bnWikiTarget = NSAttributedString.Key("bnWikiTarget")
    /// What `MarkdownLayoutFragment` draws for this paragraph, instead of the marks it stands for.
    static let bnLineDecoration = NSAttributedString.Key("bnLineDecoration")
}

/// One paragraph's drawn part. An attribute, so the storage's text stays the file's.
final class LineDecoration: NSObject {
    enum Kind: Equatable {
        case checkbox(done: Bool)
        case bullet
        case quote
        case rule
        /// The band behind fenced code, with its round corners at the two ends.
        case codeFirst, codeMiddle, codeLast
        /// First line of a GFM table: its line is as tall as the grid (`TableOverlay`) that sits over it. Bytes stay pipe Markdown.
        case tableAnchor
        /// Later table lines: collapsed, since the grid above already shows them.
        case tableHidden
    }

    let kind: Kind
    let rightToLeft: Bool
    /// From the paragraph's leading edge to the glyph.
    let lead: CGFloat

    init(kind: Kind, rightToLeft: Bool, lead: CGFloat) {
        self.kind = kind
        self.rightToLeft = rightToLeft
        self.lead = lead
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LineDecoration else { return false }
        return kind == other.kind && rightToLeft == other.rightToLeft && lead == other.lead
    }

    override var hash: Int { Int(lead) &* 31 &+ (rightToLeft ? 1 : 0) }

    /// A table's source, hidden behind its grid.
    var isTable: Bool { kind == .tableAnchor || kind == .tableHidden }
}

enum LivePreviewMetrics {
    /// One level of a nested list.
    static let levelIndent: CGFloat = 20
    /// The room a checkbox or a bullet takes in front of its text.
    static let markerSlot: CGFloat = 26
    static let quoteIndent: CGFloat = 14
}

extension PlatformColor {
    static var bnText: PlatformColor {
        #if os(iOS)
        .label
        #else
        .labelColor
        #endif
    }

    static var bnSecondary: PlatformColor {
        #if os(iOS)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    static var bnMark: PlatformColor {
        #if os(iOS)
        .tertiaryLabel
        #else
        .tertiaryLabelColor
        #endif
    }

    static var bnAccent: PlatformColor {
        #if os(iOS)
        UIColor(named: "AccentColor") ?? .tintColor
        #else
        NSColor(named: "AccentColor") ?? .controlAccentColor
        #endif
    }

    static var bnCodeFill: PlatformColor {
        #if os(iOS)
        .tertiarySystemFill
        #else
        .quaternaryLabelColor
        #endif
    }

    static var bnSeparator: PlatformColor {
        #if os(iOS)
        .separator
        #else
        .separatorColor
        #endif
    }
}

// MARK: - the attributes

/// Markdown attributes for the editor, one paragraph at a time. Only the look changes; the text is the file's text,
/// byte for byte, because the storage's characters are never touched here.
enum MarkdownStyler {
    /// A table of the note, as the styling and the grid over it see it.
    struct TableSpan: Equatable {
        var range: NSRange
        var table: MarkdownTable
        /// Its text's direction, or the one of the line above it if it has no text yet.
        var rightToLeft: Bool
        /// What its first line reserves for the grid.
        var height: CGFloat
    }

    /// What styling needs from outside the paragraph.
    struct Context {
        var fences = FencedCode()
        /// Always hidden, focus or not, VoiceOver or not: a table is only ever its grid.
        var tables: [TableSpan] = []
        /// The paragraphs holding the caret or the selection, whose marks show. Nil when the editor has no focus.
        var revealed: NSRange?
        /// Off while VoiceOver runs: what it reads and where the caret stops are then what is on screen.
        var hidesMarks = true

        func shows(_ paragraph: NSRange) -> Bool {
            guard hidesMarks else { return true }
            guard let revealed else { return false }
            if revealed.length == 0 { return paragraph.location <= revealed.location && revealed.location < NSMaxRange(paragraph) }
            return paragraph.location < NSMaxRange(revealed) && revealed.location < NSMaxRange(paragraph)
        }
    }

    /// Fonts and colours for one pass.
    fileprivate final class Palette {
        let body = PlatformFont.preferredFont(forTextStyle: .body)
        lazy var hidden = PlatformFont.systemFont(ofSize: 0.01)
        lazy var code = PlatformFont.monospacedSystemFont(ofSize: body.pointSize * 0.94, weight: .regular)
        private var fonts: [Int: PlatformFont] = [:]
        private var markerWidths: [String: CGFloat] = [:]

        /// How wide a number's marker is, `12. ` with its space, in a font.
        func width(ofMarker marker: String, in font: PlatformFont) -> CGFloat {
            let key = "\(font.pointSize) \(marker)"
            if let known = markerWidths[key] { return known }
            let width = ceil((marker as NSString).size(withAttributes: [.font: font]).width)
            markerWidths[key] = width
            return width
        }

        /// Level 0 is body text.
        func font(level: Int, bold: Bool = false, italic: Bool = false) -> PlatformFont {
            let key = level * 4 + (bold ? 1 : 0) + (italic ? 2 : 0)
            if let known = fonts[key] { return known }
            let base: PlatformFont
            if level == 0 {
                base = body
            } else {
                let style: PlatformFont.TextStyle = level == 1 ? .title1 : level == 2 ? .title2 : level == 3 ? .title3 : .headline
                base = Self.with(PlatformFont.preferredFont(forTextStyle: style), bold: true, italic: false)
            }
            let font = Self.with(base, bold: bold, italic: italic)
            fonts[key] = font
            return font
        }

        /// Hebrew has no italic in the system font, so an italic font alone would change nothing: a run with Hebrew in
        /// it gets the upright font, skewed.
        func slanted(level: Int, bold: Bool) -> PlatformFont {
            let key = -(level * 4 + (bold ? 1 : 0)) - 1
            if let known = fonts[key] { return known }
            let upright = font(level: level, bold: bold)
            #if os(iOS)
            let skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            let slanted = UIFont(descriptor: upright.fontDescriptor.addingAttributes([.matrix: skew]), size: 0)
            #else
            let skew = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
            let slanted = NSFont(descriptor: upright.fontDescriptor.addingAttributes([.matrix: skew]), size: 0) ?? upright
            #endif
            fonts[key] = slanted
            return slanted
        }

        private static func with(_ font: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
            guard bold || italic else { return font }
            #if os(iOS)
            var traits = font.fontDescriptor.symbolicTraits
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: 0)
            #else
            var out = font
            if bold { out = NSFontManager.shared.convert(out, toHaveTrait: .boldFontMask) }
            if italic { out = NSFontManager.shared.convert(out, toHaveTrait: .italicFontMask) }
            return out
            #endif
        }
    }

    /// The look a paragraph's text has, before its spans.
    private struct Look {
        var font: PlatformFont
        var color: PlatformColor
        var style: NSParagraphStyle
        var decoration: LineDecoration?
        /// What the space behind a number needs to be wider by, so that the text of the items lines up.
        var numberGap: CGFloat = 0

        var attributes: [NSAttributedString.Key: Any] {
            var out: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let decoration { out[.bnLineDecoration] = decoration }
            return out
        }
    }

    private static func look(of line: MarkdownInline.Line, units: [UInt16], role: FencedCode.Role, rightToLeft rtl: Bool, shown: Bool, palette: Palette) -> Look {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.alignment = rtl ? .right : .left
        style.paragraphSpacing = 4
        var font = line.headingLevel > 0 ? palette.font(level: line.headingLevel) : palette.body
        var color = PlatformColor.bnText
        var decoration: LineDecoration?
        var numberGap: CGFloat = 0
        // A line whose text is all hidden marks would otherwise have no height at all.
        var hasHiddenMarker = false

        switch line.block {
        case .plain:
            break
        case let .numbered(marker, level):
            // The number is text, so it has no slot of its own to sit in. Its space stretches to one, room for two digits,
            // so that the text of the items lines up, and wrapped lines hang under that text. Longer numbers take what they need.
            let text = String(decoding: units[marker.location..<NSMaxRange(marker)], as: UTF16.self)
            let width = palette.width(ofMarker: text, in: font)
            let slot = max(LivePreviewMetrics.markerSlot, palette.width(ofMarker: "00. ", in: font), width)
            let lead = CGFloat(level) * LivePreviewMetrics.levelIndent
            style.headIndent = lead + slot
            if !shown { style.firstLineHeadIndent = lead }
            numberGap = slot - width
        case .heading:
            hasHiddenMarker = !shown
        case let .bullet(level):
            let lead = CGFloat(level) * LivePreviewMetrics.levelIndent
            style.headIndent = lead + LivePreviewMetrics.markerSlot
            if !shown {
                style.firstLineHeadIndent = style.headIndent
                decoration = LineDecoration(kind: .bullet, rightToLeft: rtl, lead: lead)
                hasHiddenMarker = true
            }
        case let .task(done, level, _):
            let lead = CGFloat(level) * LivePreviewMetrics.levelIndent
            style.headIndent = lead + LivePreviewMetrics.markerSlot
            if !shown {
                style.firstLineHeadIndent = style.headIndent
                decoration = LineDecoration(kind: .checkbox(done: done), rightToLeft: rtl, lead: lead)
                hasHiddenMarker = true
            }
        case .quote:
            color = .bnSecondary
            if !shown {
                style.firstLineHeadIndent = LivePreviewMetrics.quoteIndent
                style.headIndent = LivePreviewMetrics.quoteIndent
                decoration = LineDecoration(kind: .quote, rightToLeft: rtl, lead: 0)
                hasHiddenMarker = true
            }
        case .rule:
            if !shown {
                decoration = LineDecoration(kind: .rule, rightToLeft: rtl, lead: 0)
                hasHiddenMarker = true
            }
        case .fence, .code:
            font = palette.code
            style.paragraphSpacing = 0
            let kind: LineDecoration.Kind = role == .opening ? .codeFirst : role == .closing ? .codeLast : .codeMiddle
            decoration = LineDecoration(kind: kind, rightToLeft: false, lead: 0)
            hasHiddenMarker = !shown
        }
        if hasHiddenMarker {
            style.minimumLineHeight = ceil(lineHeight(of: font))
        }
        return Look(font: font, color: color, style: style, decoration: decoration, numberGap: numberGap)
    }

    fileprivate static func lineHeight(of font: PlatformFont) -> CGFloat {
        #if os(iOS)
        font.lineHeight
        #else
        font.ascender - font.descender + font.leading
        #endif
    }

    /// Styles every paragraph touching `range`.
    static func style(_ storage: NSTextStorage, in range: NSRange, context: Context = Context()) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let clamped = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        let whole = ns.paragraphRange(for: clamped)
        let palette = Palette()
        storage.beginEditing()
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, enclosing, _ in
            var units = [UInt16](repeating: 0, count: paragraph.length)
            ns.getCharacters(&units, range: paragraph)
            let role = context.fences.role(ofParagraphAt: paragraph.location)
            let line = MarkdownInline.line(units: units, fence: role)
            let rtl = isRightToLeft(units, line: line, role: role, at: paragraph.location, in: ns)
            let shown = context.shows(enclosing)
            let look = look(of: line, units: units, role: role, rightToLeft: rtl, shown: shown, palette: palette)
            storage.setAttributes(look.attributes, range: enclosing)
            if look.numberGap > 0, case let .numbered(marker, _) = line.block {
                storage.addAttribute(.kern, value: look.numberGap, range: NSRange(location: paragraph.location + NSMaxRange(marker) - 1, length: 1))
            }
            applySpans(of: line, units: units, level: line.headingLevel, to: storage, at: paragraph.location, shown: shown, palette: palette)
        }
        hideTables(storage, in: whole, context: context, palette: palette)
        storage.endEditing()
    }

    /// A paragraph's direction. Code reads left to right, even inside a Hebrew note. A list item with no text yet has no
    /// direction of its own, so it takes the one above it: a new item in a Hebrew list starts on the right, instead of
    /// jumping there with its first letter. For the look only: nothing is written to the file.
    static func isRightToLeft(_ units: [UInt16], line: MarkdownInline.Line, role: FencedCode.Role, at start: Int, in ns: NSString) -> Bool {
        guard role == .none else { return false }
        guard isEmptyItem(line, units: units) else { return MarkdownEdits.isRightToLeft(paragraph: String(decoding: units, as: UTF16.self)) }
        var at = start
        // No further than anyone is writing a list of empty items.
        for _ in 0..<32 where at > 0 {
            var previous = 0, contentsEnd = 0
            ns.getParagraphStart(&previous, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: at - 1, length: 0))
            var above = [UInt16](repeating: 0, count: contentsEnd - previous)
            ns.getCharacters(&above, range: NSRange(location: previous, length: contentsEnd - previous))
            guard isEmptyItem(MarkdownInline.line(units: above), units: above) else {
                return MarkdownEdits.isRightToLeft(paragraph: String(decoding: above, as: UTF16.self))
            }
            at = previous
        }
        return false
    }

    private static func isEmptyItem(_ line: MarkdownInline.Line, units: [UInt16]) -> Bool {
        guard line.directionMark == nil, line.textStart == units.count else { return false }
        switch line.block {
        case .bullet, .task, .numbered: return true
        default: return false
        }
    }

    fileprivate static func applySpans(of line: MarkdownInline.Line, units: [UInt16], level: Int, to storage: NSMutableAttributedString, at start: Int, shown: Bool, palette: Palette) {
        let length = units.count
        func absolute(_ r: NSRange) -> NSRange { NSRange(location: start + r.location, length: r.length) }
        if case let .numbered(marker, _) = line.block {
            storage.addAttribute(.foregroundColor, value: PlatformColor.bnSecondary, range: absolute(marker))
        }

        if !line.spans.isEmpty {
            // Bold and italic can nest and overlap, so fonts are worked out per run of characters.
            var traits: [UInt8]?
            func mark(_ r: NSRange, _ flag: UInt8) {
                if traits == nil { traits = [UInt8](repeating: 0, count: length) }
                for i in r.location..<NSMaxRange(r) { traits?[i] |= flag }
            }
            for span in line.spans {
                let content = absolute(span.content)
                switch span.kind {
                case .bold:
                    mark(span.content, 1)
                case .italic:
                    mark(span.content, 2)
                case .strikethrough:
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                case .code, .wikiLink, .link, .bareURL:
                    break
                }
            }
            if let traits {
                var i = 0
                while i < length {
                    let t = traits[i]
                    var j = i + 1
                    while j < length, traits[j] == t { j += 1 }
                    if t != 0 {
                        let hebrew = t & 2 != 0 && units[i..<j].contains { (0x0590...0x05FF).contains($0) }
                        let font = hebrew ? palette.slanted(level: level, bold: t & 1 != 0) : palette.font(level: level, bold: t & 1 != 0, italic: t & 2 != 0)
                        storage.addAttribute(.font, value: font, range: NSRange(location: start + i, length: j - i))
                    }
                    i = j
                }
            }
            for span in line.spans {
                let content = absolute(span.content)
                switch span.kind {
                case .code:
                    storage.addAttributes([.font: palette.code, .backgroundColor: PlatformColor.bnCodeFill], range: content)
                case let .wikiLink(target):
                    storage.addAttributes([.foregroundColor: PlatformColor.bnAccent, .bnWikiTarget: target], range: content)
                case .link, .bareURL:
                    storage.addAttribute(.foregroundColor, value: PlatformColor.bnAccent, range: content)
                case .bold, .italic, .strikethrough:
                    break
                }
            }
        }

        for range in line.marks {
            let r = absolute(range)
            if shown {
                storage.addAttribute(.foregroundColor, value: PlatformColor.bnMark, range: r)
            } else {
                storage.addAttributes([.font: palette.hidden, .foregroundColor: PlatformColor.clear, .bnHiddenMark: true], range: r)
            }
        }
    }

    /// A table's source takes no room and draws nothing, wherever the caret is: the first line is as tall as the grid
    /// over it (`TableOverlay`) and the others have no height. Only what this pass touches is changed, so a keystroke in a
    /// cell of a long table costs one line. Only attributes change: the storage still holds the file's bytes.
    private static func hideTables(_ storage: NSTextStorage, in whole: NSRange, context: Context, palette: Palette) {
        guard !context.tables.isEmpty else { return }
        let ns = storage.string as NSString
        for span in context.tables {
            let touched = NSIntersectionRange(span.range, whole)
            guard touched.length > 0 else { continue }
            var at = touched.location
            while at < NSMaxRange(touched) {
                let paragraph = ns.paragraphRange(for: NSRange(location: at, length: 0))
                let isFirst = paragraph.location <= span.range.location
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byClipping
                if isFirst {
                    style.minimumLineHeight = span.height
                } else {
                    style.minimumLineHeight = 0.01
                    style.maximumLineHeight = 0.01
                }
                storage.setAttributes([
                    .font: palette.hidden,
                    .foregroundColor: PlatformColor.clear,
                    .bnHiddenMark: true,
                    .paragraphStyle: style,
                    .bnLineDecoration: LineDecoration(kind: isFirst ? .tableAnchor : .tableHidden, rightToLeft: span.rightToLeft, lead: 0),
                ], range: NSIntersectionRange(paragraph, span.range))
                let next = NSMaxRange(paragraph)
                if next <= at { break }
                at = next
            }
        }
    }

    /// What the styling reserves for a table when no grid has said yet.
    static func estimatedTableHeight(_ table: MarkdownTable) -> CGFloat {
        let row = ceil(lineHeight(of: PlatformFont.preferredFont(forTextStyle: .body))) + 2 * TableGridMetrics.cellPaddingY
        return row * CGFloat(table.gridRowCount) + TableGridMetrics.marginAbove + TableGridMetrics.marginBelow
    }

    /// Paints table cells: their text with its inline Markdown, for one pass over a grid. Fonts are the note's, so a cell
    /// reads like the text around it.
    @MainActor
    final class CellPainter {
        private let palette = Palette()
        private let header: PlatformFont

        init() {
            header = PlatformFont.systemFont(ofSize: palette.body.pointSize, weight: .semibold)
        }

        var lineHeight: CGFloat { MarkdownStyler.lineHeight(of: palette.body) }

        /// A cell's paragraph: right to left if its text is, or if it has none and the table is. An explicit alignment
        /// goes by the table's direction, as in the note view.
        func paragraph(text: String, alignment: MarkdownTable.Alignment, tableRightToLeft: Bool) -> NSParagraphStyle {
            let rightToLeft = MarkdownTable.statedRightToLeft(ofText: text) ?? tableRightToLeft
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            switch alignment {
            case .none: style.alignment = rightToLeft ? .right : .left
            case .center: style.alignment = .center
            case .left: style.alignment = tableRightToLeft ? .right : .left
            case .right: style.alignment = tableRightToLeft ? .left : .right
            }
            return style
        }

        func attributes(isHeader: Bool, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
            [.font: isHeader ? header : palette.body, .foregroundColor: PlatformColor.bnText, .paragraphStyle: paragraph]
        }

        /// A cell as it looks. With `showsMarks`, the same characters as `text`, marks dimmed, as on a line being edited.
        /// Without, the marks are gone: what a reader sees.
        func text(_ text: String, isHeader: Bool, showsMarks: Bool, alignment: MarkdownTable.Alignment, tableRightToLeft: Bool) -> NSAttributedString {
            let out = NSMutableAttributedString(string: text, attributes: attributes(isHeader: isHeader, paragraph: paragraph(text: text, alignment: alignment, tableRightToLeft: tableRightToLeft)))
            guard !text.isEmpty else { return out }
            let units = Array(text.utf16)
            let line = MarkdownInline.inline(units: units)
            MarkdownStyler.applySpans(of: line, units: units, level: 0, to: out, at: 0, shown: showsMarks, palette: palette)
            if !showsMarks {
                for mark in line.marks.reversed() { out.deleteCharacters(in: mark) }
            }
            return out
        }
    }

    /// Typing attributes for a paragraph: its plain look, so that what is typed next to a mark is neither dim nor hidden,
    /// also during a composition, when nothing is restyled.
    static func typing(forParagraph units: [UInt16], role: FencedCode.Role, rightToLeft: Bool) -> [NSAttributedString.Key: Any] {
        let line = MarkdownInline.line(units: units, fence: role)
        return look(of: line, units: units, role: role, rightToLeft: rightToLeft, shown: true, palette: Palette()).attributes
    }

    /// Typing attributes for an empty note.
    static var typing: [NSAttributedString.Key: Any] { typing(forParagraph: [], role: .none, rightToLeft: false) }
}

// MARK: - the drawn part

/// Draws a paragraph's checkbox, bullet, quote bar, rule or code band. These stand in for marks that are still in the text.
final class MarkdownLayoutFragment: NSTextLayoutFragment {
    private var decoration: LineDecoration? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return nil }
        return paragraph.attributedString.attribute(.bnLineDecoration, at: 0, effectiveRange: nil) as? LineDecoration
    }

    private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 0 }
    private var containerWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX }
    /// A fragment's frame hugs its text, so what is drawn here is placed from the container's edges. In this fragment's
    /// coordinates, the container's left edge is at minus the frame's x.
    private var containerLeft: CGFloat { -layoutFragmentFrame.minX }

    override var renderingSurfaceBounds: CGRect {
        guard let decoration else { return super.renderingSurfaceBounds }
        // Nothing to draw, and a surface as tall as the grid would be memory for no pixels.
        if decoration.isTable { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return super.renderingSurfaceBounds.union(CGRect(x: containerLeft, y: 0, width: containerWidth, height: layoutFragmentFrame.height))
    }

    /// The first line's slot in front of its text, in this fragment's coordinates.
    func markerSlot(lead: CGFloat, rightToLeft: Bool) -> CGRect {
        let line = textLineFragments.first
        let height = line?.typographicBounds.height ?? layoutFragmentFrame.height
        let top = line?.typographicBounds.minY ?? 0
        let x = rightToLeft
            ? containerLeft + containerWidth - padding - lead - LivePreviewMetrics.markerSlot
            : containerLeft + padding + lead
        return CGRect(x: x, y: top, width: LivePreviewMetrics.markerSlot, height: height)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if decoration?.isTable == true { return }
        if let decoration {
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            drawDecoration(decoration, in: context)
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }

    private func drawDecoration(_ decoration: LineDecoration, in context: CGContext) {
        switch decoration.kind {
        case let .checkbox(done):
            let slot = markerSlot(lead: decoration.lead, rightToLeft: decoration.rightToLeft)
            drawCheckbox(done: done, at: glyphCenter(in: slot, rightToLeft: decoration.rightToLeft, inset: checkboxSize / 2 + 6), context)
        case .bullet:
            let slot = markerSlot(lead: decoration.lead, rightToLeft: decoration.rightToLeft)
            let size: CGFloat = 5.5
            let center = glyphCenter(in: slot, rightToLeft: decoration.rightToLeft, inset: 12)
            context.setFillColor(PlatformColor.bnSecondary.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        case .quote:
            let x = decoration.rightToLeft ? containerLeft + containerWidth - padding - 3 : containerLeft + padding
            context.setFillColor(PlatformColor.bnAccent.cgColor)
            let bar = CGRect(x: x, y: 1, width: 3, height: layoutFragmentFrame.height - 2)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        case .rule:
            let y = (textLineFragments.first?.typographicBounds.height ?? layoutFragmentFrame.height) / 2
            context.setFillColor(PlatformColor.bnSeparator.cgColor)
            context.fill(CGRect(x: containerLeft + padding, y: y, width: containerWidth - 2 * padding, height: 1))
        case .codeFirst, .codeMiddle, .codeLast:
            drawCodeBand(decoration.kind, in: context)
        case .tableAnchor, .tableHidden:
            break
        }
    }

    private var checkboxSize: CGFloat { ceil(PlatformFont.preferredFont(forTextStyle: .body).pointSize * 1.05) }

    /// The middle of a glyph in a slot: `inset` from the slot's text end, on the middle of the first line. Not on the
    /// baseline: a line with no text yet has its baseline in another place.
    private func glyphCenter(in slot: CGRect, rightToLeft: Bool, inset: CGFloat) -> CGPoint {
        CGPoint(x: rightToLeft ? slot.minX + inset : slot.maxX - inset, y: slot.midY)
    }

    private func drawCheckbox(done: Bool, at center: CGPoint, _ context: CGContext) {
        let size = checkboxSize
        let circle = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if done {
            context.setFillColor(PlatformColor.bnAccent.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(PlatformColor.white.cgColor)
            context.setLineWidth(max(1.5, size * 0.11))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: center.x - size * 0.24, y: center.y + size * 0.02))
            context.addLine(to: CGPoint(x: center.x - size * 0.06, y: center.y + size * 0.2))
            context.addLine(to: CGPoint(x: center.x + size * 0.26, y: center.y - size * 0.2))
            context.strokePath()
        } else {
            context.setStrokeColor(PlatformColor.bnSecondary.cgColor)
            context.setLineWidth(1.2)
            context.strokeEllipse(in: circle.insetBy(dx: 0.6, dy: 0.6))
        }
    }

    private func drawCodeBand(_ kind: LineDecoration.Kind, in context: CGContext) {
        // Not the frame's height: at the end of a note it also holds the empty line after the last line ending.
        let height = textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY ?? layoutFragmentFrame.height
        let band = CGRect(x: containerLeft + padding - 4, y: 0, width: containerWidth - 2 * padding + 8, height: height)
        let radius: CGFloat = kind == .codeMiddle ? 0 : 7
        context.setFillColor(PlatformColor.bnCodeFill.cgColor)
        guard radius > 0 else { return context.fill(band) }
        let path = CGMutablePath()
        let rounded = kind == .codeFirst
            ? CGRect(x: band.minX, y: band.minY, width: band.width, height: band.height + radius)
            : CGRect(x: band.minX, y: band.minY - radius, width: band.width, height: band.height + radius)
        path.addRoundedRect(in: rounded, cornerWidth: radius, cornerHeight: radius)
        context.saveGState()
        context.clip(to: band)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

/// Hands TextKit 2 the fragment above for every paragraph.
final class MarkdownFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - what is hidden, as the text and the caret move

/// One editor's styling state, the same on iPhone and Mac: the coordinators only tell it what happened. It sees every
/// change to the text through the storage, whatever made it: typing, the bar, undo, paste or dictation.
@MainActor
final class LivePreview: NSObject, NSTextStorageDelegate {
    let storage: NSTextStorage
    private let layoutManager: NSTextLayoutManager?
    private let fragments = MarkdownFragmentProvider()
    private(set) var context = MarkdownStyler.Context()
    /// Text edited since the last styling, and whether a fence line was among it.
    private var dirty: NSRange?
    private var touchedFence = false
    /// How tall a table's grid is, given its place among the tables. Set by the editor's grid.
    var tableHeight: ((MarkdownTable, Int) -> CGFloat)?
    /// A table is being typed by hand, as the caret is on its lines: it stays text until the caret leaves them. `|---|-` is
    /// a valid delimiter row well before `|---|---|` is finished, and what comes next must go on being typed there.
    private var isTypingATable = false
    /// The list of tables changed since the editor's grid last looked.
    private var tablesDidChange = false
    /// The text changed and, by the end of this turn of the run loop, no one has said so. A text view undoing an edit
    /// while a table's cell has the focus doesn't: it isn't the first responder. What is on screen and in the file must
    /// still follow.
    var editWentUnannounced: (() -> Void)?

    private var ns: NSString { storage.string as NSString }

    init(storage: NSTextStorage, layoutManager: NSTextLayoutManager?, hidesMarks: Bool) {
        self.storage = storage
        self.layoutManager = layoutManager
        context.hidesMarks = hidesMarks
        super.init()
        storage.delegate = self
        layoutManager?.delegate = fragments
    }

    /// The whole text is new: on load, and when a sync replaced it.
    func reload(selection: NSRange, focused: Bool) {
        dirty = nil
        touchedFence = false
        context.fences = FencedCode(text: ns)
        context.revealed = wanted(selection, focused: focused)
        isTypingATable = false
        context.tables = scannedTables()
        restyleAll()
    }

    /// Every table of the note as it is now, but for one still being typed: new, with the caret on its lines. `caret` is
    /// nil if the note has no caret to type with, and `isTyping` says that a key just put it there.
    private func scannedTables(caret: Int? = nil, isTyping: Bool = false) -> [MarkdownStyler.TableSpan] {
        guard TableEdits.mayHoldTable(ns) else {
            isTypingATable = false
            return []
        }
        let known = context.tables
        var stillTyping = false
        var out: [MarkdownStyler.TableSpan] = []
        for span in TableEdits.spans(in: storage.string) {
            if let caret, isTyping || isTypingATable, holdsCaret(span.range, caret),
               !known.contains(where: { $0.range.location == span.range.location }) {
                stillTyping = true
                continue
            }
            let rightToLeft = span.table.statedRightToLeft ?? isLineAboveRightToLeft(span.range.location)
            let height = tableHeight?(span.table, out.count) ?? MarkdownStyler.estimatedTableHeight(span.table)
            out.append(MarkdownStyler.TableSpan(range: span.range, table: span.table, rightToLeft: rightToLeft, height: height))
        }
        isTypingATable = stillTyping
        return out
    }

    /// The caret is on the table's lines: past its last line ending is what follows.
    private func holdsCaret(_ table: NSRange, _ caret: Int) -> Bool {
        let end = NSMaxRange(table)
        guard table.location <= caret, caret <= end else { return false }
        if caret < end { return true }
        let last = end > 0 ? ns.character(at: end - 1) : 0
        return last != 0x0A && last != 0x0D
    }

    /// Whether the list of tables changed since this was last asked, and so the grids have to catch up.
    func takeTablesChange() -> Bool {
        defer { tablesDidChange = false }
        return tablesDidChange
    }

    /// The direction of the nearest line with text above this offset: a new table in a Hebrew note starts on the right.
    private func isLineAboveRightToLeft(_ location: Int) -> Bool {
        var at = location
        for _ in 0..<32 where at > 0 {
            var start = 0, contentsEnd = 0
            ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: at - 1, length: 0))
            let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            if line.contains(where: { !$0.isWhitespace }) { return MarkdownEdits.isRightToLeft(paragraph: line) }
            at = start
        }
        return false
    }

    /// Looks for tables again after an edit, and says which text has to be styled again because of that: what stopped
    /// being a table, what became one, and the first line of one whose grid changed height. A keystroke in a cell is
    /// only its own line.
    private func rescanTables(caret: Int?, isTyping: Bool) -> [NSRange] {
        let old = context.tables
        let fresh = scannedTables(caret: caret, isTyping: isTyping)
        context.tables = fresh
        guard old != fresh else { return [] }
        tablesDidChange = true
        var ranges: [NSRange] = []
        for table in old where !fresh.contains(where: { $0.range.location == table.range.location }) {
            ranges.append(table.range)
        }
        for table in fresh {
            guard let was = old.first(where: { $0.range.location == table.range.location }) else {
                ranges.append(table.range)
                continue
            }
            if was.table.rows.count != table.table.rows.count || was.table.columnCount != table.table.columnCount {
                ranges.append(NSUnionRange(was.range, table.range))
            } else if was.height != table.height {
                ranges.append(NSRange(location: table.range.location, length: 1))
            }
        }
        return ranges
    }

    /// The grids changed size, with no change to the text: their first lines take the new heights. No edit reaches the
    /// file from this.
    func refreshTableHeights() {
        var changed: [NSRange] = []
        for (index, span) in context.tables.enumerated() {
            let height = tableHeight?(span.table, index) ?? span.height
            guard height != span.height else { continue }
            context.tables[index].height = height
            changed.append(NSRange(location: span.range.location, length: 1))
        }
        for range in changed { MarkdownStyler.style(storage, in: range, context: context) }
    }

    func restyleAll() {
        MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length), context: context)
    }

    /// VoiceOver went on or off.
    func setHidesMarks(_ hides: Bool) {
        guard hides != context.hidesMarks else { return }
        context.hidesMarks = hides
        restyleAll()
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: StorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { noteEdit(editedRange, delta: delta) }
    }

    private func noteEdit(_ edited: NSRange, delta: Int) {
        if dirty == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.dirty != nil else { return }
                self.editWentUnannounced?()
            }
        }
        if context.fences.textChanged(edited: edited, delta: delta) { touchedFence = true }
        if let revealed = context.revealed { context.revealed = Self.moved(revealed, edited: edited, delta: delta) }
        for i in context.tables.indices { context.tables[i].range = Self.moved(context.tables[i].range, edited: edited, delta: delta) }
        dirty = dirty.map { Self.moved($0, edited: edited, delta: delta) }.map { NSUnionRange($0, edited) } ?? edited
    }

    /// A range of text after an edit: moved along, and grown to hold the edit if it touches it.
    private static func moved(_ range: NSRange, edited: NSRange, delta: Int) -> NSRange {
        let oldEnd = NSMaxRange(edited) - delta
        if NSMaxRange(range) < edited.location { return range }
        if range.location > oldEnd { return NSRange(location: range.location + delta, length: range.length) }
        let start = min(range.location, edited.location)
        return NSRange(location: start, length: max(NSMaxRange(range) + delta, NSMaxRange(edited)) - start)
    }

    private func wanted(_ selection: NSRange, focused: Bool) -> NSRange? {
        guard focused else { return nil }
        let length = storage.length
        let location = min(selection.location, length)
        return ns.paragraphRange(for: NSRange(location: location, length: min(selection.length, length - location)))
    }

    /// Text changed and hasn't been styled yet. A selection change that arrives now is part of that edit: the text view
    /// isn't done with the text's attributes (UIKit resets the writing direction after this point), so styling waits for
    /// the text-did-change that comes next.
    var isEditPending: Bool { dirty != nil }

    /// The text, the selection or the focus changed. Never call during a composition: its text isn't final.
    func update(selection: NSRange, focused: Bool) {
        let edited = dirty
        dirty = nil
        var all = false
        if let edited, touchedFence || FencedCode.hasFenceLine(ns, in: Self.clamped(edited, to: storage.length)) {
            let fresh = FencedCode(text: ns)
            all = fresh != context.fences
            context.fences = fresh
        }
        touchedFence = false
        let old = context.revealed
        let new = wanted(selection, focused: focused)
        context.revealed = new
        let caret = focused && selection.length == 0 ? selection.location : nil
        // A key at the caret, as against a paste or an undo: those put down a whole table, finished.
        let isTyping = edited.map { $0.length <= 2 && NSMaxRange($0) == selection.location } ?? false
        if all {
            context.tables = scannedTables(caret: caret, isTyping: isTyping)
            tablesDidChange = true
            return restyleAll()
        }
        var ranges: [NSRange] = edited != nil || isTypingATable ? rescanTables(caret: caret, isTyping: isTyping) : []
        // One character more: a line ending typed into a line leaves the rest of it on a new line, with its old look.
        if let edited { ranges.append(NSRange(location: edited.location, length: edited.length + 1)) }
        if context.hidesMarks, old != new {
            if let old { ranges.append(old) }
            if let new { ranges.append(new) }
        }
        for range in Self.merged(ranges, limit: storage.length) {
            MarkdownStyler.style(storage, in: range, context: context)
        }
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    /// Overlapping ranges as one, so that a keystroke styles its paragraph once.
    private static func merged(_ ranges: [NSRange], limit: Int) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.map({ clamped($0, to: limit) }).sorted(by: { $0.location < $1.location }) {
            if let last = out.last, range.location <= NSMaxRange(last) {
                out[out.count - 1] = NSUnionRange(last, range)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// A hidden marker takes no room, so a tap at the start of a line can land in front of it, where what is typed next
    /// would stop the line being a heading or a list item. A direction mark takes none either, and a letter typed in front
    /// of it becomes the line's first strong character, so the line flips and the mark is stranded. A caret arriving from
    /// another line goes behind both instead, and behind a number, which what is typed would break just as well. Once the
    /// line shows its marks, the caret can go anywhere in them.
    func caretBehindMarker(selection: NSRange, focused: Bool) -> Int? {
        guard focused, context.hidesMarks, selection.length == 0, dirty == nil, selection.location < storage.length else { return nil }
        var start = 0, contentsEnd = 0, end = 0
        ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        guard !context.shows(NSRange(location: start, length: end - start)) else { return nil }
        var units = [UInt16](repeating: 0, count: contentsEnd - start)
        ns.getCharacters(&units, range: NSRange(location: start, length: contentsEnd - start))
        let line = MarkdownInline.line(units: units, fence: context.fences.role(ofParagraphAt: start))
        if line.hasBlockMarker, selection.location < start + line.textStart { return start + line.textStart }
        if let mark = line.directionMark, selection.location == start + mark { return start + mark + 1 }
        return nil
    }

    /// Fenced code is only text: a line there that looks like a task is not one.
    func isInCode(_ location: Int) -> Bool {
        context.fences.role(ofParagraphAt: location) != .none
    }

    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let length = storage.length
        guard length > 0 else { return MarkdownStyler.typing }
        let at = min(location, length)
        var start = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
        var units = [UInt16](repeating: 0, count: contentsEnd - start)
        ns.getCharacters(&units, range: NSRange(location: start, length: contentsEnd - start))
        let role = context.fences.role(ofParagraphAt: start)
        let line = MarkdownInline.line(units: units, fence: role)
        return MarkdownStyler.typing(forParagraph: units, role: role, rightToLeft: MarkdownStyler.isRightToLeft(units, line: line, role: role, at: start, in: ns))
    }

    // MARK: finding a checkbox

    /// The task paragraph whose checkbox is at this point in the text container's coordinates, if any: the drawn one,
    /// or the same place on a line that shows its marks.
    func taskParagraph(atContainerPoint point: CGPoint) -> Int? {
        guard let layoutManager, let contentManager = layoutManager.textContentManager else { return nil }
        // By height alone: a fragment's frame hugs its text, and a checkbox is outside that, so asking the layout
        // manager for the fragment at this point finds none. A tap is always in what is laid out on screen.
        var found: MarkdownLayoutFragment?
        let first = layoutManager.textViewportLayoutController.viewportRange?.location ?? contentManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(from: first, options: []) { fragment in
            if fragment.layoutFragmentFrame.minY > point.y { return false }
            if point.y < fragment.layoutFragmentFrame.maxY {
                found = fragment as? MarkdownLayoutFragment
                return false
            }
            return true
        }
        guard let fragment = found else { return nil }
        let start = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        guard start >= 0, start < storage.length, context.fences.role(ofParagraphAt: start) == .none else { return nil }
        var contentsEnd = 0
        var paragraphStart = 0
        ns.getParagraphStart(&paragraphStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        var units = [UInt16](repeating: 0, count: contentsEnd - paragraphStart)
        ns.getCharacters(&units, range: NSRange(location: paragraphStart, length: contentsEnd - paragraphStart))
        let line = MarkdownInline.line(units: units)
        guard case let .task(_, level, _) = line.block else { return nil }
        let rtl = MarkdownStyler.isRightToLeft(units, line: line, role: .none, at: paragraphStart, in: ns)
        let lead = CGFloat(level) * LivePreviewMetrics.levelIndent
        let slot = fragment.markerSlot(lead: lead, rightToLeft: rtl)
            .offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        // On the first line, and a little over the slot on each side. Further out is a margin: a press there starts a
        // selection, and on a nested item it is the line's own indent.
        guard point.y >= slot.minY, point.y < slot.maxY else { return nil }
        let outside: CGFloat = 12, inside: CGFloat = 4
        let from = slot.minX - (rtl ? inside : outside), to = slot.maxX + (rtl ? outside : inside)
        return point.x >= from && point.x <= to ? paragraphStart : nil
    }
}
