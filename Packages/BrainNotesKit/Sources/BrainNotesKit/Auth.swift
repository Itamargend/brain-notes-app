import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// As `send`, for a body that may be large (the first-sync tarball). Throws `RepoTooLarge(.download)` as soon as the
    /// body is known to pass `maxBytes`: from its Content-Length before any of it is read, or as it arrives.
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    /// A transport that only hands over whole bodies (the tests' fakes) makes the same two checks once the body is here.
    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await send(request)
        try DownloadLimit.check(declared: DownloadLimit.contentLength(http), maxBytes: maxBytes)
        guard data.count <= maxBytes else { throw RepoTooLarge(.download, max: maxBytes) }
        return (data, http)
    }
}

/// The most an answer that is not a download may be, so that a broken or hostile reply cannot fill memory. Downloads
/// have caps of their own: the tarball (`FirstSyncLimits.maxDownloadBytes`) and a blob (`GitHubHTTPClient.blob`).
public enum ReplyLimit {
    /// A JSON answer from GitHub's REST or GraphQL API. The largest real ones, a recursive tree listing (GitHub caps
    /// those at 7 MB) and a comparison with its patches, fit several times over.
    public static let json = 32 << 20
    /// An account or installation-discovery answer (`/user`, `/user/installations`, `/user/installations/{id}/repositories`):
    /// at most 100 items per page.
    public static let discovery = 4 << 20
    /// A sign-in or token answer from github.com: a few hundred bytes.
    public static let oauth = 64 << 10
}

/// The download cap's checks, shared by every transport.
enum DownloadLimit {
    /// The Content-Length header, or -1 when there is none (a chunked response, as GitHub's tarballs often are).
    static func contentLength(_ http: HTTPURLResponse) -> Int64 {
        http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? -1
    }

    static func check(declared: Int64, maxBytes: Int) throws {
        if declared > Int64(maxBytes) { throw RepoTooLarge(.download, max: maxBytes) }
    }
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.badResponse("not http") }
        return (data, http)
    }

    /// Reads the body as it arrives, so a download past `maxBytes` stops there instead of filling memory first.
    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Darwin)
        let (bytes, response) = try await self.bytes(for: request)
        var data = Data()
        do {
            guard let http = response as? HTTPURLResponse else { throw GitHubError.badResponse("not http") }
            try DownloadLimit.check(declared: http.expectedContentLength, maxBytes: maxBytes)
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maxBytes else { throw RepoTooLarge(.download, max: maxBytes) }
                data.append(byte)
            }
            return (data, http)
        } catch {
            // Stop the transfer now, not when the stream is let go.
            bytes.task.cancel()
            throw error
        }
        #else
        // swift-corelibs-foundation has no byte stream: the whole body, then the same checks.
        let (data, http) = try await send(request)
        try DownloadLimit.check(declared: DownloadLimit.contentLength(http), maxBytes: maxBytes)
        guard data.count <= maxBytes else { throw RepoTooLarge(.download, max: maxBytes) }
        return (data, http)
        #endif
    }
}

public struct TokenPair: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String?
    public var accessExpiry: Date?
    public var refreshExpiry: Date?
    public init(access: String, refresh: String? = nil, accessExpiry: Date? = nil, refreshExpiry: Date? = nil) {
        self.access = access; self.refresh = refresh; self.accessExpiry = accessExpiry; self.refreshExpiry = refreshExpiry
    }
}

public enum TokenStoreError: Error, Equatable, Sendable {
    /// The Keychain item exists but cannot be read now (device locked). This is not "signed out".
    case unavailable
    case failed(Int32)
}

public protocol TokenStore: Sendable {
    /// nil means there is no token. Throws when one may exist but cannot be read right now.
    func load() throws -> TokenPair?
    func save(_ pair: TokenPair) throws
    func clear()
}

extension TokenStore {
    /// True when a token pair is stored, or may be but cannot be read right now (a locked device). Any other failure
    /// counts as no token: a store that fails for another reason must not leave the app looking signed in.
    public func holdsTokens() -> Bool {
        do {
            return try load() != nil
        } catch {
            return TokenStoreError.mayHideATokenPair(error)
        }
    }
}

extension TokenStoreError {
    /// Whether a failed read may still hide a stored pair: only `unavailable`, the Keychain's "interaction not
    /// allowed" while the device is locked. Every other error means there is no pair this app can use.
    public static func mayHideATokenPair(_ error: Error) -> Bool {
        (error as? TokenStoreError) == .unavailable
    }
}

