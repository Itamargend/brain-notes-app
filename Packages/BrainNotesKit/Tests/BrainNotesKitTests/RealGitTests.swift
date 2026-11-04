import Foundation
import Testing
@testable import BrainNotesKit

/// GitHub's tarball is `git archive` output. My tar writer only proves the reader agrees with my own
/// writer, so this runs the real git on a throwaway local repo: no remote, no network.
@Suite struct RealGitTests {
    private func git(_ args: [String], in dir: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.environment = [
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
            "HOME": dir.path, "PATH": "/usr/bin:/bin",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        return data
    }

    /// path -> blob sha, from `git ls-tree -r -z`, whose paths are exact bytes.
    private func blobs(in dir: URL) throws -> [PathKey: String] {
        let raw = try git(["ls-tree", "-r", "-z", "HEAD"], in: dir)
        var out: [PathKey: String] = [:]
        for record in raw.split(separator: 0) {
            let line = String(decoding: record, as: UTF8.self)
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            let meta = parts[0].split(separator: " ").map(String.init)
            out[PathKey(parts[1])] = meta[2]
        }
        return out
    }

    @Test func tarballAndHashesMatchRealGit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Short and long names (ustar name, ustar prefix, pax), Hebrew, NFD, spaces, odd bytes in files.
        let files: [(String, Data)] = [
            ("README.md", Data("# Readme\n".utf8)),
            ("empty.md", Data()),
            ("no final newline.md", Data("text".utf8)),
            ("crlf.md", Data("a\r\nb\r\n".utf8)),
            ("bom.md", Data([0xEF, 0xBB, 0xBF]) + Data("x\n".utf8)),
            ("עברית/רעיון לסופש.md", Data("# רעיון\nטקסט\n".utf8)),
            ("Cafe\u{301}/nfd.md", Data("nfd folder\n".utf8)),
            ("a/" + String(repeating: "x", count: 95) + ".md", Data("just over 100 bytes\n".utf8)),
            (String(repeating: "folder/", count: 20) + "deep.md", Data("needs the ustar prefix\n".utf8)),
            (String(repeating: "לונג/", count: 40) + "עמוק.md", Data("over 255 bytes: pax\n".utf8)),
            ("big.md", Data(String(repeating: "A line of text, שורה.\n", count: 50_000).utf8)),
        ]
        _ = try git(["init", "-q", "-b", "main"], in: dir)
        _ = try git(["config", "core.precomposeunicode", "false"], in: dir)
        _ = try git(["config", "core.quotepath", "false"], in: dir)
        _ = try git(["config", "core.autocrlf", "false"], in: dir)
        for (path, data) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        _ = try git(["add", "-A"], in: dir)
        _ = try git(["commit", "-q", "-m", "fixture"], in: dir)

        let gz = try git(["archive", "--format=tar.gz", "--prefix=Itamargend-brain-notes-test-abc1234/", "HEAD"], in: dir)
        let tree = try blobs(in: dir)
        #expect(tree.count == files.count)

        let entries = try TarReader.files(in: try Gzip.decompress(gz))
        #expect(entries.count == files.count)
        for e in entries {
            let sha = tree[PathKey(e.path)]
            #expect(sha != nil, "path from the tarball is not in the tree: \(e.path)")
            #expect(GitBlob.sha(e.data) == sha, "hash of \(e.path)")
        }
        // The Hebrew and long paths came through with their exact bytes.
        for (path, data) in files {
            let hit = entries.first { sameBytes($0.path, path) }
            #expect(hit?.data == data, "\(path)")
        }
    }

    /// A real commit, read back by the code that would read it from GitHub's blob endpoint.
    @Test func blobShaMatchesGitHashObject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try git(["init", "-q"], in: dir)
        for text in ["", "a", "שלום\n", "line\r\n", String(repeating: "x", count: 100_000)] {
            let f = dir.appendingPathComponent("f.bin")
            try Data(text.utf8).write(to: f)
            let out = try git(["hash-object", "f.bin"], in: dir)
            let real = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(GitBlob.sha(text) == real)
        }
    }
}
