import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

// Tests written from the coverage gap report (.plan/cloud/test-coverage.md): remote input that could
// reach the disk, the journal's own rules, secrets, search syntax and the synthetic demo brain.

@Suite struct HostileRemotePathTests {
    /// GitHub is trusted for content, not for paths: a tree entry that climbs out of the notes folder is
    /// never stored, on the first sync or on a pull, and the rest of the sync goes on.
    @Test func pathsThatClimbOutAreNeverWritten() async throws {
        let h = try Harness(files: [
            ("ok.md", "fine\n"),
            ("../escape.md", "x\n"),
            ("a/../../escape2.md", "y\n"),
            ("/abs.md", "z\n"),
            ("a//b.md", "w\n"),
        ])
        #expect(await h.sync() == .idle)
        #expect(h.local("ok.md") == "fine\n")
        let fm = FileManager.default
        for name in ["escape.md", "escape2.md"] {
            #expect(!fm.fileExists(atPath: h.dir.appendingPathComponent(name).path), "\(name)")
        }
        #expect(!h.store.files.exists("abs.md"))
        #expect(!h.store.files.exists("a/b.md"))
        #expect(h.store.journal.allFiles().map(\.path) == ["ok.md"])

        await h.fake.commitRemote([("../later.md", "x\n"), ("b/../../later2.md", "y\n"), ("ok2.md", "z\n")])
        #expect(await h.sync() == .idle)
        #expect(h.local("ok2.md") == "z\n")
        for name in ["later.md", "later2.md"] {
            #expect(!fm.fileExists(atPath: h.dir.appendingPathComponent(name).path), "\(name)")
        }
        #expect(h.store.journal.allFiles().map(\.path) == ["ok.md", "ok2.md"])
        #expect(h.attention().isEmpty, "not a note this app syncs, so nothing to act on")
    }
}

@Suite struct GzipHeaderTests {
    private let data = Data("a note body, gzip header flags\n".utf8)

    /// `git archive` writes a plain header, but RFC 1952 allows a name, a comment, extra data and a header
    /// CRC. A proxy or CDN that recompresses may add them.
    private func with(flags: UInt8, inserting extra: [UInt8]) throws -> Data {
        var b = [UInt8](try Gzip.compress(data))
        b[3] = flags
        b.insert(contentsOf: extra, at: 10)
        return Data(b)
    }

    @Test func optionalHeaderFieldsAreSkipped() throws {
        #expect(try Gzip.decompress(try with(flags: 0x08, inserting: Array("notes.tar\0".utf8))) == data)
        #expect(try Gzip.decompress(try with(flags: 0x18, inserting: Array("n\0a comment\0".utf8))) == data)
        #expect(try Gzip.decompress(try with(flags: 0x04, inserting: [3, 0, 1, 2, 3])) == data)
        #expect(try Gzip.decompress(try with(flags: 0x02, inserting: [0xAA, 0xBB])) == data)
        // All four, in the order the RFC puts them.
        let all: [UInt8] = [2, 0, 9, 9] + Array("n\0c\0".utf8) + [0xAA, 0xBB]
        #expect(try Gzip.decompress(try with(flags: 0x1E, inserting: all)) == data)
    }

    @Test func anExtraFieldLongerThanTheFileIsTruncated() throws {
        #expect(throws: TarballError.truncated) { try Gzip.decompress(try with(flags: 0x04, inserting: [0xFF, 0xFF])) }
    }

    @Test func aBrokenDeflateStreamFailsToInflate() {
        let broken = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF] + [UInt8](repeating: 0xFF, count: 32) + [UInt8](repeating: 0, count: 8))
        #expect(throws: TarballError.inflateFailed) { try Gzip.decompress(broken) }
    }

    @Test func notDeflateIsNotGzip() {
        var b = [UInt8](repeating: 0, count: 40)
        b[0] = 0x1F; b[1] = 0x8B; b[2] = 7
        #expect(throws: TarballError.notGzip) { try Gzip.decompress(Data(b)) }
    }
}