#if canImport(Security)
/// Keychain storage, this device only, readable only while unlocked. Tokens are never written anywhere else.
public struct KeychainTokenStore: TokenStore {
    public static let service = "com.itamargendelman.brainnotes.github"
    private let account: String

    public init(account: String = "default") { self.account = account }

    private func query(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// iOS always has the data protection keychain. A Mac build needs an entitlement for it, which a local
    /// ad-hoc build lacks: only there does the item live in the login keychain (`KeychainRules`).
    private func run<T>(_ body: ([String: Any]) -> (OSStatus, T)) -> (OSStatus, T) {
        let first = body(query(dataProtection: true))
        #if os(macOS)
        if KeychainRules.usesLoginKeychain(afterDataProtectionStatus: first.0) {
            return body(query(dataProtection: false))
        }
        #endif
        return first
    }

    public func load() throws -> TokenPair? {
        let (status, data): (OSStatus, Data?) = run { base in
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            return (status, out as? Data)
        }
        switch KeychainRules.read(status) {
        case .found:
            guard let data else { return nil }
            return try? JSONDecoder().decode(TokenPair.self, from: data)
        case .none:
            return nil
        case .unavailable:
            throw TokenStoreError.unavailable
        case let .failed(status):
            throw TokenStoreError.failed(status)
        }
    }

    /// Update first, so a kill between the two steps of a delete-and-add cannot lose a pair whose
    /// predecessor is already dead on GitHub (refresh tokens are single use).
    public func save(_ pair: TokenPair) throws {
        let data = try JSONEncoder().encode(pair)
        let (status, _): (OSStatus, Void) = run { base in
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            var status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                var add = base
                add.merge(attrs) { $1 }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return (status, ())
        }
        guard status == errSecSuccess else {
            if status == errSecInteractionNotAllowed { throw TokenStoreError.unavailable }
            throw TokenStoreError.failed(status)
        }
    }

    /// Both keychains on a Mac: a sign-out removes an item an earlier ad-hoc build left in the login keychain, or one
    /// something else planted there, even though a team-signed build never reads it.
    public func clear() {
        SecItemDelete(query(dataProtection: true) as CFDictionary)
        #if os(macOS)
        SecItemDelete(query(dataProtection: false) as CFDictionary)
        #endif
    }
}

/// What the Keychain's answers mean, apart from the Keychain itself, so tests can check the decisions without
/// touching a real Keychain.
enum KeychainRules {
    /// Whether a Mac build goes on to the file-based login keychain after this answer from the data protection
    /// keychain. Only when it cannot use the data protection keychain at all: an ad-hoc or unsigned build, which lacks
    /// the entitlement. "Not found" is an answer from the data protection keychain, not a reason to look elsewhere: any
    /// program running as this user can leave an item under this service in the login keychain, for instance right
    /// after Sign out and wipe, and a team-signed build must never sign in with it.
    ///
    /// A team-signed build that finds no item of its own does not move one over from the login keychain either: that
    /// item can't be told apart from a planted one, so it is ignored, and the user signs in once more. `clear` still
    /// deletes it.
    static func usesLoginKeychain(afterDataProtectionStatus status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
    }

    enum Read: Equatable {
        case found
        case none
        /// The item may be there but cannot be read now (device locked). This is not "signed out".
        case unavailable
        case failed(OSStatus)
    }

    /// What a read's status means.
    static func read(_ status: OSStatus) -> Read {
        switch status {
        case errSecSuccess: return .found
        case errSecItemNotFound: return .none
        case errSecInteractionNotAllowed: return .unavailable
        default: return .failed(status)
        }
    }
}
#endif

/// For tests and demo mode. Never persists.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: TokenPair?
    public init(_ pair: TokenPair? = nil) { self.pair = pair }
    public func load() throws -> TokenPair? { lock.withLock { pair } }
    public func save(_ pair: TokenPair) throws { lock.withLock { self.pair = pair } }
    public func clear() { lock.withLock { pair = nil } }
}

public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
    /// Called after a 401 with the token that failed. Returns a fresh token or throws `.unauthorized`.
    func refresh(failed: String) async throws -> String
}

