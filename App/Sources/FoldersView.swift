import BrainNotesKit
import SwiftUI

/// Home: Needs attention, Inbox, Folders, Notes. Search replaces the list while a query is typed.
struct FoldersView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var query = LaunchOptions.current.screen == "search" ? "local" : ""

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
            ToolbarItem(placement: .navigation) {
                SyncPill()
            }
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
        }
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
    @ViewBuilder func platformGroupedList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.sidebar)
        #endif
    }
}

struct CountRow: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24)
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
    let node: FolderNode

    var body: some View {
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

    private var link: some View {
        RouteLink(.folder(node.path)) {
            CountRow(title: node.name, systemImage: "folder", count: node.totalCount)
        }
        .accessibilityIdentifier("folder.\(node.path)")
    }
}

/// The global sync state, in plain words.
struct SyncPill: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            tapped()
        } label: {
            HStack(spacing: 5) {
                if app.snapshot.state.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).foregroundStyle(tint)
                }
                Text(text)
                    .font(.footnote)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sync.pill")
        .accessibilityLabel(text)
    }

    private func tapped() {
        switch app.snapshot.state {
        case .signedOut:
            app.showSignIn = true
        case .needsAttention:
            router.open(.attention)
        case .offline, .retrying, .idle:
            Task { await app.syncNow() }
        default:
            router.open(.settings)
        }
    }

    private var unsyncedSuffix: String {
        let n = app.snapshot.unsynced
        return n > 0 ? " · \(n) unsynced" : ""
    }

    private var text: String {
        switch app.snapshot.state {
        case .idle:
            if app.snapshot.unsyncedTooLong(now: Date()) { return "Unsynced for over a day" }
            return app.snapshot.unsynced > 0 ? "\(app.snapshot.unsynced) unsynced" : "Synced"
        case .checking: return "Checking"
        case .pulling: return "Getting changes"
        case .merging: return "Merging"
        case .applying: return "Updating"
        case .pushing: return "Sending"
        case .verifying: return "Verifying"
        case let .firstSync(phase):
            switch phase {
            case .downloading: return "Downloading notes"
            case let .verifying(done, total): return "Checking \(done) of \(total)"
            case let .indexing(done, total): return "Indexing \(done) of \(total)"
            }
        case let .needsAttention(n):
            return "\(n) need\(n == 1 ? "s" : "") attention" + unsyncedSuffix
        case .signedOut:
            return "Sign in again"
        case .paused(.user):
            return "Sync paused"
        case let .paused(.rateLimited(until)):
            if let until { return "Sync paused until \(until.formatted(date: .omitted, time: .shortened))" }
            return "Sync paused for now"
        case .offline:
            return "Offline" + unsyncedSuffix
        case .retrying:
            return "Trying again soon" + unsyncedSuffix
        case .accessLost:
            return "Can't reach the brain repo"
        }
    }

    private var icon: String {
        switch app.snapshot.state {
        case .idle: return app.snapshot.unsynced > 0 ? "arrow.up.circle" : "checkmark.circle"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .signedOut: return "person.crop.circle.badge.exclamationmark"
        case .paused: return "pause.circle"
        case .offline: return "wifi.slash"
        case .retrying: return "clock.arrow.circlepath"
        case .accessLost: return "lock.slash"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch app.snapshot.state {
        case .needsAttention, .signedOut, .accessLost: return .red
        case .idle where app.snapshot.unsyncedTooLong(now: Date()): return .red
        default: return .secondary
        }
    }
}
