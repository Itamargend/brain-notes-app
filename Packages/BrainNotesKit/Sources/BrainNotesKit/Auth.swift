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

public protocol TokenStore: Sendable {
    func load() -> TokenPair?
    func save(_ pair: TokenPair) throws
    func clear()
}

/// Keychain storage, this device only, readable only while unlocked. Tokens are never written anywhere else.
public struct KeychainTokenStore: TokenStore {
    public static let service = "com.itamargendelman.brainnotes.github"
    private let account: String

    public init(account: String = "default") { self.account = account }

    private var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public func load() -> TokenPair? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(TokenPair.self, from: data)
    }

    public func save(_ pair: TokenPair) throws {
        let data = try JSONEncoder().encode(pair)
        SecItemDelete(baseQuery as CFDictionary)
        var q = baseQuery
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

/// For tests and demo mode. Never persists.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: TokenPair?
    public init(_ pair: TokenPair? = nil) { self.pair = pair }
    public func load() -> TokenPair? { lock.withLock { pair } }
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
    private var inflight: Task<String, Error>?
    public private(set) var refreshCount = 0

    public init(clientId: String, transport: HTTPTransport, store: TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientId = clientId; self.transport = transport; self.store = store; self.now = now
    }

    public func accessToken() async throws -> String {
        guard let pair = store.load() else { throw GitHubError.unauthorized }
        if let exp = pair.accessExpiry, exp.timeIntervalSince(now()) < 60, pair.refresh != nil {
            return try await refresh(failed: pair.access)
        }
        return pair.access
    }

    public func refresh(failed: String) async throws -> String {
        // Someone already replaced the token that failed.
        if let cur = store.load(), cur.access != failed { return cur.access }
        if let inflight { return try await inflight.value }
        guard let refreshToken = store.load()?.refresh else { throw GitHubError.unauthorized }
        let task = Task<String, Error> { [clientId, transport, store, now] in
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Form.encode(["client_id": clientId, "grant_type": "refresh_token", "refresh_token": refreshToken])
            let (data, _) = try await transport.send(req)
            // GitHub answers HTTP 200 with an `error` field: any error is a failure.
            guard let pair = try? Self.parseTokenResponse(data, now: now()) else { throw GitHubError.unauthorized }
            try store.save(pair)  // stored before use
            return pair.access
        }
        inflight = task
        defer { inflight = nil }
        refreshCount += 1
        do { return try await task.value } catch {
            if let e = error as? GitHubError, e == .unauthorized { throw e }
            throw error
        }
    }

    static func parseTokenResponse(_ data: Data, now: Date) throws -> TokenPair {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.badResponse("token") }
        if obj["error"] != nil { throw GitHubError.unauthorized }
        guard let access = obj["access_token"] as? String, !access.isEmpty else { throw GitHubError.unauthorized }
        func seconds(_ k: String) -> Date? { (obj[k] as? Double).map { now.addingTimeInterval($0) } }
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

    private func post(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Form.encode(fields)
        let (data, _) = try await transport.send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeviceFlowError.failed("response") }
        return obj
    }

    public func start() async throws -> DeviceCode {
        let o = try await post("https://github.com/login/device/code", ["client_id": clientId])
        if let e = o["error"] as? String { throw DeviceFlowError.failed(e) }
        guard let dc = o["device_code"] as? String, let uc = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)) else { throw DeviceFlowError.failed("response") }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURI: uri,
                          interval: (o["interval"] as? Int) ?? 5, expiresIn: (o["expires_in"] as? Int) ?? 900)
    }

    /// Polls until approved, denied or expired.
    public func waitForApproval(_ code: DeviceCode) async throws -> TokenPair {
        var interval = code.interval
        let deadline = now().addingTimeInterval(Double(code.expiresIn))
        while now() < deadline {
            try await sleep(.seconds(interval))
            let o = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientId, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let e = o["error"] as? String {
                switch e {
                case "authorization_pending": continue
                case "slow_down": interval += 5
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
