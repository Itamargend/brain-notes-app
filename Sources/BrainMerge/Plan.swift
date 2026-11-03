// Port of spec/merge/ref/plan.ts (merge spec section 7). Runs after every pull, including each 422
// retry, on the new base. Produces the tree entries for one atomic commit and the Needs attention list.

public enum Op: Sendable {
    case edit(path: String, content: String)
    case create(path: String, content: String)
    case delete(path: String)

    public var path: String {
        switch self {
        case let .edit(path, _), let .create(path, _), let .delete(path): return path
        }
    }
}

public enum Entry: Sendable {
    case write(path: String, content: String)
    case delete(path: String)

    public var path: String {
        switch self {
        case let .write(path, _), let .delete(path): return path
        }
    }
}

public enum AttentionReason: Sendable, Hashable {
    case conflictCopy
    case deleteSkipped
    case caseClash
    case blocked(PathBlock)

    /// The reference's string: "conflict-copy", "delete-skipped", "case-clash" or "blocked:<PathBlock>".
    public var rawValue: String {
        switch self {
        case .conflictCopy: return "conflict-copy"
        case .deleteSkipped: return "delete-skipped"
        case .caseClash: return "case-clash"
        case let .blocked(block): return "blocked:" + block.rawValue
        }
    }
}

public struct Attention: Sendable {
    public var path: String
    public var reason: AttentionReason
    public var copy: String?
    public var detail: String?

    public init(path: String, reason: AttentionReason, copy: String? = nil, detail: String? = nil) {
        self.path = path
        self.reason = reason
        self.copy = copy
        self.detail = detail
    }
}

public struct PlanInput: Sendable {
    /// Files at the journal base (the commit the ops were made on).
    public var baseTree: PathMap
    /// Files at the current head of main (after the pull).
    public var theirsTree: PathMap
    public var ops: [Op]
    /// Renames reported by compare (`previous_filename` -> `filename`); used before the exact-content check.
    public var renames: PathMap?
    public var device: String
    /// Op creation time, exact UTC string ending in Z (same string as the commit date, spec 7.5).
    public var time: String

    public init(baseTree: PathMap, theirsTree: PathMap, ops: [Op], renames: PathMap? = nil, device: String, time: String) {
        self.baseTree = baseTree
        self.theirsTree = theirsTree
        self.ops = ops
        self.renames = renames
        self.device = device
        self.time = time
    }
}

public struct PlanOutput: Sendable {
    public var entries: [Entry]
    public var attention: [Attention]
    /// Ops that stay in the outbox (blocked); everything else is done once the commit lands.
    public var kept: [Int]
    /// Ops that needed nothing (already true on GitHub).
    public var noops: [Int]
}

/// The reference throws plain `Error`s with these messages.
public enum PlanError: Error, Sendable, CustomStringConvertible {
    case badTime
    case deleteOfMissing(String)
    case caseClash(String)

    public var description: String {
        switch self {
        case .badTime: return "time must be UTC ISO 8601 ending in Z"
        case let .deleteOfMissing(path): return "plan bug: delete of missing \(path)"
        case let .caseClash(path): return "plan bug: case clash \(path)"
        }
    }
}

public func copyHeader(_ original: String, device: String, time: String) -> String {
    "---\ntype: conflict\nconflict_of: \(yamlStr(original))\ndevice: \(yamlStr(device))\ncreated: \(yamlStr(time))\n---\n"
}

/// `/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/` -> "YYYYMMDD-HHMMSS".
/// `\d` is ASCII 0-9 only (no `u` flag), and `$` is the very end of the string.
public func copyStamp(_ time: String) throws -> String {
    let b = Array(time.utf8)
    func digits(_ r: Range<Int>) -> Bool { r.allSatisfy { b[$0] >= 0x30 && b[$0] <= 0x39 } }
    guard b.count >= 20,
          digits(0..<4), b[4] == 0x2D, digits(5..<7), b[7] == 0x2D, digits(8..<10), b[10] == 0x54,
          digits(11..<13), b[13] == 0x3A, digits(14..<16), b[16] == 0x3A, digits(17..<19)
    else { throw PlanError.badTime }
    var p = 19
    if b[p] == 0x2E {
        p += 1
        let start = p
        while p < b.count && b[p] >= 0x30 && b[p] <= 0x39 { p += 1 }
        if p == start { throw PlanError.badTime }
    }
    guard p == b.count - 1, b[p] == 0x5A else { throw PlanError.badTime }
    var out: [UInt8] = []
    out += b[0..<4]
    out += b[5..<7]
    out += b[8..<10]
    out.append(0x2D)
    out += b[11..<13]
    out += b[14..<16]
    out += b[17..<19]
    return String(decoding: out, as: UTF8.self)
}