@Suite struct TarEdgeTests {
    // TarWriter lays out: pax global header (512) + its body (512), then for each short ASCII path a header
    // and one body block of up to 512 bytes. A non-ASCII path adds a pax header and its body first.
    private static let first = 1024

    @Test func anArchiveWithoutItsEndBlocksIsTruncated() {
        let tar = TarWriter.archive([("a.md", Data("A".utf8))], rootDir: "r")
        #expect(throws: TarballError.truncated) { try TarReader.files(in: Data(tar.dropLast(1024))) }
    }

    @Test func linksAndFoldersAreNotFiles() throws {
        for type in [UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "5")] {
            var tar = [UInt8](TarWriter.archive([("a.md", Data("A".utf8)), ("b.md", Data("B".utf8))], rootDir: "r"))
            tar[Self.first + 156] = type
            let out = try TarReader.files(in: Data(tar))
            #expect(out.map(\.path) == ["b.md"], "type \(type)")
        }
    }

    /// A pax `path=` belongs to the entry right after it. If that entry is skipped, the name must not
    /// move on to the next file, or a note would be written under another note's name.
    @Test func aPaxPathDoesNotLeakPastASkippedEntry() throws {
        var tar = [UInt8](TarWriter.archive([("עברית.md", Data("A".utf8)), ("b.md", Data("B".utf8))], rootDir: "r"))
        let fileHeader = Self.first + 512 + 512  // after the pax header and its body
        #expect(tar[fileHeader + 156] == UInt8(ascii: "0"))
        tar[fileHeader + 156] = UInt8(ascii: "5")
        let out = try TarReader.files(in: Data(tar))
        #expect(out.count == 1)
        #expect(sameBytes(out.first?.path ?? "", "b.md"))
        #expect(out.first?.data == Data("B".utf8))
    }

    @Test func theUstarPrefixIsPartOfTheName() throws {
        var tar = [UInt8](TarWriter.archive([("a.md", Data("A".utf8))], rootDir: "x"))
        for i in 0..<100 { tar[Self.first + i] = 0 }
        for (i, c) in "a.md".utf8.enumerated() { tar[Self.first + i] = c }
        for (i, c) in "r/deep".utf8.enumerated() { tar[Self.first + 345 + i] = c }
        #expect(try TarReader.files(in: Data(tar)).map(\.path) == ["deep/a.md"])
    }

    @Test func theRootFolderIsKeptWhenAsked() throws {
        let tar = TarWriter.archive([("a.md", Data("A".utf8)), ("n/b.md", Data("B".utf8))], rootDir: "r")
        #expect(try TarReader.files(in: tar, stripFirstComponent: false).map(\.path) == ["r/a.md", "r/n/b.md"])
    }

    /// Only a body cut short is truncated: a size field that runs past the end is caught before reading.
    @Test func aSizePastTheEndIsTruncated() {
        var tar = [UInt8](TarWriter.archive([("a.md", Data("A".utf8))], rootDir: "r"))
        for (i, c) in "77777777777".utf8.enumerated() { tar[Self.first + 124 + i] = c }
        #expect(throws: TarballError.truncated) { try TarReader.files(in: Data(tar)) }
    }
}

@Suite struct SecretPatternGapTests {
    // Assembled at run time so no secret-shaped string sits in the sources.
    private static func gh(_ kind: String, _ body: String) -> String { "gh" + kind + "_" + body }
    private static let body36 = String(repeating: "q7W8", count: 9)

    @Test func everyGitHubTokenPrefixIsCaught() {
        for kind in ["p", "o", "u", "s", "r"] {
            #expect(SecretScan.scan("token: " + Self.gh(kind, Self.body36)) == "github-token", "gh\(kind)_")
        }
        #expect(SecretScan.scan("github_" + "pat_" + String(repeating: "Ab_9", count: 6)) == "github-pat")
        // Inside a URL with credentials, too.
        #expect(SecretScan.scan("https://x:" + Self.gh("p", Self.body36) + "@github.com/o/r") == "github-token")
    }

