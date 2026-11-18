import BrainNotesKit
import SwiftUI

/// Home: Needs attention, All Notes, Inbox, Folders, Notes.
struct FoldersView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var query = LaunchOptions.current.screen == "search" ? "books" : ""
    @State private var namingFolder = false
    @State private var movingNotePath: String?
    @State private var sharingPayload: NoteSharePayload?

    var body: some View {
        Group {
            if router.usesStack, !query.isEmpty {
                SearchResultsView(query: query)
            } else {
                list
            }
        }
        .navigationTitle("Folders")
        .modifier(PhoneFolderSearchableModifier(enabled: router.usesStack, query: $query))
        .toolbar {
            ToolbarItem(placement: .statusIcon) {
                SyncStatusButton()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .trailingAction) {
                Button {
                    router.open(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings.button")
            }
            #if os(macOS)
            if router.usesStack || router.content == nil {
                ToolbarItem(placement: .trailingAction) {
                    Button {
                        router.open(.compose(folder: nil, id: UUID()))
                    } label: {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("compose.button")
                }
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
                    router.open(.compose(folder: nil, id: UUID()))
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("compose.button")
            }
            #endif
        }
        .newFolderPrompt(isPresented: $namingFolder, parent: "")
        .noteContextSheets(movingNotePath: $movingNotePath, sharingPayload: $sharingPayload)
        .environment(\.bnRequestMoveNote, { path in movingNotePath = path })
        .environment(\.bnRequestShareNote, { payload in sharingPayload = payload })
    }

    private var list: some View {
        List {
            if app.snapshot.attention > 0 {
                Section {
                    RouteLink(.attention) {
                        CountRow(title: "Needs attention", systemImage: "exclamationmark.circle.fill", tint: .red, count: app.snapshot.attention)
                    }
                    .accessibilityIdentifier("home.attention")
                }
            }
            Section(router.usesStack ? "Inbox" : "Notes") {
                RouteLink(.allNotes) {
                    CountRow(title: "All Notes", systemImage: "folder", count: app.noteCount)
                }
                .accessibilityIdentifier("home.allNotes")

                RouteLink(.inbox) {
                    CountRow(title: "Inbox", systemImage: "tray", count: app.inboxCount)
                }
                .accessibilityIdentifier("home.inbox")

                if !router.usesStack {
                    RouteLink(.rootNotes) {
                        CountRow(title: "Notes", systemImage: "note.text", count: app.rootNotes.count)
                    }
                    .accessibilityIdentifier("home.rootNotes")
                }
            }
            if router.usesStack {
                let pinnedRoot = app.rootNotes.filter(\.isPinned)
                if !pinnedRoot.isEmpty {
                    Section("Pinned") {
                        ForEach(pinnedRoot) { note in
                            NoteLinkRow(note: note)
                        }
                    }
                }
            }
            if !app.folders.isEmpty {
                Section("Folders") {
                    ForEach(app.folders) { FolderRow(node: $0) }
                }
            }
            if router.usesStack {
                let unpinnedRoot = app.rootNotes.filter { !$0.isPinned }
                if !unpinnedRoot.isEmpty {
                    Section("Notes") {
                        ForEach(unpinnedRoot) { note in
                            NoteLinkRow(note: note)
                        }
                    }
                }
            }
            if app.noteCount == 0, !app.snapshot.state.isBusy {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Write your first note", systemImage: "square.and.pencil")
                            .font(.headline)
                        Text("Your private notes space is empty and ready. Write a note here and Brain Notes will save it to GitHub.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Write First Note") {
                            router.open(.compose(folder: nil, id: UUID()))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("home.firstNote")
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: app.rootNotes.map { "\($0.path):\($0.isPinned)" })
        .platformGroupedList()
        .overlay {
            if app.folders.isEmpty, app.rootNotes.isEmpty, app.inboxCount == 0, app.snapshot.state.isBusy {
                ProgressView("Getting your notes")
            }
        }
        .accessibilityIdentifier("home.list")
    }
}

private struct PhoneFolderSearchableModifier: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, prompt: "Search")
        } else {
            content
        }
    }
}

