# BrainNotesKit test-coverage gap report

Branch `cloud/test-coverage`, cut from `editor-spike` at `f6e792a`. Written 2026-11-04.

## Read this first: the new tests have not been compiled or run

This cloud container runs Linux and has no Swift toolchain. The package also needs Apple-only frameworks
(Compression, CryptoKit, Security, Network) and `platforms: [.macOS(.v26), .iOS(.v26)]`. I could not build
or run anything here. The 61 new tests were written against the source line by line and checked by hand,
but **nobody has seen them pass**. Run this on the Mac before merging:

```bash
cd Packages/BrainNotesKit && swift test --filter 'GraphQLVariablesTests|WireFormatGapTests|TokenParsingTests|TokenManagerGapTests|DeviceFlowGapTests|HostileRemotePathTests|GzipHeaderTests|TarEdgeTests|SecretPatternGapTests|ExactBytesTests|JournalRuleTests|ConflictCopyNamingTests|SearchSyntaxTests|FileStoreGapTests|FolderPolicyTests|DemoBrainFixtureTests|SignOutWipeTests'
```

Then run the full `swift test` and `bash scripts/verify.sh`. I did not touch BrainMerge or any source file,
so `verify.sh` should not change.

If a new test fails, first decide whether the test is wrong or the code is. The likeliest wrong guesses
are marked ⚠ below.

## How I measured

There is no line-coverage tool here (no `llvm-cov`), so this is a structural audit:

1. I listed every `func`, `var`, `init` and `case` in `Sources/BrainNotesKit` and searched the tests for
   each name (`grep -w`). About 200 names have no direct reference.
2. I read the 318 existing tests by suite and name, and read in full the files where the risk sits:
   `PathPolicy`, `Exact`, `Tarball`, `FileStore`, `Auth`, `GitHubHTTPClient`, `Journal`, `SearchIndex`,
   `NoteStore` (save, copy, delete), `Session`, and the first-sync, apply and tree-diff parts of `SyncEngine`.
3. I sorted each gap by risk: what breaks, how badly (data loss or a hard-rule breach rank above a wrong
   label), and whether anything else already catches it.

## Coverage map (before this branch)

| Area | Lines | Tests | Verdict |
|---|---:|---:|---|
| SyncEngine (pull, push, races, kills, rewrites, backoff, scheduler) | 1416 | ~140 across Engine, ReviewFindings, Chaos, SyncFuzz, Scale | **Strong.** Scenario-level, including kill-at-every-call and a fuzz. Gaps are in input checking, not logic. |
| MarkdownEdits / MarkdownInline | 1034 | 65 | **Strong.** Recently mutation-checked (`39dc92e`, `f6e792a`). |
| NoteStore (save, compose, delete, attention, reconcile) | 518 | ~30 | **Good.** Missing: conflict-copy name collisions. |
| HTTP client + token manager + device flow | 593 | 25 | **Good on the happy path and the status codes.** Missing: GraphQL injection, compare statuses, a malformed ref sha, token-response parsing, form encoding, device-flow edge answers. |
| Journal | 381 | indirect only | **Weak at unit level.** Rules like "one open item per path, reason and copy" and "a push closes only push problems" were tested only through the engine, if at all. |
| PathPolicy / SecretScan / RepoTarget | 187 | 9 | **Thin.** The guard is tested well. Secrets: one pattern of each kind and no near misses. Folder rules only through the store. |
| Tarball / Gzip | 195 | 4 | **Thin.** No optional gzip header fields, no non-file tar entries, no pax/prefix edge cases, no missing end blocks. |
| FileStore | 191 | 5 | **Partial.** Name limits, `emptyFolders`, `move` and folder path checks untested. |
| SearchIndex | 196 | 13 | **Good**, except FTS5 operator words (`AND`, `OR`, `NOT`, `NEAR`) typed as a search. |
| Exact (PathKey, sameDoc, decodeNote, isoTime) | 55 | indirect | **Untested directly**, though NFC/NFD separation is the core of several hard-won fixes. |
| Session (demo, live, sign-out) | 178 | 8 | **Partial.** `signOutAndWipe` and the demo's staged states untested in the Kit. |

## Gaps, ranked by risk, and what this branch does about each

✅ = a new test covers it, 📝 = written up only, needs a code change or a device.

### P0: hard rules and attacker-shaped input

