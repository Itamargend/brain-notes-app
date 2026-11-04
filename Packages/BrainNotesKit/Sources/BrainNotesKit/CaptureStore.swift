import BrainMerge
import Foundation
import GRDB

extension NoteStore {
    /// Add to Brain: the capture becomes a new note in `_inbox`, through the same save as any note, so it is in
    /// the outbox as a create and the next push takes it. Returns the note's path.
    ///
    /// The folder takes the spelling GitHub already has (`_Inbox` stays `_Inbox`). A name taken in any spelling,
    /// by a note in the journal or by a stray file on the disk, gets `-2`, `-3`... and nothing is overwritten:
    /// the save is `createOnly`, so a name taken between the pick and the write is picked again.
    @discardableResult
    public func capture(_ capture: Capture) throws -> String {
        let text = try CaptureNote.text(for: capture, created: now())
        let stem = CaptureNote.fileStem(for: text)
        var taken: [String] = []
        for _ in 0..<8 {
            let path = try journal.queue.read { db in
                try Self.capturePath(db, stem: stem, alsoTaken: taken, onDisk: { self.files.exists($0) })
            }
            do {
                return try save(path: path, text: text, editingFrom: nil, updateIndex: true, createOnly: true)
            } catch is PathTaken {
                taken.append(path)
            }
        }
        // Eight names taken under us in a row: not a race any more. Say so rather than loop.
        throw CaptureProblem.noFreeName
    }

    /// `_inbox/<stem>.md`, respelled to the tree, free of every name in the journal, in `alsoTaken` and on the disk.
    static func capturePath(_ db: Database, stem: String, alsoTaken: [String], onDisk: (String) -> Bool) throws -> String {
        var tree = PathIndex(try String.fetchAll(db, sql: "SELECT path FROM files") + alsoTaken)
        func free(_ wanted: String) -> String {
            let base = tree.respell(nfc(wanted))
            var path = freePath(base, tree)
            // A file the journal does not know is still someone's text: never write over it.
            while onDisk(path) {
                tree.add(path)
                path = freePath(base, tree)
            }
            return path
        }
        let path = free(PathPolicy.inboxFolder + "/" + stem + ".md")
        if checkPath(path) == nil, tree.clash(path, strict: true) == nil, FileStore.nameFits(path) { return path }
        return free(PathPolicy.inboxFolder + "/Capture.md")
    }
}

extension BrainSession {
    /// Add to Brain from the app's process: write the capture, then let the engine push it on its usual
    /// schedule (the idle wait, or right away when the app goes to the background). Refused in the sample notes.
    @discardableResult
    public func capture(_ capture: Capture) async throws -> String {
        if isDemo { throw CaptureProblem.sampleNotes }
        let store = self.store
        let path = try await Task.detached { try store.capture(capture) }.value
        await engine.noteSaved()
        return path
    }
}