    @Test func otherKeyShapes() {
        #expect(SecretScan.scan("AS" + "IA" + "IOSFODNN7EXAMPLE") == "aws-key")
        #expect(SecretScan.scan("-----BEGIN " + "PRIVATE KEY-----") == "private-key")
        #expect(SecretScan.scan("-----BEGIN " + "OPENSSH PRIVATE KEY-----") == "private-key")
        #expect(SecretScan.scan("client" + "_secret: \"" + String(repeating: "z", count: 24) + "\"") == "api-key")
        #expect(SecretScan.scan("ACCESS" + "-TOKEN=" + String(repeating: "Z9", count: 12)) == "api-key")
        #expect(SecretScan.scan("secret" + "key: '" + String(repeating: "k", count: 20) + "'") == "api-key")
    }

    /// Notes about keys are not keys: near misses must not block a commit.
    @Test func nearMissesPass() {
        #expect(SecretScan.scan("gh" + "p_" + String(repeating: "a", count: 19)) == nil)
        #expect(SecretScan.scan("AK" + "IA" + "IOSFODNN7EXAMPL") == nil)
        #expect(SecretScan.scan("-----BEGIN " + "PUBLIC KEY-----") == nil)
        #expect(SecretScan.scan("my api key is in the password manager") == nil)
        #expect(SecretScan.scan("api_key = " + String(repeating: "x", count: 19)) == nil)
    }

    @Test func movingAKnownSecretIsNotNewButASecondOneIs() {
        let known = Self.gh("p", Self.body36)
        let base = "top\n" + known + "\nbottom\n"
        #expect(SecretScan.scanAdded("moved: " + known + "\ntop\nbottom\n", comparedTo: base) == nil)
        let other = Self.gh("p", String(repeating: "m3N4", count: 9))
        #expect(SecretScan.scanAdded(base + other + "\n", comparedTo: base) == "github-token")
    }

    /// The policy check sees a secret only after the path and size rules, so a blocked path reports the path.
    @Test func thePathRuleComesFirst() {
        #expect(PathPolicy.check(path: "private/a.md", content: Self.gh("p", Self.body36)) == .path(.blockedFolder))
        #expect(PathPolicy.check(path: "a.md", content: Self.gh("p", Self.body36))?.label == "blocked:secret:github-token")
    }
}

@Suite struct ExactBytesTests {
    /// Swift's `==` calls these two the same string. The journal, the engine and the fake must not.
    @Test func nfcAndNfdAreTwoKeys() {
        let nfcPath = "Caf\u{E9}.md", nfdPath = "Cafe\u{301}.md"
        #expect(nfcPath == nfdPath, "the reason PathKey exists")
        #expect(!sameBytes(nfcPath, nfdPath))
        #expect(Set([PathKey(nfcPath), PathKey(nfdPath)]).count == 2)
        var d: [PathKey: Int] = [:]
        d[PathKey(nfcPath)] = 1
        d[PathKey(nfdPath)] = 2
        #expect(d[PathKey(nfcPath)] == 1 && d[PathKey(nfdPath)] == 2)
        #expect(!sameDoc(nfcPath, nfdPath))
        #expect(sameDoc(nil, nil))
        #expect(!sameDoc("", nil))
    }

    @Test func invalidUTF8IsNotANote() {
        #expect(decodeNote(Data([0xED, 0xA0, 0x80])) == nil, "a surrogate")
        #expect(decodeNote(Data([0xC0, 0x80])) == nil, "an overlong NUL")
        #expect(decodeNote(Data([0xE2, 0x82])) == nil, "cut mid-character")
        #expect(decodeNote(Data()) == "")
    }

    @Test func timesAreWholeSecondsInUTC() {
        #expect(isoTime(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        let d = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(parseISOTime(isoTime(d)) == d)
        #expect(parseISOTime("yesterday") == nil)
        #expect(hexString([0x00, 0xFF, 0x0A]) == "00ff0a")
    }
}

