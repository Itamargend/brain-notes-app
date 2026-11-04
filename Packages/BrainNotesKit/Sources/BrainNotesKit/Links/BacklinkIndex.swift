/// Which notes link to which, kept up to date one note at a time. It stores each note's links as written, not where
/// they lead, and resolves at query time: a note created, renamed or deleted changes where other notes' links go
/// (a link to a missing note starts working once the note exists), and nothing has to be redone for that.
///
/// An update costs the links of one note; asking for a note's backlinks costs the links that could name it.
public struct BacklinkIndex: Sendable {
    /// A link and the note it is in.
    public struct Mention: Sendable, Hashable {
        public var source: String
        public var link: WikiLink
        /// The whole line the link is on, without its line break. For showing a backlink in context.
        public var context: String
    }

    /// A link out of a note, and the note it leads to now, if any.
    public struct Outgoing: Sendable, Hashable {
        public var link: WikiLink
        public var target: String?
    }

    public private(set) var resolver = LinkResolver()
    var mentions: [String: [Stored]] = [:]
    /// A name's key to the notes that have a link with that key.
    var sourcesByKey: [String: Set<String>] = [:]

    struct Stored: Sendable, Hashable {
        var mention: Mention
        var key: String
    }

    public init() {}

    public init<S: Sequence>(notes: S) where S.Element == (path: String, text: String) {
        for note in notes { update(path: note.path, text: note.text) }
    }

    /// Every note in the index.
    public var notes: Set<String> { resolver.paths }

    // MARK: changes

    /// A note was created or its text changed.
    public mutating func update(path: String, text: String) {
        drop(source: path)
        let lines = Self.lines(of: text)
        let stored = WikiLinks.parse(text).map { link in
            Stored(mention: Mention(source: path, link: link, context: link.line < lines.count ? lines[link.line] : ""),
                   key: LinkResolver.key(link.name))
        }
        add(stored, as: path)
        resolver.insert(path)
    }

    public mutating func remove(path: String) {
        drop(source: path)
        resolver.remove(path)
    }

    /// A note moved or was renamed and its text stayed the same.
    public mutating func move(from: String, to: String) {
        applyMoves([from: to])
    }

    /// Several notes moved at once, as when a folder is renamed. Old paths to new; a swap is fine.
    public mutating func applyMoves(_ moves: [String: String]) {
        var taken: [(to: String, stored: [Stored])] = []
        for (from, to) in moves where resolver.paths.contains(from) {
            taken.append((to, drop(source: from)))
            resolver.remove(from)
        }
        for (to, stored) in taken {
            drop(source: to)
            add(stored.map { item in
                var item = item
                item.mention.source = to
                return item
            }, as: to)
            resolver.insert(to)
        }
    }

    // MARK: queries

    /// The links in other notes that lead to `path`, by source path and then position.
    public func backlinks(to path: String) -> [Mention] {
        guard resolver.paths.contains(path) else { return [] }
        var out: [Mention] = []
        for key in LinkResolver.suffixKeys(path) {
            for source in sourcesByKey[key] ?? [] where source != path {
                for item in mentions[source] ?? [] where item.key == key {
                    if resolver.resolve(item.mention.link.name, from: source) == path { out.append(item.mention) }
                }
            }
        }
        return Self.sorted(out)
    }

    /// The notes that link to `path`.
    public func linkingNotes(to path: String) -> [String] {
        var seen = Set<String>()
        return backlinks(to: path).compactMap { seen.insert($0.source).inserted ? $0.source : nil }
    }

    /// The links in `path`, in order, with where each leads. A link into the same note (`[[#Heading]]`) leads nowhere.
    public func links(from path: String) -> [Outgoing] {
        (mentions[path] ?? []).map { item in
            Outgoing(link: item.mention.link, target: item.key.isEmpty ? nil : resolver.resolve(item.mention.link.name, from: path))
        }
    }

    /// Links to notes that don't exist, by source path and then position.
    public func unresolved() -> [Mention] {
        var out: [Mention] = []
        for (source, items) in mentions {
            for item in items where !item.key.isEmpty && resolver.resolve(item.mention.link.name, from: source) == nil {
                out.append(item.mention)
            }
        }
        return Self.sorted(out)
    }

    // MARK: storage

    @discardableResult
    private mutating func drop(source: String) -> [Stored] {
        guard let old = mentions.removeValue(forKey: source) else { return [] }
        for key in Set(old.map(\.key)) where !key.isEmpty {
            sourcesByKey[key]?.remove(source)
            if sourcesByKey[key]?.isEmpty == true { sourcesByKey[key] = nil }
        }
        return old
    }

    private mutating func add(_ stored: [Stored], as source: String) {
        mentions[source] = stored
        for key in Set(stored.map(\.key)) where !key.isEmpty {
            sourcesByKey[key, default: []].insert(source)
        }
    }

    static func sorted(_ mentions: [Mention]) -> [Mention] {
        mentions.sorted { a, b in
            if a.source != b.source { return Array(a.source.utf8).lexicographicallyPrecedes(Array(b.source.utf8)) }
            return a.link.range.lowerBound < b.link.range.lowerBound
        }
    }

    /// Lines as `WikiLinks` counts them.
    static func lines(of text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if afterCR, scalar == "\n" {
                afterCR = false
                continue
            }
            afterCR = scalar == "\r"
            if WikiLinks.isLineBreak(scalar) {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        out.append(String(current))
        return out
    }
}
