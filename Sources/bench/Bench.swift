import BrainMerge
import Foundation

// Times BrainMerge on synthetic notes. Run in release mode: swift run -c release bench
//
// Each note is a realistic person page (frontmatter, Compiled Truth, Timeline, then sections).
// Both sides edit it the way M3 expects: mine edits Compiled Truth, appends to the Timeline and
// edits the last section; theirs bumps the frontmatter, edits a middle section, appends to the
// Timeline at the same point (a union insert) and edits the last section two lines away from mine.
// So every merge takes the full path: split into blocks, diff3 on two blocks, join, safety check,
// and ends "merged". Every scenario runs 3 times; the median is reported.

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

let words = [
    "demo", "company", "meeting", "notes", "tea", "project", "brain", "merge", "section", "timeline",
    "follow-up", "call", "email", "draft", "review", "idea", "plan", "github", "phone", "sync",
    "outbox", "commit", "שלום", "פגישה", "Amélie", "context", "decision", "owner", "deadline", "budget",
]

struct Section {
    var heading: String
    var lines: [String]
    var bytes: Int { heading.utf8.count + 1 + lines.reduce(0) { $0 + $1.utf8.count + 1 } }
}

struct Note {
    var frontmatter: [String]
    var sections: [Section]

    var text: String {
        var s = "---\n"
        for l in frontmatter { s += l + "\n" }
        s += "---\n"
        for sec in sections {
            s += sec.heading + "\n"
            for l in sec.lines { s += l + "\n" }
        }
        return s
    }
}

func sentence(_ rng: inout SplitMix64) -> String {
    (0..<(6 + rng.int(8))).map { _ in words[rng.int(words.count)] }.joined(separator: " ") + "."
}

func plainSection(_ k: Int, _ rng: inout SplitMix64) -> Section {
    Section(heading: "## Section \(k)", lines: ["", sentence(&rng), sentence(&rng), sentence(&rng), sentence(&rng), ""])
}

func makeNote(id: Int, targetBytes: Int, seed: UInt64) -> Note {
    var rng = SplitMix64(state: seed)
    var note = Note(
        frontmatter: ["title: Demo note \(id)", "type: person", "updated: 2026-10-01"],
        sections: [
            Section(heading: "# Demo note \(id)", lines: [""]),
            Section(heading: "## Compiled Truth", lines: ["", sentence(&rng), sentence(&rng), ""]),
            Section(heading: "## Timeline", lines: ["", "- 2026-09-01 met at demo event", "- 2026-10-01 follow-up call", ""]),
        ]
    )
    var size = 50 + note.sections.reduce(0) { $0 + $1.bytes }
    var k = 1
    while size < targetBytes {
        var sec = plainSection(k, &rng)
        if k % 7 == 0 {
            sec.lines.insert(contentsOf: ["```swift", "let x = \(k)", "# not a heading", "```"], at: 2)
        }
        note.sections.append(sec)
        size += sec.bytes
        k += 1
    }
    // At least two plain sections after the Timeline, and a plain one (6 lines) last.
    while note.sections.count < 5 || note.sections[note.sections.count - 1].lines.count != 6 {
        note.sections.append(plainSection(k, &rng))
        k += 1
    }
    return note
}

struct Triple {
    let base: String
    let mine: String
    let theirs: String
}

func makeTriple(id: Int, targetBytes: Int) -> Triple {
    let base = makeNote(id: id, targetBytes: targetBytes, seed: UInt64(id) &* 7919 &+ 17)
    var rng = SplitMix64(state: UInt64(id) &+ 99)
    var mine = base
    var theirs = base
    let last = base.sections.count - 1
    let middle = 3 + (base.sections.count - 4) / 2

    mine.sections[1].lines[1] += " (mine)"
    mine.sections[2].lines.insert("- 2026-11-03 coffee with demo person", at: 3)
    mine.sections[last].lines[1] = sentence(&rng) + " (mine)"

    theirs.frontmatter[2] = "updated: 2026-11-02"
    theirs.sections[middle].lines[1] += " (theirs)"
    theirs.sections[2].lines.insert("- 2026-11-02 bot: new email thread", at: 3)
    theirs.sections[last].lines[4] = sentence(&rng) + " (theirs)"

    return Triple(base: base.text, mine: mine.text, theirs: theirs.text)
}

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
}