@Suite struct JournalRuleTests {
    @Test func oneOpenItemPerPathReasonAndCopy() throws {
        let j = try Journal(path: nil)
        try j.transaction { db in
            try Journal.addAttention(db, path: "a.md", reason: "conflict-copy", copyPath: "_inbox/c.md", created: "t1")
            try Journal.addAttention(db, path: "a.md", reason: "conflict-copy", copyPath: "_inbox/c.md", created: "t2")
            try Journal.addAttention(db, path: "a.md", reason: "conflict-copy", copyPath: "_inbox/c-2.md", created: "t1")
            try Journal.addAttention(db, path: "a.md", reason: "push-failed", created: "t1")
            try Journal.addAttention(db, path: "a.md", reason: "push-failed", created: "t2")
        }
        #expect(j.attention().count == 3)
        #expect(j.attentionCount() == 3)
        // Once resolved, the same problem can come back as a new item.
        let first = try #require(j.attention().first)
        try j.resolveAttention(id: first.id)
        try j.transaction { db in
            try Journal.addAttention(db, path: "a.md", reason: "conflict-copy", copyPath: "_inbox/c.md", created: "t3")
        }
        #expect(j.attention().count == 3)
        #expect(j.attention(includeResolved: true).count == 4)
    }

    /// A push that works closes the push problems of its note, never a conflict the user still has to read.
    @Test func aPushClosesOnlyPushProblems() throws {
        let j = try Journal(path: nil)
        try j.transaction { db in
            for reason in ["blocked:secret:aws-key", "blocked:not-md", "case-clash", "unstorable", "push-failed", "rejected", "conflict-copy"] {
                try Journal.addAttention(db, path: "a.md", reason: reason, created: "t")
            }
            try Journal.addAttention(db, path: "b.md", reason: "push-failed", created: "t")
            try Journal.resolvePushProblems(db, path: "a.md")
        }
        #expect(j.attention().map(\.reason) == ["conflict-copy", "push-failed"])
        #expect(j.attention().map(\.path) == ["a.md", "b.md"])
    }

    @Test func needsAttentionOutranksSyncing() throws {
        let j = try Journal(path: nil)
        try j.transaction { db in
            try Journal.upsertOp(db, path: "a.md", kind: .edit, content: "a", newId: "id-a", time: "2026-01-01T00:00:00Z")
            try Journal.upsertOp(db, path: "b.md", kind: .edit, content: "b", newId: "id-b", time: "2026-01-01T00:00:00Z")
            try db.execute(sql: "UPDATE outbox SET in_flight = 1")
            try Journal.addAttention(db, path: "b.md", reason: "push-failed", created: "t")
        }
        #expect(j.status(of: "a.md") == .syncing)
        #expect(j.status(of: "b.md") == .needsAttention)
        #expect(j.status(of: "c.md") == .synced)
    }

    /// A new save of a parked op is a new attempt: it unparks, counts a revision, keeps its id and time.
    @Test func aSaveUnparksAndKeepsTheOpIdentity() throws {
        let j = try Journal(path: nil)
        try j.transaction { db in
            try Journal.upsertOp(db, path: "a.md", kind: .edit, content: "one", newId: "id-1", time: "2026-01-01T00:00:00Z")
            try db.execute(sql: "UPDATE outbox SET parked = 1")
        }
        #expect(j.pushableCount() == 0)
        try j.transaction { db in
            try Journal.upsertOp(db, path: "a.md", kind: .edit, content: "two", newId: "id-2", time: "2026-02-02T00:00:00Z")
        }
        let op = try #require(j.outbox().first)
        #expect(!op.parked)
        #expect(op.rev == 2)
        #expect(op.opId == "id-1")
        #expect(op.opTime == "2026-01-01T00:00:00Z")
        #expect(op.content == "two")
        #expect(op.contentHash == contentHash("two"))
        #expect(j.pushableCount() == 1)
    }

