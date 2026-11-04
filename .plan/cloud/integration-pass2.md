# cloud/integration-pass2

Branch `cloud/integration-pass2`, from `origin/cloud/integration` at f015d12. Pushed only to this branch. No PR, no
force-push. Nothing pushed to `main`, `editor-spike` or `m3-app`. BrainMerge (`Sources/`, `Tests/`, `spec/`, the root
`Package.swift`) is untouched: `git diff origin/cloud/integration -- Sources Tests spec Tools Package.swift` is empty.
Only synthetic fixtures; no real brain content was read or written.

## Plan

Pass 1 merged the eight *kit* branches. It did not merge the four *review* branches that were cut from the same kits
and found real bugs in them. Some of their fixes pass 1 had redone on its own; the others were missing. So:

1. List every commit on a `cloud/*` branch that is not in `cloud/integration` (`git cherry`), and sort each into
   "already there by another route", "missing kit fix", "missing tests", or "App-only / out of scope".
2. Bring the missing kit fixes and tests over, one cherry-pick each (`-x`, so each names its source commit), and
   check every auto-merged hunk by eye against what the other kits changed since.
3. Fix the inconsistencies between kits that are left, with a test each.
4. Bring the plan and review docs in line with what is now true.

## Toolchain: none ran

Pass 1 used Ubuntu's `swiftlang 6.1.3` unpacked into the scratchpad. This session downloaded the same packages, but
running the unpacked binary was refused by the session's permission policy (code from outside the repo). I did not try
to work around that. **Nothing on this branch was compiled or run in this session.** Every change was checked by
reading it against the code it calls. The cherry-picked commits were compiled and tested on Linux (Swift 6.2.4) by
the sessions that wrote them, but against their own bases, not this merge.

## What `git cherry` found

| Branch | Commit | Verdict |
|---|---|---|
| review-links-search-pin | 606701c Moves: GitHub's tree lists folders | **Missing kit fix (High).** Picked |
| | 9dfb0d7 Moves: never clear a landing record that is not the move's | **Missing kit fix (Medium).** Picked |
| | 0866998 Links: two notes onto one path is taken | **Missing kit fix (Low).** Picked |
| | d8c025f Links: U+2028/U+0085 don't end a line | Already there: pass 1 made the same fix, plus `BacklinkIndex` line counting |
| | 2286da4 Pins: no UserDefaults store | Already there: pass 1 removed it the same way |
| | 61d0990 NoteSearch test: limit | Already there (7577eac). The review's version also deleted `Package.resolved`; not taken |
| | 53e23c5 review doc | Picked; L2 marked fixed |
| review-tables-lists | cb6a90e Tables: find tables where GitHub does (cmark-gfm) | **Missing kit fix.** Picked |
| | 7eb2020 Tables: marker-only header under a paragraph | **Missing kit fix.** Picked |
| | 413b10e Lists: a quote or rule ends a list; `- - -`; only 1s are a style | **Missing kit fix.** Picked (auto-merged into `MarkdownEdits.swift` beside pass 1's Linux word finder) |
| | 30f1f81 edge-case tests, plan docs | Picked; one doc conflict in `docs/plan/tables.md`, resolved by keeping both notes |
| | 688683a review notes + parity harness | Picked (dev-only, under `.plan/`) |
| merge-adversarial | 4140718, 8fba81d, bea6f43 | **Missing kit fixes and tests**: `NoteText.frontmatterValue` reads U+2028 / combining-mark names back; `NoteStore.slug` cuts by bytes so a conflict copy's name fits the disk. Picked, no conflicts |
| | eeec606 report + Linux harness | Picked (under `.plan/`) |
| a11y-rtl-audit | fcc6ed9 `DirectionAuditTests` | **Missing kit test.** Took the test file only |
| | 20e12dd, rest of fcc6ed9 | App-only (SwiftUI labels, Dynamic Type). Not merged: it needs an Xcode build to check, and the task is the kit |
| architecture | 7c2523f, d5f1c62 | Docs only. Not merged; it describes `editor-spike` and would need a pass of its own |

### Checked by hand after each pick

- **606701c vs the merged kit.** `FakeGitHub.tree` now lists folders as `isFile: false`, so every consumer of
  `client.tree` sees them. There are three: `SyncEngine` (two calls; both filter `isFile`), `NoteMover` (goes through
  `MoveTree`, which this commit fixes), and the HTTP bridge in `HTTPTests` (sends them as `type: "tree"`, mode
  `040000`). Add to Brain does not read the tree. No test compares `fake.tree(...)` output directly. `GitBlob.sha`,
  `PathKey`, `MovePaths.parent` exist with the signatures used.
- **9dfb0d7.** `PendingPush`, `setPendingPush` (internal; the test file is `@testable`), `beforeNextUpdateRef`,
  `commitRemote`, `MoveProblem.pushPending` all exist unchanged since kit-review.
- **Tables (cb6a90e, 7eb2020).** Only `internal` signatures changed (`tableStarting`, `indent`, `closesFence` gained
  defaulted parameters), all inside `BrainNotesTables`; BrainNotesKit uses the module's public API only.
- **Lists (413b10e).** Pure `NSString`/UTF-16 code, no Darwin-only API, so pass 1's Linux rule holds.
- **merge-adversarial.** Written against `editor-spike`'s `Support.swift`, which no kit branch changed. `slug` became
  `static` internal; both callers are in `NoteStore`. `NoteText.lines` exists.
- **Names.** No two top-level declarations share a name in any target or test target after the picks (scripted grep).

## New on this branch

Each is its own commit with its test, checked by reading only.


- **Links L2: rename destinations clash by the kit's clash key** (4ce0693). `renamePlan` refused a destination only if
  its exact bytes were taken, while `MovePlanner` refuses by `PathIndex`. So `Old.md → PLAN.md` beside `plan.md`, or a
  note moved into `projects/` beside `Projects/`, passed the links plan and would have made two files (or two folders)
  that are one on a Mac. Now the notes that stay go into a `PathIndex`, and two moves onto one path are counted by
  `foldKey`. A case-only rename of the note itself is still allowed. Tests: `destinationsClashAsTheMovePlannerCountsThem`
  and two more lines in `whatIsNotDone`. Each expectation was traced through `PathIndex.clash` by hand. The random
  `everyLinkKeepsItsTarget` property only makes lower-case folders and distinct names, so it can't hit the new rule.
- Docs: `docs/plan/tables.md`'s Linux note described the tables-only manifest, which pass 1 removed. L2 marked fixed in
  `docs/review/LINKS-SEARCH-PIN-REVIEW.md`.

- **Inbox spelled `_Inbox` on GitHub: notes were saved but never shown** (534a31e, High). New notes, captures and
  conflict copies take GitHub's spelling of the inbox (`PathIndex.respell`; `CaptureTests` expects `_Inbox/Newer.md`),
  but `PathPolicy.isVisible` matched `_inbox` by exact bytes. So such a note was pushed but never indexed: missing from
  every list and from search. `MovePlanner` already matched the inbox by `foldKey`. Both now use a new
  `PathPolicy.isInbox`. Tests: four more `isVisible` cases in `PolicyTests`, and `theInboxKeepsTheSpellingGitHubHas`
  now checks the capture is in the index. **App follow-up, not done:** `AppModel.swift:289,291` and the Inbox list
  (`RootView.swift:91`, folder `"_inbox"`) still compare by bytes, so these notes now show under an `_Inbox` folder,
  not in the Inbox view. That needs an App change and an Xcode build.
- **A move the engine finishes kept no pin** (482f210, Medium). On `.unconfirmed` the mover leaves its landing
  record for the engine and moves no pins. The record had no effects (a move has no outbox op), so `land()` emitted
  no `.noteMoved`, and `Pins.apply`'s next idle snapshot dropped the pin as missing. The record now carries the
  move's from/to pairs (`LandingPlan.moves`, optional so an old record still decodes) and `land()` reports each.
  Test: `anUnconfirmedMoveKeepsItsPinOnceTheEngineLandsIt`.
- `DirectionAuditTests` from the RTL audit (3f258ce): the editor's `isRightToLeft` and the reader's `MarkdownBlock`
  agree on 15 paragraphs, now that list work changed `MarkdownEdits`.

## Cross-kit audit: found, left open

A read-only audit compared the kits against each other (search folding, path rules, line breaks, fences, front
matter, pins). Line breaks, front matter and path *legality* came out consistent. Fixed above: the `_Inbox`
visibility and the unconfirmed-move pin. Left open, because each is a product decision or changes the editor:

- **Fences, two rules (Medium).** `FencedCode` (editor), `WikiLinks` and `NoteText`'s blocks look at three characters
  and close on any indent or trailing text. `TableSyntax` and BrainMerge follow CommonMark (closing fence at least as
  long, nothing after it). With ```` ```` ```` / ```` ``` ```` / `[[Plan]]` / ```` ```` ````, Links finds `[[Plan]]`
  (so a rename would edit text inside a code block), the editor treats the inner lines as text, and Tables and
  GitHub treat all of it as code. The editor's rule is deliberate and pinned by tests (`   ```` ```` ```` closed by a
  6-space fence in `LinksEditorAgreementTests`). Suggest: move `FencedCode` and `WikiLinks` together to the
  CommonMark rule in one change, with the agreement test extended; it needs a Mac run of the editor tests.
