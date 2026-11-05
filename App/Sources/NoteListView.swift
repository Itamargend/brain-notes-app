import BrainNotesKit
import SwiftUI

/// One folder: subfolders first, then notes, newest first when dates are known.
struct NoteListView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    let folder: String
    let title: String
    @State private var notes: [IndexedNote] = []
    @State private var subfolders: [FolderNode] = []
    @State private var loaded = false
    @State private var namingFolder = false

    var body: some View {
        List {
            if !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { FolderRow(node: $0) }
                }
            }
            Section {
                ForEach(notes) { note in
                    NoteLinkRow(note: note)
                }
            }
        }
        .noteListStyle()
        .overlay {
            if loaded, notes.isEmpty, subfolders.isEmpty {
                ContentUnavailableView("No notes", systemImage: "note.text", description: Text("This folder reaches GitHub with its first note."))
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .trailingAction) {
                Button {
                    router.open(.compose(folder: PathPolicy.isInbox(folder) ? nil : folder, id: UUID()))
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("compose.button.list")
            }
            ToolbarItem(placement: .trailingAction) {
                Button {
                    namingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("folder.new")
            }
        }
        .newFolderPrompt(isPresented: $namingFolder, parent: folder)
        .task(id: app.revision) { await load() }
        .accessibilityIdentifier("list.\(folder)")
    }

    private func load() async {
        guard let s = app.session else { return }
        // The Inbox is every spelling of `_inbox` at once: a sync can bring GitHub's `_Inbox` next to ours.
        notes = PathPolicy.isInbox(folder) ? await s.store.index.inboxNotes() : await s.store.index.notes(inFolder: folder)
        subfolders = Self.children(of: folder, in: app.folderTree)
        loaded = true
    }

    private static func children(of folder: String, in nodes: [FolderNode]) -> [FolderNode] {
        if PathPolicy.isInbox(folder) {
            return nodes.filter { PathPolicy.isInbox($0.path) }.flatMap(\.children)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        for n in nodes {
            if sameBytes(n.path, folder) { return n.children }
            if folder.hasPrefix(n.path + "/") { return children(of: folder, in: n.children) }
        }
        return []
    }
}

private extension View {
    @ViewBuilder func noteListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}

/// A note row that opens the note, with swipe to delete (moves to `_trash`).
struct NoteLinkRow: View {
    @Environment(AppModel.self) private var app
    let note: IndexedNote

    var body: some View {
        RouteLink(.note(note.path)) {
            NoteRow(note: note, status: app.status(of: note.path))
        }
        .accessibilityIdentifier("note.\(note.path)")
        .swipeActions(edge: .trailing) { deleteButton }
        .contextMenu { deleteButton }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await app.delete(path: note.path) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

struct NoteRow: View {
    let note: IndexedNote
    let status: NoteSyncStatus
    /// Keeps the dot level with the title's first line at every text size.
    @ScaledMetric(relativeTo: .headline) private var dotTop: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: status)
                .padding(.top, dotTop)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                if note.isConflictCopy {
                    Label("Conflict copy", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole text block follows the note's language; the dot stays where it is.
            .paragraphDirection(rightToLeft: NoteText.isRightToLeft(note.title))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The date, then the snippet running on under it, as in Notes.
    private var detail: Text {
        let snippet = note.snippet.isEmpty ? "No additional text" : note.snippet
        guard let date = note.modified else { return Text(verbatim: snippet) }
        // The date comes first, and it may be in English. An RLM keeps a Hebrew row reading right to left.
        let mark = NoteText.isRightToLeft(note.title) ? "\u{200F}" : ""
        return Text("\(mark)\(Text(date, format: .relative(presentation: .named)))  \(Text(verbatim: snippet))")
    }
}

/// The per-note state as a dot, and in words for VoiceOver. With Differentiate Without Color on, each state has a shape
/// of its own: orange and green dots are only about 2:1 against a white row, so colour alone can't carry it.
struct StatusDot: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    let status: NoteSyncStatus

    var body: some View {
        Group {
            if withoutColor {
                Image(systemName: status.shapeSymbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(status.label)
        .accessibilityIdentifier("status.\(status.rawValue)")
    }

    private var color: Color {
        switch status {
        case .savedOnDevice: return .orange
        case .syncing: return .accentColor
        case .synced: return .green
        case .needsAttention: return .red
        }
    }
}

extension NoteSyncStatus {
    var label: String {
        switch self {
        case .savedOnDevice: return "Saved on device"
        case .syncing: return "Syncing"
        case .synced: return "Synced"
        case .needsAttention: return "Needs attention"
        }
    }

    /// A shape per state, for when colour can't be told apart. Each one is different.
    var shapeSymbol: String {
        switch self {
        case .savedOnDevice: return "arrow.up.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }
}

/// Search over the local index: Hebrew and English, offline.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var app
    let query: String
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        List(hits) { hit in
            RouteLink(.note(hit.path)) {
                VStack(alignment: .leading, spacing: 3) {
                    Highlighted(hit.title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paragraphDirection(rightToLeft: NoteText.isRightToLeft(hit.title))
                    Highlighted(hit.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paragraphDirection(rightToLeft: NoteText.isRightToLeft(hit.snippet))
                    // Secondary, not tertiary: tertiary grey is under 3:1, too faint for words.
                    Text(SearchIndex.folder(of: hit.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("search.\(hit.path)")
        }
        .overlay {
            if searched, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            hits = await app.session?.store.index.search(query) ?? []
            searched = true
        }
    }
}

/// Text with the index's match markers turned into emphasis.
struct Highlighted: View {
    private let text: AttributedString

    init(_ marked: String) {
        var out = AttributedString()
        var inside = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if inside {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            out += piece
            run = ""
        }
        for c in marked {
            if c == SearchHit.open {
                flush()
                inside = true
            } else if c == SearchHit.close {
                flush()
                inside = false
            } else {
                run.append(c)
            }
        }
        flush()
        text = out
    }

    var body: some View { Text(text) }
}