    @Test func theOldestOpSetsTheBadgeTime() throws {
        let j = try Journal(path: nil)
        #expect(j.oldestOpTime() == nil)
        try j.transaction { db in
            try Journal.upsertOp(db, path: "b.md", kind: .edit, content: "b", newId: "1", time: "2026-03-01T10:00:00Z")
            try Journal.upsertOp(db, path: "a.md", kind: .edit, content: "a", newId: "2", time: "2026-01-01T10:00:00Z")
        }
        #expect(j.oldestOpTime() == parseISOTime("2026-01-01T10:00:00Z"))
    }

    /// SQLite compares text by bytes: two spellings of one name are two rows and two ops, never one.
    @Test func nfcAndNfdAreSeparateRowsAndOps() throws {
        let j = try Journal(path: nil)
        let nfcPath = "Caf\u{E9}.md", nfdPath = "Cafe\u{301}.md"
        try j.transaction { db in
            try Journal.putFile(db, FileRow(path: nfcPath, blobSha: "1"))
            try Journal.putFile(db, FileRow(path: nfdPath, blobSha: "2"))
            try Journal.upsertOp(db, path: nfcPath, kind: .edit, content: "c", newId: "c", time: "2026-01-01T00:00:00Z")
            try Journal.upsertOp(db, path: nfdPath, kind: .edit, content: "d", newId: "d", time: "2026-01-01T00:00:00Z")
        }
        #expect(j.allFiles().count == 2)
        #expect(j.file(nfcPath)?.blobSha == "1")
        #expect(j.file(nfdPath)?.blobSha == "2")
        #expect(j.outboxCount() == 2)
        #expect(j.outbox().first { sameBytes($0.path, nfdPath) }?.content == "d")
    }
}

@Suite struct ConflictCopyNamingTests {
    private func store(at clock: TestClock) throws -> NoteStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-copy-\(UUID().uuidString)", isDirectory: true)
        return try NoteStore(root: dir, deviceLabel: "test", now: { clock.now })
    }

    /// Two copies of one note in the same second must be two files: the second must never overwrite the first.
    @Test func twoCopiesInOneSecondAreTwoFiles() throws {
        let clock = TestClock()
        let s = try store(at: clock)
        defer { try? s.wipe() }
        let a = try s.createCopy(of: "notes/alpha.md", text: "mine, first\n")
        let b = try s.createCopy(of: "notes/alpha.md", text: "mine, second\n")
        #expect(!sameBytes(a, b))
        #expect(a.hasPrefix("_inbox/conflict-notes-alpha-"))
        #expect(b.hasPrefix("_inbox/conflict-notes-alpha-"))
        #expect(try s.files.readText(a)?.hasSuffix("mine, first\n") == true)
        #expect(try s.files.readText(b)?.hasSuffix("mine, second\n") == true)
        #expect(ConflictCopy(text: try s.files.readText(a) ?? "")?.mine == "mine, first\n")
        #expect(s.journal.outbox().count == 2)
    }

    /// A copy's name keeps only the end of a long path, so two long paths can share it. In the same second
    /// they still get two files.
    @Test func copiesOfTwoLongPathsWithOneEndingAreTwoFiles() throws {
        let clock = TestClock()
        let s = try store(at: clock)
        defer { try? s.wipe() }
        let tail = String(repeating: "x", count: 200) + "/n.md"
        let a = try s.createCopy(of: "a" + tail, text: "from a\n")
        let b = try s.createCopy(of: "b" + tail, text: "from b\n")
        #expect(!sameBytes(a, b))
        #expect(FileStore.nameFits(a) && FileStore.nameFits(b))
        #expect(try s.files.readText(a)?.hasSuffix("from a\n") == true)
        #expect(try s.files.readText(b)?.hasSuffix("from b\n") == true)
    }
}

