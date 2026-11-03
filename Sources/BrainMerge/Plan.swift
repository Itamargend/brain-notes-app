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
    case pathPolicy(String)

    public var description: String {
        switch self {
        case .badTime: return "time must be UTC ISO 8601 ending in Z"
        case let .deleteOfMissing(path): return "plan bug: delete of missing \(path)"
        case let .caseClash(path): return "plan bug: case clash \(path)"
        case let .pathPolicy(path): return "plan bug: path policy \(path)"
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

/// Outbox coalescing (spec 7.1): ops on one path become one op, at the place of the first, in order.
/// Group key: the op's path if base has exactly that path; else the base path with the same NFC form,
/// if base has only one; else the NFC form. A group on a base path uses the base spelling.
/// The path existed if the first op is a delete, or an edit of a base path. It exists afterwards unless
/// the last op is a delete. Only a path on base can come out as an edit: anything else is a create,
/// with a create's checks (P47).
/// So edit+edit = edit (last text), delete+create = edit, create+delete = nothing (nil).
public func coalesce(_ ops: [Op], baseTree: PathMap) -> [(op: Op?, idx: [Int])] {
    var byNfc: [ExactKey: String?] = [:] // NFC form -> the one base path with it, or nil if several
    for p in baseTree.keys {
        let n = ExactKey(nfc(p))
        byNfc[n] = byNfc[n] == nil ? .some(p) : .some(nil)
    }
    var groups: [(key: String, first: Op, last: Op, idx: [Int])] = []
    var byKey: [ExactKey: Int] = [:]
    for (i, op) in ops.enumerated() {
        let n = nfc(op.path)
        let key = baseTree.has(op.path) ? op.path : ((byNfc[ExactKey(n)] ?? nil) ?? n)
        if let g = byKey[ExactKey(key)] {
            groups[g].last = op
            groups[g].idx.append(i)
        } else {
            byKey[ExactKey(key)] = groups.count
            groups.append((key: key, first: op, last: op, idx: [i]))
        }
    }
    return groups.map { g in
        let path = baseTree.has(g.key) ? g.key : g.first.path
        let existed: Bool
        switch g.first {
        case .delete: existed = true
        case .edit: existed = baseTree.has(path)
        case .create: existed = false
        }
        switch g.last {
        case .delete: return (op: existed ? .delete(path: path) : nil, idx: g.idx)
        case let .edit(_, content), let .create(_, content):
            // Only a path on base can be edited; anything else is a new note with a create's checks (P47).
            return (op: existed && baseTree.has(path) ? .edit(path: path, content: content) : .create(path: path, content: content), idx: g.idx)
        }
    }
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
    func tooBig(_ s: String) -> Bool { s.utf8.count > maxNoteBytes }

    // Remote renames (spec 7.2): compare's report, else a base path missing in theirs whose exact content
    // sits at exactly one new path, and no other missing base path has that content (one-to-one).
    func renamed(_ p: String) -> String? {
        guard let baseText = baseTree[p], !theirsTree.has(p) else { return nil }
        if let r = input.renames?[p], theirsTree.has(r) { return r }
        let hits = theirsTree.keys.filter { q in !baseTree.has(q) && exactEqual(theirsTree[q]!, baseText) }
        let twins = baseTree.keys.filter { q in !theirsTree.has(q) && exactEqual(baseTree[q]!, baseText) }
        return hits.count == 1 && twins.count == 1 ? hits[0] : nil
    }
    // One op per target (spec 7.1): a later op never overwrites what an earlier op wrote there.
    var claimed = Set<ExactKey>()
    func write(_ path: String, _ content: String) {
        writes[ExactKey(path)] = .write(path: path, content: content)
        index.add(path)
    }
    func copyPath(_ original: String) -> String {
        let slug = String(decoding: Array(dropMarkdownExtension(nfc(original)).utf8).map { $0 == 0x2F ? 0x2D : $0 }, as: UTF8.self)
        return freePath(index.respell("_inbox/conflict-\(slug)-\(stamp).md"), index)
    }
    func copyText(_ original: String, _ mine: String) -> String {
        copyHeader(original, device: device, time: time) + mine
    }
    // Size (spec 6.4, F-04): if a write of this op would be over the limit, the op writes nothing,
    // theirs stays, and the op stays in the outbox with a too-large notice (mine is not lost).
    func blockBig(_ path: String, _ idx: [Int]) {
        attention.append(Attention(path: path, reason: .blocked(.tooLarge)))
        kept.append(contentsOf: idx)
    }
    func apply(_ target: String, _ r: MergeResult, _ idx: [Int]) {
        let cur = theirsTree[target]
        let changed = r.content.map { !docEqual($0, cur) } ?? false
        if (changed && tooBig(r.content!)) || (r.copy.map { tooBig(copyText(target, $0)) } ?? false) {
            claimed.remove(ExactKey(target)) // a blocked op writes nothing, so it takes no target (like a path-policy block)
            return blockBig(target, idx)
        }
        if changed { write(target, r.content!) }
        if r.content == nil && cur != nil { writes[ExactKey(target)] = .delete(path: target) }
        if let copy = r.copy {
            let p = copyPath(target)
            write(p, copyText(target, copy))
            attention.append(Attention(path: target, reason: .conflictCopy, copy: p, detail: r.reason?.rawValue))
        }
        if r.kind == .deleteSkipped { attention.append(Attention(path: target, reason: .deleteSkipped)) }
        if docEqual(r.content, cur) && r.copy == nil && r.kind != .deleteSkipped { noops.append(contentsOf: idx) }
    }
    func isTaken(_ target: String) -> Bool {
        claimed.contains(ExactKey(target)) || writes[ExactKey(target)] != nil
    }
    func sameTarget(_ target: String, _ op: Op, _ idx: [Int]) {
        switch op {
        case .delete:
            attention.append(Attention(path: target, reason: .deleteSkipped, detail: "same-target"))
        case let .edit(_, content), let .create(_, content):
            if tooBig(copyText(target, content)) { return blockBig(target, idx) }
            let p = copyPath(target)
            write(p, copyText(target, content))
            attention.append(Attention(path: target, reason: .conflictCopy, copy: p, detail: "same-target"))
        }
    }

    for (op, idx) in coalesce(input.ops, baseTree: baseTree) {
        guard let op else {
            noops.append(contentsOf: idx) // created and deleted again before sync
            continue
        }
        if case let .create(rawPath, content) = op {
            let path = nfc(rawPath)
            if let block = checkPath(path, content: content) {
                attention.append(Attention(path: path, reason: .blocked(block)))
                kept.append(contentsOf: idx)
                continue
            }
            if let clash = index.clash(path, strict: true) {
                attention.append(Attention(path: path, reason: .caseClash, detail: clash))
                kept.append(contentsOf: idx)
                continue
            }
            if isTaken(path) {
                sameTarget(path, op, idx)
                continue
            }
            claimed.insert(ExactKey(path))
            apply(path, try mergeFile(base: nil, mine: content, theirs: theirsTree[path]), idx)
            continue
        }
        // edit and delete act on an existing repo path: keep its exact bytes, follow a remote rename.
        let target = renamed(op.path) ?? op.path
        var editContent: String?
        if case let .edit(_, content) = op { editContent = content }
        if let block = checkPath(target, content: editContent) {
            attention.append(Attention(path: target, reason: .blocked(block)))
            kept.append(contentsOf: idx)
            continue
        }
        if isTaken(target) {
            sameTarget(target, op, idx)
            continue
        }
        claimed.insert(ExactKey(target))
        let base = baseTree[op.path]
        let theirs = theirsTree[target]
        if let editContent {
            apply(target, try mergeFile(base: base, mine: editContent, theirs: theirs), idx)
            continue
        }
        // Delete (spec 7.3): re-checked against the new base on every retry.
        guard let theirsText = theirs else {
            noops.append(contentsOf: idx) // already gone: never send sha null for a missing path
            continue
        }
        if !docEqual(theirsText, base) {
            attention.append(Attention(path: target, reason: .deleteSkipped))
            continue
        }
        // An existing `_trash` copy with the same text counts only if no op of this batch takes it; relying
        // on it claims it, so a later op on it goes to a copy and the text stays (spec 7.3).
        let trash = index.respell(nfc("_trash/\(target)"))
        let trashed = (theirsTree[trash].map { exactEqual($0, theirsText) } ?? false) && !isTaken(trash)
        if !trashed && tooBig(theirsText) {
            claimed.remove(ExactKey(target))
            blockBig(target, idx)
            continue
        }
        writes[ExactKey(target)] = .delete(path: target)
        if trashed { claimed.insert(ExactKey(trash)) } else { write(freePath(trash, index), theirsText) }
    }

    // Final guard (spec 7.6). A throw here is the planner's internal assert; the app shows it in Needs attention.
    // 1. Deletes only for paths present on the new base.
    // 2. No two new writes share a clash key. Deletes create no file, so a write may share a key with a delete (twin cleanup,
    //    P25), and writes to twins that are both already on the new base add no clash (P56).
    // 3. Every write passes the path policy, and every new path is clash-free against the new base and the other writes.
    // Entries are sorted by UTF-16 code unit, like JS `<`.
    let entries = writes.values.sorted { utf16Less($0.path, $1.path) }
    for e in entries {
        if case let .delete(path) = e, !theirsTree.has(path) { throw PlanError.deleteOfMissing(path) }
    }
    var keys = Set<ExactKey>()
    var guardIndex = PathIndex(theirsTree.keys)
    for e in entries {
        guard case let .write(path, content) = e else { continue }
        let (inserted, _) = keys.insert(ExactKey(foldKey(path)))
        if !inserted && !theirsTree.has(path) { throw PlanError.caseClash(path) }
        if checkPath(path, content: content) != nil { throw PlanError.pathPolicy(path) }
        if !theirsTree.has(path) && guardIndex.clash(path) != nil { throw PlanError.caseClash(path) }
        guardIndex.add(path)
    }
    return PlanOutput(entries: entries, attention: attention, kept: kept.sorted(), noops: noops.sorted())
}
