import BrainNotesKit
import SwiftUI

/// What a status icon says. Plain data, so a test can go through every state.
struct StatusBadge: Equatable {
    enum Tone: Equatable {
        case good, waiting, moving, quiet, problem

        var color: Color {
            switch self {
            case .good: .green
            case .waiting: .orange
            case .moving: .accentColor
            case .quiet: .secondary
            case .problem: .red
            }
        }
    }

    var symbol: String
    var tone: Tone
    /// A few words: what VoiceOver says, and the top line of the detail.
    var title: String
    /// One sentence, shown on a tap.
    var detail: String
    /// Moving right now: shown as a spinner.
    var isBusy = false

    /// One note, on its own screen.
    static func note(status: NoteSyncStatus, offline: Bool, saveFailed: Bool, isNew: Bool) -> StatusBadge {
        if saveFailed {
            return StatusBadge(symbol: "exclamationmark.triangle.fill", tone: .problem, title: "Couldn't save",
                               detail: "Couldn't save on this device. Keep this screen open and free up some space.")
        }
        if isNew {
            return StatusBadge(symbol: "circle.dashed", tone: .waiting, title: "Not saved yet",
                               detail: "A new note starts existing with its first text.")
        }
        switch status {
        case .needsAttention:
            return StatusBadge(symbol: "exclamationmark.circle.fill", tone: .problem, title: status.label,
                               detail: "This note hasn't reached GitHub as it is. See Needs attention.")
        case .savedOnDevice:
            if offline {
                return StatusBadge(symbol: "wifi.slash", tone: .waiting, title: "Offline",
                                   detail: "Saved on this device. It goes to GitHub when you're back online.")
            }
            return StatusBadge(symbol: "arrow.up.circle", tone: .waiting, title: status.label,
                               detail: "Saved on this device, and waiting to go to GitHub.")
        case .syncing:
            return StatusBadge(symbol: "arrow.triangle.2.circlepath", tone: .moving, title: status.label,
                               detail: "On its way to GitHub.", isBusy: true)
        case .synced:
            if offline {
                return StatusBadge(symbol: "wifi.slash", tone: .quiet, title: "Offline",
                                   detail: "Nothing to send. Changes on GitHub come down when you're back online.")
            }
            return StatusBadge(symbol: "checkmark.circle", tone: .good, title: status.label,
                               detail: "The same here and on GitHub.")
        }
    }

    /// The whole device, on the home screen.
    static func sync(_ snapshot: SyncSnapshot, now: Date) -> StatusBadge {
        let suffix = snapshot.unsynced > 0 ? " · \(snapshot.unsynced) unsynced" : ""
        func working(_ title: String) -> StatusBadge {
            StatusBadge(symbol: "arrow.triangle.2.circlepath", tone: .moving, title: title, detail: "Comparing this device with GitHub.", isBusy: true)
        }
        switch snapshot.state {
        case .idle:
            if snapshot.unsyncedTooLong(now: now) {
                return StatusBadge(symbol: "exclamationmark.circle.fill", tone: .problem, title: "Unsynced for over a day",
                                   detail: "Some notes have been waiting to go to GitHub for more than a day.")
            }
            if snapshot.unsynced > 0 {
                return StatusBadge(symbol: "arrow.up.circle", tone: .waiting, title: "\(snapshot.unsynced) unsynced",
                                   detail: "Saved on this device, and waiting to go to GitHub.")
            }
            return StatusBadge(symbol: "checkmark.circle", tone: .good, title: "Synced", detail: "Everything here is on GitHub too.")
        case .checking: return working("Checking")
        case .pulling: return working("Getting changes")
        case .merging: return working("Merging")
        case .applying: return working("Updating")
        case .pushing: return working("Sending")
        case .verifying: return working("Verifying")
        case let .firstSync(phase):
            switch phase {
            case .downloading: return working("Downloading notes")
            case let .verifying(done, total): return working("Checking \(done) of \(total)")
            case let .indexing(done, total): return working("Indexing \(done) of \(total)")
            }
        case let .needsAttention(n):
            return StatusBadge(symbol: "exclamationmark.circle.fill", tone: .problem, title: "\(n) need\(n == 1 ? "s" : "") attention" + suffix,
                               detail: "Some notes need a decision from you.")
        case .signedOut:
            return StatusBadge(symbol: "person.crop.circle.badge.exclamationmark", tone: .problem, title: "Sign in again",
                               detail: "GitHub stopped accepting this sign-in. Your notes stay on this device.")
        case .paused(.user):
            return StatusBadge(symbol: "pause.circle", tone: .quiet, title: "Sync paused", detail: "You paused sync in Settings.")
        case let .paused(.rateLimited(until)):
            let title = until.map { "Sync paused until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Sync paused for now"
            return StatusBadge(symbol: "pause.circle", tone: .quiet, title: title, detail: "GitHub asked the app to wait. It carries on by itself.")
        case .offline:
            return StatusBadge(symbol: "wifi.slash", tone: .quiet, title: "Offline" + suffix,
                               detail: "Changes stay on this device and go to GitHub when you're back online.")
        case .retrying:
            return StatusBadge(symbol: "clock.arrow.circlepath", tone: .waiting, title: "Trying again soon" + suffix,
                               detail: "GitHub didn't answer. The app tries again by itself.")
        case .accessLost:
            return StatusBadge(symbol: "lock.slash", tone: .problem, title: "Can't reach the brain repo",
                               detail: "This app no longer has access to its repo on GitHub.")
        }
    }
}

/// A small icon in the navigation bar: words only for VoiceOver, and on a tap.
struct StatusIconButton<Extra: View>: View {
    let badge: StatusBadge
    let identifier: String
    @ViewBuilder let extra: () -> Extra
    @State private var showsDetail = false

    var body: some View {
        Button {
            showsDetail = true
        } label: {
            Group {
                if badge.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: badge.symbol).foregroundStyle(badge.tone.color)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.title)
        .accessibilityHint("Shows what this means")
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $showsDetail) {
            VStack(alignment: .leading, spacing: 8) {
                Label(badge.title, systemImage: badge.symbol)
                    .font(.headline)
                    .foregroundStyle(badge.tone == .problem ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Text(badge.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            .padding(16)
            .frame(width: 280, alignment: .leading)
            .accessibilityIdentifier(identifier + ".detail")
            // A small popover on the iPhone too, not a sheet over the note.
            .presentationCompactAdaptation(.popover)
        }
    }
}

extension ToolbarItemPlacement {
    /// Top left, next to the back button.
    static var statusIcon: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}
