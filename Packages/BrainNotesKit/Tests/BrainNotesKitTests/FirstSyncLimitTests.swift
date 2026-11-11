import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

// Audit S-M1: first sync's download had no size limit. These check `FirstSyncLimits` from the inflater up to the
// state the app shows, and the tarball's fallback to blobs when the download times out.

/// A raw deflate stream of one fixed-Huffman block: a literal zero, then `repeats` copies of "length 258, distance 1".
/// It inflates to 1 + 258 × `repeats` zero bytes, about 160 times its own size.
func deflateBomb(repeats: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(repeats * 13 / 8 + 8)
    var buffer: UInt32 = 0
    var count: UInt32 = 0
    func put(_ bits: UInt32, _ n: UInt32) {
        buffer |= bits << count
        count += n
        while count >= 8 {
            out.append(UInt8(truncatingIfNeeded: buffer))
            buffer >>= 8
            count -= 8
        }
    }
    // Huffman codes go most significant bit first; everything else least significant first.
    func reversed(_ code: UInt32, _ n: UInt32) -> UInt32 {
        var r: UInt32 = 0
        for i in 0..<n where code & (1 << i) != 0 { r |= 1 << (n - 1 - i) }
        return r
    }
    put(1, 1)  // the last block
    put(1, 2)  // fixed Huffman codes
    put(reversed(0x30, 8), 8)  // literal 0
    let match = reversed(0xC5, 8) | reversed(0, 5) << 8  // length code 285 (258 bytes), distance code 0 (1 back)
    for _ in 0..<repeats { put(match, 13) }
    put(reversed(0, 7), 7)  // end of block
    if count > 0 { out.append(UInt8(truncatingIfNeeded: buffer)) }
    return out
}

/// The bomb in a gzip container. The trailer's CRC and size are never read.
func gzipBomb(repeats: Int) -> Data {
    Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF] + deflateBomb(repeats: repeats) + [UInt8](repeating: 0, count: 8))
}

@Suite struct FirstSyncLimitTests {
    @Test func theStandardLimitsAndWhatTheySay() {
        let s = FirstSyncLimits.standard
        #expect(s.maxDownloadBytes == 128 * 1024 * 1024)
        #expect(s.maxExtractedBytes == 512 * 1024 * 1024)
        #expect(s.maxEntries == 100_000)
        #expect(s.maxEntryBytes == 64 * 1024 * 1024)
        #expect(SyncEngine.Config().limits == s, "first sync uses them unless a test says otherwise")
        #expect(RepoTooLarge(.download, max: s.maxDownloadBytes).message == "This repository is too large for Brain Notes (limit: a 128 MB download).")
        #expect(RepoTooLarge(.extracted, max: s.maxExtractedBytes).message == "This repository is too large for Brain Notes (limit: 512 MB of files).")
        #expect(RepoTooLarge(.entries, max: s.maxEntries).message == "This repository is too large for Brain Notes (limit: 100,000 files and folders).")
        #expect(RepoTooLarge(.entry, max: s.maxEntryBytes).message == "This repository is too large for Brain Notes (limit: 64 MB for one file).")
        #expect(RepoTooLarge(.entry, max: 999).message == "This repository is too large for Brain Notes (limit: 999 bytes for one file).")
    }

    @Test func theBombIsWhatItSays() throws {
        let small = deflateBomb(repeats: 10)
        #expect(try Inflate.raw(small) == [UInt8](repeating: 0, count: 2581))
        #expect(try Gzip.decompress(gzipBomb(repeats: 10)) == Data(count: 2581))
    }

