import Foundation
import Security

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.badResponse("not http") }
        return (data, http)
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
    /// ad-hoc build lacks: there the item lives in the login keychain, so "missing entitlement" and
    /// "not found" both fall through to it.
    private func run<T>(_ body: ([String: Any]) -> (OSStatus, T)) -> (OSStatus, T) {
        let first = body(query(dataProtection: true))
        #if os(macOS)
        if first.0 == errSecMissingEntitlement || first.0 == errSecItemNotFound {
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
        switch status {
        case errSecSuccess:
            guard let data else { return nil }
            return try? JSONDecoder().decode(TokenPair.self, from: data)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw TokenStoreError.unavailable
        default:
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

    public func clear() {
        SecItemDelete(query(dataProtection: true) as CFDictionary)
        #if os(macOS)
        SecItemDelete(query(dataProtection: false) as CFDictionary)
        #endif
    }
}

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
    /// Keeps a push going for the seconds after the phone locks, when the Keychain item cannot be read.
    private var cached: TokenPair?
    /// The rotated pair could not be stored. The old one is dead on GitHub, so this is the only copy.
    private var unsaved = false
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

    /// Sign-in finished: the store has a new pair.
    public func reload() {
        cached = nil
    }

    public func accessToken() async throws -> String {
        guard let pair = try current() else { throw GitHubError.unauthorized }
        if let exp = pair.accessExpiry, exp.timeIntervalSince(now()) < 60, pair.refresh != nil {
            return try await refresh(failed: pair.access)
        }
        return pair.access
    }

    public func refresh(failed: String) async throws -> String {
        // Someone already replaced the token that failed. In-flight requests retry with the new one.
        if let cur = try current(), !sameBytes(cur.access, failed) { return cur.access }
        if let inflight { return try await inflight.value.access }
        guard let refreshToken = try current()?.refresh else { throw GitHubError.unauthorized }
        // A refresh spends the old pair. While the Keychain is locked the new one could not be stored, so wait.
        _ = try store.load()
        let task = Task<TokenPair, Error> { [clientId, transport, now] in
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Form.encode(["client_id": clientId, "grant_type": "refresh_token", "refresh_token": refreshToken])
            let (data, http) = try await transport.send(req)
            if http.statusCode >= 500 { throw GitHubError.server(http.statusCode) }
            // GitHub answers HTTP 200 with an `error` field: any error is a failure.
            do { return try Self.parseTokenResponse(data, now: now()) } catch { throw GitHubError.unauthorized }
        }
        inflight = task
        defer { inflight = nil }
        refreshCount += 1
        let pair = try await task.value
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

    /// The answer as a JSON object, or nil for a server error or a body that is no JSON object (an error page).
    private func post(_ url: String, _ fields: [String: String]) async throws -> [String: Any]? {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Form.encode(fields)
        let (data, http) = try await transport.send(req)
        guard http.statusCode < 500 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func start() async throws -> DeviceCode {
        guard let o = try await post("https://github.com/login/device/code", ["client_id": clientId]) else {
            throw DeviceFlowError.failed("response")
        }
        if let e = o["error"] as? String { throw DeviceFlowError.failed(e) }
        guard let dc = o["device_code"] as? String, let uc = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)) else { throw DeviceFlowError.failed("response") }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURI: uri,
                          interval: (o["interval"] as? NSNumber)?.intValue ?? 5,
                          expiresIn: (o["expires_in"] as? NSNumber)?.intValue ?? 900)
    }

    /// Polls until approved, denied or expired. A dropped connection or a server error page while waiting does not
    /// end the sign-in: the user may be minutes into approving on another device, and the code's expiry bounds the wait.
    public func waitForApproval(_ code: DeviceCode) async throws -> TokenPair {
        var interval = code.interval
        let deadline = now().addingTimeInterval(Double(code.expiresIn))
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
                case "slow_down": interval = (o["interval"] as? NSNumber)?.intValue ?? (interval + 5)
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
