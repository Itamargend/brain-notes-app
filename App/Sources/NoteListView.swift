import BrainNotesKit
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Context-Menu Sheet Hooks & Mac Row Share Anchor

struct NoteSharePayload: Identifiable, Equatable {
    let id = UUID()
    var items: [String]
}

typealias MoveNoteRequestHandler = @MainActor @Sendable (String) -> Void
typealias ShareNoteRequestHandler = @MainActor @Sendable (NoteSharePayload) -> Void

private struct RequestMoveNoteKey: EnvironmentKey {
    static let defaultValue: MoveNoteRequestHandler? = nil
}

private struct RequestShareNoteKey: EnvironmentKey {
    static let defaultValue: ShareNoteRequestHandler? = nil
}

private struct OrderedNotePathsKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var bnRequestMoveNote: MoveNoteRequestHandler? {
        get { self[RequestMoveNoteKey.self] }
        set { self[RequestMoveNoteKey.self] = newValue }
    }

    var bnRequestShareNote: ShareNoteRequestHandler? {
        get { self[RequestShareNoteKey.self] }
        set { self[RequestShareNoteKey.self] = newValue }
    }

    var bnOrderedNotePaths: [String] {
        get { self[OrderedNotePathsKey.self] }
        set { self[OrderedNotePathsKey.self] = newValue }
    }
}

#if os(iOS)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [String]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

private struct NoteContextSheetsModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var movingNotePath: String?
    @Binding var sharingPayload: NoteSharePayload?

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(
                    get: { movingNotePath != nil },
                    set: { if !$0 { movingNotePath = nil } }
                )
            ) {
                if let path = movingNotePath {
                    MoveNoteSheet(currentPath: path) { newFolder in
                        _ = await app.moveNote(path: path, toFolder: newFolder)
                    }
                    #if os(iOS)
                    .preferredColorScheme(.dark)
                    #endif
                }
            }
            #if os(iOS)
            .sheet(item: $sharingPayload) { payload in
                ActivityShareSheet(items: payload.items)
                    .presentationDetents([.medium, .large])
            }
            #endif
    }
}

extension View {
    func noteContextSheets(movingNotePath: Binding<String?>, sharingPayload: Binding<NoteSharePayload?>) -> some View {
        modifier(NoteContextSheetsModifier(movingNotePath: movingNotePath, sharingPayload: sharingPayload))
    }
}

#if os(macOS)
@MainActor
enum MacShareAnchorRegistry {
    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var anchors: [String: WeakView] = [:]

    static func register(_ view: NSView, for path: String) {
        anchors[path] = WeakView(view)
    }

    static func presentSharePicker(items: [String], for path: String) {
        guard !items.isEmpty else { return }
        if let rawView = anchors[path]?.view, rawView.window != nil {
            let target = rawView.superview ?? rawView
            let edge: NSRectEdge = target.isFlipped ? .maxY : .minY
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: target.bounds, of: target, preferredEdge: edge)
            return
        }
        if let contentView = NSApp.keyWindow?.contentView {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1), of: contentView, preferredEdge: .minY)
        }
    }
}

private struct MacRowShareAnchor: NSViewRepresentable {
    let notePath: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        MacShareAnchorRegistry.register(view, for: notePath)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MacShareAnchorRegistry.register(nsView, for: notePath)
    }
}
#endif

// MARK: - NoteListView

/// One folder (or All Notes / Root Notes / Inbox): subfolders on iPhone, collapsible pinned section, and sorted/grouped notes.
struct NoteListView: View {
    static let allNotesToken = "__all__"

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    let folder: String
    let title: String
    @State private var notes: [IndexedNote] = []
    @State private var subfolders: [FolderNode] = []
    @State private var loaded = false
    @State private var namingFolder = false
    @State private var query = ""
    @State private var movingNotePath: String?
    @State private var sharingPayload: NoteSharePayload?
    @State private var isSelectingNotes = false
    @State private var selectedOnPhone: Set<String> = []
    @State private var showingBatchMoveSheet = false
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    private struct DateBucket: Identifiable {
        var id: String { title }
        var title: String
        var notes: [IndexedNote]
    }

