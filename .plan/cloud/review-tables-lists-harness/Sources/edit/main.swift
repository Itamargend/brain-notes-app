import BrainNotesTables
// stdin: notes separated by \u{1E}. For each: edit every table at random, then print the new note, \u{1F}, and the
// model's view of each table (header + body cells padded/cut to the column count, cells joined by \u{1D}, rows by
// \u{1C}, tables by \u{1B}). Records end with \u{1E}.
struct R: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
var data: [UInt8] = []
while let line = readLine(strippingNewline: false) { data += Array(line.utf8) }
let texts = ["a", "b c", "שלום", "", " ", "|", "a|b", "1. x", "- x", "# x", "> x", "---", ":-:", "x |", "| x", "  pad  ", "1)", "+ y", "* z", "***"]
var r = R(s: 42)
var out = ""
for note in String(decoding: data, as: UTF8.self).split(separator: "\u{1E}", omittingEmptySubsequences: false) {
    var doc = TableDocument(parsing: String(note))
    for t in doc.tables.indices {
        doc.updateTable(at: t) { table in
            for _ in 0..<(1 + Int.random(in: 0..<5, using: &r)) {
                let cols = table.columnCount, rows = table.rows.count
                let text = texts.randomElement(using: &r)!
                switch Int.random(in: 0..<7, using: &r) {
                case 0 where rows > 0: try? table.setCell(row: Int.random(in: 0..<rows, using: &r), column: Int.random(in: 0..<cols, using: &r), to: text)
                case 1: try? table.setHeader(column: Int.random(in: 0..<cols, using: &r), to: text)
                case 2: try? table.insertRow(at: Int.random(in: 0...rows, using: &r), texts: (0..<Int.random(in: 0...cols, using: &r)).map { _ in texts.randomElement(using: &r)! })
                case 3 where rows > 0: try? table.removeRow(at: Int.random(in: 0..<rows, using: &r))
                case 4: try? table.insertColumn(at: Int.random(in: 0...cols, using: &r), header: text, alignment: MarkdownTable.Alignment.allCases.randomElement(using: &r)!)
                case 5 where cols > 1: try? table.removeColumn(at: Int.random(in: 0..<cols, using: &r))
                case 6: try? table.setAlignment(MarkdownTable.Alignment.allCases.randomElement(using: &r)!, column: Int.random(in: 0..<cols, using: &r))
                default: break
                }
            }
        }
    }
    let views = doc.tables.map { t -> String in
        let n = t.columnCount
        func cut(_ c: [String]) -> [String] { (0..<n).map { $0 < c.count ? c[$0] : "" } }
        return "T" + ([cut(t.headerTexts)] + t.rows.map { cut($0.texts) }).map { $0.joined(separator: "\u{1D}") }.joined(separator: "\u{1C}")
    }
    out += doc.markdown + "\u{1F}" + views.joined(separator: "\u{1B}") + "\u{1E}"
}
print(out, terminator: "")