    /// A few MB of gzip that would inflate to over 540 MB. The inflater hands out no more than the limit, then stops.
    @Test func aGzipBombStopsAtTheLimitWithoutBeingHeld() throws {
        let bomb = gzipBomb(repeats: 2_100_000)
        #expect(bomb.count < 4 << 20)
        let limit = 1 << 20
        var seen = 0
        #expect(throws: RepoTooLarge(.extracted, max: limit)) {
            try Gzip.inflate(bomb, limit: limit) { seen += $0.count }
        }
        #expect(seen <= limit, "never more than the limit leaves the inflater")
        #expect(throws: RepoTooLarge(.extracted, max: limit)) { try Gzip.decompress(bomb, limit: limit) }
        #if canImport(Compression)
        // Apple's decoder hands its output over 64 KiB at a time, so it got as far as the limit. Linux's inflater is not
        // a stream: it stops at the limit before handing anything over, and would hold the 512 MB below in one array.
        #expect(seen > limit - (64 << 10), "and it got as far as the limit")
        // First sync's own path with the real limits: 512 MB inflated and read past, never stored, then refused.
        #expect(throws: RepoTooLarge(.extracted, max: FirstSyncLimits.standard.maxExtractedBytes)) {
            try TarReader.files(inGzip: bomb, limits: .standard, keep: { _ in true })
        }
        #endif
    }

    /// The plain Swift inflater (Linux) checks before every write too.
    @Test func thePlainSwiftInflaterStopsABomb() {
        let limit = 1 << 20
        #expect(throws: RepoTooLarge(.extracted, max: limit)) { try Inflate.raw(deflateBomb(repeats: 1_000_000), limit: limit) }
        // Stored blocks count the same way.
        let stored = Inflate.stored([UInt8](repeating: 7, count: 200_000))
        #expect(throws: RepoTooLarge(.extracted, max: 100_000)) { try Inflate.raw(stored, limit: 100_000) }
        #expect((try? Inflate.raw(stored, limit: 200_000))?.count == 200_000)
    }

    @Test func tooManyEntriesAreRefused() throws {
        let files = (0..<6).map { (path: "notes/n\($0).md", data: Data("x".utf8)) }
        let tar = TarWriter.archive(files, rootDir: "r")
        var limits = FirstSyncLimits.unlimited
        limits.maxEntries = 6
        #expect(try TarReader.files(in: tar, limits: limits).count == 6)
        limits.maxEntries = 5
        #expect(throws: RepoTooLarge(.entries, max: 5)) { try TarReader.files(in: tar, limits: limits) }
        // Kept or read past, every entry counts.
        #expect(throws: RepoTooLarge(.entries, max: 5)) { try TarReader.files(in: tar, limits: limits, keep: { _ in false }) }
        // As first sync reads it, through gzip.
        #expect(throws: RepoTooLarge(.entries, max: 5)) {
            try TarReader.files(inGzip: try Gzip.compress(tar), limits: limits, keep: { _ in true })
        }
        // Pax headers (long and non-ASCII names) are not entries of their own.
        let named = TarWriter.archive([("עברית/א.md", Data("a".utf8)), (String(repeating: "long/", count: 30) + "b.md", Data("b".utf8))],
                                      rootDir: "r")
        limits.maxEntries = 2
        #expect(try TarReader.files(in: named, limits: limits).count == 2)
    }

    @Test func anOversizeEntryIsRefusedFromItsHeader() throws {
        let tar = TarWriter.archive([("small.md", Data(count: 10)), ("big.md", Data(count: 1000))], rootDir: "r")
        var limits = FirstSyncLimits.unlimited
        limits.maxEntryBytes = 1000
        #expect(try TarReader.files(in: tar, limits: limits).map(\.data.count) == [10, 1000])
        limits.maxEntryBytes = 999
        #expect(throws: RepoTooLarge(.entry, max: 999)) { try TarReader.files(in: tar, limits: limits) }
        // A file nobody asked for counts too: the limit is on what the archive holds.
        #expect(throws: RepoTooLarge(.entry, max: 999)) { try TarReader.files(in: tar, limits: limits, keep: { $0 == "small.md" }) }
        // A header claiming 8 GB is refused from the header alone: no body follows it here, and none is read.
        var header = [UInt8](TarWriter.archive([("a.md", Data())], rootDir: "r").prefix(1024 + 512))
        for (k, c) in "77777777777".utf8.enumerated() { header[1024 + 124 + k] = c }
        #expect(throws: RepoTooLarge(.entry, max: FirstSyncLimits.standard.maxEntryBytes)) {
            try TarReader.files(in: Data(header), limits: .standard)
        }
    }

    /// The inflater hands over 64 KiB at a time, so a header or body can be cut anywhere. Pieces of any size, single
    /// bytes too, read the same files as one piece.
    @Test func piecesOfAnySizeReadTheSame() throws {
        let files: [(path: String, data: Data)] = [
            ("README.md", Data("# Readme\n".utf8)),
            ("עברית/רעיון.md", Data("טקסט\n".utf8)),
            (String(repeating: "long/", count: 30) + "a.md", Data(repeating: 0x61, count: 2000)),
            ("empty.md", Data()),
            ("exact.md", Data(repeating: 0x62, count: 512)),
            ("one-over.md", Data(repeating: 0x63, count: 513)),
            ("assets/photo.png", Data(repeating: 0x89, count: 3000)),
        ]
        let tar = [UInt8](TarWriter.archive(files, rootDir: "r"))
        let whole = try TarReader.files(in: Data(tar))
        #expect(whole.count == files.count)
        func read(pieces next: () -> Int, keep: @escaping (String) -> Bool = { _ in true }) throws -> [TarEntry] {
            var reader = TarStream(stripFirstComponent: true, limits: .unlimited, keep: keep)
            var i = 0
            while i < tar.count {
                let n = min(tar.count - i, next())
                try tar[i..<(i + n)].withUnsafeBytes { try reader.consume($0) }
                i += n
            }
            return try reader.finish()
        }
        #expect(try read(pieces: { 1 }) == whole)
        var seed: UInt64 = 42
        for _ in 0..<40 {
            let entries = try read(pieces: {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int(seed >> 33) % 700 + 1
            })
            #expect(entries == whole)
        }
        // Kept or not, in pieces: only what was asked for.
        #expect(try read(pieces: { 7 }, keep: { $0.hasSuffix(".md") }) == whole.filter { $0.path.hasSuffix(".md") })
    }

    /// A tarball like the real brain's still reads under the standard limits, and only the files asked for are kept.
    @Test func aNormalTarballReadsUnderTheStandardLimits() throws {
        let files: [(path: String, data: Data)] = [
            ("README.md", Data("# Readme\n".utf8)),
            ("עברית/רעיון.md", Data("טקסט\n".utf8)),
            (String(repeating: "long/", count: 30) + "a.md", Data(repeating: 0x61, count: 2000)),
            ("empty.md", Data()),
            ("assets/photo.png", Data(repeating: 0x89, count: 300_000)),
        ]
        let gz = try Gzip.compress(TarWriter.archive(files, rootDir: "Itamargend-brain-abc1234"))
        let all = try TarReader.files(inGzip: gz, limits: .standard, keep: { _ in true })
        #expect(all.count == files.count)
        for (a, b) in zip(files, all) {
            #expect(sameBytes(a.path, b.path))
            #expect(a.data == b.data)
        }
        let notes = try TarReader.files(inGzip: gz, limits: .standard, keep: { $0.hasSuffix(".md") })
        #expect(notes.count == 4)
        #expect(!notes.contains { $0.path == "assets/photo.png" }, "read past, not kept")
    }
}

