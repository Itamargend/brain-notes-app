import Foundation

/// Raw deflate (RFC 1951) in plain Swift, for platforms without Apple's Compression (Linux). A direct reading of the
/// RFC in the manner of zlib's `puff.c`: small and slow-ish, which is fine for one tarball at first sync. Compiled
/// everywhere, so the Mac test run checks it against what Compression writes.
enum Inflate {
    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
                                       3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// A canonical Huffman code as counts per length and symbols in code order.
    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init<C: Collection>(_ lengths: C) where C.Element == Int {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            var offset = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offset[l + 1] = offset[l] + count[l] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offset[l]] = sym
                offset[l] += 1
            }
        }
    }

    private static let fixedLengths = Huffman([Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112)
        + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
    private static let fixedDistances = Huffman([Int](repeating: 5, count: 30))

    private struct Reader {
        let input: [UInt8]
        var position = 0
        var bitBuffer: UInt32 = 0
        var bitCount: UInt32 = 0
        var output: [UInt8] = []

        init(_ input: [UInt8]) { self.input = input }

        /// The next `n` bits (at most 16), least significant first.
        mutating func bits(_ n: UInt32) throws -> Int {
            var value = bitBuffer
            while bitCount < n {
                guard position < input.count else { throw TarballError.inflateFailed }
                value |= UInt32(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = n == 32 ? 0 : value >> n
            bitCount -= n
            return Int(value & ((1 << n) - 1))
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1...15 {
                code |= try bits(1)
                let count = h.count[length]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw TarballError.inflateFailed
        }

        mutating func stored() throws {
            // The rest of the current byte is padding.
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw TarballError.inflateFailed }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
            position += 4
            guard length == ~complement & 0xFFFF, position + length <= input.count else { throw TarballError.inflateFailed }
            output.append(contentsOf: input[position..<(position + length)])
            position += length
        }

        mutating func codes(_ lengths: Huffman, _ distances: Huffman) throws {
            while true {
                var sym = try decode(lengths)
                if sym < 256 {
                    output.append(UInt8(sym))
                } else if sym == 256 {
                    return
                } else {
                    sym -= 257
                    guard sym < 29 else { throw TarballError.inflateFailed }
                    let lengthExtra = try bits(UInt32(Inflate.lengthExtra[sym]))
                    let length = Inflate.lengthBase[sym] + lengthExtra
                    let dsym = try decode(distances)
                    guard dsym < 30 else { throw TarballError.inflateFailed }
                    let distanceExtra = try bits(UInt32(Inflate.distanceExtra[dsym]))
                    let distance = Inflate.distanceBase[dsym] + distanceExtra
                    guard distance <= output.count else { throw TarballError.inflateFailed }
                    // Byte by byte: a copy may overlap what it is writing.
                    let start = output.count - distance
                    for k in 0..<length { output.append(output[start + k]) }
                }
            }
        }

        mutating func dynamic() throws {
            let nlen = try bits(5) + 257
            let ndist = try bits(5) + 1
            let ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw TarballError.inflateFailed }
            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<ncode { codeLengths[Inflate.codeLengthOrder[i]] = try bits(3) }
            let lengthCode = Huffman(codeLengths)
            var lengths = [Int](repeating: 0, count: nlen + ndist)
            var index = 0
            while index < nlen + ndist {
                let sym = try decode(lengthCode)
                if sym < 16 {
                    lengths[index] = sym
                    index += 1
                    continue
                }
                var value = 0
                let repeats: Int
                switch sym {
                case 16:
                    guard index > 0 else { throw TarballError.inflateFailed }
                    value = lengths[index - 1]
                    repeats = try bits(2) + 3
                case 17:
                    repeats = try bits(3) + 3
                default:
                    repeats = try bits(7) + 11
                }
                guard index + repeats <= nlen + ndist else { throw TarballError.inflateFailed }
                for _ in 0..<repeats {
                    lengths[index] = value
                    index += 1
                }
            }
            guard lengths[256] != 0 else { throw TarballError.inflateFailed }
            try codes(Huffman(lengths[0..<nlen]), Huffman(lengths[nlen...]))
        }
    }

    /// The bytes of a raw deflate stream. Throws `TarballError.inflateFailed` on anything malformed or cut short.
    static func raw(_ input: [UInt8]) throws -> [UInt8] {
        var r = Reader(input)
        while true {
            let last = try r.bits(1)
            switch try r.bits(2) {
            case 0: try r.stored()
            case 1: try r.codes(fixedLengths, fixedDistances)
            case 2: try r.dynamic()
            default: throw TarballError.inflateFailed
            }
            if last == 1 { return r.output }
        }
    }

    /// A valid raw deflate stream of stored (uncompressed) blocks. For the fake's tarballs where Compression is missing.
    static func stored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 5 * (data.count / 65535 + 1))
        var i = 0
        repeat {
            let n = min(65535, data.count - i)
            out.append(i + n == data.count ? 1 : 0)  // BFINAL, then BTYPE 00 and padding to the byte
            out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += data[i..<(i + n)]
            i += n
        } while i < data.count
        return out
    }
}
