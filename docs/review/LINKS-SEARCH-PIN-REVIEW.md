# Review: links, search, moves and pins

Scope: second-pass review of `cloud/links-kit` (97ae4a9), `cloud/search-kit` (7fbd51f) and `cloud/move-pin-kit`
(7a8ca1f), all from `editor-spike` f6e792a, merged on `cloud/review-links-search-pin`. Every source file of the three
branches was read in full, plus the kit code they lean on (`MarkdownInline`/`FencedCode`, the HTTP client's `tree`,
`FakeGitHub`, the engine's pending-push handling). BrainMerge was not touched.

**This time the code ran.** Swift 6.2.4 (the official `swift:6.2-noble` image, pulled from a registry mirror and run in
a chroot) on x86_64 Linux. What ran where is in "Verification" below.

Severity: **High** breaks a feature or loses data on a normal path. **Medium** is a real bug a user can hit.
**Low** is an edge case or a cost. **Nit** is cosmetic.

## Summary

| ID | Sev | Branch | Finding | Status |
|----|-----|--------|---------|--------|
| H1 | High | move-pin | Against GitHub's real tree, every note move into an existing folder fails (`notAllowed`) and every folder move with a subfolder fails (`leftBehind`). The fake never listed folders, so no test saw it | Fixed + tests: 606701c |
| M1 | Medium | move-pin | The mover can overwrite, then clear, the engine's own `pending_push` record if a sync gets in while it waits on GitHub | Fixed + test: 9dfb0d7 |
| M2 | Medium | move-pin | `UserDefaultsPinsStore` fails the kit's own policy test and outlives sign-out's wipe | Fixed (removed): 2286da4 |
| M3 | Medium | links | U+2028 and U+0085 ended a link's line; the editor's paragraphs don't end there, so the two parsers disagreed | Fixed + test: d8c025f |
| L1 | Low | links | `renamePlan` let two notes move onto one path | Fixed + test: 0866998 |
| T1 | Test | search | `manyThreadsAtOnce` expected 528 results from a search whose limit defaults to 50 | Fixed: 61d0990 |
| L2 | Low | links | `renamePlan` compared destinations by exact bytes, not by clash key | Fixed + tests on `cloud/integration-pass2` |
| L3–L9 | Low/Nit | all | Below | Open |

## High

### H1. Moves and GitHub's tree listing

`GitHubHTTPClient.tree` asks for `git/trees/<sha>?recursive=1`. GitHub's answer lists every folder too, as a
`type: "tree"` entry, which the client keeps with `isFile: false`. `FakeGitHub.tree` listed files only. The planner
was written and tested against the fake's shape:

- `MoveTree.index()` put every entry's path into the clash index, folders included. A folder entry `people` taken as
  a *file* clashes with every path under it, so `MovePlanner.free("people/beta.md")` tried `beta 2` ... `beta 999`,
  all "taken", and threw `notAllowed`. **Every note move into an existing folder failed.**
- `MovePlanner.folder` put every non-file entry under the folder into `left`. **Every folder with a subfolder** was
  refused as `leftBehind([subfolder])`.

**Fix:** a non-file entry with something under it is a folder: it takes no name and does not stay behind. A submodule
or symlink (nothing under it) still stays behind. `FakeGitHub.tree` now lists folders as GitHub does, and the HTTP
test bridge sends them as `type: "tree"`, so every mover *and engine* test runs against the real shape. With the
fake fixed and the planner not, 13 `NoteMoverTests` failed; with both, the move, pin, HTTP, engine, sync, chaos and
session suites pass (245 tests). The engine already filtered with `isFile`, and still passes.

## Medium

### M1. The mover and the engine's landing record

`NoteMover.commit` checks `pendingPush() == nil` in `remoteState`, then awaits `getCommit`, `tree`, blobs,
`createTree` and `createCommit` before it writes its own record. Nothing stops the engine meanwhile: the doc says
"call it while the engine is not running a sync", but the timer and `noteSaved` can start one. If the engine's push
wrote its record in that window, the mover replaced it; and on a 422 or a refused answer, the mover cleared whatever
record was there. The engine's next run then had nothing to verify its commit by.

**Fix:** re-check right before writing (`pushPending` if a record appeared), and clear only a record whose commit is
the move's. Test `aLosingMoveLeavesTheEnginesRecordAlone`; it fails with the old unconditional clear.

**Still open (Low):** the mover is not mutually exclusive with the engine. The best fix is to run a move inside the
engine's actor (an `engine.perform { }` that waits for the run in flight and holds off the timer), so the
"call while idle" rule is enforced, not documented.

### M2. Pins in UserDefaults

`PolicyTests.noClientSecretAndNoTokenInUserDefaults` allows `UserDefaults` only in `AppModel`; `Pins.swift` failed it
(on every platform). The store also kept a signed-out repo's note paths unless the app remembered `clear()`.
`FilePinsStore` lives in the store root and goes with sign-out's wipe, and it is the one the plan wires. Removed the
defaults store and its tests.

### M3. Where a link's line ends

`WikiLinks.isLineBreak` said "the same paragraph breaks as NSString's" but included U+2028 and U+0085.
`.byParagraphs` breaks only at `\n`, `\r` (and CRLF) and U+2029, so `[[a<U+2028>b]]` is a link in the editor and was
not one here: no backlink, and a rename would leave it behind. `LinksEditorAgreementTests.handPickedCases` caught it
on its first run (Linux Foundation, which follows CoreFoundation's paragraph rule). Run it on a Mac to confirm Apple's
Foundation agrees; if it doesn't, the editor and the kit disagree on Apple, which is the case that matters.

## Low and nits (open)

- **L2 (links), fixed on `cloud/integration-pass2`.** `renamePlan`'s `destinationTaken` compared exact bytes, so `Old.md` → `PLAN.md` beside `plan.md`
  passes; on a case-insensitive disk the two are one file. `MovePlanner` already counts by clash key, so this only
  matters if `renamePlan` is used without it. Suggest: check with `PathIndex` there too.
- **L3 (links)** A full-path link written with a leading slash, `[[/a/Note]]`, is rewritten without it.
- **L4 (links)** A file name with spaces at either end resolves but can't be written (the parser trims), so every link
  to it is `unwritableName` on a rename.
- **L5 (links)** `\\![[x]]` (an escaped backslash, then `!`) is read as not an embed. Nit.
- **L6 (search)** Each query walks the whole vocabulary. Measured: 4–22 ms per query in release, 100–300 ms in debug,
  at 2,000 notes of 2 KB on x86_64 Linux; build 0.47 s release. Fine on a Mac; unmeasured on an iPhone. If it
  becomes a problem, a sorted term list answers prefix matches by binary search.
- **L7 (search)** The snippet shows `\n`, `\r`, `\t` as spaces but not U+2028, U+2029 or U+0085. Nit.
- **L8 (moves)** A moved file is sent as `.content(text)`, so an executable file (`100755`) arrives as `100644`.
  Notes are rarely executable. Nit.
- **L9 (moves)** See M1: exclusivity with the engine is a convention, not code.

## Verification

Linux, Swift 6.2.4, on this branch:

- `cd Packages/BrainNotesKit && swift test`: the Linux manifest (Links + NoteSearch): **123/123 pass**.
- `swift test -c release -Xswiftc -enable-testing --filter SearchScale`: the timings in L6.
- `bash scripts/verify.sh`: **110/110 vectors pass**, and every differential suite but one: "nfc, foldKey and
  checkPath" differs on 28 cases, all case folding of letters new in Unicode 16 (U+A7CE, U+16EA0, ...): Linux
  Swift 6.2.4's tables against the TypeScript reference's. BrainMerge is not changed on this branch; this is a
  Linux-only observation.

Linux, Swift 6.2.4, in a throwaway worktree (never pushed) with `cloud/kit-review`'s Linux port merged in, to run the
code that needs the full kit:

- `cloud/kit-review` does **not** compile on Linux as pushed: `MarkdownEdits.swift` uses `.byWords`
  ("unavailable in swift-corelibs-foundation") and `SyncEngine.swift:220` sends a closure that captures a weak
  actor reference ("passing closure as a 'sending' parameter"). Two local patches got it building; they are not on
  this branch.
- With them: MovePlanner, NoteMover, Pins, HTTP, Engine, Sync, Chaos, Session and Links suites: **245/245 pass**.
- The full kit's other Linux failures are all in code these three branches don't touch: MarkdownEdits (the `.byWords`
  patch), `FencedCode.hasFenceLine`, `PolicyTests` backup exclusion and NFC lookups on ext4, and the SQLite search
  speed test (4.3 s against a 0.1 s budget, debug build).

**Not run:** anything on Apple platforms. Before merging, on a Mac:

```
cd Packages/BrainNotesKit && swift test
bash scripts/verify.sh
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' build test
```

`LinksEditorAgreementTests` (M3) and `NoteMoverTests` are the ones to watch.

## Merging

- `Package.swift`: links-kit and search-kit each made a Linux-only manifest; the merge declares NoteSearch everywhere
  and, off Apple, BrainNotesKit limited to `Links/`. Once `cloud/kit-review`'s port compiles, drop the `#else` branch
  and declare everything everywhere (kit-review's test target also needs GRDB).
- `FakeGitHub.swift` and `HTTPTests.swift` also differ in `cloud/kit-review`; the H1 hunks are small and apart from
  kit-review's.