1. ✅ **GraphQL query injection through a note path.** `lastCommitDates` sends paths as GraphQL variables.
   Nothing proved it. A path like `a") { viewer { login } } #.md` must stay out of the query text, and the
   query must name only the allowed repo. → `GraphQLVariablesTests` (3 tests).
2. ✅ **Paths from GitHub that climb out of the notes folder.** `../escape.md`, `a/../../x.md`, `/abs.md` and
   `a//b.md` on the first sync (tarball and tree) and on a pull (compare). The defence is `checkPath` plus
   `FileStore.url(for:)`. Each was tested alone; this tests the whole path from server to disk.
   → `HostileRemotePathTests`.
3. ✅ **A ref or sha from GitHub that is not a sha.** `getRef` passes the returned sha through `checkedSha`
   before it becomes a URL; only the input side was tested. → `aRefWithABadShaIsRefused`.
4. ✅ **The refresh request.** It must carry no `Authorization` header and no secret, and send exactly the
   three form fields. → `theRefreshRequestHasNoSecretAndNoBearer`.
5. 📝 **The redirect guard is untested.** `GitHubSession.RedirectGuard` strips `Authorization` and allows
   only `https://codeload.github.com`. It is `private`, inside a `URLSession` delegate, so no test can reach
   it. Suggested seam: move the decision into `static func redirect(_ request: URLRequest) -> URLRequest?`
   on `GitHubSession`, test that, and have the delegate call it. Without this, a refactor could forward the
   token to any host GitHub redirects to.
6. 📝 **`RepoTarget.guardURL` accepts an explicit port** (`https://api.github.com:8443/repos/Itamargend/brain-notes-test/...`)
   and never looks at the query. Only the client's own code builds URLs, so this is not reachable today.
   One-line hardening: `url.port == nil`. ⚠ It probably also accepts `..%2F..%2F` inside one segment,
   because `pathComponents` decodes it to a single segment that is not `..`. Verify on the Mac before
   relying on that.

### P1: data loss or silent corruption

7. ✅ **Two conflict copies in one second.** Copy names use second-resolution stamps, and a long path is cut
   to its last 150 characters, so two copies can want the same name. `freePath` must give the second one
   `-2`. → `ConflictCopyNamingTests` (2 tests).
8. ✅ **Journal invariants at unit level.** One open item per (path, reason, copy). A resolved item does not
   block a new one. `resolvePushProblems` closes `blocked:*`, `case-clash`, `unstorable`, `push-failed` and
   `rejected`, but never `conflict-copy`. Needs attention outranks syncing. A save unparks its op and keeps
   its id and time. The oldest op sets the 24 h badge. NFC and NFD paths are separate rows and separate ops.
   → `JournalRuleTests` (6 tests).
9. ✅ **PathKey and exact bytes.** `"Café" == "Cafe\u{301}"` is true in Swift. The test states that and
   checks that `PathKey`, `Set` and `Dictionary` keep the two apart. Also invalid UTF-8 (surrogate,
   overlong, cut mid-character) and the whole-seconds `Z` time format. → `ExactBytesTests`.
