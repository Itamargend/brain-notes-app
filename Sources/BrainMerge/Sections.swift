// Port of spec/merge/ref/sections.ts (merge spec section 2).
// A note is a list of blocks: optional frontmatter, optional preamble, then one block per ATX heading.
// Joining the blocks gives back the exact input bytes.
//
// The reference uses these regexes on each line (the line includes its "\n" or "\r\n"):
//   ATX        /^ {0,3}#{1,6}(?:[ \t]|\r?\n|$)/
//   FENCE_OPEN /^ {0,3}(`{3,}|~{3,})/
//   fence end  /^ {0,3}(`+|~+)[ \t]*\r?\n?$/
//   FM_DELIM   /^---[ \t]*\r?\n?$/
//   FM_CLOSE   /^(?:---|\.\.\.)[ \t]*\r?\n?$/
// They only look at ASCII, so they are matched here byte by byte. Without the `m` flag, `$` means
// the end of the line string, after any "\n".

public struct Block: Sendable {
    /// "fm" for frontmatter, "pre" for text before the first heading, else the heading line without
    /// its EOL and trailing spaces/tabs, plus "#<n>" (1-based occurrence).
    public var key: String
    public var lines: [String]

    public init(key: String, lines: [String]) {
        self.key = key
        self.lines = lines
    }
}

/// ` {0,3}` at the start: the number of leading spaces, or nil when there are 4 or more.
@inline(__always)
private func leadingSpaces(_ b: UnsafeBufferPointer<UInt8>) -> Int? {
    var p = 0
    while p < b.count && b[p] == 0x20 {
        p += 1
        if p > 3 { return nil }
    }
    return p
}

/// `[ \t]*\r?\n?$` starting at `start`.
@inline(__always)
private func blankToEnd(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Bool {
    var q = start
    while q < b.count && (b[q] == 0x20 || b[q] == 0x09) { q += 1 }
    if q < b.count && b[q] == 0x0D { q += 1 }
    if q < b.count && b[q] == 0x0A { q += 1 }
    return q == b.count
}

/// ATX heading: up to 3 spaces, 1 to 6 `#`, then a space, a tab, "\n", "\r\n", or the end.
private func isATXHeading(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
    guard let p = leadingSpaces(b) else { return false }
    var q = p
    while q < b.count && b[q] == 0x23 { q += 1 }
    let hashes = q - p
    guard hashes >= 1 && hashes <= 6 else { return false }
    if q == b.count { return true }
    switch b[q] {
    case 0x20, 0x09, 0x0A: return true
    case 0x0D: return q + 1 < b.count && b[q + 1] == 0x0A
    default: return false
    }
}

/// Run of a fence character after up to 3 spaces: (character, run length), or nil.
@inline(__always)
private func fenceRun(_ b: UnsafeBufferPointer<UInt8>) -> (char: UInt8, length: Int, end: Int)? {
    guard let p = leadingSpaces(b), p < b.count else { return nil }
    let c = b[p]
    guard c == 0x60 || c == 0x7E else { return nil }
    var q = p
    while q < b.count && b[q] == c { q += 1 }
    return (c, q - p, q)
}

/// FENCE_OPEN: 3 or more backticks or tildes after up to 3 spaces. Anything may follow.
private func fenceOpen(_ b: UnsafeBufferPointer<UInt8>) -> (char: UInt8, length: Int)? {
    guard let run = fenceRun(b), run.length >= 3 else { return nil }
    return (run.char, run.length)
}

/// Closing fence candidate: a run of backticks or tildes followed only by spaces/tabs and the EOL.
private func fenceClose(_ b: UnsafeBufferPointer<UInt8>) -> (char: UInt8, length: Int)? {
    guard let run = fenceRun(b), blankToEnd(b, from: run.end) else { return nil }
    return (run.char, run.length)
}

private func isFrontmatterOpen(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
    b.count >= 3 && b[0] == 0x2D && b[1] == 0x2D && b[2] == 0x2D && blankToEnd(b, from: 3)
}

private func isFrontmatterClose(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
    guard b.count >= 3 else { return false }
    let dashes = b[0] == 0x2D && b[1] == 0x2D && b[2] == 0x2D
    let dots = b[0] == 0x2E && b[1] == 0x2E && b[2] == 0x2E
    return (dashes || dots) && blankToEnd(b, from: 3)
}

/// `line.replace(/\r?\n$/, "").replace(/[ \t]+$/, "")`
private func headingKey(_ line: String) -> String {
    withUTF8Bytes(line) { (b) -> String in
        var end = b.count
        if end > 0 && b[end - 1] == 0x0A {
            end -= 1
            if end > 0 && b[end - 1] == 0x0D { end -= 1 }
        }
        while end > 0 && (b[end - 1] == 0x20 || b[end - 1] == 0x09) { end -= 1 }
        return utf8String(b, 0, end)
    }
}

public func splitBlocks(_ text: String) -> [Block] {
    let lines = splitLines(text)
    var blocks: [Block] = []
    var start = 0
    if let first = lines.first, withUTF8Bytes(first, isFrontmatterOpen) {
        var close = -1
        var j = 1
        while j < lines.count {
            if withUTF8Bytes(lines[j], isFrontmatterClose) {
                close = j
                break
            }
            j += 1
        }
        if close > 0 {
            blocks.append(Block(key: "fm", lines: Array(lines[0...close])))
            start = close + 1
        }
    }
    var seen: [ExactKey: Int] = [:]
    var current: Int? = nil
    var fence: (char: UInt8, length: Int)? = nil
    for line in lines[start...] {
        var heading = false
        withUTF8Bytes(line) { b in
            if let open = fence {
                if let close = fenceClose(b), close.char == open.char, close.length >= open.length { fence = nil }
            } else if let opened = fenceOpen(b) {
                fence = opened
            } else if isATXHeading(b) {
                heading = true
            }
        }
        if heading {
            let head = headingKey(line)
            let n = (seen[ExactKey(head)] ?? 0) + 1
            seen[ExactKey(head)] = n
            blocks.append(Block(key: head + "#" + String(n), lines: [line]))
            current = blocks.count - 1
            continue
        }
        if current == nil {
            blocks.append(Block(key: "pre", lines: []))
            current = blocks.count - 1
        }
        blocks[current!].lines.append(line)
    }
    return blocks
}

/// Concatenate blocks; a block that is not last and lacks a final EOL gets one (spec 5.4), using `eol`.
public func joinBlocks(_ blocks: [Block], eol: String) -> String {
    var s = ""
    for (idx, block) in blocks.enumerated() {
        var t = block.lines.joined()
        // `t.hasSuffix("\n")` would be wrong: in Swift a trailing "\r\n" is one Character, not "\n".
        if idx < blocks.count - 1 && !t.isEmpty && t.utf8.last != 0x0A { t += eol }
        s += t
    }
    return s
}

/// "\r\n" when CRLF endings outnumber bare LF endings, else "\n".
public func detectEol(_ text: String) -> String {
    withUTF8Bytes(text) { (b) -> String in
        var crlf = 0
        var lf = 0
        for i in 0..<b.count where b[i] == 0x0A {
            if i > 0 && b[i - 1] == 0x0D { crlf += 1 } else { lf += 1 }
        }
        return crlf > lf ? "\r\n" : "\n"
    }
}
