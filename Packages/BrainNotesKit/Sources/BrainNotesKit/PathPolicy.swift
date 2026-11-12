import BrainMerge
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
    ///
    /// The inbox is matched by clash key, not bytes: new notes, captures and conflict copies take the spelling
    /// GitHub already has (`PathIndex.respell`), so a repo with `_Inbox/` gets them there, and they must show.
    public static func isVisible(_ path: String) -> Bool {
        guard isSyncable(path) else { return false }
        let folders = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        for (i, seg) in folders.enumerated() where seg.utf8.first == UInt8(ascii: "_") {
            if !(i == 0 && isInbox(String(seg))) { return false }
        }
        return true
    }

    public static let inboxFolder = "_inbox"

    /// `folder` is the inbox in any spelling (`_inbox`, `_Inbox`, `_INBOX`).
    public static func isInbox(_ folder: String) -> Bool { sameBytes(foldKey(folder), foldKey(inboxFolder)) }

    /// `path` is in the inbox, or in a folder under it, whatever the inbox's spelling. Root files are not.
    public static func isInInbox(_ path: String) -> Bool {
        guard let slash = path.utf8.firstIndex(of: UInt8(ascii: "/")) else { return false }
        return isInbox(String(path[..<slash]))
    }

    /// Check a local write: policy and size, then secrets, then clashes against the tree.
    public static func check(path: String, content: String?, index: PathIndex? = nil) -> PolicyViolation? {
        if let b = checkPath(path, content: content) { return .path(b) }
        if let content, let kind = SecretScan.scan(content) { return .secret(kind) }
        if let index, let other = index.clash(path, strict: true) { return .clash(other) }
        return nil
    }

    /// File name without folder or extension, from a note's first line, as a reader sees that line: no Markdown
    /// marks, so the bar's `- [ ] ` or `**` can't end up in the name. NFC, no separators, control or invisible
    /// characters, at most 60 characters, never empty.
    public static func fileName(fromFirstLine line: String) -> String {
        var title = MarkdownInline.plainText(line.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.utf8.first == UInt8(ascii: "#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Marks with nothing in them yet, as Bold leaves an empty note.
        if title.utf8.allSatisfy({ "*_~`".utf8.contains($0) }) { title = "" }
        let name = cleanName(title)
        return nfc(name.isEmpty ? "Untitled" : name)
    }

    /// A folder's name from what was typed: cleaned as a file name is, or nil if nothing is left.
    public static func folderName(fromTyped typed: String) -> String? {
        let name = cleanName(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        return name.isEmpty ? nil : nfc(name)
    }

    /// May a folder live at this path? It must be able to hold a note that syncs and shows. A name ending in `.md` could
    /// never become a note's folder: GitHub could later deliver a note at exactly that path.
    public static func canHoldNotes(folder path: String) -> Bool {
        let probe = path + "/x.md"
        guard isVisible(probe), FileStore.nameFits(probe) else { return false }
        return !(path.split(separator: "/").last.map { $0.lowercased().hasSuffix(".md") } ?? true)
    }

    private static func cleanName(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            if "/\\:*?\"<>|".unicodeScalars.contains(scalar) { out.append("-"); continue }
            out.append(scalar)
        }
        var name = String(out).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces)) }
        return name
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
        var h = SHA1Hasher()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.hex()
    }

    public static func sha(_ text: String) -> String { sha(Data(text.utf8)) }
}

/// SHA-256 hex of text, for outbox content hashes.
func contentHash(_ text: String) -> String {
    sha256Hex(Data(text.utf8))
}

/// Repo identity and the hard per-request URL guard: a session talks to at most one validated private repository,
/// the one the signed-in user picked from an installation of the Brain Notes GitHub App.
public struct RepoTarget: Sendable, Equatable {
    public enum GuardError: Error, Equatable, Sendable {
        case repoNotAllowed
        case publicRepo
    }

    /// Plain-English explanation shown whenever a repository is not private.
    public static let publicRepoMessage =
        "This notes repository is public, so anyone on the internet can read it. Brain Notes only opens private ones. Make it private on GitHub, then try again."

    public let repoId: Int64
    public let owner: String
    public let name: String
    public let defaultBranch: String

    private init(validated repoId: Int64, owner: String, name: String, defaultBranch: String) {
        self.repoId = repoId
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
    }

    /// Synthetic target for offline demo mode, which uses an in-process fake and never reaches the network.
    public static let demoRepo = RepoTarget(validated: 1, owner: "sample", name: "sample-notes", defaultBranch: "main")

    /// Validates numeric repository ID, owner, repository name, default branch, and privacy.
    public init(repoId: Int64, owner: String, name: String, defaultBranch: String = "main", isPrivate: Bool = true) throws {
        guard repoId > 0,
              Self.isValidOwner(owner),
              Self.isValidRepoName(name),
              Self.isValidBranch(defaultBranch) else {
            throw GuardError.repoNotAllowed
        }
        guard isPrivate else {
            throw GuardError.publicRepo
        }
        self.init(validated: repoId, owner: owner, name: name, defaultBranch: defaultBranch)
    }

    /// Unique local folder key under `Brain/<id>`: strictly positive numeric repo ID, so two users or two repos
    /// (even after rename or owner transfer) never share a folder.
    public var id: String { String(repoId) }
    public var slug: String { "\(owner)/\(name)" }

