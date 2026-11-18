import BrainMerge
import Foundation

/// Derived views of a note's text. Nothing here changes bytes: the frontmatter prefix plus the body
/// is always exactly the original text.
public enum NoteText {
    /// The frontmatter block (with its closing line) and the rest, using the merge spec's rule (2.1).
    public static func split(_ text: String) -> (frontmatter: String, body: String) {
        guard text.utf8.starts(with: "---".utf8), let first = splitBlocks(text).first, first.key.utf8.elementsEqual("fm".utf8) else {
            return ("", text)
        }
        let prefix = first.lines.joined()
        let body = String(decoding: Array(text.utf8.dropFirst(prefix.utf8.count)), as: UTF8.self)
        return (prefix, body)
    }

    /// A `key: value` from frontmatter, unquoted. Lines are the merge spec's lines (split after "\n" only):
    /// Swift's `isNewline` also breaks on U+2028, U+2029, NEL and a lone CR, which `yamlStr` leaves inside a
    /// quoted value, so a conflict copy of `notes/a<U+2028>b.md` read back as `conflict_of: "notes/a`.
    public static func frontmatterValue(_ frontmatter: String, key: String) -> String? {
        let prefix = Array((key + ":").utf8)
        for line in lines(frontmatter) {
            guard line.utf8.starts(with: prefix) else { continue }
            let trimmed = String(decoding: line.utf8.dropFirst(prefix.count), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            // Quotes are stripped as bytes: `"` followed by a combining mark is one Character to Swift.
            var v = Array(trimmed.utf8)
            if v.count >= 2, let f = v.first, f == v.last, f == UInt8(ascii: "\"") || f == UInt8(ascii: "'") {
                v = Array(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : String(decoding: v, as: UTF8.self)
        }
        return nil
    }

    /// `type: conflict` in the header (merge spec 6.1).
    public static func isConflictCopy(_ text: String) -> Bool {
        let (fm, _) = split(text)
        return !fm.isEmpty && frontmatterValue(fm, key: "type") == "conflict"
    }

    /// `pinned: true` in YAML frontmatter, synced across iPhone and Mac via Git.
    public static func isPinned(_ text: String) -> Bool {
        let (fm, _) = split(text)
        guard !fm.isEmpty, let raw = frontmatterValue(fm, key: "pinned")?.lowercased() else { return false }
        return raw == "true" || raw == "yes" || raw == "1"
    }

    /// Sets or clears `pinned: true` in YAML frontmatter, removing the frontmatter block completely if empty.
    public static func settingPinned(_ pinned: Bool, in text: String) -> String {
        if isPinned(text) == pinned { return text }
        let rawEnding = MarkdownEdits.lineEnding(in: text, at: 0)
        let ending = rawEnding == "\r\n" ? "\r\n" : "\n"
        let (fm, body) = split(text)
        if fm.isEmpty {
            guard pinned else { return text }
            return "---" + ending + "pinned: true" + ending + "---" + ending + body
        }
        var rawLines = lines(fm)
        // First and last lines are the opening and closing `---` delimiters.
        guard rawLines.count >= 2 else {
            return pinned ? ("---" + ending + "pinned: true" + ending + "---" + ending + body) : body
        }
        let openFence = rawLines.removeFirst()
        let closeFence = rawLines.removeLast()
        rawLines.removeAll { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return trimmed.hasPrefix("pinned:")
        }
        if pinned {
            rawLines.append("pinned: true")
        }
        if rawLines.isEmpty {
            return body
        }
        let rebuilt = ([openFence] + rawLines + [closeFence]).joined(separator: ending) + ending
        return rebuilt + body
    }

    /// Clean human-readable note text for sharing (Messages, Mail, Copy) without raw Markdown syntax.
    public static func cleanShareText(_ text: String) -> String {
        let (_, body) = split(text)
        var out: [String] = []
        var inFence = false
        for rawLine in lines(body) {
            let trimmed = rawLine.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(rawLine)
                continue
            }
            if let tableLine = parsePipeTableLine(String(trimmed)) {
                if !tableLine.isEmpty {
                    out.append(tableLine)
                }
                continue
            }
            let indentCount = (rawLine.count - trimmed.count) / 2
            let pad = String(repeating: "  ", count: indentCount)
            var content = String(trimmed)
            var prefix = ""
            if content.hasPrefix("- [ ] ") || content.hasPrefix("* [ ] ") {
                prefix = pad + "○ "
                content = String(content.dropFirst(6))
            } else if content.hasPrefix("- [x] ") || content.hasPrefix("- [X] ") || content.hasPrefix("* [x] ") {
                prefix = pad + "✓ "
                content = String(content.dropFirst(6))
            } else if content.hasPrefix("+ ") {
                prefix = pad + "– "
                content = String(content.dropFirst(2))
            } else if content.hasPrefix("- ") || content.hasPrefix("* ") {
                prefix = pad + "• "
                content = String(content.dropFirst(2))
            } else if content.hasPrefix("> ") {
                prefix = "▎ "
                content = String(content.dropFirst(2))
            } else if content == ">" {
                prefix = "▎"
                content = ""
            } else {
                var hashes = 0
                for c in content {
                    if c == "#" { hashes += 1 } else { break }
                }
                if (1...6).contains(hashes), content.dropFirst(hashes).first == " " {
                    content = String(content.dropFirst(hashes + 1))
                }
            }
            let plain = stripStrayFormattingTags(MarkdownInline.plainText(content))
            out.append(prefix + plain)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Title: frontmatter `title`, else the first non-empty body line without heading marks, else the file name.
    public static func title(of text: String, path: String) -> String {
        let (fm, body) = split(text)
        if !fm.isEmpty, let t = frontmatterValue(fm, key: "title") { return String(t.prefix(120)) }
        for line in body.split(whereSeparator: \.isNewline) {
            let t = stripMarks(String(line))
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return fileStem(path)
    }

    public static func fileStem(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.count > 3 && name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// Text for list rows and search: the body after the title line, without Markdown marks.
    static func snippet(of text: String, title: String) -> String {
        let (_, body) = split(text)
        var pieces: [String] = []
        var length = 0
        var skippedTitle = false
        for line in body.split(whereSeparator: \.isNewline) {
            let t = stripMarks(String(line))
            if t.isEmpty { continue }
            if !skippedTitle {
                skippedTitle = true
                if t.hasPrefix(title) || title.hasPrefix(t) { continue }
            }
            pieces.append(t)
            length += t.count + 1
            if length > 200 { break }
        }
        return String(pieces.joined(separator: " ").prefix(240))
    }

    /// The body as search sees it and snippets show it: no frontmatter, no title line (the title has its
    /// own column), no Markdown marks. Line breaks stay, so a snippet doesn't run words together.
    static func searchableBody(of text: String, title: String) -> String {
        let (_, body) = split(text)
        var lines: [String] = []
        var skippedTitle = false
        for line in body.split(whereSeparator: \.isNewline) {
            let t = stripMarks(String(line))
            if t.isEmpty { continue }
            if !skippedTitle {
                skippedTitle = true
                if t.hasPrefix(title) || title.hasPrefix(t) { continue }
            }
            lines.append(t)
        }
        return lines.joined(separator: "\n")
    }

    /// One line without leading heading, list, quote and task marks and without emphasis marks.
    static func stripMarks(_ line: String) -> String {
        let cleaned = stripStrayFormattingTags(line)
        if let tableLine = parsePipeTableLine(cleaned) {
            return tableLine
        }
        var t = Substring(cleaned).drop(while: \.isWhitespace)
        while let f = t.first, f == "#" { t = t.dropFirst() }
        t = t.drop(while: \.isWhitespace)
        for mark in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> "] where t.hasPrefix(mark) {
            t = t.dropFirst(mark.count)
            break
        }
        // A heading inside a list item.
        let hashes = t.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), t.dropFirst(hashes.count).first == " " { t = t.dropFirst(hashes.count).drop(while: \.isWhitespace) }
        var s = String(t)
        if s == "---" || s == "***" || s == "```" { return "" }
        s = stripStrayFormattingTags(MarkdownInline.plainText(s))
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Parses a GFM pipe table row or delimiter line into clean space-separated cell words (or `""` for delimiter / empty rows).
    /// Returns `nil` when `line` is ordinary prose rather than a pipe table row.
    static func parsePipeTableLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        let isDelimiterOrBlankPipes = trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " || $0 == "\t" }
        if isDelimiterOrBlankPipes {
            return ""
        }
        guard trimmed.hasPrefix("|") || trimmed.hasSuffix("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
                current.append(ch)
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current)
        if trimmed.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        let cleanedCells = cells.compactMap { rawCell -> String? in
            let unescaped = rawCell.replacingOccurrences(of: "\\|", with: "|")
            let plain = stripStrayFormattingTags(MarkdownInline.plainText(unescaped)).trimmingCharacters(in: .whitespaces)
            return plain.isEmpty ? nil : plain
        }
        return cleanedCells.joined(separator: " ")
    }

    private static func stripStrayFormattingTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = s
        for tag in ["<u>", "</u>", "<mark>", "</mark>"] {
            out = out.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        for color in HighlightColor.allCases {
            out = out.replacingOccurrences(of: "<mark data-color=\"\(color.rawValue)\">", with: "", options: .caseInsensitive)
        }
        return out
    }

    /// Lines without their endings, for display. Works on bytes: to Swift and Foundation a CRLF is one
    /// character, so splitting on "\n" as text can miss it.
    public static func lines(_ text: String) -> [String] {
        var out = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { piece -> String in
            let bytes = piece.last == 0x0D ? piece.dropLast() : piece
            return String(decoding: bytes, as: UTF8.self)
        }
        if out.last?.utf8.isEmpty == true { out.removeLast() }
        return out
    }

    public static func firstLine(of text: String) -> String {
        let (_, body) = split(text)
        for line in body.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            return String(line)
        }
        return ""
    }

    // MARK: direction

    /// Unicode bidi rule P2: the paragraph direction is that of its first strong character.
    public static func isRightToLeft(_ s: some StringProtocol) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x200F: return true // RLM
            case 0x200E: return false // LRM
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                if u.properties.isAlphabetic || u.properties.generalCategory == .otherLetter { return true }
            default:
                if u.properties.isAlphabetic { return false }
            }
        }
        return false
    }

