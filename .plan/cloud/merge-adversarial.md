# cloud/merge-adversarial

Cloud session, 4 Nov 2026. Branched from `editor-spike` at `f6e792a`. Pushed only to `cloud/merge-adversarial`.
No PR. BrainMerge sources not touched. Only synthetic test content; no real brain repo, no secrets.

## What I did

1. **Got Swift running on Linux.** `download.swift.org` is blocked by the proxy, but the GCR Docker mirror works.
   I pulled the `swift:6.2.4-noble` layers from it by hand, unpacked them into a chroot, mounted `/proc` and `/dev`,
   and copied the host's `sqlite3.h` in. GRDB was cloned at the pinned tag `v7.12.0` (commit `92a554c`, the same as in `Package.resolved`).
2. **Built a Linux copy of BrainNotesKit** (`merge-adversarial-linux/gen.py`, `Shims.swift`, next to this file). The
   generator copies the real Kit sources and tests into the chroot and changes only what Linux lacks:
   - CryptoKit's SHA-1 and SHA-256, written in pure Swift (they hash to the same values; GitBlob test vectors still pass);
   - `os.Logger` replaced by a no-op;
   - Compression replaced by zlib, raw deflate;
   - Keychain replaced by an in-memory store, and `NWPathMonitor` by a stub;
   - `waitsForConnectivity` dropped;
   - `.byWords` swapped for composed characters, and AttributedString's Markdown parser for plain text;
   - one closure capture changed for the older region checker.

   The app sources in the repo are not changed for Linux.
3. **Wrote the adversarial suite** in `Packages/BrainNotesKit/Tests/BrainNotesKitTests/`. Every comparison uses bytes (`sameBytes`/`sameDoc`), never String `==`.
   - `AdversarialMergeTests.swift` (mergeFile and planCommit directly), covering:
     - CRLF, LF, mixed and lone-CR endings;
     - CRLF frontmatter;
     - NFC/NFD text;
     - Hebrew niqqud in non-canonical order;
     - RTL bidi marks;
     - ZWJ, flag, skin-tone and variation-selector emoji;
     - emoji heading keys;
     - same-line and adjacent-line edits;
     - deletes against edits at line, section and file level;
     - empty files;
     - frontmatter clashes, adds and removes, and `...` closers;
     - the 2,000-block limit (just over and just under);
     - 1 MiB after a merge;
     - a copy exactly at the limit;
     - UTF-8 bytes versus Characters;
     - the conflict-copy header round trip with quotes, backslashes, colons, emoji, bidi, U+2028/U+2029/NEL, combining marks, nested copies, BOM and empty or unterminated mine.

     It also has a **hostile-alphabet fuzz**: 3,200 seeded cases, with invariants listed in the file. The fuzz asserts that it reaches clean merges, conflicts and pure-CRLF notes, so it can't pass by doing nothing.
   - `AdversarialSyncTests.swift` (engine plus FakeGitHub, end to end) runs the same inputs through the engine and adds:
     - a NUL inside a note;
     - an emptied note (empty file, not a delete);
     - "use mine" byte exactness;
     - byte-exact side-by-side texts;
     - two devices on one Hebrew line;
     - `CopyNameLengthTests`.

## Bugs found and fixed (each test failed first; I confirmed this with the fix stashed)

