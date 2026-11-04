# Brain Notes: how it was built (case study, draft)

> **Draft.** Every claim below comes from the repository's `.plan` session reports or from its git history (commit
> messages, dates, branches). Each claim names its source: a short commit hash such as `6ac12de`, or a plan file
> such as `integration.md`, short for `.plan/cloud/integration.md` on the branch of the same name. Anything marked
> **(uncertain)** or listed under "Not verified" is not established. The main planning document, `.plan/A-app.md`,
> is kept off git, so the *why* behind scope and budgets is mostly missing here. Nothing was re-run for this draft.

## 1. The short version

Brain Notes is a native SwiftUI app for iPhone and Mac (iOS 26+ and macOS 26+). It edits a folder of Markdown notes
stored in a GitHub repository, works offline first, and syncs through GitHub's Git Data API rather than through git
(`CLAUDE.md`).

The git history covers about **28.5 hours of wall-clock time**: from the first commit (3 Nov 2026, 18:43 +0200) to
the last (4 Nov 2026, 23:14 +0200). In that time it went from a written merge spec to:

- a merge library checked against a reference implementation;
- a sync engine and app reviewed several times;
- an Obsidian-style Live Preview editor;
- fourteen parallel cloud branches, which added and then reviewed six new features.

The work was done by the owner directing AI coding agents. The habit that runs through all of it is that every
session writes down what it verified and what it did not.

That 28.5 hours is the span between commit timestamps, not a measure of effort. How much work came before the first
commit, which is titled "Starting files", is not recorded **(uncertain)**.

## 2. The problem and the constraints

**What the repo states** (`CLAUDE.md`): notes are plain Markdown in a GitHub repo. The app keeps a full local copy and
syncs with the Git Data API. A purpose-built library, `BrainMerge`, merges a note when both sides have edited it.

**What the repo does not state:** why the app exists, who it is for beyond its owner, or what it was measured
against. That reasoning lives in the off-git plan. The architecture session noted the same gap: two of its fourteen
decision entries have "no recorded alternatives in the repo" (`architecture.md`).

**The hard rules**, set before the app code was written (`6dc33a7`, `CLAUDE.md`):

- The app talks **only** to one test repository, and any other repository is refused in code and in tests.
- A branch update always sends `force: false`.
- Tokens live only in the Keychain. There is no client secret, and the client ID is never logged or committed.
- Fixtures contain only synthetic content.
- GRDB, at an exact pinned version, is the only third-party dependency.
- BrainMerge's behaviour cannot change unless `scripts/verify.sh` stays green.

These rules shaped later decisions. In the sources available, they read as a safety perimeter for a prototype that
syncs someone's knowledge base, and none of them reads as a product feature.

## 3. Timeline

Times are the committer's local time: +0200 for the owner's machine, UTC for the cloud sessions.