    // MARK: search folding

    /// Hebrew points and cantillation marks removed. FTS5's unicode61 tokenizer treats them as separators,
    /// so "שָׁלוֹם" would otherwise index as fragments and never match "שלום".
    public static func foldForSearch(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isHebrewMark) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where !isHebrewMark(u) { out.append(u) }
        return String(out)
    }

    private static func isHebrewMark(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0591...0x05BD, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7: return true
        default: return false
        }
    }

    /// Hebrew attaches "the", "and", "in", "to", "from", "that", "like" to the word, so "הגרגירים" should
    /// be found by "גרגירים". This lists each Hebrew word without one or two such letters, for a hidden
    /// index column; the visible text is never changed.
    static func hebrewStems(_ text: String) -> String {
        let particles: Set<Unicode.Scalar> = ["ו", "ה", "ב", "כ", "ל", "מ", "ש"]
        var out: [String] = []
        var word: [Unicode.Scalar] = []
        func flush() {
            defer { word.removeAll(keepingCapacity: true) }
            var rest = word[...]
            for _ in 0..<2 {
                guard let first = rest.first, particles.contains(first), rest.count > 2 else { return }
                rest = rest.dropFirst()
                var s = String.UnicodeScalarView()
                s.append(contentsOf: rest)
                out.append(String(s))
            }
        }
        for u in text.unicodeScalars {
            if (0x05D0...0x05EA).contains(u.value) {
                word.append(u)
            } else if !word.isEmpty {
                flush()
            }
        }
        if !word.isEmpty { flush() }
        return out.joined(separator: " ")
    }
}