@Suite struct DownloadLimitTests {
    /// Answers every request with this body and these headers.
    struct Canned: HTTPTransport {
        var headers: [String: String] = [:]
        var body = Data()
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    private let request = URLRequest(url: URL(string: "https://api.github.com/repos/Itamargend/brain/tarball/x")!)

    /// A transport that hands over whole bodies (the tests' fakes) is held to the same cap, once the body is here.
    @Test func aWholeBodyTransportIsHeldToTheCap() async throws {
        await #expect(throws: RepoTooLarge(.download, max: 1000)) {
            try await Canned(headers: ["Content-Length": "1001"], body: Data(count: 10)).send(request, maxBytes: 1000)
        }
        await #expect(throws: RepoTooLarge(.download, max: 1000)) {
            try await Canned(body: Data(count: 1001)).send(request, maxBytes: 1000)
        }
        let (data, _) = try await Canned(headers: ["Content-Length": "1000"], body: Data(count: 1000)).send(request, maxBytes: 1000)
        #expect(data.count == 1000)
    }

    /// The client asks for the cap on the tarball, with the standard limit: a Content-Length past it is refused.
    @Test func theClientRefusesAnOversizeContentLength() async throws {
        let declared = String(FirstSyncLimits.standard.maxDownloadBytes + 1)
        let t = Canned(headers: ["Content-Length": declared], body: Data(count: 16))
        let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore(TokenPair(access: "a")))
        let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: t, tokens: m)
        #expect(client.limits == .standard)
        await #expect(throws: RepoTooLarge(.download, max: FirstSyncLimits.standard.maxDownloadBytes)) {
            try await client.tarball(String(repeating: "a", count: 40))
        }
    }

    #if canImport(Darwin)
    /// Serves a URLSession without any network. `https://stub.invalid/<content-length>/<pieces>/<piece size>[/open]`:
    /// that Content-Length (none for 0), then the body in that many pieces of that size, then the end. With `open` the
    /// end never comes, as with a download still under way.
    final class Stub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let client else { return }
            let n = url.pathComponents.dropFirst().compactMap { Int($0) }
            guard n.count == 3 else { return client.urlProtocol(self, didFailWithError: URLError(.badURL)) }
            // A type, as GitHub's tarballs have: without one URLSession holds the response back to sniff the body.
            var headers = ["Content-Type": "application/x-gzip"]
            if n[0] > 0 { headers["Content-Length"] = String(n[0]) }
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                               cacheStoragePolicy: .notAllowed)
            for _ in 0..<n[1] { client.urlProtocol(self, didLoad: Data(repeating: 0x61, count: n[2])) }
            if url.lastPathComponent != "open" { client.urlProtocolDidFinishLoading(self) }
        }
        override func stopLoading() {}
    }

    /// The app's real transport reads the body as it arrives: refused from the Content-Length before any body, or once
    /// the bytes pass the cap when there is no length (GitHub's tarballs often come chunked). The refused downloads here
    /// never end, so only a reader that stops by itself gets the cap's error; one that waited for the whole body would
    /// time out instead, as the buffering read below does.
    @Test func urlSessionStopsReadingAtTheCap() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func get(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://stub.invalid/" + path)!) }
        await #expect(throws: RepoTooLarge(.download, max: 100_000)) { try await session.send(get("200000/0/0/open"), maxBytes: 100_000) }
        await #expect(throws: RepoTooLarge(.download, max: 100_000)) { try await session.send(get("0/4/40000/open"), maxBytes: 100_000) }
        await #expect(throws: URLError.self, "a buffering read waits for an end that never comes") {
            try await session.data(for: get("0/4/40000/open"))
        }
        let (some, http) = try await session.send(get("0/2/40000"), maxBytes: 100_000)
        #expect(some.count == 80_000)
        #expect(http.statusCode == 200)
        let (exact, _) = try await session.send(get("100000/4/25000"), maxBytes: 100_000)
        #expect(exact.count == 100_000)
    }
    #endif
}

