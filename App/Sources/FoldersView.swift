import BrainNotesKit
import SwiftUI

/// Home: Needs attention, Inbox, Folders, Notes. Search replaces the list while a query is typed.
struct FoldersView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var query = LaunchOptions.current.screen == "search" ? "swiftui" : ""
    @State private var namingFolder = false

    var body: some View {
        Group {
            if query.isEmpty {
                list
            } else {
                SearchResultsView(query: query)
            }
        }
        .navigationTitle("Folders")
        .searchable(text: $query, prompt: "Search")
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
            ToolbarItem(placement: .trailingAction) {
                Button {
                    router.open(.compose(folder: nil, id: UUID()))
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("compose.button")
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
        .newFolderPrompt(isPresented: $namingFolder, parent: "")
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
            Section("Inbox") {
                RouteLink(.inbox) {
                    CountRow(title: "Inbox", systemImage: "tray", count: app.inboxCount)
                }
                .accessibilityIdentifier("home.inbox")
            }
            if !app.folders.isEmpty {
                Section("Folders") {
                    ForEach(app.folders) { FolderRow(node: $0) }
                }
            }
            if !app.rootNotes.isEmpty {
                Section("Notes") {
                    ForEach(app.rootNotes) { note in
                        NoteLinkRow(note: note)
                    }
                }
            }
        }
        .platformGroupedList()
        .overlay {
            if app.folders.isEmpty, app.rootNotes.isEmpty, app.inboxCount == 0, app.snapshot.state.isBusy {
                ProgressView("Getting your notes")
            }
        }
        .accessibilityIdentifier("home.list")
    }
}

extension View {
    /// Apple-Notes-style grouped cards on iPhone; the sidebar look in the Mac's first column.
    func platformGroupedList() -> some View {
        #if os(iOS)
        return listStyle(.insetGrouped).brainBlackList()
        #else
        return listStyle(.sidebar).brainBlackList()
        #endif
    }
}

struct CountRow: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let count: Int
    /// The icon column grows with the text, so titles stay lined up at large sizes.
    @ScaledMetric private var iconWidth: CGFloat = 24

    var body: some View {
        HStack {
            // The title says it: VoiceOver would otherwise read "tray, Inbox" or "folder, Projects".
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
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
    /// Loaded for the peek only — the preview itself never touches AppModel.
    @State private var peekNotes: [IndexedNote] = []

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
        .alert(
            "Delete \(node.totalCount) \(node.totalCount == 1 ? "note" : "notes") in \(node.name)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { await app.requestDeleteFolder(path: node.path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will swirl away. You can Undo for a few seconds after.")
        }
        .task(id: node.path) { await loadPeekNotes() }
    }

    private var link: some View {
        // Menu+preview on the row content inside the link — not on DisclosureGroup / RouteLink.
        RouteLink(.folder(node.path)) {
            CountRow(title: node.name, systemImage: "folder", count: node.totalCount)
                .contextMenu {
                    if node.totalCount > 0 {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
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
        case .paused, .accessLost:
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
