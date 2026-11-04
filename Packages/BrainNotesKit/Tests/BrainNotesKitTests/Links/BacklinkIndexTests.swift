import Testing
@testable import BrainNotesKit

/// Which note a name means, and the backlinks index kept up to date one change at a time.
@Suite struct LinkResolverTests {
    @Test func namesCompareWithoutCase() {
        let r = LinkResolver(paths: ["Plan.md", "Ideas/Kela.md"])
        #expect(r.resolve("plan", from: nil) == "Plan.md")
        #expect(r.resolve("PLAN", from: "Ideas/Kela.md") == "Plan.md")
        #expect(r.resolve("kela", from: nil) == "Ideas/Kela.md")
        #expect(r.resolve("Missing", from: nil) == nil)
        #expect(r.resolve("", from: nil) == nil)
        #expect(r.resolve("   ", from: nil) == nil)
    }

    @Test func folderPathsMatchFromTheEnd() {
        let r = LinkResolver(paths: ["a/b/Note.md", "c/Note.md", "Note.md"])
        #expect(r.resolve("b/Note", from: nil) == "a/b/Note.md")
        #expect(r.resolve("a/b/Note", from: nil) == "a/b/Note.md")
        #expect(r.resolve("/a/b/Note", from: nil) == "a/b/Note.md", "a leading slash is the root")
        #expect(r.resolve("c/Note", from: nil) == "c/Note.md")
        #expect(r.resolve("x/Note", from: nil) == nil)
        #expect(r.resolve("/b/Note", from: nil) == "a/b/Note.md")
        #expect(r.resolve("Note", from: "c/Other.md") == "Note.md", "the note whose whole path is the name comes first")
    }

    @Test func ambiguousNamesPreferTheSameFolderThenTheShortestPath() {
        let r = LinkResolver(paths: ["a/Note.md", "b/Note.md", "x/y/Note.md"])
        #expect(r.resolve("Note", from: "b/Source.md") == "b/Note.md")
        #expect(r.resolve("Note", from: "x/y/Source.md") == "x/y/Note.md")
        #expect(r.resolve("Note", from: "c/Source.md") == "a/Note.md", "same depth: first by bytes")
        #expect(r.resolve("Note", from: nil) == "a/Note.md")
        let deeper = LinkResolver(paths: ["a/b/Note.md", "z/Note.md"])
        #expect(deeper.resolve("Note", from: "Root.md") == "z/Note.md", "fewer folders first")
    }

    @Test func hebrewNamesInAnyFormAndWithMarks() {
        // בָּ written with dagesh then qamats, and the other way round: the same text to Unicode.
        let stored = "פרויקטים/ב\u{05BC}\u{05B8}יִת.md"
        let typed = "ב\u{05B8}\u{05BC}יִת"
        let r = LinkResolver(paths: [stored, "מגן.md", "Caf\u{E9}.md"])
        #expect(r.resolve(typed, from: nil) == stored)
        #expect(r.resolve("פרויקטים/" + typed, from: nil) == stored)
        #expect(r.resolve("\u{200F}מגן\u{200E}", from: nil) == "מגן.md")
        #expect(r.resolve("מ\u{200F}גן", from: nil) == "מגן.md", "a mark inside the name too")
        #expect(r.resolve("Cafe\u{301}", from: nil) == "Caf\u{E9}.md")
        #expect(r.resolve("CAFÉ", from: nil) == "Caf\u{E9}.md")
    }

    @Test func insertAndRemove() {
        var r = LinkResolver(paths: ["a/Note.md"])
        #expect(r.resolve("Note", from: "b/S.md") == "a/Note.md")
        r.insert("b/Note.md")
        #expect(r.resolve("Note", from: "b/S.md") == "b/Note.md")
        r.remove("b/Note.md")
        r.remove("b/Note.md")
        #expect(r.resolve("Note", from: "b/S.md") == "a/Note.md")
        r.remove("a/Note.md")
        #expect(r.resolve("Note", from: nil) == nil)
        #expect(r.paths.isEmpty)
    }

