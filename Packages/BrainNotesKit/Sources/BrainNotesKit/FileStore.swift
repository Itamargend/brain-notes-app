import BrainMerge
import Foundation

/// Note files on disk: `<root>/files/<repo path>`. Atomic writes. On iOS the files use
/// `NSFileProtectionComplete`; the whole folder is excluded from backup (the journal is not).
public struct FileStore: Sendable {
    public let root: URL  // .../Brain/<repoId>
    public var filesRoot: URL { root.appendingPathComponent("files", isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        var url = filesRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: filesRoot.path)
        #endif
    }

    /// File URL for a repo path. Paths are validated: no "..", no absolute, no empty segments.
    public func url(for path: String) throws -> URL {
        let segs = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !segs.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return filesRoot.appendingPathComponent(path, isDirectory: false)
    }

    public func read(_ path: String) -> String? {
        guard let u = try? url(for: path), let d = try? Data(contentsOf: u) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func readData(_ path: String) -> Data? {
        guard let u = try? url(for: path) else { return nil }
        return try? Data(contentsOf: u)
    }

    public func exists(_ path: String) -> Bool {
        guard let u = try? url(for: path) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    public func modified(_ path: String) -> Date? {
        guard let u = try? url(for: path) else { return nil }
        return (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    public func write(_ path: String, _ data: Data) throws {
        let u = try url(for: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try data.write(to: u, options: options)
    }

    public func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }

    public func remove(_ path: String) throws {
        let u = try url(for: path)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
        // Tidy empty parent folders, never the root.
        var dir = u.deletingLastPathComponent()
        while dir.path.count > filesRoot.path.count {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["x"]
            if items.isEmpty { try? FileManager.default.removeItem(at: dir) } else { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Every file under `files/` as a repo path (relative, `/` separated).
    public func allPaths() -> [String] {
        let base = filesRoot.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(String(p.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    /// Swap a staging folder in for `files/`. The old folder goes away only after the new one is in place.
    public func swapIn(staging: URL) throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent("files.old", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: filesRoot.path) { try fm.moveItem(at: filesRoot, to: old) }
        try fm.moveItem(at: staging, to: filesRoot)
        try? fm.removeItem(at: old)
        var url = filesRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func stagingURL() -> URL { root.appendingPathComponent("files.staging", isDirectory: true) }

    public func wipe() { try? FileManager.default.removeItem(at: root) }
}
