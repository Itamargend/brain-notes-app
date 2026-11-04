import BrainMerge
import CryptoKit
import Foundation

/// Why a path or text may not be committed. Mapped to Needs attention items.
public enum PolicyViolation: Error, Equatable, Sendable {
    case path(PathBlock)
    case invalidUTF8
    case secret(String)
    case clash(String)

    public var label: String {
        switch self {
        case let .path(b): return "blocked:" + b.rawValue
        case .invalidUTF8: return "blocked:invalid-utf8"
        case let .secret(kind): return "blocked:secret:" + kind
        case let .clash(other): return "case-clash:" + other
        }
    }
}

/// Local path policy: what the app shows and what it may commit. Wraps the BrainMerge rules
/// (`checkPath`, `PathIndex`) and adds the secret check and display rules.
public enum PathPolicy {
    /// Hidden from the UI and never downloaded.
    public static func isSyncable(_ path: String) -> Bool {
        checkPath(path) == nil || checkPath(path) == .tooLarge
    }

    /// Hidden from lists: dot folders, `_trash`, other `_` folders except `_inbox`, non-.md.
    public static func isVisible(_ path: String) -> Bool {
        guard isSyncable(path) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for seg in parts.dropLast() where seg.hasPrefix("_") && seg != "_inbox" { return false }
        return true
    }

    /// Check a local write before it enters the outbox: policy, size, UTF-8 is guaranteed by String.
    public static func check(path: String, content: String?, index: PathIndex? = nil) -> PolicyViolation? {
        if let b = checkPath(path, content: content) { return .path(b) }
        if let content, let kind = SecretScan.scan(content) { return .secret(kind) }
        if let index, let other = index.clash(path, strict: true) { return .clash(other) }
        return nil
    }

    /// Filename (without folder) from a note's first line: NFC, no separators or control characters.
    public static func fileName(fromFirstLine line: String) -> String {
        var title = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        for scalar in title.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            if "/\\:*?\"<>|".unicodeScalars.contains(scalar) { out.append("-"); continue }
            out.unicodeScalars.append(scalar)
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if out.count > 60 { out = String(out.prefix(60)).trimmingCharacters(in: .whitespaces) }
        if out.isEmpty { out = "Untitled" }
        return nfc(out)
    }
}

/// Small secret-pattern check. A hit blocks the commit (Needs attention); it never rewrites text.
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
}

/// Git blob SHA-1: sha1("blob <len>\0" + bytes), lowercase hex.
public enum GitBlob {
    public static func sha(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha(_ text: String) -> String { sha(Data(text.utf8)) }
}

/// SHA-256 hex of text, for outbox content hashes.
func contentHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
        guard owner == Self.allowedOwner, name == Self.allowedName else { throw GuardError.repoNotAllowed }
        self.owner = owner
        self.name = name
    }

    public static var allowed: RepoTarget { try! RepoTarget(owner: allowedOwner, name: allowedName) }

    public var id: String { "\(owner)_\(name)" }
    public var slug: String { "\(owner)/\(name)" }
}
