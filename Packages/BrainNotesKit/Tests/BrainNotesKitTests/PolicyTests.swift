import BrainMerge
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BrainNotesKit

@Suite struct RepoGuardTests {
    /// Not on the allow-list: other owners, forks, case variants, whitespace, invisible and look-alike characters,
    /// near names, and owner and name run together or split elsewhere.
    static let refused: [(owner: String, name: String)] = [
        ("itamargend", "brain-notes-test"), ("Itamargend", "Brain-Notes-Test"), ("ITAMARGEND", "brain"),
        ("Itamargend", "Brain"), ("Itamargend", "BRAIN"),
        ("someone", "brain-notes-test"), ("someone", "brain"), ("Itamargend-fork", "brain"), ("brain-fork", "brain"),
        (" Itamargend", "brain"), ("Itamargend ", "brain"), ("Itamargend", " brain"), ("Itamargend", "brain "),
        ("Itamargend", "brain\n"), ("Itamargend", "\tbrain-notes-test"),
        ("Itamargend", "brain\u{200B}"), ("Itamargend", "br\u{0430}in"), ("Itamargend", "\u{FF42}rain"),
        ("Itamargend", "brain.git"), ("Itamargend", "brain-notes"), ("Itamargend", "brain-notes-test2"), ("Itamargend", "brai"),
        ("Itamargend", "brain/../brain-notes-test"), ("Itamargend/brain", ""), ("", "Itamargend/brain"), ("Itamargend", "Itamargend/brain"),
        ("Itamargend", ""), ("", "brain"), ("", ""), ("someone", "else"),
    ]

    /// A build may name exactly two repos: the test repo and the real brain.
    @Test func bothListedReposAreAllowed() throws {
        #expect(RepoTarget.allowList.map(\.slug) == ["Itamargend/brain-notes-test", "Itamargend/brain"])
        let test = try RepoTarget(owner: "Itamargend", name: "brain-notes-test")
        #expect(test == .testRepo)
        #expect(test.slug == "Itamargend/brain-notes-test")
        #expect(test.id == "Itamargend_brain-notes-test")
        let brain = try RepoTarget(owner: "Itamargend", name: "brain")
        #expect(brain == .brain)
        #expect(brain.slug == "Itamargend/brain")
        #expect(brain.id == "Itamargend_brain")
        #expect(test != brain)
    }

    /// Byte for byte: nothing is trimmed, case-folded or normalized into a listed repo.
    @Test func everyOtherRepoIsRefused() {
        for (owner, name) in Self.refused {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(owner)/\(name)") { try RepoTarget(owner: owner, name: name) }
        }
    }

