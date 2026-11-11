import BrainNotesKit
import SwiftUI
import os

/// One open note: what is on screen, what was last saved, and the autosave.
@MainActor @Observable
final class NoteEditorModel {
    private(set) var path: String?
    let newNoteFolder: String?
    /// Frontmatter is never shown and never changed: it is put back in front of the body on every save.
    private(set) var prefix = ""
    private(set) var body = ""
    /// The whole text this editing session is based on: the merge base if a sync moves the note meanwhile.
    private(set) var base: String?
    private(set) var blocks: [MarkdownBlock] = []
    var isEditing: Bool
    /// A cell tapped in the note view: the editor opens with the focus there.
    var startCell: TableCellAddress?
    /// Bumps when the text changed from outside the editor (a sync), so the text view reloads it.
    private(set) var externalRevision = 0
    private(set) var missing = false
    private(set) var loaded = false
    /// The last save failed (disk full). The text stays on screen and the next save tries again.
    private(set) var saveFailed = false
    private var pending: Task<Void, Never>?
    /// The save running now. A new save waits for it: two saves running together could finish out of
    /// order and leave older text on disk, or create a new note twice.
    private var saving: Task<Void, Never>?
    private var hasUnsaved = false
    /// Counts keystrokes, so a disk read that started before one can tell it is out of date.
    private var edits = 0
    private let log = Logger(subsystem: "com.itamargendelman.brainnotes", category: "editor")

    init(path: String?, newNoteFolder: String?, isEditing: Bool) {
        self.path = path
        self.newNoteFolder = newNoteFolder
        self.isEditing = isEditing
    }

    private func decode(_ text: String) {
        let (fm, rest) = NoteText.split(text)
        prefix = fm
        body = rest
        blocks = MarkdownBlock.parse(rest)
    }

    func load(_ app: AppModel) async {
        guard let s = app.session else { return }
        defer { loaded = true }
        guard let path else { return }
        let text = await Task.detached { (try? s.store.read(path)) ?? nil }.value
        guard let text else {
            missing = true
            return
        }
        decode(text)
        base = text
    }

    /// The user typed. Saves after a short pause.
    func userEdited(_ newBody: String, app: AppModel) {
        guard !sameBytes(newBody, body) else { return }
        body = newBody
        hasUnsaved = true
        edits += 1
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await self?.saveNow(app)
        }
    }

    /// The durable step, off the main thread. Saves run one after the other, each with the newest text.
    func saveNow(_ app: AppModel) async {
        pending?.cancel()
        pending = nil
        let previous = saving
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSave(app)
        }
        saving = task
        await task.value
    }

    private func performSave(_ app: AppModel) async {
        guard hasUnsaved, let s = app.session else { return }
        hasUnsaved = false
        let text = prefix + body
        let currentPath = path
        let folder = newNoteFolder
        let editingFrom = base
        do {
            let saved: String? = try await Task.detached { () -> String? in
                if let currentPath {
                    return try s.store.save(path: currentPath, text: text, editingFrom: editingFrom)
                }
                // A new note starts existing with its first non-empty text.
                if text.allSatisfy(\.isWhitespace) { return nil }
                return try s.store.createNote(folder: folder, text: text)
            }.value
            if let saved {
                path = saved
                base = text
            }
            saveFailed = false
            await app.noteSaved()
        } catch {
            hasUnsaved = true
            saveFailed = true
            log.error("save failed")
        }
    }

    /// Leaving the note: everything typed is saved first.
    func finish(_ app: AppModel) async {
        await saveNow(app)
        // A new note left empty never existed; an emptied existing note stays as it is.
        app.leftNote()
    }

    func setEditing(_ editing: Bool, app: AppModel) {
        if !editing {
            blocks = MarkdownBlock.parse(body)
            Task { await finish(app) }
        }
        isEditing = editing
    }

    /// A sync changed this note on disk. An unedited note refreshes in place; with text being typed the
    /// disk version waits, and the next save merges against the text this session started from.
    func syncChangedNote(_ app: AppModel) async {
        // A save on its way to disk: reading now would bring older text back into the editor.
        await saving?.value
        guard let s = app.session, let path, !hasUnsaved else { return }
        let before = edits
        let text = await Task.detached { (try? s.store.read(path)) ?? nil }.value
        // Typing started during the read: this text is the disk's, not the editor's. The next save merges.
        guard edits == before, !hasUnsaved else { return }
        guard let text else {
            missing = true
            return
        }
        missing = false
        if !sameBytes(text, prefix + body) {
            decode(text)
            externalRevision += 1
        }
        base = text
    }

    func moved(to newPath: String) {
        path = newPath
    }
}

