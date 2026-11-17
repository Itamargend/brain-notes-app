import BrainNotesKit
import SwiftUI

/// One folder: subfolders first, then pinned notes, then date-grouped unpinned notes (`Today`, `Previous 7 Days`, `Previous 30 Days`, Year).
struct NoteListView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    let folder: String
    let title: String
    @State private var notes: [IndexedNote] = []
    @State private var subfolders: [FolderNode] = []
    @State private var loaded = false
    @State private var namingFolder = false
    @State private var query = ""

    private struct DateBucket: Identifiable {
        var id: String { title }
        var title: String
        var notes: [IndexedNote]
    }

    private var pinnedNotes: [IndexedNote] { notes.filter(\.isPinned) }
    private var unpinnedNotes: [IndexedNote] { notes.filter { !$0.isPinned } }

    private var dateBuckets: [DateBucket] {
        Self.groupByDate(unpinnedNotes)
    }

    private var noteCountSubtitle: String {
        "\(notes.count) \(notes.count == 1 ? "Note" : "Notes")"
    }

    var body: some View {
        Group {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultsView(query: query)
            } else {
                listContent
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(loaded ? noteCountSubtitle : "")
        #if os(iOS)
        .searchable(text: $query, prompt: "Search")
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .trailingAction) {
                Button {
                    router.open(.compose(folder: PathPolicy.isInbox(folder) ? nil : folder, id: UUID()))
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("compose.button.list")
            }
            #endif
            ToolbarItem(placement: .trailingAction) {
                Button {
                    namingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("folder.new")
            }
            #if os(iOS)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    router.open(.compose(folder: PathPolicy.isInbox(folder) ? nil : folder, id: UUID()))
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("compose.button.list")
            }
            #endif
        }
        .newFolderPrompt(isPresented: $namingFolder, parent: folder)
        .task(id: app.revision) { await load() }
        .accessibilityIdentifier("list.\(folder)")
    }

    private var listContent: some View {
        List {
            if !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { FolderRow(node: $0) }
                }
            }
            if !pinnedNotes.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedNotes) { note in
                        NoteLinkRow(note: note)
                    }
                }
            }
            ForEach(dateBuckets) { bucket in
                Section(bucket.title) {
                    ForEach(bucket.notes) { note in
                        NoteLinkRow(note: note)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: notes.map { "\($0.path):\($0.isPinned)" })
        .noteListStyle()
        .overlay {
            if loaded, notes.isEmpty, subfolders.isEmpty {
                ContentUnavailableView("No notes", systemImage: "note.text", description: Text("This folder reaches GitHub with its first note."))
            }
        }
    }

    private static func groupByDate(_ items: [IndexedNote], now: Date = Date()) -> [DateBucket] {
        guard !items.isEmpty else { return [] }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

        var order: [String] = []
        var grouped: [String: [IndexedNote]] = [:]
        for note in items {
            let bucket: String
            if let date = note.modified {
                if calendar.isDateInToday(date) || date >= startOfToday {
                    bucket = "Today"
                } else if date >= sevenDaysAgo {
                    bucket = "Previous 7 Days"
                } else if date >= thirtyDaysAgo {
                    bucket = "Previous 30 Days"
                } else {
                    bucket = String(calendar.component(.year, from: date))
                }
            } else {
                bucket = "Notes"
            }
            if grouped[bucket] == nil {
                order.append(bucket)
                grouped[bucket] = []
            }
            grouped[bucket]?.append(note)
        }
        return order.compactMap { key in
            guard let list = grouped[key], !list.isEmpty else { return nil }
            return DateBucket(title: key, notes: list)
        }
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
    func noteListStyle() -> some View {
        #if os(iOS)
        return listStyle(.insetGrouped).brainBlackList()
        #else
        return listStyle(.inset).brainBlackList()
        #endif
    }
}

/// A note row that opens the note, with leading swipe to Pin/Unpin and trailing swipe to Delete (`_trash`).
struct NoteLinkRow: View {
    @Environment(AppModel.self) private var app
    let note: IndexedNote

    var body: some View {
        // Menu+preview on the row content — NOT on the NavigationLink wrapper.
        // Attaching a contextMenu preview to RouteLink/NavigationLink crashed on long-press.
        RouteLink(.note(note.path)) {
            NoteRow(note: note, status: app.status(of: note.path))
                .contextMenu {
                    pinButton
                    Divider()
                    deleteButton
                } preview: {
                    NotePeekPreview(note: note)
                }
        }
        .accessibilityIdentifier("note.\(note.path)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) { pinButton.tint(.orange) }
        .swipeActions(edge: .trailing) { deleteButton }
    }

    private var pinButton: some View {
        Button {
            Task { await app.togglePin(path: note.path) }
        } label: {
            Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash.fill" : "pin.fill")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await app.requestDelete(paths: [note.path]) }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.title)
                        .font(.headline)
                        .lineLimit(1)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                            .accessibilityLabel("Pinned")
                    }
                }
                .animation(.snappy(duration: 0.22, extraBounce: 0.08), value: note.isPinned)
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
        #if os(iOS)
        .brainBlackList()
        #else
        // Search replaces the folder list, so it stays on the sidebar surface.
        .brainSurface(.sidebar)
        #endif
        .overlay {
            if searched, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            var found = await app.session?.store.index.search(query) ?? []
            // Demo portfolio: stable shelf order for query "books" (path sort, 01… first).
            if LaunchOptions.current.demo, query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "books" {
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
            hits = found
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
