import BrainMerge
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

@Suite struct RepoGuardTests {
    /// Malformed owners and repository names: whitespace, slashes, traversal, percent-encoding, Unicode look-alikes,
    /// leading/trailing/double hyphens on owners, `.` / `..` / `.git`, empty strings, and oversize names.
    static let refused: [(owner: String, name: String)] = [
        (" alice", "brain"), ("alice ", "brain"), ("alice", " brain"), ("alice", "brain "),
        ("alice", "brain\n"), ("alice", "\tbrain"),
        ("alice", "brain\u{200B}"), ("alice", "br\u{0430}in"), ("alice", "\u{FF42}rain"),
        ("\u{0430}lice", "brain"), ("-lead", "brain"), ("trail-", "brain"), ("a--b", "brain"),
        ("alice_1", "brain"), ("alice.1", "brain"),
        ("alice", "brain.git"), ("alice", "BRAIN.GIT"), ("alice", "."), ("alice", ".."),
        ("alice", "../x"), ("../x", "brain"), ("a/b", "brain"), ("alice", "a/b"),
        ("%2e%2e", "brain"), ("alice", "%2e%2e"),
        ("alice", "brain/../other"), ("alice/brain", ""), ("", "alice/brain"),
        ("alice", ""), ("", "brain"), ("", ""),
        (String(repeating: "a", count: 40), "brain"),
        ("alice", String(repeating: "a", count: 101)),
    ]

    @Test func validatedTargetsCarryNumericIdsAndBranches() throws {
        let first = try RepoTarget(repoId: 101, owner: "alice", name: "brain-notes", defaultBranch: "main")
        let second = try RepoTarget(repoId: 202, owner: "bob-42", name: "notes_2026.private", defaultBranch: "trunk")
        #expect(first.slug == "alice/brain-notes")
        #expect(first.id == "101")
        #expect(second.slug == "bob-42/notes_2026.private")
        #expect(second.id == "202")
        #expect(second.defaultBranch == "trunk")
        #expect(first != second)
    }

