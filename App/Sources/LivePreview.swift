import BrainNotesKit
import Foundation
import QuartzCore

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
    /// An external or relative Markdown link's destination URL/path.
    static let bnExternalLink = NSAttributedString.Key("bnExternalLink")
    /// What `MarkdownLayoutFragment` draws for this paragraph, instead of the marks it stands for.
    static let bnLineDecoration = NSAttributedString.Key("bnLineDecoration")
}

/// One paragraph's drawn part. An attribute, so the storage's text stays the file's.
final class LineDecoration: NSObject {
    enum Kind: Equatable {
        case checkbox(done: Bool)
        case bullet
        case dashed
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

    static func bnHighlightFill(_ color: HighlightColor) -> PlatformColor {
        switch color {
        case .mint: PlatformColor(red: 0.16, green: 0.82, blue: 0.72, alpha: 0.28)
        case .purple: PlatformColor(red: 0.68, green: 0.34, blue: 0.92, alpha: 0.28)
        case .pink: PlatformColor(red: 0.98, green: 0.25, blue: 0.58, alpha: 0.28)
        case .orange: PlatformColor(red: 1.00, green: 0.56, blue: 0.12, alpha: 0.28)
        case .amber: PlatformColor(red: 0.96, green: 0.76, blue: 0.16, alpha: 0.28)
        }
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
        /// Tracked for caret changes; syntax marks stay hidden whenever `hidesMarks` is on (Apple Notes WYSIWYG).
        var revealed: NSRange?
        /// Off while VoiceOver runs: what it reads and where the caret stops are then what is on screen.
        var hidesMarks = true

        func shows(_ paragraph: NSRange) -> Bool {
            !hidesMarks
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

        func codeFont(bold: Bool, italic: Bool, hebrew: Bool) -> PlatformFont {
            let base = PlatformFont.monospacedSystemFont(ofSize: body.pointSize * 0.94, weight: bold ? .bold : .regular)
            guard italic else { return base }
            if hebrew {
                #if os(iOS)
                let skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                return UIFont(descriptor: base.fontDescriptor.addingAttributes([.matrix: skew]), size: 0)
                #else
                let skew = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
                return NSFont(descriptor: base.fontDescriptor.addingAttributes([.matrix: skew]), size: 0) ?? base
                #endif
            }
            return Self.with(base, bold: false, italic: true)
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
            if line.plainIndentLevel > 0 {
                let lead = CGFloat(line.plainIndentLevel) * LivePreviewMetrics.levelIndent
                style.headIndent = lead
                if !shown {
                    style.firstLineHeadIndent = lead
                    hasHiddenMarker = true
                }
            }
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
                decoration = LineDecoration(kind: line.isDashedBullet ? .dashed : .bullet, rightToLeft: rtl, lead: lead)
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
        case .fence:
            font = palette.code
            style.paragraphSpacing = 0
            let kind: LineDecoration.Kind = role == .opening ? .codeFirst : role == .closing ? .codeLast : .codeMiddle
            decoration = LineDecoration(kind: kind, rightToLeft: false, lead: 0)
            if !shown {
                style.minimumLineHeight = 8
                style.maximumLineHeight = 8
            }
        case .code:
            font = palette.code
            style.paragraphSpacing = 0
            decoration = LineDecoration(kind: .codeMiddle, rightToLeft: rtl, lead: 0)
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
            let mono = context.fences.isMonostyled(at: paragraph.location)
            let line = MarkdownInline.line(units: units, fence: role, monostyled: mono)
            let rtl = isRightToLeft(units, line: line, role: role, monostyled: mono, at: paragraph.location, in: ns)
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

    /// A paragraph's direction. Tagged code reads left to right, even inside a Hebrew note; bare Monostyled blocks follow
    /// natural direction like Apple Notes. A list item with no text yet takes the direction of the item above it.
    static func isRightToLeft(_ units: [UInt16], line: MarkdownInline.Line, role: FencedCode.Role, monostyled: Bool = false, at start: Int, in ns: NSString) -> Bool {
        guard role == .none || (role == .inside && monostyled) else { return false }
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
                case .underline:
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                case .highlight, .code, .wikiLink, .link, .bareURL:
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
                        let font: PlatformFont
                        if line.block == .code {
                            font = palette.codeFont(bold: t & 1 != 0, italic: t & 2 != 0, hebrew: hebrew)
                        } else {
                            font = hebrew ? palette.slanted(level: level, bold: t & 1 != 0) : palette.font(level: level, bold: t & 1 != 0, italic: t & 2 != 0)
                        }
                        storage.addAttribute(.font, value: font, range: NSRange(location: start + i, length: j - i))
                    }
                    i = j
                }
            }
            for span in line.spans {
                let content = absolute(span.content)
                switch span.kind {
                case let .highlight(color):
                    storage.addAttribute(.backgroundColor, value: PlatformColor.bnHighlightFill(color), range: content)
                case .code:
                    storage.addAttributes([.font: palette.code, .backgroundColor: PlatformColor.bnCodeFill], range: content)
                case let .wikiLink(target):
                    storage.addAttributes([
                        .foregroundColor: PlatformColor.bnAccent,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .bnWikiTarget: target,
                    ], range: content)
                case let .link(url):
                    storage.addAttributes([
                        .foregroundColor: PlatformColor.bnAccent,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .bnExternalLink: url,
                    ], range: content)
                case .bareURL:
                    let urlText = String(decoding: units[span.content.location..<NSMaxRange(span.content)], as: UTF16.self)
                    storage.addAttributes([
                        .foregroundColor: PlatformColor.bnAccent,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .bnExternalLink: urlText,
                    ], range: content)
                case .bold, .italic, .strikethrough, .underline:
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
    static func typing(forParagraph units: [UInt16], role: FencedCode.Role, monostyled: Bool = false, rightToLeft: Bool, shown: Bool = false) -> [NSAttributedString.Key: Any] {
        let line = MarkdownInline.line(units: units, fence: role, monostyled: monostyled)
        return look(of: line, units: units, role: role, rightToLeft: rightToLeft, shown: shown, palette: Palette()).attributes
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
        case .dashed:
            let slot = markerSlot(lead: decoration.lead, rightToLeft: decoration.rightToLeft)
            let center = glyphCenter(in: slot, rightToLeft: decoration.rightToLeft, inset: 12)
            context.setFillColor(PlatformColor.bnSecondary.cgColor)
            context.fill(CGRect(x: center.x - 4, y: center.y - 0.8, width: 8, height: 1.6))
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
    /// Last settled caret offset so arrowing across hidden inline delimiters snaps in the direction of travel.
    private var previousCaret: Int?
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
        defer { previousCaret = caret }
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
        if !context.hidesMarks, old != new {
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

    /// Keeps the caret out of zero-width hidden block prefixes, direction marks, collapsed fence lines, and multi-byte
    /// hidden inline delimiters (`**`, `~~`, `<u>`, `<mark...>`, `[[...]]`, `](...)`) whenever `hidesMarks` is active.
    func caretBehindMarker(selection: NSRange, focused: Bool) -> Int? {
        guard focused, context.hidesMarks, selection.length == 0, dirty == nil, selection.location < storage.length else { return nil }
        var start = 0, contentsEnd = 0, end = 0
        ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        guard !context.shows(NSRange(location: start, length: end - start)) else { return nil }
        let role = context.fences.role(ofParagraphAt: start)
        let movingLeft = previousCaret.map { $0 > selection.location } ?? false
        if role == .opening {
            if movingLeft, start > 0 { return start - 1 }
            if end < storage.length { return end }
        } else if role == .closing {
            if movingLeft, start > 0 { return start - 1 }
            if end <= storage.length, selection.location < contentsEnd { return min(storage.length, end) }
        }
        var units = [UInt16](repeating: 0, count: contentsEnd - start)
        ns.getCharacters(&units, range: NSRange(location: start, length: contentsEnd - start))
        let mono = context.fences.isMonostyled(at: start)
        let line = MarkdownInline.line(units: units, fence: role, monostyled: mono)
        if line.hasBlockMarker, selection.location < start + line.textStart { return start + line.textStart }
        if let mark = line.directionMark, selection.location == start + mark { return start + mark + 1 }
        let rel = selection.location - start
        for span in line.spans {
            if span.open.length > 0, span.open.location < rel, rel < NSMaxRange(span.open) {
                return start + (movingLeft ? span.open.location : NSMaxRange(span.open))
            }
            if span.close.length > 0, span.close.location < rel, rel < NSMaxRange(span.close) {
                return start + (movingLeft ? span.close.location : NSMaxRange(span.close))
            }
        }
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
        let mono = context.fences.isMonostyled(at: start)
        let line = MarkdownInline.line(units: units, fence: role, monostyled: mono)
        return MarkdownStyler.typing(
            forParagraph: units,
            role: role,
            monostyled: mono,
            rightToLeft: MarkdownStyler.isRightToLeft(units, line: line, role: role, monostyled: mono, at: start, in: ns),
            shown: !context.hidesMarks
        )
    }

    // MARK: finding a checkbox or link

    /// Hit-tests rendered link text at a point in the text container's coordinates, returning nil in margins or trailing whitespace.
    func linkMatch(atContainerPoint point: CGPoint) -> MarkdownEdits.LinkMatch? {
        guard let layoutManager, let contentManager = layoutManager.textContentManager else { return nil }
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
        guard start >= 0, start < storage.length, context.fences.allowsInlineFormatting(at: start) else { return nil }
        let local = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
        guard let lineFrag = fragment.textLineFragments.first(where: { $0.typographicBounds.insetBy(dx: -2, dy: -3).contains(local) }),
              local.x >= lineFrag.typographicBounds.minX - 2,
              local.x <= lineFrag.typographicBounds.maxX + 2 else {
            return nil
        }
        let linePoint = CGPoint(x: local.x - lineFrag.typographicBounds.minX, y: local.y - lineFrag.typographicBounds.minY)
        let charIndex = lineFrag.characterIndex(for: linePoint)
        let docOffset = min(storage.length, max(0, start + charIndex))
        guard let match = MarkdownEdits.activeFormat(in: storage.string, selection: NSRange(location: docOffset, length: 0)).link,
              docOffset >= match.wholeRange.location,
              docOffset < NSMaxRange(match.wholeRange) else {
            return nil
        }
        return match
    }

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

    /// Exact checkbox circle frame in text-container coordinates and its current `done` state, for press & tick micro-animations.
    func checkboxCircleRect(forParagraphAt location: Int) -> (rect: CGRect, done: Bool)? {
        guard let layoutManager, let contentManager = layoutManager.textContentManager else { return nil }
        guard location >= 0, location <= storage.length, context.fences.role(ofParagraphAt: location) == .none else { return nil }
        var paragraphStart = 0
        var contentsEnd = 0
        ns.getParagraphStart(&paragraphStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(location, storage.length), length: 0))
        var units = [UInt16](repeating: 0, count: contentsEnd - paragraphStart)
        ns.getCharacters(&units, range: NSRange(location: paragraphStart, length: contentsEnd - paragraphStart))
        let line = MarkdownInline.line(units: units)
        guard case let .task(done, level, _) = line.block else { return nil }
        guard let docLoc = contentManager.location(contentManager.documentRange.location, offsetBy: paragraphStart),
              let fragment = layoutManager.textLayoutFragment(for: docLoc) as? MarkdownLayoutFragment else { return nil }
        let rtl = MarkdownStyler.isRightToLeft(units, line: line, role: .none, at: paragraphStart, in: ns)
        let lead = CGFloat(level) * LivePreviewMetrics.levelIndent
        let slot = fragment.markerSlot(lead: lead, rightToLeft: rtl)
            .offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        let size = ceil(PlatformFont.preferredFont(forTextStyle: .body).pointSize * 1.05)
        let inset = size / 2 + 6
        let center = CGPoint(x: rtl ? slot.minX + inset : slot.maxX - inset, y: slot.midY)
        let circle = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        return (circle, done)
    }
}

// MARK: - Apple Notes Checkbox Press & Stroke-Draw Micro-Animation

#if os(iOS)
typealias CheckboxHostBaseView = UIView
#else
typealias CheckboxHostBaseView = NSView
#endif

/// Transient, non-interactive vector overlay rendered over a task's checkbox circle during press-down and tick/untick.
/// Driven at native ProMotion frame rate via `CADisplayLink` without mutating `NSTextStorage` or invalidating TextKit 2 fragments.
@MainActor
final class CheckboxOverlayView: CheckboxHostBaseView {
    enum Mode {
        case pressed(done: Bool)
        case checking
        case unchecking
    }

    private let circleSize: CGFloat
    private let backdropColor: PlatformColor
    private var mode: Mode
    private var startTime: CFTimeInterval = 0
    private var progress: CGFloat = 0
    private var displayLink: CADisplayLink?

    @MainActor
    private final class LinkProxy: NSObject {
        weak var owner: CheckboxOverlayView?
        init(_ owner: CheckboxOverlayView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            owner?.step()
        }
    }

    init(circleRectInView: CGRect, backdropColor: PlatformColor, mode: Mode) {
        self.circleSize = circleRectInView.width
        self.backdropColor = backdropColor
        self.mode = mode
        super.init(frame: circleRectInView.insetBy(dx: -5, dy: -5))
        #if os(iOS)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        #else
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        #endif

        switch mode {
        case .pressed:
            break
        case .checking, .unchecking:
            startAnimation()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    func transitionToToggle(nowDone: Bool) {
        stopDisplayLink()
        mode = nowDone ? .checking : .unchecking
        startAnimation()
    }

    func dismissImmediately() {
        stopDisplayLink()
        removeFromSuperview()
    }

    private var duration: CFTimeInterval {
        switch mode {
        case .pressed: 0
        case .checking: 0.24
        case .unchecking: 0.15
        }
    }

    private func startAnimation() {
        startTime = CACurrentMediaTime()
        progress = 0
        let proxy = LinkProxy(self)
        #if os(iOS)
        let link = CADisplayLink(target: proxy, selector: #selector(LinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsDisplay()
        #else
        let link = self.displayLink(target: proxy, selector: #selector(LinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        needsDisplay = true
        #endif
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func step() {
        guard duration > 0 else { return }
        let elapsed = CACurrentMediaTime() - startTime
        if elapsed >= duration {
            stopDisplayLink()
            removeFromSuperview()
            return
        }
        progress = CGFloat(min(max(elapsed / duration, 0), 1))
        #if os(iOS)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }

    override func draw(_ rect: CGRect) {
        #if os(iOS)
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        #else
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        #endif

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maskSize = circleSize + 4
        ctx.setFillColor(backdropColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - maskSize / 2, y: center.y - maskSize / 2, width: maskSize, height: maskSize))

        switch mode {
        case let .pressed(done):
            let s = circleSize * 0.94
            let circle = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            if done {
                ctx.setFillColor(PlatformColor.bnAccent.withAlphaComponent(0.78).cgColor)
                ctx.fillEllipse(in: circle)
                drawCheckmark(in: ctx, center: center, size: s, fraction: 1.0)
            } else {
                ctx.setFillColor(PlatformColor.bnAccent.withAlphaComponent(0.24).cgColor)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(PlatformColor.bnAccent.withAlphaComponent(0.92).cgColor)
                ctx.setLineWidth(1.35)
                ctx.strokeEllipse(in: circle.insetBy(dx: 0.65, dy: 0.65))
            }

        case .checking:
            let p = progress
            let scale: CGFloat
            if p < 0.44 {
                let u = p / 0.44
                let eased = 1 - pow(1 - u, 3)
                scale = 0.88 + 0.18 * eased
            } else {
                let u = (p - 0.44) / 0.56
                let eased = 1 - pow(1 - u, 2)
                scale = 1.06 - 0.06 * eased
            }
            let s = circleSize * scale
            let circle = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            let fillAlpha = min(1, 0.36 + 0.64 * (p / 0.28))
            ctx.setFillColor(PlatformColor.bnAccent.withAlphaComponent(fillAlpha).cgColor)
            ctx.fillEllipse(in: circle)

            if p > 0.15 {
                let rawStroke = min(max((p - 0.15) / 0.85, 0), 1)
                let drawFraction = 1 - pow(1 - rawStroke, 2.6)
                drawCheckmark(in: ctx, center: center, size: s, fraction: drawFraction)
            }

        case .unchecking:
            let p = progress
            let baseCircle = CGRect(x: center.x - circleSize / 2, y: center.y - circleSize / 2, width: circleSize, height: circleSize)
            ctx.setStrokeColor(PlatformColor.bnSecondary.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: baseCircle.insetBy(dx: 0.6, dy: 0.6))

            let fade = pow(1 - p, 2)
            let shrink = circleSize * (1 - 0.16 * p)
            let shrinkingCircle = CGRect(x: center.x - shrink / 2, y: center.y - shrink / 2, width: shrink, height: shrink)
            ctx.setFillColor(PlatformColor.bnAccent.withAlphaComponent(fade).cgColor)
            ctx.fillEllipse(in: shrinkingCircle)
        }
    }

    private func drawCheckmark(in ctx: CGContext, center: CGPoint, size: CGFloat, fraction: CGFloat) {
        guard fraction > 0.001 else { return }
        let p0 = CGPoint(x: center.x - size * 0.24, y: center.y + size * 0.02)
        let p1 = CGPoint(x: center.x - size * 0.06, y: center.y + size * 0.20)
        let p2 = CGPoint(x: center.x + size * 0.26, y: center.y - size * 0.20)
        let seg1Len = hypot(p1.x - p0.x, p1.y - p0.y)
        let seg2Len = hypot(p2.x - p1.x, p2.y - p1.y)
        let split = seg1Len / (seg1Len + seg2Len)

        ctx.setStrokeColor(PlatformColor.white.cgColor)
        ctx.setLineWidth(max(1.5, size * 0.11))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: p0)

        if fraction <= split {
            let t = fraction / split
            ctx.addLine(to: CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
        } else {
            ctx.addLine(to: p1)
            let t = min(1, (fraction - split) / (1 - split))
            ctx.addLine(to: CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t))
        }
        ctx.strokePath()
    }
}