public func planCommit(_ input: PlanInput) throws -> PlanOutput {
    let baseTree = input.baseTree
    let theirsTree = input.theirsTree
    let device = input.device
    let time = input.time
    var index = PathIndex(theirsTree.keys)
    var writes: [ExactKey: Entry] = [:]
    var attention: [Attention] = []
    var kept: [Int] = []
    var noops: [Int] = []
    let stamp = try copyStamp(time)

    // Remote renames: a base path missing in theirs whose exact content sits at exactly one new path.
    func renamed(_ p: String) -> String? {
        guard let baseText = baseTree[p], !theirsTree.has(p) else { return nil }
        if let r = input.renames?[p], theirsTree.has(r) { return r }
        let hits = theirsTree.keys.filter { q in !baseTree.has(q) && exactEqual(theirsTree[q]!, baseText) }
        return hits.count == 1 ? hits[0] : nil
    }
    func write(_ path: String, _ content: String) {
        writes[ExactKey(path)] = .write(path: path, content: content)
        index.add(path)
    }
    func addCopy(_ original: String, _ mine: String) -> String {
        let slug = String(decoding: Array(dropMarkdownExtension(nfc(original)).utf8).map { $0 == 0x2F ? 0x2D : $0 }, as: UTF8.self)
        let p = freePath("_inbox/conflict-\(slug)-\(stamp).md", index)
        write(p, copyHeader(original, device: device, time: time) + mine)
        return p
    }
    func apply(_ target: String, _ r: MergeResult, _ i: Int) {
        let cur = theirsTree[target]
        if let content = r.content, !docEqual(content, cur) { write(target, content) }
        if r.content == nil && cur != nil { writes[ExactKey(target)] = .delete(path: target) }
        if let copy = r.copy {
            let copyPath = addCopy(target, copy)
            attention.append(Attention(path: target, reason: .conflictCopy, copy: copyPath, detail: r.reason?.rawValue))
        }
        if r.kind == .deleteSkipped { attention.append(Attention(path: target, reason: .deleteSkipped)) }
        if docEqual(r.content, cur) && r.copy == nil && r.kind != .deleteSkipped { noops.append(i) }
    }

    for (i, op) in input.ops.enumerated() {
        if case let .create(rawPath, content) = op {
            let path = nfc(rawPath)
            if let block = checkPath(path, content: content) {
                attention.append(Attention(path: path, reason: .blocked(block)))
                kept.append(i)
                continue
            }
            if let clash = index.clash(path) {
                attention.append(Attention(path: path, reason: .caseClash, detail: clash))
                kept.append(i)
                continue
            }
            let cur: String?
            if let t = theirsTree[path] {
                cur = t
            } else if case let .write(_, written)? = writes[ExactKey(path)] {
                cur = written
            } else {
                cur = nil
            }
            apply(path, try mergeFile(base: nil, mine: content, theirs: cur), i)
            continue
        }
        // edit and delete act on an existing repo path: keep its exact bytes, follow a remote rename.
        let target = renamed(op.path) ?? op.path
        var editContent: String?
        if case let .edit(_, content) = op { editContent = content }
        if let block = checkPath(target, content: editContent) {
            attention.append(Attention(path: target, reason: .blocked(block)))
            kept.append(i)
            continue
        }
        let base = baseTree[op.path]
        let theirs = theirsTree[target]
        if let editContent {
            apply(target, try mergeFile(base: base, mine: editContent, theirs: theirs), i)
            continue
        }
        // Delete (spec 7.3): re-checked against the new base on every retry.
        guard let theirsText = theirs else {
            noops.append(i) // already gone: never send sha null for a missing path
            continue
        }
        if !docEqual(theirsText, base) {
            attention.append(Attention(path: target, reason: .deleteSkipped))
            continue
        }
        writes[ExactKey(target)] = .delete(path: target)
        let trash = "_trash/\(target)"
        if !(theirsTree.has(trash) && exactEqual(theirsTree[trash]!, theirsText)) {
            write(freePath(trash, index), theirsText)
        }
    }

    // Final guard (spec 7.6): deletes only for paths present on the new base; no two writes clash by case.
    // Entries are sorted by UTF-16 code unit, like JS `<`.
    let entries = writes.values.sorted { utf16Less($0.path, $1.path) }
    for e in entries {
        if case let .delete(path) = e, !theirsTree.has(path) { throw PlanError.deleteOfMissing(path) }
    }
    var keys = Set<ExactKey>()
    for e in entries {
        let (inserted, _) = keys.insert(ExactKey(foldKey(e.path)))
        if !inserted { throw PlanError.caseClash(e.path) }
    }
    return PlanOutput(entries: entries, attention: attention, kept: kept, noops: noops)
}
