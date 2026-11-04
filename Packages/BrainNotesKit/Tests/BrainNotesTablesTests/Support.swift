import Foundation
import Testing
@testable import BrainNotesTables

// Text is compared as bytes everywhere: Swift's `==` calls canonically equivalent strings equal, and byte-identical
// is the promise under test.

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// The running log fixture, exactly as stored.
func runningLog() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "running-log", withExtension: "md", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    return try #require(String(validating: data, as: UTF8.self))
}

/// `text` with the first occurrence of `old` replaced by `new`, found and replaced by bytes.
func replacingFirst(_ old: String, with new: String, in text: String) -> String? {
    let t = bytes(text)
    let o = bytes(old)
    guard !o.isEmpty, o.count <= t.count else { return nil }
    for start in 0...(t.count - o.count) where t[start..<(start + o.count)].elementsEqual(o) {
        return String(decoding: t[..<start] + bytes(new) + t[(start + o.count)...], as: UTF8.self)
    }
    return nil
}

/// The table at `index` of `text`, changed by `change`, and the whole text after it.
func edited(_ text: String, table index: Int = 0, _ change: (inout MarkdownTable) throws -> Void) throws -> String {
    var doc = TableDocument(parsing: text)
    try doc.updateTable(at: index, change)
    return doc.markdown
}

/// SplitMix64: deterministic, so a failing seed can be replayed.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int.random(in: 0..<n, using: &self) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    mutating func chance(_ n: Int) -> Bool { int(n) == 0 }
}

/// Random notes full of table-shaped lines: real tables, broken ones, fences, quotes, lists, ragged rows, every line
/// ending, Hebrew, direction marks, escaped pipes and backslashes, and pipes inside backticks.
enum RandomNotes {
    static let words = [
        "a", "run", "5.20", "0:27:44", "ריצה", "שבוע טוב", "`x\\|y`", "`a|b`", "a\\|b", "\\", "x\\", "", "  ", "🏃",
        "\u{200F}ריצה", "\u{200E}10K", "PB!", "# h", "- li", "> q", "---", "1. n", "```", ":--", "|", "\\\\|", "ק\"מ",
    ]
    static let lineEndings = ["\n", "\r\n", "\r"]

    static func cellText(_ r: inout SeededRandom) -> String { r.pick(words) }

    static func row(_ cells: Int, _ r: inout SeededRandom) -> String {
        let indent = r.pick(["", "", " ", "   ", "\t"])
        var parts: [String] = []
        for _ in 0..<cells {
            // Pipes in a word are written escaped. A word ending in a backslash still hides the next pipe, as it should.
            let word = String(decoding: bytes(cellText(&r)).flatMap { (b: UInt8) -> [UInt8] in b == 0x7C ? [0x5C, 0x7C] : [b] }, as: UTF8.self)
            parts.append(r.pick(["", " ", "  ", "\t"]) + word + r.pick(["", " ", "  "]))
        }
        let open = r.chance(2) ? "|" : ""
        let close = r.chance(2) ? "|" + r.pick(["", " "]) : ""
        return indent + open + parts.joined(separator: "|") + close
    }

    static func delimiter(_ cells: Int, _ r: inout SeededRandom) -> String {
        var parts: [String] = []
        for _ in 0..<cells {
            parts.append(r.pick(["", " "]) + r.pick(["-", "---", ":--", "--:", ":-:", "-----:"]) + r.pick(["", " "]))
        }
        return (r.chance(2) ? "|" : "") + parts.joined(separator: "|") + (r.chance(2) ? "|" : "")
    }

    static func note(_ r: inout SeededRandom) -> String {
        var lines: [String] = []
        for _ in 0..<r.int(12) {
            if r.int(10) < 4 {
                let columns = 1 + r.int(4)
                lines.append(row(columns, &r))
                let delimiterCells = r.chance(5) ? columns + 1 : columns
                lines.append(delimiter(delimiterCells, &r))
                for _ in 0..<r.int(5) {
                    let cells = max(1, columns + r.int(3) - 1)
                    lines.append(row(cells, &r))
                }
            } else {
                let tableish = row(2, &r)
                lines.append(r.pick([
                    "text", "", "  ", "```", "~~~~", "# head", "> q", "- item", "    | code | x |", "| a | b |",
                    "|---|---|", "---", "a|b", "plain | pipes", "שורה | עם | צינורות", tableish,
                ]))
            }
        }
        let ending = r.pick(lineEndings)
        var text = ""
        for (k, line) in lines.enumerated() {
            if k > 0 { text += r.chance(4) ? r.pick(lineEndings) : ending }
            text += line
        }
        if r.chance(2) { text += ending }
        if r.chance(8) { text = "\u{FEFF}" + text }
        return text
    }
}

extension MarkdownTable {
    /// What GitHub would show: header texts, alignments and every body row's texts.
    var shown: [[String]] {
        [headerTexts, alignments.map { "\($0)" }] + rows.map(\.texts)
    }

    /// A header of only delimiter cells (`---`, `:-:`) can read as a delimiter row under the line above it.
    var headerLooksLikeDelimiter: Bool { header.cells.allSatisfy { TableSyntax.isMarker($0.raw) } }
}
