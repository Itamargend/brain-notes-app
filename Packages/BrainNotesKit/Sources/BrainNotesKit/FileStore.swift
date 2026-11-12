import BrainMerge
import Foundation

public enum FileStoreError: Error, Equatable, Sendable {
    case invalidPath
    /// The file exists but holds no valid UTF-8.
    case notText
}

/// Note files on disk: `<root>/files/<repo path>`. Atomic writes. On iOS the files use
/// `NSFileProtectionComplete`. They are out of backups, as is everything else under `root` (`NoteStore.init`).
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
        excludeFromBackup(dir)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        #endif
    }

    /// Out of iCloud and device backups on iOS, and out of Time Machine on a Mac. On a folder this covers everything in
    /// it, files made later included.
    static func excludeFromBackup(_ dir: URL) {
        guard !LegacyBrainMigration.isSymbolicLink(dir) else { return }
        var url = URL(fileURLWithPath: dir.path, isDirectory: false)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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
    /// paths than APFS does), or when the note is over `maxNoteBytes`: more than the app opens, and more than it
    /// could ever push back. Such a note stays on GitHub only, and sync carries on without it.
    func writeIfPossible(_ path: String, _ data: Data) throws -> Bool {
        guard Self.nameFits(path), data.count <= maxNoteBytes else { return false }
        do {
            try write(path, data)
            return true
        } catch {
            if Self.isNameProblem(error) { return false }
            throw error
        }
    }

    /// APFS holds at most 255 characters in a name and 1,024 bytes in a whole path; leave room for our own folders. It
    /// also refuses a name with more than 31 combining marks in a row, counted decomposed, however short (EILSEQ).
    static func nameFits(_ path: String) -> Bool {
        path.utf8.count < 700 && path.split(separator: "/").allSatisfy { $0.unicodeScalars.count <= 255 && longestMarkRun(String($0)) <= 31 }
    }

    /// The most combining marks (canonical combining class not 0) in a row in the name's decomposed form, as APFS counts
    /// them: a precomposed letter counts the marks it decomposes into.
    static func longestMarkRun(_ name: String) -> Int {
        var longest = 0
        var run = 0
        for u in nfd(name).unicodeScalars {
            if u.properties.canonicalCombiningClass != .notReordered {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    /// A name this disk can't hold: too long, or one APFS refuses outright (EILSEQ, "Illegal byte sequence").
    static func isNameProblem(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain, e.code == Int(ENAMETOOLONG) || e.code == Int(EILSEQ) { return true }
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

    /// A folder with no note in it yet. Git has no empty folders, so it stays on this device until its first note.
    public func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: try url(for: path), withIntermediateDirectories: true)
    }

    /// Every folder on this disk that has nothing in it, as repo paths. Folders with notes are known from the notes.
    public func emptyFolders() -> [String] {
        var out: [String] = []
        func walk(_ dir: URL, _ path: String) {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            if items.isEmpty, !path.isEmpty { out.append(path) }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(item, path.isEmpty ? item.lastPathComponent : path + "/" + item.lastPathComponent)
            }
        }
        walk(filesRoot, "")
        return out
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
        Self.protectAndExclude(stagingURL())
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

    /// Removes everything of this repo. A folder that is already gone is not an error; one that is still
    /// there after the attempt is, so that a wipe that left notes behind never looks like one that worked.
    public func wipe() throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: root)
        } catch {
            if fm.fileExists(atPath: root.path) { throw error }
        }
    }
}