| When | What happened | Source |
|---|---|---|
| 3 Nov, 18:43 | **Spec first.** `merge-spec.md`, a TypeScript reference merge, hand-written vectors and a vector generator. 2,855 lines, no app code | `3ebc2bd` |
| 3 Nov, 20:30 | Swift port of BrainMerge passes **73/73** vectors, plus differential tests and a benchmark | `1c23bf4` |
| 3 Nov, 20:45–23:02 | Three rounds of fixes. The first two are F1/F2: a final guard that ignored deletes, and a case-fold clash key rebuilt to match how Apple's file system folds names. The third answers an **independent review by a different AI model**, F-01 to F-07: coalescing, line floor, NFC trash, size after merge, folder clashes, work budget, invisible characters. Then a second review's follow-ups (P48–P57). Each fix lands in the spec, the reference and the vectors together | `d478c82`, `07d7af4`, `b1b316b` |
| 4 Nov, 10:28 | Rules file for coding agents, and local plans git-ignored | `6dc33a7`, `7de04fd` |
| 4 Nov, 10:39 | A first kit run is committed as WIP and "stopped to switch model" | `9f0bd22` |
| 4 Nov, 11:31 | Kit foundations reworked: HTTP client with the repository guard on every request, an in-process fake GitHub, note store, sync engine. **172 tests**, including kills at every API call and random runs | `6ac12de` |
| 4 Nov, 12:02–12:18 | All planned screens on iPhone and Mac. A demo mode runs the real engine against the fake GitHub. A scale test on **2,434 notes**, one of them 271 KB. The tar reader is checked against real `git archive` output | `8a1e502`, `d1257dd`, `c1de7d9` |
| 4 Nov, 12:50 & 14:11 | **Two independent review passes on the engine**, each fix with a regression test. The reviewer's fuzz becomes permanent: 13 configs × 200 seeds | `b9e972f`, `be79d43` |
| 4 Nov, 15:53–16:57 | Onboarding with a no-account "sample notes" path, tested at every moment of launch. Status file updated. **This commit is `main` and `m3-app` today** | `f0ae062`, `b2993d1`, `be9bdec` |
| 4 Nov, 17:45–20:48 | **Editor spike**, tried on the phone, then rebuilt as Live Preview. Keyboard bar, Mac Format menu, status icons, New Folder. Mutation checks on the editor tests, then fixes from an independent review | `6df2652` … `f6e792a` |
| 4 Nov, 19:11–21:14 UTC | **Fourteen cloud branches** from `f6e792a`. Six feature kits (tables, lists, links, search, move/pin, Add to Brain), a kit review, a README and an architecture doc. Then an integration branch and four review or audit sessions | `cloud/*` branches |

Count: 106 commits. 30 are authored on the owner's machine, 21 of them with an AI co-author trailer, and 76 are by
the cloud agent. `main` and `m3-app` point at the same commit (`be9bdec`). `editor-spike` is 10 commits ahead of
them. None of the cloud work is merged into those three branches.

## 4. Decisions with a recorded reason

Only decisions whose reason is written in a commit or a plan doc are listed here.

| Decision | Recorded reason | Source |
|---|---|---|
| Write the merge as a spec, with a reference implementation and vectors, before the Swift code | The first commit is the spec, vectors and reference. The port must pass them, and differential tests compare the two | `3ebc2bd`, `1c23bf4` |
| One commit's fixes go into spec, reference and vectors together | Visible in every S3 fix commit (`d478c82` lists all three layers) | `d478c82` |
| Live Preview: hide Markdown marks except where the caret is | "Replaces f2's 'dimmed, never hidden', on the owner's request after the phone test." The file stays byte-for-byte Markdown. Marks stay in storage, so caret, undo, copy and sync see every byte | `04a9281` |
| Keyboard bar as a plain full-width view, not a `UIToolbar` | "A UIToolbar draws floating glass pills on iOS 26, which is what the phone test showed" | `04a9281` |
| Apple's Writing Tools stay in their panel, never in place | An in-place rewrite runs while autosave carries on, and it treats the hidden marks as text, so "a half-done rewrite could reach the file" | `f6e792a` |
| Empty folders stay on the device until their first note | Git has no empty folders, and the path check accepts only `.md` files, so a `.gitkeep` could never be sent. Choosing this keeps BrainMerge untouched | `40348f7`, `e3a227d` |
| UserDefaults only in `AppModel`, only for two yes/no flags | The earlier source rule banned the word everywhere. It was narrowed on purpose and a test holds the new rule. Tokens stay in the Keychain | `f0ae062` |
| No UserDefaults store for pins | It failed the policy test above, and its key outlived sign-out's wipe. The file-based store, which the wipe deletes, stays | `integration.md`, `2286da4` |
| Tables and lists follow GitHub's renderer (cmark-gfm), not a looser reading | What GitHub shows is what the note *is*. Expected test values were taken from cmark-gfm itself | `docs/plan/tables.md`, `review-tables-lists.md` |
| Hebrew prefix-letter search keeps at least three letters after stripping (two after ה) | To keep false positives low: `מים` is not `ים`, `כלב` is not `לב` | `docs/plan/search-kit.md` |
| "Add to Brain" captures through the same save path as typing | The capture is in the outbox at once, shows in the Inbox at once, and is pushed online or later | `docs/plan/add-to-brain.md` |