@Suite struct SearchSyntaxTests {
    /// What a person types is words, never FTS5 syntax: operators, quotes, column filters and stars are
    /// literal, and nothing typed can make the query fail (a failed query shows as no results).
    @Test func operatorsAreWords() async throws {
        let i = try SearchIndex(path: nil)
        try i.upsert(path: "a.md", text: "# Logic\nand or not near\n", modified: nil)
        try i.upsert(path: "b.md", text: "# Other\nalpha beta\n", modified: nil)
        for q in ["AND", "or", "NOT", "NEAR", "near(", "and OR not"] {
            #expect(await i.search(q).map(\.path) == ["a.md"], "\(q)")
        }
        #expect(await i.search("NOT alpha").isEmpty, "NOT is a word to find, not a negation")
        #expect(await i.search("alpha OR logic").isEmpty, "OR is a word to find, not a union")
    }

    @Test func quotesAndMarksInsideWordsDoNotBreakTheQuery() async throws {
        let i = try SearchIndex(path: nil)
        try i.upsert(path: "a.md", text: "# Notes\nc++ tips and don't forget\n", modified: nil)
        #expect(await i.search("c++").map(\.path) == ["a.md"])
        #expect(await i.search("don't").map(\.path) == ["a.md"])
        #expect(await i.search("\"tips").map(\.path) == ["a.md"])
        #expect(await i.search("tips\"").map(\.path) == ["a.md"])
        #expect(await i.search("body:tips").isEmpty, "a column filter is two words; 'body' is not in the note")
        #expect(await i.search("*").isEmpty)
        #expect(await i.search("^tips").map(\.path) == ["a.md"])
    }

    @Test func theMatchExpressionQuotesEveryWord() {
        #expect(SearchIndex.matchExpression("NEAR(a b)") == "\"NEAR\"* \"a\"* \"b\"*")
        #expect(SearchIndex.matchExpression("x\"y") == "\"x\"* \"y\"*")
        #expect(SearchIndex.matchExpression("\" * ( ) :") == nil)
    }
}

@Suite struct FileStoreGapTests {
    private func store() throws -> FileStore {
        let s = FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("bn-fs2-\(UUID().uuidString)"))
        try s.prepare()
        return s
    }

    /// GitHub takes names APFS cannot hold. Such a note is skipped, not an error that stops the sync.
    @Test func nameLimits() throws {
        #expect(FileStore.nameFits(String(repeating: "a", count: 252) + ".md"))
        #expect(!FileStore.nameFits(String(repeating: "a", count: 253) + ".md"))
        #expect(FileStore.nameFits(String(repeating: "א", count: 252) + ".md"), "characters, not bytes, per name")
        #expect(!FileStore.nameFits(String(repeating: "abcdefghi/", count: 70) + "x.md"), "700 bytes in all")
        let s = try store()
        defer { try? s.wipe() }
        let long = "n/" + String(repeating: "a", count: 300) + ".md"
        #expect(try s.writeIfPossible(long, Data("x".utf8)) == false)
        #expect(!s.exists(long))
        #expect(try s.writeIfPossible("n/ok.md", Data("x".utf8)))
        #expect(try s.readText("n/ok.md") == "x")
    }

    @Test func emptyFoldersAreListedAndFoldersWithNotesAreNot() throws {
        let s = try store()
        defer { try? s.wipe() }
        try s.createFolder("a/b")
        try s.createFolder("c")
        try s.write("d/x.md", "x")
        #expect(s.emptyFolders().sorted() == ["a/b", "c"])
        try s.move("d/x.md", to: "c/sub/x.md")
        #expect(try s.readText("c/sub/x.md") == "x")
        #expect(s.emptyFolders().sorted() == ["a/b", "d"])
    }

    @Test func folderPathsAreCheckedLikeNotePaths() throws {
        let s = try store()
        defer { try? s.wipe() }
        for bad in ["../x", "a/../../x", "", "/etc"] {
            #expect(throws: FileStoreError.invalidPath, "\(bad)") { try s.createFolder(bad) }
        }
        #expect(throws: FileStoreError.invalidPath) { try s.move("a.md", to: "../a.md") }
    }
}

