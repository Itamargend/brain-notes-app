import BrainNotesKit
import SwiftUI

/// Everything that needs a look. Sync never waits for this list.
struct AttentionListView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [AttentionItem] = []
    @State private var loaded = false

    var body: some View {
        List(items) { item in
            RouteLink(.attentionItem(item.id)) {
                VStack(alignment: .leading, spacing: 3) {
                    let title = app.session?.store.index.note(path: item.path)?.title ?? item.displayTitle
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paragraphDirection(rightToLeft: NoteText.isRightToLeft(title))
                    Text(item.bannerTextOrGlobal)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("attention.\(item.reason)")
        }
        .overlay {
            if loaded, items.isEmpty {
                ContentUnavailableView("Nothing needs attention", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Needs attention")
        .task(id: app.revision) {
            items = await app.session?.store.openAttention() ?? []
            loaded = true
        }
    }
}

extension AttentionItem {
    var displayTitle: String {
        if path.isEmpty { return "Main was rewritten" }
        return NoteText.fileStem(path)
    }

    var bannerTextOrGlobal: String {
        if reason == "history-rewritten" {
            return "The history on GitHub changed. Sync stopped, and your notes are untouched."
        }
        return bannerText
    }
}

/// Both versions side by side, with choices that never lose text.
struct AttentionDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    let id: Int64
    @State private var item: AttentionItem?
    @State private var texts = AttentionTexts(mine: nil, theirs: nil)
    @State private var working = false

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    Text(item.bannerTextOrGlobal)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    if item.reason != "history-rewritten" {
                        sideBySide(item)
                    } else {
                        Spacer()
                    }
                    actions(item)
                        .padding(12)
                }
            } else {
                ContentUnavailableView("This item is closed", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle(item.map { app.session?.store.index.note(path: $0.path)?.title ?? $0.displayTitle } ?? "")
        .task {
            guard let s = app.session else { return }
            let id = self.id
            let (found, both) = await Task.detached { () -> (AttentionItem?, AttentionTexts) in
                let i = s.store.journal.attention(id: id)
                return (i, i.map { s.store.texts(for: $0) } ?? AttentionTexts(mine: nil, theirs: nil))
            }.value
            item = found?.resolved == true ? nil : found
            texts = both
        }
    }

    private func sideBySide(_ item: AttentionItem) -> some View {
        let mine = texts.mine, theirs = texts.theirs
        let mineLines = Set(NoteText.lines(mine ?? "").map(PathKey.init))
        let theirLines = Set(NoteText.lines(theirs ?? "").map(PathKey.init))
        return ScrollView {
            HStack(alignment: .top, spacing: 8) {
                VersionColumn(title: "Mine", text: mine, others: theirLines, emptyText: item.reason == "delete-skipped" ? "You deleted this note." : "No version here.")
                    .accessibilityIdentifier("attention.mine")
                Divider()
                VersionColumn(title: "On GitHub", text: theirs, others: mineLines, emptyText: "Deleted on GitHub.")
                    .accessibilityIdentifier("attention.theirs")
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder private func actions(_ item: AttentionItem) -> some View {
        HStack(spacing: 8) {
            switch item.reason {
            case "conflict-copy" where item.detail == "deleted-remotely":
                choice("Keep in Inbox", .keepBoth, id: "attention.keep")
                choice("Restore", .restore, id: "attention.restore", prominent: true)
            case "conflict-copy":
                choice("Use mine", .useMine, id: "attention.useMine")
                choice("Keep both", .keepBoth, id: "attention.keep", prominent: true)
                choice("Use GitHub's", .useTheirs, id: "attention.useTheirs")
            case "delete-skipped":
                choice("Keep the note", .keepBoth, id: "attention.keep", prominent: true)
                choice("Delete anyway", .deleteAnyway, id: "attention.deleteAnyway")
            case "history-rewritten":
                Button {
                    working = true
                    Task {
                        await app.freshSync()
                        working = false
                        leave()
                    }
                } label: {
                    Text("Start a fresh sync").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("attention.fresh")
            case "case-clash", "unstorable":
                choice("OK", .keepBoth, id: "attention.keep", prominent: true)
            default:
                if !item.path.isEmpty {
                    Button {
                        router.replaceTop(with: .note(item.path))
                    } label: {
                        Text("Open the note").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("attention.open")
                }
                choice("Try again", .retry, id: "attention.retry", prominent: true)
            }
        }
        .disabled(working)
    }

    private func choice(_ title: String, _ choice: AttentionChoice, id: String, prominent: Bool = false) -> some View {
        Button {
            guard let item else { return }
            working = true
            Task {
                await app.resolve(item, choice)
                working = false
                leave()
            }
        } label: {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .modifier(ProminentIf(prominent: prominent))
        .accessibilityIdentifier(id)
    }

    private func leave() {
        router.replaceTop(with: nil)
    }
}

private struct ProminentIf: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// One side of a comparison. Lines the other side doesn't have are tinted.
private struct VersionColumn: View {
    let title: String
    let text: String?
    let others: Set<PathKey>
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let text {
                ForEach(Array(NoteText.lines(text).enumerated()), id: \.offset) { _, line in
                    let onlyHere = !others.contains(PathKey(line))
                    Text(line.isEmpty ? " " : line)
                        .font(.footnote)
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paragraphDirection(rightToLeft: NoteText.isRightToLeft(line))
                        .background(onlyHere ? Color.accentColor.opacity(0.18) : Color.clear)
                        // The tint is the only sign of a difference on screen; VoiceOver says it in words.
                        .accessibilityValue(onlyHere ? Text("Only in this version") : Text(verbatim: ""))
                }
            } else {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}