**Recorded as undecided** (`architecture.md`): the reasons for using the Git Data API instead of libgit2, and for
syncing only while the app is open, are not in the repo. The off-git plan may hold them **(uncertain)**.

## 5. Engineering stories

### 5.1 A merge that may be conservative but may not lose a line

The merge library came first and was built to be argued with. It has three parts: a spec, a TypeScript reference, and
hand-written vectors, followed by a Swift port and differential runs between the two (`3ebc2bd`, `1c23bf4`). It
passed 73/73 vectors on the first port. The rules file now records **110/110 vectors and 9,637 differential cases**
(`CLAUDE.md`), which means the reviews added cases as they went.

The later adversarial session (`merge-adversarial.md`) added hostile inputs:

- CRLF, lone CR and mixed line endings;
- NFC/NFD spellings, and Hebrew niqqud in non-canonical order;
- bidi marks and ZWJ emoji;
- the 2,000-block and 1 MiB limits;
- a 3,200-case seeded fuzz that asserts it actually reaches clean merges, conflicts and CRLF notes, so it can't pass
  by doing nothing.

Every comparison is by bytes, never by Swift's `String ==`.

It found one data-loss path outside the merge itself. A conflict copy's name was cut to 150 *characters*. A Hebrew
name with niqqud, or a name in emoji, fits the disk, but its copy name may not: one test reached 274 bytes. So a
second window's text could be lost, and recovery after a rewritten history never finished. The fix cuts names by
UTF-8 bytes on character boundaries (`8fba81d`). The session confirmed that each new test failed with the fix stashed.

### 5.2 Reviewing the sync engine until the reviews ran dry

The engine had two independent review passes inside 90 minutes (`b9e972f`, `be79d43`). What they found shows where
sync loses text:

- A second save of a draft could overwrite another writer's note.
- A case-only rename on GitHub could overwrite a dirty note's file.
- A commit "of unknown fate" lost its operations across a relaunch.
- A name too long for the disk stopped sync for good. Now it stays on GitHub with a Needs attention item.
- A ref that kept refusing spent write calls on every poll. Now it waits 5 minutes, doubling to an hour.

Each fix came with a regression test. The second pass's random-interleaving fuzz became a permanent suite (13 configs,
200 seeds each).

The cloud kit review found more (`cloud/kit-review` commits):

- Sign-out-and-wipe didn't wait for a sync already running, so a first sync could write every note back after the
  wipe (`034e836`).
- A timer tick just before `stop()` could still start a run (`e1d6c7e`).
- Every autosave did a full scan of all note text to update the search index (`fd3aa7e`).

### 5.3 Tests that were caught lying

Twice, the owner's sessions checked whether the tests could fail at all:

- **Onboarding** (`b2993d1`): `testAReloadInFlightDoesNotCrossSessions` "passed with the guard it exists for removed",
  so it was rewritten to start mid-flight. A test named for a device code reading left to right "never checked that".
  Its replacement reads the code back from the window's pixels, with the English layout as a control.
- **Editor** (`39dc92e`): mutation checks found three bugs the suite would miss: an action merged into the typing
  before it, a composition being restyled, and a selection not restored. Each is now caught.

One commit owns up to a gap of its own. A CRLF fix "went in with this test failing, since it was checked only through
the app's tests" (`aa08670`).

### 5.4 An editor that is allowed to change the look but never the file

The Live Preview editor (`04a9281`) hides Markdown syntax but keeps every byte in storage, and tests prove that
rendering alone never changes the file. The hard parts in the history are small and concrete:

- UIKit resets a paragraph's writing direction after an edit's selection callback, so styling has to wait. This was
  found on real UIKit through a Catalyst harness (`04a9281`).
- A hidden marker takes no room, so a tap could put the caret in front of `# `. The next keystroke would then end the
  heading (`9790f9f`).
- A sync reload kept the old text's undo steps, which would replay into the new text and write wrong bytes. It also
  kept a caret offset that could land inside an emoji (`f6e792a`).
