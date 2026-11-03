// Port of spec/merge/ref/merge.ts (merge spec section 5).
// Rule: never discard text. Sections that merge cleanly are merged; a section that clashes keeps
// the GitHub version (theirs) in the note, and the caller writes mine, whole, to an _inbox conflict copy.
// Safety net: if the per-section result fails the line check, the whole note keeps theirs.

/// `nil` means the file does not exist on that side.
public typealias Doc = String?

public enum MergeKind: String, Sendable {
    /// mine and theirs are identical
    case same
    /// only theirs changed (or nothing changed)
    case takeTheirs = "take-theirs"
    /// only mine changed
    case takeMine = "take-mine"
    /// both changed, merged cleanly
    case merged
    /// clashing sections keep theirs, clean sections merged; copy = mine (whole)
    case conflict
    /// I deleted, GitHub edited: theirs stays, needs attention
    case deleteSkipped = "delete-skipped"
}

public enum ConflictReason: String, Sendable {
    case sameLines = "same-lines"
    case deletedRemotely = "deleted-remotely"
    case bothCreated = "both-created"
    case sectionDeleted = "section-deleted"
    case headingRenamed = "heading-renamed"
    case unsafeMerge = "unsafe-merge"
    case tooLarge = "too-large"
}

public struct MergeResult: Sendable {
    public var kind: MergeKind
    /// Resulting file content; nil means the file is absent afterwards.
    public var content: String?
    /// Text for the conflict copy (mine, verbatim) or nil.
    public var copy: String?
    public var reason: ConflictReason?
    /// Keys of the blocks that clashed, for the review list.
    public var clashes: [String]?
    /// Number of points where both sides inserted text and both were kept (spec 4.3).
    public var unions: Int?

    public init(kind: MergeKind, content: String?, copy: String?, reason: ConflictReason? = nil,
                clashes: [String]? = nil, unions: Int? = nil) {
        self.kind = kind
        self.content = content
        self.copy = copy
        self.reason = reason
        self.clashes = clashes
        self.unions = unions
    }
}

public struct MergeOptions: Sendable {
    public var unionInsertions: Bool
    public init(unionInsertions: Bool = true) { self.unionInsertions = unionInsertions }
}

/// Three-way merge of one file. `base` is the version the edit started from, `mine` the phone's
/// version, `theirs` what GitHub has now. Throws only `Diff3Error.noProgress`, which the
/// reference also throws and which its matchings cannot produce.
public func mergeFile(base: String?, mine: String?, theirs: String?, options: MergeOptions = MergeOptions()) throws -> MergeResult {
    let union = options.unionInsertions
    if docEqual(mine, theirs) { return MergeResult(kind: .same, content: theirs, copy: nil) }
    if docEqual(mine, base) { return MergeResult(kind: .takeTheirs, content: theirs, copy: nil) }
    if docEqual(theirs, base) { return MergeResult(kind: .takeMine, content: mine, copy: nil) }
    // Both sides changed and differ from each other.
    guard let mine else { return MergeResult(kind: .deleteSkipped, content: theirs, copy: nil) }
    guard let theirs else { return MergeResult(kind: .conflict, content: nil, copy: mine, reason: .deletedRemotely) }
    guard let base else { return MergeResult(kind: .conflict, content: theirs, copy: mine, reason: .bothCreated) }
    do {
        let bb = splitBlocks(base), mb = splitBlocks(mine), tb = splitBlocks(theirs)
        func hasFrontmatter(_ x: [Block]) -> Bool { x.first.map { exactEqual($0.key, "fm") } ?? false }
        let text: String
        let unions: Int
        if hasFrontmatter(bb) == hasFrontmatter(mb) && hasFrontmatter(bb) == hasFrontmatter(tb) {
            let r = try mergeBlocks(bb, mb, tb, union: union, eol: detectEol(theirs))
            if !r.clashes.isEmpty {
                // Two different renames of one heading: no safe per-section answer, whole note keeps theirs (spec 5.2).
                if r.renamed {
                    return MergeResult(kind: .conflict, content: theirs, copy: mine, reason: r.reason, clashes: r.clashes)
                }
                // Per-section conflict (spec 5.2): mine's lines may be missing from the note, they are all in the copy.
                if !safe(base: base, mine: mine, theirs: theirs, result: r.text, requireMine: false) {
                    return MergeResult(kind: .conflict, content: theirs, copy: mine, reason: .unsafeMerge, clashes: r.clashes)
                }
                return MergeResult(kind: .conflict, content: r.text, copy: mine, reason: r.reason, clashes: r.clashes, unions: r.unions)
            }
            text = r.text
            unions = r.unions
        } else {
            // Frontmatter added or removed on one side (spec 5.5): block keys shift, so merge the whole file by lines.
            let d = try diff3(splitLines(base), splitLines(mine), splitLines(theirs), unionInsertions: union)
            guard case let .clean(lines, u) = d else {
                return MergeResult(kind: .conflict, content: theirs, copy: mine, reason: .sameLines, clashes: ["(file)"])
            }
            text = lines.joined()
            unions = u
        }
        // Safety check (spec 5.5): a clean result must keep every added line, invent no line, duplicate nothing.
        if !safe(base: base, mine: mine, theirs: theirs, result: text) {
            return MergeResult(kind: .conflict, content: theirs, copy: mine, reason: .unsafeMerge)
        }
        return MergeResult(kind: .merged, content: text, copy: nil, unions: unions)
    } catch is DiffTooLarge {
        return MergeResult(kind: .conflict, content: theirs, copy: mine, reason: .tooLarge)
    }
}

