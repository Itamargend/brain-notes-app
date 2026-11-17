/// Which note a link's name means, among a set of note paths (`Folder/Note.md`). Rules, in order:
///
/// 1. Names compare without case, without direction marks, and in any Unicode form (Swift's string equality), so
///    `[[Plan]]` finds `plan.md` and a name typed with its Hebrew points in another order still finds its note.
/// 2. A name with no `/` matches every note with that file name. A name with `/` matches a note whose path, without
///    `.md`, is that name or ends with `/` and that name: `[[b/Note]]` finds `a/b/Note.md`. A leading `/` is ignored.
/// 3. Of several matches: the note whose whole path is the name, then one in the linking note's folder, then the one
///    with the fewest folders, then the first by bytes. So every name means exactly one note, or none.
public struct LinkResolver: Sendable {
    public private(set) var paths: Set<String> = []
    /// Folded file name to the notes with it.
    private var byStem: [String: Set<String>] = [:]

    public init() {}

    public init<S: Sequence>(paths: S) where S.Element == String {
        for path in paths { insert(path) }
    }

    public mutating func insert(_ path: String) {
        guard paths.insert(path).inserted else { return }
        byStem[Self.stemKey(path), default: []].insert(path)
    }

    public mutating func remove(_ path: String) {
        guard paths.remove(path) != nil else { return }
        let stem = Self.stemKey(path)
        byStem[stem]?.remove(path)
        if byStem[stem]?.isEmpty == true { byStem[stem] = nil }
    }

    /// The note `name` means when written in `source`, or nil if none.
    public func resolve(_ name: String, from source: String?) -> String? {
        let key = Self.key(name)
        guard !key.isEmpty, let stem = key.split(separator: "/").last, let candidates = byStem[String(stem)] else { return nil }
        var exact: [String] = []
        var matches: [String] = []
        for path in candidates {
            let full = Self.pathKey(path)
            if full == key {
                exact.append(path)
            } else if !key.contains("/") || full.hasSuffix("/" + key) {
                matches.append(path)
            }
        }
        // Two exact matches differ only in case (`Plan.md`, `plan.md`): still one answer, whatever the set's order.
        return Self.pick(exact.isEmpty ? matches : exact, from: source)
    }

    /// The shortest name that means `path` when written in `source`: its file name if that is enough, else as many
    /// folders as it takes. `fullPath` asks for the whole path, for links that were written that way. Nil if no name
    /// can be written as a link, as when the file name holds `#`, `|`, `[` or `]`.
    public func shortestName(for path: String, from source: String?, fullPath: Bool = false) -> String? {
        let parts = Self.dropExtension(path).split(separator: "/", omittingEmptySubsequences: false)
        let counts: [Int] = fullPath ? [parts.count] : Array(1...max(parts.count, 1))
        for n in counts {
            let name = parts.suffix(n).joined(separator: "/")
            if Self.isWritable(name), resolve(name, from: source) == path { return name }
        }
        return nil
    }

    /// Reads back as itself between `[[` and `]]`.
    static func isWritable(_ name: String) -> Bool {
        let links = WikiLinks.parse("[[" + name + "]]")
        return links.count == 1 && links[0].name == name && links[0].heading == nil && links[0].alias == nil
    }

    /// Resolves a Markdown `[title](destination)` link to a note path if it refers to an internal note rather than an external URL.
    /// Rejects traversal (`..`), backslashes, null/encoded tricks, hidden folders, and all URI schemes.
    public func resolveMarkdownLink(_ destination: String, from source: String?) -> String? {
        let trimmed = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefixBeforeSlash = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard !trimmed.isEmpty,
              !prefixBeforeSlash.contains(":"),
              !trimmed.contains("\\") else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.contains("%00") || lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c") {
            return nil
        }
        let decoded = Self.percentDecodeUTF8(trimmed)
        guard !decoded.isEmpty else { return nil }
        let rawSegments = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if rawSegments.contains("..") { return nil }

        func visible(_ candidate: String?) -> String? {
            guard let candidate, PathPolicy.isVisible(candidate), !FolderPlaceholder.isPlaceholder(candidate) else {
                return nil
            }
            return candidate
        }

        let cleanSegments = rawSegments.filter { !$0.isEmpty && $0 != "." }
        guard !cleanSegments.isEmpty else { return nil }

        if !decoded.hasPrefix("/"), let source, source.contains("/") {
            let folderParts = source.split(separator: "/").dropLast().map(String.init)
            let relativeTarget = Self.dropExtension((folderParts + cleanSegments).joined(separator: "/"))
            if let hit = visible(resolve(relativeTarget, from: source)) {
                return hit
            }
            if decoded.hasPrefix("./") {
                return nil
            }
        }

        let directTarget = Self.dropExtension(cleanSegments.joined(separator: "/"))
        return visible(resolve(directTarget, from: source))
    }

    private static func percentDecodeUTF8(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            if (0x30...0x39).contains(b) { return b - 0x30 }
            if (0x41...0x46).contains(b) { return b - 0x41 + 10 }
            if (0x61...0x66).contains(b) { return b - 0x61 + 10 }
            return nil
        }
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                let decodedByte = (hi << 4) | lo
                if decodedByte == 0 { return "" }
                out.append(decodedByte)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: keys

    /// A name as compared: no direction marks, no spaces around it or leading `/`, lowercase.
    static func key(_ name: String) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: name.unicodeScalars.filter { !WikiLinks.isDirectionControl($0) })
        var scalars = Array(view)
        while let first = scalars.first, first.properties.isWhitespace || first == "/" { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out).lowercased()
    }

    /// A note's path as a key: `Folder/Note.md` is `folder/note`.
    static func pathKey(_ path: String) -> String {
        key(dropExtension(path))
    }

    static func stemKey(_ path: String) -> String {
        pathKey(path).split(separator: "/").last.map(String.init) ?? ""
    }

    /// Every key a link to `path` can have: `a/b/note`, `b/note`, `note`.
    static func suffixKeys(_ path: String) -> [String] {
        let parts = pathKey(path).split(separator: "/")
        return (1...max(parts.count, 1)).map { parts.suffix($0).joined(separator: "/") }
    }

    static func dropExtension(_ path: String) -> String {
        let lowered = path.lowercased()
        guard lowered.hasSuffix(".md"), path.unicodeScalars.count > 3 else { return path }
        var scalars = Array(path.unicodeScalars)
        scalars.removeLast(3)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    private static func pick(_ matches: [String], from source: String?) -> String? {
        guard matches.count > 1 else { return matches.first }
        var pool = matches
        if let source {
            let here = folder(of: source)
            let near = matches.filter { folder(of: $0) == here }
            if !near.isEmpty { pool = near }
        }
        return pool.min { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            if da != db { return da < db }
            return Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
        }
    }
}
