import Foundation

// Why this file exists
//
// The TypeScript reference treats a string as a list of UTF-16 code units: `===` compares code
// units, `<` orders by code unit, `split("\n")` cuts at a code unit and the regexes match code
// units. Swift's String works differently, in ways that would silently change merge results:
//
//   - `==` and hashing use canonical equivalence, so "e\u{301}" == "\u{e9}" (NFD equals NFC).
//     The spec compares lines and paths exactly (sections 1 and 6.2), so that would be wrong.
//   - "\r\n" is one Character, so `"a\r\n".hasSuffix("\n")` is false and `split(separator: "\n")`
//     does not cut a CRLF line.
//   - `<` orders by Unicode scalar; JS orders by UTF-16 code unit, which puts astral characters
//     (surrogates 0xD800-0xDFFF) before U+E000-U+FFFF.
//   - `lowercased()` maps each scalar on its own; JS (ICU) also applies Final_Sigma. (The clash key,
//     `foldKey`, avoids that rule on purpose: it maps ς to σ, see `caseFold`.)
//
// So nothing in this module uses String ==, <, hashing, hasSuffix or split on content or paths.
// It works on UTF-8 bytes (equal bytes <=> equal code units, and every ASCII byte the patterns
// look for is a whole character) and on UTF-16 code units where order matters.

/// Exact equality, like JS `===` on strings.
@inline(__always)
func exactEqual(_ a: String, _ b: String) -> Bool {
    let ua = a.utf8, ub = b.utf8
    guard ua.count == ub.count else { return false }
    let fast: Bool?? = ua.withContiguousStorageIfAvailable { pa in
        ub.withContiguousStorageIfAvailable { pb in
            pa.isEmpty || memcmp(pa.baseAddress!, pb.baseAddress!, pa.count) == 0
        }
    }
    if let outer = fast, let result = outer { return result }
    return ua.elementsEqual(ub)
}

/// Exact equality of two optional documents (`null === null`, `null !== ""`).
@inline(__always)
func docEqual(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return exactEqual(x, y)
    default: return false
    }
}

/// A dictionary key that compares and hashes a string by its exact bytes (JS Map/Set key semantics).
struct ExactKey: Hashable, Sendable {
    let string: String

    init(_ string: String) { self.string = string }

    static func == (lhs: ExactKey, rhs: ExactKey) -> Bool { exactEqual(lhs.string, rhs.string) }

