import Foundation

// Port of spec/merge/ref/diff3.ts (merge spec sections 1, 3 and 4).

/// Split into lines, keeping each line's terminator ("\n" or "\r\n"). The last line may have none.
/// A lone "\r" is not a line break. Splitting is done on the byte 0x0A, never on Characters,
/// because Swift treats "\r\n" as a single Character.
public func splitLines(_ text: String) -> [String] {
    withUTF8Bytes(text) { (b) -> [String] in
        var out: [String] = []
        guard let base = b.baseAddress else { return out }
        let n = b.count
        var i = 0
        while i < n {
            if let hit = memchr(base + i, 0x0A, n - i) {
                let j = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                out.append(utf8String(b, i, j + 1))
                i = j + 1
            } else {
                out.append(utf8String(b, i, n))
                break
            }
        }
        return out
    }
}

/// Above this many DP cells (after trimming the common prefix and suffix) a merge is refused as a conflict.
public let maxDiffCells = 4_000_000

/// Per-note work budget (spec 3, item 5): all DP cells of one `mergeFile` together, and blocks per side.
public let maxNoteCells = 8_000_000
public let maxBlocks = 2_000

/// Cells left for one note; `matchLines` takes its cells from it.
public final class DiffBudget {
    public var cells: Int
    public init(cells: Int = maxNoteCells) { self.cells = cells }
}

public struct DiffTooLarge: Error, Sendable, CustomStringConvertible {
    /// Same text as the reference's error message.
    public let description: String
    public init(_ message: String) { description = message }
    public init(rows: Int, columns: Int) { description = "diff of \(rows)x\(columns) lines is too large" }
}

/// The reference throws `Error("diff3: no progress")` on a state its matchings cannot produce.
public enum Diff3Error: Error, Sendable, CustomStringConvertible {
    case noProgress
    public var description: String { "diff3: no progress" }
}

/// Longest common subsequence matching of `a` against `b` (spec 3).
/// Returns `m` where `m[i]` is the index in `b` that `a[i]` is matched to, or -1.
/// Match the common prefix greedily, then the common suffix, then fill an LCS table for the middle
/// (`lcs[i][j]` = LCS of `a[i...]` and `b[j...]`) and walk it forward: match when the lines are equal
/// and matching keeps the LCS length; otherwise skip `a[i]` if `lcs[i+1][j] >= lcs[i][j+1]`, else skip `b[j]`.
public func matchLines(_ a: [String], _ b: [String], budget: DiffBudget? = nil) throws -> [Int] {
    var m = [Int](repeating: -1, count: a.count)
    var pre = 0
    while pre < a.count && pre < b.count && exactEqual(a[pre], b[pre]) {
        m[pre] = pre
        pre += 1
    }
    var suf = 0
    while suf < a.count - pre && suf < b.count - pre && exactEqual(a[a.count - 1 - suf], b[b.count - 1 - suf]) {
        m[a.count - 1 - suf] = b.count - 1 - suf
        suf += 1
    }
    let n = a.count - pre - suf
    let k = b.count - pre - suf
    if n == 0 || k == 0 { return m }
    if (n + 1) * (k + 1) > maxDiffCells { throw DiffTooLarge(rows: n, columns: k) }
    if let budget {
        budget.cells -= (n + 1) * (k + 1)
        if budget.cells < 0 { throw DiffTooLarge("note is over its diff budget") }
    }

    // The table compares lines n*k times, so give each distinct line (exact bytes) a small integer.
    var ids: [ExactKey: Int32] = [:]
    ids.reserveCapacity(n + k)
    func intern(_ line: String) -> Int32 {
        let key = ExactKey(line)
        if let id = ids[key] { return id }
        let id = Int32(ids.count)
        ids[key] = id
        return id
    }
    var ia = [Int32]()
    ia.reserveCapacity(n)
    for i in 0..<n { ia.append(intern(a[pre + i])) }
    var ib = [Int32]()
    ib.reserveCapacity(k)
    for j in 0..<k { ib.append(intern(b[pre + j])) }

    let w = k + 1
    var lcs = [UInt32](repeating: 0, count: (n + 1) * w)
    lcs.withUnsafeMutableBufferPointer { table in
        ia.withUnsafeBufferPointer { A in
            ib.withUnsafeBufferPointer { B in
                var i = n - 1
                while i >= 0 {
                    let row = i * w
                    let next = row + w
                    let ai = A[i]
                    var j = k - 1
                    while j >= 0 {
                        if ai == B[j] {
                            table[row + j] = table[next + j + 1] + 1
                        } else {
                            let down = table[next + j]
                            let right = table[row + j + 1]
                            table[row + j] = down >= right ? down : right
                        }
                        j -= 1
                    }
                    i -= 1
                }
            }
        }
    }
    var i = 0
    var j = 0
    while i < n && j < k {
        if ia[i] == ib[j] && lcs[i * w + j] == lcs[(i + 1) * w + j + 1] + 1 {
            m[pre + i] = pre + j
            i += 1
            j += 1
        } else if lcs[(i + 1) * w + j] >= lcs[i * w + j + 1] {
            i += 1
        } else {
            j += 1
        }
    }
    return m
}

