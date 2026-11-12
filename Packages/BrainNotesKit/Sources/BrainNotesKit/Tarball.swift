#if canImport(Compression)
import Compression
#endif
import Foundation

public enum TarballError: Error, Equatable, Sendable {
    case notGzip
    case truncated
    case badHeader
    case inflateFailed
}

/// What first sync takes in at most, all in one place. The real brain, measured 2026-11: about 2,600 files, 23.8 MiB of
/// files, an 8.2 MiB tarball, the largest file about 5 MB. Every limit is far above that. A repo past one stops first
/// sync with `RepoTooLarge` before memory runs out, rather than getting the app killed on every try.
public struct FirstSyncLimits: Sendable, Equatable {
    /// The gzip download: refused from its Content-Length when it has one, and again as the bytes arrive.
    public var maxDownloadBytes: Int
    /// Everything inflated from it, counted while inflating: a small gzip that expands without end stops here.
    public var maxExtractedBytes: Int
    /// Files, folders and links in the tarball. Pax headers don't count.
    public var maxEntries: Int
    /// One entry's body, any entry, checked from its header before any of the body is read.
    public var maxEntryBytes: Int

    public init(maxDownloadBytes: Int, maxExtractedBytes: Int, maxEntries: Int, maxEntryBytes: Int) {
        self.maxDownloadBytes = maxDownloadBytes
        self.maxExtractedBytes = maxExtractedBytes
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
    }

    public static let standard = FirstSyncLimits(maxDownloadBytes: 128 << 20, maxExtractedBytes: 512 << 20,
                                                 maxEntries: 100_000, maxEntryBytes: 64 << 20)
    /// For archives the app or its tests made themselves, which are not downloads.
    public static let unlimited = FirstSyncLimits(maxDownloadBytes: .max, maxExtractedBytes: .max, maxEntries: .max, maxEntryBytes: .max)
}

/// The repository is past one of `FirstSyncLimits`. Trying again gets the same answer, so sync stops and says so.
public struct RepoTooLarge: Error, Equatable, Sendable {
    public enum Limit: Sendable, Equatable {
        case download, extracted, entries, entry
    }

    public var limit: Limit
    /// The limit that was passed: bytes, or a count for `.entries`.
    public var max: Int

    public init(_ limit: Limit, max: Int) {
        self.limit = limit
        self.max = max
    }

    /// For the user: what happened, and which limit.
    public var message: String {
        let what: String
        switch limit {
        case .download: what = "a \(Self.size(max)) download"
        case .extracted: what = "\(Self.size(max)) of files"
        case .entries: what = "\(Self.count(max)) files and folders"
        case .entry: what = "\(Self.size(max)) for one file"
        }
        return "This repository is too large for Brain Notes (limit: \(what))."
    }

    private static func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? "\(count(bytes >> 20)) MB" : "\(count(bytes)) bytes"
    }

    /// Digits in groups of three, as the app's English text writes numbers.
    private static func count(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }
}

/// Gzip (RFC 1952): strip the header and trailer, inflate the raw deflate stream. Apple's Compression where it
/// exists, the plain Swift `Inflate` elsewhere (Linux).
public enum Gzip {
    /// The whole inflated stream. Throws `RepoTooLarge(.extracted)` rather than grow past `limit` bytes.
    public static func decompress(_ data: Data, limit: Int = .max) throws -> Data {
        var out = Data()
        try inflate(data, limit: limit) { piece in
            if let base = piece.baseAddress { out.append(base.assumingMemoryBound(to: UInt8.self), count: piece.count) }
        }
        return out
    }

