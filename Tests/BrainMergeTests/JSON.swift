import Foundation

// A small JSON reader for the test fixtures. Foundation's JSONSerialization is not used because it
// returns unordered dictionaries with Swift String keys, which would merge an NFC and an NFD key and
// lose `Object.keys` order. Here objects keep their order and strings keep their exact scalars.

enum JSON: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([(key: String, value: JSON)])
}

/// Exact string equality for tests (Swift's `==` treats NFC and NFD as equal).
func sameText(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

extension JSON {
    subscript(key: String) -> JSON? {
        guard case let .object(members) = self else { return nil }
        return members.first { sameText($0.key, key) }?.value
    }

    var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var array: [JSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var members: [(key: String, value: JSON)]? {
        if case let .object(m) = self { return m }
        return nil
    }

    var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var int: Int? {
        if case let .number(d) = self, d.rounded() == d, abs(d) < 9.0e15 { return Int(d) }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Deep equality with exact strings; object member order does not matter.
func jsonEqual(_ a: JSON, _ b: JSON) -> Bool {
    switch (a, b) {
    case (.null, .null):
        return true
    case let (.bool(x), .bool(y)):
        return x == y
    case let (.number(x), .number(y)):
        return x == y
    case let (.string(x), .string(y)):
        return sameText(x, y)
    case let (.array(x), .array(y)):
        guard x.count == y.count else { return false }
        for i in x.indices where !jsonEqual(x[i], y[i]) { return false }
        return true
    case let (.object(x), .object(y)):
        guard x.count == y.count else { return false }
        for m in x {
            guard let other = y.first(where: { sameText($0.key, m.key) }), jsonEqual(m.value, other.value) else { return false }
        }
        return true
    default:
        return false
    }
}

extension JSON {
    /// Compact JSON with every non-ASCII or invisible scalar escaped, so NFC/NFD, CR and the like show up.
    var rendered: String {
        switch self {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(d): return d.rounded() == d && abs(d) < 9.0e15 ? String(Int(d)) : String(d)
        case let .string(s): return Self.quote(s)
        case let .array(a): return "[" + a.map(\.rendered).joined(separator: ",") + "]"
        case let .object(m): return "{" + m.map { Self.quote($0.key) + ":" + $0.value.rendered }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20..<0x7F: out.unicodeScalars.append(u)
            default: out += "\\u{" + String(u.value, radix: 16) + "}"
            }
        }
        return out + "\""
    }
}

/// A readable "expected vs got" for two values, centred on the first difference.
func describeDifference(expected: JSON, actual: JSON?) -> String {
    let e = expected.rendered
    guard let actual else { return "expected \(clip(e, around: 0)), got nothing" }
    let a = actual.rendered
    let ec = Array(e), ac = Array(a)
    var i = 0
    while i < ec.count && i < ac.count && ec[i] == ac[i] { i += 1 }
    return "first difference at character \(i): expected \(clip(e, around: i)) got \(clip(a, around: i))"
}

private func clip(_ s: String, around i: Int) -> String {
    let c = Array(s)
    if c.count <= 160 { return s }
    let lo = max(0, i - 60), hi = min(c.count, i + 100)
    return (lo > 0 ? "…" : "") + String(c[lo..<hi]) + (hi < c.count ? "…" : "")
}

struct JSONError: Error, CustomStringConvertible {
    let message: String
    let offset: Int
    var description: String { "JSON: \(message) at byte \(offset)" }
}

struct JSONParser {
    private let bytes: [UInt8]
    private var i = 0

    private init(_ data: Data) { bytes = [UInt8](data) }

    static func parse(_ data: Data) throws -> JSON {
        var p = JSONParser(data)
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.error("trailing characters") }
        return v
    }

    private func error(_ message: String) -> JSONError { JSONError(message: message, offset: i) }

    private func peek(_ c: UInt8) -> Bool { i < bytes.count && bytes[i] == c }

    private mutating func skipSpace() {
        while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09) { i += 1 }
    }

    private mutating func value(depth: Int) throws -> JSON {
        guard depth < 256 else { throw error("nesting too deep") }
        guard i < bytes.count else { throw error("unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw error("bad literal") }
        i += w.count
    }

    private mutating func object(depth: Int) throws -> JSON {
        i += 1
        var members: [(key: String, value: JSON)] = []
        skipSpace()
        if peek(UInt8(ascii: "}")) {
            i += 1
            return .object(members)
        }
        while true {
            skipSpace()
            guard peek(UInt8(ascii: "\"")) else { throw error("expected a key") }
            let key = try string()
            skipSpace()
            guard peek(UInt8(ascii: ":")) else { throw error("expected ':'") }
            i += 1
            skipSpace()
            let v = try value(depth: depth + 1)
            // Like JSON.parse: a repeated key keeps its first position and takes the last value.
            if let k = members.firstIndex(where: { sameText($0.key, key) }) {
                members[k].value = v
            } else {
                members.append((key: key, value: v))
            }
            skipSpace()
            if peek(UInt8(ascii: ",")) {
                i += 1
                continue
            }
            if peek(UInt8(ascii: "}")) {
                i += 1
                return .object(members)
            }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func array(depth: Int) throws -> JSON {
        i += 1
        var items: [JSON] = []
        skipSpace()
        if peek(UInt8(ascii: "]")) {
            i += 1
            return .array(items)
        }
        while true {
            skipSpace()
            items.append(try value(depth: depth + 1))
            skipSpace()
            if peek(UInt8(ascii: ",")) {
                i += 1
                continue
            }
            if peek(UInt8(ascii: "]")) {
                i += 1
                return .array(items)
            }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw error("short \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw error("bad \\u escape")
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    private mutating func string() throws -> String {
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let c = bytes[i]
            if c == 0x22 {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c != 0x5C {
                out.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < bytes.count else { throw error("unterminated escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if code >= 0xD800 && code < 0xDC00, i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == UInt8(ascii: "u") {
                    let save = i
                    i += 2
                    let low = try hex4()
                    if low >= 0xDC00 && low < 0xE000 {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save
                    }
                }
                // A lone surrogate cannot be stored in a Swift String; it becomes U+FFFD. The fixtures have none.
                let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                out.append(contentsOf: String(Character(scalar)).utf8)
            default:
                throw error("bad escape")
            }
        }
    }

    private mutating func number() throws -> Double {
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            let isNumberByte = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
            if !isNumberByte { break }
            i += 1
        }
        guard i > start, let d = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw error("bad number") }
        return d
    }
}
