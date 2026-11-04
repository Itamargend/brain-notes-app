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

    /// A `key: value` from frontmatter, unquoted.
    public static func frontmatterValue(_ frontmatter: String, key: String) -> String? {
        for line in frontmatter.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(key + ":") else { continue }
            var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// `type: conflict` in the header (merge spec 6.1).
    public static func isConflictCopy(_ text: String) -> Bool {
        let (fm, _) = split(text)
        return !fm.isEmpty && frontmatterValue(fm, key: "type") == "conflict"
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
        var t = Substring(line).drop(while: \.isWhitespace)
        while let f = t.first, f == "#" { t = t.dropFirst() }
        t = t.drop(while: \.isWhitespace)
        for mark in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> "] where t.hasPrefix(mark) {
            t = t.dropFirst(mark.count)
            break
        }
        var s = String(t)
        if s == "---" || s == "***" || s == "```" { return "" }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespaces)
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
        let escaped = text.replacingOccurrences(of: "<", with: "\\<")
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
    }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var isRightToLeft: Bool

    public static func parse(_ body: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?

        func add(_ kind: Kind, _ text: String) {
            out.append(MarkdownBlock(id: out.count, kind: kind, text: text, isRightToLeft: NoteText.isRightToLeft(text)))
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
                add(.task(done: false, indent: indent / 2), String(trimmed.dropFirst(6)))
                continue
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") || trimmed.hasPrefix("* [x] ") {
                flushParagraph()
                add(.task(done: true, indent: indent / 2), String(trimmed.dropFirst(6)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                add(.bullet(indent: indent / 2), String(trimmed.dropFirst(2)))
                continue
            }
            if let marker = numberedMarker(trimmed) {
                flushParagraph()
                add(.numbered(marker: marker, indent: indent / 2), String(trimmed.dropFirst(marker.count + 1)))
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                add(.quote, String(trimmed.dropFirst(trimmed == ">" ? 1 : 2)))
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