- On the Mac, any press in the checkbox margin ticked the box, including drags and double clicks (`f6e792a`).

### 5.5 Matching GitHub, measured against GitHub's own parser

The tables kit was written in a session that couldn't install Swift at all. So it mirrored the parser in JavaScript
and ran 600,000 random notes and 840,000 edits on the mirror (`docs/plan/tables.md`).

The review session then got a real toolchain and used **cmark-gfm**, the parser GitHub renders with, as an oracle
(`review-tables-lists.md`). The first differential found **1,510 disagreements in 20,000 notes**. For example, a table
pasted under a list item with no blank line is not a table on GitHub. After the fix there were **0 wrong finds in
240,000 notes** and **0 disagreements in 30,000 edited notes**, compared cell by cell. Two old test expectations
turned out to be wrong by GitHub's reading and were corrected.

The links/search/pin review found the most serious cloud bug (`review-links-search-pin.md`, `606701c`). GitHub's tree
lists folders as entries, the planner took them for files, and so **every note move into a folder and every folder
move with a subfolder would break**. The fake GitHub hadn't listed folders, which is why tests had passed. The fix
was to the fake, so it now behaves like the real API.

### 5.6 Getting a compiler in a locked-down sandbox

Every cloud session ran behind a proxy that refused `download.swift.org`. The sessions found three ways around it:

- Docker image layers pulled by hand from a mirror and run in a chroot (`merge-adversarial.md`);
- the same layers run straight from the host, when the chroot was refused (`review-tables-lists.md`);
- Ubuntu's Swift 6.1.3 package unpacked with `dpkg -x` (`integration.md`).

The Linux runs turned up two things a Mac alone would not have shown:

- Linux Foundation enumerates paragraphs differently. The fix was that the links parser now ends a line exactly where
  the editor does (`d8c025f`).
- 28 path-folding differential cases fail on Linux because its Unicode tables are older than Unicode 17. The merge's
  clash key follows the operating system's Unicode tables, which is a fact worth knowing for portability
  (`merge-adversarial.md`, `integration.md`).

## 6. Verification ledger

| Claim | Where it ran | Source |
|---|---|---|
| BrainMerge 110/110 vectors, 9,637 differential cases | Mac (stated in the rules file; run not shown in history) | `CLAUDE.md` |
| Same, on Linux: 110/110 and 9,609 of 9,637 (28 misses from Unicode 17 tables) | Linux, Swift 6.1.3 | `integration.md` |
| Integrated kit: **614 tests in 68 suites, 612 pass**. Both failures are timing budgets under parallel load and pass alone | Linux, Swift 6.1.3 | `integration.md` |
| Kit tests 239 and Mac app tests 312, plus scale timings | Mac, per `App/STATUS.md`. "Copied … not re-run" | `architecture.md` |
| Adversarial suite: 399 kit tests on a Linux copy. The set of failures is identical before and after; all are Linux artifacts | Linux, Swift 6.2.4 | `merge-adversarial.md` |
| Tables 63/63; list tests 89 run, all pass | Linux, Swift 6.2.4 | `review-tables-lists.md` |
| Links + search 123/123. Move, pin, sync, chaos and session suites 245/245 in a throwaway worktree | Linux, Swift 6.2.4 | `review-links-search-pin.md` |
| Search 4–22 ms per query at 2,000 notes of 2 KB | Linux, release build | `review-links-search-pin.md` |
| An iPhone run reached the real GitHub | iPhone, by the owner, before onboarding existed | `be9bdec` (commit message) |
| UI tests | Compile for iPhone. Need macOS automation mode | `d1257dd`, `8a1e502` |

## 7. How the agents were run

The history shows a consistent operating pattern. It is described here because it is part of what was built.

- **Rules before code.** A `CLAUDE.md` with hard rules came in before the kit (`6dc33a7`). Every cloud report repeats
  its boundaries: branch from one commit, push to one branch, no PR, no force push, BrainMerge untouched.
