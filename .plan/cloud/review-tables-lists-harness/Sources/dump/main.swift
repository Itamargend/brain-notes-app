import BrainNotesTables
// Reads notes separated by \u{1E} on stdin; prints per note: tables as "cols:rows" joined by ",".
var data: [UInt8] = []
while let line = readLine(strippingNewline: false) { data += Array(line.utf8) }
let all = String(decoding: data, as: UTF8.self)
for note in all.split(separator: "\u{1E}", omittingEmptySubsequences: false) {
    let doc = TableDocument(parsing: String(note))
    print(doc.tables.map { "\($0.columnCount):\($0.rows.count)" }.joined(separator: ","))
}
