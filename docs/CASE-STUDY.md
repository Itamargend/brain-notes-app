# Brain Notes: a case study

A notes app for iPhone and Mac whose only storage is a folder of Markdown files in a GitHub repository. This document
covers why it exists, the product choices, the engineering problems that turned out to be the real work, and what is
still unproven.

Every number here comes from the test suite. Nothing was
measured for this document.

## 1. The problem

A second brain kept as plain Markdown in git is a strong foundation. Every tool can read it: scripts, full-text search,
AI agents that file and link notes, diffs and history. It has one weak point: the phone. The moment an idea arrives
away from a laptop, the options are a git client built for developers, or a notes app with its own sync that quietly
becomes a second source of truth.

The goal: **one source of truth (the repo), and a phone experience as calm as Apple Notes.** Open, type, leave. Sync
is the app's problem, not the user's.

## 2. Product principles

1. **The repo is the truth.** The device holds a copy it can always rebuild. Nothing about the notes lives only in the
   app.
2. **Typing never waits.** A save is a local write plus one journal row. The network is never on the typing path.
3. **No text is ever thrown away.** Not by a merge, a delete, a race, a crash, a sign-out or a restore. When the app
   can't decide, it keeps both versions and asks.
4. **Every byte is kept.** A note the user didn't touch is never rewritten; a note they did touch changes only where
   they typed. Line endings, frontmatter, Unicode spelling of names: all preserved.
5. **Calm.** One accent colour (slate blue), SF Symbols only, sentence-case titles, status as a quiet dot or icon, not a
   banner. Problems go to one place, Needs attention, with plain choices: Keep both, Use this one, Restore.
6. **Bilingual from day one.** Hebrew and English side by side: right-to-left per paragraph, search that understands
   Hebrew prefix letters and vowel points.

### Choices the product made

- **Conflicts become a file, not a modal.** A clash produces `_inbox/conflict-<note>-<time>.md`, holding the whole of
  this device's version under a small YAML header. It syncs like any other note, so a laptop, a script or an agent can
  resolve it too. The phone shows it in the Inbox and in Needs attention with both versions side by side.
- **Deletes are soft.** Deleting a note writes `_trash/<path>` in the same commit. A delete of a note someone else has
  since edited is skipped, and the user is told.
- **Onboarding has an exit that needs no account.** "Try with Sample Notes" opens 48 synthetic notes on an in-process
  fake GitHub, with no network and no Keychain. Connecting GitHub later throws the sample folder away and never touches
  the real one.
- **Where design mockups and the written plan disagreed, the plan won** (sentence case, "Open My Notes" rather than
  "Start Writing", no tip card).
- **Future ideas intentionally kept out of v1:** Face ID per-folder lock, an iOS "Add to Brain" App Intent, and backlink graph views. The core local-first sync and merge loop came first.

## 3. Architecture in one paragraph

