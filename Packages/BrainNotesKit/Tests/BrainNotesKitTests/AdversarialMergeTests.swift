import BrainMerge
import Foundation
import Testing
@testable import BrainNotesKit

// Adversarial inputs for the merge layer as BrainNotesKit uses it: line endings, Unicode that Swift's
// String treats as "equal" when the bytes differ, emoji clusters, size limits, empty files, frontmatter,
// and the conflict-copy header round trip. Every check compares bytes (`sameBytes`), never `==`: Swift's
// String equality is canonical, so `==` would pass where the merge changed a note's bytes.

/// The rule the whole design rests on: nothing typed on either side is lost. For a conflict the copy is
/// mine byte for byte and the note is theirs (or theirs with clean sections merged); for a clean merge
/// every line either side added is in the result.
func expectNothingLost(base: String?, mine: String?, theirs: String?, _ r: MergeResult,
                       sourceLocation: SourceLocation = #_sourceLocation) {
    if let copy = r.copy {
        #expect(sameDoc(copy, mine), "a copy is all of mine, byte for byte", sourceLocation: sourceLocation)
    }
    switch r.kind {
    case .same, .takeTheirs, .deleteSkipped:
        #expect(sameDoc(r.content, theirs), sourceLocation: sourceLocation)
    case .takeMine:
        #expect(sameDoc(r.content, mine), sourceLocation: sourceLocation)
    case .merged:
        guard let content = r.content, let base, let mine, let theirs else {
            Issue.record("merged needs three texts", sourceLocation: sourceLocation)
            return
        }
        #expect(safe(base: base, mine: mine, theirs: theirs, result: content), sourceLocation: sourceLocation)
    case .conflict:
        #expect(sameDoc(r.copy, mine), "every conflict copies mine", sourceLocation: sourceLocation)
        if r.reason == .deletedRemotely {
            #expect(r.content == nil, sourceLocation: sourceLocation)
        } else if let base, let mine, let theirs, let content = r.content {
            #expect(safe(base: base, mine: mine, theirs: theirs, result: content, requireMine: false), sourceLocation: sourceLocation)
        }
    }
}

private func merge(_ base: String?, _ mine: String?, _ theirs: String?,
                   sourceLocation: SourceLocation = #_sourceLocation) throws -> MergeResult {
    let r = try mergeFile(base: base, mine: mine, theirs: theirs)
    expectNothingLost(base: base, mine: mine, theirs: theirs, r, sourceLocation: sourceLocation)
    return r
}

@Suite struct LineEndingMergeTests {
    @Test func crlfNoteMergesAndStaysCRLF() throws {
        let base = "# T\r\n\r\n## A\r\none\r\n\r\n## B\r\ntwo\r\n"
        let mine = "# T\r\n\r\n## A\r\none MINE\r\n\r\n## B\r\ntwo\r\n"
        let theirs = "# T\r\n\r\n## A\r\none\r\n\r\n## B\r\ntwo THEIRS\r\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "# T\r\n\r\n## A\r\none MINE\r\n\r\n## B\r\ntwo THEIRS\r\n"))
        #expect(!(r.content ?? "").utf8.split(separator: 0x0A).contains { $0.last != 0x0D }, "no bare LF crept in")
    }

