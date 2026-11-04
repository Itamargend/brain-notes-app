import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// Names and checks, with no I/O.
@Suite struct MovePlannerTests {
    private func tree(_ paths: [String], rows: [String]? = nil, ops: [String] = [], empty: [String] = []) -> MoveTree {
        let entries = paths.map { TreeEntry(path: $0, sha: GitBlob.sha($0)) }
        let fileRows = (rows ?? paths).map { p in FileRow(path: p, blobSha: entries.first { sameBytes($0.path, p) }?.sha) }
        return MoveTree(entries: entries, rows: fileRows, opPaths: ops, emptyFolders: empty)
    }

    @Test func numbersGoBeforeTheExtension() {
        #expect(MovePaths.numbered("a/name.md", 2, isNote: true) == "a/name 2.md")
        #expect(MovePaths.numbered("NAME.MD", 3, isNote: true) == "NAME 3.MD")
        #expect(MovePaths.numbered("a/Folder", 2, isNote: false) == "a/Folder 2")
        #expect(MovePaths.numbered("רעיונות/רעיון.md", 2, isNote: true) == "רעיונות/רעיון 2.md")
    }

    @Test func pathPiecesByBytes() {
        #expect(MovePaths.lastSegment("a/b/c.md") == "c.md")
        #expect(MovePaths.lastSegment("c.md") == "c.md")
        #expect(MovePaths.parent("a/b/c.md") == "a/b")
        #expect(MovePaths.parent("c.md") == "")
        #expect(MovePaths.parent("עברית/רעיון.md") == "עברית")
        #expect(MovePaths.rebase("notes/deep/x.md", from: "notes", to: "people/notes 2") == "people/notes 2/deep/x.md")
        #expect(MovePaths.isSameOrInside("Notes/Deep", "notes"))
        #expect(MovePaths.isSameOrInside("notes", "NOTES"))
        #expect(!MovePaths.isSameOrInside("notesX/a", "notes"))
    }

    @Test func aFreeNameIsKeptAndATakenOneCounts() throws {
        let t = tree(["people/beta.md", "people/beta 2.md", "people/Gamma.md"])
        let index = t.index()
        #expect(try MovePlanner.free("people/alpha.md", index, isNote: true) == "people/alpha.md")
        #expect(try MovePlanner.free("people/beta.md", index, isNote: true) == "people/beta 3.md")
        #expect(try MovePlanner.free("people/gamma.md", index, isNote: true) == "people/gamma 2.md", "taken in another case")
        #expect(try MovePlanner.free("people", index, isNote: false) == "people 2")
    }

    /// An empty folder on this disk takes its name as much as a folder on GitHub does.
    @Test func anEmptyFolderHereTakesItsName() throws {
        let t = tree([], empty: ["Ideas"])
        #expect(try MovePlanner.free("ideas", t.index(), isNote: false) == "ideas 2")
        #expect(try MovePlanner.free("Ideas/x.md", t.index(), isNote: true) == "Ideas/x.md", "the sentinel is no note's name")
    }

    @Test func nfdIsMadeNfcAndTakesTheExistingSpelling() throws {
        let t = tree(["Caf\u{E9}/a.md", "todo.md"])
        let plan = try MovePlanner.note("todo.md", into: "Cafe\u{301}", t)
        #expect(Array(plan.items[0].to.utf8) == Array("Caf\u{E9}/todo.md".utf8))
        let upper = try MovePlanner.note("todo.md", into: "CAF\u{C9}", t)
        #expect(Array(upper.items[0].to.utf8) == Array("Caf\u{E9}/todo.md".utf8), "the folder GitHub has, not a twin")
    }

    @Test func destinationsTheRulesRefuse() throws {
        for dest in ["private", "PRIVATE", "_capture", "_trash", "x/.git", ".hidden", "notes.md", "a//b", "/abs", "a/", "../up", "a/../b",
                     String(repeating: "long/", count: 200)] {
            #expect(throws: MoveProblem.notAllowed(dest), "\(dest)") { try MovePlanner.destination(dest) }
        }
        #expect(try MovePlanner.destination("") == "")
        #expect(try MovePlanner.destination("_inbox") == "_inbox")
        #expect(try MovePlanner.destination("תיקייה/פנימית") == "תיקייה/פנימית")
    }