/// Runs `body` 3 times and returns the sorted times in ms. `body` returns a checksum so the work is not optimised away.
func time3(_ body: () throws -> Int) rethrows -> (sorted: [Double], checksum: Int) {
    var times: [Double] = []
    var checksum = 0
    let clock = ContinuousClock()
    for _ in 0..<3 {
        let start = clock.now
        checksum &+= try body()
        times.append(ms(clock.now - start))
    }
    return (times.sorted(), checksum)
}

func fmt(_ x: Double) -> String {
    x < 1 ? String(format: "%.4f", x) : x < 100 ? String(format: "%.3f", x) : String(format: "%.1f", x)
}

func report(_ label: String, _ t: (sorted: [Double], checksum: Int), note: String = "") {
    let runs = t.sorted.map(fmt).joined(separator: ", ")
    let padded = label.count >= 48 ? label : label + String(repeating: " ", count: 48 - label.count)
    print("\(padded) median \(fmt(t.sorted[1]).leftPad(9)) ms   (runs sorted: \(runs))\(note.isEmpty ? "" : "   " + note)")
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

func kinds(_ results: [MergeResult]) -> String {
    var counts: [String: Int] = [:]
    for r in results { counts[r.kind.rawValue + (r.reason.map { "/" + $0.rawValue } ?? ""), default: 0] += 1 }
    return counts.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
}

@main
struct Bench {
    static func main() throws {
        #if DEBUG
        print("warning: debug build; use swift run -c release bench")
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        print("BrainMerge bench: \(os), \(ProcessInfo.processInfo.activeProcessorCount) cores; 3 runs per line, median shown")
        print("")

        for (label, target) in [("1 KB note", 1_024), ("50 KB note", 50 * 1_024), ("500 KB note", 500 * 1_024)] {
            let t = makeTriple(id: target, targetBytes: target)
            let check = try mergeFile(base: t.base, mine: t.mine, theirs: t.theirs)
            let timing = try time3 { try mergeFile(base: t.base, mine: t.mine, theirs: t.theirs).content?.utf8.count ?? 0 }
            report("mergeFile, \(label) (\(t.base.utf8.count) bytes)", timing, note: kinds([check]) + ", unions \(check.unions ?? 0)")
        }

        let batch = (0..<2_000).map { makeTriple(id: 10_000 + $0, targetBytes: 3 * 1_024) }
        let avg = batch.reduce(0) { $0 + $1.base.utf8.count } / batch.count
        let batchKinds = kinds(try batch.map { try mergeFile(base: $0.base, mine: $0.mine, theirs: $0.theirs) })
        let batchTiming = try time3 {
            var total = 0
            for t in batch { total &+= try mergeFile(base: t.base, mine: t.mine, theirs: t.theirs).content?.utf8.count ?? 0 }
            return total
        }
        report("mergeFile, 2,000 notes of ~3 KB (avg \(avg) B)", batchTiming,
               note: "= \(fmt(batchTiming.sorted[1] / 2_000 * 1_000)) µs/note; \(batchKinds)")

        // Worst case the spec allows: a one-block note whose middle is 1,999 x 1,999 distinct lines,
        // i.e. exactly 4,000,000 LCS cells per side. One more line and the merge is refused as too-large.
        func numbered(_ p: String, _ n: Int) -> String { (0..<n).map { "\(p)\($0)\n" }.joined() }
        let (wb, wm, wt) = (numbered("base ", 1_999), numbered("mine ", 1_999), numbered("theirs ", 1_999))
        let worst = try mergeFile(base: wb, mine: wm, theirs: wt)
        report("extra: mergeFile at the 4,000,000-cell limit", try time3 { try mergeFile(base: wb, mine: wm, theirs: wt).copy?.utf8.count ?? 0 },
               note: kinds([worst]))
        let refused = try mergeFile(base: numbered("base ", 2_000), mine: numbered("mine ", 2_000), theirs: numbered("theirs ", 2_000))
        print("       (2,000 x 2,000 lines is refused: \(kinds([refused])))")

        // Per-note work budget (Gemini review F-06): 8,000,000 cells for the whole note, 2,000 blocks per side.
        // Two blocks of 1,413 distinct lines on each side: 4 diffs of 1,414 x 1,414 = 7,997,584 cells, the most
        // the budget allows. One more line per block and the note is refused.
        func blocks(_ k: Int, _ p: String, _ n: Int) -> String { (0..<k).map { "# S\($0)\n" + numbered("\(p)\($0) ", n) }.joined() }
        let (cb, cm, ct) = (blocks(2, "base ", 1_413), blocks(2, "mine ", 1_413), blocks(2, "theirs ", 1_413))
        let cellsWorst = try mergeFile(base: cb, mine: cm, theirs: ct)
        report("budget: 2 blocks x 1,413 lines (7,997,584 cells)", try time3 { try mergeFile(base: cb, mine: cm, theirs: ct).copy?.utf8.count ?? 0 },
               note: kinds([cellsWorst]))
        let (ob, om, ot) = (blocks(2, "base ", 1_414), blocks(2, "mine ", 1_414), blocks(2, "theirs ", 1_414))
        report("budget: 2 blocks x 1,414 lines (over, refused)", try time3 { try mergeFile(base: ob, mine: om, theirs: ot).copy?.utf8.count ?? 0 },
               note: kinds([try mergeFile(base: ob, mine: om, theirs: ot)]))
        let (fb, fm, ft) = (blocks(8, "base ", 1_000), blocks(8, "mine ", 1_000), blocks(8, "theirs ", 1_000))
        report("budget: 8 blocks x 1,000 lines (refused midway)", try time3 { try mergeFile(base: fb, mine: fm, theirs: ft).copy?.utf8.count ?? 0 },
               note: kinds([try mergeFile(base: fb, mine: fm, theirs: ft)]))
        // 2,000 headings, both sides edit every block (mine line a, theirs line c): 2,000 small diff3s, merged.
        func headed(_ n: Int, _ a: String, _ c: String) -> String { (0..<n).map { "## H\($0)\na\($0)\(a)\nb\($0)\nc\($0)\(c)\n" }.joined() }
        let (hb, hm, ht) = (headed(2_000, "", ""), headed(2_000, " mine", ""), headed(2_000, "", " theirs"))
        let headWorst = try mergeFile(base: hb, mine: hm, theirs: ht)
        report("budget: 2,000 blocks, all edited on both sides", try time3 { try mergeFile(base: hb, mine: hm, theirs: ht).content?.utf8.count ?? 0 },
               note: kinds([headWorst]))
        let (h1b, h1m, h1t) = (headed(2_001, "", ""), headed(2_001, " mine", ""), headed(2_001, "", " theirs"))
        report("budget: 2,001 blocks (over, refused)", try time3 { try mergeFile(base: h1b, mine: h1m, theirs: h1t).copy?.utf8.count ?? 0 },
               note: kinds([try mergeFile(base: h1b, mine: h1m, theirs: h1t)]))
        print("")

        // Path rules over 5,000 new paths: NFC, the path policy, and the case/NFC clash check
        // against an index of 2,434 existing notes (the size of the brain at HEAD).
        var existing = PathIndex()
        for i in 0..<2_434 { existing.add(["people", "companies", "notes", "ideas", "projects/magen"][i % 5] + "/note-\(i).md") }
        let paths: [String] = (0..<5_000).map { i in
            switch i % 10 {
            case 0..<6: return ["people", "companies", "notes", "_inbox", "ideas", "projects/gbrain"][i % 6] + "/new-note-\(i).md"
            case 6, 7: return "מחשבות/רעיון-\(i).md"
            case 8: return "people/Ame\u{301}lie-\(i).md" // NFD, as typed on some keyboards
            default: return "People/Note-\(i).md" // clashes with the existing people/ folder
            }
        }
        let policy = time3 {
            var ok = 0
            for raw in paths where checkPath(nfc(raw), content: nil) == nil { ok += 1 }
            return ok
        }
        report("paths: 5,000 x (NFC + checkPath)", policy, note: "\(policy.checksum / 3) pass the policy")
        let full = time3 {
            var index = existing
            var accepted = 0
            for raw in paths {
                let p = nfc(raw)
                if checkPath(p, content: nil) == nil, index.clash(p) == nil {
                    index.add(p)
                    accepted += 1
                }
            }
            return accepted
        }
        report("paths: 5,000 x (NFC + checkPath + clash check)", full, note: "\(full.checksum / 3) accepted, \(5_000 - full.checksum / 3) refused")
    }
}