    private var isAllNotes: Bool { folder == Self.allNotesToken }

    private var composeFolder: String? {
        if isAllNotes || folder.isEmpty || PathPolicy.isInbox(folder) {
            return nil
        }
        return folder
    }

    private var prefs: ListPreferences { app.listPreferences }

    private var sortedPinnedNotes: [IndexedNote] {
        prefs.sorted(notes.filter(\.isPinned))
    }

    private var sortedUnpinnedNotes: [IndexedNote] {
        prefs.sorted(notes.filter { !$0.isPinned })
    }

    private var usesDateBuckets: Bool {
        prefs.groupByDate && !prefs.sortBy.usesTitleOrder
    }

    private var dateBuckets: [DateBucket] {
        Self.groupByDate(sortedUnpinnedNotes, useCreatedDate: prefs.sortBy == .dateCreated)
    }

    private var orderedVisiblePaths: [String] {
        let pinnedPart = prefs.pinnedCollapsed ? [] : sortedPinnedNotes.map(\.path)
        let unpinnedPart = usesDateBuckets ? dateBuckets.flatMap { $0.notes.map(\.path) } : sortedUnpinnedNotes.map(\.path)
        return pinnedPart + unpinnedPart
    }

    private var noteCountSubtitle: String {
        "\(notes.count) \(notes.count == 1 ? "Note" : "Notes")"
    }

    private var navigationHeaderTitle: String {
        if isSelectingNotes {
            return selectedOnPhone.isEmpty ? "Select Notes" : "\(selectedOnPhone.count) Selected"
        }
        return title
    }