@Suite struct FirstSyncSizeStopTests {
    private func config(_ change: (inout FirstSyncLimits) -> Void) -> SyncEngine.Config {
        var c = Harness.fastConfig()
        change(&c.limits)
        return c
    }

    /// Past a limit, first sync stops and says why. It doesn't fall back to blobs, doesn't back off and retry, and
    /// downloads nothing again until Sync now.
    @Test func aRepoPastALimitStopsFirstSyncAndStaysStopped() async throws {
        // The seed is 11 files.
        let h = try Harness(config: config { $0.maxEntries = 10 })
        let stop = SyncState.repoTooLarge(RepoTooLarge(.entries, max: 10))
        #expect(await h.sync() == stop)
        #expect(h.store.journal.baseCommit == nil)
        #expect(h.allLocal().isEmpty)
        #expect(await h.fake.count(.tarball) == 1)
        #expect(await h.fake.count(.blob) == 0, "not a fallback to the blobs API")
        #expect(await h.engine.currentBackoffStep == 0, "not a retry with backoff")
        let refs = await h.fake.count(.getRef)
        for trigger: SyncTrigger in [.poll, .foreground, .leftNote, .background] {
            #expect(await h.sync(trigger) == stop, "\(trigger)")
        }
        #expect(await h.fake.count(.tarball) == 1, "no download again by itself")
        #expect(await h.fake.count(.getRef) == refs, "nothing goes to GitHub at all")
        // A note written meanwhile waits for the normal poll: no one-second wake-up loop.
        _ = try h.store.createNote(folder: nil, text: "Written while stopped\n")
        await h.engine.noteSaved()
        h.clock.advance(120)
        #expect(await h.engine.delayUntilNextWake == Harness.fastConfig().pollInterval)
        // Sync now does try again, and gets the same answer.
        #expect(await h.sync(.manual) == stop)
        #expect(await h.fake.count(.tarball) == 2)
    }

