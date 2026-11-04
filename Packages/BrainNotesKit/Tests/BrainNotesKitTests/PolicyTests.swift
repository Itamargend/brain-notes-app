import BrainMerge
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

@Suite struct RepoGuardTests {
    @Test func onlyTheTestRepoIsAllowed() throws {
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) { try RepoTarget(owner: "Itamargend", name: "brain") }
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) { try RepoTarget(owner: "itamargend", name: "brain-notes-test") }
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) { try RepoTarget(owner: "Itamargend", name: "Brain-Notes-Test") }
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) { try RepoTarget(owner: "someone", name: "brain-notes-test") }
        let ok = try RepoTarget(owner: "Itamargend", name: "brain-notes-test")
        #expect(ok.slug == "Itamargend/brain-notes-test")
    }

    @Test func theClientCannotBeBuiltForAnotherRepo() {
        let t = InMemoryTokenStore()
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: t)
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
            try GitHubHTTPClient(owner: "Itamargend", name: "brain", transport: URLSession.shared, tokens: m)
        }
    }

    /// A build configured for the real brain must not even open.
    @Test func theLiveSessionRefusesAnyOtherRepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (owner, name) in [("Itamargend", "brain"), ("", ""), ("Itamargend", ""), ("someone", "else")] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
                try BrainSession.live(config: AppConfig(clientId: "x", owner: owner, name: name), baseFolder: dir, deviceLabel: "test")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "and it leaves nothing behind")
    }

    @Test func theLiveSessionOpensForTheAllowedRepoAndKeysItsData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try BrainSession.live(config: AppConfig(clientId: "x", owner: "Itamargend", name: "brain-notes-test"), baseFolder: dir, deviceLabel: "test")
        #expect(s.repo.slug == "Itamargend/brain-notes-test")
        #expect(!s.isDemo)
        #expect(s.deviceFlow() != nil)
        let files = dir.appendingPathComponent("Brain/Itamargend_brain-notes-test/files").path
        #expect(FileManager.default.fileExists(atPath: files))
        #expect(s.store.device.hasPrefix("test-"))
    }

    @Test func theFilesFolderIsOutOfBackupsAndTheJournalIsIn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(root: dir, deviceLabel: "test")
        func excluded(_ u: URL) throws -> Bool { try u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true }
        #expect(try excluded(store.files.filesRoot))
        #expect(try excluded(dir.appendingPathComponent("index", isDirectory: true)))
        #expect(try !excluded(dir.appendingPathComponent("journal.sqlite")))
    }

    @Test func everyRequestPassesTheGuard() throws {
        let t = InMemoryTokenStore()
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: t)
        let c = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: URLSession.shared, tokens: m)
        // Allowed.
        _ = try c.request("GET", "repos/Itamargend/brain-notes-test/git/ref/heads/main")
        _ = try c.request("POST", "graphql")
        // Refused, even though only the client's own code could ask for them.
        for path in [
            "repos/Itamargend/brain/git/ref/heads/main",
            "repos/Itamargend/brain",
            "repos/Itamargend/brain-notes-test/../brain/git/ref/heads/main",
            "repos/Itamargend/brain-notes-test/%2E%2E/brain/git/ref/heads/main",
            "repos/Itamargend/brain-notes-tes/git/ref/heads/main",
            "repos/ITAMARGEND/brain-notes-test/git/ref/heads/main",
            "user",
            "user/repos",
            "repositories/1/git/ref/heads/main",
        ] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(path)") { try c.request("GET", path) }
        }
    }

    @Test func otherHostsAreRefused() throws {
        let r = RepoTarget.allowed
        for s in [
            "https://evil.example/repos/Itamargend/brain-notes-test/x",
            "http://api.github.com/repos/Itamargend/brain-notes-test/x",
            "https://github.com/repos/Itamargend/brain-notes-test/x",
            "https://user@api.github.com/repos/Itamargend/brain-notes-test/x",
        ] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(s)") { try r.guardURL(URL(string: s)!) }
        }
    }
}

