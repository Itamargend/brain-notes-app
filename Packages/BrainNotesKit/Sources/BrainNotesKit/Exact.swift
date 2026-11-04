import Foundation

// Swift's String `==` and hashing use canonical equivalence, so an NFC and an NFD spelling of a name
// compare equal. GitHub can hold both as two files and the merge spec compares text exactly, so
// nothing in this package uses String equality on repo paths or note content.

/// Exact byte equality.
@inline(__always)
public func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// Exact equality of two optional texts (`nil` means the file does not exist).
public func sameDoc(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return sameBytes(x, y)
    default: return false
    }
}

/// A repo path as a dictionary key, compared and hashed by its exact bytes.
public struct PathKey: Hashable, Sendable {
    public let path: String
    public init(_ path: String) { self.path = path }
    public static func == (l: PathKey, r: PathKey) -> Bool { sameBytes(l.path, r.path) }
    public func hash(into hasher: inout Hasher) {
        var s = path
        s.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// Lowercase hex of a byte sequence.
func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for b in bytes {
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

/// UTF-8 decoding that never changes bytes: no BOM stripping, nil on invalid input.
/// `Data(text.utf8)` gives back exactly what was read, which is what "untouched notes round-trip" needs.
public func decodeNote(_ data: Data) -> String? {
    String(validating: data, as: UTF8.self)
}

/// The exact UTC string used as op time, conflict stamp and commit date: whole seconds, ending in Z.
public func isoTime(_ date: Date) -> String {
    date.formatted(.iso8601)
}

public func parseISOTime(_ s: String) -> Date? {
    try? Date(s, strategy: .iso8601)
}