    /// Trimmed on GitHub, the repo fits: Sync now finishes first sync, and the stop is gone.
    @Test func syncNowAfterTheRepoShrinksFinishesFirstSync() async throws {
        let h = try Harness(files: Harness.seed + [("big/extra.md", "one more\n")], config: config { $0.maxEntries = 11 })
        #expect(await h.sync() == .repoTooLarge(RepoTooLarge(.entries, max: 11)))
        await h.fake.commitRemote([("big/extra.md", nil)])
        #expect(await h.sync(.manual) == .idle)
        #expect(h.local("todo.md") == "# Todo\n- one\n- two\n")
        #expect(await h.sync(.poll) == .idle)
    }

    @Test(arguments: [RepoTooLarge.Limit.download, .extracted, .entries, .entry])
    func eachLimitStopsFirstSync(_ limit: RepoTooLarge.Limit) async throws {
        let max: Int
        var limits = FirstSyncLimits.standard
        switch limit {
        case .download: max = 100; limits.maxDownloadBytes = max  // the fake's gzip is several times that
        case .extracted: max = 4096; limits.maxExtractedBytes = max  // its tar stream is about 14 KB
        case .entries: max = 10; limits.maxEntries = max  // 11 files
        case .entry: max = 40; limits.maxEntryBytes = max  // notes/alpha.md is longer
        }
        var c = Harness.fastConfig()
        c.limits = limits
        let h = try Harness(config: c)
        #expect(await h.sync() == .repoTooLarge(RepoTooLarge(limit, max: max)))
        #expect(await h.fake.count(.blob) == 0)
        #expect(h.store.journal.baseCommit == nil)
    }

    /// The whole way: the HTTP client stops the download at its own cap, and the engine shows the stop.
    @Test func theHTTPClientsCapReachesTheState() async throws {
        let fake = FakeGitHub(files: Harness.seed)
        let http = FakeGitHubHTTP(fake: fake)
        let manager = TokenManager(clientId: "test-client", transport: http,
                                   store: InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start")))
        var limits = FirstSyncLimits.standard
        limits.maxDownloadBytes = 100
        let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: http, tokens: manager, limits: limits)
        // The engine's own limits are the standard ones: this stop is the client's.
        let h = try Harness(fake: fake, client: client)
        #expect(await h.sync() == .repoTooLarge(RepoTooLarge(.download, max: 100)))
        #expect(await h.fake.count(.blob) == 0)
    }
}

@Suite struct TarballTimeoutFallbackTests {
    /// A tarball too slow for the request's time budget used to be retried whole, forever. Now the blobs bring the notes.
    @Test func aTarballThatTimesOutFallsBackToBlobs() async throws {
        let h = try Harness()
        await h.fake.inject(.tarball, .error(.timedOut))
        #expect(await h.sync() == .idle)
        #expect(h.local("notes/beta.md") == "# Beta\nbody\n")
        #expect(await h.fake.count(.tarball) == 1)
        #expect(await h.fake.count(.blob) > 0)
    }

    /// Through the real client: a timeout, or a connection dropped mid-download, on the tarball alone.
    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .cannotParseResponse])
    func aTransientURLErrorOnTheTarballFallsBackToBlobs(_ code: URLError.Code) async throws {
        struct DropsTarball: HTTPTransport {
            let inner: FakeGitHubHTTP
            let code: URLError.Code
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.path.contains("/tarball/") == true { throw URLError(code) }
                return try await inner.send(request)
            }
        }
        let fake = FakeGitHub(files: Harness.seed)
        let http = DropsTarball(inner: FakeGitHubHTTP(fake: fake), code: code)
        let manager = TokenManager(clientId: "test-client", transport: http,
                                   store: InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start")))
        let client = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: http, tokens: manager)
        let h = try Harness(fake: fake, client: client)
        #expect(await h.sync() == .idle)
        #expect(h.local("עברית/רעיון.md") == "# רעיון\nטקסט בעברית\n")
        #expect(await h.fake.count(.blob) > 0)
    }
}
