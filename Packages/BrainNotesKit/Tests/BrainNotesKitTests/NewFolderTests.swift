import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

/// New Folder: on disk at once, in the lists at once, on GitHub with its first note.
@Suite struct NewFolderTests {
    private func makeStore() throws -> (NoteStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bn-folder-\(UUID().uuidString)", isDirectory: true)
        return (try NoteStore(root: folder), folder)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    @Test func aFolderInsideAFolderIsOnDiskAndInTheTree() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(path: "projects/a.md", text: "# A\n")
        let path = try store.createFolder(named: "Ideas", in: "projects")
        #expect(path == "projects/Ideas")
        #expect(isDirectory(try store.files.url(for: path)))
        #expect(store.files.emptyFolders() == ["projects/Ideas"])

        let tree = FolderNode.tree(paths: ["projects/a.md"], emptyFolders: store.files.emptyFolders())
        #expect(tree.map(\.name) == ["projects"])
        #expect(tree[0].totalCount == 1, "an empty folder counts no notes")
        #expect(tree[0].children.map(\.path) == ["projects/Ideas"])
        #expect(tree[0].children[0].totalCount == 0)
    }

    @Test func theTopLevelAndNestingWork() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.createFolder(named: "תיקייה", in: "") == "תיקייה")
        #expect(try store.createFolder(named: "פנימית", in: "תיקייה") == "תיקייה/פנימית")
        #expect(try store.createFolder(named: "deep", in: "תיקייה/פנימית") == "תיקייה/פנימית/deep")
        // Only the last holds nothing at all; the tree shows the whole chain from it.
        #expect(store.files.emptyFolders() == ["תיקייה/פנימית/deep"])
        let tree = FolderNode.tree(paths: [], emptyFolders: store.files.emptyFolders())
        #expect(tree.map(\.path) == ["תיקייה"])
        #expect(tree[0].children.map(\.path) == ["תיקייה/פנימית"])
        #expect(tree[0].children[0].children.map(\.path) == ["תיקייה/פנימית/deep"])
    }

    @Test func theInboxCanHoldAFolder() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.createFolder(named: "later", in: PathPolicy.inboxFolder) == "_inbox/later")
    }

    @Test func aTypedNameIsCleanedAsAFileNameIs() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.createFolder(named: "  a/b  ", in: "") == "a-b")
        #expect(try store.createFolder(named: "\u{200F}שלום", in: "") == "שלום")
        let nfd = try store.createFolder(named: "Cafe\u{301}", in: "")
        #expect(Array(nfd.utf8) == Array("Caf\u{E9}".utf8), "a repo path made here is NFC")
    }

    @Test func namesTheSyncRulesRefuseAreRefusedNow() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for typed in ["", "   ", "...", "\u{200F}"] {
            #expect(throws: NoteStore.FolderProblem.noName, "\(typed.debugDescription)") { try store.createFolder(named: typed, in: "") }
        }
        for typed in ["private", "PRIVATE", "_capture", "_trash", "_hidden", "notes.md", "NOTES.MD"] {
            #expect(throws: NoteStore.FolderProblem.notAllowed, "\(typed)") { try store.createFolder(named: typed, in: "") }
        }
        // `.git`'s leading dot is cleaned away, so it becomes the ordinary folder `git`.
        #expect(try store.createFolder(named: ".git", in: "") == "git")
        #expect(throws: NoteStore.FolderProblem.notAllowed) { try store.createFolder(named: "x", in: String(repeating: "long/", count: 200)) }
        #expect(store.files.emptyFolders() == ["git"], "nothing else reached the disk")
    }

    @Test func aNameTakenInAnySpellingIsSaidToBeTaken() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(path: "Projects/a.md", text: "# A\n")
        try store.createFolder(named: "Empty", in: "")
        for typed in ["Projects", "projects", "PROJECTS", "Empty", "empty"] {
            #expect(throws: NoteStore.FolderProblem.alreadyExists, "\(typed)") { try store.createFolder(named: typed, in: "") }
        }
    }

    /// An iPhone's disk tells these apart, so the disk's answer isn't enough. An empty folder counts by its clash key.
    @Test func anEmptyFolderIsTakenByItsClashKeyNotJustByTheDisk() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.createFolder(named: "Ideas", in: "")
        for typed in ["ideas", "IDEAS", "Ide\u{0041}s"] {
            #expect(throws: NoteStore.FolderProblem.alreadyExists, "\(typed)") { try store.createFolder(named: typed, in: "") }
        }
        let nested = try store.createFolder(named: "Sub", in: "Ideas")
        #expect(nested == "Ideas/Sub")
        #expect(throws: NoteStore.FolderProblem.alreadyExists) { try store.createFolder(named: "sub", in: "Ideas") }
    }

    /// GitHub's `shared/a.md` arrives after an empty `Shared` was made: on an iPhone's disk that's two folders, one list row.
    @Test func anEmptyTwinOfAFolderWithNotesIsNotAFolderOfItsOwn() {
        let tree = FolderNode.tree(paths: ["shared/a.md"], emptyFolders: ["Shared", "Other"])
        #expect(tree.map(\.path) == ["Other", "shared"])
        #expect(tree.first { $0.path == "shared" }?.totalCount == 1)
        let nested = FolderNode.tree(paths: ["a/Deep/n.md"], emptyFolders: ["a/deep", "a/new"])
        #expect(nested[0].children.map(\.path) == ["a/Deep", "a/new"])
    }

    @Test func aParentKeepsTheSpellingItHas() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(path: "Projects/a.md", text: "# A\n")
        #expect(try store.createFolder(named: "new", in: "projects") == "Projects/new")
    }

    /// Why not a `.gitkeep`: the rules every commit passes through refuse it, so it could never reach GitHub.
    @Test func aGitkeepCouldNeverSync() {
        #expect(!PathPolicy.isSyncable("a/.gitkeep"))
        #expect(checkPath("a/.gitkeep") != nil)
    }

    @Test func anEmptyFolderSurvivesARestart() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.createFolder(named: "keep", in: "")
        let again = try NoteStore(root: root)
        #expect(again.files.emptyFolders() == ["keep"])
    }

    /// Hidden and blocked folders stay out of the lists, as notes in them do.
    @Test func theTreeLeavesOutWhatNoListShows() {
        let tree = FolderNode.tree(paths: [], emptyFolders: ["_trash/x", ".git", "private", "ok"])
        #expect(tree.map(\.path) == ["ok"])
    }

    @Test func aNoteLastInItsFolderTakesTheFolderWithIt() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.createFolder(named: "soon", in: "")
        let note = try store.createNote(folder: folder, text: "# Note\n")
        #expect(store.files.emptyFolders().isEmpty, "it holds a note now")
        try store.delete(path: note)
        #expect(store.files.emptyFolders().isEmpty)
        #expect(!store.files.exists(folder), "as a repo's folder goes with its last file")
    }

    /// The whole route: nothing goes out for the empty folder, the first note carries it to GitHub, and another
    /// device's note arriving in a folder with the same name shows as one folder.
    @Test func theFolderReachesGitHubWithItsFirstNote() async throws {
        let h = try Harness(files: [("projects/old.md", "# Old\n")])
        await h.sync()
        let history = await h.fake.history().count
        let folder = try h.store.createFolder(named: "Ideas", in: "projects")
        #expect(h.store.journal.outbox().isEmpty, "an empty folder queues nothing")
        await h.sync()
        #expect(await h.fake.history().count == history, "and commits nothing")
        #expect(h.store.files.emptyFolders() == ["projects/Ideas"], "a sync leaves it alone")

        let note = try h.store.createNote(folder: folder, text: "# First note\nהערה ראשונה\n")
        #expect(note == "projects/Ideas/First note.md")
        await h.sync()
        #expect(await h.fake.text(note) == "# First note\nהערה ראשונה\n")
        #expect(h.store.status(of: note) == .synced)
        #expect(h.store.files.emptyFolders().isEmpty)

        try h.store.createFolder(named: "Shared", in: "")
        await h.fake.commitRemote([("Shared/from-the-mac.md", "# From the Mac\n")], message: "another device")
        await h.sync()
        #expect(h.local("Shared/from-the-mac.md") == "# From the Mac\n")
        #expect(h.store.files.emptyFolders().isEmpty, "the same folder, not a second one")
    }

    @Test func syncedFoldersAndSubfoldersReachGitHubImmediatelyWithoutShowingAsNotes() async throws {
        let h = try Harness(files: [("ideas/seed.md", "# Seed\n")])
        await h.sync()
        let second = try h.secondDevice()
        await second.sync()

        // 1. Creating a subfolder queues `ideas/jj/_folder.md`, keeps it out of SearchIndex, and syncs to GitHub.
        let sub = try h.store.createSyncedFolder(named: "jj", in: "ideas")
        #expect(sub == "ideas/jj")
        #expect(h.local("ideas/jj/_folder.md") == FolderPlaceholder.text)
        #expect(await h.store.index.notes(inFolder: "ideas/jj").isEmpty, "_folder.md never shows as a note")
        #expect(await h.store.index.search("_folder").isEmpty)
        await h.sync()
        #expect(await h.fake.text("ideas/jj/_folder.md") == FolderPlaceholder.text)
        #expect(h.store.status(of: "ideas/jj/_folder.md") == .synced)

        // 2. Second device pulls `ideas/jj/_folder.md` and sees `ideas/jj` with 0 visible notes.
        await second.sync()
        #expect(await second.store.index.notes(inFolder: "ideas/jj").isEmpty)
        let secondTree = FolderNode.tree(
            paths: await second.store.index.allPaths(),
            emptyFolders: second.store.files.emptyFolders() + second.store.activePlaceholderFolders()
        )
        let ideasNode = try #require(secondTree.first { $0.path == "ideas" })
        #expect(ideasNode.children.map(\.path) == ["ideas/jj"])
        #expect(ideasNode.children[0].totalCount == 0)

        // 3. Pre-existing local empty folders (created before Build 14) auto-receive `_folder.md` and sync to GitHub.
        _ = try h.store.createFolder(named: "legacy-empty", in: "ideas")
        let upgraded = try h.store.ensureEmptyFoldersHavePlaceholders()
        #expect(upgraded == ["ideas/legacy-empty/_folder.md"])
        await h.sync()
        #expect(await h.fake.has("ideas/legacy-empty/_folder.md"))

        // 4. Renaming, moving, deleting, and immediately recreating an empty subfolder translates 1:1 to GitHub.
        let renamed = try h.store.renameFolderLocally("ideas/jj", to: "kk")
        #expect(renamed == "ideas/kk")
        await h.sync()
        #expect(!(await h.fake.has("ideas/jj/_folder.md")))
        #expect(await h.fake.has("ideas/kk/_folder.md"))

        let moved = try h.store.moveFolderLocally("ideas/kk", into: "")
        #expect(moved == "kk")
        await h.sync()
        #expect(!(await h.fake.has("ideas/kk/_folder.md")))
        #expect(await h.fake.has("kk/_folder.md"))

        // Delete while offline (pending `.delete` in outbox), confirm folder leaves activePlaceholderFolders immediately,
        // and verify recreating `"kk"` before sync succeeds cleanly.
        try h.store.removeEmptyOrPlaceholderFolder("kk")
        #expect(!h.store.activePlaceholderFolders().contains("kk"))
        let recreated = try h.store.createSyncedFolder(named: "kk", in: "")
        #expect(recreated == "kk")
        await h.sync()
        #expect(await h.fake.has("kk/_folder.md"))

        // Final delete removes `kk/_folder.md` from GitHub.
        try h.store.removeEmptyOrPlaceholderFolder("kk")
        await h.sync()
        #expect(!(await h.fake.has("kk/_folder.md")))
    }
}
