import Foundation
import Testing
@testable import BrainNotesKit

/// The plain Swift inflater Linux uses for the first-sync tarball (review H1). Compiled and checked everywhere.
@Suite struct InflateTests {
    private func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// 400 letters drawn with a fixed generator, skewed so zlib picks a dynamic Huffman block for them.
    private var skewedText: [UInt8] {
        var x = 12345
        var out: [UInt8] = []
        for _ in 0..<400 {
            x = (x * 1_103_515_245 + 12345) & 0x7fff_ffff
            let r = x % 100
            let c: Character = r < 40 ? "e" : r < 60 ? "t" : r < 72 ? "a" : r < 85 ? " " : r < 93 ? "o" : r < 98 ? "n" : "\n"
            out.append(c.asciiValue!)
        }
        return out
    }

    /// Streams written by zlib 1.3 at level 9 (`compressobj(9, DEFLATED, -15)`): one fixed block, one dynamic block.
    @Test func zlibStreams() throws {
        #expect(try Inflate.raw(bytes(hex: "cb48cdc9c957c84027b900")) == Array("hello hello hello hello\n".utf8))
        let dynamic = """
            2590b11500310842fb9b82d52868b571ff775fd34445444c1469bae229393dd15899646636d2cc954a2ed94c59b095222d37334c1e11\
            da3841c32e81828c18e9cd509be38846adc64765b0d269835106859d5d11ad0dbde17b3ced31a45b59ecc4a2091eb92dd3c3da9a00\
            ffce5a8e7056a09b2d7b2df7fa03f32acf3b6a998c1d32aa7c5defe8ede09ebdc5ceb5328bae4aded7f08d88e6d6614ce70aabb53e\
            bfa3bd5ff27343522feec1d8e4ca1f
            """
        #expect(bytes(hex: dynamic).first.map { ($0 >> 1) & 3 } == 2, "the sample really is a dynamic block")
        #expect(try Inflate.raw(bytes(hex: dynamic)) == skewedText)
    }

    @Test func storedBlocksRoundTrip() throws {
        for n in [0, 1, 1000, 65535, 65536, 140_000] {
            let data = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
            #expect(try Inflate.raw(Inflate.stored(data)) == data, "\(n) bytes")
        }
    }

    @Test func malformedStreamsThrow() {
        #expect(throws: TarballError.inflateFailed) { try Inflate.raw(bytes(hex: "cb48cdc9c9")) }  // cut short
        #expect(throws: TarballError.inflateFailed) { try Inflate.raw([0x07]) }  // block type 3
        #expect(throws: TarballError.inflateFailed) { try Inflate.raw([1, 5, 0, 0, 0] + Array("hello".utf8)) }  // bad length check
        #expect(throws: TarballError.inflateFailed) { try Inflate.raw([]) }
    }

    @Test func gzipThroughTheFallback() throws {
        let text = Array(String(repeating: "hello hebrew שלום\n", count: 1000).utf8)
        var gz = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        gz.append(contentsOf: Inflate.stored(text))
        gz.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])  // trailer: not read
        #expect(try Gzip.decompress(gz) == Data(text))
    }

    #if canImport(Compression)
    /// What Apple's Compression writes, the fallback reads, at sizes that span several blocks.
    @Test func readsWhatCompressionWrites() throws {
        var seed: UInt64 = 7
        for n in [0, 10, 5_000, 200_000] {
            var data: [UInt8] = []
            for i in 0..<n {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                // Mostly text with repeats, some noise: exercises literals, matches and long distances.
                data.append(i % 7 == 0 ? UInt8(truncatingIfNeeded: seed >> 56) : Array("brain notes ".utf8)[i % 12])
            }
            let deflated = try (Data(data) as NSData).compressed(using: .zlib) as Data
            #expect(try Inflate.raw([UInt8](deflated)) == data, "\(n) bytes")
        }
    }
    #endif
}
