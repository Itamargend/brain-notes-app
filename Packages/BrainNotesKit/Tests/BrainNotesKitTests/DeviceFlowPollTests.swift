import Foundation
import Testing
@testable import BrainNotesKit

/// What the token endpoint does on each request, in order; the last step repeats. No network.
private final class PollScript: HTTPTransport, @unchecked Sendable {
    enum Step {
        case json([String: Any])
        case body(Int, String)
        case fail(Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var sent: [URLRequest] = []

    init(_ steps: Step...) { self.steps = steps.isEmpty ? [.json(["error": "authorization_pending"])] : steps }

    var requestCount: Int { lock.withLock { sent.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: Step = lock.withLock {
            sent.append(request)
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        let url = try #require(request.url)
        switch step {
        case let .json(fields):
            return (try JSONSerialization.data(withJSONObject: fields),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        case let .body(status, text):
            return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        case let .fail(error):
            throw error
        }
    }
}

private let page = URL(string: "https://github.com/login/device")!

private func code(interval: Int = 5, expiresIn: Int = 900) -> DeviceCode {
    DeviceCode(deviceCode: "d", userCode: "WDJB-MJHT", verificationURI: page, interval: interval, expiresIn: expiresIn)
}

private func flow(_ transport: HTTPTransport, clock: TestClock = TestClock()) -> DeviceFlow {
    DeviceFlow(clientId: "c", transport: transport, sleep: { clock.sleep(Double($0.components.seconds)) }, now: { clock.now })
}

@Suite struct DeviceFlowPollTests {
    @Test func eachAnswerIsOneOutcome() async throws {
        #expect(await flow(PollScript(.json(["error": "authorization_pending"]))).poll(code()) == .pending)
        #expect(await flow(PollScript(.json(["error": "expired_token"]))).poll(code()) == .expired)
        #expect(await flow(PollScript(.json(["error": "access_denied"]))).poll(code()) == .denied)
        #expect(await flow(PollScript(.json(["error": "incorrect_device_code"]))).poll(code()) == .fatal("incorrect_device_code"))
        #expect(await flow(PollScript(.json(["error": "device_flow_disabled"]))).poll(code()) == .fatal("device_flow_disabled"))

        let outcome = await flow(PollScript(.json(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 28800]))).poll(code())
        guard case let .approved(pair) = outcome else {
            Issue.record("not approved: \(outcome)")
            return
        }
        #expect(pair.access == "ghu_new")
        #expect(pair.refresh == "ghr_new")
        #expect(pair.accessExpiry != nil)
    }

    /// `slow_down` raises the interval in force by 5, or takes the larger interval GitHub names.
    @Test func slowDownRaisesTheIntervalInForce() async {
        let echoed = PollScript(.json(["error": "slow_down", "interval": 30]))
        #expect(await flow(echoed).poll(code(), currentInterval: 5) == .slowDown(newInterval: 30))
        let bare = PollScript(.json(["error": "slow_down"]))
        #expect(await flow(bare).poll(code(), currentInterval: 5) == .slowDown(newInterval: 10))
        #expect(await flow(bare).poll(code(), currentInterval: 12) == .slowDown(newInterval: 17))
        #expect(await flow(bare).poll(code(interval: 8)) == .slowDown(newInterval: 13), "the code's own interval when none is given")
    }

    /// The report: iOS suspends the app while the user signs in somewhere else, and the dropped request came back as
    /// an error that was not a `URLError`. Nothing but a verdict may end the wait.
    @Test func everyFailureThatIsNoVerdictIsTransient() async {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 53, userInfo: [NSLocalizedDescriptionKey: "Software caused connection abort"])
        let failures: [(String, PollScript)] = [
            ("NSPOSIXErrorDomain 53", PollScript(.fail(posix))),
            ("URLError", PollScript(.fail(URLError(.networkConnectionLost)))),
            ("some other error", PollScript(.fail(GitHubError.badResponse("x")))),
            ("CancellationError", PollScript(.fail(CancellationError()))),
            ("502 page", PollScript(.body(502, "<html>Bad Gateway</html>"))),
            ("503 json", PollScript(.body(503, "{\"error\":\"authorization_pending\"}"))),
            ("200 that is no JSON", PollScript(.body(200, "<html>captive portal</html>"))),
            ("200 JSON array", PollScript(.body(200, "[]"))),
            ("200 JSON with no token", PollScript(.body(200, "{}"))),
        ]
        for (name, transport) in failures {
            #expect(await flow(transport).poll(code()) == .transientFailure, "\(name)")
        }
    }

    @Test func aMissingClientIdIsFatalAndAsksNothing() async {
        let transport = PollScript()
        let outcome = await DeviceFlow(clientId: "", transport: transport, sleep: { _ in }).poll(code())
        #expect(outcome == .fatal("client_id"))
        #expect(transport.requestCount == 0)
    }

    /// `waitForApproval` is built on `poll`: a run of failures of every kind, then the token.
    @Test func waitForApprovalKeepsPollingThroughErrorsThatAreNotURLErrors() async throws {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 53)
        let transport = PollScript(
            .fail(posix), .fail(GitHubError.badResponse("x")), .body(500, "oops"), .body(200, "not json"),
            .json(["error": "authorization_pending"]), .fail(posix),
            .json(["access_token": "ghu_after_a_rough_patch"])
        )
        let pair = try await flow(transport).waitForApproval(code())
        #expect(pair.access == "ghu_after_a_rough_patch")
        #expect(transport.requestCount == 7)
    }

    /// With the network gone for good, the wait ends at the code's expiry, and not before.
    @Test func waitForApprovalOnlyEndsAtExpiryWhenEveryPollFails() async {
        let clock = TestClock()
        let transport = PollScript(.fail(NSError(domain: NSPOSIXErrorDomain, code: 53)))
        await #expect(throws: DeviceFlowError.expired) {
            try await flow(transport, clock: clock).waitForApproval(code(interval: 5, expiresIn: 60))
        }
        #expect(transport.requestCount == 12, "one request per 5 seconds for the whole minute")
        #expect(clock.sleeps.allSatisfy { $0 == 5 })
    }

