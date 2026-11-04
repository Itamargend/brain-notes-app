import BrainNotesKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(AppModel.onboardedKey) private var onboarded = false

    var body: some View {
        @Bindable var app = app
        Group {
            // One branch for the whole flow: it stays the same view from Connect through Ready, while the
            // phase goes from `.needsSignIn` to `.ready` under it.
            if app.showsOnboarding {
                OnboardingFlow(start: onboarded ? .connect : app.options.onboardingStep ?? .welcome)
                    .environment(\.layoutDirection, app.options.hebrew ? .rightToLeft : layoutDirection)
            } else {
                switch app.phase {
                case .loading, .needsSignIn:
                    ProgressView().accessibilityIdentifier("loading")
                case let .misconfigured(message), let .failed(message):
                    ContentUnavailableView("Brain Notes can't open", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    if router.usesStack { StackRoot() } else { SplitRoot() }
                }
            }
        }
        .sheet(isPresented: $app.showSignIn) {
            NavigationStack {
                SignInView()
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 620)
            #endif
        }
    }
}

/// iPhone: one column, pushed screens.
private struct StackRoot: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            FoldersView()
                // The id gives each route its own screen state: a reused screen would show the previous note.
                .navigationDestination(for: Route.self) { RouteScreen(route: $0).id($0) }
        }
    }
}

/// Mac: sidebar, list, note.
private struct SplitRoot: View {
    @Environment(Router.self) private var router

    var body: some View {
        NavigationSplitView {
            FoldersView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            Group {
                if let route = router.content {
                    RouteScreen(route: route).id(route)
                } else {
                    ContentUnavailableView("Choose a folder", systemImage: "folder")
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            Group {
                if let route = router.detail {
                    RouteScreen(route: route).id(route)
                } else {
                    ContentUnavailableView("No note selected", systemImage: "note.text")
                }
            }
        }
    }
}

struct RouteScreen: View {
    let route: Route

    var body: some View {
        switch route {
        case let .folder(path):
            NoteListView(folder: path, title: path.split(separator: "/").last.map(String.init) ?? path)
        case .inbox:
            NoteListView(folder: PathPolicy.inboxFolder, title: "Inbox")
        case let .note(path):
            NoteScreen(path: path)
        case let .compose(folder, _):
            NoteScreen(newNoteIn: folder)
        case .attention:
            AttentionListView()
        case let .attentionItem(id):
            AttentionDetailView(id: id)
        case .settings:
            SettingsView()
        }
    }
}

/// A row that navigates: a `NavigationLink` in the stack, a plain button that fills a column on Mac.
struct RouteLink<Label: View>: View {
    @Environment(Router.self) private var router
    let route: Route
    @ViewBuilder let label: () -> Label

    init(_ route: Route, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.label = label
    }

    var body: some View {
        if router.usesStack {
            NavigationLink(value: route, label: label)
        } else {
            Button {
                router.open(route)
            } label: {
                HStack(spacing: 0) {
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
            // The tint shows the open row; VoiceOver hears it too.
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var isSelected: Bool { router.content == route || router.detail == route }
}

/// Text aligned by its own first strong character, whatever the app's layout direction.
extension View {
    func paragraphDirection(rightToLeft: Bool) -> some View {
        environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }
}

extension ToolbarItemPlacement {
    /// Trailing on iPhone, the usual place on Mac.
    static var trailingAction: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}