/// Single refresher. No client secret anywhere: device flow and refresh use the client id only.
public actor TokenManager: TokenProvider {
    private let clientId: String
    private let transport: HTTPTransport
    private let store: TokenStore
    private let now: @Sendable () -> Date
    private var inflight: Task<TokenPair, Error>?
    /// Keeps a push going for the seconds after the phone locks, when the Keychain item cannot be read. Let go once
    /// the background flush is over (`forgetCachedPair`).
    private var cached: TokenPair?
    /// The rotated pair could not be stored. The old one is dead on GitHub, so this is the only copy.
    private var unsaved = false
    /// Bumped by every sign-out and sign-in. A refresh that started in an older generation must not store
    /// or hand out its pair: the user signed out (or in again) while it was on the wire.
    private var generation = 0
    public private(set) var refreshCount = 0

    public init(clientId: String, transport: HTTPTransport, store: TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientId = clientId; self.transport = transport; self.store = store; self.now = now
    }

    private func current() throws -> TokenPair? {
        if unsaved, let cached, (try? store.save(cached)) != nil { unsaved = false }
        if let cached { return cached }
        cached = try store.load()
        return cached
    }

    /// Sign-in finished: the store has a new pair. Sign-out: the store is empty.
    /// Either way a refresh still on the wire belongs to the old sign-in: it is no longer shared with new
    /// callers, and its pair is dropped when it comes back.
    public func reload() {
        cached = nil
        unsaved = false
        inflight?.cancel()
        inflight = nil
        generation += 1
    }

    /// Lets go of the pair held in memory once the store has it, for when no request is coming for a while: the app
    /// left the screen and its background flush is over. The next request reads the store again. A pair the store has
    /// not taken yet is saved first; if it still can't be, it stays, since refresh tokens are single use and memory then
    /// holds the only copy. Not a sign-out: a refresh on the wire still completes. Returns whether no pair is held now.
    @discardableResult
    public func forgetCachedPair() -> Bool {
        if unsaved, let cached, (try? store.save(cached)) != nil { unsaved = false }
        guard !unsaved else { return false }
        cached = nil
        return true
    }

    /// Whether a pair is held in memory. For tests.
    var holdsPairInMemory: Bool { cached != nil }

    public func accessToken() async throws -> String {
        guard let pair = try current() else { throw GitHubError.unauthorized }
        if let exp = pair.accessExpiry, exp.timeIntervalSince(now()) < 60, pair.refresh != nil {
            return try await refresh(failed: pair.access)
        }
        return pair.access
    }

    public func refresh(failed: String) async throws -> String {
        guard !clientId.isEmpty else { throw GitHubError.unauthorized }
        // Someone already replaced the token that failed. In-flight requests retry with the new one.
        if let cur = try current(), !sameBytes(cur.access, failed) { return cur.access }
        let startedIn = generation
        if let inflight {
            let pair: TokenPair
            do {
                pair = try await inflight.value
            } catch {
                guard startedIn == generation else { throw GitHubError.unauthorized }
                throw error
            }
            // Signed out, or signed in again, while waiting: this pair is not ours to hand out.
            guard startedIn == generation else { throw GitHubError.unauthorized }
            return pair.access
        }
        guard let refreshToken = try current()?.refresh else { throw GitHubError.unauthorized }
        // A refresh spends the old pair. While the Keychain is locked the new one could not be stored, so wait.
        _ = try store.load()
        let task = Task<TokenPair, Error> { [clientId, transport, now] in
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Form.encode(["client_id": clientId, "grant_type": "refresh_token", "refresh_token": refreshToken])
            let data: Data, http: HTTPURLResponse
            do {
                (data, http) = try await transport.send(req, maxBytes: ReplyLimit.oauth)
            } catch is RepoTooLarge {
                // No token answer is this long: a broken reply, not a verdict on the sign-in.
                throw GitHubError.badResponse("token")
            }
            if http.statusCode >= 500 { throw GitHubError.server(http.statusCode) }
            // GitHub answers HTTP 200 with an `error` field: any error is a failure.
            do { return try Self.parseTokenResponse(data, now: now()) } catch { throw GitHubError.unauthorized }
        }
        inflight = task
        // After a reload, `inflight` is no longer this task (reload cleared it, a newer refresh may have set it).
        defer { if startedIn == generation { inflight = nil } }
        refreshCount += 1
        let pair: TokenPair
        do {
            pair = try await task.value
        } catch {
            guard startedIn == generation else { throw GitHubError.unauthorized }
            throw error
        }
        // Signed out, or signed in again, while this was on the wire: never store this pair or return it.
        guard startedIn == generation else { throw GitHubError.unauthorized }
        cached = pair
        // Stored before anyone uses it. If that fails, memory holds the only copy until a save works.
        unsaved = (try? store.save(pair)) == nil
        return pair.access
    }

    static func parseTokenResponse(_ data: Data, now: Date) throws -> TokenPair {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.badResponse("token") }
        if obj["error"] != nil { throw GitHubError.unauthorized }
        guard let access = obj["access_token"] as? String, !access.isEmpty else { throw GitHubError.unauthorized }
        func seconds(_ k: String) -> Date? { (obj[k] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) } }
        return TokenPair(access: access, refresh: obj["refresh_token"] as? String,
                         accessExpiry: seconds("expires_in"), refreshExpiry: seconds("refresh_token_expires_in"))
    }
}

