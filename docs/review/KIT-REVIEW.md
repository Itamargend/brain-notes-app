# BrainNotesKit review

Scope: all of `Packages/BrainNotesKit/Sources/BrainNotesKit` (5,700 lines) at `editor-spike` f6e792a, read in full,
plus the tests where a finding needed one. Looked at: correctness, edge cases, concurrency, performance, API shape,
and the request that `swift test` runs on Linux. BrainMerge and the merge semantics were not changed.

**Read this first: nothing in this branch was compiled or run.** The cloud session that wrote it could not install
a Swift toolchain: its network policy refuses `download.swift.org`, `swift.org` and `github.com`, which also blocks
fetching GRDB. Every fix below has a test, but no test has run. Before merging, run on a Mac:

```
cd Packages/BrainNotesKit && swift test
bash scripts/verify.sh
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' build test
```

and `swift test` on Linux (Swift 6.2, `libsqlite3-dev`).

Severity: **High** loses or leaks data, or breaks a stated requirement. **Medium** is a real bug or cost on a
normal path. **Low** is an edge case, a smell or a small cost. **Nit** is cosmetic.

## Summary

| ID | Sev | Area | Finding | Status |
|----|-----|------|---------|--------|
| H1 | High | Portability | The kit cannot compile on Linux: `Compression`, `CryptoKit`, `Security`, `Network`, `os`, `AttributedString(markdown:)`, and `URLRequest` without `FoundationNetworking` | Fixed + tests: 6e35d56, f9308a3, d9bf873. Needs a Linux run |
| H2 | High | Concurrency, privacy | `signOutAndWipe` does not wait for a run in flight; a first sync can write every note back to disk after the wipe | Fixed + test: 034e836 |
| H3 | High | Concurrency | A timer tick spawned just before `stop()` still starts a run after it | Fixed + test: e1d6c7e |
| M1 | Medium | Performance | Every index upsert or remove runs `DELETE FROM fts WHERE path = ?` on an UNINDEXED column: a full scan of all note text on every autosave; rebuild is quadratic | Fixed + tests: fd3aa7e, 4c800a7 |
| M2 | Medium | Robustness | `TarReader` traps on a malformed pax record (range with lower bound above upper) | Fixed + test: 482a708 |
| M3 | Medium | Errors | A network error while refreshing the token escapes the client's error mapping: offline becomes a backoff retry loop, and a cancel does not count as one | Fixed + test: 9acd4fa |
| M4 | Medium | Sign-in | A 5xx or non-JSON answer while polling the device flow ends the sign-in | Fixed + tests: c08c71f |
| M5 | Medium | API shape | Journal and index reads turn every error into "empty" (`try?`), so "unreadable" and "nothing there" look the same | Open |
| L1–L12 | Low | Various | Edge cases and small costs, listed below | Open |
| A1–A5 | Low | API shape | Listed below | Open |

---

## High

### H1. The kit does not build on Linux

The task needs `swift test` on Linux. These imports exist only on Apple platforms:

| File | Apple-only | Used for |
|------|-----------|----------|
| `Tarball.swift` | `Compression`, `NSData.decompressed(using: .zlib)` | gzip inflate for first sync, deflate for the fake |
| `PathPolicy.swift`, `FakeGitHub.swift` | `CryptoKit` (`Insecure.SHA1`, `SHA256`) | git blob shas, outbox hashes, fake object ids |
| `Auth.swift` | `Security` (Keychain) | `KeychainTokenStore` |
| `Session.swift` | `Network` (`NWPathMonitor`) | `NetworkMonitor` |
| `NoteStore.swift` | `os` (`Logger`) | logging |
| `NoteText.swift` | `AttributedString(markdown:)` | `inlineMarkdown` (only the app uses it) |
| `Auth.swift`, `GitHubHTTPClient.swift`, tests | `URLRequest`, `URLSession`, `HTTPURLResponse` live in `FoundationNetworking` on Linux | the whole HTTP layer |
| `HTTPTests.swift` | `KeychainTests` uses the real Keychain | |

**Fix:** each is behind `#if canImport(...)`. Apple builds compile the code they had, with two exceptions that
behave the same: the redirect guard's check moved into a helper (so Linux's completion-handler form can share it),
and `BrainSession.live`'s default token store comes from `platformTokenStore()`, which is the Keychain on Apple.
Linux gets:

- `Digest.swift`: SHA-1 and SHA-256 in plain Swift. They are always compiled, so the Mac test run checks them
  against the FIPS test vectors and against CryptoKit.
