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
}

enum LivePreviewMetrics {
    /// One level of a nested list.
    static let levelIndent: CGFloat = 20
    /// The room a checkbox or a bullet takes in front of its text.
    static let markerSlot: CGFloat = 26
    static let quoteIndent: CGFloat = 14
}

private extension PlatformColor {
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
    /// What styling needs from outside the paragraph.
    struct Context {
        var fences = FencedCode()
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
    private final class Palette {
        let body = PlatformFont.preferredFont(forTextStyle: .body)
        lazy var hidden = PlatformFont.systemFont(ofSize: 0.01)
        lazy var code = PlatformFont.monospacedSystemFont(ofSize: body.pointSize * 0.94, weight: .regular)
        private var fonts: [Int: PlatformFont] = [:]

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

        var attributes: [NSAttributedString.Key: Any] {
            var out: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let decoration { out[.bnLineDecoration] = decoration }
            return out
        }
    }

    private static func look(of line: MarkdownInline.Line, role: FencedCode.Role, rightToLeft rtl: Bool, shown: Bool, palette: Palette) -> Look {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.alignment = rtl ? .right : .left
        style.paragraphSpacing = 4
        var font = palette.body
        var color = PlatformColor.bnText
        var decoration: LineDecoration?
        // A line whose text is all hidden marks would otherwise have no height at all.
        var hasHiddenMarker = false

        switch line.block {
        case .plain, .numbered:
            break
        case let .heading(level):
            font = palette.font(level: level)
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
        return Look(font: font, color: color, style: style, decoration: decoration)
    }

    private static func lineHeight(of font: PlatformFont) -> CGFloat {
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
            // Code reads left to right, even inside a Hebrew note.
            let rtl = role == .none && MarkdownEdits.isRightToLeft(paragraph: String(decoding: units, as: UTF16.self))
            let shown = context.shows(enclosing)
            let look = look(of: line, role: role, rightToLeft: rtl, shown: shown, palette: palette)
            storage.setAttributes(look.attributes, range: enclosing)
            applySpans(of: line, units: units, level: level(of: line), to: storage, at: paragraph.location, shown: shown, palette: palette)
        }
        storage.endEditing()
    }

    private static func level(of line: MarkdownInline.Line) -> Int {
        if case let .heading(level) = line.block { return level }
        return 0
    }

    private static func applySpans(of line: MarkdownInline.Line, units: [UInt16], level: Int, to storage: NSTextStorage, at start: Int, shown: Bool, palette: Palette) {
        let length = units.count
        func absolute(_ r: NSRange) -> NSRange { NSRange(location: start + r.location, length: r.length) }
        if case let .numbered(marker) = line.block {
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

    /// Typing attributes for a paragraph: its plain look, so that what is typed next to a mark is neither dim nor hidden,
    /// also during a composition, when nothing is restyled.
    static func typing(forParagraph units: [UInt16], role: FencedCode.Role) -> [NSAttributedString.Key: Any] {
        let line = MarkdownInline.line(units: units, fence: role)
        let rtl = role == .none && MarkdownEdits.isRightToLeft(paragraph: String(decoding: units, as: UTF16.self))
        return look(of: line, role: role, rightToLeft: rtl, shown: true, palette: Palette()).attributes
    }

    /// Typing attributes for an empty note.
    static var typing: [NSAttributedString.Key: Any] { typing(forParagraph: [], role: .none) }
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
        guard decoration != nil else { return super.renderingSurfaceBounds }
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
        restyleAll()
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
        if context.fences.textChanged(edited: edited, delta: delta) { touchedFence = true }
        if let revealed = context.revealed { context.revealed = Self.moved(revealed, edited: edited, delta: delta) }
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
        if all { return restyleAll() }
        var ranges: [NSRange] = []
        if let edited { ranges.append(edited) }
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
    /// would stop the line being a heading or a list item. A caret arriving from another line goes just behind the marker
    /// instead. Once the line shows its marks, the caret can go anywhere in them.
    func caretBehindMarker(selection: NSRange, focused: Bool) -> Int? {
        guard focused, context.hidesMarks, selection.length == 0, dirty == nil, selection.location < storage.length else { return nil }
        var start = 0, contentsEnd = 0, end = 0
        ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        guard !context.shows(NSRange(location: start, length: end - start)) else { return nil }
        var units = [UInt16](repeating: 0, count: contentsEnd - start)
        ns.getCharacters(&units, range: NSRange(location: start, length: contentsEnd - start))
        guard let marker = MarkdownInline.line(units: units, fence: context.fences.role(ofParagraphAt: start)).marker,
              selection.location < start + NSMaxRange(marker) else { return nil }
        return start + NSMaxRange(marker)
    }

    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let length = storage.length
        guard length > 0 else { return MarkdownStyler.typing }
        let at = min(location, length)
        var start = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
        var units = [UInt16](repeating: 0, count: contentsEnd - start)
        ns.getCharacters(&units, range: NSRange(location: start, length: contentsEnd - start))
        return MarkdownStyler.typing(forParagraph: units, role: context.fences.role(ofParagraphAt: start))
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
        guard case let .task(_, level, _) = MarkdownInline.line(units: units).block else { return nil }
        let rtl = MarkdownEdits.isRightToLeft(paragraph: String(decoding: units, as: UTF16.self))
        let lead = CGFloat(level) * LivePreviewMetrics.levelIndent
        let slot = fragment.markerSlot(lead: lead, rightToLeft: rtl)
            .offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        // On the first line, from the edge of the view on the outside to a little over the slot on the inside.
        guard point.y >= slot.minY, point.y < slot.maxY else { return nil }
        return (rtl ? point.x >= slot.minX - 4 : point.x <= slot.maxX + 4) ? paragraphStart : nil
    }
}