    @Test func aFolderNeverGoesIntoItself() {
        let t = tree(["notes/a.md", "notes/deep/b.md"])
        for dest in ["notes", "notes/deep", "NOTES/Deep", "notes/new/place"] {
            #expect(throws: MoveProblem.intoItself, "\(dest)") { try MovePlanner.folder("notes", into: dest, t) }
        }
        #expect(throws: MoveProblem.alreadyThere) { try MovePlanner.folder("notes/deep", into: "Notes", t) }
    }

    @Test func aFolderMovesWholeOrNotAtAll() throws {
        let t = tree(["notes/a.md", "notes/deep/b.md", "notes/pic.png", "notes/.obsidian/x.md", "people/c.md"])
        #expect(throws: MoveProblem.leftBehind(["notes/.obsidian/x.md", "notes/pic.png"])) { try MovePlanner.folder("notes", into: "people", t) }
        let twins = tree(["notes/a.md", "Notes/b.md"])
        #expect(throws: MoveProblem.leftBehind(["Notes/b.md"])) { try MovePlanner.folder("notes", into: "x", twins) }
        let clean = tree(["notes/a.md", "notes/deep/b.md"], empty: ["notes/later"])
        let plan = try MovePlanner.folder("notes", into: "people", clean)
        #expect(plan.items.map(\.to) == ["people/notes/a.md", "people/notes/deep/b.md"])
        #expect(plan.items.map(\.sha) == clean.entries.map(\.sha), "the same blobs")
        #expect(plan.emptyFolders == [.init(from: "notes/later", to: "people/notes/later")])
    }

    @Test func unsyncedNotesStopAMove() {
        let t = tree(["notes/a.md", "notes/b.md"], ops: ["notes/b.md", "notes/new.md"])
        #expect(throws: MoveProblem.unsynced(["notes/b.md"])) { try MovePlanner.note("notes/b.md", into: "x", t) }
        #expect(throws: MoveProblem.unsynced(["notes/new.md"])) { try MovePlanner.note("notes/new.md", into: "x", t) }
        #expect(throws: MoveProblem.unsynced(["notes/b.md", "notes/new.md"])) { try MovePlanner.folder("notes", into: "x", t) }
    }

    @Test func theInboxAndHiddenFoldersStayPut() {
        let t = tree(["_inbox/a.md", "_trash/b.md", "notes/c.md"])
        #expect(throws: MoveProblem.notAllowed("_inbox")) { try MovePlanner.folder("_inbox", into: "notes", t) }
        #expect(throws: MoveProblem.notAllowed("_trash")) { try MovePlanner.folder("_trash", into: "notes", t) }
        #expect(throws: MoveProblem.notAllowed("")) { try MovePlanner.folder("", into: "notes", t) }
    }

    @Test func aPlaceholderOnlyForAFolderGitHubDoesNotHave() throws {
        let t = tree(["notes/a.md", "assets/photo.png"])
        #expect(try MovePlanner.placeholder(for: "Ideas", t) == "Ideas/_folder.md")
        #expect(try MovePlanner.placeholder(for: "notes", t) == nil)
        #expect(try MovePlanner.placeholder(for: "ASSETS", t) == nil, "any file keeps a folder, in any case")
        #expect(throws: MoveProblem.notAllowed("private")) { try MovePlanner.placeholder(for: "private", t) }
    }

    /// The placeholder passes every rule a commit goes through, and lists can tell it from a note.
    @Test func thePlaceholderSyncsAndListsLeaveItOut() {
        let p = FolderPlaceholder.path(in: "notes/Ideas")
        #expect(checkPath(p) == nil)
        #expect(PathPolicy.isSyncable(p))
        #expect(FolderPlaceholder.isPlaceholder(p))
        #expect(!FolderPlaceholder.isPlaceholder("notes/folder.md"))
        let (notes, folders) = FolderPlaceholder.listing(["notes/a.md", p, "רעיונות/_folder.md"])
        #expect(notes == ["notes/a.md"])
        #expect(folders == ["notes/Ideas", "רעיונות"])
        let tree = FolderNode.tree(paths: notes, emptyFolders: folders)
        #expect(tree.map(\.path) == ["notes", "רעיונות"])
        #expect(tree[0].children.map(\.path) == ["notes/Ideas"])
        #expect(tree[0].totalCount == 1, "the placeholder is not counted as a note")
    }
}