A SwiftUI app (one multiplatform target, iOS 26 and macOS 26) sits on **BrainNotesKit**, which owns the files on disk,
a SQLite journal (via GRDB, the only dependency, pinned exactly), a rebuildable FTS5 search index, and a sync engine
written as a Swift actor. The engine talks to GitHub through a `GitHubClient` protocol with two implementations: the
real HTTP client and `FakeGitHub`, an in-process actor with blobs, trees, commits, a compare-and-swap `main` ref, ETags
and injectable failures. Merging is delegated to **BrainMerge**, a pure Swift package with no dependencies. Layout overview
is in the [README](../README.md#repository-layout).

## 4. Engineering: where the real work was

### 4.1 Use the Git Data API, not git

A git implementation on a phone means packfiles, an object database and a lot of surface. GitHub's Git Data API offers
exactly what a notes app needs: read a tree, read a blob, write a tree on top of another tree, write a commit, and move
a branch with compare-and-swap (`force: false`). One user save batch becomes one atomic commit.

The cost is coupling to GitHub's API semantics, which is where the first real bug hid (4.4).

### 4.2 Specify the merge before writing it

Merging Markdown three ways is where notes apps lose text. So the merge was written as a spec first
([`merge-spec.md`](merge-spec.md)), with:

- a **TypeScript reference** implementation;
- **hand-written vectors** whose expected outputs are typed from the spec, never computed by the code under test;
- a **Swift port** that must pass the same JSON files, unchanged;
- a **differential test** that runs thousands of generated cases through both implementations and requires identical
  output.

The rule at the centre: a note is split into blocks (frontmatter, preamble, one block per heading). Each block merges
three ways. Clean blocks merge; a clashing block keeps GitHub's text; this device's whole version goes to the `_inbox`
copy. A line-count safety check runs on every merged note: no added line lost, no invented line, no line duplicated
or dropped beyond what the two sides agreed. If the check fails, the merge falls back to "keep GitHub's text, copy
mine". It can be conservative; it can't lose a line.

Result on the last full run: **110/110 vectors and 9,637 differential cases** match the reference.

Independent reviews by other models found real holes: overlapping operations on one path in a single batch could
overwrite an edit, a merge could drop a line that all three sides had, a merge could push a note over the size limit.
Each fix went into the spec, the reference, a new vector and the Swift port together, and none changed an existing
vector's expected output.

### 4.3 Unicode is a correctness problem, not a display problem

Two traps that would each silently damage notes:

- **Swift's `String ==` is too clever.** It treats NFC and NFD spellings as equal and `\r\n` as one character. A merge
  that compares lines that way would "fix" notes nobody asked it to touch. BrainMerge compares exact bytes and UTF-16
  code units, the way the JavaScript reference does (`ExactText.swift`).
- **GitHub can hold files a Mac or iPhone can't.** `Straße.md` and `STRASSE.md` are two files in git and one file on
  APFS. The planner uses a clash key built to match APFS's case and normalisation folding, checked against real APFS
  behaviour on the development Mac. A note the device can't hold stays on GitHub only,
  listed in Needs attention, and commits leave it alone.

### 4.4 Losing a response is the hard case

A commit request that times out may or may not have landed. Guess wrong and you either push a duplicate or drop the
user's text. The engine:

1. writes the commit sha and exactly what it means for the device to the journal **before** moving the ref;
2. after a timeout, a 5xx or a kill, enters **Verifying**: reads the ref and asks GitHub whether the commit is in
   main's history;
3. landed → finishes applying it; not landed and main unchanged → retries the same sha; main moved → drops the commit,
   and the ops, still safe in the outbox, are planned again on the new head.

The commit date, author (`Brain Notes <brain-notes-app@noreply.invalid>`) and message are fixed by the operation, so a
retry builds the identical sha.

**The plan had this check backwards.** It said that GitHub's compare status `behind` meant the commit had landed.
`behind` means the head is *before* our commit, so it has not. An earlier spike measured `ahead` on a landed commit,
and GitHub's documentation agrees. The code follows the evidence, and a test named `behindDoesNotCountAsLanded` keeps
it that way.

### 4.5 Typing during a push

A user can type into a note while its previous version is being pushed. The note stays dirty, based on what was
pushed, so the next push merges against GitHub's side instead of overwriting it. Saves also carry the text they
started from (`editingFrom`), so an editor holding stale text merges with a sync rather than clobbering it.

### 4.6 Guardrails in code, not in policy

Syncing a personal knowledge base needs hard limits, and they are enforced in code with automated policy tests (`SourceRulesTests`):

- **One verified private repository.** Each session locks onto the single private repository (by numeric GitHub `repoId`) chosen by the signed-in user from their GitHub App installation. `RepoTarget.guardURL` refuses public repositories and blocks any request outside `/repositories/<repoId>/...` or GraphQL commit timestamps.
- **Never force.** Ref updates always send `force: false`; a race costs a pull, a merge and a retry (up to three, with
  1 to 4 s of jitter), then Needs attention.
- **Secrets stay out.** Tokens only in the hardware Keychain; Device Flow, so there is no client secret anywhere; no URL cache
  on disk; redirects followed only to GitHub's tarball host, without the Authorization header; paths and text redacted in logs.
- **Secret scan on new text.** API commits skip the repo's hooks, so the app checks newly added text and blocks the
  commit. A secret already on GitHub doesn't block, or that note could never be edited again.

### 4.7 An editor that never changes the file behind your back

The editor renders notes in place using TextKit 2: the file stays plain Markdown byte for byte, while syntax delimiters stay tucked behind the scenes so writing feels like Apple Notes. The marks remain in text storage as zero-width attributes, so caret positions, selection, copy, undo, saving and sync preserve the exact source bytes. The Markdown parsing (`MarkdownInline`) and formatting actions (`MarkdownEdits`) are pure functions in the kit, from text and selection to one replacement, so each action is one undo step and unit-tested offline.

## 5. How it is tested

| Layer | Approach |
|---|---|
| Merge | Hand-typed vectors, a TypeScript reference and a differential run against it |
| Sync engine | Runs against `FakeGitHub` in-process, plus an HTTP-level fake for the wire format; chaos and fuzz suites inject failures and random edits; a test against real git checks the tarball reader |
| Reviews | Findings from independent reviews each became a permanent regression test (`ReviewFindingsTests`) |
| Onboarding | Mutation checks: eight routing rules were each broken alone in a throwaway worktree, and each break was caught by the test meant to catch it |
| Screens | `ScreenWalkTests` shows every screen in a real window from inside the app, types through the real text view and presses buttons through the accessibility tree |
| Scale | `ScaleTests` runs the engine at the real brain's size |

Full test suite: BrainMerge 14 tests; BrainNotesKit **318 tests in 46 suites**; the Mac app
**in-process and UI tests**. `ScaleTests` on the Mac in a debug build: first sync 4.2 s, search 2 ms, pull,
merge and push of a 271 KB note 250 ms.

## 6. Roadmap ideas

1. Backlink panel showing incoming `[[wiki-links]]` across folders.
2. iOS Share Sheet & Shortcuts ("Add to Brain" App Intent) for 1-tap capture from Safari or voice memos.
3. Optional Face ID / Touch ID app lock.

## 7. Lessons

- **Write the spec, then two implementations, then make them argue.** The differential test found holes that the
  hand-written vectors missed.
- **Believe the measurement over the plan.** The reversed "landed" check could have marked a commit that never landed
  as done, or pushed the same change twice, after a lost response.
- **"No text is ever lost" is a design constraint, not a feature.** It decided the conflict-copy format, soft deletes,
  the journal-before-ref order, keeping text in the outbox, and what sign-out does.
- **Write down what isn't verified.** The status file lists gaps next to results, which is what makes the results
  believable.
