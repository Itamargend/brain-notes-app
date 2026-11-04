import BrainMerge
import Foundation

/// Add to Brain: shared text, a shared link or a quick note, on its way to becoming a note in `_inbox`.
/// The App Intent and the share sheet fill this in; `NoteStore.capture` turns it into a note.
public struct Capture: Sendable, Equatable {
    /// Where a capture came from. The raw values are written to the note's `source:` and are part of
    /// the intent's contract (docs/plan/add-to-brain.md), so they never change.
    public enum Source: String, Sendable, CaseIterable {
        /// The system share sheet: text or a link from another app.
        case share
        /// The Shortcuts app, Siri or an automation running the intent.
        case shortcut
        /// Typed straight into the intent's prompt, or a Control Center / Action button capture.
        case quickNote = "quick-note"
    }

    public var text: String
    public var url: URL?
    /// A title the sender knows, such as a web page's. Without one, the first line of the text names the note.
    public var title: String?
    public var source: Source

    public init(text: String = "", url: URL? = nil, title: String? = nil, source: Source) {
        self.text = text
        self.url = url
        self.title = title
        self.source = source
    }
}

/// Why a capture was refused. Nothing is written for any of these.
public enum CaptureProblem: Error, Equatable, Sendable {
    /// No text and no link, or only white space.
    case empty
    /// Over the 1 MiB a note may hold (merge spec 6.4).
    case tooLarge
    /// The text holds something shaped like a secret. A saved note with one would be blocked at commit and sit
    /// in Needs attention, so the intent says so at once and the text stays where it came from.
    case secret(String)
    /// The sample notes are open. Their folder is rebuilt at every launch, so a capture there would vanish.
    case sampleNotes
    /// Every name tried was taken between the pick and the write. Not expected outside a test.
    case noFreeName
}

/// The text and file name of a capture note. Pure: no disk, no clock, no network.
public enum CaptureNote {
    /// A file name's stem in UTF-8 bytes at most. The kit's 60-character cap keeps Hebrew to 120 bytes, but
    /// 60 emoji or letters with many combining marks can pass 255 bytes, which no disk holds in one name.
    public static let maxStemBytes = 180

    /// Frontmatter (`type`, `created`, `source`, and `url` for a link), then the body: a `# ` heading when a
    /// title was given or only a link was shared, the text, and the link unless the text already holds it.
    /// Line endings become `\n`, and the note ends with one.
    public static func text(for capture: Capture, created: Date) throws -> String {
        let body = normalized(capture.text)
        let link = capture.url.flatMap(cleanLink)
        let title = capture.title.map(oneLine) ?? ""
        if body.isEmpty && link == nil && title.isEmpty { throw CaptureProblem.empty }

        var parts: [String] = []
        // A share sheet often sends the page title both as the title and as the text's first line.
        let bodyStartsWithTitle = sameBytes(NoteText.stripMarks(NoteText.firstLine(of: body)), title)
        if !title.isEmpty && !bodyStartsWithTitle {
            parts.append("# " + title)
        } else if body.isEmpty, let link {
            parts.append("# " + (URLComponents(string: link)?.host ?? "Link"))
        }
        if !body.isEmpty { parts.append(body) }
        if let link, !body.contains(link) { parts.append(link) }

        var header = "---\ntype: capture\ncreated: \(yamlStr(isoTime(created)))\nsource: \(yamlStr(capture.source.rawValue))\n"
        if let link { header += "url: \(yamlStr(link))\n" }
        header += "---\n"
        let note = header + parts.joined(separator: "\n\n") + "\n"

        if checkPath(PathPolicy.inboxFolder + "/x.md", content: note) == .tooLarge { throw CaptureProblem.tooLarge }
        if let kind = SecretScan.scan(note) { throw CaptureProblem.secret(kind) }
        return note
    }

    /// The file name without `.md`, from the note's first body line, as the app names any new note
    /// (`PathPolicy.fileName`): Hebrew and other scripts as typed, in NFC; no `/ \ : * ? " < > |`, control or
    /// invisible characters; no leading or trailing dots and spaces; 60 characters. On top of that, for a name
    /// that must survive every checkout of the repo: at most `maxStemBytes` bytes, and never a Windows device
    /// name (`CON`, `nul.txt`, `COM1`...), which a Windows clone cannot create.
    public static func fileStem(for text: String) -> String {
        var stem = PathPolicy.fileName(fromFirstLine: NoteText.firstLine(of: text))
        while stem.utf8.count > maxStemBytes { stem.removeLast() }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if stem.isEmpty { return "Untitled" }
        if isWindowsDeviceName(stem) { stem += "-note" }
        return nfc(stem)
    }

    static func isWindowsDeviceName(_ stem: String) -> Bool {
        // Windows reads the part before the first dot, with trailing spaces ignored, case-insensitively.
        let base = (stem.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? stem)
            .trimmingCharacters(in: .whitespaces).uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(base) { return true }
        for prefix in ["COM", "LPT"] where base.count == 4 && base.hasPrefix(prefix) {
            if let d = base.last, "123456789¹²³".contains(d) { return true }
        }
        return false
    }

    /// `\n` line endings, no blank lines before the text and no white space after it.
    static func normalized(_ text: String) -> String {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = lf.components(separatedBy: "\n")
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A title on one line, for the heading.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The link as it goes into the note: no user name or password, which would be a credential in the repo.
    /// Nil for something that is not a link (no scheme).
    static func cleanLink(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme, !scheme.isEmpty else { return nil }
        parts.user = nil
        parts.password = nil
        guard let link = parts.string, !link.contains(where: \.isNewline) else { return nil }
        return link
    }
}
