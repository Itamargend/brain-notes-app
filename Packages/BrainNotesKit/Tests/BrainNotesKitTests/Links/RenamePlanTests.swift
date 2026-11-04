import Testing
@testable import BrainNotesKit

/// The edits a rename or move makes: every link still leads where it did, and nothing else changes.
@Suite struct RenamePlanTests {
    /// The notes, the index over them, and the notes after the plan is applied, by their new paths.
    private struct Vault {
        var notes: [String: String]
        var index: BacklinkIndex

        init(_ notes: [String: String]) {
            self.notes = notes
            index = BacklinkIndex(notes: notes.map { (path: $0.key, text: $0.value) })
        }

        func plan(_ moves: [String: String]) -> RenamePlan {
            index.renamePlan(moves: moves) { notes[$0] }
        }

        /// Moves the files, writes the edits, and brings the index along as the app would.
        mutating func apply(_ moves: [String: String]) -> RenamePlan {
            let result = self.plan(moves)
            var moved = notes
            for from in moves.keys { moved[from] = nil }
            for (from, to) in moves { moved[to] = notes[from] }
            index.applyMoves(moves)
            for file in result.files {
                let text = file.applied(to: notes[file.originalPath]!)
                moved[file.path] = text
                index.update(path: file.path, text: text)
            }
            notes = moved
            return result
        }
    }

