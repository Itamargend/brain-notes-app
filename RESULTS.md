# Spike S3 results: Swift port of the Brain Notes merge

First run 3 Nov 2026 (18:23 UTC), second run after the F1/F2 fixes 3 Nov 2026 (18:43 UTC): MacBook Air (Mac16,12), Apple M4, 10 cores, macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2. Logs from `scripts/verify.sh` are in `.logs/` (git-ignored).

## Verdict

**Pass.** The Swift package `BrainMerge` (no third-party dependencies, macOS 26 and iOS 26) reproduces the TypeScript reference in `spec/merge/ref/` exactly, and it is fast enough to run on the main device path.

## Correctness

After the F1 and F2 fixes (second run, 3 Nov 2026, 18:43 UTC, Node v26.7.0 for the generator):

| Check | Result |
|---|---|
| `vectors.json` (`mergeFile`) | 49 / 49 |
| `plan-vectors.json` (`planCommit`) | 29 / 29 (24 before, plus P25 to P29) |
| TypeScript reference against the same vectors | 78 / 78 (the old reference fails P25, P26, P27) |
| Bundled vector files byte-identical to `spec/merge` | yes |
| Differential vs reference (`Tools/differential/gen.ts`, seed 20261103) | 4,608 / 4,608 |

Differential breakdown: diff3 300, freePath 150, splitBlocks 250, paths 2,093 (500 random plus every one of the 1,561 code points the clash key changes, plus 32 fold edge cases), matchLines 202 (including the 4,000,000-cell limit), path size limits 8, yaml 53, stamp 13, planCommit 588 (418 before; adds the P25 to P29 inputs, 15 twin-cleanup cases G423 to G437 and 150 random cases F0 to F149 over fold-twin names), mergeFile 951. In total 14 tests in 2 suites, all passing.

First run (before the fixes): 73 / 73 vectors; the differential file held 2,845 cases (the first version of this file reported 2,779).

The Swift port compares and orders text the way JavaScript does: by exact UTF-8 bytes and UTF-16 code units. It doesn't use Swift's built-in String comparison, because String `==` treats NFC and NFD spellings as equal, counts `\r\n` as one character, sorts by Unicode scalar and has no final-sigma rule. See `Sources/BrainMerge/ExactText.swift`.

## Speed (release build, 3 runs, median)

| Case | First run (quiet Mac) | After the fixes | Old code, same moment |
|---|---|---|---|
| mergeFile, 1 KB note | 0.11 ms | 0.10 ms | 0.13 ms |
| mergeFile, 50 KB note | 3.0 ms | 3.6 ms | 2.9 ms |
| mergeFile, 500 KB note | 17.5 ms | 40.5 ms | 34.2 ms |
| mergeFile, 2,000 notes of about 3 KB | 239 ms (0.12 ms per note) | 450 ms (0.23 ms per note) | 395 ms |
| mergeFile at the 4,000,000-cell limit | 9.9 ms | 18.2 ms | 16.4 ms |
| 5,000 paths: NFC + checkPath | 8.4 ms | 16.1 ms | 14.6 ms |
| 5,000 paths: NFC + checkPath + clash check | 26.7 ms | 37.2 ms | 45.7 ms |

The second run happened while the Mac was busy (load average about 5, Chrome and Google Drive using CPU), so it is slower across the board, including merge code that did not change. The last column is the pre-fix commit benchmarked right after, under the same load: the new clash key costs nothing measurable. The paths benchmark is mostly ASCII, which takes a fast path; the fold only does real work on non-ASCII names.

These timings are for the M4 Mac. An iPhone 16 should be the same order of magnitude, but S6 hasn't measured it on the phone yet.

## Findings

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

It is per code point and has no locale or context rules, so it is the same in TypeScript (`ref/paths.ts`) and Swift (`foldKey` in `Paths.swift`, `caseFold` and `nfd` in `ExactText.swift`). The differential test checks all 1,561 code points it changes, and Swift matches Node exactly. Compared with Python's `str.casefold()` (Unicode 16) over every code point, it puts code points into exactly the same groups. The only differences are characters new in Unicode 17, which Python doesn't know yet. `checkPath`'s blocked-folder test (`private`, `_capture`) now uses `foldKey` too.

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
- In random plan cases, a time that isn't UTC ISO 8601 ending in `Z` throws an error (10 cases) instead of being normalised. This is intended input validation, so it isn't a bug. The app must always pass a `Z` timestamp.

## Files

- `Sources/BrainMerge/`: Diff3, Sections, Merge, Plan, Paths, PathMap, ExactText
- `Sources/bench/Bench.swift`
- `Tests/BrainMergeTests/`: vector tests plus differential tests (now 78 vectors) (`Resources/differential.json`, generated by `Tools/differential/gen.ts`)
- `scripts/verify.sh`: build, test and bench, with logs in `.logs/`