#if canImport(Darwin)
// Foundation's Markdown parser is not part of swift-corelibs-foundation. Only the app's views use this.
extension NoteText {
    /// One block of inline Markdown for display. Raw HTML stays literal text (never interpreted), and only
    /// http and https links stay tappable; any other scheme (javascript, file, shortcuts) shows as plain text.
    public static func inlineMarkdown(_ text: String) -> AttributedString {
        let escaped = closingOpenBold(text).replacingOccurrences(of: "<", with: "\\<")
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var out = try? AttributedString(markdown: escaped, options: options) else { return AttributedString(text) }
        for run in out.runs {
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                out[run.range].link = nil
            }
        }
        return out
    }

    /// `**a` on a line of its own reads as bold in the editor (`MarkdownInline`), so it does here. Foundation's parser
    /// pairs marks across lines, so a paragraph of several lines is left to it. For display only.
    private static func closingOpenBold(_ text: String) -> String {
        guard !text.contains(where: \.isNewline), MarkdownInline.line(text).spans.contains(where: { $0.kind == .bold && $0.close.length == 0 }) else { return text }
        let trimmed = text.prefix(through: text.lastIndex { !$0.isWhitespace } ?? text.startIndex)
        return trimmed + "**"
    }
}
#endif

/// A conflict copy: the merge spec's header (6.1) followed by mine, exactly as it was.
public struct ConflictCopy: Sendable, Equatable {
    public var conflictOf: String?
    public var device: String?
    public var created: String?
    public var mine: String