/// Counts lines by text without the line ending (`l.replace(/\r?\n$/, "")`). Only a "\r" right
/// before a "\n" is part of the ending; the last line keeps a trailing lone "\r".
private func lineCounts(_ text: String) -> [ExactKey: Int] {
    withUTF8Bytes(text) { (b) -> [ExactKey: Int] in
        var counts: [ExactKey: Int] = [:]
        let n = b.count
        var start = 0
        while start < n {
            var end = start
            while end < n && b[end] != 0x0A { end += 1 }
            var keyEnd = end
            if end < n && keyEnd > start && b[keyEnd - 1] == 0x0D { keyEnd -= 1 }
            counts[ExactKey(utf8String(b, start, keyEnd)), default: 0] += 1
            start = end + 1
        }
        return counts
    }
}

/// Line check (spec 5.5). `requireMine` is false for a per-section conflict, whose copy holds all
/// of mine: then only theirs' added lines must be in the note.
public func safe(base: String, mine: String, theirs: String, result: String, requireMine: Bool = true) -> Bool {
    let b = lineCounts(base), m = lineCounts(mine), t = lineCounts(theirs), r = lineCounts(result)
    for (k, n) in r {
        let cb = b[k] ?? 0, cm = m[k] ?? 0, ct = t[k] ?? 0
        if cb + cm + ct == 0 { return false } // invented line
        if n > max(cm, ct, cm + ct - cb) { return false } // duplicated line
    }
    for side in requireMine ? [m, t] : [t] {
        for (k, n) in side where n > (b[k] ?? 0) && (r[k] ?? 0) == 0 { return false } // lost an added line
    }
    return true
}

private struct BlockMerge {
    var text: String
    var clashes: [String]
    var reason: ConflictReason
    var unions: Int
    var renamed: Bool
}

@inline(__always)
private func sameLines(_ x: [String]?, _ y: [String]?) -> Bool {
    switch (x, y) {
    case (nil, nil): return true
    case let (p?, q?): return linesEqual(p[...], q[...])
    default: return false
    }
}

private func mergeBlocks(_ b: [Block], _ m: [Block], _ t: [Block], union: Bool, eol: String) throws -> BlockMerge {
    func byKey(_ blocks: [Block]) -> [ExactKey: [String]] {
        var d = [ExactKey: [String]](minimumCapacity: blocks.count)
        for x in blocks { d[ExactKey(x.key)] = x.lines }
        return d
    }
    let B = byKey(b), M = byKey(m), T = byKey(t)
    var result: [ExactKey: [String]] = [:]
    var clashes: [String] = []
    var sectionDeleted = false
    var unions = 0
    // Keys from base, then mine, then theirs, first occurrence wins (`new Set([...b, ...m, ...t])`).
    var keys: [String] = []
    var seen = Set<ExactKey>()
    for blocks in [b, m, t] {
        for x in blocks where seen.insert(ExactKey(x.key)).inserted { keys.append(x.key) }
    }
    for k in keys {
        let kk = ExactKey(k)
        let vb = B[kk], vm = M[kk], vt = T[kk]
        var r: [String]?
        if sameLines(vm, vt) {
            r = vt
        } else if sameLines(vm, vb) {
            r = vt
        } else if sameLines(vt, vb) {
            r = vm
        } else if vm == nil || vt == nil {
            clashes.append(k) // one side removed the block, the other changed it: theirs wins in the note
            sectionDeleted = true
            r = vt
        } else if vb == nil {
            clashes.append(k) // both added a block with the same key and different text
            r = vt
        } else {
            switch try diff3(vb!, vm!, vt!, unionInsertions: union) {
            case .conflict:
                clashes.append(k)
                r = vt
            case let .clean(lines, u):
                unions += u
                r = lines
            }
        }
        if let r { result[kk] = r }
    }
    // Both sides renamed the same heading differently (spec 5.2, last rule): base key gone on both sides
    // while each side has a key the other lacks. Without this the body would be kept twice.
    let droppedBoth = b.filter { M[ExactKey($0.key)] == nil && T[ExactKey($0.key)] == nil }.map(\.key)
    let onlyM = m.contains { B[ExactKey($0.key)] == nil && T[ExactKey($0.key)] == nil }
    let onlyT = t.contains { B[ExactKey($0.key)] == nil && M[ExactKey($0.key)] == nil }
    var renamed = false
    if !droppedBoth.isEmpty && onlyM && onlyT {
        clashes.append(contentsOf: droppedBoth)
        renamed = true
    }
    let reason: ConflictReason = sectionDeleted
        ? .sectionDeleted
        : (renamed && clashes.count == droppedBoth.count ? .headingRenamed : .sameLines)
    // Order (spec 5.3): theirs order, then blocks only in mine after their nearest kept predecessor in mine.
    var order = t.map(\.key).filter { result[ExactKey($0)] != nil }
    var inOrder = Set(order.map(ExactKey.init))
    var prev: String?
    for x in m {
        let xk = ExactKey(x.key)
        if result[xk] == nil { continue }
        if !inOrder.contains(xk) {
            // `order.indexOf(prev) + 1`, or 0 when there is no kept predecessor.
            let at = prev.map { p in (order.firstIndex { exactEqual($0, p) } ?? -1) + 1 } ?? 0
            order.insert(x.key, at: at)
            inOrder.insert(xk)
        }
        prev = x.key
    }
    let text = joinBlocks(order.map { Block(key: $0, lines: result[ExactKey($0)]!) }, eol: eol)
    return BlockMerge(text: text, clashes: clashes, reason: reason, unions: unions, renamed: renamed)
}
