# Spike S3 results: Swift port of the Brain Notes merge

First run 3 Nov 2026 (18:23 UTC), second run after the F1/F2 fixes 3 Nov 2026 (18:43 UTC), third run after the Gemini review fixes F-01 to F-07 3 Nov 2026 (19:36 UTC): MacBook Air (Mac16,12), Apple M4, 10 cores, macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2. Logs from `scripts/verify.sh` are in `.logs/` (git-ignored).

## Verdict

**Pass.** The Swift package `BrainMerge` (no third-party dependencies, macOS 26 and iOS 26) reproduces the TypeScript reference in `spec/merge/ref/` exactly, and it is fast enough to run on the main device path.

## Correctness

After the Gemini review fixes F-01 to F-07 (third run, 3 Nov 2026, 19:36 UTC, Node v26.7.0 for the generator):

| Check | Result |
|---|---|
| `vectors.json` (`mergeFile`) | 53 / 53 (49 before, plus M50 to M53) |
| `plan-vectors.json` (`planCommit`) | 47 / 47 (29 before, plus P30 to P47) |
| TypeScript reference against the same vectors | 100 / 100 (the reference before the fixes fails 20 of the 22 new vectors; M52 and P34 are boundary checks it already passed) |
| Bundled vector files byte-identical to `spec/merge` | yes |
| Differential vs reference (`Tools/differential/gen.ts`, seed 20261103) | 9,327 / 9,327 |

Differential breakdown: diff3 300, freePath 150, splitBlocks 250, paths 6,275, matchLines 202 (including the 4,000,000-cell limit), path size limits 8, yaml 53, stamp 13, planCommit 912, mergeFile 1,164. In total 14 tests in 2 suites, all passing.

- paths: 500 random; the 1,561 code points `c` where `foldKey(c)` differs from NFC(`c`) (the loop skips the 1,110 code points that NFC alone changes and that fold to their NFC form, and lowercase letters such as Cherokee small letters whose key is themselves; see F-09 below); 32 fold edge cases; new: all 4,174 `Default_Ignorable_Code_Point` code points inside a path, plus 8 look-alike neighbours that must pass.
- planCommit: 588 before; adds the P30 to P47 inputs, 300 random outboxes O0 to O299 with several ops per path (renames onto edited paths, NFC and NFD spellings, `_inbox`/`_Inbox` and `_trash`/`_TRASH`, folder twins, file/folder clashes), and 6 size-after-merge cases at the 1 MiB edge (S-merged--1, S-merged-0, S-merged-1, S-copy-over, S-trash-over, S-trash-under).
- mergeFile: 951 before; adds the M50 to M53 inputs, block-count edges B1999 to B2001, cell-budget edges (C2x1412, C2x1413, C3x1150, C3x1160, C1x1997, C1x1998) and 200 random cases K0 to K199 for the line floor.

Existing differential cases whose expected output changed (all from the reference, all intended):
- planCommit, 109 cases. 87 random cases have several ops on one path, so coalescing (F-01) changes the plan. Of the 19 with one op per path, R140 is a rename onto `ǆ.md` that silently replaced a delete's write and now gets a `same-target` copy (F-01); in the other 18 only the `_trash` copy's path changed, now NFC (F-03): R3, R19, R27, R42, R43, R120, R156, R161, R195, R240, R328, R344, F11, F23, F41, F49, F59, F131. Twin-cleanup cases: G447 and G449 (were G429, G431) write `_trash` in NFC (F-03); G455 (was G437) puts both `_trash` copies of the folder twins in one folder spelling (F-05, as P45).
- mergeFile, 9 random cases (R64, R72, R302, R398, R476, R484, R498, R515, R860): `conflict/same-lines` became `conflict/unsafe-merge`, because the merge also dropped a line that base, mine and theirs all had (F-02). Before, the note was written as a per-section merge that had lost that line; now it keeps theirs, and mine goes to the conflict copy as before.
- Nothing else changed: splitBlocks, matchLines, diff3, path, size, yaml and stamp outputs are byte-identical, and the vector-derived cases moved ids only because 22 vectors were added (G379 to G382 are now G396 to G399, still tripping the guard as intended).

Second run (after F1/F2): 78 / 78 vectors, 4,608 / 4,608 differential cases.

First run (before the fixes): 73 / 73 vectors; the differential file held 2,845 cases (the first version of this file reported 2,779).

The Swift port compares and orders text the way JavaScript does: by exact UTF-8 bytes and UTF-16 code units. It doesn't use Swift's built-in String comparison, because String `==` treats NFC and NFD spellings as equal, counts `\r\n` as one character, sorts by Unicode scalar and has no final-sigma rule. See `Sources/BrainMerge/ExactText.swift`.