    func hash(into hasher: inout Hasher) {
        let hashed: Void? = string.utf8.withContiguousStorageIfAvailable {
            hasher.combine(bytes: UnsafeRawBufferPointer($0))
        }
        if hashed == nil {
            var native = string
            native.makeContiguousUTF8()
            _ = native.utf8.withContiguousStorageIfAvailable { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }
}

/// Runs `body` over the string's UTF-8 bytes without copying when the string is native.
@inline(__always)
func withUTF8Bytes<R>(_ s: String, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
    if let result = try s.utf8.withContiguousStorageIfAvailable(body) { return result }
    return try Array(s.utf8).withUnsafeBufferPointer(body)
}

/// The string for bytes `from..<to` of `b`. Callers cut only next to ASCII bytes, so the slice is valid UTF-8.
@inline(__always)
func utf8String(_ b: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> String {
    String(decoding: UnsafeBufferPointer(rebasing: b[from..<to]), as: UTF8.self)
}

@inline(__always)
func isASCII(_ s: String) -> Bool {
    withUTF8Bytes(s) { (b) -> Bool in
        for byte in b where byte >= 0x80 { return false }
        return true
    }
}

/// JS `a < b` on strings: UTF-16 code unit order.
@inline(__always)
func utf16Less(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

/// `s.split(sep)` in JS for a one-byte ASCII separator: empty pieces are kept, "" gives [""].
func splitKeepingEmpty(_ s: String, on separator: UInt8) -> [String] {
    withUTF8Bytes(s) { (b) -> [String] in
        var out: [String] = []
        var start = 0
        for i in 0..<b.count where b[i] == separator {
            out.append(utf8String(b, start, i))
            start = i + 1
        }
        out.append(utf8String(b, start, b.count))
        return out
    }
}

/// `s.replace(/\.md$/i, "")`. Without the `u` flag, `/i` never matches a non-ASCII character to
/// ASCII, so this is exactly a trailing ".", "m" or "M", "d" or "D".
func dropMarkdownExtension(_ s: String) -> String {
    withUTF8Bytes(s) { (b) -> String in
        let n = b.count
        if n >= 3, b[n - 3] == 0x2E, (b[n - 2] | 0x20) == 0x6D, (b[n - 1] | 0x20) == 0x64 {
            return utf8String(b, 0, n - 3)
        }
        return s
    }
}

/// `s.normalize("NFC")`. ASCII is already NFC.
public func nfc(_ s: String) -> String {
    if isASCII(s) { return s }
    var out = s.precomposedStringWithCanonicalMapping
    out.makeContiguousUTF8()
    return out
}

/// `s.normalize("NFD")`. ASCII is already NFD.
public func nfd(_ s: String) -> String {
    if isASCII(s) { return s }
    var out = s.decomposedStringWithCanonicalMapping
    out.makeContiguousUTF8()
    return out
}

/// The case-fold step of `foldKey` (spec 6.3), per scalar and without context, like the reference's
/// `c.toLowerCase().toUpperCase().toLowerCase()` per code point: full lowercase, then full uppercase
/// of each result, then full lowercase of each of those. Dotless "ı" (U+0131) is kept, because its
/// uppercase is plain "I". Final sigma "ς" becomes "σ". The caller does NFD before and NFC after.
func caseFold(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars {
        if c.value == 0x0131 {
            out.append(c)
            continue
        }
        for l in c.properties.lowercaseMapping.unicodeScalars {
            for u in l.properties.uppercaseMapping.unicodeScalars {
                for x in u.properties.lowercaseMapping.unicodeScalars {
                    out.append(x.value == 0x03C2 ? "\u{03C3}" : x)
                }
            }
        }
    }
    return String(out)
}

/// `s.toLowerCase()`. V8 hands this to ICU's root-locale `u_strToLower`: every scalar gets its full
/// Unicode lowercase mapping (so "İ" becomes "i̇", two scalars), plus the one context rule that
/// applies without a locale: a capital sigma at the end of a word becomes "ς" (Final_Sigma).
/// Swift's `lowercased()` has no Final_Sigma rule, so "ΟΔΟΣ/" would fold to "οδοσ/", not "οδος/".
func jsLowercase(_ s: String) -> String {
    if isASCII(s) {
        return withUTF8Bytes(s) { (b) -> String in
            var hasUpper = false
            for byte in b where byte >= 0x41 && byte <= 0x5A {
                hasUpper = true
                break
            }
            if !hasUpper { return s }
            return String(decoding: b.map { ($0 >= 0x41 && $0 <= 0x5A) ? ($0 | 0x20) : $0 }, as: UTF8.self)
        }
    }
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for i in scalars.indices {
        let c = scalars[i]
        if c.value == 0x03A3 {
            let sigma: Unicode.Scalar = isFinalSigma(scalars, at: i) ? "\u{03C2}" : "\u{03C3}"
            out.append(sigma)
        } else {
            out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
        }
    }
    return String(out)
}

/// Final_Sigma as ICU tests it: preceded by a cased letter and not followed by one, skipping
/// case-ignorable characters in both directions (ICU checks "case-ignorable" before "cased").
private func isFinalSigma(_ s: [Unicode.Scalar], at i: Int) -> Bool {
    casedLetter(s, from: i, step: -1) && !casedLetter(s, from: i, step: 1)
}

private func casedLetter(_ s: [Unicode.Scalar], from i: Int, step: Int) -> Bool {
    var j = i + step
    while j >= 0 && j < s.count {
        let p = s[j].properties
        if p.isCaseIgnorable {
            j += step
            continue
        }
        return p.isCased
    }
    return false
}

/// `JSON.stringify(s)` for a string: double quotes; escapes `"`, `\`, \b \f \n \r \t, and other
/// C0 controls as lowercase \u00xx. Everything else, DEL and U+2028 included, is kept as is.
public func yamlStr(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00..<0x20:
            let hex = String(u.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default:
            out.unicodeScalars.append(u)
        }
    }
    out += "\""
    return out
}