    public init?(text: String) {
        let (fm, body) = NoteText.split(text)
        guard !fm.isEmpty, NoteText.frontmatterValue(fm, key: "type") == "conflict" else { return nil }
        conflictOf = NoteText.frontmatterValue(fm, key: "conflict_of").map(Self.unescape)
        device = NoteText.frontmatterValue(fm, key: "device").map(Self.unescape)
        created = NoteText.frontmatterValue(fm, key: "created")
        mine = body
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

/// Markdown blocks for the note view: line based, tolerant, never fails. Edit mode shows the source.
public struct MarkdownBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case heading(Int)
        case paragraph
        case bullet(indent: Int)
        case task(done: Bool, indent: Int)
        case numbered(marker: String, indent: Int)
        case quote
        case code
        case rule
        /// A GFM pipe table, as `BrainNotesTables` reads it.
        case table(MarkdownTable)
    }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var isRightToLeft: Bool
    /// A heading inside a list item or a quote, as in `- [ ] # a`: its level. `text` is then without its marker.
    public var innerHeadingLevel: Int?

    public static func parse(_ body: String) -> [MarkdownBlock] {
        let doc = TableDocument(parsing: body)
        var out: [MarkdownBlock] = []
        for piece in doc.pieces {
            switch piece {
            case .table(let table):
                out.append(MarkdownBlock(
                    id: out.count,
                    kind: .table(table),
                    text: table.markdown,
                    isRightToLeft: table.isRightToLeft
                ))
            case .text(let text):
                for block in parseText(text) {
                    out.append(MarkdownBlock(
                        id: out.count,
                        kind: block.kind,
                        text: block.text,
                        isRightToLeft: block.isRightToLeft,
                        innerHeadingLevel: block.innerHeadingLevel
                    ))
                }
            }
        }
        return out
    }