    /// Inflates `data` and hands the output to `sink` a piece at a time, as it is made. Throws `RepoTooLarge(.extracted)`
    /// before the output passes `limit` bytes: a small gzip that would expand without end costs at most `limit` bytes,
    /// and only if `sink` keeps them, plus one buffer.
    static func inflate(_ data: Data, limit: Int, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
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
            let deflated = UnsafeRawBufferPointer(rebasing: b[p..<(b.count - 8)])
            #if canImport(Compression)
            try inflateWithCompression(deflated, limit: limit, into: sink)
            #else
            let out = try Inflate.raw(Array(deflated), limit: limit)
            try out.withUnsafeBytes { try sink($0) }
            #endif
        }
    }

    #if canImport(Compression)
    /// Apple's streaming decoder, one 64 KiB buffer at a time, each piece counted before it is handed on.
    private static func inflateWithCompression(_ input: UnsafeRawBufferPointer, limit: Int,
                                               into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw TarballError.inflateFailed }
        let capacity = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: source, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw TarballError.inflateFailed
        }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = source
        stream.src_size = input.count
        var total = 0
        while true {
            stream.dst_ptr = buffer
            stream.dst_size = capacity
            // All the input is here: finalize, so a stream cut short is an error and not an endless wait for more.
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let made = capacity - stream.dst_size
            if made > 0 {
                guard made <= limit - total else { throw RepoTooLarge(.extracted, max: limit) }
                total += made
                try sink(UnsafeRawBufferPointer(start: buffer, count: made))
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // A full buffer means there is more. An empty one means the input ran out before the stream ended.
                guard made > 0 else { throw TarballError.inflateFailed }
            default:
                throw TarballError.inflateFailed
            }
        }
    }
    #endif

    /// Gzip container for tests and the fake server. Without Compression the stream is stored blocks: valid, not smaller.
    public static func compress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        #else
        let deflated = Data(Inflate.stored([UInt8](data)))
        #endif
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
    /// Every regular file in an uncompressed archive, as the fake server and the tests write them. `keep` picks the
    /// files whose bodies are stored; the others are read past.
    public static func files(in tar: Data, stripFirstComponent: Bool = true, limits: FirstSyncLimits = .unlimited,
                             keep: @escaping (String) -> Bool = { _ in true }) throws -> [TarEntry] {
        var reader = TarStream(stripFirstComponent: stripFirstComponent, limits: limits, keep: keep)
        try tar.withUnsafeBytes { try reader.consume($0) }
        return try reader.finish()
    }

    /// GitHub's tarball as downloaded, gzip and all, read under `limits`. It is inflated a piece at a time straight into
    /// the reader, so neither the whole tar stream nor any file `keep` turns down is ever held in memory. Throws
    /// `RepoTooLarge` at the first limit passed.
    public static func files(inGzip gz: Data, limits: FirstSyncLimits, keep: @escaping (String) -> Bool) throws -> [TarEntry] {
        var reader = TarStream(stripFirstComponent: true, limits: limits, keep: keep)
        try Gzip.inflate(gz, limit: limits.maxExtractedBytes) { try reader.consume($0) }
        return try reader.finish()
    }

    /// As `files(inGzip:limits:keep:)`, but each file `keep` asks for goes to `each` the moment its body is read, and
    /// nothing is collected here: one file's bytes at a time, never all the kept files at once. Throws at the first limit
    /// passed or when the archive turns out cut short, possibly after `each` has had some of the files.
    public static func forEachFile(inGzip gz: Data, limits: FirstSyncLimits, keep: @escaping (String) -> Bool,
                                   _ each: (TarEntry) throws -> Void) throws {
        var reader = TarStream(stripFirstComponent: true, limits: limits, keep: keep)
        try Gzip.inflate(gz, limit: limits.maxExtractedBytes) { try reader.consume($0, each: each) }
        _ = try reader.finish()
    }
}

/// The reader itself, fed bytes in pieces of any size: a header block, then its body and the padding to the next block.
struct TarStream {
    private enum Body {
        /// A regular file `keep` asked for, under its path in the repo.
        case file(String)
        /// A pax extended header: its records describe the next entry.
        case pax
        /// Anything else, and files nobody asked for: read past, not stored.
        case skip
    }

    private let stripFirstComponent: Bool
    private let limits: FirstSyncLimits
    private let keep: (String) -> Bool
    private var out: [TarEntry] = []
    private var header: [UInt8] = []
    private var body = Body.skip
    private var bodyBytes = Data()
    private var bodyLeft = 0
    private var paddingLeft = 0
    private var paxPath: String?
    private var entries = 0
    private var sawEnd = false

    init(stripFirstComponent: Bool, limits: FirstSyncLimits, keep: @escaping (String) -> Bool) {
        self.stripFirstComponent = stripFirstComponent
        self.limits = limits
        self.keep = keep
        header.reserveCapacity(512)
    }

    /// Reads a piece and keeps the files it completes, for `finish`.
    mutating func consume(_ bytes: UnsafeRawBufferPointer) throws {
        var read: [TarEntry] = []
        try consume(bytes) { read.append($0) }
        out.append(contentsOf: read)
    }

