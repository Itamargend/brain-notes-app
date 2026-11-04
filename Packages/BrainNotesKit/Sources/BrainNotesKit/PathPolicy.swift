import BrainMerge
import CryptoKit
import Foundation

/// Why a path or text may not be committed. Mapped to Needs attention items.
public enum PolicyViolation: Error, Equatable, Sendable {
    case path(PathBlock)
    case secret(String)
    case clash(String)

    /// The reason string stored in Needs attention.
    public var label: String {
        switch self {
        case let .path(b): return "blocked:" + b.rawValue
        case let .secret(kind): return "blocked:secret:" + kind
        case .clash: return "case-clash"
        }
    }
}

/// Local path policy: what the app stores, shows and may commit. Wraps the BrainMerge rules
/// (`checkPath`, `PathIndex`) and adds the secret check and display rules.
public enum PathPolicy {
    /// Stored on the device. Anything else (dot folders, `private/`, `_capture/`, non-`.md`) is never downloaded.
    public static func isSyncable(_ path: String) -> Bool {
        checkPath(path) == nil
    }

    /// Shown in lists and search: syncable, and no folder starting with `_` except a top-level `_inbox`.
    public static func isVisible(_ path: String) -> Bool {
        guard isSyncable(path) else { return false }
        let folders = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        for (i, seg) in folders.enumerated() where seg.utf8.first == UInt8(ascii: "_") {
            if !(i == 0 && sameBytes(String(seg), inboxFolder)) { return false }
        }
        return true
    }

    public static let inboxFolder = "_inbox"

    /// Check a local write: policy and size, then secrets, then clashes against the tree.
    public static func check(path: String, content: String?, index: PathIndex? = nil) -> PolicyViolation? {
        if let b = checkPath(path, content: content) { return .path(b) }
        if let content, let kind = SecretScan.scan(content) { return .secret(kind) }
        if let index, let other = index.clash(path, strict: true) { return .clash(other) }
        return nil
    }

    /// File name without folder or extension, from a note's first line: NFC, no separators,
    /// control or invisible characters, at most 60 characters, never empty.
    public static func fileName(fromFirstLine line: String) -> String {
        var title = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.utf8.first == UInt8(ascii: "#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            if "/\\:*?\"<>|".unicodeScalars.contains(scalar) { out.append("-"); continue }
            out.append(scalar)
        }
        var name = String(out).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces)) }
        return nfc(name.isEmpty ? "Untitled" : name)
    }
}

/// Small secret-pattern check. API commits skip the repo's hooks, so a hit blocks the commit
/// (Needs attention); it never rewrites text.
public enum SecretScan {
    private static let patterns: [(String, NSRegularExpression)] = {
        let defs: [(String, String)] = [
            ("github-token", #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
            ("github-pat", #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#),
            ("aws-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
            ("private-key", #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#),
            ("api-key", #"(?i)\b(?:api[_-]?key|secret[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*["']?[A-Za-z0-9_\-+/=]{20,}"#),
        ]
        return defs.compactMap { name, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (name, $0) }
        }
    }()

    /// The name of the first matching pattern, or nil.
    public static func scan(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for (name, re) in patterns where re.firstMatch(in: text, options: [], range: range) != nil {
            return name
        }
        return nil
    }

    /// The first pattern with a match in `text` that `base` does not have. A secret that is already
    /// on GitHub must not make its note uneditable; only a newly added one blocks the commit.
    public static func scanAdded(_ text: String, comparedTo base: String?) -> String? {
        guard let base else { return scan(text) }
        for (name, re) in patterns {
            let found = matches(re, in: text)
            if found.isEmpty { continue }
            let known = matches(re, in: base)
            if found.contains(where: { hit in !known.contains(where: { sameBytes($0, hit) }) }) { return name }
        }
        return nil
    }

    private static func matches(_ re: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

/// Git blob SHA-1: sha1("blob <len>\0" + bytes), lowercase hex.
public enum GitBlob {
    public static func sha(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return hexString(h.finalize())
    }

    public static func sha(_ text: String) -> String { sha(Data(text.utf8)) }
}

/// SHA-256 hex of text, for outbox content hashes.
func contentHash(_ text: String) -> String {
    hexString(SHA256.hash(data: Data(text.utf8)))
}

/// Repo identity and the hard guard: the app talks to exactly one repository.
public struct RepoTarget: Sendable, Equatable {
    public static let allowedOwner = "Itamargend"
    public static let allowedName = "brain-notes-test"

    public enum GuardError: Error, Equatable, Sendable { case repoNotAllowed }

    public let owner: String
    public let name: String

    /// Throws for anything but exactly `Itamargend/brain-notes-test`.
    public init(owner: String, name: String) throws {
        guard sameBytes(owner, Self.allowedOwner), sameBytes(name, Self.allowedName) else { throw GuardError.repoNotAllowed }
        self.owner = owner
        self.name = name
    }

    public static var allowed: RepoTarget {
        // The two constants above satisfy the guard by definition.
        try! RepoTarget(owner: allowedOwner, name: allowedName)
    }

    public var id: String { "\(owner)_\(name)" }
    public var slug: String { "\(owner)/\(name)" }

    /// The final check on every request: API host, https, and either this repo's path or GraphQL
    /// (whose query names the repo through variables set by the client from this target).
    public func guardURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "api.github.com", url.user == nil else { throw GuardError.repoNotAllowed }
        let components = url.pathComponents
        guard !components.contains("..") else { throw GuardError.repoNotAllowed }
        if components == ["/", "graphql"] { return }
        guard components.count >= 4, components[0] == "/", components[1] == "repos",
              sameBytes(components[2], owner), sameBytes(components[3], name) else { throw GuardError.repoNotAllowed }
    }
}
