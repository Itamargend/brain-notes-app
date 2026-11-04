import Compression
import Foundation

public enum TarballError: Error, Equatable, Sendable {
    case notGzip
    case truncated
    case badHeader
    case inflateFailed
}

/// Gzip (RFC 1952) via the Compression framework: strip the header and trailer, inflate the raw deflate stream.
public enum Gzip {
    public static func decompress(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw TarballError.notGzip }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard p + 2 <= b.count else { throw TarballError.truncated }
            p += 2 + Int(b[p]) + Int(b[p + 1]) << 8
        }
        if flags & 0x08 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }  // FNAME
        if flags & 0x10 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { p += 2 }  // FHCRC
        guard p < b.count - 8 else { throw TarballError.truncated }
        let deflated = Data(b[p..<(b.count - 8)])
        do {
            return try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw TarballError.inflateFailed
        }
    }

    /// Gzip container for tests and the fake server.
    public static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(deflated)
        var crc = CRC32.checksum(data).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &size, count: 4))
        return out
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

public struct TarEntry: Sendable, Equatable {
    public var path: String
    public var data: Data
}

/// Minimal ustar + pax reader. Regular files only; the first path segment (GitHub's `<owner>-<repo>-<sha>/`)
/// is stripped. Handles pax `path=` records (long and non-ASCII names) and ustar `prefix`.
public enum TarReader {
    public static func files(in tar: Data, stripFirstComponent: Bool = true) throws -> [TarEntry] {
        let b = [UInt8](tar)
        var out: [TarEntry] = []
        var p = 0
        var paxPath: String?
        var sawEnd = false

        func string(_ range: Range<Int>) -> String {
            var bytes = Array(b[range])
            if let z = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<z]) }
            return String(decoding: bytes, as: UTF8.self)
        }
        func octal(_ range: Range<Int>) -> Int {
            var v = 0
            for c in b[range] {
                if c == 0 || c == 0x20 { if v == 0 && c == 0x20 { continue } else { break } }
                guard c >= 0x30, c <= 0x37 else { break }
                v = v * 8 + Int(c - 0x30)
            }
            return v
        }
        func parsePax(_ data: ArraySlice<UInt8>) -> [String: String] {
            var res: [String: String] = [:]
            var i = data.startIndex
            while i < data.endIndex {
                // "<len> key=value\n"
                var j = i
                while j < data.endIndex, data[j] != 0x20 { j += 1 }
                // A record holds its length, a space, the key and value, and a newline. One that ends at or before its
                // own space is malformed: stop here rather than slice a range whose bounds are reversed.
                guard let len = Int(String(decoding: data[i..<j], as: UTF8.self)), len > 0, i + len <= data.endIndex,
                      j < i + len - 1 else { break }
                let rec = data[(j + 1)..<(i + len - 1)]
                if let eq = rec.firstIndex(of: 0x3D) {
                    res[String(decoding: rec[rec.startIndex..<eq], as: UTF8.self)] = String(decoding: rec[(eq + 1)...], as: UTF8.self)
                }
                i += len
            }
            return res
        }

        while p + 512 <= b.count {
            if b[p..<(p + 512)].allSatisfy({ $0 == 0 }) {
                sawEnd = true
                break
            }
            let size = octal((p + 124)..<(p + 136))
            let type = b[p + 156]
            var name = string(p..<(p + 100))
            let magic = string((p + 257)..<(p + 263))
            if magic.hasPrefix("ustar") {
                let prefix = string((p + 345)..<(p + 500))
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let bodyStart = p + 512
            guard bodyStart + size <= b.count else { throw TarballError.truncated }
            let body = b[bodyStart..<(bodyStart + size)]
            p = bodyStart + ((size + 511) / 512) * 512
            switch type {
            case UInt8(ascii: "x"):
                paxPath = parsePax(body)["path"]
            case UInt8(ascii: "g"):
                break  // GitHub's global header holds only the commit id.
            case 0, UInt8(ascii: "0"):
                var full = paxPath ?? name
                paxPath = nil
                if stripFirstComponent {
                    guard let slash = full.firstIndex(of: "/") else { continue }
                    full = String(full[full.index(after: slash)...])
                }
                if full.isEmpty || full.hasSuffix("/") { continue }
                out.append(TarEntry(path: full, data: Data(body)))
            default:
                paxPath = nil
            }
        }
        // `git archive` always ends with zero blocks: without them the download was cut short.
        guard sawEnd else { throw TarballError.truncated }
        return out
    }
}

/// Builds ustar/pax archives (for the fake server and tests).
public enum TarWriter {
    public static func archive(_ files: [(path: String, data: Data)], rootDir: String) -> Data {
        var out = Data()
        func header(name: String, size: Int, type: UInt8) -> Data {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ at: Int, _ len: Int) {
                let u = Array(s.utf8.prefix(len))
                for (i, c) in u.enumerated() { h[at + i] = c }
            }
            put(name, 0, 100)
            put("0000644", 100, 8); put("0000000", 108, 8); put("0000000", 116, 8)
            put(String(size, radix: 8).leftPad(11), 124, 12)
            put("00000000000", 136, 12)
            h[156] = type
            put("ustar", 257, 6); put("00", 263, 2)
            for i in 148..<156 { h[i] = 0x20 }
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(sum, radix: 8).leftPad(6), 148, 6)
            h[154] = 0; h[155] = 0x20
            return Data(h)
        }
        func pad(_ d: Data) -> Data {
            let r = d.count % 512
            return r == 0 ? d : d + Data(count: 512 - r)
        }
        // pax global header like GitHub's.
        let g = Data("52 comment=0000000000000000000000000000000000000000\n".utf8)
        out += header(name: "pax_global_header", size: g.count, type: UInt8(ascii: "g")) + pad(g)
        for f in files {
            let full = rootDir + "/" + f.path
            if full.utf8.count > 99 || !full.allSatisfy(\.isASCII) {
                let rec = " path=\(full)\n"
                var len = rec.utf8.count + 1
                while String(len).utf8.count + rec.utf8.count != len { len = String(len).utf8.count + rec.utf8.count }
                let pax = Data("\(len)\(rec)".utf8)
                out += header(name: "PaxHeader", size: pax.count, type: UInt8(ascii: "x")) + pad(pax)
            }
            out += header(name: String(full.prefix(99)), size: f.data.count, type: UInt8(ascii: "0")) + pad(f.data)
        }
        out += Data(count: 1024)
        return out
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}