    /// A Windows editor on GitHub's side rewrote every ending. That is a change to every line, so a mine
    /// edit clashes with it: the note keeps theirs (CRLF), the copy keeps mine (LF). Nothing is lost.
    @Test func theirsConvertedLFToCRLFWhileMineEdited() throws {
        let base = "# T\none\ntwo\nthree\n"
        let mine = "# T\none\ntwo MINE\nthree\n"
        let theirs = base.replacingOccurrences(of: "\n", with: "\r\n")
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, theirs))
        #expect(sameDoc(r.copy, mine))
    }

    /// The same text with only the endings changed on both sides, differently: still a conflict, not a
    /// silent pick of one side's endings.
    @Test func bothSidesChangedOnlyEndings() throws {
        let base = "a\nb\nc\n"
        let mine = "a\r\nb\r\nc\r\n"
        let theirs = "a\nb\r\nc\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, theirs))
    }

    /// One file, both endings, each line keeps its own.
    @Test func mixedEndingsKeepEachLinesOwnEnding() throws {
        let base = "# M\r\n\r\n## A\nx\r\ny\n\r\n## B\r\nz\n"
        let mine = "# M\r\n\r\n## A\nx MINE\r\ny\n\r\n## B\r\nz\n"
        let theirs = "# M\r\n\r\n## A\nx\r\ny\n\r\n## B\r\nz THEIRS\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "# M\r\n\r\n## A\nx MINE\r\ny\n\r\n## B\r\nz THEIRS\n"))
    }

    /// A lone CR is not a line break (spec 1): "a\rb" is one line, so an edit of it is a same-line edit.
    @Test func loneCRIsNotALineBreak() throws {
        let base = "top\na\rb\nend\n"
        let mine = "top\na\rb MINE\nend\n"
        let theirs = "top\nA\rb\nend\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, theirs))
    }

    /// The last block has no newline and stops being last: it gets theirs' predominant ending (spec 5.4).
    @Test func missingFinalNewlineThenABlockAfterItInCRLF() throws {
        let base = "# T\r\n\r\n## A\r\nend"
        let mine = "# T\r\n\r\n## A\r\nend"
        let theirs = "# T\r\n\r\n## A\r\nend"
        // Only mine adds a section after the unterminated one.
        let mine2 = mine + "\r\n\r\n## B\r\nnew"
        let r = try merge(base, mine2, theirs)
        #expect(r.kind == .takeMine)
        #expect(sameDoc(r.content, mine2))
        // Both changed: theirs edits A, mine appends B. The join must not glue "end" to "## B".
        let theirs2 = "# T\r\n\r\n## A\r\nend THEIRS"
        let mine3 = "# T\r\n\r\n## A\r\nend\r\n## B\r\nnew\r\n"
        let r2 = try merge(base, mine3, theirs2)
        // Block A clashes ("end" vs "end\r\n" vs "end THEIRS"): it keeps theirs, which has no ending, and
        // mine's new block B follows it. The join must add theirs' CRLF, not glue the lines.
        #expect(r2.kind == .conflict)
        #expect(sameDoc(r2.content, "# T\r\n\r\n## A\r\nend THEIRS\r\n## B\r\nnew\r\n"))
    }

    /// CRLF frontmatter delimiters are frontmatter (trailing "\r" is part of the ending, not the line).
    @Test func crlfFrontmatterIsFrontmatter() throws {
        let text = "---\r\ntitle: x\r\n---\r\n# Body\r\n"
        let blocks = splitBlocks(text)
        #expect(blocks.first?.key == "fm")
        let (fm, body) = NoteText.split(text)
        #expect(sameBytes(fm, "---\r\ntitle: x\r\n---\r\n"))
        #expect(sameBytes(body, "# Body\r\n"))
        #expect(NoteText.frontmatterValue(fm, key: "title") == "x")
    }
}

@Suite struct UnicodeMergeTests {
    /// Swift says NFC "é" == NFD "é". The merge must not: mine re-typed the same word in NFD, so the
    /// bytes changed and mine must win, not be thrown away as "same as base".
    @Test func canonicallyEqualButDifferentBytesIsAChange() throws {
        let base = "Caf\u{E9}\n"
        let mine = "Cafe\u{301}\n"
        #expect(base == mine, "the trap: Swift's == is canonical")
        let r = try merge(base, mine, base)
        #expect(r.kind == .takeMine)
        #expect(sameDoc(r.content, mine))
    }