    @Test func waitForApprovalStillThrowsTheVerdicts() async {
        await #expect(throws: DeviceFlowError.denied) { try await flow(PollScript(.json(["error": "access_denied"]))).waitForApproval(code()) }
        await #expect(throws: DeviceFlowError.expired) { try await flow(PollScript(.json(["error": "expired_token"]))).waitForApproval(code()) }
        await #expect(throws: DeviceFlowError.failed("incorrect_device_code")) {
            try await flow(PollScript(.json(["error": "incorrect_device_code"]))).waitForApproval(code())
        }
    }

    /// `slow_down` in `waitForApproval` still moves the pace the same way the old loop did: 5, then 5 + 5, then 10 each.
    @Test func waitForApprovalFollowsSlowDown() async throws {
        let clock = TestClock()
        let transport = PollScript(
            .json(["error": "authorization_pending"]),
            .json(["error": "slow_down", "interval": 10]),
            .json(["access_token": "ghu"])
        )
        _ = try await flow(transport, clock: clock).waitForApproval(code())
        #expect(clock.sleeps == [5, 5, 10])
    }

    @Test func aCancelledWaitStopsInsteadOfPollingOn() async {
        let transport = PollScript(.fail(CancellationError()))
        let task = Task {
            try await DeviceFlow(clientId: "c", transport: transport, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
                .waitForApproval(code(interval: 5, expiresIn: 3600))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct DeviceCodePageTests {
    @Test func theSwitchIsOnByDefault() {
        #expect(AppConfig.prefillDeviceCodeInURL == true)
    }

    @Test func theCodeIsAddedAsAQueryItem() throws {
        let url = code().browserURL(prefill: true)
        #expect(url.absoluteString == "https://github.com/login/device?user_code=WDJB-MJHT")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "user_code", value: "WDJB-MJHT")])
    }

    @Test func withTheSwitchOffThePageIsThePlainOne() {
        #expect(code().browserURL(prefill: false) == page)
    }

    @Test func aCodeIsEncodedAndNeverDuplicated() throws {
        let tricky = DeviceCode(deviceCode: "d", userCode: "A&B=C D", verificationURI: URL(string: "https://github.com/login/device?user_code=OLD&x=1")!,
                                interval: 5, expiresIn: 900)
        let url = tricky.browserURL(prefill: true)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "user_code" }.map(\.value) == ["A&B=C D"], "one user_code, round-trips through the query encoding")
        #expect(items.contains(URLQueryItem(name: "x", value: "1")))
        #expect(url.host == "github.com")
        #expect(url.scheme == "https")
    }

    /// `start()` keeps refusing a page that is not github.com, so the page opened can only ever be a github.com one.
    @Test func theOpenedPageStaysOnGitHub() async throws {
        let body = "{\"device_code\":\"d\",\"user_code\":\"WDJB-MJHT\",\"verification_uri\":\"https://github.com/login/device\"}"
        let started = try await flow(PollScript(.body(200, body))).start()
        let url = started.browserURL(prefill: true)
        #expect(url.host == "github.com" && url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil)
    }
}
