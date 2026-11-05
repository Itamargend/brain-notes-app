import BrainNotesKit
import SwiftUI

/// Apple Notes-style long-press peek: a glimpse of the note before the context menu actions.
struct NotePeekPreview: View {
    let note: IndexedNote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.title)
                .font(.title2.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paragraphDirection(rightToLeft: NoteText.isRightToLeft(note.title))
            if note.isConflictCopy {
                Label("Conflict copy", systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paragraphDirection(rightToLeft: NoteText.isRightToLeft(note.snippet))
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 320, height: 420, alignment: .topLeading)
        .background(.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("peek.note")
    }
}

/// Peek inside a folder: name, count, and the first notes (title + snippet).
struct FolderPeekPreview: View {
    @Environment(AppModel.self) private var app
    let node: FolderNode
    @State private var notes: [IndexedNote] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(countLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if notes.isEmpty {
                Text(node.totalCount == 0 ? "Empty folder" : "Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes.prefix(5)) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paragraphDirection(rightToLeft: NoteText.isRightToLeft(note.title))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 320, height: 420, alignment: .topLeading)
        .background(.background)
        .task(id: node.path) { await load() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("peek.folder")
    }

    private var countLabel: String {
        let n = node.totalCount
        return n == 1 ? "1 note" : "\(n) notes"
    }

    private func load() async {
        guard let s = app.session else {
            notes = []
            return
        }
        notes = await s.store.index.notes(inFolder: node.path)
    }
}