/// The note screen: rendered view, tap to edit, status icon, conflict banner.
struct NoteScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var model: NoteEditorModel
    /// A format tool pressed while the Mac note is still the reading view. The editor applies it as it opens.
    @State private var pendingFormat: EditorAction?

    init(path: String, startEditing: Bool = LaunchOptions.current.screen == "edit" || LaunchOptions.current.screen == "live" || LaunchOptions.current.screen == "table" || LaunchOptions.current.isEditorSpike) {
        _model = State(initialValue: NoteEditorModel(path: path, newNoteFolder: nil, isEditing: startEditing))
    }

    init(newNoteIn folder: String?) {
        _model = State(initialValue: NoteEditorModel(path: nil, newNoteFolder: folder, isEditing: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            saveProblem
            if LaunchOptions.current.isEditorSpike { StyleTimingLine() }
            if let path = model.path { NoteBanner(path: path) }
            if !model.loaded {
                // Never an empty editor over a note that hasn't loaded: typing there would replace it.
                Spacer()
            } else if model.missing {
                ContentUnavailableView("This note is gone", systemImage: "note.text.badge.plus",
                                       description: Text("It was deleted or moved. Anything unsynced was kept in Inbox."))
            } else if model.isEditing {
                MarkdownTextView(
                    text: model.body,
                    externalRevision: model.externalRevision,
                    startCell: model.startCell,
                    startAction: pendingFormat,
                    onDidApplyStartAction: { pendingFormat = nil },
                    onEdit: { model.userEdited($0, app: app) }
                )
                .accessibilityIdentifier("note.editor")
                #if os(iOS)
                // On under the keyboard and its bar, or their glass has only black behind it and no note to show. The
                // text view makes room for them itself: `Coordinator.keyboardMoved`.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                #endif
            } else {
                viewer
            }
        }
        .navigationTitle(model.path == nil ? "New note" : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .brainSurface(.editor)
        #if os(macOS)
        .focusedSceneValue(\.editorIsOpen, model.isEditing)
        #endif
        .task {
            await model.load(app)
        }
        .onAppear { app.editorAppeared(model) }
        .onChange(of: app.changeTick) { _, _ in
            if let m = app.moved, let path = model.path, sameBytes(m.from, path) {
                model.moved(to: m.to)
            }
            if let path = model.path, app.changedPaths.contains(where: { sameBytes($0, path) }) {
                Task { await model.syncChangedNote(app) }
            }
        }
        .onDisappear {
            app.editorDisappeared(model)
            Task { await model.finish(app) }
        }
    }

    /// A failed save stays in words as well: it asks the user to do something.
    @ViewBuilder private var saveProblem: some View {
        if model.saveFailed {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Couldn't save on this device. Keep this screen open and free up some space.")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("note.saveProblem")
        }
    }

    private var statusBadge: StatusBadge {
        var offline = false
        if case .offline = app.snapshot.state { offline = true }
        return .note(status: model.path.map(app.status(of:)) ?? .synced, offline: offline, saveFailed: model.saveFailed, isNew: model.path == nil)
    }

    private var viewer: some View {
        ScrollView {
            MarkdownView(blocks: model.blocks, onTapText: {
                model.startCell = nil
                model.setEditing(true, app: app)
            }, onTapCell: { cell in
                model.startCell = cell
                model.setEditing(true, app: app)
            })
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            // The empty space under the text starts editing too.
            Color.clear
                .frame(height: 200)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.startCell = nil
                    model.setEditing(true, app: app)
                }
        }
        #if os(iOS)
        .preferredColorScheme(.dark)
        #endif
        .brainSurface(.editor)
        .accessibilityIdentifier("note.viewer")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .statusIcon) {
            StatusIconButton(badge: statusBadge, identifier: "note.status") {
                if let path = model.path, let date = app.session?.store.journal.file(path)?.modified {
                    Text("Changed \(Text(date, format: .relative(presentation: .named)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        #if os(macOS)
        // Visible whenever the note is open, reading or editing. ToolbarItemGroup lets a narrow window
        // park the extra tools in the overflow. The pencil still switches to editing; it is not what reveals the tools.
        if model.loaded, !model.missing {
            ToolbarItemGroup(placement: .automatic) {
                EditorToolbarButtons(perform: applyFormat)
            }
        }
        #endif
        ToolbarItem(placement: .trailingAction) {
            if model.isEditing {
                Button {
                    model.setEditing(false, app: app)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .accessibilityIdentifier("note.done")
            } else {
                Button {
                    model.startCell = nil
                    model.setEditing(true, app: app)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .accessibilityIdentifier("note.edit")
            }
        }
        if let path = model.path {
            ToolbarItem(placement: .trailingAction) {
                Menu {
                    Button(role: .destructive) {
                        Task {
                            await app.requestDelete(paths: [path])
                            router.replaceTop(with: nil)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("note.delete")
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("note.more")
            }
        }
    }

    #if os(macOS)
    /// From the reading view, a tool opens the editor and then runs. While editing, it goes straight to the text view.
    private func applyFormat(_ action: EditorAction) {
        if model.isEditing {
            EditorActionSender.send(action)
        } else {
            pendingFormat = action
            model.startCell = nil
            model.setEditing(true, app: app)
        }
    }
    #endif
}

/// What the note's open Needs attention items mean, right where it matters.
struct NoteBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    let path: String
    @State private var items: [AttentionItem] = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    router.open(.attentionItem(item.id))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "doc.on.doc").foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(item.bannerText)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Compare").foregroundStyle(.tint)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.tint.opacity(0.1))
                .accessibilityIdentifier("note.banner")
            }
        }
        .task(id: app.revision) {
            guard let s = app.session else { return }
            let journal = s.store.journal
            let path = self.path
            items = await Task.detached { journal.attention(forPath: path) }.value
        }
    }
}

extension AttentionItem {
    var bannerText: String {
        switch reason {
        case "conflict-copy":
            if detail == "deleted-remotely" { return "Deleted elsewhere. Your text was saved in Inbox." }
            return "Merged. Your version of a section was saved as a copy in Inbox."
        case "delete-skipped":
            return "Not deleted: this note changed on GitHub."
        case "case-clash":
            return "Another note has almost the same name, and this device can't hold both side by side."
        case "unstorable":
            return "This note's name is too long for this device. It stays on GitHub."
        case "too-large":
            return "This note is over 1 MiB, too large to open here. It stays on GitHub."
        case "rejected", "push-failed":
            return "This note hasn't reached GitHub yet."
        default:
            if reason.hasPrefix("blocked:secret") { return "Not synced: this note contains what looks like a secret." }
            if reason.hasPrefix("blocked:too-large") { return "Not synced: this note is over 1 MiB." }
            if reason.hasPrefix("blocked:") { return "Not synced: this name or folder can't go to GitHub." }
            return "This note needs a look."
        }
    }
}