    var body: some View {
        Group {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultsView(query: query)
            } else {
                listContent
            }
        }
        .navigationTitle(navigationHeaderTitle)
        .navigationSubtitle(loaded && !isSelectingNotes ? noteCountSubtitle : "")
        #if os(iOS)
        .searchable(text: $query, prompt: "Search")
        #endif
        .toolbar { toolbarContent }
        .newFolderPrompt(isPresented: $namingFolder, parent: isAllNotes || PathPolicy.isInbox(folder) ? "" : folder)
        .noteContextSheets(movingNotePath: $movingNotePath, sharingPayload: $sharingPayload)
        .sheet(isPresented: $showingBatchMoveSheet) {
            let batchPaths = isSelectingNotes ? Array(selectedOnPhone) : Array(app.selectedNotePaths)
            if let first = batchPaths.first {
                MoveNoteSheet(currentPath: first, noteCount: batchPaths.count) { dest in
                    _ = await app.moveNotes(paths: batchPaths, toFolder: dest)
                    selectedOnPhone.removeAll()
                    isSelectingNotes = false
                }
                #if os(iOS)
                .preferredColorScheme(.dark)
                #endif
            }
        }
        .environment(\.bnRequestMoveNote, { path in movingNotePath = path })
        .environment(\.bnRequestShareNote, { payload in sharingPayload = payload })
        .environment(\.bnOrderedNotePaths, orderedVisiblePaths)
        .task(id: app.revision) { await load() }
        #if os(macOS)
        .onAppear { installMacKeyMonitor() }
        .onDisappear { removeMacKeyMonitor() }
        #endif
        .accessibilityIdentifier("list.\(folder)")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .trailingAction) {
            Button {
                app.clearNoteSelection()
                app.activePane = .editor
                router.open(.compose(folder: composeFolder, id: UUID()))
            } label: {
                Label("New note", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("compose.button.list")

            folderMoreMenu
        }
        if router.usesStack {
            ToolbarItem(placement: .trailingAction) {
                Button {
                    namingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("folder.new")
            }
        }
        #else
        if isSelectingNotes {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    withAnimation(.snappy(duration: 0.22)) {
                        isSelectingNotes = false
                        selectedOnPhone.removeAll()
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .accessibilityIdentifier("list.select.done")
            }
            ToolbarItem(placement: .bottomBar) {
                Button(selectedOnPhone.isEmpty ? "Move All" : "Move") {
                    if selectedOnPhone.isEmpty {
                        selectedOnPhone = Set(notes.map(\.path))
                    }
                    showingBatchMoveSheet = true
                }
                .disabled(notes.isEmpty)
                .accessibilityIdentifier("list.select.move")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(selectedOnPhone.isEmpty ? "Delete All" : "Delete", role: .destructive) {
                    let targets = selectedOnPhone.isEmpty ? notes.map(\.path) : Array(selectedOnPhone)
                    selectedOnPhone.removeAll()
                    isSelectingNotes = false
                    Task { await app.requestDelete(paths: targets) }
                }
                .tint(.red)
                .disabled(notes.isEmpty)
                .accessibilityIdentifier("list.select.delete")
            }
        } else {
            ToolbarItemGroup(placement: .trailingAction) {
                if !isAllNotes {
                    Button {
                        namingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("folder.new")
                }

                folderMoreMenu
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    router.open(.compose(folder: composeFolder, id: UUID()))
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("compose.button.list")
            }
        }
        #endif
    }

    private var folderMoreMenu: some View {
        Menu {
            #if os(iOS)
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    selectedOnPhone.removeAll()
                    isSelectingNotes = true
                }
            } label: {
                Label("Select Notes", systemImage: "checkmark.circle")
            }
            .disabled(notes.isEmpty)
            .accessibilityIdentifier("list.more.select")

            Divider()
            #endif

            Menu {
                sortOptionButton("Default (Date Edited)", field: .defaultEdited)
                sortOptionButton("Date Edited", field: .dateEdited)
                sortOptionButton("Date Created", field: .dateCreated)
                sortOptionButton("Title", field: .title)

                Divider()

                if prefs.sortBy.usesTitleOrder {
                    directionButton("A to Z", isSelected: prefs.titleAscending) {
                        app.updateListPreferences { $0.titleAscending = true }
                    }
                    directionButton("Z to A", isSelected: !prefs.titleAscending) {
                        app.updateListPreferences { $0.titleAscending = false }
                    }
                } else {
                    directionButton("Newest First", isSelected: prefs.newestFirst) {
                        app.updateListPreferences { $0.newestFirst = true }
                    }
                    directionButton("Oldest First", isSelected: !prefs.newestFirst) {
                        app.updateListPreferences { $0.newestFirst = false }
                    }
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }

            Menu {
                directionButton("On", isSelected: prefs.groupByDate) {
                    app.updateListPreferences { $0.groupByDate = true }
                }
                directionButton("Off", isSelected: !prefs.groupByDate) {
                    app.updateListPreferences { $0.groupByDate = false }
                }
            } label: {
                Label("Group By Date", systemImage: "calendar")
            }
            .disabled(prefs.sortBy.usesTitleOrder)

            if !isAllNotes, !PathPolicy.isInbox(folder) {
                Divider()
                Button {
                    namingFolder = true
                } label: {
                    Label("New Subfolder…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityIdentifier("list.more")
    }

    private func sortOptionButton(_ label: String, field: NoteSortField) -> some View {
        Button {
            app.updateListPreferences { p in
                p.sortBy = field
                if field == .defaultEdited {
                    p.newestFirst = true
                }
            }
        } label: {
            if prefs.sortBy == field {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func directionButton(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var listContent: some View {
        List {
            if router.usesStack, !isSelectingNotes, !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { FolderRow(node: $0) }
                }
            }
            if !sortedPinnedNotes.isEmpty {
                Section {
                    if !prefs.pinnedCollapsed {
                        ForEach(sortedPinnedNotes) { note in
                            rowForNote(note)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            app.updateListPreferences { $0.pinnedCollapsed.toggle() }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Pinned")
                            Spacer()
                            Image(systemName: prefs.pinnedCollapsed ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("list.pinned.toggle")
                }
            }
            if usesDateBuckets {
                ForEach(dateBuckets) { bucket in
                    Section(bucket.title) {
                        ForEach(bucket.notes) { note in
                            rowForNote(note)
                        }
                    }
                }
            } else if !sortedUnpinnedNotes.isEmpty {
                Section("Notes") {
                    ForEach(sortedUnpinnedNotes) { note in
                        rowForNote(note)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: notes.map { "\($0.path):\($0.isPinned)" })
        .noteListStyle()
        .overlay {
            if loaded, notes.isEmpty, (subfolders.isEmpty || !router.usesStack) {
                ContentUnavailableView(
                    "No notes",
                    systemImage: "note.text",
                    description: Text(isAllNotes ? "Create a note to get started." : "This folder reaches GitHub with its first note.")
                )
            }
        }
    }

    @ViewBuilder
    private func rowForNote(_ note: IndexedNote) -> some View {
        if isSelectingNotes {
            let checked = selectedOnPhone.contains(note.path)
            PhoneSelectableNoteRow(
                note: note,
                status: app.status(of: note.path),
                isSelected: checked,
                showsFolderSubtitle: isAllNotes
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    if selectedOnPhone.contains(note.path) {
                        selectedOnPhone.remove(note.path)
                    } else {
                        selectedOnPhone.insert(note.path)
                    }
                }
            }
        } else {
            NoteLinkRow(note: note, showsFolderSubtitle: isAllNotes)
        }
    }

    private static func groupByDate(_ items: [IndexedNote], useCreatedDate: Bool = false, now: Date = Date()) -> [DateBucket] {
        guard !items.isEmpty else { return [] }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

        var order: [String] = []
        var grouped: [String: [IndexedNote]] = [:]
        for note in items {
            let timestamp = useCreatedDate ? (note.created ?? note.modified) : note.modified
            let bucket: String
            if let date = timestamp {
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
        if isAllNotes {
            notes = await s.store.index.notes(inFolder: nil)
            subfolders = []
        } else if PathPolicy.isInbox(folder) {
            // The Inbox is every spelling of `_inbox` at once: a sync can bring GitHub's `_Inbox` next to ours.
            notes = await s.store.index.inboxNotes()
            subfolders = Self.children(of: folder, in: app.folderTree)
        } else {
            notes = await s.store.index.notes(inFolder: folder)
            subfolders = folder.isEmpty ? [] : Self.children(of: folder, in: app.folderTree)
        }
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

    #if os(macOS)
    private func installMacKeyMonitor() {
        guard !router.usesStack, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard app.activePane == .list else { return event }
            guard let win = NSApp.keyWindow, win.sheets.isEmpty, !(win.firstResponder is NSText) else {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
                app.selectAllNotes(orderedVisiblePaths, router: router)
                return nil
            }
            if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
                let targets: [String]
                if !app.selectedNotePaths.isEmpty {
                    targets = orderedVisiblePaths.filter { p in app.selectedNotePaths.contains { sameBytes($0, p) } }
                } else if case let .note(single)? = router.detail {
                    targets = [single]
                } else {
                    targets = []
                }
                guard !targets.isEmpty else { return event }
                app.clearNoteSelection()
                router.detail = nil
                Task { await app.requestDelete(paths: targets) }
                return nil
            }
            return event
        }
    }

    private func removeMacKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif
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

private struct PhoneSelectableNoteRow: View {
    let note: IndexedNote
    let status: NoteSyncStatus
    let isSelected: Bool
    let showsFolderSubtitle: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                NoteRow(note: note, status: status, showsFolderSubtitle: showsFolderSubtitle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("select.\(note.path)")
    }
}

// MARK: - NoteLinkRow & Apple Notes Context Menus

/// A note row that opens the note, with Mac modifier multi-selection, Apple Notes context menus, and swipe actions.
struct NoteLinkRow: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.bnOrderedNotePaths) private var orderedPaths
    @Environment(\.bnRequestMoveNote) private var requestMoveNote
    @Environment(\.bnRequestShareNote) private var requestShareNote

    let note: IndexedNote
    var showsFolderSubtitle: Bool = false

    private var isSelectedOnMac: Bool {
        app.isNoteSelected(note.path, detailRoute: router.detail)
    }

    private var macSelectionState: RowSelectionState {
        guard isSelectedOnMac else { return .none }
        return app.activePane == .list ? .activeAccent : .inactiveNeutral
    }

    /// When right-clicking inside an active multi-selection on Mac, batch actions operate on all selected notes.
    private var contextTargetPaths: [String] {
        if !router.usesStack,
           app.selectedNotePaths.count > 1,
           app.selectedNotePaths.contains(where: { sameBytes($0, note.path) }) {
            let ordered = orderedPaths.filter { p in app.selectedNotePaths.contains { sameBytes($0, p) } }
            return ordered.isEmpty ? Array(app.selectedNotePaths) : ordered
        }
        return [note.path]
    }

    var body: some View {
        // Menu+preview on the row content — NOT on the NavigationLink wrapper.
        // Attaching a contextMenu preview to RouteLink/NavigationLink crashed on long-press.
        Group {
            if router.usesStack {
                RouteLink(.note(note.path)) {
                    rowWithContextMenu
                }
            } else {
                Button(action: handleMacRowClick) {
                    HStack(spacing: 0) {
                        rowWithContextMenu
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(MacSelectionPillModifier(selectionState: macSelectionState, isSidebar: false))
                .accessibilityAddTraits(isSelectedOnMac ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("note.\(note.path)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) { swipePinButton.tint(.orange) }
        .swipeActions(edge: .trailing) { swipeDeleteButton }
    }

    private var rowWithContextMenu: some View {
        NoteRow(note: note, status: app.status(of: note.path))
                .contextMenu {
                    contextMenuItems
                } preview: {
                    NotePeekPreview(note: note)
                }
                .environment(\.bnNoteShowsFolderSubtitle, showsFolderSubtitle)
    }

    private func handleMacRowClick() {
        #if os(macOS)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            app.selectNoteRange(to: note.path, orderedPaths: orderedPaths, additive: flags.contains(.command), router: router)
            return
        }
        if flags.contains(.command) {
            app.toggleNoteSelection(note.path, orderedPaths: orderedPaths, router: router)
            return
        }
        #endif
        app.selectSingleNote(note.path, router: router)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        #if os(iOS)
        ControlGroup {
            Button {
                Task {
                    let items = await app.cleanShareItems(for: [note.path])
                    if !items.isEmpty {
                        requestShareNote?(NoteSharePayload(items: items))
                    }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                requestMoveNote?(note.path)
            } label: {
                Label("Move", systemImage: "folder")
            }

            Button(role: .destructive) {
                Task { await app.requestDelete(paths: [note.path]) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        Button {
            Task { await app.togglePin(path: note.path) }
        } label: {
            Label(note.isPinned ? "Unpin Note" : "Pin Note", systemImage: note.isPinned ? "pin.slash" : "pin")
        }

        Button {
            Task { _ = await app.duplicateNotes(paths: [note.path]) }
        } label: {
            Label("Duplicate Note", systemImage: "plus.square.on.square")
        }
        #else
        let targets = contextTargetPaths
        let batch = targets.count > 1
        let anyUnpinned = targets.contains { !app.isPinned($0) }

        Button {
            Task { await app.setPinned(anyUnpinned, paths: targets) }
        } label: {
            if batch {
                Label(anyUnpinned ? "Pin \(targets.count) Notes" : "Unpin \(targets.count) Notes", systemImage: anyUnpinned ? "pin" : "pin.slash")
            } else {
                Label(note.isPinned ? "Unpin Note" : "Pin Note", systemImage: note.isPinned ? "pin.slash" : "pin")
            }
        }

        Divider()

        Button {
            let folder = SearchIndex.folder(of: note.path)
            let targetFolder: String? = (folder.isEmpty || PathPolicy.isInbox(folder)) ? nil : folder
            app.clearNoteSelection()
            app.activePane = .editor
            router.open(.compose(folder: targetFolder, id: UUID()))
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }

        Button {
            Task {
                let copies = await app.duplicateNotes(paths: targets)
                if copies.count == 1, let first = copies.first {
                    app.selectSingleNote(first, router: router)
                }
            }
        } label: {
            Label(batch ? "Duplicate \(targets.count) Notes" : "Duplicate Note", systemImage: "plus.square.on.square")
        }

        Divider()

        Button {
            let anchorPath = note.path
            Task {
                let items = await app.cleanShareItems(for: targets)
                MacShareAnchorRegistry.presentSharePicker(items: items, for: anchorPath)
            }
        } label: {
            Label("Share Note", systemImage: "square.and.arrow.up")
        }

        Divider()

        Menu {
            let singleCurrentFolder: String? = batch ? nil : SearchIndex.folder(of: note.path)
            Button {
                Task { _ = await app.moveNotes(paths: targets, toFolder: PathPolicy.inboxFolder) }
            } label: {
                Label("Inbox", systemImage: "tray")
            }
            .disabled(singleCurrentFolder.map(PathPolicy.isInbox) == true)

            Button {
                Task { _ = await app.moveNotes(paths: targets, toFolder: "") }
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .disabled(singleCurrentFolder == "")

            if !app.folders.isEmpty {
                Divider()
                NoteMoveSubmenuItems(nodes: app.folders, currentFolder: singleCurrentFolder) { dest in
                    Task {
                        let moved = await app.moveNotes(paths: targets, toFolder: dest)
                        if moved.count == 1, case .note = router.detail {
                            router.detail = nil
                        }
                    }
                }
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            if !router.usesStack {
                app.clearNoteSelection()
                if targets.contains(where: { p in
                    if case let .note(openPath)? = router.detail { return sameBytes(openPath, p) }
                    return false
                }) {
                    router.detail = nil
                }
            }
            Task { await app.requestDelete(paths: targets) }
        } label: {
            Label(batch ? "Delete \(targets.count) Notes" : "Delete", systemImage: "trash")
        }
        #endif
    }

    private var swipePinButton: some View {
        Button {
            Task { await app.togglePin(path: note.path) }
        } label: {
            Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash.fill" : "pin.fill")
        }
    }

    private var swipeDeleteButton: some View {
        Button(role: .destructive) {
            Task { await app.requestDelete(paths: [note.path]) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct NoteMoveSubmenuItems: View {
    let nodes: [FolderNode]
    let currentFolder: String?
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(nodes) { folderNode in
            let isCurrent = currentFolder.map { sameBytes($0, folderNode.path) } ?? false
            if folderNode.children.isEmpty {
                Button {
                    onSelect(folderNode.path)
                } label: {
                    Label(folderNode.name, systemImage: "folder")
                }
                .disabled(isCurrent)
            } else {
                Menu {
                    Button {
                        onSelect(folderNode.path)
                    } label: {
                        Label(folderNode.name, systemImage: "folder")
                    }
                    .disabled(isCurrent)
                    Divider()
                    NoteMoveSubmenuItems(nodes: folderNode.children, currentFolder: currentFolder, onSelect: onSelect)
                } label: {
                    Label(folderNode.name, systemImage: "folder")
                }
            }
        }
    }
}

private struct NoteShowsFolderSubtitleKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private extension EnvironmentValues {
    var bnNoteShowsFolderSubtitle: Bool {
        get { self[NoteShowsFolderSubtitleKey.self] }
        set { self[NoteShowsFolderSubtitleKey.self] = newValue }
    }
}

// MARK: - NoteRow & Apple Notes Date Formatting

enum AppleNotesDateFormat {
    static func rowString(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
           date >= sevenDaysAgo,
           date <= now {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func editorHeaderString(for date: Date, prefix: String? = nil) -> String {
        let dayPart = date.formatted(.dateTime.day().month(.wide).year())
        let timePart = date.formatted(date: .omitted, time: .shortened)
        let base = "\(dayPart) at \(timePart)"
        if let prefix {
            return "\(prefix): \(base)"
        }
        return base
    }
}

struct NoteRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.bnRowSelectionState) private var selectionState
    @Environment(\.bnNoteShowsFolderSubtitle) private var envShowsFolder
    let note: IndexedNote
    let status: NoteSyncStatus
    var showsFolderSubtitle: Bool = false
    /// Keeps the dot level with the title's first line at every text size.
    @ScaledMetric(relativeTo: .headline) private var dotTop: CGFloat = 6

    private var activeSelected: Bool {
        selectionState == .activeAccent
    }

    private var displayDate: Date? {
        app.listPreferences.sortBy == .dateCreated ? (note.created ?? note.modified) : note.modified
    }

    private var folderDisplayName: String? {
        guard showsFolderSubtitle || envShowsFolder else { return nil }
        if note.folder.isEmpty { return "Notes" }
        if PathPolicy.isInbox(note.folder) { return "Inbox" }
        return note.folder.split(separator: "/").last.map(String.init) ?? note.folder
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if status != .synced {
                StatusDot(status: status, onAccent: activeSelected)
                    .padding(.top, dotTop)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.title)
                        .font(.headline)
                        .foregroundStyle(activeSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(activeSelected ? Color.white : Color.orange)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                            .accessibilityLabel("Pinned")
                    }
                }
                .animation(.snappy(duration: 0.22, extraBounce: 0.08), value: note.isPinned)
                if note.isConflictCopy {
                    Label("Conflict copy", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(activeSelected ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(.tint))
                }
                detail
                    .font(.subheadline)
                    .foregroundStyle(activeSelected ? Color.white.opacity(0.86) : Color.secondary)
                    .lineLimit(1)
                if let folderName = folderDisplayName {
                    Label(folderName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(activeSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole text block follows the note's language; the dot stays where it is.
            .paragraphDirection(rightToLeft: NoteText.isRightToLeft(note.title))
        }
        .padding(.vertical, 2)
        #if os(macOS)
        .background(MacRowShareAnchor(notePath: note.path))
        #endif
        .accessibilityElement(children: .combine)
    }

    /// Compact Apple Notes date (`7:16` / `Yesterday` / `Sunday` / `04/11/2026`), followed by the clean single-line snippet.
    private var detail: Text {
        let snippet = note.snippet.isEmpty ? "No additional text" : note.snippet
        guard let date = displayDate else { return Text(verbatim: snippet) }
        let formattedDate = AppleNotesDateFormat.rowString(for: date)
        let mark = NoteText.isRightToLeft(note.title) ? "\u{200F}" : ""
        return Text(verbatim: "\(mark)\(formattedDate)  \(snippet)")
    }
}

/// The per-note state as a dot when unsynced/syncing/needs-attention (synced notes stay clean like Apple Notes).
struct StatusDot: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    let status: NoteSyncStatus
    var onAccent: Bool = false

    var body: some View {
        Group {
            if withoutColor {
                Image(systemName: status.shapeSymbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(onAccent ? Color.white : color)
            } else {
                Circle()
                    .fill(onAccent ? Color.white : color)
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
    @Environment(\.bnRowSelectionState) private var selectionState
    let query: String
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        List(hits) { hit in
            RouteLink(.note(hit.path), pane: .list) {
                SearchResultRow(hit: hit)
            }
            .accessibilityIdentifier("search.\(hit.path)")
        }
        .noteListStyle()
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

private struct SearchResultRow: View {
    @Environment(\.bnRowSelectionState) private var selectionState
    let hit: SearchHit

    private var activeSelected: Bool { selectionState == .activeAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Highlighted(hit.title, onAccent: activeSelected)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paragraphDirection(rightToLeft: NoteText.isRightToLeft(hit.title))
            Highlighted(hit.snippet, onAccent: activeSelected)
                .font(.subheadline)
                .foregroundStyle(activeSelected ? Color.white.opacity(0.86) : Color.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paragraphDirection(rightToLeft: NoteText.isRightToLeft(hit.snippet))
            Text(SearchIndex.folder(of: hit.path).isEmpty ? "Notes" : SearchIndex.folder(of: hit.path))
                .font(.caption)
                .foregroundStyle(activeSelected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text with the index's match markers turned into emphasis.
struct Highlighted: View {
    private let text: AttributedString

    init(_ marked: String, onAccent: Bool = false) {
        var out = AttributedString()
        var inside = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if inside {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = onAccent ? .white : .accentColor
            } else if onAccent {
                piece.foregroundColor = .white
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