    /// Exact byte match for `^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$`.
    public static func isValidOwner(_ owner: String) -> Bool {
        let bytes = Array(owner.utf8)
        guard !bytes.isEmpty, bytes.count <= 39 else { return false }
        guard isASCIIAlphaNumeric(bytes[0]), isASCIIAlphaNumeric(bytes[bytes.count - 1]) else { return false }
        for i in 0..<bytes.count {
            let b = bytes[i]
            if isASCIIAlphaNumeric(b) { continue }
            if b == 0x2D {  // '-'
                guard i + 1 < bytes.count, isASCIIAlphaNumeric(bytes[i + 1]) else { return false }
                continue
            }
            return false
        }
        return true
    }

    /// Exact byte match for `^[A-Za-z0-9._-]{1,100}$`, refusing `.`, `..`, and any `.git` suffix.
    public static func isValidRepoName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 100 else { return false }
        if sameBytes(name, ".") || sameBytes(name, "..") { return false }
        for b in bytes {
            if isASCIIAlphaNumeric(b) || b == 0x2E || b == 0x5F || b == 0x2D { continue }
            return false
        }
        if bytes.count >= 4 {
            let tail = bytes.suffix(4).map { ($0 >= 0x41 && $0 <= 0x5A) ? ($0 + 0x20) : $0 }
            if tail == [0x2E, 0x67, 0x69, 0x74] { return false }  // ".git"
        }
        return true
    }

    /// Validates a Git branch name under `git check-ref-format --branch` rules plus URL safety (no `%` or `#`).
    public static func isValidBranch(_ branch: String) -> Bool {
        let bytes = Array(branch.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { return false }
        if sameBytes(branch, "@") { return false }
        if bytes.first == 0x2D || bytes.first == 0x2F || bytes.last == 0x2F || bytes.last == 0x2E { return false }
        for i in 0..<bytes.count {
            let b = bytes[i]
            // Printable ASCII only (no control chars, DEL, space, or non-ASCII), and no git/URL forbidden marks.
            if b <= 0x20 || b >= 0x7F { return false }
            switch b {
            case 0x7E, 0x5E, 0x3A, 0x3F, 0x2A, 0x5B, 0x5C, 0x25, 0x23:  // ~ ^ : ? * [ \ % #
                return false
            case 0x2E:  // '.'
                if i + 1 < bytes.count, bytes[i + 1] == 0x2E { return false }  // ".."
            case 0x2F:  // '/'
                if i + 1 < bytes.count, bytes[i + 1] == 0x2F { return false }  // "//"
            case 0x40:  // '@'
                if i + 1 < bytes.count, bytes[i + 1] == 0x7B { return false }  // "@{"
            default:
                break
            }
        }
        for segment in branch.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty { return false }
            if segment.utf8.first == 0x2E { return false }  // leading '.'
            if segment.lowercased().hasSuffix(".lock") { return false }
        }
        return true
    }

    /// Exact byte match for `^[a-z0-9-]{1,100}$` for `BN_GITHUB_APP_SLUG`.
    public static func isValidAppSlug(_ slug: String) -> Bool {
        let bytes = Array(slug.utf8)
        guard !bytes.isEmpty, bytes.count <= 100 else { return false }
        for b in bytes {
            let lower = b >= 0x61 && b <= 0x7A
            let digit = b >= 0x30 && b <= 0x39
            if lower || digit || b == 0x2D { continue }
            return false
        }
        return true
    }

    private static func isASCIIAlphaNumeric(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    /// The final check on every request: API host, https, no credentials/port/fragment, no dot or encoded-slash
    /// tricks, and either this repo's exact path or GraphQL (whose query names the repo through variables set by the
    /// client from this target). Any other repository or endpoint is refused.
    public func guardURL(_ url: URL) throws {
        guard url.scheme == "https",
              url.host == "api.github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              Self.hasSafeRawPath(url) else {
            throw GuardError.repoNotAllowed
        }
        let components = url.pathComponents
        guard !components.contains(".."), !components.contains(".") else { throw GuardError.repoNotAllowed }
        if components == ["/", "graphql"] { return }
        guard components.count >= 4, components[0] == "/", components[1] == "repos",
              sameBytes(components[2], owner), sameBytes(components[3], name) else { throw GuardError.repoNotAllowed }
    }

    static func hasSafeRawPath(_ url: URL) -> Bool {
        let full = url.absoluteString
        let prefix = "https://api.github.com/"
        guard full.hasPrefix(prefix) else { return false }
        let afterHost = Substring(full.dropFirst(prefix.count))
        let rawPath = afterHost.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !rawPath.isEmpty else { return false }
        let lower = rawPath.lowercased()
        if lower.contains("%2f") || lower.contains("%5c") || lower.contains("%00") || lower.contains("\\") {
            return false
        }
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        // Allow no empty `//` segments (and no trailing slash).
        for seg in segments {
            if seg.isEmpty { return false }
            let s = seg.lowercased()
            if s == "." || s == ".." || s == "%2e" || s == "%2e%2e" || s == ".%2e" || s == "%2e." {
                return false
            }
        }
        return true
    }
}