    /// Hebrew with niqqud: dagesh and vowel in two orders are canonically equivalent, different bytes.
    /// Theirs reordered them on one line, mine edits another: both kept, exact bytes.
    @Test func hebrewNiqqudOrderIsKeptByteForByte() throws {
        let shinDageshQamats = "\u{5E9}\u{5BC}\u{5B8}"  // not in canonical order (qamats ccc 18 sorts first)
        let shinQamatsDagesh = "\u{5E9}\u{5B8}\u{5BC}"
        #expect(shinDageshQamats == shinQamatsDagesh)
        #expect(!sameBytes(shinDageshQamats, shinQamatsDagesh))
        let base = "# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\n\(shinDageshQamats)\n\nשורה שנייה\n"
        let theirs = "# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\n\(shinQamatsDagesh)\n\nשורה שנייה\n"
        let mine = "# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\n\(shinDageshQamats)\n\nשורה שנייה ומשהו\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\n\(shinQamatsDagesh)\n\nשורה שנייה ומשהו\n"))
    }

    /// RTL text with bidi controls and mixed-direction lines: a same-line edit is a conflict, and the copy
    /// keeps the invisible marks.
    @Test func rtlSameLineEditKeepsBidiMarksInTheCopy() throws {
        let base = "# פגישה\n\nנקבע ל-10:00 עם Noa\n"
        let mine = "# פגישה\n\n\u{200F}נקבע ל-11:00 עם Noa\u{200E}\n"
        let theirs = "# פגישה\n\nנקבע ל-10:30 עם Noa\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.copy, mine))
        #expect(r.copy?.unicodeScalars.contains("\u{200F}") == true)
    }

    /// Hebrew headings are block keys. Two sides editing different Hebrew sections merge.
    @Test func hebrewSectionsMergeIndependently() throws {
        let base = "# מחברת\n\n## רעיונות\nאחד\n\n## משימות\n- לקנות חלב\n"
        let mine = "# מחברת\n\n## רעיונות\nאחד\nשניים\n\n## משימות\n- לקנות חלב\n"
        let theirs = "# מחברת\n\n## רעיונות\nאחד\n\n## משימות\n- לקנות חלב\n- להתקשר לנועה\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "# מחברת\n\n## רעיונות\nאחד\nשניים\n\n## משימות\n- לקנות חלב\n- להתקשר לנועה\n"))
    }

    /// NFC and NFD spellings of one Hebrew-with-niqqud heading are two different block keys.
    @Test func canonicallyEqualHeadingsAreDifferentKeys() throws {
        let a = "## \u{5E9}\u{5BC}\u{5B8}\n", b = "## \u{5E9}\u{5B8}\u{5BC}\n"
        let blocks = splitBlocks(a + "x\n" + b + "y\n")
        #expect(blocks.count == 2)
        #expect(blocks.map(\.key).allSatisfy { $0.hasSuffix("#1") }, "each is the first of its exact spelling")
    }

    /// Emoji ZWJ sequences, flags and skin tones are one Character to Swift but many scalars. Changing one
    /// member of a family emoji is a byte change on that line.
    @Test func zwjFamilyEditIsAChange() throws {
        let family3 = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let family4 = family3 + "\u{200D}\u{1F466}"
        let base = "# 🎉\n\n\(family3) trip\n\nflags 🇮🇱🇺🇸\n"
        let mine = "# 🎉\n\n\(family4) trip\n\nflags 🇮🇱🇺🇸\n"
        let theirs = "# 🎉\n\n\(family3) trip\n\nflags 🇮🇱🇺🇸 👍🏽\n"
        let r = try merge(base, mine, theirs)
        // Adjacent? No: an empty line separates them, so this merges.
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "# 🎉\n\n\(family4) trip\n\nflags 🇮🇱🇺🇸 👍🏽\n"))
    }

    /// A ZWJ sequence that differs only by a variation selector (U+FE0F) is a different line.
    @Test func variationSelectorIsAChange() throws {
        let base = "a\n\u{2764}\n"
        let mine = "a\n\u{2764}\u{FE0F}\n"
        let r = try merge(base, mine, base)
        #expect(r.kind == .takeMine)
        #expect(sameDoc(r.content, mine))
    }

    /// A line made of one family emoji, edited the same way on both sides: `same`, no copy.
    @Test func identicalEmojiEditsAreSame() throws {
        let base = "x\n"
        let both = "x\n\u{1F9D1}\u{1F3FD}\u{200D}\u{1F4BB}\n"
        let r = try merge(base, both, both)
        #expect(r.kind == .same)
        #expect(r.copy == nil)
    }

    /// Supplementary-plane text and an emoji heading key survive a three-way block merge.
    @Test func emojiHeadingKeys() throws {
        let base = "## 📌 Pinned\na\n\n## 🗑️ Later\nb\n"
        let mine = "## 📌 Pinned\na MINE\n\n## 🗑️ Later\nb\n"
        let theirs = "## 📌 Pinned\na\n\n## 🗑️ Later\nb THEIRS\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "## 📌 Pinned\na MINE\n\n## 🗑️ Later\nb THEIRS\n"))
    }
}

@Suite struct SameLineAndDeleteMergeTests {
    @Test func sameLineDifferentEdits() throws {
        let base = "# N\nshared line\n"
        let r = try merge(base, "# N\nshared line MINE\n", "# N\nshared line THEIRS\n")
        #expect(r.kind == .conflict)
        #expect(r.reason == .sameLines)
        #expect(r.clashes == ["# N#1"])
    }