extension View {
    /// Apple-Notes-style grouped cards on iPhone; the sidebar look in the Mac's first column.
    func platformGroupedList() -> some View {
        #if os(iOS)
        return listStyle(.insetGrouped).brainBlackList()
        #else
        return listStyle(.sidebar)
            .brainSurface(.sidebar)
        #endif
    }
}

struct CountRow: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bnRowSelectionState) private var selectionState
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let count: Int
    /// The icon column grows with the text, so titles stay lined up at large sizes.
    @ScaledMetric private var iconWidth: CGFloat = 24

    private var activeSelected: Bool {
        selectionState == .activeAccent
    }

    private var titleInk: Color {
        if activeSelected { return .white }
        return scheme == .dark ? Color.white.opacity(0.93) : Color.primary
    }

    private var countInk: Color {
        if activeSelected { return Color.white.opacity(0.9) }
        return scheme == .dark ? Color.white.opacity(0.58) : Color.secondary
    }

    var body: some View {
        HStack {
            // The title says it: VoiceOver would otherwise read "tray, Inbox" or "folder, Projects".
            Image(systemName: systemImage)
                .foregroundStyle(activeSelected ? Color.white : tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(activeSelected ? .medium : .regular)
                .foregroundStyle(titleInk)
                .lineLimit(1)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(countInk)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A folder, with its subfolders in a disclosure group.
struct FolderRow: View {
    @Environment(AppModel.self) private var app
    let node: FolderNode
    @State private var confirmDelete = false
    @State private var namingSubfolder = false
    @State private var renamingFolder = false
    @State private var renameInput = ""
    @State private var folderProblem: String?
    /// Loaded for the peek only — the preview itself never touches AppModel.
    @State private var peekNotes: [IndexedNote] = []

    private var currentParent: String {
        SearchIndex.folder(of: node.path)
    }

    var body: some View {
        Group {
            if node.children.isEmpty {
                link
            } else {
                DisclosureGroup {
                    ForEach(node.children) { FolderRow(node: $0) }
                } label: {
                    link
                }
            }
        }
        .newFolderPrompt(isPresented: $namingSubfolder, parent: node.path)
        .alert("Rename Folder", isPresented: $renamingFolder) {
            TextField("Folder Name", text: $renameInput)
            Button("Rename") {
                let typed = renameInput
                Task {
                    switch await app.renameFolder(path: node.path, to: typed) {
                    case .success:
                        break
                    case .failure(.noName):
                        folderProblem = "A folder needs a name."
                    case .failure(.alreadyExists):
                        folderProblem = "There is already a folder with that name here."
                    case .failure(.notAllowed):
                        folderProblem = "That name can't sync to GitHub. Names can't start with a dot or an underscore, end in .md, or be private."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            node.totalCount == 0
                ? "Delete empty folder “\(node.name)”?"
                : "Delete \(node.totalCount) \(node.totalCount == 1 ? "note" : "notes") in \(node.name)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { await app.requestDeleteFolder(path: node.path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if node.totalCount > 0 {
                Text("You can Undo for a few seconds after.")
            }
        }
        .alert("Can't Update Folder", isPresented: Binding(get: { folderProblem != nil }, set: { if !$0 { folderProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderProblem ?? "")
        }
        .task(id: node.path) { await loadPeekNotes() }
    }

    private var link: some View {
        // Menu+preview on the row content inside the link — not on DisclosureGroup / RouteLink.
        RouteLink(.folder(node.path)) {
            CountRow(title: node.name, systemImage: "folder", count: node.totalCount)
                .contextMenu {
                    Button {
                        namingSubfolder = true
                    } label: {
                        Label("New Subfolder…", systemImage: "folder.badge.plus")
                    }

                    Button {
                        renameInput = node.name
                        renamingFolder = true
                    } label: {
                        Label("Rename Folder…", systemImage: "pencil")
                    }

                    Menu {
                        Button {
                            Task { _ = await app.moveFolder(path: node.path, into: "") }
                        } label: {
                            Label("Top Level", systemImage: "folder")
                        }
                        .disabled(currentParent.isEmpty)

                        if !app.folders.isEmpty {
                            Divider()
                            FolderMoveSubmenuItems(
                                nodes: app.folders,
                                movingFolderPath: node.path,
                                currentParent: currentParent
                            ) { dest in
                                Task { _ = await app.moveFolder(path: node.path, into: dest) }
                            }
                        }
                    } label: {
                        Label("Move Folder to", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } preview: {
                    FolderPeekPreview(node: node, notes: peekNotes)
                }
        }
        .accessibilityIdentifier("folder.\(node.path)")
    }

    private func loadPeekNotes() async {
        guard let s = app.session else {
            peekNotes = []
            return
        }
        peekNotes = await s.store.index.notes(inFolder: node.path)
    }
}

private struct FolderMoveSubmenuItems: View {
    let nodes: [FolderNode]
    let movingFolderPath: String
    let currentParent: String
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(nodes) { candidate in
            let isSelfOrInside = sameBytes(candidate.path, movingFolderPath) || candidate.path.hasPrefix(movingFolderPath + "/")
            if !isSelfOrInside {
                if candidate.children.isEmpty {
                    Button {
                        onSelect(candidate.path)
                    } label: {
                        Label(candidate.name, systemImage: "folder")
                    }
                    .disabled(sameBytes(candidate.path, currentParent))
                } else {
                    Menu {
                        Button {
                            onSelect(candidate.path)
                        } label: {
                            Label("Move into “\(candidate.name)”", systemImage: "folder")
                        }
                        .disabled(sameBytes(candidate.path, currentParent))
                        Divider()
                        FolderMoveSubmenuItems(
                            nodes: candidate.children,
                            movingFolderPath: movingFolderPath,
                            currentParent: currentParent,
                            onSelect: onSelect
                        )
                    } label: {
                        Label(candidate.name, systemImage: "folder")
                    }
                }
            }
        }
    }
}

/// The whole device's sync state as an icon. A tap says what it means and offers what can be done about it.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        StatusIconButton(badge: .sync(app.snapshot, now: Date()), identifier: "sync.pill", action: action) {
            EmptyView()
        }
    }

    private var action: StatusAction? {
        switch app.snapshot.state {
        case .signedOut:
            StatusAction(title: "Sign In Again") { app.showSignIn = true }
        case .needsAttention:
            StatusAction(title: "Open Needs Attention") { router.open(.attention) }
        case .offline, .retrying, .idle:
            StatusAction(title: "Sync Now") { Task { await app.syncNow() } }
        case .paused, .accessLost, .publicRepo, .repoTooLarge:
            StatusAction(title: "Open Settings") { router.open(.settings) }
        default:
            nil
        }
    }
}

/// New Folder: asks for a name, makes the folder, and opens it so the first note is one tap away.
private struct NewFolderPrompt: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Binding var isPresented: Bool
    let parent: String
    @State private var name = ""
    @State private var problem: String?

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: $isPresented) {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("folder.new.name")
                Button("Create", action: create)
                    .accessibilityIdentifier("folder.new.create")
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text("It reaches GitHub with its first note.")
            }
            .alert("Can't Create This Folder", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }

    private func create() {
        let typed = name
        name = ""
        Task {
            switch await app.createFolder(named: typed, in: parent) {
            case let .success(path):
                router.open(.folder(path))
            case .failure(.noName):
                problem = "A folder needs a name."
            case .failure(.alreadyExists):
                problem = "There is already a folder with that name here."
            case .failure(.notAllowed):
                problem = "That name can't sync to GitHub. Names can't start with a dot or an underscore, end in .md, or be private."
            }
        }
    }
}

extension View {
    func newFolderPrompt(isPresented: Binding<Bool>, parent: String) -> some View {
        modifier(NewFolderPrompt(isPresented: isPresented, parent: parent))
    }
}
