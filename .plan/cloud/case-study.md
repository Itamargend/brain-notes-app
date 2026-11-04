# cloud/case-study

Branch `cloud/case-study`, from `editor-spike` at `f6e792a`. Pushed to `origin/cloud/case-study` only. No PR, no
force push, nothing pushed to `main`, `editor-spike` or `m3-app`. No code, BrainMerge, fixtures or config touched.

## Task

Write a draft `docs/CASE-STUDY.md` for a portfolio reader (hiring manager or investor) about building Brain Notes.
Build it only from the `.plan` docs across the repo's branches and from the git history. Invent nothing; mark what
is uncertain.

## Sources I allowed myself

1. **`.plan` docs on every remote branch** (fetched all 17 branches):
   - `cloud/architecture:.plan/cloud/architecture.md`
   - `cloud/integration:.plan/cloud/integration.md`
   - `cloud/merge-adversarial:.plan/cloud/merge-adversarial.md`
   - `cloud/review-tables-lists:.plan/cloud/review-tables-lists.md`
   - `cloud/review-links-search-pin:.plan/cloud/review-links-search-pin.md`
   - `cloud/a11y-rtl-audit:.plan/cloud/cloud-a11y-rtl-audit.md`
   - The kit branches' plan docs under `docs/plan/` (tables, lists-kit, links-kit, search-kit, move-pin-kit,
     add-to-brain). They are plan docs by name and by commit message ("Plan: …"), so I counted them.
2. **Git history:** all 106 commits on all branches: subjects, bodies, authors, dates, time zones, which branches
   contain which commits, and file and line counts at three commits (`main`, `editor-spike`, `cloud/integration`).
   `CLAUDE.md` is part of that history and is the only place the 110/110 and 9,637 figures sit on `editor-spike`.

## Sources I did not use as evidence

- `.plan/A-app.md`, the main task and architecture plan. It is git-ignored and on no branch, so it isn't in this
  clone. Every cloud session before me reports the same gap.
- `App/STATUS.md`, `RESULTS.md`, `merge-spec.md`, the code and the review docs (`docs/review/*`) were not read as
  sources. Where a `.plan` doc quotes them (such as test counts "copied from `App/STATUS.md`, not re-run"), the case
  study quotes the `.plan` doc and says the numbers were not re-run.
- The existing `docs/CASE-STUDY.md` on `cloud/readme` and `cloud/integration` (commit `4a32c22`). I read it to avoid
  contradicting it without reason, but it was built from `App/STATUS.md` and the code, so I took no claim from it.
  It covers the product design in more depth; this draft covers how the thing was built and checked. A later
  session should merge the two or pick one. See "Worth a look".

## Plan

1. Fetch all branches; list every `.plan/` and `docs/plan/` file per branch. ✓
2. Read each `.plan` doc in full and the kit plan docs' decisions and limits. ✓
3. Read the full log with bodies; work out the timeline, who committed what, and which branches are merged where. ✓
4. Draft the case study in this order: the one-paragraph version; the problem; the build timeline; the decisions
   with their recorded reasons; the engineering stories with numbers; how it was checked; the agent workflow; what is
   unverified or undecided; lessons. Every claim names a commit or a plan file.
5. Keep model names out (repo rule for this session): say "a different AI model", "an AI coding agent".
6. Commit plan + doc together, push to `cloud/case-study` with `-u`.

## Judgement calls

- **Time span.** First commit 2026-11-03 18:43 +0200; last 2026-11-04 21:14 +0000 (23:14 +0200). About 28.5 hours of
  wall clock. That is commit timestamps, not effort. Work before the first commit (the spec arrived as "Starting
  files") is unknown. The doc says so.
- **Who did what.** 30 commits authored "Itamargend" (+0200, the owner's machine), 21 of them (from `6ac12de` on) with an AI
  Co-Authored-By trailer; 76 commits authored "Claude" (+0000) on the 14 `cloud/*` branches. I describe it as an
  owner directing AI coding agents, in local sessions and in parallel cloud sessions, and do not claim more about
  how much the owner typed.
- **Mac/iPhone results.** Commit messages on `main`/`editor-spike` claim Mac and iPhone results (an iPhone run, the
  mutation checks, the Catalyst harness). I report them as claimed by the commit, since no `.plan` doc re-ran them
  and every cloud session says it couldn't run anything on Apple.
- **Not integrated.** `cloud/integration` merges 8 branches. The 5 review/audit branches (`merge-adversarial`,
  `review-tables-lists`, `review-links-search-pin`, `a11y-rtl-audit`, `architecture`) are not in it (checked with
  `git merge-base --is-ancestor`). The doc says their fixes still need to be merged.

## Verified

- Every number in the doc was checked against the commit or plan file it cites, at writing time.
- Branch containment and the main == m3-app == `be9bdec` fact were checked with git.
- Line counts are from `git show <ref>:<file> | wc -l` over `.swift`/`.ts`/`.json` files. They are rough, and
  `spec/` includes the JSON vectors.

## Not verified

- No build or test was run in this session (no Swift toolchain installed, and the task changes no code).
- Claims in commit messages and `.plan` docs are taken as their authors reported them.

## Worth a look

- Two case studies now exist (`cloud/readme`'s and this one). Suggest keeping this one's build story and
  verification ledger, and the other's product principles section, in a single file.
- `.plan/A-app.md` would close the main gap: why the scope, budgets and non-goals are what they are. One paragraph
  from it would make section 2 much stronger.
- Several review fixes overlap across branches (the NoteSearch 528-vs-50 fix is both `7577eac` and `61d0990`; the
  UserDefaults pins removal is in both integration and `2286da4`). Expect small conflicts when they meet.