    @Test func sameLineSameEditIsSame() throws {
        let r = try merge("a\n", "b\n", "b\n")
        #expect(r.kind == .same)
    }

    /// Edits on adjacent lines conflict, as in git (spec 4).
    @Test func adjacentLinesConflict() throws {
        let r = try merge("1\n2\n3\n", "1\n2m\n3\n", "1\n2\n3t\n")
        #expect(r.kind == .conflict)
    }

    /// One side deletes a line, the other edits it.
    @Test func lineDeletedAgainstLineEdited() throws {
        let r = try merge("a\nb\nc\n", "a\nc\n", "a\nB\nc\n")
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, "a\nB\nc\n"))
    }

    @Test func iDeletedTheyEdited() throws {
        let r = try merge("x\n", nil, "x edited\n")
        #expect(r.kind == .deleteSkipped)
        #expect(sameDoc(r.content, "x edited\n"))
        #expect(r.copy == nil)
    }

    @Test func theyDeletedIEdited() throws {
        let r = try merge("x\n", "x edited\n", nil)
        #expect(r.kind == .conflict)
        #expect(r.reason == .deletedRemotely)
        #expect(r.content == nil)
        #expect(sameDoc(r.copy, "x edited\n"))
    }

    @Test func bothDeleted() throws {
        let r = try merge("x\n", nil, nil)
        #expect(r.kind == .same)
        #expect(r.content == nil)
    }

    /// Mine deleted a section that theirs edited: a clash, theirs' section stays, mine in the copy.
    @Test func sectionDeletedAgainstSectionEdited() throws {
        let base = "# T\n\n## A\na\n\n## B\nb\n"
        let mine = "# T\n\n## B\nb\n"
        let theirs = "# T\n\n## A\na THEIRS\n\n## B\nb\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(r.reason == .sectionDeleted)
        #expect(r.content?.contains("a THEIRS") == true)
    }
}

@Suite struct EmptyFileMergeTests {
    /// An empty file is a file, not a delete.
    @Test func emptyIsNotDeleted() throws {
        let r = try merge("x\n", "", "x\n")
        #expect(r.kind == .takeMine)
        #expect(r.content == "")
        let r2 = try merge("x\n", "", nil)
        #expect(r2.kind == .conflict)
        #expect(r2.reason == .deletedRemotely)
        #expect(r2.copy == "")
    }

    @Test func bothEmptiedIsSame() throws {
        let r = try merge("x\n", "", "")
        #expect(r.kind == .same)
        #expect(r.content == "")
    }

    /// From an empty base, both sides type. An empty base has no blocks, so both sides *added* the `pre`
    /// block with different text: a clash (spec 5.2, as M17), not a line union (4.3). Conservative: the
    /// note keeps theirs, the copy keeps mine.
    @Test func bothFilledAnEmptyNote() throws {
        let r = try merge("", "mine\n", "theirs\n")
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, "theirs\n"))
        #expect(sameDoc(r.copy, "mine\n"))
    }

    @Test func bothFilledAnEmptyNoteWithoutFinalNewlines() throws {
        let r = try merge("", "mine", "theirs")
        #expect(r.kind == .conflict)
        #expect(!(r.content ?? "").contains("theirsmine"), "lines glued: \(String(describing: r.content))")
    }

    /// Mine emptied a note that theirs edited: conflict, the copy is empty (all of mine), theirs stays.
    @Test func mineEmptiedTheirsEdited() throws {
        let r = try merge("a\nb\n", "", "a\nb\nc\n")
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, "a\nb\nc\n"))
        #expect(r.copy == "")
    }

    @Test func emptyCreatesOnBothSides() throws {
        let r = try merge(nil, "", "")
        #expect(r.kind == .same)
        let r2 = try merge(nil, "", "x\n")
        #expect(r2.kind == .conflict)
        #expect(r2.reason == .bothCreated)
        #expect(r2.copy == "")
    }

    @Test func emptyNoteHasNoBlocksAndNoFrontmatter() {
        #expect(splitBlocks("").isEmpty)
        let (fm, body) = NoteText.split("")
        #expect(fm.isEmpty && body.isEmpty)
        #expect(NoteText.title(of: "", path: "notes/empty.md") == "empty")
        #expect(ConflictCopy(text: "") == nil)
    }
}