## Speed (release build, 3 runs, median)

| Case | First run (quiet Mac) | After F1/F2 | Old code, same moment | After F-01 to F-07 |
|---|---|---|---|---|
| mergeFile, 1 KB note | 0.11 ms | 0.10 ms | 0.13 ms | 0.14 ms |
| mergeFile, 50 KB note | 3.0 ms | 3.6 ms | 2.9 ms | 2.5 ms |
| mergeFile, 500 KB note | 17.5 ms | 40.5 ms | 34.2 ms | 18.0 ms |
| mergeFile, 2,000 notes of about 3 KB | 239 ms (0.12 ms per note) | 450 ms (0.23 ms per note) | 395 ms | 237 ms (0.12 ms per note) |
| mergeFile at the 4,000,000-cell limit | 9.9 ms | 18.2 ms | 16.4 ms | 9.6 ms |
| 5,000 paths: NFC + checkPath | 8.4 ms | 16.1 ms | 14.6 ms | 8.9 ms (now also the invisible-char check) |
| 5,000 paths: NFC + checkPath + clash check | 26.7 ms | 37.2 ms | 45.7 ms | 26.0 ms |

Per-note work budget (Gemini review F-06, spec 3 item 5: at most 8,000,000 diff cells per note in total and 2,000 blocks per side; beyond that the result is `too-large`). Third run, worst cases:

| Case | Median | Result |
|---|---|---|
| 2 blocks of 1,413 distinct lines per side: 7,997,584 cells, the most the budget allows | 9.6 ms | conflict/same-lines |
| 2 blocks of 1,414 lines: over the budget | 6.0 ms | conflict/too-large |
| 8 blocks of 1,000 lines: refused partway | 7.5 ms | conflict/too-large |
| 2,000 blocks, every block edited on both sides | 8.8 ms | merged |
| 2,001 blocks: over the block limit | 1.5 ms | conflict/too-large |

The slowest note the budget allows takes under 10 ms on the M4, well under the 100 ms target. Merges still run off the main thread (spec 3, item 6), so even a slower phone doesn't block the UI.

The second run happened while the Mac was busy (load average about 5, Chrome and Google Drive using CPU), so it is slower across the board, including merge code that did not change. The last column is the pre-fix commit benchmarked right after, under the same load: the new clash key costs nothing measurable. The paths benchmark is mostly ASCII, which takes a fast path; the fold only does real work on non-ASCII names.

These timings are for the M4 Mac. An iPhone 16 should be the same order of magnitude, but S6 hasn't measured it on the phone yet.

## Gemini review, 3 Nov 2026: F-01 to F-07 fixed

Itamar approved fixing F-01 to F-06 (and F-07, F-09, F-13) on 3 Nov 2026. Each is fixed in the spec (`merge-spec.md`), the TypeScript reference, the vectors and the Swift port. No existing spec vector changed.