public enum Diff3Result: Sendable {
    case clean(lines: [String], unions: Int)
    case conflict(conflicts: Int)
}

@inline(__always)
func linesEqual(_ x: ArraySlice<String>, _ y: ArraySlice<String>) -> Bool {
    guard x.count == y.count else { return false }
    var i = x.startIndex
    var j = y.startIndex
    while i < x.endIndex {
        if !exactEqual(x[i], y[j]) { return false }
        i += 1
        j += 1
    }
    return true
}

/// `xs.slice(from, to)` for the non-negative indices used here: empty when `to <= from`.
@inline(__always)
private func slice(_ xs: [String], _ from: Int, _ to: Int) -> ArraySlice<String> {
    let lo = min(max(from, 0), xs.count)
    let hi = min(max(to, 0), xs.count)
    return lo < hi ? xs[lo..<hi] : xs[lo..<lo]
}

/// diff3 (spec 4). `o` = base, `a` = mine, `b` = theirs.
/// Stable lines are base lines matched in both sides at the current position. Between stable runs,
/// an unstable chunk resolves as: a == o -> b; b == o -> a; a == b -> a;
/// o empty and unionInsertions -> b then a (both sides only inserted text at the same point);
/// otherwise a conflict.
public func diff3(_ o: [String], _ a: [String], _ b: [String], unionInsertions: Bool = true, budget: DiffBudget? = nil) throws -> Diff3Result {
    let ma = try matchLines(o, a, budget: budget)
    let mb = try matchLines(o, b, budget: budget)
    var out: [String] = []
    var conflicts = 0
    var unions = 0
    var io = 0
    var ia = 0
    var ib = 0
    while true {
        if io < o.count && ma[io] == ia && mb[io] == ib {
            out.append(o[io])
            io += 1
            ia += 1
            ib += 1
            continue
        }
        var so = io
        while so < o.count && (ma[so] == -1 || mb[so] == -1) { so += 1 }
        let sa = so < o.count ? ma[so] : a.count
        let sb = so < o.count ? mb[so] : b.count
        let co = slice(o, io, so)
        let ca = slice(a, ia, sa)
        let cb = slice(b, ib, sb)
        if co.isEmpty && ca.isEmpty && cb.isEmpty {
            if so >= o.count { break }
            // Defensive: cannot happen with monotonic matchings, but never loop forever.
            throw Diff3Error.noProgress
        }
        if linesEqual(ca, co) {
            out.append(contentsOf: cb)
        } else if linesEqual(cb, co) {
            out.append(contentsOf: ca)
        } else if linesEqual(ca, cb) {
            out.append(contentsOf: ca)
        } else if co.isEmpty && unionInsertions {
            out.append(contentsOf: cb)
            out.append(contentsOf: ca)
            unions += 1
        } else {
            conflicts += 1
        }
        io = so
        ia = sa
        ib = sb
    }
    return conflicts > 0 ? .conflict(conflicts: conflicts) : .clean(lines: out, unions: unions)
}