1. **Conflict header read back wrong (`NoteText.frontmatterValue`).**
   - It split on `Character.isNewline`, which also breaks on U+2028, U+2029 and NEL. The path policy allows those
     in a name, and `yamlStr` leaves them literal. So a copy of `notes/a<U+2028>b.md` parsed as `conflict_of: "notes/a`.
     Fix: split on `\n` only (the merge spec's lines).
   - It stripped quotes per Character. `"` followed by a combining mark is one Character, so a name or device starting
     with a mark kept its quotes. Fix: strip the quotes as bytes.
   - Impact today is small: nothing in the app reads `conflictOf` yet, and `type`, `mine` and copy detection were right.
     But the header did not round-trip.
2. **Device-made copies could get a name the disk refuses (`NoteStore.slug`). Data loss in one path.**
   - The slug was cut to 150 *Characters*. A note named with letters plus marks that have no precomposed form, Hebrew
     with niqqud, or emoji fits the disk, but its copy name does not (274 bytes in the test).
   - `save(…editingFrom:)` in the second-window case writes the new text and then fails to write the copy of the
     other window's text, so **that text was lost**.
   - `freshSync()` threw on every try, so recovery from a rewritten history never finished.
   - Fix: cut to 150 UTF-8 bytes on Character boundaries, keeping the end. A single Character over the limit keeps
     its base and the marks that fit.

## Found, not fixed (needs your decision)

- **Both sides add different frontmatter to a note that had none → a clean "merge" with two `---` blocks.**
  Frontmatter presence differs from base, so the file falls back to the line merge (5.5). Both inserted at line 0, so the
  union rule (4.3) applies: the result is theirs' frontmatter, then mine's frontmatter as *body* text. No line is lost and
  the line check passes. But mine's keys stop being metadata, the body gains a `---` rule, and nothing goes to Needs attention.
  This is BrainMerge behaviour, which this branch may not change. It is pinned as `withKnownIssue` in `FrontmatterMergeTests.bothAddFrontmatter`.
  Smallest fix to consider: in the 5.5 fallback, a union whose inserted lines include a frontmatter opener at line 0 becomes a conflict.
- **Both sides fill an empty note → conflict, not a union.** An empty base has no blocks, so both sides "added" `pre` (5.2, like M17).
  It is spec'd and safe (copy = mine), just stricter than you might expect for a note created empty on one device and typed on two. Tested as is.
- **Planner-made copy names are not truncated** (spec 6.1 has no limit). A deep or long path gets a copy name the device can't
  hold: it lands on GitHub and is held back on the device as `unstorable`, so the text is safe but not visible on the phone.
  I did not change BrainMerge. The existing sync fuzz (`longNames`) already covers that the text survives.
- The conflict header is LF even for a CRLF note (spec 6.1 says header, then mine exactly). The copy is mixed-ending by design. I only noted it.

## Verified (Linux, Swift 6.2.4, chroot)

- BrainMerge `swift test`: 110/110 vectors and the merge, plan and matchLines differentials pass.
  **28 of 6,275 `paths` differential cases fail on Linux only**: Unicode 17 case pairs (U+A7CE/A7CF, U+16EA0…) that the
  Linux 6.2.4 stdlib's tables don't have yet. This is a platform difference, not a code change (BrainMerge is untouched).
  It is a reminder that `foldKey` follows the OS Unicode tables (spec 6.3 says "over Unicode 17").
- BrainNotesKit, the whole suite on the Linux copy: 399 tests. The new tests all pass (one is a known issue, on purpose). The set
  of failing tests is identical before and after my changes (diffed against a baseline run). All of those failures are Linux artifacts:
  - no APFS normalization or case-insensitivity on ext4;
  - no word enumeration or Markdown parser in corelibs Foundation;
  - source-scanning policy tests can't find `/lk` sources;
  - no backup flag;
  - timing budgets on a debug build. `saveIsFastEnoughForABigNote` missed by 10 ms once under full load and passes 3/3 alone.
- `SyncFuzzTests` (12 configs) and `ChaosTests` pass on Linux after the changes.

## Not verified

- **Nothing was built or run on macOS or iOS, or with Xcode.** Not run: `xcodebuild`, the App target, `scripts/verify.sh`
  (it calls `sw_vers`/`xcodebuild`; I ran `swift test` directly), and the real CryptoKit, Compression and Keychain.
- The new tests compiled with the Linux 6.2.4 toolchain under Swift 6 language mode. Xcode 26's compiler could differ on
  concurrency diagnostics. The tests use only `Testing`, `@testable` internals (`FileStore.nameFits`, `NoteStore.createCopy`) and public BrainMerge.
- Two tests assume a disk limit of 255 bytes per name, which is true on both APFS and ext4. `FileStore.nameFits` counts scalars;
  the fix keeps copy names under both limits.
- The `.byWords` and Markdown substitutions mean the Linux run says nothing about MarkdownEdits or the inline Markdown view.

## How to rerun on Linux

From a cloud session:
1. Pull `mirror.gcr.io/library/swift:6.2.4-noble` layers (see the session for `pull.py`) into `<root>`.
2. `mount -t proc proc <root>/proc; mount --bind /dev <root>/dev; mount --bind <repo> <root>/work`.
3. Copy `/usr/include/sqlite3.h` in, and link `libsqlite3.so`.
4. Clone GRDB v7.12.0 into `<root>/deps/`.
5. Run `python3 gen.py ""` (fix the two paths at its top first).
6. Run `chroot <root> sh -c 'cd /lk && swift test --scratch-path /tmp/lk'`.