- **Parallel sessions from a single base.** All fourteen cloud branches start at `f6e792a`. The feature sessions were
  kit-only by design: "nothing in `App/` calls these yet" (`docs/plan/lists-kit.md`). That kept them from colliding
  in the app.
- **Builders and reviewers kept apart.** Five of the six feature branches got a second session (Add to Brain did not) that read every line and ran the
  tests. Every fix came with a test that "failed first" (`merge-adversarial.md`). Each fix commit is linked from the
  review doc (`3d25b3b`).
- **Each report has the same shape: Verified, Not verified, Worth a look.** The reports call out each other's gaps.
  For example, the links/search/pin review notes that `cloud/kit-review` "does not compile on Linux as pushed".
- **Integration as its own job.** One session merged eight branches in order and fixed what the first real build
  found. It recorded each conflict resolution, all of them in one manifest file (`integration.md`).

## 8. What is not proven yet

- **Nothing in the cloud work has run on Apple hardware or Xcode.** Every cloud report says so. The Apple-only code
  paths were "compiled by nobody in this session" (`integration.md`), and the accessibility fixes were not even type
  checked (`cloud-a11y-rtl-audit.md`).
- **The cloud work is not integrated with itself.** `cloud/integration` merges eight branches. The four review or
  audit branches with fixes (`merge-adversarial`, `review-tables-lists`, `review-links-search-pin`, `a11y-rtl-audit`)
  are not in it, and neither is `architecture` (checked with `git merge-base`).
- **The app is not wired to the new kits:** tables, lists, links, search, moves, pins and Add to Brain
  (`integration.md`).
- **No automated test talks to the real GitHub.** That is ruled out by the rules. The folder-entries fix rests on the
  API's documented tree shape (`review-links-search-pin.md`).
- **Open decisions handed back to the owner:**
  - Both sides add different frontmatter to a note with none. The result is a clean "merge" with two `---` blocks,
    pinned as a known issue (`merge-adversarial.md`).
  - A Hebrew paragraph that starts with a URL or code runs left to right (`cloud-a11y-rtl-audit.md`).
  - A 28×28 status-icon tap target (`cloud-a11y-rtl-audit.md`).
  - Planner-made conflict-copy names are not truncated (`merge-adversarial.md`).
- **Device budgets** (cold start, typing latency, memory) appear nowhere in the history as measured on a phone
  **(uncertain: they may be in `App/STATUS.md`, which this draft did not use)**.

## 9. Size, as a rough snapshot

Lines of Swift, TypeScript and JSON, counted with `git show … | wc -l`. These are a rough guide only.

| Area | `main` | `editor-spike` | `cloud/integration` |
|---|---:|---:|---:|
| BrainMerge (Swift) | 1,387 | 1,387 | 1,387 |
| Merge spec, reference and vectors (`spec/`) | 4,362 | 4,362 | 4,362 |
| BrainNotesKit sources | 4,691 | 5,805 | 9,940 |
| BrainNotesKit tests | 4,695 | 5,732 | 9,697 |
| App sources | 3,076 | 4,598 | 4,598 |
| App tests | 1,549 | 3,061 | 3,061 |

The merge library has not changed since 3 Nov (last commit `b1b316b`). Test code roughly matches source code line for line.

## 10. Lessons (the author's reading of the record)

- **Specify the risky part first and make two implementations argue.** The project's first commit is a spec. Its
  second puts a reference and a port side by side.
- **A review isn't finished until its findings are tests.** Every review in the history turned into regression tests,
  and twice into permanent fuzz suites.
- **Test the tests.** Mutation checks and "pass with the guard removed" found three editor tests and two onboarding
  tests that couldn't fail.
- **Use the real oracle when there is one.** Checking against cmark-gfm turned a table parser with 1,510
  disagreements per 20,000 notes into one with none in 240,000.
- **Fakes need the same scrutiny.** The worst cloud bug came from a fake GitHub that was simpler than the real one.
- **Let agents work in parallel, but integrate on purpose and keep the ledger honest.** Most of what is worth trusting
  here is trustworthy because each session wrote down what it did *not* check.
