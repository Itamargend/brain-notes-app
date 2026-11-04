import Foundation

public enum FileStoreError: Error, Equatable, Sendable {
    case invalidPath
    /// The file exists but holds no valid UTF-8.
    case notText
}

/// Note files on disk: `<root>/files/<repo path>`. Atomic writes. On iOS the files use
/// `NSFileProtectionComplete`; the whole folder is excluded from backup (the journal is not).
///
/// Reading distinguishes "no such file" (nil) from "cannot read" (throws). A note file is unreadable
/// while the phone is locked, and the engine must not mistake that for a deleted note.
public struct FileStore: Sendable {
    public let root: URL  // .../Brain/<repoId>
    public let filesRoot: URL

    public init(root: URL) {
        self.root = root
        self.filesRoot = root.appendingPathComponent("files", isDirectory: true)
    }

    private init(root: URL, filesRoot: URL) {
        self.root = root
        self.filesRoot = filesRoot
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        Self.protectAndExclude(filesRoot)
    }

    static func protectAndExclude(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        #endif
    }

    /// File URL for a repo path. Paths are validated: no "..", no absolute, no empty segments.
    public func url(for path: String) throws -> URL {
        let segs = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !segs.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw FileStoreError.invalidPath
        }
        return filesRoot.appendingPathComponent(path, isDirectory: false)
    }

    /// The bytes of a note, or nil if there is no such file. Other read errors throw.
    public func readData(_ path: String) throws -> Data? {
        let u = try url(for: path)
        do {
            return try Data(contentsOf: u)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return nil
        } catch {
            // A name this disk can't hold names no file here (the note stays on GitHub only).
            if Self.isNameProblem(error) { return nil }
            throw error
        }
    }

    /// The text of a note, or nil if there is no such file.
    public func readText(_ path: String) throws -> String? {
        guard let d = try readData(path) else { return nil }
        guard let text = decodeNote(d) else { throw FileStoreError.notText }
        return text
    }

    public func exists(_ path: String) -> Bool {
        guard let u = try? url(for: path) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// Size and modification time, to notice a file that changed outside the journal without hashing it.
    public func stat(_ path: String) -> (size: Int64, mtime: Double)? {
        guard let u = try? url(for: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
              let size = attrs[.size] as? NSNumber,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return (size.int64Value, date.timeIntervalSince1970)
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

    /// Writes a note from GitHub. False when this file system cannot hold the name (GitHub takes longer
    /// paths than APFS does): that note stays on GitHub only, and sync carries on without it.
    func writeIfPossible(_ path: String, _ data: Data) throws -> Bool {
        guard Self.nameFits(path) else { return false }
        do {
            try write(path, data)
            return true
        } catch {
            if Self.isNameProblem(error) { return false }
            throw error
        }
    }

    /// APFS holds at most 255 characters in a name and 1,024 bytes in a whole path; leave room for our own folders.
    static func nameFits(_ path: String) -> Bool {
        path.utf8.count < 700 && path.split(separator: "/").allSatisfy { $0.unicodeScalars.count <= 255 }
    }

    private static func isNameProblem(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain, e.code == Int(ENAMETOOLONG) { return true }
            if e.domain == NSCocoaErrorDomain,
               e.code == CocoaError.fileWriteInvalidFileName.rawValue || e.code == CocoaError.fileReadInvalidFileName.rawValue { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    public func remove(_ path: String) throws {
        let u = try url(for: path)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
        // Tidy empty parent folders, never the root.
        var dir = u.deletingLastPathComponent()
        let rootPath = filesRoot.standardizedFileURL.path
        while dir.standardizedFileURL.path.count > rootPath.count {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["x"]
            if items.isEmpty { try? FileManager.default.removeItem(at: dir) } else { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    public func move(_ from: String, to: String) throws {
        let a = try url(for: from), b = try url(for: to)
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: b)
    }

    // MARK: first sync staging

    public func stagingURL() -> URL { root.appendingPathComponent("files.staging", isDirectory: true) }

    /// The same store over the staging folder: same path rules, same protection.
    public var staging: FileStore { FileStore(root: root, filesRoot: stagingURL()) }

    public func resetStaging() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingURL())
        try fm.createDirectory(at: stagingURL(), withIntermediateDirectories: true)
    }

    /// Swap the verified staging folder in for `files/`. The old folder goes away only after the new one is in place.
    public func swapIn() throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent("files.old", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: filesRoot.path) { try fm.moveItem(at: filesRoot, to: old) }
        try fm.moveItem(at: stagingURL(), to: filesRoot)
        try? fm.removeItem(at: old)
        Self.protectAndExclude(filesRoot)
    }

    public func wipe() { try? FileManager.default.removeItem(at: root) }
}
