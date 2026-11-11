import Foundation
import Testing
@testable import BrainNotesKit

// Tests written from the coverage gap report (.plan/cloud/test-coverage.md): what GitHub's wire format,
// the token endpoints and the device flow can send that no other test sends.

/// Answers every request with the next scripted body (the last one repeats) and records what was sent.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String]
    private let status: Int
    private var sent: [URLRequest] = []

    init(status: Int = 200, _ bodies: String...) {
        self.status = status
        self.bodies = bodies.isEmpty ? ["{}"] : bodies
    }

    var log: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String = lock.withLock {
            sent.append(request)
            return bodies.count > 1 ? bodies.removeFirst() : bodies[0]
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

private func makeClient(_ t: HTTPTransport) throws -> GitHubHTTPClient {
    let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore(TokenPair(access: "a")))
    return try GitHubHTTPClient(owner: RepoTarget.testRepo.owner, name: RepoTarget.testRepo.name, transport: t, tokens: m)
}

private let goodSha = String(repeating: "b", count: 40)

@Suite struct GraphQLVariablesTests {
    /// A note path is user text. It must travel only as a GraphQL variable, never inside the query text,
    /// and the repository the query names must be the one allowed repo.
    @Test func aPathCannotRewriteTheQuery() async throws {
        let hostile = "a\") { viewer { login } } #.md"
        let t = ScriptedTransport("""
            {"data":{"repository":{"object":{"f0":{"nodes":[{"committedDate":"2026-01-02T03:04:05Z"}]},"f1":{"nodes":[]}}}}}
            """)
        let out = try await makeClient(t).lastCommitDates(head: goodSha, paths: [hostile, "b.md"])

        let date = try #require(parseISOTime("2026-01-02T03:04:05Z"))
        #expect(out == [PathDate(path: hostile, date: date)])
        let req = try #require(t.log.first)
        #expect(req.url?.path == "/graphql")
        #expect(req.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        let query = try #require(body["query"] as? String)
        let vars = try #require(body["variables"] as? [String: Any])
        #expect(!query.contains("viewer"), "the path stayed out of the query text")
        #expect(!query.contains("b.md"))
        #expect(sameBytes(vars["p0"] as? String ?? "", hostile))
        #expect(sameBytes(vars["p1"] as? String ?? "", "b.md"))
        #expect(vars["owner"] as? String == RepoTarget.testRepo.owner)
        #expect(vars["name"] as? String == RepoTarget.testRepo.name)
        #expect(vars["oid"] as? String == goodSha)
    }

    @Test func noPathsMakeNoRequest() async throws {
        let t = ScriptedTransport()
        #expect(try await makeClient(t).lastCommitDates(head: goodSha, paths: []).isEmpty)
        #expect(t.log.isEmpty)
    }

    @Test func aBadHeadNeverReachesTheQuery() async throws {
        let t = ScriptedTransport()
        await #expect(throws: GitHubError.badResponse("sha")) {
            try await makeClient(t).lastCommitDates(head: "main\") { x }", paths: ["a.md"])
        }
        #expect(t.log.isEmpty)
    }
}