    @Test func theClientCannotBeBuiltForAnotherRepo() {
        let t = InMemoryTokenStore()
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: t)
        for (owner, name) in Self.refused {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(owner)/\(name)") {
                try GitHubHTTPClient(owner: owner, name: name, transport: URLSession.shared, tokens: m)
            }
        }
    }

    /// A build that names a repo off the list must not even open: the app shows its "misconfigured" screen.
    @Test func theLiveSessionRefusesAnyOtherRepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (owner, name) in Self.refused {
            #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(owner)/\(name)") {
                try BrainSession.live(config: AppConfig(clientId: "x", owner: owner, name: name), baseFolder: dir, deviceLabel: "test",
                                      tokens: InMemoryTokenStore())
            }
        }
        // As the app reads it from Info.plist, too: a wrong spelling, and a build with no repo set at all.
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
            try BrainSession.live(config: AppConfig(info: ["BNGitHubClientID": "x", "BNRepoOwner": "Itamargend", "BNRepoName": "Brain"]),
                                  baseFolder: dir, deviceLabel: "test", tokens: InMemoryTokenStore())
        }
        #expect(throws: RepoTarget.GuardError.repoNotAllowed) {
            try BrainSession.live(config: AppConfig(info: [:]), baseFolder: dir, deviceLabel: "test", tokens: InMemoryTokenStore())
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "and it leaves nothing behind")
    }

    @Test func theLiveSessionOpensForEitherListedRepoAndKeysItsData() throws {
        for repo in RepoTarget.allowList {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-live-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let info: [String: Any] = ["BNGitHubClientID": "x", "BNRepoOwner": repo.owner, "BNRepoName": repo.name]
            let s = try BrainSession.live(config: AppConfig(info: info), baseFolder: dir, deviceLabel: "test", tokens: InMemoryTokenStore())
            #expect(s.repo == repo)
            #expect(!s.isDemo)
            #expect(s.deviceFlow() != nil)
            let files = dir.appendingPathComponent("Brain/\(repo.id)/files").path
            #expect(FileManager.default.fileExists(atPath: files))
            #expect(s.store.device.hasPrefix("test-"))
        }
    }

    /// A build talks to the one repo it names. The other repo on the list is refused like any other, both ways round,
    /// by the guard itself and by the client that checks every request it builds.
    @Test func theGuardRefusesTheOtherListedRepo() throws {
        let m = TokenManager(clientId: "x", transport: URLSession.shared, store: InMemoryTokenStore())
        for (active, other) in [(RepoTarget.testRepo, RepoTarget.brain), (RepoTarget.brain, RepoTarget.testRepo)] {
            try active.guardURL(URL(string: "https://api.github.com/repos/\(active.slug)/git/ref/heads/main")!)
            try active.guardURL(URL(string: "https://api.github.com/graphql")!)
            let c = try GitHubHTTPClient(owner: active.owner, name: active.name, transport: URLSession.shared, tokens: m)
            #expect(c.repo == active)
            _ = try c.request("GET", "repos/\(active.slug)/tarball/" + String(repeating: "a", count: 40))
            for path in [
                "repos/\(other.slug)/git/ref/heads/main",
                "repos/\(other.slug)/tarball/" + String(repeating: "a", count: 40),
                "repos/\(other.slug)",
                "repos/\(active.slug)/../\(other.name)/git/ref/heads/main",
                "repos/\(active.slug)/%2E%2E/\(other.name)/git/ref/heads/main",
            ] {
                #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(active.name): \(path)") {
                    try active.guardURL(URL(string: "https://api.github.com/" + path)!)
                }
                #expect(throws: RepoTarget.GuardError.repoNotAllowed, "\(active.name): \(path)") { try c.request("GET", path) }
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
        for r in RepoTarget.allowList {
            for s in [
                "https://evil.example/repos/\(r.slug)/x",
                "http://api.github.com/repos/\(r.slug)/x",
                "https://github.com/repos/\(r.slug)/x",
                "https://user@api.github.com/repos/\(r.slug)/x",
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

    /// Audit S-M3. Mac Release is team-signed with a keychain access group when the git-ignored Signing.local.xcconfig
    /// names a team, and ad-hoc without one. Mac Debug is always ad-hoc. No team ID is committed.
    @Test func macReleaseSigningComesFromTheLocalFileAndNoTeamIsCommitted() throws {
        let app = Self.repoRoot.appendingPathComponent("App")
        func read(_ path: String) throws -> String { try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8) }
        let spec = try read("project.yml"), base = try read("Config/Base.xcconfig"), pbx = try read("BrainNotes.xcodeproj/project.pbxproj")
        // A team ID is ten capitals and digits. None follows DEVELOPMENT_TEAM in a committed file.
        let team = try NSRegularExpression(pattern: #"DEVELOPMENT_TEAM[^\n]*?[:=]\s*"?[A-Z0-9]{10}\b"#)
        for name in ["project.yml", "Config/Base.xcconfig", "Config/Signing.example.xcconfig", "Config/GitHubApp.example.xcconfig",
                     "BrainNotes.xcodeproj/project.pbxproj"] {
            let text = try read(name)
            #expect(team.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, "a team ID in \(name)")
        }
        // Mac Debug: ad-hoc. Mac Release: whatever Base.xcconfig works out. The project matches its spec.
        #expect(spec.contains(#"CODE_SIGN_IDENTITY[config=Debug][sdk=macosx*]: "-""#))
        #expect(spec.contains("CODE_SIGN_STYLE[config=Debug][sdk=macosx*]: Manual"))
        #expect(spec.contains("CODE_SIGN_IDENTITY[config=Release][sdk=macosx*]: $(BN_MAC_RELEASE_IDENTITY)"))
        #expect(spec.contains("CODE_SIGN_STYLE[config=Release][sdk=macosx*]: $(BN_MAC_RELEASE_SIGN_STYLE)"))
        #expect(spec.contains("CODE_SIGN_ENTITLEMENTS[config=Release][sdk=macosx*]: $(BN_MAC_RELEASE_ENTITLEMENTS)"))
        #expect(!spec.contains("DEVELOPMENT_TEAM[config=Release]"), "the Release team comes from the local file, through Base.xcconfig")
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
        #expect(source.contains("DeviceCodeClipboard.copy(text, until: model.expiresAt"))
        // After sign-in: once GitHub approved, before the screen goes.
        let approved = try #require(source.range(of: "let pair = try await flow.waitForApproval(code)"))
        let forget = try #require(source.range(of: "DeviceCodeClipboard.forget(code.userCode)"))
        let signedIn = try #require(source.range(of: "Task { await app.signedIn(pair: pair) }"))
        #expect(approved.upperBound < forget.lowerBound && forget.upperBound < signedIn.lowerBound)
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
        for signature in ["func startSampleNotes() async {", "func leaveSampleNotes() async {", "func signOutAndWipe() async {"] {
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
