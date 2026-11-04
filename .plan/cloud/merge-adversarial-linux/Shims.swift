// Linux-only stand-ins for CryptoKit, os.Logger, Compression and the Keychain, so the platform-neutral
// parts of BrainNotesKit build and test on Linux. Never part of the app.
import CZlib
import Foundation

private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

private func padded(_ m: [UInt8]) -> [UInt8] {
    var b = m
    let bits = UInt64(m.count) * 8
    b.append(0x80)
    while b.count % 64 != 56 { b.append(0) }
    for i in (0..<8).reversed() { b.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
    return b
}

private func words(_ c: ArraySlice<UInt8>) -> [UInt32] {
    (0..<16).map { i in
        let o = c.startIndex + i * 4
        return UInt32(c[o]) << 24 | UInt32(c[o + 1]) << 16 | UInt32(c[o + 2]) << 8 | UInt32(c[o + 3])
    }
}

private func bytes(_ hs: [UInt32]) -> [UInt8] {
    hs.flatMap { h in [UInt8(h >> 24), UInt8(truncatingIfNeeded: h >> 16), UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h)] }
}

enum Insecure {
    struct SHA1 {
        private var buf: [UInt8] = []
        init() {}
        mutating func update(data: Data) { buf.append(contentsOf: data) }
        func finalize() -> [UInt8] {
            var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
            let p = padded(buf)
            for s in stride(from: 0, to: p.count, by: 64) {
                var w = words(p[s..<(s + 64)])
                for i in 16..<80 { w.append(rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)) }
                var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
                for i in 0..<80 {
                    let f: UInt32, k: UInt32
                    switch i {
                    case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                    case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                    case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                    default: f = b ^ c ^ d; k = 0xCA62C1D6
                    }
                    let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                    e = d; d = c; c = rotl(b, 30); b = a; a = t
                }
                h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
            }
            return bytes(h)
        }
    }
}

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    static func hash(data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let p = padded([UInt8](data))
        for s in stride(from: 0, to: p.count, by: 64) {
            var w = words(p[s..<(s + 64)])
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w.append(w[i - 16] &+ s0 &+ w[i - 7] &+ s1)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return bytes(h)
    }
}

struct LogMessage: ExpressibleByStringInterpolation {
    struct Interp: StringInterpolationProtocol {
        var s = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ l: String) { s += l }
        mutating func appendInterpolation<T>(_ v: T, privacy: LogPrivacy = .private) { s += "\(v)" }
    }
    let s: String
    init(stringLiteral value: String) { s = value }
    init(stringInterpolation i: Interp) { s = i.s }
}

enum LogPrivacy { case `public`, `private` }

struct Logger: Sendable {
    init(subsystem: String, category: String) {}
    func error(_ m: LogMessage) {}
    func notice(_ m: LogMessage) {}
    func info(_ m: LogMessage) {}
    func debug(_ m: LogMessage) {}
}

/// Raw deflate (no zlib header), matching Compression's `.zlib` algorithm.
enum LinuxZlib {
    static func inflate(_ data: Data) throws -> Data {
        var s = z_stream()
        guard inflateInit2_(&s, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TarballError.inflateFailed }
        defer { inflateEnd(&s) }
        var input = [UInt8](data)
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var rc: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { ip in
            s.next_in = ip.baseAddress
            s.avail_in = uInt(ip.count)
            repeat {
                chunk.withUnsafeMutableBufferPointer { cp in
                    s.next_out = cp.baseAddress
                    s.avail_out = uInt(cp.count)
                    rc = CZlib.inflate(&s, Z_NO_FLUSH)
                    out.append(cp.baseAddress!, count: cp.count - Int(s.avail_out))
                }
            } while rc == Z_OK
        }
        guard rc == Z_STREAM_END else { throw TarballError.inflateFailed }
        return out
    }

    static func deflate(_ data: Data) throws -> Data {
        var s = z_stream()
        guard deflateInit2_(&s, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TarballError.inflateFailed
        }
        defer { deflateEnd(&s) }
        var input = [UInt8](data)
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var rc: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { ip in
            s.next_in = ip.baseAddress
            s.avail_in = uInt(ip.count)
            repeat {
                chunk.withUnsafeMutableBufferPointer { cp in
                    s.next_out = cp.baseAddress
                    s.avail_out = uInt(cp.count)
                    rc = CZlib.deflate(&s, Z_FINISH)
                    out.append(cp.baseAddress!, count: cp.count - Int(s.avail_out))
                }
            } while rc == Z_OK
        }
        guard rc == Z_STREAM_END else { throw TarballError.inflateFailed }
        return out
    }
}

/// No Keychain on Linux: an in-memory store with the same surface.
public struct KeychainTokenStore: TokenStore {
    public static let service = "com.itamargendelman.brainnotes.github"
    private let inner = InMemoryTokenStore()
    public init(account: String = "default") {}
    public func load() throws -> TokenPair? { try inner.load() }
    public func save(_ pair: TokenPair) throws { try inner.save(pair) }
    public func clear() { inner.clear() }
}
