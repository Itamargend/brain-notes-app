import BrainNotesKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(AppModel.onboardedKey) private var onboarded = false

    /// First-run is over when either the view's defaults or the model recorded it.
    private var finishedFirstRun: Bool {
        onboarded || app.defaults.bool(forKey: AppModel.onboardedKey)
    }

    var body: some View {
        @Bindable var app = app
        Group {
            // One branch for the whole flow: it stays the same view from Connect through Ready, while the
            // phase goes from `.needsSignIn` to `.ready` under it.
            if app.showsOnboarding {
                OnboardingFlow(start: finishedFirstRun ? .connect : app.options.onboardingStep ?? .welcome)
                    .environment(\.layoutDirection, app.options.hebrew ? .rightToLeft : layoutDirection)
            } else {
                switch app.phase {
                case .loading, .needsSignIn, .needsRepoSelection:
                    ProgressView().accessibilityIdentifier("loading")
                case let .failed(message):
                    ContentUnavailableView("Brain Notes can't open", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    if let issue = app.repoIssue {
                        RepoIssueView(issue: issue)
                    } else if app.isAwaitingOwnerVerificationAtLaunch {
                        ProgressView().accessibilityIdentifier("loading")
                    } else if router.usesStack {
                        StackRoot()
                    } else {
                        SplitRoot()
                    }
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
        .overlay {
            BlackHoleOverlay()
        }
    }
}

/// Shown when the previously selected repository is no longer in the user's GitHub App list or was made public.
/// Syncing is stopped; the user can retry (after making a public repository private again) or wipe and pick again.
private struct RepoIssueView: View {
    @Environment(AppModel.self) private var app
    let issue: AppModel.RepoIssue
    @State private var confirmChangeRepo = false
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            OnboardingPage(id: "repoIssue.view") {
                VStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 54))
                        .foregroundStyle(.red)
                        .padding(.top, 44)
                        .accessibilityHidden(true)
                    Text(issue.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(issue.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("repoIssue.message")
                }
            } bottom: {
                VStack(spacing: 12) {
                    if issue.allowsRetry {
                        Button("Try again") {
                            Task { await app.retryCurrentRepository() }
                        }
                        .buttonStyle(.onboarding(.accent))
                        .accessibilityIdentifier("repoIssue.retry")
                    }
                    if issue.offersSignIn {
                        Button("Sign in to verify") {
                            app.showSignIn = true
                        }
                        .buttonStyle(issue.allowsRetry ? .onboarding(.quiet) : .onboarding(.accent))
                        .accessibilityIdentifier("repoIssue.signIn")
                    } else if !issue.isAccountMismatch {
                        Button(chooseButtonTitle) {
                            Task {
                                if await app.checkUnsyncedBeforeRepoSwitch() {
                                    confirmChangeRepo = true
                                } else {
                                    await app.changeNotesRepository()
                                }
                            }
                        }
                        .buttonStyle(.onboarding(.quiet))
                        .accessibilityIdentifier("repoIssue.chooseNotes")
                    }
                    Button("Sign out and wipe", role: .destructive) {
                        confirmWipe = true
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                    .accessibilityIdentifier("repoIssue.wipe")
                }
            }
            .confirmationDialog("Unsynced changes on this device", isPresented: $confirmChangeRepo) {
                Button("Delete local copy and choose notes", role: .destructive) {
                    Task { await app.changeNotesRepository() }
                }
                .accessibilityIdentifier("repoIssue.chooseNotes.confirm")
            } message: {
                Text("Some notes on this device haven’t synced to GitHub yet. Choosing different notes deletes this local copy first.")
            }
            .confirmationDialog("Sign out and wipe this device?", isPresented: $confirmWipe) {
                Button("Sign out and wipe", role: .destructive) {
                    Task { await app.signOutAndWipe() }
                }
            } message: {
                Text("This can't be undone.")
            }
        }
        .tint(Color("AccentColor"))
    }

    private var symbol: String {
        switch issue {
        case .publicRepo:
            return "lock.trianglebadge.exclamationmark"
        case .truncated:
            return "exclamationmark.triangle.fill"
        case .unverifiedOwner, .accountCheckFailed, .accountMismatch:
            return "person.crop.circle.badge.exclamationmark"
        case .notListed:
            return "lock.slash"
        }
    }

    private var chooseButtonTitle: String {
        if case .publicRepo = issue {
            return "Choose different notes"
        }
        return "Choose your notes"
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
                #if os(macOS)
                .brainSurface(.sidebar)
                #endif
        } content: {
            Group {
                if let route = router.content {
                    RouteScreen(route: route).id(route)
                } else {
                    ContentUnavailableView("Choose a folder", systemImage: "folder")
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            #if os(macOS)
            .brainSurface(.list)
            #endif
        } detail: {
            Group {
                if let route = router.detail {
                    RouteScreen(route: route).id(route)
                } else {
                    ContentUnavailableView("No note selected", systemImage: "note.text")
                }
            }
            #if os(macOS)
            .brainSurface(.editor)
            #endif
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