    /// Everything that is not a GFM table: the original line-by-line reader.
    private static func parseText(_ body: String) -> [MarkdownBlock] {

        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?

        func add(_ kind: Kind, _ text: String) {
            out.append(MarkdownBlock(id: out.count, kind: kind, text: text, isRightToLeft: NoteText.isRightToLeft(text)))
        }
        /// What a list item or a quote holds, which can start with a heading.
        func addItem(_ kind: Kind, _ text: String) {
            let marks = text.prefix { $0 == "\u{200F}" || $0 == "\u{200E}" }
            let rest = text.dropFirst(marks.count)
            guard let level = headingLevel(rest), rest.dropFirst(level).first != nil else { return add(kind, text) }
            let inner = marks + rest.dropFirst(level).drop { $0 == " " || $0 == "\t" }
            out.append(MarkdownBlock(id: out.count, kind: kind, text: String(inner), isRightToLeft: NoteText.isRightToLeft(inner), innerHeadingLevel: level))
        }
        func flushParagraph() {
            if !paragraph.isEmpty { add(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] }
        }

        for line in NoteText.lines(body) {
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count

            if let open = fence {
                if trimmed.hasPrefix(open) {
                    add(.code, code.joined(separator: "\n")); code = []; fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if indent <= 3, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                continue
            }
            if trimmed.isEmpty { flushParagraph(); continue }
            if indent <= 3, let level = headingLevel(trimmed) {
                flushParagraph()
                add(.heading(level), String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                continue
            }
            if indent <= 3, trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                add(.rule, "")
                continue
            }
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") {
                flushParagraph()
                addItem(.task(done: false, indent: indent / 2), String(trimmed.dropFirst(6)))
                continue
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") || trimmed.hasPrefix("* [x] ") {
                flushParagraph()
                addItem(.task(done: true, indent: indent / 2), String(trimmed.dropFirst(6)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                addItem(.bullet(indent: indent / 2), String(trimmed.dropFirst(2)))
                continue
            }
            if let marker = numberedMarker(trimmed) {
                flushParagraph()
                addItem(.numbered(marker: marker, indent: (indent + 2) / 3), String(trimmed.dropFirst(marker.count + 1)))
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                addItem(.quote, String(trimmed.dropFirst(trimmed == ">" ? 1 : 2)))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        if fence != nil, !code.isEmpty { add(.code, code.joined(separator: "\n")) }
        return out
    }

    private static func headingLevel(_ s: Substring) -> Int? {
        var n = 0
        for c in s {
            if c == "#" { n += 1 } else { break }
        }
        guard n >= 1, n <= 6 else { return nil }
        let rest = s.dropFirst(n)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" ? n : nil
    }

    /// "12." -> "12.", when followed by a space.
    private static func numberedMarker(_ s: Substring) -> String? {
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(digits) + String(rest.prefix(1))
    }
}

/// Folder tree for the home screen, built from the visible paths.
public struct FolderNode: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    /// Notes directly in this folder.
    public var ownCount: Int
    /// Notes here and in every subfolder.
    public var totalCount: Int
    public var children: [FolderNode]

    /// `children` for `OutlineGroup` and `List(children:)`: nil for a leaf, so no disclosure arrow.
    public var childrenOrNil: [FolderNode]? { children.isEmpty ? nil : children }

    /// `emptyFolders`: folders with nothing in them yet (`FileStore.emptyFolders`), which no note's path can show.
    public static func tree(paths: [String], emptyFolders: [String] = []) -> [FolderNode] {
        final class Box {
            var name: String, path: String, own = 0, total = 0
            var kids: [PathKey: Box] = [:]
            init(name: String, path: String) { self.name = name; self.path = path }
        }
        let root = Box(name: "", path: "")
        func walk(_ folders: ArraySlice<String>, counting: Bool) -> Box {
            var node = root
            var prefix = ""
            for seg in folders {
                prefix = prefix.isEmpty ? seg : prefix + "/" + seg
                let key = PathKey(seg)
                if let next = node.kids[key] {
                    node = next
                } else {
                    let next = Box(name: seg, path: prefix)
                    node.kids[key] = next
                    node = next
                }
                if counting { node.total += 1 }
            }
            return node
        }
        for p in paths {
            let segs = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segs.count > 1 else { continue }
            walk(segs.dropLast(), counting: true).own += 1
        }
        // An empty folder with the same name as one that has notes, in another spelling, is that folder: a note written
        // to it would go there. Two can exist on an iPhone's disk, when GitHub's arrives after the empty one was made.
        let known = PathIndex(paths)
        for folder in emptyFolders where PathPolicy.isVisible(folder + "/x.md") && !known.takenByAny(folder) {
            _ = walk(folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)[...], counting: false)
        }
        func build(_ b: Box) -> [FolderNode] {
            b.kids.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { FolderNode(name: $0.name, path: $0.path, ownCount: $0.own, totalCount: $0.total, children: build($0)) }
        }
        return build(root)
    }
}