- `Inflate.swift`: a raw-deflate (RFC 1951) decoder in plain Swift, and a stored-block deflater for the fake's
  tarballs. Also always compiled, and the Mac tests check it against `Compression`'s output.
- A small `Log` shim with the same calls as `Logger`, which drops messages on Linux (no `print`, as the package rule says).
- `KeychainTokenStore`, `NetworkMonitor`, `inlineMarkdown` and their tests exist only where their frameworks do.

**Not verified:** these Foundation APIs are used and are believed, not known, to behave the same on Linux:
`NSString.enumerateSubstrings` with `.byWords` and `.byParagraphs` (editor code), `URLResourceValues.isExcludedFromBackup`,
`NSRegularExpression`, `NSLock.withLock`, and `URLSessionTaskDelegate`'s async redirect method (on Linux it may not
be called; the app does not ship there). A Linux run will show whether any of them needs a guard.

### H2. Sign out and wipe races a run in flight

`BrainSession.signOutAndWipe` calls `engine.stop()`, clears the tokens and deletes the folder. `stop()` only
cancels the timer. A run already waiting on the network carries on after the wipe:

- During a first sync, `resetStaging()` runs before the tarball download. When the download returns,
  `staging.writeIfPossible` calls `createDirectory(withIntermediateDirectories: true)` and writes **every note** into
  `Brain/<repo>/files.staging/`, outside any journal transaction. The journal write after it fails because the
  database is closed, so nothing cleans up. The user signed out and wiped, and the notes are back on disk.
- `TokenManager` keeps the access token in memory (`cached`), so clearing the Keychain does not stop that run's
  next requests either.

`AppModel.leaveSampleNotes` calls `waitUntilIdle()` first; `AppModel.signOutAndWipe` does not, so the live path
has the bug.

**Fix:** `signOutAndWipe` stops the timer, clears the tokens and drops the manager's cached pair (so the run fails
at its next request), waits until the engine is idle, and only then wipes. Test: a first sync held at the tarball,
sign out during it, release the tarball; the repo folder must not exist afterwards.

### H3. A timer tick can start a run after `stop()`

`reschedule()` sleeps in `wakeTask`, then spawns a separate `Task { await self?.tick() }` so that moving the timer
can't cancel a push. `stop()` cancels only `wakeTask`. A tick spawned just before `stop()` runs afterwards, and
`tick → sync(.poll)` never checks `started`. With H2 fixed this matters even more: a tick arriving after
`waitUntilIdle()` returned would start a run while the folder is being deleted.

**Fix:** `tick()` returns at once when the engine is stopped. Test: stop, then deliver a tick; GitHub sees no call.

---

## Medium

### M1. Each index write scans the whole full-text table

`SearchIndex.upsert` and `remove` run `DELETE FROM fts WHERE path = ?`. `path` is declared `UNINDEXED` in the FTS5
table, and FTS5 can only look up by `rowid` or `MATCH`. Any other constraint is a full scan that reads each row's
stored content. So:

- Every autosave of a note (`NoteStore.save → reindex`) reads the stored text of **every** note in the index, which
  is the whole brain. At about 1,600 notes and one 271 KB note, that is megabytes per keystroke pause, on the
  main path of typing.
- `rebuildIndex` (first sync, repair) clears and then upserts n notes: about n²/2 row reads.

**Fix:** the FTS row's `rowid` is the `notes` row's `rowid` (stable under `ON CONFLICT DO UPDATE`). Writes and
deletes go by `rowid`. An index built by the old code (no `schema` key in `meta`) is emptied and loses its stamp
when opened, so `repairIndexIfNeeded` rebuilds it from the files. It is derived data. Tests: upsert twice leaves
one searchable row, remove clears both tables, and an old-schema index is reset and rebuilt.

### M2. Malformed pax record traps

`TarReader.parsePax` slices `data[(j + 1)..<(i + len - 1)]` after checking only `i + len <= endIndex`. A record
whose length doesn't reach past its space (`"1 …"`, `"2 x"`), or a body with no space at all, makes a range whose
lower bound is above its upper bound, and Swift traps. The archive comes from the network. Everything else in the
reader throws `TarballError`, and first sync falls back to the blobs API on that error, so a crash here is the
odd one out.

**Fix:** a record has to hold its space and at least its newline, or parsing that header stops. That entry keeps
its ustar name, the sha check doesn't match it, and the blobs API supplies it as for any other missing file.
Test: a pax body of `"1 "` reads without a trap.