    @Test func renameRewritesEveryFormAndNothingElse() {
        var vault = Vault([
            "Old.md": "# Old\n",
            "Folder/Old Sibling.md": "",
            "Source.md": """
                Plain [[Old]], alias [[Old|shown]], heading [[Old#Part 2]], embed ![[Old]], ext [[Old.md]].
                Spaced [[ Old ]] and case [[old]] and a block [[Old#^abc|b]].
                Path [[/Old]] | table [[Old\\|cell]] |
                Code `[[Old]]` and \\[[Old]] and https://x.org/[[Old]]
                ```
                [[Old]]
                ```
                Others: [[Old Sibling]] [[Ghost]] [[#Old]]
                """,
        ])
        let plan = vault.apply(["Old.md": "New Name.md"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.files.map(\.path) == ["Source.md"])
        #expect(vault.notes["Source.md"] == """
            Plain [[New Name]], alias [[New Name|shown]], heading [[New Name#Part 2]], embed ![[New Name]], ext [[New Name.md]].
            Spaced [[ New Name ]] and case [[New Name]] and a block [[New Name#^abc|b]].
            Path [[New Name]] | table [[New Name\\|cell]] |
            Code `[[Old]]` and \\[[Old]] and https://x.org/[[Old]]
            ```
            [[Old]]
            ```
            Others: [[Old Sibling]] [[Ghost]] [[#Old]]
            """)
        #expect(vault.index.backlinks(to: "New Name.md").count == 10)
        #expect(vault.notes["New Name.md"] == "# Old\n", "the renamed note's own text is left to the app")
    }

    @Test func hebrewRenameIsByteStableWithCRLFAndBOM() {
        let source = "\u{FEFF}ראו [[מגן|המיזם]] וגם [[פרויקטים/מגן#רקע]].\r\nCafe\u{301} ב\u{05BC}\u{05B8}ית\r\n"
        var vault = Vault(["פרויקטים/מגן.md": "", "אנשים/איתמר.md": source])
        let plan = vault.apply(["פרויקטים/מגן.md": "פרויקטים/מגן ארכיון.md"])
        #expect(plan.skipped.isEmpty)
        let expected = "\u{FEFF}ראו [[מגן ארכיון|המיזם]] וגם [[פרויקטים/מגן ארכיון#רקע]].\r\nCafe\u{301} ב\u{05BC}\u{05B8}ית\r\n"
        #expect(Array(vault.notes["אנשים/איתמר.md"]!.utf8) == Array(expected.utf8))
    }

    @Test func editsTouchOnlyNameRanges() {
        let source = "a [[Old]] b [[Old|x]] c [[Keep]] d"
        let vault = Vault(["Old.md": "", "Keep.md": "", "S.md": source])
        let plan = vault.plan(["Old.md": "Brand New.md"])
        let names = WikiLinks.parse(source).map(\.nameRange)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].edits.map(\.range) == [names[0], names[1]])
        #expect(plan.files[0].edits.allSatisfy { $0.replacement == "Brand New" })
    }

    @Test func aMoveThatKeepsTheNameUniqueChangesNothing() {
        let vault = Vault(["Inbox/Idea.md": "", "S.md": "[[Idea]] [[Idea#h|x]]"])
        let plan = vault.plan(["Inbox/Idea.md": "Projects/2026/Idea.md"])
        #expect(plan.isEmpty)
        #expect(plan.skipped.isEmpty)
    }

    @Test func pathLinksGetTheNewPath() {
        var vault = Vault(["Inbox/Idea.md": "", "S.md": "[[Inbox/Idea]] [[Idea]] [[inbox/idea.md|x]]"])
        _ = vault.apply(["Inbox/Idea.md": "Projects/Idea.md"])
        #expect(vault.notes["S.md"] == "[[Projects/Idea]] [[Idea]] [[Projects/Idea.md|x]]")
    }

    @Test func aMoveIntoAmbiguityWritesAFolder() {
        var vault = Vault(["a/Note.md": "", "inbox/Note.md": "", "inbox/S.md": "[[Note]]", "b/S.md": "[[Note]]"])
        // inbox/S.md meant inbox/Note.md (same folder). Once that moves into b/, a bare [[Note]] from inbox/ means a/Note.
        _ = vault.apply(["inbox/Note.md": "b/Note.md"])
        #expect(vault.notes["inbox/S.md"] == "[[b/Note]]")
        // b/S.md meant a/Note.md (first by bytes), and b/Note.md would now take the bare name over.
        #expect(vault.notes["b/S.md"] == "[[a/Note]]")
        #expect(vault.index.backlinks(to: "b/Note.md").map(\.source) == ["inbox/S.md"])
        #expect(vault.index.backlinks(to: "a/Note.md").map(\.source) == ["b/S.md"])
    }

    @Test func aRenameDoesNotStealOtherNotesLinks() {
        var vault = Vault(["a/Note.md": "", "b/Other.md": "", "b/S.md": "[[Note]] and [[Other]]", "Root.md": "[[Note]]"])
        _ = vault.apply(["b/Other.md": "b/Note.md"])
        #expect(vault.notes["b/S.md"] == "[[a/Note]] and [[Note]]")
        #expect(vault.notes["Root.md"] == "[[Note]]", "a/Note.md still wins from the root, so no edit")
        #expect(vault.index.backlinks(to: "a/Note.md").map(\.source) == ["Root.md", "b/S.md"])
    }

    @Test func aMovedNoteKeepsItsOwnLinks() {
        var vault = Vault(["a/Note.md": "", "b/Note.md": "", "a/Src.md": "[[Note]] [[Src#Top]] [[#Top]]"])
        let plan = vault.apply(["a/Src.md": "b/Src.md"])
        #expect(plan.files.map(\.path) == ["b/Src.md"])
        #expect(plan.files.map(\.originalPath) == ["a/Src.md"])
        #expect(vault.notes["b/Src.md"] == "[[a/Note]] [[Src#Top]] [[#Top]]")
    }

    @Test func aNoteThatLinksToItself() {
        var vault = Vault(["Old.md": "see [[Old#Top]] and [[#Top]]"])
        let plan = vault.apply(["Old.md": "New.md"])
        #expect(plan.files.map(\.path) == ["New.md"])
        #expect(vault.notes["New.md"] == "see [[New#Top]] and [[#Top]]")
    }

    @Test func linksToMissingNotesAreLeftAlone() {
        var vault = Vault(["Old.md": "", "S.md": "[[Old]] [[Ghost]]"])
        _ = vault.apply(["Old.md": "Ghost.md"])
        #expect(vault.notes["S.md"] == "[[Ghost]] [[Ghost]]", "the old link renamed; the missing one now finds the note")
        #expect(vault.index.backlinks(to: "Ghost.md").count == 2)
    }

    @Test func folderRename() {
        var vault = Vault([
            "Projects/Plan.md": "[[Projects/Sub/Deep]]",
            "Projects/Sub/Deep.md": "[[Plan]]",
            "Projectsish/Other.md": "",
            "Home.md": "[[Projects/Plan]] [[Plan]] [[Deep|d]] [[Other]]",
        ])
        let moves = vault.index.moves(renamingFolder: "Projects", to: "Archive")
        #expect(moves == ["Projects/Plan.md": "Archive/Plan.md", "Projects/Sub/Deep.md": "Archive/Sub/Deep.md"])
        let plan = vault.apply(moves)
        #expect(plan.skipped.isEmpty)
        #expect(vault.notes["Home.md"] == "[[Archive/Plan]] [[Plan]] [[Deep|d]] [[Other]]")
        #expect(vault.notes["Archive/Plan.md"] == "[[Archive/Sub/Deep]]", "two moved notes, one plan")
        #expect(vault.notes["Archive/Sub/Deep.md"] == "[[Plan]]")
        #expect(vault.notes["Projectsish/Other.md"] == "")
    }

    @Test func aFolderMovedDeeperKeepsItsPathLinksWorking() {
        let vault = Vault(["Projects/Plan.md": "", "Home.md": "[[Projects/Plan]]"])
        let moves = vault.index.moves(renamingFolder: "Projects", to: "Archive/Projects")
        #expect(moves == ["Projects/Plan.md": "Archive/Projects/Plan.md"])
        #expect(vault.plan(moves).isEmpty, "a path matches from the end, so the link still finds the note")
    }

    @Test func aSwap() {
        var vault = Vault(["A.md": "", "B.md": "", "S.md": "[[A]] [[B]]"])
        _ = vault.apply(["A.md": "B.md", "B.md": "A.md"])
        #expect(vault.notes["S.md"] == "[[B]] [[A]]")
    }

    @Test func caseOnlyRename() {
        var vault = Vault(["plan.md": "", "S.md": "[[plan]] [[PLAN]]"])
        let plan = vault.apply(["plan.md": "Plan.md"])
        #expect(plan.isEmpty, "the old names still find it")
        #expect(vault.notes["S.md"] == "[[plan]] [[PLAN]]")
    }

    @Test func whatIsNotDone() {
        let vault = Vault(["Old.md": "", "Taken.md": "", "S.md": "[[Old]]", "T.md": "[[Old]]"])
        #expect(vault.plan(["Old.md": "Taken.md"]).skipped == [.destinationTaken(path: "Taken.md")])
        #expect(vault.plan(["Old.md": "Taken.md"]).files.isEmpty)
        #expect(vault.plan(["Missing.md": "X.md"]).isEmpty)
        // Two notes onto one free path: the second would overwrite the first.
        #expect(vault.plan(["Old.md": "New.md", "Taken.md": "New.md"]).skipped == [.destinationTaken(path: "New.md")])
        #expect(vault.plan(["Old.md": "New.md", "Taken.md": "New.md"]).files.isEmpty)
        #expect(vault.plan(["Old.md": "Old.md"]).isEmpty)

        let unwritable = vault.plan(["Old.md": "C# tips.md"])
        #expect(unwritable.files.isEmpty)
        #expect(unwritable.skipped.count == 2)
        if case let .unwritableName(source, link, target)? = unwritable.skipped.first {
            #expect(source == "S.md")
            #expect(link.name == "Old")
            #expect(target == "C# tips.md")
        } else {
            Issue.record("expected unwritableName")
        }

        let noText = vault.index.renamePlan(from: "Old.md", to: "New.md") { $0 == "S.md" ? nil : vault.notes[$0] }
        #expect(noText.skipped == [.missingText(source: "S.md")])
        #expect(noText.files.map(\.path) == ["T.md"])
    }

    @Test func aStaleIndexOnlyReadsTheTextItIsGiven() {
        // The index saw [[Old]], but the note on disk has changed since: the plan works from the text it is given.
        let vault = Vault(["Old.md": "", "S.md": "[[Old]]"])
        let plan = vault.index.renamePlan(from: "Old.md", to: "New.md") { $0 == "S.md" ? "now [[Old|o]] and [[Old]]" : "" }
        #expect(plan.files.first?.applied(to: "now [[Old|o]] and [[Old]]") == "now [[New|o]] and [[New]]")
    }

    /// Random notes and random moves: after the plan every link that led somewhere leads to the same note, moved or
    /// not, and every byte outside a rewritten name is unchanged.
    @Test(arguments: 0..<40) func everyLinkKeepsItsTarget(seed: Int) {
        var rng = LinksGenerator(seed: UInt64(seed) &+ 1000)
        let names = ["Plan", "Kela", "מגן", "Note", "Idea", "פתק"]
        let folders = ["", "a/", "b/", "a/b/", "ארכיון/"]
        var notes: [String: String] = [:]
        for _ in 0..<12 {
            let path = folders.randomElement(using: &rng)! + names.randomElement(using: &rng)! + ".md"
            notes[path] = (0..<Int.random(in: 0...5, using: &rng)).map { _ -> String in
                let name = names.randomElement(using: &rng)!
                let folder = String(folders.randomElement(using: &rng)!.dropLast())
                let target = folder.isEmpty || Bool.random(using: &rng) ? name : folder + "/" + name
                let link = ["[[\(target)]]", "[[\(target)|כינוי]]", "![[\(target)#h]]", "[[\(target).md]]", "`[[\(target)]]`"]
                return link.randomElement(using: &rng)! + ["\n", " ", "\r\n", " שלום "].randomElement(using: &rng)!
            }.joined()
        }
        var vault = Vault(notes)
        let before = vault.index
        let paths = notes.keys.sorted()
        var moves: [String: String] = [:]
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            let from = paths.randomElement(using: &rng)!
            let to = folders.randomElement(using: &rng)! + names.randomElement(using: &rng)! + (Bool.random(using: &rng) ? " 2" : "") + ".md"
            if notes[to] == nil, !moves.values.contains(to) { moves[from] = to }
        }
        guard !moves.isEmpty else { return }
        let plan = vault.apply(moves)
        #expect(plan.skipped.isEmpty)

        for file in plan.files {
            // Only names change: every edit is exactly one link's name, so every other byte stays.
            let names = Set(WikiLinks.parse(notes[file.originalPath]!).map(\.nameRange))
            #expect(file.edits.allSatisfy { names.contains($0.range) })
        }

        let after = BacklinkIndex(notes: vault.notes.map { (path: $0.key, text: $0.value) })
        #expect(after.notes == vault.index.notes, "applying the plan to the index agrees with a rebuild")
        for path in after.notes {
            #expect(after.backlinks(to: path) == vault.index.backlinks(to: path), "\(path)")
        }
        for (old, text) in notes {
            let new = moves[old] ?? old
            let wasLinks = before.links(from: old)
            let nowLinks = after.links(from: new)
            #expect(wasLinks.count == nowLinks.count)
            for (was, now) in zip(wasLinks, nowLinks) {
                guard let target = was.target else { continue }
                #expect(now.target == (moves[target] ?? target), "\(old): \(was.link.name) in \(text.debugDescription)")
            }
        }
    }
}