@Suite struct WireFormatGapTests {
    /// Every status the compare API documents. "copied" is a new file here, "changed" an edit, and
    /// "unchanged" nothing at all; an entry without a file name is skipped, not fatal.
    @Test func everyCompareStatusMaps() async throws {
        let t = ScriptedTransport("""
            {"status":"ahead","files":[
              {"filename":"a.md","status":"copied","sha":"1"},
              {"filename":"b.md","status":"unchanged","sha":"2"},
              {"filename":"c.md","status":"changed","sha":"3"},
              {"filename":"d.md","status":"renamed","previous_filename":"old/d.md","sha":"4"},
              {"filename":"e.md","status":"removed"},
              {"filename":"f.md","status":"modified","sha":"6"},
              {"status":"added","sha":"7"}
            ]}
            """)
        let c = try await makeClient(t).compare(base: goodSha, head: goodSha)
        #expect(c.files == [
            ChangedFile(path: "a.md", status: .added, sha: "1"),
            ChangedFile(path: "c.md", status: .modified, sha: "3"),
            ChangedFile(path: "d.md", status: .renamed, previousPath: "old/d.md", sha: "4"),
            ChangedFile(path: "e.md", status: .removed),
            ChangedFile(path: "f.md", status: .modified, sha: "6"),
        ])
        #expect(!c.truncated)
    }

    /// A ref that answers with something other than a sha must not become a URL in the next request.
    @Test func aRefWithABadShaIsRefused() async throws {
        for bad in ["../../brain", "main", String(repeating: "A", count: 40), String(repeating: "a", count: 39)] {
            let t = ScriptedTransport("{\"object\":{\"sha\":\"\(bad)\"}}")
            await #expect(throws: GitHubError.badResponse("sha"), "\(bad)") { try await makeClient(t).getRef(etag: nil) }
        }
        let t = ScriptedTransport("{\"object\":{}}")
        await #expect(throws: GitHubError.badResponse("ref")) { try await makeClient(t).getRef(etag: nil) }
    }

    @Test func aRefSendsItsEtagAndA304IsNotModified() async throws {
        let t = ScriptedTransport(status: 304, "")
        let r = try await makeClient(t).getRef(etag: "W/\"abc\"")
        #expect(r == .notModified)
        #expect(t.log.first?.value(forHTTPHeaderField: "If-None-Match") == "W/\"abc\"")
    }

    @Test func aBlobThatIsNotBase64IsRefused() async throws {
        let t = ScriptedTransport("{\"content\":\"hello\",\"encoding\":\"utf-8\"}")
        await #expect(throws: GitHubError.badResponse("blob")) { try await makeClient(t).blob(goodSha) }
        let none = ScriptedTransport("{\"encoding\":\"base64\"}")
        await #expect(throws: GitHubError.badResponse("blob")) { try await makeClient(none).blob(goodSha) }
    }

    /// Anything that is not a JSON object is a bad response, never a crash or an empty success.
    @Test func aBodyThatIsNotAnObjectIsABadResponse() async throws {
        await #expect(throws: GitHubError.badResponse("json")) { try await makeClient(ScriptedTransport("[]")).getCommit(goodSha) }
        await #expect(throws: (any Error).self) { try await makeClient(ScriptedTransport("<html>")).getCommit(goodSha) }
    }

    /// A status the client has no rule for (409: the repository is empty) is a failure with the code in it.
    @Test func anUnmappedStatusIsABadResponse() async throws {
        await #expect(throws: GitHubError.badResponse("status 409")) {
            try await makeClient(ScriptedTransport(status: 409, "{\"message\":\"Git Repository is empty.\"}")).getCommit(goodSha)
        }
    }

    /// Every request the client builds carries the API version and the token, and nothing else of ours.
    @Test func requestsCarryTheTokenAndTheAPIVersion() async throws {
        let t = ScriptedTransport("{\"sha\":\"\(goodSha)\",\"tree\":{\"sha\":\"\(goodSha)\"},\"parents\":[]}")
        _ = try await makeClient(t).getCommit(goodSha)
        let req = try #require(t.log.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer a")
        #expect(req.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(req.url?.absoluteString == "https://api.github.com/repos/Itamargend/brain-notes-test/git/commits/\(goodSha)")
    }
}

@Suite struct TokenParsingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aFullAnswerSetsBothExpiries() throws {
        let data = Data("{\"access_token\":\"tok-a\",\"expires_in\":28800,\"refresh_token\":\"tok-r\",\"refresh_token_expires_in\":100}".utf8)
        let p = try TokenManager.parseTokenResponse(data, now: now)
        #expect(p == TokenPair(access: "tok-a", refresh: "tok-r",
                               accessExpiry: now.addingTimeInterval(28800), refreshExpiry: now.addingTimeInterval(100)))
    }

    @Test func aTokenThatNeverExpiresHasNoExpiry() throws {
        let p = try TokenManager.parseTokenResponse(Data("{\"access_token\":\"tok-a\"}".utf8), now: now)
        #expect(p == TokenPair(access: "tok-a"))
    }

    @Test func errorsAndEmptyTokensAreNotASignIn() {
        for body in ["{\"error\":\"bad_refresh_token\"}", "{\"access_token\":\"\"}", "{\"access_token\":\"x\",\"error\":\"e\"}", "{}"] {
            #expect(throws: GitHubError.unauthorized, "\(body)") { try TokenManager.parseTokenResponse(Data(body.utf8), now: now) }
        }
        #expect(throws: GitHubError.badResponse("token")) { try TokenManager.parseTokenResponse(Data("[]".utf8), now: now) }
        #expect(throws: (any Error).self) { try TokenManager.parseTokenResponse(Data("not json".utf8), now: now) }
    }

    /// The refresh token and device code travel in a form body: characters that mean something there are escaped.
    @Test func formBodiesEscapeWhatTheFormUses() {
        let body = String(decoding: Form.encode(["b": "x y&z=+/", "a": "1", "c": "-._~"]), as: UTF8.self)
        #expect(body == "a=1&b=x%20y%26z%3D%2B%2F&c=-._~")
    }
}

