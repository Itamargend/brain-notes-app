# cloud/architecture: session report

Branch `cloud/architecture`, from `editor-spike` at `f6e792a`. Pushed to `origin/cloud/architecture` only.
No PR, no force push, no changes to `main`, `editor-spike` or `m3-app`.

## What I did

- Wrote `docs/ARCHITECTURE.md` for a portfolio reader:
  1. system overview (three layers, one dependency) with a diagram;
  2. the app layer (routing, Live Preview editor, Hebrew, demo mode) with a screen diagram;
  3. BrainNotesKit: components, on-device layout and file protection table, how a save works;
  4. sync over the Git Data API: triggers table, state diagram, push sequence diagram (call by call,
     including `pending_push` before the ref update and the Verifying path), first sync flow, held-back
     notes, launch repair;
  5. the merge: `mergeFile` flowchart, `planCommit` rules;
  6. conflict copies in `_inbox`: sequence diagram, path, header, resolution choices;
  7. a decision log, D1 to D14, each with decision, alternatives and reason, labelled "recorded"
     (the repo states the alternative) or "implied" (a repo rule rules it out, no evaluation written);
  8. the security model: an asset / threat / protection / source table, why data loss counts, known limits;
  9. what is verified and what isn't.
- Did not touch any code, BrainMerge, fixtures or config.

## Sources

Code in `Packages/BrainNotesKit`, `Sources/BrainMerge`, `App/Sources`; `merge-spec.md`; `RESULTS.md`;
`App/STATUS.md`; `CLAUDE.md`; `App/Config/*.example.xcconfig`; entitlements; commit messages.

`.plan/A-app.md` and the "v2 plan" are git-ignored and **not in this clone**, so I could not read them. Where the
code cites the plan ("Plan: ..."), the doc quotes that comment instead.

## Verified

- All 8 mermaid diagrams parse and render with mermaid 11.4.1 (local npm install, rendered in the pre-installed
  Chromium through Playwright). The CDN was blocked by the proxy, so the check used the npm package.
- Every factual claim was checked against the file it cites while writing (constants such as poll 60 s, idle 30 s,
  one commit a minute, 3 retries with 1 to 4 s jitter, backoff to 5 min, push hold 5 min doubling to 1 h, the
  `force: false` body, the `RepoTarget` guard, Keychain accessibility class, file protection classes, backup
  exclusion, redirect guard, the conflict-copy path and header, the five secret patterns).

## Unverified

- **Swift is not installed** (`swift --version`: command not found). I did not try to install a toolchain: this
  task changes no code, so there was nothing to build. No tests were run in this session.
- Test counts and timings in the doc (110 vectors, 9,637 differential cases, 239 kit tests, 312 Mac tests, scale
  numbers, merge timings) are copied from `RESULTS.md` and `App/STATUS.md`, not re-run.
- Decision rationales that live only in the git-ignored plan: D2 (sync only while open) has no recorded
  alternatives in the repo, and D1's libgit2 alternative is only implied by the "GRDB only" rule. The doc says so
  in each entry. D3's "why theirs" paragraph is labelled as an inference.
- I did not compare the doc against the real behaviour on a device or against real GitHub.

## Worth a look

- `App/STATUS.md` says unpushed text of a deleted note goes to `_trash/<note>-unsynced-<time>.md`; the code
  (`NoteStore.keepInTrash`) writes `_trash/unsynced-<slug>-<stamp>.md`. The doc follows the code.
- If the plan holds the reasoning for D1 and D2 (libgit2, background sync), adding a line from it to
  `docs/ARCHITECTURE.md` would close the two "not recorded" gaps.
