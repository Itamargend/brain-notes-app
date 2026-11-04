# cloud/review-links-search-pin

Second-pass review of `cloud/links-kit`, `cloud/search-kit` and `cloud/move-pin-kit`, merged on this branch
(from `editor-spike` f6e792a). Findings, with severity and fix commits: `docs/review/LINKS-SEARCH-PIN-REVIEW.md`.

## What I did

1. Merged the three branches here. One conflict, `Packages/BrainNotesKit/Package.swift`: one manifest now declares
   NoteSearch everywhere and, off Apple, BrainNotesKit limited to `Links/`.
2. Got Swift 6.2.4 running: `download.swift.org` is blocked and Docker Hub rate-limits, but `mirror.gcr.io` serves
   the official `swift:6.2-noble` image. Its layers, unpacked into a chroot with the repo bind-mounted, run
   `swift build` and `swift test`. `github.com` git fetches work, so GRDB 7.12.0 resolves; `libsqlite3-dev` came from
   the host's apt.
3. Read every source file of the three branches, ran their tests, fixed what I found, each with a test:

| Commit | Fix |
|--------|-----|
| 61d0990 | NoteSearch test asked for 528 results from a search capped at 50 |
| d8c025f | Links: U+2028/U+0085 are not paragraph breaks, as in the editor (caught by the agreement test) |
| 0866998 | Links: two notes onto one path is a taken destination |
| 606701c | **Moves vs GitHub's tree: folder entries broke every note move into a folder and every folder move with a subfolder.** FakeGitHub now lists folders as GitHub does |
| 2286da4 | Pins: removed the UserDefaults store (failed the kit's policy test, outlived sign-out's wipe) |
| 9dfb0d7 | Moves: never replace or clear a landing record that is not the move's |

## Verified (Linux x86_64, Swift 6.2.4)

- This branch, `swift test` in `Packages/BrainNotesKit` (Links + NoteSearch): 123/123.
- Search speed, release: 4–22 ms per query at 2,000 notes of 2 KB; build 0.47 s.
- `bash scripts/verify.sh`: 110/110 vectors; 28 differential path cases differ on Unicode 16 case folding
  (BrainMerge unchanged; Linux-only).
- In a throwaway worktree with `cloud/kit-review` merged plus two local compile patches (never pushed): move, pin,
  HTTP, engine, sync, chaos, session and links suites, 245/245. Each new test was seen failing without its fix.

## Not verified

- Nothing ran on macOS or iOS: no Xcode build, no app tests, no Apple Foundation. `LinksEditorAgreementTests` on a
  Mac decides M3 for Apple.
- `NoteMover`, `Pins` and `FakeGitHub` changes ran only on Linux, and only on top of `cloud/kit-review`'s port.
- No real GitHub call (the rules forbid it). H1 rests on the API's documented `recursive=1` shape, which the client's
  own `isFile` code already expects.

## For the next session

- `cloud/kit-review` does not compile on Linux as pushed (`.byWords` in MarkdownEdits, a `sending` closure at
  SyncEngine.swift:220). Details in the review doc.
- Open lows L2–L9 in the review doc; the one worth doing is running a move inside the engine's actor.