@Suite struct SourceRulesTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func sources() throws -> [(String, String)] {
        var out: [(String, String)] = []
        for folder in ["Packages/BrainNotesKit/Sources", "App"] {
            let root = Self.repoRoot.appendingPathComponent(folder)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where ["swift", "yml", "plist", "entitlements"].contains(u.pathExtension) {
                if let s = try? String(contentsOf: u, encoding: .utf8) { out.append((u.path, s)) }
            }
        }
        return out
    }

    @Test func foundTheSources() throws {
        #expect(try sources().contains { $0.0.hasSuffix("SyncEngine.swift") })
    }

    /// The patterns are assembled here so that this test does not match itself (and it is not scanned anyway).
    @Test func noForceTrueAnywhere() throws {
        let t = "tr" + "ue"
        let needles = ["force: " + t, "force:" + t, "\"force\": " + t, "\"force\":" + t, "\"force\" : " + t]
        for (path, text) in try sources() {
            for n in needles { #expect(!text.contains(n), "\(n) in \(path)") }
        }
    }

    @Test func theRefUpdateSendsForceFalseExplicitly() throws {
        let client = try sources().first { $0.0.hasSuffix("GitHubHTTPClient.swift") }
        #expect(client?.1.contains("\"force\": false") == true)
    }

    @Test func noPrintAndNoYellow() throws {
        for (path, text) in try sources() where path.hasSuffix(".swift") {
            #expect(!text.contains("print("), "print in \(path)")
            #expect(!text.contains("NSLog("), "NSLog in \(path)")
            #expect(!text.contains(".yellow"), ".yellow in \(path)")
        }
    }

    /// Tokens live only in the Keychain. The app model is the one user of defaults, for the two flags below;
    /// the app tests need a throwaway suite, to keep off the real settings.
    @Test func noClientSecretAndNoTokenInUserDefaults() throws {
        let mayUseDefaults = ["App/Sources/AppModel.swift", "App/AppTests/OnboardingTests.swift"]
        for (path, text) in try sources() {
            #expect(!text.contains("client_secret\":"), "client secret in \(path)")
            if !mayUseDefaults.contains(where: { path.hasSuffix($0) }) {
                #expect(!text.contains("UserDefaults"), "UserDefaults in \(path)")
            }
        }
    }

    /// All that defaults ever hold: two yes/no flags, under keys fixed in one place.
    @Test func defaultsHoldOnlyTheOnboardingFlags() throws {
        let all = try sources()
        let model = try #require(all.first { $0.0.hasSuffix("App/Sources/AppModel.swift") }?.1)
        #expect(model.contains("static let onboardedKey = \"bn.onboarded\""))
        #expect(model.contains("static let sampleModeKey = \"bn.sampleMode\""))
        let writes = model.split(separator: "\n").filter { $0.contains("defaults.set(") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Set(writes) == ["defaults.set(true, forKey: Self.onboardedKey)", "defaults.set(true, forKey: Self.sampleModeKey)"])
        for (path, text) in all where path.contains("/App/Sources/") {
            for line in text.split(separator: "\n") where line.contains("@AppStorage(") {
                #expect(line.contains("@AppStorage(AppModel.onboardedKey) private var onboarded = false"), "\(line) in \(path)")
            }
        }
    }
}

@Suite struct PathPolicyTests {
    @Test func syncableAndVisible() {
        #expect(PathPolicy.isSyncable("notes/a.md"))
        #expect(PathPolicy.isSyncable("_trash/a.md"))
        #expect(!PathPolicy.isSyncable(".obsidian/a.md"))
        #expect(!PathPolicy.isSyncable("private/a.md"))
        #expect(!PathPolicy.isSyncable("Private/a.md"))
        #expect(!PathPolicy.isSyncable("_capture/a.md"))
        #expect(!PathPolicy.isSyncable("notes/a.png"))
        #expect(!PathPolicy.isSyncable("notes/a\u{200B}b.md"))

        #expect(PathPolicy.isVisible("notes/a.md"))
        #expect(PathPolicy.isVisible("root.md"))
        #expect(PathPolicy.isVisible("_inbox/a.md"))
        #expect(PathPolicy.isVisible("_root-file.md"))
        #expect(!PathPolicy.isVisible("_trash/a.md"))
        #expect(!PathPolicy.isVisible("_templates/a.md"))
        #expect(!PathPolicy.isVisible("notes/_inbox/a.md"))
        #expect(!PathPolicy.isVisible(".obsidian/a.md"))
    }