enum Form {
    static func encode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(s.utf8)
    }
}

public struct DeviceCode: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var interval: Int
    public var expiresIn: Int
    public init(deviceCode: String, userCode: String, verificationURI: URL, interval: Int, expiresIn: Int) {
        self.deviceCode = deviceCode; self.userCode = userCode; self.verificationURI = verificationURI
        self.interval = interval; self.expiresIn = expiresIn
    }
}

public enum DeviceFlowError: Error, Equatable, Sendable { case expired, denied, failed(String) }

/// GitHub device flow with the client id only.
public struct DeviceFlow: Sendable {
    let clientId: String
    let transport: HTTPTransport
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date

    public init(clientId: String, transport: HTTPTransport,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientId = clientId; self.transport = transport; self.sleep = sleep; self.now = now
    }

    /// The answer as a JSON object, or nil for a server error or a body that is no JSON object (an error page), or one
    /// longer than any sign-in answer is (`ReplyLimit.oauth`).
    private func post(_ url: String, _ fields: [String: String]) async throws -> [String: Any]? {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Form.encode(fields)
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(req, maxBytes: ReplyLimit.oauth)
        } catch is RepoTooLarge {
            return nil
        }
        guard http.statusCode < 500 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func start() async throws -> DeviceCode {
        guard !clientId.isEmpty else { throw DeviceFlowError.failed("client_id") }
        guard let o = try await post("https://github.com/login/device/code", ["client_id": clientId]) else {
            throw DeviceFlowError.failed("response")
        }
        if let e = o["error"] as? String { throw DeviceFlowError.failed(e) }
        guard let dc = o["device_code"] as? String, let uc = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)) else { throw DeviceFlowError.failed("response") }
        // The sign-in screen opens this page and calls it github.com: anything else is refused, never opened.
        guard uri.scheme == "https",
              uri.host == "github.com",
              uri.user == nil,
              uri.password == nil,
              uri.port == nil else {
            throw DeviceFlowError.failed("verification_uri")
        }
        let interval = max(5, (o["interval"] as? NSNumber)?.intValue ?? 5)
        let expiresIn = min(max(1, (o["expires_in"] as? NSNumber)?.intValue ?? 900), 3600)
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURI: uri,
                          interval: interval,
                          expiresIn: expiresIn)
    }

    /// Polls until approved, denied or expired. A dropped connection or a server error page while waiting does not
    /// end the sign-in: the user may be minutes into approving on another device, and the code's expiry bounds the wait.
    public func waitForApproval(_ code: DeviceCode) async throws -> TokenPair {
        guard !clientId.isEmpty else { throw DeviceFlowError.failed("client_id") }
        var interval = max(5, code.interval)
        let deadline = now().addingTimeInterval(Double(min(max(0, code.expiresIn), 3600)))
        while now() < deadline {
            try await sleep(.seconds(interval))
            let answer: [String: Any]?
            do {
                answer = try await post("https://github.com/login/oauth/access_token", [
                    "client_id": clientId, "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch is URLError {
                continue
            }
            guard let o = answer else { continue }
            if let e = o["error"] as? String {
                switch e {
                case "authorization_pending": continue
                case "slow_down":
                    let echoed = (o["interval"] as? NSNumber)?.intValue ?? 0
                    interval = max(interval + 5, echoed)
                case "expired_token": throw DeviceFlowError.expired
                case "access_denied": throw DeviceFlowError.denied
                default: throw DeviceFlowError.failed(e)
                }
            } else {
                let data = try JSONSerialization.data(withJSONObject: o)
                return try TokenManager.parseTokenResponse(data, now: now())
            }
        }
        throw DeviceFlowError.expired
    }
}