@Suite struct FrontmatterMergeTests {
    private let body = "# Note\n\n## A\nalpha\n\n## B\nbeta\n"

    @Test func bothEditTheSameFrontmatterKey() throws {
        let base = "---\nstatus: draft\ntags: [a]\n---\n" + body
        let mine = "---\nstatus: done\ntags: [a]\n---\n" + body.replacingOccurrences(of: "beta", with: "beta MINE")
        let theirs = "---\nstatus: review\ntags: [a]\n---\n" + body.replacingOccurrences(of: "alpha", with: "alpha THEIRS")
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(r.clashes == ["fm"])
        let c = try #require(r.content)
        #expect(c.hasPrefix("---\nstatus: review\n"), "the clashing frontmatter keeps theirs")
        #expect(c.contains("alpha THEIRS") && c.contains("beta MINE"), "clean sections still merge")
    }

    @Test func differentFrontmatterKeysMerge() throws {
        let base = "---\nstatus: draft\n\ntags: [a]\n---\n" + body
        let mine = "---\nstatus: done\n\ntags: [a]\n---\n" + body
        let theirs = "---\nstatus: draft\n\ntags: [a, b]\n---\n" + body
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "---\nstatus: done\n\ntags: [a, b]\n---\n" + body))
    }

    /// Mine adds frontmatter where there was none while theirs edits the body: the whole file merges by
    /// lines (spec 5.5).
    @Test func mineAddsFrontmatterTheirsEditsBody() throws {
        let base = body
        let mine = "---\ntitle: Note\n---\n" + body
        let theirs = body.replacingOccurrences(of: "beta", with: "beta THEIRS")
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "---\ntitle: Note\n---\n" + theirs))
    }

    /// Both add different frontmatter to a note that had none. Frontmatter presence differs from base, so
    /// the whole file merges by lines (5.5), and two insertions at line 0 are a union (4.3): theirs'
    /// frontmatter, then mine's as BODY text. No line is lost and the line check passes, but mine's keys are
    /// no longer metadata, the body gains a `---` rule, and nothing reaches Needs attention.
    /// BrainMerge behaviour, which this branch may not change: pinned here as a known issue for a decision.
    @Test func bothAddFrontmatter() throws {
        let r = try merge(body, "---\na: 1\n---\n" + body, "---\nb: 2\n---\n" + body)
        #expect(sameDoc(r.content, "---\nb: 2\n---\n---\na: 1\n---\n" + body), "today's result")
        #expect(NoteText.frontmatterValue(NoteText.split(r.content ?? "").frontmatter, key: "a") == nil,
                "mine's key is not frontmatter any more")
        withKnownIssue("both sides adding frontmatter should clash, not demote mine's frontmatter to body text") {
            #expect(r.kind == .conflict)
        }
    }

    /// Theirs removed the frontmatter, mine edited it.
    @Test func theirsRemovedFrontmatterMineEditedIt() throws {
        let base = "---\nstatus: draft\n---\n" + body
        let mine = "---\nstatus: done\n---\n" + body
        let r = try merge(base, mine, body)
        #expect(r.kind == .conflict)
        #expect(sameDoc(r.content, body))
    }

    /// An unclosed `---` is not frontmatter (spec 2.1): closing it on one side switches the file to the
    /// line-merge fallback, which must still lose nothing.
    @Test func closingAnUnclosedFrontmatter() throws {
        let base = "---\ntitle: x\n# Body\nline\n"
        let mine = "---\ntitle: x\n---\n# Body\nline\n"
        let theirs = "---\ntitle: x\n# Body\nline THEIRS\n"
        _ = try merge(base, mine, theirs)
    }

    /// `...` closes frontmatter too; a CRLF one is frontmatter.
    @Test func dotsCloseFrontmatterAndCRLFMerges() throws {
        let base = "---\r\nk: 1\r\n...\r\n# H\r\nx\r\n"
        let mine = "---\r\nk: 2\r\n...\r\n# H\r\nx\r\n"
        let theirs = "---\r\nk: 1\r\n...\r\n# H\r\nx THEIRS\r\n"
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
        #expect(sameDoc(r.content, "---\r\nk: 2\r\n...\r\n# H\r\nx THEIRS\r\n"))
    }
}