    /// Reads a piece and hands each file it completes to `each`, keeping none of them.
    mutating func consume(_ bytes: UnsafeRawBufferPointer, each: (TarEntry) throws -> Void) throws {
        guard let base = bytes.baseAddress else { return }
        var i = 0
        while i < bytes.count, !sawEnd {
            if bodyLeft > 0 {
                let n = min(bodyLeft, bytes.count - i)
                if case .skip = body {} else { bodyBytes.append(base.advanced(by: i).assumingMemoryBound(to: UInt8.self), count: n) }
                bodyLeft -= n
                i += n
                if bodyLeft == 0 { try endBody(each) }
            } else if paddingLeft > 0 {
                let n = min(paddingLeft, bytes.count - i)
                paddingLeft -= n
                i += n
            } else {
                let n = min(512 - header.count, bytes.count - i)
                header.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[i..<(i + n)]))
                i += n
                if header.count == 512 {
                    try startEntry(each)
                    header.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    /// The files read and kept by `consume(_:)`. An archive without its end block was cut short.
    func finish() throws -> [TarEntry] {
        // `git archive` always ends with zero blocks: without them the download was cut short.
        guard sawEnd else { throw TarballError.truncated }
        return out
    }

    private mutating func startEntry(_ each: (TarEntry) throws -> Void) throws {
        if header.allSatisfy({ $0 == 0 }) {
            sawEnd = true
            return
        }
        let size = octal(124..<136)
        let type = header[156]
        var name = string(0..<100)
        if string(257..<263).hasPrefix("ustar") {
            let prefix = string(345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        // From the header, before any of the body is read or kept.
        guard size <= limits.maxEntryBytes else { throw RepoTooLarge(.entry, max: limits.maxEntryBytes) }
        bodyLeft = size
        paddingLeft = (512 - size % 512) % 512
        body = .skip
        switch type {
        case UInt8(ascii: "x"):
            body = .pax
        case UInt8(ascii: "g"):
            break  // GitHub's global header holds only the commit id.
        default:
            entries += 1
            guard entries <= limits.maxEntries else { throw RepoTooLarge(.entries, max: limits.maxEntries) }
            // A pax path belongs to this entry alone, whatever it is and whether or not it is kept.
            let full = paxPath ?? name
            paxPath = nil
            if type == 0 || type == UInt8(ascii: "0"), let path = Self.repoPath(full, strip: stripFirstComponent), keep(path) {
                body = .file(path)
            }
        }
        if size == 0 { try endBody(each) }
    }

    private mutating func endBody(_ each: (TarEntry) throws -> Void) throws {
        switch body {
        case let .file(path): try each(TarEntry(path: path, data: bodyBytes))
        case .pax: paxPath = try Self.paxRecords([UInt8](bodyBytes))["path"]
        case .skip: break
        }
        body = .skip
        bodyBytes = Data()
    }

    /// The path in the repo, without GitHub's top folder. nil for a folder, or for anything outside that top folder.
    private static func repoPath(_ full: String, strip: Bool) -> String? {
        var path = full
        if strip {
            guard let slash = path.firstIndex(of: "/") else { return nil }
            path = String(path[path.index(after: slash)...])
        }
        return path.isEmpty || path.hasSuffix("/") ? nil : path
    }

    private func string(_ range: Range<Int>) -> String {
        var bytes = header[range]
        if let z = bytes.firstIndex(of: 0) { bytes = bytes[..<z] }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func octal(_ range: Range<Int>) -> Int {
        var v = 0
        for c in header[range] {
            if c == 0 || c == 0x20 { if v == 0 && c == 0x20 { continue } else { break } }
            guard c >= 0x30, c <= 0x37 else { break }
            v = v * 8 + Int(c - 0x30)
        }
        return v
    }

    /// Pax records: "<len> key=value\n", each length counting its whole record.
    static func paxRecords(_ data: [UInt8]) throws -> [String: String] {
        var res: [String: String] = [:]
        var i = 0
        while i < data.count {
            var j = i
            while j < data.count, data[j] != 0x20 { j += 1 }
            let digits = data[i..<j]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { break }
            // The length comes from the archive. One that runs past the end of this header, however large, means
            // a forged or broken header: refused, compared without forming `i + len`, which a length near
            // `Int.max` overflows. Too many digits for an Int is past the end too.
            guard let len = Int(String(decoding: digits, as: UTF8.self)), len <= data.count - i else {
                throw TarballError.badHeader
            }
            // A record holds its length, a space, the key and value, and a newline. One that ends at or before its
            // own space is malformed: stop here rather than slice a range whose bounds are reversed.
            guard len > 0, j < i + len - 1 else { break }
            let rec = data[(j + 1)..<(i + len - 1)]
            if let eq = rec.firstIndex(of: 0x3D) {
                res[String(decoding: rec[rec.startIndex..<eq], as: UTF8.self)] = String(decoding: rec[(eq + 1)...], as: UTF8.self)
            }
            i += len
        }
        return res
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