    @Test func shortestName() {
        let r = LinkResolver(paths: ["a/Note.md", "b/Note.md", "b/Only.md", "C# tips.md", "x/[draft].md", "Top.md"])
        #expect(r.shortestName(for: "b/Only.md", from: nil) == "Only")
        #expect(r.shortestName(for: "b/Note.md", from: "b/S.md") == "Note", "the same folder makes the short name enough")
        #expect(r.shortestName(for: "b/Note.md", from: "a/S.md") == "b/Note")
        #expect(r.shortestName(for: "b/Only.md", from: nil, fullPath: true) == "b/Only")
        #expect(r.shortestName(for: "Top.md", from: nil, fullPath: true) == "Top")
        #expect(r.shortestName(for: "C# tips.md", from: nil) == nil, "# would start a heading")
        #expect(r.shortestName(for: "x/[draft].md", from: nil) == nil)
    }
}

@Suite struct BacklinkIndexTests {
    private func sources(_ index: BacklinkIndex, _ path: String) -> [String] {
        index.backlinks(to: path).map(\.source)
    }

    @Test func backlinksWithContext() {
        let index = BacklinkIndex(notes: [
            (path: "Kela.md", text: "# Kela\nSee [[Palantir]].\n"),
            (path: "Ideas/Plan.md", text: "Jobs: [[palantir|P]] and ![[Palantir#Notes]]\n```\n[[Palantir]]\n```\n`[[Palantir]]`"),
            (path: "Palantir.md", text: "Self: [[Palantir]] [[#Top]]"),
            (path: "Other.md", text: "nothing here"),
        ])
        let found = index.backlinks(to: "Palantir.md")
        #expect(found.map(\.source) == ["Ideas/Plan.md", "Ideas/Plan.md", "Kela.md"], "a note's own links are not backlinks")
        #expect(found.map(\.context) == ["Jobs: [[palantir|P]] and ![[Palantir#Notes]]",
                                         "Jobs: [[palantir|P]] and ![[Palantir#Notes]]",
                                         "See [[Palantir]]."])
        #expect(found.map(\.link.isEmbed) == [false, true, false])
        #expect(index.linkingNotes(to: "Palantir.md") == ["Ideas/Plan.md", "Kela.md"])
        #expect(index.backlinks(to: "Other.md").isEmpty)
        #expect(index.backlinks(to: "Missing.md").isEmpty)
    }

    @Test func hebrewBacklinks() {
        let index = BacklinkIndex(notes: [
            (path: "אנשים/איתמר.md", text: "עובד על [[מגן]] ועל [[פרויקטים/מגן#רקע|הרקע]]\r\n"),
            (path: "פרויקטים/מגן.md", text: "# מגן\r\n"),
        ])
        let found = index.backlinks(to: "פרויקטים/מגן.md")
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.source == "אנשים/איתמר.md" })
        #expect(found[0].context == "עובד על [[מגן]] ועל [[פרויקטים/מגן#רקע|הרקע]]", "no \\r in the context")
    }

    @Test func outgoingAndUnresolved() {
        let index = BacklinkIndex(notes: [
            (path: "A.md", text: "[[B]] [[Ghost]] [[#Here]] [[b|again]]"),
            (path: "B.md", text: "[[Nobody]]"),
        ])
        #expect(index.links(from: "A.md").map(\.target) == ["B.md", nil, nil, "B.md"])
        #expect(index.unresolved().map(\.link.name) == ["Ghost", "Nobody"])
        #expect(index.links(from: "Missing.md").isEmpty)
    }

    @Test func updatesAreIncremental() {
        var index = BacklinkIndex()
        index.update(path: "A.md", text: "[[Target]]")
        #expect(index.notes == ["A.md"])
        #expect(index.unresolved().count == 1, "a link to a note that isn't there yet")

        index.update(path: "Target.md", text: "")
        #expect(sources(index, "Target.md") == ["A.md"], "it works as soon as the note exists")
        #expect(index.unresolved().isEmpty)

        index.update(path: "A.md", text: "no links now")
        #expect(sources(index, "Target.md").isEmpty)

        index.update(path: "A.md", text: "[[Target]] [[Target]]")
        index.update(path: "B.md", text: "[[target]]")
        #expect(sources(index, "Target.md") == ["A.md", "A.md", "B.md"])

        index.remove(path: "Target.md")
        #expect(index.backlinks(to: "Target.md").isEmpty)
        #expect(index.unresolved().count == 3)

        index.remove(path: "A.md")
        index.remove(path: "A.md")
        #expect(index.notes == ["B.md"])
        #expect(index.unresolved().map(\.source) == ["B.md"])
    }

    @Test func aNewNoteCanTakeOverAName() {
        var index = BacklinkIndex(notes: [
            (path: "a/Note.md", text: ""),
            (path: "b/Source.md", text: "[[Note]]"),
        ])
        #expect(sources(index, "a/Note.md") == ["b/Source.md"])
        index.update(path: "b/Note.md", text: "")
        #expect(sources(index, "a/Note.md").isEmpty, "a note in the linking note's own folder wins")
        #expect(sources(index, "b/Note.md") == ["b/Source.md"])
    }

    @Test func movesKeepTheLinksAndChangeWhereTheyLead() {
        var index = BacklinkIndex(notes: [
            (path: "Inbox/Idea.md", text: "about [[Plan]]"),
            (path: "Plan.md", text: ""),
        ])
        index.move(from: "Inbox/Idea.md", to: "Projects/Idea.md")
        #expect(sources(index, "Plan.md") == ["Projects/Idea.md"])
        #expect(index.backlinks(to: "Plan.md")[0].source == "Projects/Idea.md")
        index.move(from: "Plan.md", to: "Old Plan.md")
        #expect(index.backlinks(to: "Old Plan.md").isEmpty)
        #expect(index.unresolved().map(\.source) == ["Projects/Idea.md"])

        index.applyMoves(["Old Plan.md": "Projects/Idea.md", "Projects/Idea.md": "Old Plan.md"])
        #expect(index.notes == ["Old Plan.md", "Projects/Idea.md"])
        #expect(index.links(from: "Old Plan.md").map(\.link.name) == ["Plan"], "a swap carries each note's links along")
        #expect(index.links(from: "Projects/Idea.md").isEmpty)
    }

    @Test func lineBreaksMatchTheParser() {
        let text = "a\r\n[[x]]\r\n\r\n[[y]]\n[[z]]\r[[w]]\u{2029}[[v]]"
        #expect(BacklinkIndex.lines(of: text) == ["a", "[[x]]", "", "[[y]]", "[[z]]", "[[w]]", "[[v]]"])
        let index = BacklinkIndex(notes: [(path: "S.md", text: text)])
        #expect(index.links(from: "S.md").map(\.link.line) == [1, 3, 4, 5, 6])
    }

    /// Any order of creates, edits, deletes and moves leaves the index as building it from the final notes would.
    @Test(arguments: 0..<20) func incrementalMatchesARebuild(seed: Int) {
        var rng = LinksGenerator(seed: UInt64(seed))
        let names = ["Plan", "plan", "Kela", "מגן", "Note", "Ghost"]
        let folders = ["", "a/", "b/", "a/b/", "פרויקטים/"]
        func randomPath() -> String { folders.randomElement(using: &rng)! + names.randomElement(using: &rng)! + ".md" }
        func randomText() -> String {
            (0..<Int.random(in: 0...4, using: &rng)).map { _ -> String in
                let name = names.randomElement(using: &rng)!
                let folder = Bool.random(using: &rng) ? "" : String(folders.randomElement(using: &rng)!.dropLast())
                let target = folder.isEmpty ? name : folder + "/" + name
                return ["[[\(target)]]", "[[\(target)|x]]", "`[[\(target)]]`", "![[\(target)#h]]"].randomElement(using: &rng)!
            }.joined(separator: " ")
        }

        var index = BacklinkIndex()
        var notes: [String: String] = [:]
        for _ in 0..<60 {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5:
                let path = randomPath(), text = randomText()
                notes[path] = text
                index.update(path: path, text: text)
            case 5..<7:
                guard let path = notes.keys.sorted().randomElement(using: &rng) else { continue }
                notes[path] = nil
                index.remove(path: path)
            default:
                guard let from = notes.keys.sorted().randomElement(using: &rng) else { continue }
                let to = randomPath()
                guard notes[to] == nil else { continue }
                notes[to] = notes.removeValue(forKey: from)
                index.move(from: from, to: to)
            }
        }
        let rebuilt = BacklinkIndex(notes: notes.map { (path: $0.key, text: $0.value) })
        #expect(index.notes == rebuilt.notes)
        for path in notes.keys {
            #expect(index.backlinks(to: path) == rebuilt.backlinks(to: path), "\(path)")
            #expect(index.links(from: path) == rebuilt.links(from: path), "\(path)")
        }
        #expect(index.unresolved() == rebuilt.unresolved())
    }
}

/// SplitMix64, so a failing seed fails the same way every run.
struct LinksGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
