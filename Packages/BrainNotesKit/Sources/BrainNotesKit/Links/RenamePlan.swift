/// The edits that keep every link pointing where it did when notes move. Edits replace only a link's name: its
/// `#heading`, `|alias`, `.md`, `!` and every other byte of the note stay as they were.
public struct RenamePlan: Sendable, Equatable {
    public struct FileEdits: Sendable, Equatable {
        /// Where the note is after the moves: a moved note that links to itself or to another moved note is here under
        /// its new path.
        public var path: String
        /// Where its text was read from.
        public var originalPath: String
        public var edits: [TextEdit]

        public func applied(to text: String) -> String { TextEdit.apply(edits, to: text) }
    }

    public enum Skipped: Sendable, Equatable {
        /// No name for the note can be written as a link (it has `#`, `|`, `[` or `]`); this link was left as it was.
        case unwritableName(source: String, link: WikiLink, target: String)
        /// The note's text wasn't available, so its links were left as they were.
        case missingText(source: String)
        /// Reading the edited note back didn't give the expected links, so the note was left as it was.
        case unexpectedResult(source: String)
        /// A note would move onto a path that is taken. Nothing was planned.
        case destinationTaken(path: String)
    }

    public var files: [FileEdits] = []
    public var skipped: [Skipped] = []

    public init(files: [FileEdits] = [], skipped: [Skipped] = []) {
        self.files = files
        self.skipped = skipped
    }

    public var isEmpty: Bool { files.isEmpty }
}

extension BacklinkIndex {
    /// The edits to make when notes move, old path to new: a rename, a move to another folder, or a whole folder.
    ///
    /// Every link that led to a note before the moves leads to the same note after them: links to a moved note, a
    /// moved note's own links whose meaning depends on its folder, and links to other notes that a moved note would
    /// otherwise take over. Such a link gets the shortest name that works, or the full path if it was written with
    /// one. A link that still works is not touched, and a link to a missing note is left alone, even if a moved note
    /// now answers to it.
    ///
    /// `text` gives the current text of a note by its old path. The plan doesn't change the index: after writing the
    /// files, call `applyMoves` and then `update` for each edited note.
    public func renamePlan(moves requested: [String: String], text: (String) -> String?) -> RenamePlan {
        var plan = RenamePlan()
        let moves = requested.filter { $0.key != $0.value && resolver.paths.contains($0.key) }
        guard !moves.isEmpty else { return plan }
        let leaving = Set(moves.keys)
        for destination in Set(moves.values).sorted(by: Self.byBytes)
        where resolver.paths.contains(destination) && !leaving.contains(destination) {
            plan.skipped.append(.destinationTaken(path: destination))
        }
        guard plan.skipped.isEmpty else { return plan }

        let before = resolver
        var after = resolver
        for from in moves.keys { after.remove(from) }
        for to in moves.values { after.insert(to) }

        var sources = Set<String>()
        for (from, to) in moves {
            if mentions[from] != nil { sources.insert(from) }
            for key in LinkResolver.suffixKeys(from) + LinkResolver.suffixKeys(to) {
                sources.formUnion(sourcesByKey[key] ?? [])
            }
        }

        for source in sources.sorted(by: Self.byBytes) {
            guard let original = text(source) else {
                plan.skipped.append(.missingText(source: source))
                continue
            }
            let newSource = moves[source] ?? source
            let links = WikiLinks.parse(original)
            var edits: [TextEdit] = []
            var expected = links.map(\.name)
            for (index, link) in links.enumerated() where !LinkResolver.key(link.name).isEmpty {
                guard let was = before.resolve(link.name, from: source) else { continue }
                let target = moves[was] ?? was
                if after.resolve(link.name, from: newSource) == target { continue }
                guard let name = after.shortestName(for: target, from: newSource, fullPath: link.name.contains("/")) else {
                    plan.skipped.append(.unwritableName(source: source, link: link, target: target))
                    continue
                }
                edits.append(TextEdit(range: link.nameRange, replacement: name))
                expected[index] = name
            }
            guard !edits.isEmpty else { continue }

            // Read the result back: the same links, in the same places in the text, with the new names.
            let reread = WikiLinks.parse(TextEdit.apply(edits, to: original))
            let sameNames: Bool = reread.map(\.name) == expected
            let sameParts: Bool = zip(reread, links).allSatisfy { new, old in
                new.heading == old.heading && new.alias == old.alias && new.isEmbed == old.isEmbed && new.line == old.line
            }
            guard sameNames, sameParts else {
                plan.skipped.append(.unexpectedResult(source: source))
                continue
            }
            plan.files.append(.init(path: newSource, originalPath: source, edits: edits))
        }
        return plan
    }

    /// One rename or move.
    public func renamePlan(from: String, to: String, text: (String) -> String?) -> RenamePlan {
        renamePlan(moves: [from: to], text: text)
    }

    /// The moves that renaming a folder makes: every note under `folder`, old path to new.
    public func moves(renamingFolder folder: String, to newFolder: String) -> [String: String] {
        let prefix = Array((folder + "/").utf8)
        var out: [String: String] = [:]
        for path in resolver.paths {
            let bytes = Array(path.utf8)
            guard bytes.starts(with: prefix) else { continue }
            out[path] = newFolder + "/" + String(decoding: bytes[prefix.count...], as: UTF8.self)
        }
        return out
    }

    private static func byBytes(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }
}
