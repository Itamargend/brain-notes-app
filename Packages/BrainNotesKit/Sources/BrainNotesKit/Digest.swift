#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

// Git blob ids, the fake's object ids and outbox hashes need SHA-1 and SHA-256. Apple platforms use CryptoKit. Linux
// has no CryptoKit, and the package takes no dependency but GRDB, so it uses the plain Swift versions below. Those are
// compiled everywhere, so the tests on a Mac check them against CryptoKit as well as the published test vectors.

/// SHA-1, through CryptoKit where it exists. Same bytes either way.
struct SHA1Hasher {
    #if canImport(CryptoKit)
    private var inner = Insecure.SHA1()
    #else
    private var inner = PortableSHA1()
    #endif

    mutating func update(data: Data) { inner.update(data: data) }

    /// Lowercase hex of the digest.
    func hex() -> String { hexString(inner.finalize()) }
}

/// SHA-256 hex of some bytes, through CryptoKit where it exists.
func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return hexString(SHA256.hash(data: data))
    #else
    var h = PortableSHA256()
    h.update(data: data)
    return hexString(h.finalize())
    #endif
}

// MARK: - Plain Swift versions (FIPS 180-4)

/// The message schedule both hashes share: 64-byte blocks, big-endian words, a length in bits at the end.
private struct BlockFeeder {
    var pending: [UInt8] = []
    var length: UInt64 = 0

    /// Calls `block` with each complete 64-byte block of `bytes` (after what was pending), keeps the rest.
    mutating func feed(_ bytes: [UInt8], _ block: (_ bytes: [UInt8], _ offset: Int) -> Void) {
        length &+= UInt64(bytes.count)
        var i = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, bytes.count)
            pending.append(contentsOf: bytes[0..<take])
            i = take
            if pending.count == 64 {
                block(pending, 0)
                pending.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= bytes.count {
            block(bytes, i)
            i += 64
        }
        if i < bytes.count { pending.append(contentsOf: bytes[i...]) }
    }

    /// The padded last block or two: 0x80, zeros, then the length in bits, big-endian.
    func tail() -> [UInt8] {
        var out = pending
        out.append(0x80)
        while out.count % 64 != 56 { out.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        return out
    }
}

@inline(__always) private func word(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}

@inline(__always) private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
@inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

private func bigEndianBytes(_ words: [UInt32]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(words.count * 4)
    for w in words {
        out.append(UInt8(truncatingIfNeeded: w >> 24))
        out.append(UInt8(truncatingIfNeeded: w >> 16))
        out.append(UInt8(truncatingIfNeeded: w >> 8))
        out.append(UInt8(truncatingIfNeeded: w))
    }
    return out
}

struct PortableSHA1 {
    private var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    private var feeder = BlockFeeder()

    mutating func update(data: Data) {
        var h = self.h
        feeder.feed([UInt8](data)) { b, o in Self.compress(&h, b, o) }
        self.h = h
    }

    func finalize() -> [UInt8] {
        var h = self.h
        let tail = feeder.tail()
        var i = 0
        while i < tail.count {
            Self.compress(&h, tail, i)
            i += 64
        }
        return bigEndianBytes(h)
    }

    private static func compress(_ h: inout [UInt32], _ b: [UInt8], _ o: Int) {
        var w = [UInt32](repeating: 0, count: 80)
        for t in 0..<16 { w[t] = word(b, o + 4 * t) }
        for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
        var a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4]
        for t in 0..<80 {
            let f: UInt32
            let k: UInt32
            switch t {
            case 0..<20:
                f = (bb & c) | (~bb & d)
                k = 0x5A82_7999
            case 20..<40:
                f = bb ^ c ^ d
                k = 0x6ED9_EBA1
            case 40..<60:
                f = (bb & c) | (bb & d) | (c & d)
                k = 0x8F1B_BCDC
            default:
                f = bb ^ c ^ d
                k = 0xCA62_C1D6
            }
            let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
            e = d
            d = c
            c = rotl(bb, 30)
            bb = a
            a = temp
        }
        h[0] = h[0] &+ a
        h[1] = h[1] &+ bb
        h[2] = h[2] &+ c
        h[3] = h[3] &+ d
        h[4] = h[4] &+ e
    }
}

struct PortableSHA256 {
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
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var feeder = BlockFeeder()

    mutating func update(data: Data) {
        var h = self.h
        feeder.feed([UInt8](data)) { b, o in Self.compress(&h, b, o) }
        self.h = h
    }

    func finalize() -> [UInt8] {
        var h = self.h
        let tail = feeder.tail()
        var i = 0
        while i < tail.count {
            Self.compress(&h, tail, i)
            i += 64
        }
        return bigEndianBytes(h)
    }

    private static func compress(_ h: inout [UInt32], _ b: [UInt8], _ o: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 { w[t] = word(b, o + 4 * t) }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & bb) ^ (a & c) ^ (bb & c)
            let temp2 = s0 &+ maj
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = bb
            bb = a
            a = temp1 &+ temp2
        }
        h[0] = h[0] &+ a
        h[1] = h[1] &+ bb
        h[2] = h[2] &+ c
        h[3] = h[3] &+ d
        h[4] = h[4] &+ e
        h[5] = h[5] &+ f
        h[6] = h[6] &+ g
        h[7] = h[7] &+ hh
    }
}
