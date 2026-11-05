import XCTest
@testable import BrainNotes

/// Guards the long-press crash fix: peeks must not depend on Observation AppModel
/// environment (the context-menu preview host historically omitted it and fataled).
final class PeekPreviewTests: XCTestCase {
    func testPeekSourcesDoNotReadAppModelEnvironment() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let peek = try String(contentsOf: sources.appendingPathComponent("PeekPreviews.swift"), encoding: .utf8)
        XCTAssertFalse(peek.contains("@Environment(AppModel.self)"), "preview must not depend on AppModel")
        XCTAssertFalse(peek.contains(".task(id:"), "preview must not hit the store during presentation")
        XCTAssertTrue(peek.contains("struct NotePeekPreview"), "note peek exists")
        XCTAssertTrue(peek.contains("struct FolderPeekPreview"), "folder peek exists")
        XCTAssertTrue(peek.contains("notes: [IndexedNote]"), "folder peek takes notes in")

        let notes = try String(contentsOf: sources.appendingPathComponent("NoteListView.swift"), encoding: .utf8)
        XCTAssertTrue(notes.contains("NotePeekPreview(note: note)"))
        XCTAssertTrue(notes.contains("NoteRow(note: note, status: app.status(of: note.path))\n                .contextMenu"))

        let folders = try String(contentsOf: sources.appendingPathComponent("FoldersView.swift"), encoding: .utf8)
        XCTAssertTrue(folders.contains("FolderPeekPreview(node: node, notes: peekNotes)"))
        XCTAssertTrue(folders.contains("CountRow(title: node.name, systemImage: \"folder\", count: node.totalCount)\n                .contextMenu"))
    }
}