@Suite struct TokenManagerGapTests {
    @Test func noStoredPairIsSignedOut() async {
        let t = ScriptedTransport(status: 500)
        let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore())
        await #expect(throws: GitHubError.unauthorized) { try await m.accessToken() }
        #expect(t.log.isEmpty)
    }

    /// An expiring token with nothing to refresh it is used as it is; there is no request to make.
    @Test func anExpiringTokenWithoutARefreshTokenIsUsedAsIs() async throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let t = ScriptedTransport(status: 500)
        let m = TokenManager(clientId: "c", transport: t,
                             store: InMemoryTokenStore(TokenPair(access: "a", accessExpiry: now.addingTimeInterval(30))), now: { now })
        #expect(try await m.accessToken() == "a")
        #expect(t.log.isEmpty)
    }

    @Test func aRefreshWithoutARefreshTokenSignsOut() async {
        let t = ScriptedTransport(status: 500)
        let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore(TokenPair(access: "a")))
        await #expect(throws: GitHubError.unauthorized) { try await m.refresh(failed: "a") }
        #expect(t.log.isEmpty)
    }

    /// Another request already rotated the token that failed: use the new one, spend nothing.
    @Test func aTokenAlreadyReplacedIsNotRefreshedAgain() async throws {
        let t = ScriptedTransport(status: 500)
        let m = TokenManager(clientId: "c", transport: t, store: InMemoryTokenStore(TokenPair(access: "new", refresh: "r")))
        #expect(try await m.refresh(failed: "old") == "new")
        #expect(t.log.isEmpty)
        #expect(await m.refreshCount == 0)
    }

    @Test func theRefreshRequestHasNoSecretAndNoBearer() async throws {
        let t = ScriptedTransport("{\"access_token\":\"fresh\",\"refresh_token\":\"r2\"}")
        let store = InMemoryTokenStore(TokenPair(access: "a", refresh: "r1"))
        let m = TokenManager(clientId: "cid", transport: t, store: store)
        #expect(try await m.refresh(failed: "a") == "fresh")
        let req = try #require(t.log.first)
        #expect(req.url?.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=cid&grant_type=refresh_token&refresh_token=r1")
        #expect(try store.load() == TokenPair(access: "fresh", refresh: "r2"))
    }
}

@Suite struct DeviceFlowGapTests {
    private func flow(_ t: HTTPTransport, now: Date = Date(timeIntervalSince1970: 0)) -> DeviceFlow {
        DeviceFlow(clientId: "c", transport: t, sleep: { _ in }, now: { now })
    }

    @Test func startUsesGitHubsDefaultsWhenTheyAreLeftOut() async throws {
        let t = ScriptedTransport("{\"device_code\":\"d\",\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://github.com/login/device\"}")
        let code = try await flow(t).start()
        #expect(code == DeviceCode(deviceCode: "d", userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!,
                                   interval: 5, expiresIn: 900))
    }

    @Test func startFailsOnAnErrorOrAMissingField() async {
        await #expect(throws: DeviceFlowError.failed("unauthorized_client")) {
            try await flow(ScriptedTransport("{\"error\":\"unauthorized_client\"}")).start()
        }
        await #expect(throws: DeviceFlowError.failed("response")) {
            try await flow(ScriptedTransport("{\"device_code\":\"d\",\"user_code\":\"U\"}")).start()
        }
        await #expect(throws: DeviceFlowError.failed("response")) { try await flow(ScriptedTransport("[]")).start() }
    }

    /// The sign-in button opens this page and says it is github.com: any other scheme or host is refused (audit B4).
    @Test func startRefusesAVerificationPageThatIsNotGitHub() async throws {
        for bad in ["http://github.com/login/device", "https://github.com.example.com/login/device",
                    "https://example.com/login/device", "https://gist.github.com/login/device",
                    "https://github.com@example.com/login/device", "https://user@github.com/login/device",
                    "javascript:alert(1)", "/login/device", "ftp://github.com/login/device"] {
            let body = "{\"device_code\":\"d\",\"user_code\":\"U\",\"verification_uri\":\"\(bad)\"}"
            await #expect(throws: DeviceFlowError.failed("verification_uri"), "\(bad)") {
                try await flow(ScriptedTransport(body)).start()
            }
        }
        let good = "{\"device_code\":\"d\",\"user_code\":\"U\",\"verification_uri\":\"https://github.com/login/device\"}"
        #expect(try await flow(ScriptedTransport(good)).start().verificationURI.absoluteString == "https://github.com/login/device")
    }

    @Test func anUnknownPollErrorEndsTheFlow() async {
        let code = DeviceCode(deviceCode: "d", userCode: "U", verificationURI: URL(string: "https://github.com/login/device")!,
                              interval: 1, expiresIn: 900)
        await #expect(throws: DeviceFlowError.failed("incorrect_device_code")) {
            try await flow(ScriptedTransport("{\"error\":\"incorrect_device_code\"}")).waitForApproval(code)
        }
    }

    @Test func aCodeAlreadyExpiredAsksNothing() async {
        let t = ScriptedTransport("{\"access_token\":\"never\"}")
        let code = DeviceCode(deviceCode: "d", userCode: "U", verificationURI: URL(string: "https://github.com/login/device")!,
                              interval: 1, expiresIn: 0)
        await #expect(throws: DeviceFlowError.expired) { try await flow(t).waitForApproval(code) }
        #expect(t.log.isEmpty)
    }
}