    @Test func checkCoversPathSizeSecretAndClash() {
        #expect(PathPolicy.check(path: "a.txt", content: "x") == .path(.notMd))
        #expect(PathPolicy.check(path: "private/a.md", content: "x") == .path(.blockedFolder))
        #expect(PathPolicy.check(path: "a.md", content: String(repeating: "x", count: maxNoteBytes + 1)) == .path(.tooLarge))
        #expect(PathPolicy.check(path: "a.md", content: "key " + Fixture.githubToken) == .secret("github-token"))
        let index = PathIndex(["People/x.md"])
        #expect(PathPolicy.check(path: "people/y.md", content: "fine", index: index) == .clash("People/"))
        #expect(PathPolicy.check(path: "People/y.md", content: "fine", index: index) == nil)
    }

    @Test func fileNameFromFirstLine() {
        #expect(PathPolicy.fileName(fromFirstLine: "# Groceries") == "Groceries")
        #expect(PathPolicy.fileName(fromFirstLine: "  ## a/b: c?  ") == "a-b- c-")
        #expect(PathPolicy.fileName(fromFirstLine: "") == "Untitled")
        #expect(PathPolicy.fileName(fromFirstLine: "...") == "Untitled")
        #expect(PathPolicy.fileName(fromFirstLine: ".hidden") == "hidden")
        #expect(PathPolicy.fileName(fromFirstLine: "zero\u{200B}width") == "zerowidth")
        #expect(PathPolicy.fileName(fromFirstLine: String(repeating: "x", count: 200)).count == 60)
        #expect(checkPath(PathPolicy.fileName(fromFirstLine: "רעיון לסופש") + ".md") == nil)
        // NFD input gives an NFC name.
        let nfdName = PathPolicy.fileName(fromFirstLine: "Cafe\u{301}")
        #expect(sameBytes(nfdName, "Caf\u{E9}"))
    }
}

@Suite struct SecretScanTests {
    @Test func patterns() {
        #expect(SecretScan.scan("token " + Fixture.githubToken) == "github-token")
        #expect(SecretScan.scan("id " + Fixture.awsKey) == "aws-key")
        #expect(SecretScan.scan(Fixture.privateKeyHeader + "\nabc") == "private-key")
        #expect(SecretScan.scan(Fixture.apiKeyLine) == "api-key")
        #expect(SecretScan.scan("plain text about api keys and tokens") == nil)
        #expect(SecretScan.scan("api_key = short") == nil)
    }

    @Test func onlyNewSecretsBlock() {
        let base = "line\n" + Fixture.apiKeyLine + "\n"
        #expect(SecretScan.scanAdded(base + "more\n", comparedTo: base) == nil)
        #expect(SecretScan.scanAdded(base + Fixture.awsKey + "\n", comparedTo: base) == "aws-key")
        #expect(SecretScan.scanAdded(base, comparedTo: nil) == "api-key")
    }
}

@Suite struct GitBlobTests {
    @Test func knownHashes() {
        #expect(GitBlob.sha("hello") == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
        #expect(GitBlob.sha("hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitBlob.sha("") == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }
}

@Suite struct FileStoreTests {
    private func store() throws -> FileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bn-fs-\(UUID().uuidString)")
        let s = FileStore(root: root)
        try s.prepare()
        return s
    }

    @Test func refusesEscapingPaths() throws {
        let s = try store()
        defer { s.wipe() }
        for bad in ["../x.md", "a/../../x.md", "", "a//b.md", "./a.md", "/etc/x.md"] {
            #expect(throws: FileStoreError.invalidPath, "\(bad)") { try s.write(bad, "x") }
        }
    }

    @Test func missingFileIsNilNotAnError() throws {
        let s = try store()
        defer { s.wipe() }
        #expect(try s.readText("nope.md") == nil)
        try s.write("a/b.md", "x")
        #expect(try s.readText("a/b.md") == "x")
        try s.remove("a/b.md")
        #expect(!FileManager.default.fileExists(atPath: s.filesRoot.appendingPathComponent("a").path))
        #expect(FileManager.default.fileExists(atPath: s.filesRoot.path))
    }