    /// Malformed owner, name, repoId, or branch is refused, and public repos are refused with `.publicRepo`.
    @Test func malformedOrPublicTargetsAreRefused() {
        for (owner, name) in Self.refused {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(owner)/\(name)") {
                try RepoTarget(repoId: 1, owner: owner, name: name)
            }
        }
        for badId: Int64 in [0, -1, .min] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
                try RepoTarget(repoId: badId, owner: "alice", name: "brain")
            }
        }
        #expect(throws: RepoTarget.GuardError.publicRepo) {
            try RepoTarget(repoId: 1, owner: "alice", name: "brain", isPrivate: false)
        }
    }

    @Test func theClientCannotBeBuiltForAMalformedOrPublicRepo() {
        let t = InMemoryTokenStore()
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: t)
        for (owner, name) in Self.refused {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(owner)/\(name)") {
                try GitHubHTTPClient(repoId: 1, owner: owner, name: name, transport: URLSession.shared, tokens: m)
            }
        }
        #expect(throws: RepoTarget.GuardError.publicRepo) {
            try GitHubHTTPClient(repoId: 1, owner: "alice", name: "brain", isPrivate: false, transport: URLSession.shared, tokens: m)
        }
    }

    /// `openVerified` refuses any selection that is not returned by `/user/installations/{id}/repositories`, and leaves
    /// nothing on disk.
    @Test func openVerifiedRefusesUnlistedOrMismatchedSelections() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = FakeGitHubHTTP(fake: FakeGitHub(), repoId: 500, installationId: 10, owner: "alice", name: "notes")
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let config = AppConfig(clientId: "x")

        for wrong in [
            try SelectedRepo(installationId: 10, repoId: 999, owner: "alice", name: "notes"),
            try SelectedRepo(installationId: 10, repoId: 500, owner: "bob", name: "notes"),
            try SelectedRepo(installationId: 10, repoId: 500, owner: "alice", name: "other"),
            try SelectedRepo(installationId: 10, repoId: 500, owner: "ALICE", name: "notes"),
        ] {
            await #expect(throws: SelectionVerificationError.notListed, "\(wrong.slug)#\(wrong.repoId)") {
                try await BrainSession.openVerified(config: config, selection: wrong, baseFolder: dir,
                                                    deviceLabel: "test", tokens: tokens, transport: http)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "and it leaves nothing behind")
    }

    @Test func liveSessionsKeyLocalDataByNumericRepoId() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = InMemoryTokenStore(TokenPair(access: "ghu_start", refresh: "ghr_start"))
        let info: [String: Any] = ["BNGitHubClientID": "x", "BNGitHubAppSlug": "brain-notes-app"]
        for (repoId, owner, name) in [(Int64(101), "alice", "brain"), (Int64(202), "bob", "notes")] {
            let http = FakeGitHubHTTP(fake: FakeGitHub(), repoId: repoId, installationId: 7, owner: owner, name: name)
            let sel = try SelectedRepo(installationId: 7, repoId: repoId, owner: owner, name: name)
            let s = try await BrainSession.openVerified(config: AppConfig(info: info), selection: sel,
                                                        baseFolder: dir, deviceLabel: "test", tokens: tokens, transport: http)
            #expect(s.repo.repoId == repoId)
            #expect(s.repo.slug == "\(owner)/\(name)")
            #expect(!s.isDemo)
            #expect(s.deviceFlow() != nil)
            let files = dir.appendingPathComponent("Brain/\(repoId)/files").path
            #expect(FileManager.default.fileExists(atPath: files))
            #expect(s.store.device.hasPrefix("test-"))
        }
    }

    /// A session talks ONLY to the single repo the user picked: every other repo (even another valid private repo) is
    /// refused byte-for-byte by `guardURL` and by `GitHubHTTPClient.request`.
    @Test func theGuardRefusesEveryOtherRepo() throws {
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: InMemoryTokenStore())
        let repoA = try RepoTarget(repoId: 101, owner: "alice", name: "notes")
        let repoB = try RepoTarget(repoId: 202, owner: "bob", name: "brain")
        for (active, other) in [(repoA, repoB), (repoB, repoA)] {
            try active.guardURL(URL(string: "https://api.github.com/repositories/\(active.id)/git/ref/heads/main")!)
            try active.guardURL(URL(string: "https://api.github.com/repositories/\(active.id)")!)
            try active.guardURL(URL(string: "https://api.github.com/graphql")!)
            let c = GitHubHTTPClient(repo: active, transport: URLSession.shared, tokens: m)
            #expect(c.repo == active)
            _ = try c.request("GET", "repositories/\(active.id)/tarball/" + String(repeating: "a", count: 40))
            for path in [
                "repositories/\(other.id)/git/ref/heads/main",
                "repositories/\(other.id)/tarball/" + String(repeating: "a", count: 40),
                "repositories/\(other.id)",
                "repositories/0\(active.id)/git/ref/heads/main",
                "repositories/\(active.id)0/git/ref/heads/main",
                "repositories/\(active.id)/../\(other.id)/git/ref/heads/main",
                "repositories/\(active.id)/%2E%2E/\(other.id)/git/ref/heads/main",
                "repos/\(active.slug)/git/ref/heads/main",
                "repos/\(other.slug)/git/ref/heads/main",
                "repos/\(other.slug)/tarball/" + String(repeating: "a", count: 40),
                "repos/\(other.slug)",
                "repos/\(active.slug)/../\(other.name)/git/ref/heads/main",
                "repos/\(active.slug)/%2E%2E/\(other.name)/git/ref/heads/main",
                "repos/\(active.owner)/\(other.name)/git/ref/heads/main",
            ] {
                #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(active.slug): \(path)") {
                    try active.guardURL(URL(string: "https://api.github.com/" + path)!)
                }
                #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(active.slug): \(path)") { try c.request("GET", path) }
            }
        }
    }

    /// Audit F-4. The journal holds unsynced text, notes the secret scan kept from GitHub included, so the whole repo
    /// folder is out of backups (iCloud and device backups, Time Machine), not only the note files. Everything of the
    /// repo lives under that folder: the journal and SQLite's files next to it, the index, pins, first sync's staging.
    @Test func theWholeRepoFolderIsOutOfBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(root: dir, deviceLabel: "test")
        try store.save(path: "_inbox/a.md", text: "# A\nunsynced\n")
        let pins = FilePinsStore(store: store)
        try pins.pin("_inbox/a.md")
        try store.files.resetStaging()
        let rootPath = dir.standardizedFileURL.path + "/"
        func under(_ u: URL) -> Bool { u.standardizedFileURL.path.hasPrefix(rootPath) }
        let journal = dir.appendingPathComponent("journal.sqlite")
        let index = dir.appendingPathComponent("index/index.sqlite")
        for u in [journal, index, pins.url] {
            #expect(FileManager.default.fileExists(atPath: u.path), "\(u.lastPathComponent)")
        }
        for u in [journal, index, pins.url, store.files.filesRoot, store.files.stagingURL()] {
            #expect(under(u), "\(u.path)")
        }
        #if canImport(Darwin)
        func excluded(_ u: URL) throws -> Bool {
            try URL(fileURLWithPath: u.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        }
        #expect(try excluded(dir), "the repo folder itself, so everything in it")
        #expect(try excluded(store.files.filesRoot))
        #expect(try excluded(dir.appendingPathComponent("index", isDirectory: true)))
        // A folder an earlier version made, which left the journal in backups, gets the flag when a store opens it. Made
        // by hand, and not read before the store opens it: turning the flag off and on again on one folder, with a
        // read in between, gave a stale read now and then while other tests ran.
        let earlier = FileManager.default.temporaryDirectory.appendingPathComponent("bn-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: earlier) }
        try FileManager.default.createDirectory(at: earlier.appendingPathComponent("files/notes", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("# Old\n".utf8).write(to: earlier.appendingPathComponent("files/notes/old.md"))
        _ = try NoteStore(root: earlier, deviceLabel: "test")
        #expect(try excluded(earlier))
        #else
        // Backups are an Apple notion; swift-corelibs-foundation does not keep the flag.
        _ = store
        #endif
    }

    @Test func everyRequestPassesTheGuard() throws {
        let t = InMemoryTokenStore()
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: t)
        let c = try GitHubHTTPClient(owner: "Itamargend", name: "brain-notes-test", transport: URLSession.shared, tokens: m)
        // Allowed.
        _ = try c.request("GET", "repositories/1/git/ref/heads/main")
        _ = try c.request("GET", "repositories/1")
        _ = try c.request("POST", "graphql")
        // Refused, even though only the client's own code could ask for them.
        for path in [
            "repositories/2/git/ref/heads/main",
            "repositories/01/git/ref/heads/main",
            "repositories/10/git/ref/heads/main",
            "repositories/1/../2/git/ref/heads/main",
            "repositories/1/%2E%2E/2/git/ref/heads/main",
            "repos/Itamargend/brain-notes-test/git/ref/heads/main",
            "repos/Itamargend/brain/git/ref/heads/main",
            "repos/Itamargend/brain",
            "repos/Itamargend/brain-notes-test/../brain/git/ref/heads/main",
            "repos/Itamargend/brain-notes-test/%2E%2E/brain/git/ref/heads/main",
            "repos/Itamargend/brain-notes-tes/git/ref/heads/main",
            "repos/ITAMARGEND/brain-notes-test/git/ref/heads/main",
            "user",
            "user/repos",
        ] {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(path)") { try c.request("GET", path) }
        }
    }

    @Test func otherHostsAreRefused() throws {
        for r in [
            try RepoTarget(repoId: 101, owner: "alice", name: "notes"),
            try RepoTarget(repoId: 202, owner: "bob", name: "brain"),
        ] {
            for s in [
                "https://evil.example/repositories/\(r.id)/x",
                "http://api.github.com/repositories/\(r.id)/x",
                "https://github.com/repositories/\(r.id)/x",
                "https://user@api.github.com/repositories/\(r.id)/x",
                "https://api.github.com:8443/repositories/\(r.id)/x",
            ] {
                #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(s)") { try r.guardURL(URL(string: s)!) }
            }
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

    /// Audit S-M3. Mac Release is team-signed with team 7V4A6JBG4R and a keychain access group, so archives need no
    /// manual Team pick. Mac Debug is always ad-hoc, so the in-app tests can still be hosted. Signing.local.xcconfig
    /// can still override the iPhone team.
    /// A Release archive without GitHubApp.local.xcconfig ships an empty BNGitHubClientID, and the app
    /// shows "GitHub sign-in isn't set up in this version of the app yet." The client ID stays out of git
    /// (the local xcconfig is git-ignored); Release builds must fail instead of shipping empty.
    @Test func releaseBuildsFailWhenTheGitHubClientIDIsEmpty() throws {
        let app = Self.repoRoot.appendingPathComponent("App")
        func read(_ path: String) throws -> String { try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8) }
        let spec = try read("project.yml")
        let base = try read("Config/Base.xcconfig")
        let info = try read("Info.plist")
        let example = try read("Config/GitHubApp.example.xcconfig")
        let ignore = try String(contentsOf: Self.repoRoot.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(info.contains("<key>BNGitHubClientID</key>"))
        #expect(info.contains("<string>$(BN_GITHUB_CLIENT_ID)</string>"))
        #expect(base.contains("BN_GITHUB_CLIENT_ID ="))
        #expect(base.contains(#"#include? "GitHubApp.local.xcconfig""#))
        #expect(ignore.contains("App/Config/*.local.xcconfig"))
        #expect(spec.contains("Require GitHub App client ID in Release"))
        #expect(spec.contains(#"if [ "${CONFIGURATION}" != "Release" ]; then"#))
        #expect(spec.contains(#"if [ -z "${BN_GITHUB_CLIENT_ID}" ]; then"#))
        #expect(spec.contains("error: BN_GITHUB_CLIENT_ID is empty"))
        #expect(example.contains("GitHubApp.local.xcconfig"))
        #expect(example.contains("Required for Release"))
    }

    @Test func macReleaseSignsWithTheCommittedTeamAndDebugStaysAdHoc() throws {
        let app = Self.repoRoot.appendingPathComponent("App")
        func read(_ path: String) throws -> String { try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8) }
        let spec = try read("project.yml"), base = try read("Config/Base.xcconfig"), pbx = try read("BrainNotes.xcodeproj/project.pbxproj")
        // The paid team is committed in Base.xcconfig (iPhone default and Mac Release) and on the Mac Release target.
        #expect(base.contains("DEVELOPMENT_TEAM = 7V4A6JBG4R"))
        #expect(spec.contains("DEVELOPMENT_TEAM[config=Release][sdk=macosx*]: 7V4A6JBG4R"))
        #expect(pbx.contains(#""DEVELOPMENT_TEAM[config=Release][sdk=macosx*]" = 7V4A6JBG4R;"#))
        let example = try read("Config/Signing.example.xcconfig")
        #expect(example.contains("DEVELOPMENT_TEAM = YOUR_TEAM_ID"))
        // Mac Debug: ad-hoc. Mac Release identity/style/entitlements still come from Base.xcconfig's team switch.
        #expect(spec.contains(#"CODE_SIGN_IDENTITY[config=Debug][sdk=macosx*]: "-""#))
        #expect(spec.contains("CODE_SIGN_STYLE[config=Debug][sdk=macosx*]: Manual"))
        #expect(spec.contains(#"DEVELOPMENT_TEAM[config=Debug][sdk=macosx*]: """#))
        #expect(spec.contains("CODE_SIGN_IDENTITY[config=Release][sdk=macosx*]: $(BN_MAC_RELEASE_IDENTITY)"))
        #expect(spec.contains("CODE_SIGN_STYLE[config=Release][sdk=macosx*]: $(BN_MAC_RELEASE_SIGN_STYLE)"))
        #expect(spec.contains("CODE_SIGN_ENTITLEMENTS[config=Release][sdk=macosx*]: $(BN_MAC_RELEASE_ENTITLEMENTS)"))
        for line in [#""CODE_SIGN_IDENTITY[config=Debug][sdk=macosx*]" = "-";"#,
                     #""CODE_SIGN_IDENTITY[config=Release][sdk=macosx*]" = "$(BN_MAC_RELEASE_IDENTITY)";"#,
                     #""CODE_SIGN_STYLE[config=Release][sdk=macosx*]" = "$(BN_MAC_RELEASE_SIGN_STYLE)";"#,
                     #""CODE_SIGN_ENTITLEMENTS[config=Release][sdk=macosx*]" = "$(BN_MAC_RELEASE_ENTITLEMENTS)";"#] {
            #expect(pbx.components(separatedBy: line).count == 3, "in the app target's Debug and Release: \(line)")
        }
        #expect(base.contains(#"#include? "Signing.local.xcconfig""#))
        #expect(base.contains("DEVELOPMENT_TEAM[config=Debug][sdk=macosx*] ="))
        #expect(!base.contains("DEVELOPMENT_TEAM[sdk=macosx*]"), "that would clear the team for Mac Release too")
        #expect(base.contains("BN_MAC_RELEASE_TEAM_OR_NONE = $(DEVELOPMENT_TEAM:default=NONE)"))
        #expect(base.contains("BN_MAC_RELEASE_ENTITLEMENTS_NO = BrainNotes.entitlements"))
        #expect(base.contains("BN_MAC_RELEASE_ENTITLEMENTS_YES = BrainNotes.adhoc.entitlements"))
        // Team-signed Release carries the app's keychain group; the ad-hoc fallback can't, and doesn't.
        let release = try read("BrainNotes.entitlements"), adhoc = try read("BrainNotes.adhoc.entitlements")
        #expect(release.contains("<key>keychain-access-groups</key>"))
        #expect(release.contains("<string>$(AppIdentifierPrefix)com.itamargendelman.brainnotes</string>"))
        #expect(!adhoc.contains("keychain-access-groups"))
        for entitlements in [release, adhoc] {
            #expect(entitlements.contains("<key>com.apple.security.app-sandbox</key>"))
            #expect(entitlements.contains("<key>com.apple.security.network.client</key>"))
        }
    }

    /// Audit S-L1. The device code opens this sign-in for a few minutes. On iOS it stays on the device and expires with
    /// the code. On macOS it comes off the pasteboard after sign-in or when it runs out, unless something else was
    /// copied since. Read from the source, as the iOS half doesn't compile on a Mac.
    @Test func theDeviceCodeLeavesThePasteboard() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Sources/SignInAndSettings.swift"), encoding: .utf8)
        #expect(source.contains("options: [.expirationDate: expiresAt, .localOnly: true]"))
        #expect(source.components(separatedBy: "UIPasteboard.general.setItems(").count == 2, "one way onto the iPhone's pasteboard")
        #expect(source.components(separatedBy: "setString(").count == 2, "one way onto the Mac's")
        #expect(source.contains("copied = (board.changeCount, code)"))
        #expect(source.contains("guard board.changeCount == mine.change, board.string(forType: .string) == code else { return }"))
        #expect(source.contains("try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))"), "when it runs out")
        #expect(source.contains("DeviceCodeClipboard.copy(code.userCode, until: expiresAt"))
        #expect(source.components(separatedBy: "DeviceCodeClipboard.copy(").count == 2, "one place copies the code: the model's")
        // Automatic re-copy on returning to the foreground is iPhone-only; on a Mac it would overwrite the clipboard
        // whenever the window became active. copyCode is the one path onto the pasteboard, and sceneBecameActive
        // calls it only under #if os(iOS).
        let scene = try #require(source.range(of: "func sceneBecameActive(_ app: AppModel) {"))
        let sceneEnd = try #require(source.range(of: "\n    }\n", range: scene.upperBound..<source.endIndex))
        let sceneBody = source[scene.upperBound..<sceneEnd.lowerBound]
        #expect(sceneBody.contains("poller?.wake()"))
        #expect(sceneBody.contains("#if os(iOS)"))
        #expect(sceneBody.contains("copyCode(app)"))
        let ios = try #require(sceneBody.range(of: "#if os(iOS)"))
        let endif = try #require(sceneBody.range(of: "#endif", range: ios.upperBound..<sceneBody.endIndex))
        let copy = try #require(sceneBody.range(of: "copyCode(app)"))
        #expect(ios.upperBound < copy.lowerBound && copy.upperBound < endif.lowerBound)
        // After sign-in: once GitHub approved (the code is used up), before anything is verified or saved.
        let approved = try #require(source.range(of: "private func approved(_ pair: TokenPair, code: DeviceCode) {"))
        let forget = try #require(source.range(of: "DeviceCodeClipboard.forget(code.userCode)", range: approved.upperBound..<source.endIndex))
        let checking = try #require(source.range(of: "step = .checking", range: approved.upperBound..<source.endIndex))
        #expect(approved.upperBound < forget.lowerBound && forget.upperBound < checking.lowerBound)
        // The sign-in itself is handed over only by Continue, with the pair that was verified, never straight from polling.
        #expect(source.components(separatedBy: "app.signedIn(pair:").count == 2)
        let confirm = try #require(source.range(of: "func confirm(_ app: AppModel) {"))
        let handover = try #require(source.range(of: "app.signedIn(pair: ok.pair, verifiedUser: ok.user)"))
        let guardedBy = try #require(source.range(of: "guard case .confirming = step", range: confirm.upperBound..<source.endIndex))
        #expect(confirm.upperBound < guardedBy.lowerBound && guardedBy.upperBound < handover.lowerBound)
        // A code that ended without a sign-in comes off the pasteboard as well.
        let finish = try #require(source.range(of: "private func finish(_ ended: Step, code: DeviceCode) {"))
        #expect(source.range(of: "DeviceCodeClipboard.forget(code.userCode)", range: finish.upperBound..<source.endIndex) != nil)
    }

    /// Audit F-3. A session that ends (Sign out and wipe, or a switch to or from the sample notes) takes the Undo of a
    /// delete with it. Otherwise the deleted note's text stays in memory, and an Undo still on screen writes it back
    /// into the session that opens next, the freshly wiped one included. Read from the source: the app model's own
    /// tests run only inside the app.
    @Test func endingASessionTakesItsUndoAndTextWithIt() throws {
        let model = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Sources/AppModel.swift"), encoding: .utf8)
        func body(of signature: String) throws -> Substring {
            let start = try #require(model.range(of: signature), "\(signature)")
            let end = try #require(model.range(of: "\n    }\n", range: start.upperBound..<model.endIndex))
            return model[start.upperBound..<end.lowerBound]
        }
        let drop = try body(of: "private func dropSession() {")
        for needle in ["listener?.cancel()", "session = nil", "undoDismissTask?.cancel()", "undoDismissTask = nil", "blackHole = nil",
                       "blackHoleSnapshots = []", "openEditor = nil", "changedPaths = []", "moved = nil"] {
            #expect(drop.contains(needle), "dropSession: \(needle)")
        }
        for signature in ["func startSampleNotes() async {", "func leaveSampleNotes() async {",
                          "func changeNotesRepository() async {", "func signOutAndWipe() async {"] {
            #expect(try body(of: signature).contains("dropSession()"), "\(signature)")
        }
        // A delete that is still reading or deleting its notes when the session ends offers no Undo for them.
        let delete = try body(of: "func requestDelete(paths: [String], intensity: BlackHoleIntensity? = nil) async {")
        #expect(delete.components(separatedBy: "guard session === s else { return }").count == 3,
                "checked once the notes are read, and again once they are deleted")
        let swirl = try body(of: "func blackHoleAnimationDidFinish() async {")
        #expect(swirl.contains("guard session === s else { return }"))
    }

    /// All that defaults ever hold: three yes/no flags, under keys fixed in one place.
    @Test func defaultsHoldOnlyTheOnboardingFlags() throws {
        let all = try sources()
        let model = try #require(all.first { $0.0.hasSuffix("App/Sources/AppModel.swift") }?.1)
        #expect(model.contains("static let onboardedKey = \"bn.onboarded\""))
        #expect(model.contains("static let sampleModeKey = \"bn.sampleMode\""))
        #expect(model.contains("static let installedKey = \"bn.installed\""))
        let writes = model.split(separator: "\n").filter { $0.contains("defaults.set(") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Set(writes) == [
            "defaults.set(true, forKey: Self.onboardedKey)",
            "defaults.set(true, forKey: Self.sampleModeKey)",
            "defaults.set(true, forKey: Self.installedKey)",
        ])
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
        // The inbox in GitHub's spelling, which captures and conflict copies take: shown too.
        #expect(PathPolicy.isVisible("_Inbox/a.md"))
        #expect(PathPolicy.isVisible("_INBOX/a.md"))
        #expect(!PathPolicy.isVisible("notes/_Inbox/a.md"))
        #expect(!PathPolicy.isVisible("_inboxes/a.md"))
        // In the inbox, any spelling, subfolders too; never a root file or a look-alike folder.
        #expect(PathPolicy.isInInbox("_inbox/a.md"))
        #expect(PathPolicy.isInInbox("_Inbox/a.md"))
        #expect(PathPolicy.isInInbox("_INBOX/later/a.md"))
        #expect(!PathPolicy.isInInbox("_inbox.md"))
        #expect(!PathPolicy.isInInbox("_inboxes/a.md"))
        #expect(!PathPolicy.isInInbox("notes/_Inbox/a.md"))
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
        defer { try? s.wipe() }
        for bad in ["../x.md", "a/../../x.md", "", "a//b.md", "./a.md", "/etc/x.md"] {
            #expect(throws: FileStoreError.invalidPath, "\(bad)") { try s.write(bad, "x") }
        }
    }

    @Test func missingFileIsNilNotAnError() throws {
        let s = try store()
        defer { try? s.wipe() }
        #expect(try s.readText("nope.md") == nil)
        try s.write("a/b.md", "x")
        #expect(try s.readText("a/b.md") == "x")
        try s.remove("a/b.md")
        #expect(!FileManager.default.fileExists(atPath: s.filesRoot.appendingPathComponent("a").path))
        #expect(FileManager.default.fileExists(atPath: s.filesRoot.path))
    }

    @Test func bytesRoundTripExactly() throws {
        let s = try store()
        defer { try? s.wipe() }
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
        defer { try? s.wipe() }
        let nfdPath = "עברית/Cafe\u{301}.md"
        let nfcPath = "עברית/Caf\u{E9}.md"
        try s.write(nfdPath, "x")
        #expect(try s.readText(nfdPath) == "x")
        // APFS is normalization-insensitive: the other spelling reaches the same file. That is why the
        // engine stores only one of two twins on a device. Linux file systems keep both spellings apart.
        #if canImport(Darwin)
        #expect(try s.readText(nfcPath) == "x")
        #else
        _ = nfcPath
        #endif
    }

    @Test func stagingSwap() throws {
        let s = try store()
        defer { try? s.wipe() }
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

    /// Audit S-L2. A pax record's length is a number from the archive: one near `Int.max` overflowed `i + len` and
    /// trapped. A length that runs past the end of its header, however large, is now a bad header: thrown, not a crash.
    /// First sync then takes every note from the blobs API, as for any tarball it can't use.
    @Test func aPaxLengthPastItsHeaderThrowsInsteadOfTrapping() throws {
        let long = String(repeating: "long/", count: 30) + "a.md"
        for length in ["9223372036854775807", "9223372036854775806", "99999999999999999999999", "4000"] {
            var tar = [UInt8](TarWriter.archive([(long, Data("x".utf8))], rootDir: "r"))
            // The global header and its body, then the pax header (block 2) and its one-block body (block 3).
            #expect(tar[1024 + 156] == UInt8(ascii: "x"))
            let body = Array("\(length) path=r/a.md\n".utf8)
            for k in 1536..<2048 { tar[k] = 0 }
            for (k, c) in body.enumerated() { tar[1536 + k] = c }
            // The pax header's size field, in octal, says how long that body is now.
            for k in (1024 + 124)..<(1024 + 136) { tar[k] = 0 }
            for (k, c) in String(body.count, radix: 8).utf8.enumerated() { tar[1024 + 124 + k] = c }
            #expect(throws: TarballError.badHeader, "\(length)") { try TarReader.files(in: Data(tar)) }
        }
        // The same record with its true length still names the file.
        var tar = [UInt8](TarWriter.archive([(long, Data("x".utf8))], rootDir: "r"))
        let record = " path=r/a.md\n"
        let body = Array("\(record.utf8.count + 2)\(record)".utf8)
        for k in 1536..<2048 { tar[k] = 0 }
        for (k, c) in body.enumerated() { tar[1536 + k] = c }
        for k in (1024 + 124)..<(1024 + 136) { tar[k] = 0 }
        for (k, c) in String(body.count, radix: 8).utf8.enumerated() { tar[1024 + 124 + k] = c }
        #expect(try TarReader.files(in: Data(tar)).map(\.path) == ["a.md"])
    }

    /// The bytes `git archive` really writes for a repo: read the checked-in sample shape by hand.
    @Test func readsPaxPathOverUstarName() throws {
        let tar = TarWriter.archive([("a/עברית.md", Data("x".utf8))], rootDir: "r")
        let out = try TarReader.files(in: tar)
        #expect(out.map(\.path) == ["a/עברית.md"])
    }
}