@Suite struct BudgetMergeTests {
    /// Over 2,000 blocks on a side: whole-note conflict, too-large, theirs kept, mine copied.
    @Test func tooManyBlocks() throws {
        let base = (0..<2001).map { "## h\($0)\nx\n" }.joined()
        let mine = base + "## new\nmine\n"
        let theirs = "theirs\n" + base
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .conflict)
        #expect(r.reason == .tooLarge)
        #expect(sameDoc(r.content, theirs))
    }

    /// Just at the block limit, still merges.
    @Test func atTheBlockLimit() throws {
        let base = (0..<1999).map { "## h\($0)\nx\n" }.joined()
        let mine = base + "## new\nmine\n"
        let theirs = "theirs\n" + base
        let r = try merge(base, mine, theirs)
        #expect(r.kind == .merged)
    }

    /// A note near 1 MiB with both sides editing different ends merges, but the result can be over the
    /// limit: the planner must refuse to write it (spec 6.4), keep the op and say so.
    @Test func mergedResultOverTheSizeLimitIsBlocked() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let filler = String(repeating: line, count: 10_480)  // 1,048,000 bytes
        let base = "# Big\n\n## Top\nt\n\n## Body\n" + filler
        #expect(base.utf8.count < 1_048_576)
        let mine = base.replacingOccurrences(of: "## Top\nt\n", with: "## Top\nt\n" + String(repeating: "m", count: 300) + "\n")
        let theirs = base + String(repeating: "t", count: 300) + "\n"
        #expect(mine.utf8.count <= 1_048_576 && theirs.utf8.count <= 1_048_576)
        let plan = try planCommit(PlanInput(baseTree: ["big.md": base], theirsTree: ["big.md": theirs],
                                            ops: [.edit(path: "big.md", content: mine)],
                                            device: "d", time: "2026-11-04T10:00:00Z"))
        #expect(plan.entries.isEmpty, "nothing over the limit is written")
        #expect(plan.kept == [0])
        #expect(plan.attention.map(\.reason) == [.blocked(.tooLarge)])
    }

    /// Mine exactly at the limit, conflicting: the copy (header + mine) would be over, so nothing is written
    /// and the op stays. Mine is not lost: it is still in the outbox.
    @Test func conflictAtTheLimitKeepsTheOp() throws {
        let base = "# Big\nshared\n"
        var mine = "# Big\nshared MINE\n"
        mine += String(repeating: "y", count: 1_048_576 - mine.utf8.count - 1) + "\n"
        #expect(mine.utf8.count == 1_048_576)
        let theirs = "# Big\nshared THEIRS\n"
        let plan = try planCommit(PlanInput(baseTree: ["big.md": base], theirsTree: ["big.md": theirs],
                                            ops: [.edit(path: "big.md", content: mine)],
                                            device: "d", time: "2026-11-04T10:00:00Z"))
        #expect(plan.kept == [0])
        #expect(plan.entries.isEmpty)
    }

    /// The size limit counts UTF-8 bytes, not Characters: 350,000 Hebrew letters are 700,000 bytes, and
    /// 300,000 family emoji (one Character each) are 5.4 MB.
    @Test func sizeIsBytesNotCharacters() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text = String(repeating: family, count: 60_000)
        #expect(text.count == 60_000)
        #expect(text.utf8.count == 60_000 * 18)
        #expect(checkPath("a.md", content: text) == .tooLarge)
        #expect(checkPath("a.md", content: String(repeating: "א", count: 524_288)) == nil)
        #expect(checkPath("a.md", content: String(repeating: "א", count: 524_289)) == .tooLarge)
    }
}

@Suite struct ConflictCopyHeaderTests {
    private func roundTrip(path: String, device: String, mine: String,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = copyHeader(path, device: device, time: "2026-11-04T10:00:00Z") + mine
        let c = try #require(ConflictCopy(text: text), sourceLocation: sourceLocation)
        #expect(c.conflictOf.map { sameBytes($0, path) } == true, "conflict_of \(String(describing: c.conflictOf)) for \(path)", sourceLocation: sourceLocation)
        #expect(c.device.map { sameBytes($0, device) } == true, "device \(String(describing: c.device)) for \(device)", sourceLocation: sourceLocation)
        #expect(c.created == "2026-11-04T10:00:00Z", sourceLocation: sourceLocation)
        #expect(sameBytes(c.mine, mine), "mine must come back byte for byte", sourceLocation: sourceLocation)
        #expect(NoteText.isConflictCopy(text), sourceLocation: sourceLocation)
        // The header is real frontmatter to the merge, whatever mine holds.
        #expect(splitBlocks(text).first?.key == "fm", sourceLocation: sourceLocation)
    }