@Suite struct FolderPolicyTests {
    @Test func typedFolderNames() {
        #expect(PathPolicy.folderName(fromTyped: "   ") == nil)
        #expect(PathPolicy.folderName(fromTyped: "..") == nil)
        #expect(PathPolicy.folderName(fromTyped: "a/b") == "a-b")
        #expect(PathPolicy.folderName(fromTyped: "  Ideas  ") == "Ideas")
        #expect(sameBytes(PathPolicy.folderName(fromTyped: "Cafe\u{301}") ?? "", "Caf\u{E9}"))
    }

    @Test func whichFoldersCanHoldNotes() {
        for ok in ["notes", "_inbox", "_inbox/sub", "עברית", "a/b/c"] {
            #expect(PathPolicy.canHoldNotes(folder: ok), "\(ok)")
        }
        for bad in ["_trash", "_templates", "private", "Private", "notes/private", ".hidden", "ideas.md", "a/IDEAS.MD",
                    "notes/_inbox", String(repeating: "a", count: 300)] {
            #expect(!PathPolicy.canHoldNotes(folder: bad), "\(bad)")
        }
    }
}

@Suite struct DemoBrainFixtureTests {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo-brain", isDirectory: true)

    /// The synthetic brain the demo and the screen tests use: every note loads, syncs, shows, and holds no secret.
    @Test func everyFixtureIsASafeSyncableNote() throws {
        let notes = DemoBrain.load(from: Self.folder)
        let onDisk = (FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "md" }
        #expect(notes.count == onDisk.count)
        #expect(notes.count >= 40)
        var index = PathIndex()
        for n in notes {
            #expect(sameBytes(nfc(n.path), n.path), "\(n.path) is NFC")
            #expect(PathPolicy.isVisible(n.path), "\(n.path)")
            #expect(PathPolicy.check(path: n.path, content: n.text, index: index) == nil, "\(n.path)")
            index.add(n.path)
        }
        #expect(notes.map(\.path) == notes.map(\.path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    /// The demo stages its three states with the real engine: a conflict copy, a note deleted elsewhere
    /// while edited here, and an unsynced note.
    @Test func theDemoShowsItsThreeStates() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-demo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let s = try await BrainSession.demo(fixtures: DemoBrain.load(from: Self.folder), baseFolder: base)
        let items = s.store.journal.attention()
        #expect(items.contains { $0.path == "projects/brain-notes-app.md" && $0.reason == "conflict-copy" })
        #expect(items.contains { $0.detail == "deleted-remotely" && $0.copyPath != nil })
        #expect(s.store.journal.outbox().map(\.path) == ["todo.md"])
        #expect(s.store.status(of: "todo.md") == .savedOnDevice)
        #expect(s.store.index.count() > 0)
    }
}

@Suite struct SignOutWipeTests {
    private struct Offline: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    }

    /// Sign out and wipe means all of it: the tokens, the note files, the journal and the index. A new session
    /// on the same folder starts empty.
    @Test func signOutRemovesTokensNotesJournalAndIndex() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bn-wipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let tokens = InMemoryTokenStore(TokenPair(access: "a", refresh: "r"))
        let config = AppConfig(clientId: "x", owner: RepoTarget.testRepo.owner, name: RepoTarget.testRepo.name)
        let s = try BrainSession.live(config: config, baseFolder: base, deviceLabel: "test", tokens: tokens, transport: Offline())
        try s.store.save(path: "_inbox/a.md", text: "# A\nunsynced\n")
        #expect(s.hasTokens)
        let root = s.store.root

        try await s.signOutAndWipe()
        #expect(!s.hasTokens)
        #expect(try tokens.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let again = try BrainSession.live(config: config, baseFolder: base, deviceLabel: "test", tokens: tokens, transport: Offline())
        #expect(again.store.journal.outboxCount() == 0)
        #expect(again.store.index.count() == 0)
        #expect(try again.store.read("_inbox/a.md") == nil)
    }
}
