#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
@testable import BrainNotesKit

/// The plain Swift hashes Linux uses (review H1). Compiled and checked on every platform.
@Suite struct DigestTests {
    private func sha1(_ data: Data) -> String {
        var h = PortableSHA1()
        h.update(data: data)
        return hexString(h.finalize())
    }

    private func sha256(_ data: Data) -> String {
        var h = PortableSHA256()
        h.update(data: data)
        return hexString(h.finalize())
    }

    /// FIPS 180-4 examples, and the 448-bit message whose padding needs a second block.
    @Test func publishedVectors() {
        let two = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(sha1(Data()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(sha1(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(sha1(two) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(sha256(two) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func aMillionAs() {
        let a = Data(repeating: 0x61, count: 1_000_000)
        #expect(sha1(a) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        #expect(sha256(a) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Fed in pieces that cut across block edges, the digest is the same as fed at once.
    @Test func piecesGiveTheSameDigest() {
        let data = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        for cut in [1, 55, 56, 63, 64, 65, 127, 128, 500] {
            var h = PortableSHA1()
            h.update(data: data.prefix(cut))
            h.update(data: data.dropFirst(cut))
            #expect(hexString(h.finalize()) == sha1(data), "cut at \(cut)")
            var g = PortableSHA256()
            g.update(data: data.prefix(cut))
            g.update(data: data.dropFirst(cut))
            #expect(hexString(g.finalize()) == sha256(data), "cut at \(cut)")
        }
    }

    /// What `git hash-object` gives.
    @Test func gitBlobIds() {
        #expect(GitBlob.sha("hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitBlob.sha("") == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    #if canImport(CryptoKit)
    /// Where both exist they agree, on lengths around every block edge.
    @Test func agreesWithCryptoKit() {
        for n in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000, 4097] {
            let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) })
            #expect(sha1(data) == hexString(Insecure.SHA1.hash(data: data)), "SHA-1, \(n) bytes")
            #expect(sha256(data) == hexString(SHA256.hash(data: data)), "SHA-256, \(n) bytes")
        }
    }
    #endif
}