10. ✅ **Tarball reader edge cases.** A pax `path=` must not leak past a skipped entry (that would write one
    note under another note's name). Hard links, symlinks and folders are not files. The ustar `prefix`
    field. `stripFirstComponent: false`. A size field past the end. Missing end blocks mean truncated.
    → `TarEdgeTests` (6 tests).
11. ✅ **Gzip optional header fields** (FNAME, FCOMMENT, FEXTRA, FHCRC, all four together), an over-long
    FEXTRA, a broken deflate stream, and a method byte that is not deflate. → `GzipHeaderTests` (4 tests).
    ⚠ `aBrokenDeflateStreamFailsToInflate` assumes Apple's zlib decoder throws on a reserved block type
    rather than returning empty data.
12. ✅ **Sign out and wipe.** Tokens, files, journal and index all gone, and a new session on the same
    folder starts empty. → `SignOutWipeTests`.
13. 📝 **Integrity checks that do not exist.** `Gzip.decompress` checks neither the CRC32 nor ISIZE trailer.
    `TarReader` never checks a header checksum, and `TarballError.badHeader` is never thrown. Today this is
    covered: the engine checks every file's git blob sha against the tree (`aTamperedTarballFileIsReplacedFromBlobs`),
    so a corrupt archive costs blob calls, not data. Worth a comment in `Tarball.swift` so nobody later
    trusts the reader on its own.

### P2: wrong behaviour the user would notice

14. ✅ **Typed FTS5 operators.** `AND`, `OR`, `NOT`, `NEAR(`, `body:x`, `^x`, `*`, quotes, `c++` and
    `don't`. Each must be searched as words, and none may make the query fail. A failed query is swallowed
    and shows as "no results", the worst failure for a search box. → `SearchSyntaxTests` (3 tests).
15. ✅ **Secret patterns.** All five `gh?_` prefixes, `github_pat_`, `ASIA`, PKCS#8 and OpenSSH private keys,
    `client_secret`, `ACCESS-TOKEN`, `secretkey`, and a token inside a URL. Near misses must pass (19-char
    token, 15-char AWS id, public key, prose about keys). Moving a known secret is not new; a second one is.
    The path rule reports before the secret rule. → `SecretPatternGapTests` (5 tests). All secret-shaped
    strings are built at run time, as in `Fixture`.
16. ✅ **Compare API statuses.** `copied` → added, `changed` → modified, `unchanged` skipped, an entry with
    no filename skipped. → `everyCompareStatusMaps`.
17. ✅ **Token-response parsing and form encoding.** Expiries, a token that never expires, `error` in a
    200 body, an empty token, a non-object body, and escaping `& = + / space`. → `TokenParsingTests`.
18. ✅ **Token manager short paths.** No stored pair, an expiring token with no refresh token, a refresh with
    no refresh token, and a token already rotated by another request (no network, `refreshCount == 0`).
    → `TokenManagerGapTests`.
19. ✅ **Device-flow edge answers.** Defaults when `interval` and `expires_in` are left out, `error` from
    `start`, missing fields, an unknown poll error, and an already-expired code that asks nothing.
    → `DeviceFlowGapTests`.
20. ✅ **FileStore** name limits (255 characters per name, not bytes; 700 bytes per path), `writeIfPossible`
    on a name the disk cannot hold, `emptyFolders`, `move`, and folder-path validation. → `FileStoreGapTests`.
21. ✅ **Folder rules** (`folderName`, `canHoldNotes`) as pure functions. → `FolderPolicyTests`.
22. ✅ **The synthetic demo brain** (`Fixtures/demo-brain`). Every fixture loads, is NFC, visible, clash-free
    and secret-free. `BrainSession.demo` stages its three states with the real engine.
    → `DemoBrainFixtureTests`. ⚠ The second test depends on the exact fixture text that `DemoBrain.stage`
    looks for; editing those fixtures will break it, which is intended.
23. ✅ **Misc wire format.** A 304 with its ETag, a blob that is not base64, a body that is not an object, an
    unmapped 409, and the token and API version on every request. → `WireFormatGapTests`.

### P3: written up, not tested (low risk or device-only)

24. 📝 `Form.encode` uses `CharacterSet.alphanumerics`, which is Unicode. Non-ASCII letters would go out
    unescaped. Every value sent today is ASCII (client id, tokens, device code). If that changes, build the
    allowed set from ASCII ranges.
25. 📝 `Journal.opRow` drops a row with an unknown `kind`. The op then disappears from `outbox()` but still
    holds the path's `UNIQUE` slot. This can only happen after a downgrade across a schema change. Worth a
    log line.
26. 📝 `SearchIndex.search`, `notes` and `count` turn every database error into empty results. With item 14
    covered this is mostly about a corrupt index on disk, which `corruptFileIsResetNotFatal` already tests
    at open.
27. 📝 Device-only, cannot be faked meaningfully: `KeychainTokenStore` under `errSecInteractionNotAllowed`
    (only the fakes are tested), iOS `NSFileProtectionComplete` attributes, and `NetworkMonitor`.

## Next steps

1. Run the filter command above on the Mac. Fix any test that encodes a wrong assumption (the ⚠ ones first).
2. Decide on the two small hardening changes: the redirect-guard seam (item 5) and `port == nil` (item 6).
   They change source, so each should come with its own test, and they are outside this branch's scope.
3. Add a real line-coverage run to the local workflow, so the next audit can measure instead of reading:
   `swift test --enable-code-coverage`, then
   `xcrun llvm-cov report .build/debug/BrainNotesKitPackageTests.xctest/Contents/MacOS/BrainNotesKitPackageTests -instr-profile .build/debug/codecov/default.profdata -ignore-filename-regex 'Tests|BrainMerge'`.