    @Test func bytesRoundTripExactly() throws {
        let s = try store()
        defer { s.wipe() }
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\nno final newline".utf8)
        try s.write("bom.md", bom)
        let text = try #require(try s.readText("bom.md"))
        #expect(Data(text.utf8) == bom)
        #expect(GitBlob.sha(text) == GitBlob.sha(bom))

        try s.write("bad.md", Data([0xFF, 0xFE, 0x41]))
        #expect(throws: FileStoreError.notText) { try s.readText("bad.md") }
    }

    @Test func hebrewAndNormalizationLookups() throws {
        let s = try store()
        defer { s.wipe() }
        let nfdPath = "עברית/Cafe\u{301}.md"
        let nfcPath = "עברית/Caf\u{E9}.md"
        try s.write(nfdPath, "x")
        #expect(try s.readText(nfdPath) == "x")
        // APFS is normalization-insensitive: the other spelling reaches the same file. That is why the
        // engine stores only one of two twins on a device.
        #expect(try s.readText(nfcPath) == "x")
    }

    @Test func stagingSwap() throws {
        let s = try store()
        defer { s.wipe() }
        try s.write("old.md", "old")
        try s.resetStaging()
        try s.staging.write("new/a.md", "new")
        #expect(try s.readText("new/a.md") == nil)
        try s.swapIn()
        #expect(try s.readText("new/a.md") == "new")
        #expect(try s.readText("old.md") == nil)
        #expect(!FileManager.default.fileExists(atPath: s.stagingURL().path))
    }
}

@Suite struct TarballTests {
    private let files: [(path: String, data: Data)] = [
        ("README.md", Data("# Readme\n".utf8)),
        ("עברית/רעיון.md", Data("טקסט\n".utf8)),
        ("nfd/Cafe\u{301}.md", Data("x".utf8)),
        (String(repeating: "long/", count: 30) + "a.md", Data(repeating: 0x61, count: 2000)),
        ("empty.md", Data()),
    ]

    @Test func writerReaderRoundTrip() throws {
        let tar = TarWriter.archive(files, rootDir: "owner-repo-abc1234")
        let out = try TarReader.files(in: tar)
        #expect(out.count == files.count)
        for (a, b) in zip(files, out) {
            #expect(sameBytes(a.path, b.path))
            #expect(a.data == b.data)
        }
    }

    @Test func gzipRoundTrip() throws {
        let data = Data(String(repeating: "hello hebrew שלום\n", count: 1000).utf8)
        let gz = try Gzip.compress(data)
        #if canImport(Compression)
        // Elsewhere the fake writes stored blocks, which are not smaller.
        #expect(gz.count < data.count)
        #endif
        #expect(try Gzip.decompress(gz) == data)
    }

    @Test func rejectsGarbage() {
        #expect(throws: TarballError.notGzip) { try Gzip.decompress(Data("not gzip at all, not even close".utf8)) }
        let tar = TarWriter.archive(files, rootDir: "r")
        #expect(throws: TarballError.truncated) { try TarReader.files(in: tar.prefix(800)) }
    }

    /// Review M2. A pax record whose length ends before its own space used to trap on a reversed range.
    @Test func aMalformedPaxRecordDoesNotTrap() throws {
        let long = String(repeating: "long/", count: 30) + "a.md"
        var tar = [UInt8](TarWriter.archive([(long, Data("x".utf8))], rootDir: "r"))
        // The global header and its body, then the pax header: its body is block 3.
        #expect(tar[1024 + 156] == UInt8(ascii: "x"))
        tar[1536] = UInt8(ascii: "1")
        tar[1537] = UInt8(ascii: " ")
        let out = try TarReader.files(in: Data(tar))
        #expect(out.count == 1)
        #expect(out.first?.data == Data("x".utf8))
        // Without its pax path the entry keeps the cut-off ustar name. The tree's sha check won't match it, so first
        // sync fetches that note from the blobs API, as for any file the tarball did not deliver.
        #expect(out.first.map { !sameBytes($0.path, long) } == true)
    }

    /// The bytes `git archive` really writes for a repo: read the checked-in sample shape by hand.
    @Test func readsPaxPathOverUstarName() throws {
        let tar = TarWriter.archive([("a/עברית.md", Data("x".utf8))], rootDir: "r")
        let out = try TarReader.files(in: tar)
        #expect(out.map(\.path) == ["a/עברית.md"])
    }
}