### M3. Token-refresh network errors are not mapped

`GitHubHTTPClient.sendOnce` maps `URLError` to `.offline`, `.timedOut` or `CancellationError`. But
`tokens.accessToken()` and `tokens.refresh(failed:)` also go to the network (refresh before expiry, refresh after a
401), and their `URLError`s pass through raw. `SyncEngine.handle` doesn't know `URLError`, so:

- going offline while a refresh is due is a generic failure: backoff 2, 4, 8 s… with a call each time, not
  `.offline`. STATUS.md says "Offline makes no calls";
- a cancelled refresh (`URLError.cancelled`) also counts as a failure and grows the backoff.

**Fix:** the token calls inside `perform` go through the same mapping. Test: a refresh that hits
`notConnectedToInternet` surfaces as `GitHubError.offline`.

### M4. One bad poll ends the device flow

`DeviceFlow.waitForApproval` keeps polling only through a `URLError`. `post` ignores the HTTP status and parses the
body as JSON, so a 502 with an HTML page (or any non-JSON body) throws an `NSError` out of the loop. A user who
spent minutes approving on another device gets "sign-in failed" for one blip.

**Fix:** while polling, a 5xx or a body that is not a JSON object counts as "try again at the next interval", like
a dropped connection. `start()` is unchanged: a failure there is shown at once. Test: a 503 between two pending
answers, then approval.

### M5. Reads that cannot fail (API shape, open)

`Journal.meta`, `file`, `allFiles`, `outbox`, `outboxCount`, `pushableCount`, `attention…`, `statuses`,
`pendingPush` and the `SearchIndex` reads all use `try?` and return nil or empty on any error. A database that
can't be read right now looks like a database with nothing in it:

- `journal.baseCommit == nil` is how `runOnce` decides to run a **first sync**. Today the first write in
  `firstSync` (`setMeta(swapping)`) would fail before `swapIn()` replaces the files folder, so nothing is lost. But
  that is one line away from replacing the folder, and nothing documents it.
- `reconcile()` reads `meta(swapping)`; unreadable means "not swapping".
- `pendingPush()` unreadable means "nothing to verify".

Not changed here: the fix is a throwing read API, and every caller in the engine and the app would have to decide
what to do with the error. Suggested: make the engine-facing reads `throws`, keep `try?` variants for views, and
have `firstSync` check that the outbox and files tables are readable before it touches the disk.

---

## Low

- **L1. Gzip trailer not checked.** `Gzip.decompress` drops the CRC-32 and size trailer without comparing them.
  Every file is verified against its blob sha afterwards, so a corrupt stream can't land, but it does pass as
  "tarball usable" and fall back file by file. A one-line check would turn it into the clean `TarballError` path.
- **L2. Token endpoint 429 or 4xx means signed out.** `TokenManager.refresh` treats everything except 5xx as
  `.unauthorized`. A rate limit or an HTML error page from `github.com/login/oauth` signs the user out (data is
  kept, but they have to sign in again).
- **L3. A changed file with no `sha` is skipped silently.** In `pull`, an `.upsert` with `sha == nil` does
  `continue`, and the base still moves to head, so that note stays stale until it changes again. GitHub always sends
  `sha` today. Suggest: treat it as a truncated comparison (use `treeDiff`).
- **L4. Quadratic rename detection.** `treeDiff` runs `added.filter` and `removed.filter` for each removed path:
  O(removed × added). Only above 300 changed files, and fine at today's sizes; a dictionary by sha makes it linear.
- **L5. Mode reset.** `createTree` writes every path as `100644`. Editing a note committed as executable
  (`100755`) quietly drops the bit. It is harmless for notes, but it shows up as a mode change in `git log`.
- **L6. `headDate` can be wrong.** GitHub's compare lists at most 250 commits, and `headDate` takes the date of the
  last commit *listed*. On a big catch-up, pulled notes get an older date than the real head. It is used only as a
  list date.
- **L7. Whole outbox for one op.** `NoteStore.read` (when the file is gone), `delete`, `texts(for:)` call
  `journal.outbox()` and decode every op's full text to find one path. `Journal.status(of:)` builds the full status
  map for one path. `Journal.op(db, path:)` exists for the first group.
- **L8. Rename on every autosave of a new note.** While a note is still a create, each save runs
  `notePath`, which loads every path and builds a `PathIndex` (NFC and case folding of each). It is O(n) per
  keystroke pause on a 1,600-note brain. It could run only when the first line changed.