- **Two search engines, different matches (Medium, latent).** The App uses the old GRDB `SearchIndex`. `NoteSearch` is
  not wired. They differ: `מלך` finds `מלכים` (final letters) and `צהל` finds `צה״ל` only in NoteSearch; `ים` after
  `ה` and in-word `plan` in `explanation` too. Decide which one wins before wiring; to keep the old one, run
  `SearchText.normalize` over what it indexes and over the query.
- **Link names fold with `lowercased()`, paths with `foldKey` (Low).** `[[STRASSE]]` doesn't find `Straße.md`, though
  the two names clash as paths.
- **New-note names skip Capture's safeguards (Low).** `NoteStore.notePath` has no 180-byte cap and no Windows
  device-name rename (`CON.md` from the editor, `_inbox/CON-note.md` from Capture).
- **`name 2.md` (moves) vs `name-2.md` (new notes, captures) (Nit).**
- Still open from the links review: L3–L9, including that the mover is not mutually exclusive with the engine (L9).

## Not verified

- **Nothing compiled or ran in this session** (see Toolchain). The likeliest failures are compile-level: a picked
  commit's code meeting a pass-1 change it was not written against. I checked each by reading, which is not a build.
- Everything pass 1 listed as unverified still is: no Mac, no `xcodebuild`, no Swift 6.2 on the merged tree, App not
  wired to the new kit pieces, nothing against real GitHub.
- The review branches' Linux results (Swift 6.2.4) were on their own bases. Pass 1's 614-test run was before these
  picks; the count now is higher by the picked and new tests.

## Before merging

```sh
cd Packages/BrainNotesKit && swift test
bash scripts/verify.sh
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' build test
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Suites to watch first: `NoteMoverTests`, `MovePlannerTests`, `RenamePlanTests`, `GitHubParityTests`,
`MarkdownEditsTests`, `AdversarialMergeTests`, `AdversarialSyncTests`, `LinksEditorAgreementTests`.
