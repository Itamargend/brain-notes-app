#if canImport(Foundation)
import Foundation

public enum NoteSortField: String, Codable, Sendable, Equatable, CaseIterable {
    case defaultEdited
    case dateEdited
    case dateCreated
    case title

    public var usesTitleOrder: Bool {
        self == .title
    }
}

/// Per-repository list display preferences (`Sort By`, `Group By Date`, `Pinned` collapse state).
/// Stored as `ui-prefs.json` inside `store.root` alongside `pins.json`,
/// automatically excluded from backups, and wiped on sign-out or repository switch.
public struct ListPreferences: Codable, Sendable, Equatable {
    public var sortBy: NoteSortField
    public var newestFirst: Bool
    public var titleAscending: Bool
    public var groupByDate: Bool
    public var pinnedCollapsed: Bool

    public init(
        sortBy: NoteSortField = .defaultEdited,
        newestFirst: Bool = true,
        titleAscending: Bool = true,
        groupByDate: Bool = true,
        pinnedCollapsed: Bool = false
    ) {
        self.sortBy = sortBy
        self.newestFirst = newestFirst
        self.titleAscending = titleAscending
        self.groupByDate = groupByDate
        self.pinnedCollapsed = pinnedCollapsed
    }

    /// Sort a slice of notes according to these preferences.
    public func sorted(_ notes: [IndexedNote]) -> [IndexedNote] {
        switch sortBy {
        case .defaultEdited, .dateEdited:
            let newest = newestFirst
            return notes.sorted { a, b in
                compareDates(a.modified, b.modified, newestFirst: newest, fallbackA: a.title, fallbackB: b.title)
            }
        case .dateCreated:
            let newest = newestFirst
            return notes.sorted { a, b in
                compareDates(a.created ?? a.modified, b.created ?? b.modified, newestFirst: newest, fallbackA: a.title, fallbackB: b.title)
            }
        case .title:
            let asc = titleAscending
            return notes.sorted { a, b in
                let cmp = a.title.localizedStandardCompare(b.title)
                if cmp != .orderedSame {
                    return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
        }
    }

    private func compareDates(_ da: Date?, _ db: Date?, newestFirst: Bool, fallbackA: String, fallbackB: String) -> Bool {
        switch (da, db) {
        case let (a?, b?):
            if a != b { return newestFirst ? (a > b) : (a < b) }
            return fallbackA.localizedStandardCompare(fallbackB) == .orderedAscending
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return fallbackA.localizedStandardCompare(fallbackB) == .orderedAscending
        }
    }
}

public final class FileListPreferencesStore: @unchecked Sendable {
    public static let fileName = "ui-prefs.json"

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public convenience init(store: NoteStore) {
        self.init(url: store.root.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    public func load() -> ListPreferences {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return ListPreferences() }
            return (try? JSONDecoder().decode(ListPreferences.self, from: data)) ?? ListPreferences()
        }
    }

    public func save(_ prefs: ListPreferences) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try? JSONEncoder().encode(prefs).write(to: url, options: options)
        }
    }
}
#endif