    @Test func plainRoundTrip() throws {
        try roundTrip(path: "people/demo-person.md", device: "iphone-a1b2c3", mine: "# Demo\nbody\n")
    }

    @Test func hebrewPathAndNFDPath() throws {
        try roundTrip(path: "עברית/רעיון.md", device: "iphone-a1b2c3", mine: "# רעיון\nטקסט\n")
        try roundTrip(path: "Cafe\u{301}.md", device: "mac-x", mine: "nfd\n")
    }

    @Test func quotesBackslashesAndColonsInNames() throws {
        try roundTrip(path: "notes/say \"hi\".md", device: "mac-x", mine: "q\n")
        try roundTrip(path: "notes/back\\slash.md", device: "mac-x", mine: "b\n")
        try roundTrip(path: "notes/end\\\".md", device: "a\\\"b\\", mine: "both\n")
        try roundTrip(path: "notes/key: value.md", device: "d: e", mine: "colon\n")
        try roundTrip(path: "notes/'single'.md", device: "'d'", mine: "s\n")
    }

    @Test func emojiAndBidiInNames() throws {
        try roundTrip(path: "📌/👨‍👩‍👧 trip.md", device: "iphone-🎉", mine: "🎉\n")
        try roundTrip(path: "notes/ש\u{200F}x.md", device: "d", mine: "rtl\n")
    }

    /// Characters Swift calls newlines but the merge does not: NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR.
    /// The path policy lets them through (they are not ASCII controls or default-ignorable), and
    /// `yamlStr` leaves them unescaped (JSON does), so the header line holds them literally.
    @Test func unicodeLineSeparatorsInThePath() throws {
        for sep in ["\u{2028}", "\u{2029}", "\u{85}"] {
            let path = "notes/a\(sep)b.md"
            #expect(checkPath(path) == nil, "the policy allows \(sep.unicodeScalars.first!.value)")
            try roundTrip(path: path, device: "d", mine: "x\n")
        }
    }

    /// A name that starts with a combining mark: to Swift the opening quote and the mark are one Character,
    /// so a Character-level quote strip would keep the quotes.
    @Test func combiningMarkRightAfterTheOpeningQuote() throws {
        try roundTrip(path: "\u{301}lone-mark.md", device: "\u{5BC}d", mine: "x\n")
        try roundTrip(path: "notes/\u{5B8}.md", device: "d\u{301}", mine: "x\n")
    }

    @Test func mineWithItsOwnFrontmatterAndCRLF() throws {
        try roundTrip(path: "a.md", device: "d", mine: "---\r\ntype: note\r\n---\r\n# A\r\n")
        try roundTrip(path: "a.md", device: "d", mine: "---\ntype: conflict\nconflict_of: \"b.md\"\n---\nnested copy\n")
    }

    @Test func mineEmptyOrWithoutFinalNewline() throws {
        try roundTrip(path: "a.md", device: "d", mine: "")
        try roundTrip(path: "a.md", device: "d", mine: "no newline")
        try roundTrip(path: "a.md", device: "d", mine: "\n")
        try roundTrip(path: "a.md", device: "d", mine: "---")
        try roundTrip(path: "a.md", device: "d", mine: "...\n")
    }

    /// Mine starting with a BOM or blank lines stays exact.
    @Test func mineWithBOM() throws {
        try roundTrip(path: "a.md", device: "d", mine: "\u{FEFF}# A\n")
        try roundTrip(path: "a.md", device: "d", mine: "\n\n# A\n")
    }

    /// A user note whose own frontmatter says `type: conflict` but has no copy header is still parsed as a
    /// copy (that is what the type means); its `mine` is its body. A note with a different type is not.
    @Test func typeMustBeExactlyConflict() {
        #expect(!NoteText.isConflictCopy("---\ntype: conflicts\n---\nx\n"))
        #expect(!NoteText.isConflictCopy("---\ntypes: conflict\n---\nx\n"))
        #expect(NoteText.isConflictCopy("---\ntype: \"conflict\"\n---\nx\n"))
        #expect(!NoteText.isConflictCopy("# not frontmatter\n---\ntype: conflict\n---\n"))
    }
}
