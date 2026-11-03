// Port of spec/merge/ref/paths.ts (merge spec section 6). Findings from spike S1:
// GitHub stores NFC and NFD spellings, and names differing only by case, as separate files,
// which collide on Apple file systems. New paths are normalised to NFC; clashes by case or normalisation (foldKey) are refused.

public let maxNoteBytes = 1024 * 1024

public enum PathBlock: String, Sendable {
    case notMd = "not-md"
    case dotSegment = "dot-segment"
    case blockedFolder = "blocked-folder"
    case badSegment = "bad-segment"
    case controlChar = "control-char"
    case tooLarge = "too-large"
}

/// Clash key (spec 6.3): full Unicode case fold that ignores NFC/NFD, matching APFS.
/// NFD, then per scalar lowercase -> uppercase -> lowercase (dotless "ı" kept), "ς" -> "σ", then NFC.
/// Same steps as `foldKey` in spec/merge/ref/paths.ts; see `caseFold` in ExactText.swift.
public func foldKey(_ path: String) -> String {
    if isASCII(path) { return jsLowercase(path) }
    return nfc(caseFold(nfd(path)))
}

/// The path policy (spec 6.4), checked in the reference's order. `content` is checked for size only.
public func checkPath(_ path: String, content: String? = nil) -> PathBlock? {
    if path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) { return .controlChar }
    let segs = splitKeepingEmpty(path, on: 0x2F)
    if segs.contains(where: { $0.isEmpty || exactEqual($0, ".") || exactEqual($0, "..") }) { return .badSegment }
    if segs.contains(where: { $0.utf8.first == 0x2E }) { return .dotSegment }
    if segs.dropLast().contains(where: { seg in
        let f = foldKey(seg)
        return exactEqual(f, "private") || exactEqual(f, "_capture")
    }) { return .blockedFolder }
    // `path.toLowerCase().endsWith(".md")`, on code units (Swift's hasSuffix compares Characters).
    let lower = jsLowercase(path)
    let isMarkdown = withUTF8Bytes(lower) { (b) -> Bool in
        let n = b.count
        return n >= 3 && b[n - 3] == 0x2E && b[n - 2] == 0x6D && b[n - 1] == 0x64
    }
    if !isMarkdown { return .notMd }
    // `Buffer.byteLength(content, "utf8")`
    if let content, content.utf8.count > maxNoteBytes { return .tooLarge }
    return nil
}

/// Index of a tree's paths by clash key. Folder prefixes are indexed too (with a trailing "/"),
/// because `People/a.md` next to `people/b.md` also collides on a Mac.
public struct PathIndex: Sendable {
    private var byKey: [ExactKey: String] = [:]

    public init() {}

    public init<S: Sequence>(_ paths: S) where S.Element == String {
        for p in paths { add(p) }
    }

    /// "a/b/c.md" -> ["a/", "a/b/"]: the text up to and including each "/".
    private static func prefixes(_ p: String) -> [String] {
        withUTF8Bytes(p) { (b) -> [String] in
            var out: [String] = []
            for i in 0..<b.count where b[i] == 0x2F { out.append(utf8String(b, 0, i + 1)) }
            return out
        }
    }

    public mutating func add(_ p: String) {
        for k in Self.prefixes(p) + [p] {
            let fk = ExactKey(foldKey(k))
            if byKey[fk] == nil { byKey[fk] = k }
        }
    }

    /// The first existing folder or file that clashes with `p` (same clash key, different bytes), if any.
    public func clash(_ p: String) -> String? {
        for k in Self.prefixes(p) + [p] {
            if let e = byKey[ExactKey(foldKey(k))], !exactEqual(e, k) { return e }
        }
        return nil
    }

    public func takenByAny(_ p: String) -> Bool {
        byKey[ExactKey(foldKey(p))] != nil
    }
}

/// Add -2, -3, ... before ".md" until the path is free (by clash key).
public func freePath(_ path: String, _ index: PathIndex) -> String {
    if !index.takenByAny(path) { return path }
    let stem = dropMarkdownExtension(path)
    var n = 2
    while true {
        let p = "\(stem)-\(n).md"
        if !index.takenByAny(p) { return p }
        n += 1
    }
}