- **L9. `emptyFolders()` walks the whole tree** on every `createFolder` and each time the app asks for folders.
- **L10. `freshSync` is not serialized with a run.** It edits the outbox, deletes `pending_push` and clears the
  base without checking `running`. Today a run can't be in flight then (a run returns at once while the rewrite
  item is open), but nothing enforces that. Suggest: an `isRunning` guard, or doing the reset inside `sync`.
- **L11. Index open failure deletes the index.** `SearchIndex.open` treats every error as corruption and deletes
  the files. On iOS the index folder is `.complete` protection: opened while locked, the delete works and the
  re-create fails, so `NoteStore.init` throws. Sync is foreground only today, so this needs a launch in the
  background to show. Suggest: delete only on `SQLITE_CORRUPT` / `SQLITE_NOTADB`.
- **L12. Two clocks in one copy.** `NoteStore.createCopy` calls `now()` twice: the stamp in the file name and the
  `created` in its header can differ by a second.

## API shape

- **A1.** `Comparison.status` is a `String`. The plan's "landed" check got `ahead` and `behind` backwards once
  already (STATUS.md). An enum (`ahead`, `behind`, `identical`, `diverged`) would let the compiler hold the
  meaning.
- **A2.** `Journal.queue` and `SearchIndex.queue` are public, so the app can write rows that skip the journal's
  rules (one op per path, in-flight protection). Internal plus named operations would close that.
- **A3.** `SyncEngine.events` is one `AsyncStream`. A second `for await` would split events between the two
  readers instead of copying them. Either document "one reader", or hand out a stream per subscriber.
- **A4.** `NoteStore`, `Journal` and `SearchIndex` are `@unchecked Sendable`. That is sound today because every
  mutable thing sits behind a GRDB queue, but the file I/O in `save` runs inside the journal's write transaction.
  That is correct (it is what keeps the file and the row in step) but worth a comment where the class is declared:
  the invariant is "disk writes for a note happen only inside a journal write".
- **A5.** `Journal.allFiles()`'s comment mentions a `withBase` parameter that doesn't exist. It loads `base_text`
  for every dirty row; callers that only need paths (several in the engine) pay for it.

## Checked and fine

- Exact-byte equality everywhere paths or text are compared (`sameBytes`, `PathKey`, SQLite `BINARY` primary
  keys), including NFC/NFD twins.
- The repo guard on every request, the redirect guard, `force: false`, no client secret, and the token single
  flight in `TokenManager` (concurrent 401s share one refresh).
- The push protocol: pending push written before the ref update, verification after a lost response, rev checks
  so text typed during a push is kept, and the per-op fallback after a rejected batch.
- Pull: dirty notes keep their text, removes before writes for case-only renames, the clash index and
  held-back rows.
- Launch repair: size and mtime first, hash only on a difference, the outbox copy winning over a disk that went
  back.
- `MarkdownEdits` and `MarkdownInline` were read for crashes only (index arithmetic, clamping). They already carry
  mutation-checked tests. Nothing found.

## What is in this branch

| Commit | What |
|--------|------|
| 51b4cf9 | This review |
| 034e836 | H2: sign out and wipe waits for a run in flight |
| e1d6c7e | H3: a tick after `stop` starts no run |
| fd3aa7e, 4c800a7 | M1: index rows keyed by rowid; old indexes rebuilt |
| 482a708 | M2: malformed pax record throws instead of trapping |
| 9acd4fa | M3: token-call network errors mapped |
| c08c71f | M4: device flow survives a server error while polling |
| 6e35d56 | H1: SHA-1 and SHA-256 without CryptoKit |
| f9308a3 | H1: gzip without Compression |
| d9bf873 | H1: the remaining guards |

New tests: `DigestTests`, `InflateTests`, and one or two per fix in `SessionSwitchTests`, `TextAndIndexTests`,
`PolicyTests` and `HTTPTests`. Changes stay inside `Packages/BrainNotesKit` and `docs/review/`. BrainMerge and the
merge semantics are untouched; `Package.swift` gains only GRDB (already pinned) for the test target.

Found by reading the diff, since nothing could be compiled: 4c800a7 fixes two of this branch's own tests, which
called GRDB's sync `read` and `write` inside `async` tests, where Swift picks the async overloads. Expect a first
compile to turn up more of the same kind.

> **Update on `cloud/integration`:** the kit was built and `swift test` run on Linux (Swift 6.1.3). H1 needed two more compile fixes, one workaround for a swift-corelibs-foundation bug and two Apple-only test guards; see `.plan/cloud/integration.md`.
