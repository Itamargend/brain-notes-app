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
    case invisibleChar = "invisible-char"
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
    // Default_Ignorable_Code_Point (ZWSP, ZWJ, ZWNJ, BOM, soft hyphen, bidi marks, variation selectors, ...):
    // invisible in a file name, and APFS keeps them, so "a\u{200B}b.md" and "ab.md" look the same but are two files.
    if !isASCII(path) && path.unicodeScalars.contains(where: { $0.properties.isDefaultIgnorableCodePoint }) { return .invisibleChar }
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
/// because `People/a.md` next to `people/b.md` also collides on a Mac. The first spelling seen for a
/// key wins (tree order); a second spelling of a folder already on GitHub is remembered as its twin.
public struct PathIndex: Sendable {
    private var byKey: [ExactKey: String] = [:]
    private var twins: [ExactKey: String] = [:]

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
            if let e = byKey[fk] {
                if !exactEqual(e, k) && endsWithSlash(k) && twins[fk] == nil { twins[fk] = k }
            } else {
                byKey[fk] = k
            }
        }
    }

    /// The first existing folder or file that clashes with `p`, if any (spec 6.3): same clash key with
    /// different bytes; a folder of `p` that is a file, or `p` itself is a folder; and with `strict`
    /// (new paths the user made), a folder of `p` that already has case twins on GitHub.
    public func clash(_ p: String, strict: Bool = false) -> String? {
        let pre = Self.prefixes(p)
        for k in pre + [p] {
            let fk = ExactKey(foldKey(k))
            if let e = byKey[fk], !exactEqual(e, k) { return e }
            if strict, let tw = twins[fk] { return tw }
        }
        for k in pre {
            if let e = byKey[ExactKey(foldKey(dropLastSlash(k)))] { return e }
        }
        return byKey[ExactKey(foldKey(p + "/"))]
    }

    public func takenByAny(_ p: String) -> Bool {
        byKey[ExactKey(foldKey(p))] != nil || byKey[ExactKey(foldKey(p + "/"))] != nil
    }

    /// `p` with each folder spelled as the folder already in the index (spec 6.3), for paths the app names itself.
    public func respell(_ p: String) -> String {
        let segs = splitKeepingEmpty(p, on: 0x2F)
        var out = ""
        for seg in segs.dropLast() {
            let k = out + seg + "/"
            out = byKey[ExactKey(foldKey(k))] ?? k
        }
        return out + (segs.last ?? "")
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

private func endsWithSlash(_ s: String) -> Bool { s.utf8.last == 0x2F }
/// "a/b/" -> "a/b" (the trailing "/" is one ASCII byte).
private func dropLastSlash(_ s: String) -> String { String(decoding: Array(s.utf8.dropLast()), as: UTF8.self) }