| Finding | Rule now (spec section) | New vectors |
|---|---|---|
| F-01 lost edit when ops overlap | The outbox is coalesced per path (exact path if base has it, else NFC; result is the last op's content); an edit of a path not on base is planned as a create; each target takes at most one op, a later one goes to a `same-target` copy or `delete-skipped`; content renames are one-to-one (7.1, 7.2) | P30 to P36, P47 |
| F-02 a line all three sides had was dropped | The safety check counts lines: each line keeps at least min(mine, theirs, mine + theirs − base) copies, else `unsafe-merge` (5.5) | M50 |
| F-03 `_trash` path not NFC | `_trash/<path>` is written in NFC (6.2, 7.3) | P37 |
| F-04 a merge could make a note over 1 MiB | The size is checked after the merge, for the note, the conflict copy and the `_trash` copy; over the limit nothing is written, theirs stays, the op is kept, `blocked:too-large` (6.4) | P38 to P40 |
| F-05 file/folder clash and folder twins | A file and a folder with one key clash both ways; generated paths reuse the folder spelling already on GitHub or in the batch; a new note is refused next to folder twins already on GitHub (6.1, 6.3) | P41 to P45 |
| F-06 no work limit per note | 8,000,000 diff cells per note in total and 2,000 blocks per side, else `too-large`; merges run off the main thread (3) | M51 to M53 |
| F-07 invisible characters in paths | `Default_Ignorable_Code_Point` in a path is `blocked:invisible-char` (6.4) | P46 |

The S3 differential found one more hole while checking F-01: an edit of a path the old base doesn't have skipped the create checks and could write a note next to a folder twin, which the final guard then rejected (random cases O2, O8 and 36 others). Fixed by the "edit of a path not on base is a create" rule; vector P47.

F-09: the paths loop covers the 1,561 code points whose clash key differs from their NFC form, not every code point the key changes (2,671). The text above now says so. The skipped code points need NFC only, or are lowercase letters whose key is themselves, so the loop is unchanged. F-13: the bad-time count below is now 11, which is right.

Left for later: F-08 (flattened conflict-copy name can pass 255 bytes), F-10 (`heading-renamed` with another clash reports `same-lines`), F-11 (dead non-ASCII lowercase work in the `.md` check), F-12 (inline fence at a line start; a lone `\r` at EOF).

## Findings (S3)

Itamar approved fixing F1 and F2 on 3 Nov 2026. Both are fixed in the spec, the TypeScript reference, the vectors and the Swift port.

### F1. The final guard rejected a valid twin cleanup: FIXED

Random plan case R104: GitHub already holds the case twins `ǅ.md` and `ǆ.md`. A batch that edits one twin and deletes the other produced a write entry and a delete entry with the same clash key. The final guard (spec 7.6) then threw `plan bug: case clash ǆ.md`, and the whole commit failed. But deleting one twin is exactly how someone would resolve a twin pair, and a delete creates no file.

What changed:
- Spec 7.6: only writes count toward the clash-key check; a write may share a key with a delete. A failed guard is a planner bug: the app catches it, sends nothing, keeps the ops in the outbox and shows it in Needs attention instead of crashing. The reference still throws (its internal assert).
- `ref/plan.ts` and `Plan.swift`: the guard skips delete entries and uses `foldKey`.
- New plan vector P25 (edit `notes/ǅ.md`, delete `notes/ǆ.md`: a valid plan with the write, the delete and the `_trash` copy). New differential cases G423 to G437 (edit one and delete the other, both ways round, and delete both, over five kinds of twin). R104 now returns a valid plan. Editing both twins in one batch still trips the guard, as intended (G379 to G382).

### F2. The clash key was weaker than APFS: FIXED

`foldKey` was NFC + `toLowerCase()`. It is now a full case fold that ignores NFC/NFD (spec 6.3):

1. NFD;
2. each code point on its own: lowercase, then uppercase, then lowercase again, except dotless `ı` (U+0131), which is kept;
3. `ς` becomes `σ`;
4. NFC.

It is per code point and has no locale or context rules, so it is the same in TypeScript (`ref/paths.ts`) and Swift (`foldKey` in `Paths.swift`, `caseFold` and `nfd` in `ExactText.swift`). The differential test checks the 1,561 code points whose key differs from their NFC form, and Swift matches Node exactly. Compared with Python's `str.casefold()` (Unicode 16) over every code point, it puts code points into exactly the same groups. The only differences are characters new in Unicode 17, which Python doesn't know yet. `checkPath`'s blocked-folder test (`private`, `_capture`) now uses `foldKey` too.

Why not NFKC_Casefold: NFKC also merges compatibility forms such as full-width `Ａ`/`A`, `²`/`2` and `Ǳ`/`dz`, which APFS keeps as separate files. That would refuse valid notes.

APFS test, 3 Nov 2026, on this Mac's case-insensitive APFS volume, in `/tmp`. For each pair, the first name was created and then the second was checked with `existsSync`. "Old key" is NFC + lowercase. "New key" is the shipped `foldKey`. "NFKC" is NFKC followed by the new key.

| Pair | Code points | Same file on APFS | Old key | New key | NFKC + fold |
|---|---|---|---|---|---|
| `ǅ / ǆ` | 1c5 | 1c6 | yes | yes | yes | yes |
| `Ǆ / ǆ` | 1c4 | 1c6 | yes | yes | yes | yes |
| `ΟΔΟΣ / οδοσ` | 39f 394 39f 3a3 | 3bf 3b4 3bf 3c3 | yes | no | yes | yes |
| `ΟΔΟΣ/x / οδοσ/x` | 39f 394 39f 3a3 2f 78 | 3bf 3b4 3bf 3c3 2f 78 | yes | no | yes | yes |
| `οδος / οδοσ` | 3bf 3b4 3bf 3c2 | 3bf 3b4 3bf 3c3 | yes | no | yes | yes |
| `Straße / STRASSE` | 53 74 72 61 df 65 | 53 54 52 41 53 53 45 | yes | no | yes | yes |
| `ß / ss` | df | 73 73 | yes | no | yes | yes |
| `ﬁ / fi` | fb01 | 66 69 | yes | no | yes | yes |
| `ß / ẞ` | df | 1e9e | yes | yes | yes | yes |
| `K / k` | 212a | 6b | yes | yes | yes | yes |
| `İ / i̇` | 130 | 69 307 | yes | yes | yes | yes |
| `İ / i` | 130 | 69 | no | no | no | no |
| `Ａ / A` | ff21 | 41 | no | no | no | yes |
| `² / 2` | b2 | 32 | no | no | no | yes |
| `ǈ / ǉ` | 1c8 | 1c9 | yes | yes | yes | yes |
| `ﬀ / ff` | fb00 | 66 66 | yes | no | yes | yes |
| `ſ / s` | 17f | 73 | yes | no | yes | yes |
| `ı / I` | 131 | 49 | no | no | no | no |
| `ı / i` | 131 | 69 | no | no | no | no |
| `Ω / ω` | 2126 | 3c9 | yes | yes | yes | yes |
| `Å / å` | 212b | e5 | yes | yes | yes | yes |
| `é / é` | 65 301 | e9 | yes | yes | yes | yes |
| `ᾳ / ᾼ` | 1fb3 | 1fbc | yes | yes | yes | yes |
| `ᾳ / αι` | 1fb3 | 3b1 3b9 | yes | no | yes | yes |
| `ﬅ / st` | fb05 | 73 74 | yes | no | yes | yes |
| `ŉ / ʼn` | 149 | 2bc 6e | yes | no | yes | yes |
| `Ⅰ / ⅰ` | 2160 | 2170 | yes | yes | yes | yes |
| `Ⓐ / ⓐ` | 24b6 | 24d0 | yes | yes | yes | yes |
| `𐐀 / 𐐨` | 10400 | 10428 | yes | yes | yes | yes |
| `Ａ / ａ` | ff21 | ff41 | yes | yes | yes | yes |
| `a\u200Db / ab` | 61 200d 62 | 61 62 | no | no | no | no |
| `Ꭰ / ꭰ` | 13a0 | ab70 | yes | yes | yes | yes |
| `ﬃ / ffi` | fb03 | 66 66 69 | yes | no | yes | yes |
| `µ / μ` | b5 | 3bc | yes | no | yes | yes |
| `ẛ / ṡ` | 1e9b | 1e61 | yes | no | yes | yes |
| `ϐ / β` | 3d0 | 3b2 | yes | no | yes | yes |
| `Å / å` | c5 | e5 | yes | yes | yes | yes |
| `Ǳ / dz` | 1f1 | 64 7a | no | no | no | yes |
| `½ / 1⁄2` | bd | 31 2044 32 | no | no | no | yes |
| `ｶ / カ` | ff76 | 30ab | no | no | no | yes |
| `é / É` | e9 | c9 | yes | yes | yes | yes |

Score against APFS: old key 26 / 41, **new key 41 / 41**, NFKC + fold 36 / 41. The first run's table said the old key matched on `ΟΔΟΣ`/`οδοσ`; it didn't, because `toLowerCase()` turns the last `Σ` into `ς`.

What changed:
- Spec 6.3 (the key, the clashing and non-clashing pairs) and 6.4 (blocked folders compared by clash key).
- `ref/paths.ts` (`foldKey`, blocked-folder check) and `ref/plan.ts` (final guard uses `foldKey`). There's no other inline NFC + lowercase key left. The `.md` suffix check still uses plain lowercase, which is unaffected.
- New plan vectors: P26 (`STRASSE` refused next to `Straße`), P27 (`οδοσ` refused next to `οδος`, and folder `οδοσ/` refused next to `ΟΔΟΣ/`), P28 (`ı`/`I` and `İ`/`i` are not clashes), P29 (full-width `Ａ` is not a clash with `A`).
- Differential: G382 (edit both `ΟΔΟΣ/x.md` and `οδοσ/x.md`) now trips the guard; before, it was accepted although APFS holds one file. In the 500 random path cases, only `fold` changed, in 87 cases, all because of `ς` or `ß`.
- Caveat: case mappings depend on the Unicode version. Node 26 uses Unicode 17, and the Swift stdlib on this Mac matched it on every code point. If an iPhone runs an older stdlib, characters added in Unicode 17 could fold differently. That's very unlikely to matter for note names. S6 should repeat the APFS test on the iPhone.

### F3. Minor
- In random plan cases, a time that isn't UTC ISO 8601 ending in `Z` throws an error (11 cases) instead of being normalised. This is intended input validation, so it isn't a bug. The app must always pass a `Z` timestamp.

## Files

- `Sources/BrainMerge/`: Diff3, Sections, Merge, Plan, Paths, PathMap, ExactText
- `Sources/bench/Bench.swift`
- `Tests/BrainMergeTests/`: vector tests plus differential tests (now 100 vectors) (`Resources/differential.json`, generated by `Tools/differential/gen.ts`)
- `scripts/verify.sh`: build, test and bench, with logs in `.logs/`
