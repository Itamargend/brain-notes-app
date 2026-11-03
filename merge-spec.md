# M3 merge spec (spike S2)

Status: draft from spike S2, 3 Nov 2026. The TypeScript reference in `spec/merge/ref/` passes every vector. The Swift port (S3) must pass the same JSON files, unchanged.

Rule approved on 3 Nov: when both sides change the same text, the note keeps the GitHub version and the phone's version goes to `_inbox` as a copy. No text is ever thrown away.

Names: base is the version the edit started from, mine is the phone's version, theirs is what GitHub has now.

| File | What it is |
| --- | --- |
| `spec/merge/vectors.json` | 49 file-merge vectors (`mergeFile`), including per-section conflicts (M44 to M49) |
| `spec/merge/plan-vectors.json` | 24 commit-planner vectors (`planCommit`): deletes, renames, NFC, case clashes, path policy |
| `spec/merge/gen_vectors.py` | Writes both JSON files. Expected values are typed by hand from this spec, never computed by the code under test |
| `spec/merge/ref/*.ts` | TypeScript reference (spike code, not app code) |
| `tests/merge3-vectors.test.ts` | Runs both vector files |
| `tests/merge3-property.test.ts` | 20,000 random two-sided edits over `tests/fixtures/notes`: no added line lost, every conflict copy is all of mine, a per-section note passes the line check, the safety net fires only after a structural edit, results are deterministic |

## 1. Lines

- Text is split after each `\n`, so every line keeps its ending (`\n` or `\r\n`). A lone `\r` is not a line break. The last line may have no ending.
- Lines are compared as exact UTF-16 strings. A trailing space is a change (M33). No Unicode normalisation of content.
- Line endings are kept as they are. CRLF files stay CRLF (M25). A missing final newline is kept (M26).

## 2. Blocks

A note is cut into blocks. Each block has a key and its lines. Joining the blocks gives back the exact bytes (checked on all 2,434 notes in the brain clone).

### 2.1 Frontmatter

- Key `fm`. Only when line 0 is `---` and a later line is `---` or `...` (trailing spaces or tabs allowed on both). The block runs up to and including that closing line.
- An unclosed `---` is not frontmatter (M37). A `---` later in the body is a thematic break (M12).

### 2.2 Preamble and fences

- Key `pre`: the lines before the first heading, if there are any.
- Inside fenced code, nothing is a heading. A fence opens with 3 or more backticks or tildes, after up to 3 spaces. It closes with the same character, repeated at least as many times, followed only by spaces (M14).

### 2.3 Headings

- A block starts at each ATX heading: up to 3 spaces, 1 to 6 `#`, then a space, a tab or the end of the line.
- Key: the heading line without its line ending and trailing spaces, plus `#` and its occurrence number. Two `## Meeting` headings become `## Meeting#1` and `## Meeting#2` (M13).
- Setext headings (text underlined with `===`) stay body text (M38).

## 3. Line matching

The diff has to be deterministic, so Swift and TS make the same choices:

1. Match the common prefix greedily, then the common suffix.
2. On the middle, fill an LCS table where `lcs[i][j]` is the LCS of `a[i..]` and `b[j..]`.
3. Walk forward:
   - Lines equal and `lcs[i][j] == lcs[i+1][j+1] + 1`: match them.
   - Else, `lcs[i+1][j] >= lcs[i][j+1]`: skip `a[i]`.
   - Else: skip `b[j]`.
4. If the middle is larger than 4,000,000 cells, stop and treat the file as a conflict (`too-large`).

## 4. Three-way line merge (diff3)

- A base line is stable when both mine and theirs match it, and the previous stable line matches the previous line on both sides.
- Between stable lines, each chunk is decided like this:

| Chunk | Result |
| --- | --- |
| mine equals base | theirs |
| theirs equals base | mine |
| mine equals theirs | that text |
| Base empty, both inserted different lines (4.3) | theirs, then mine |
| Anything else | conflict |

- Edits on adjacent lines, with no unchanged line between them, conflict. git does the same (M06, M36).

### 4.3 Union of insertions

When both sides insert at the same point and remove nothing, both are kept, theirs first. Example: both append to the Timeline (M08, M34). Turning `unionInsertions` off makes this a conflict (M35). Decided by Itamar on 3 Nov: keep it on.

## 5. File merge

### 5.1 Whole-file rules, in order

| Case | Result kind | Note content | Copy |
| --- | --- | --- | --- |
| mine equals theirs (both deleted counts too) | `same` | theirs | none |
| mine equals base | `take-theirs` | theirs | none |
| theirs equals base | `take-mine` | mine | none |
| I deleted, GitHub edited | `delete-skipped` | theirs | none; shown in Needs attention |
| GitHub deleted, I edited | `conflict` / `deleted-remotely` | stays deleted | mine |
| Both created the path | `conflict` / `both-created` | theirs | mine |
| Otherwise | block merge (5.2) | | |

### 5.2 Block merge

For each key, taking keys from base, then mine, then theirs:

| Case | Result |
| --- | --- |
| mine equals theirs | theirs |
| mine equals base | theirs (may be "gone") |
| theirs equals base | mine (may be "gone") |
| One side removed the block, the other changed it | clash `section-deleted` (M19, M20) |
| Both added the key with different text | clash (M17) |
| Otherwise | diff3 on the block's lines; a conflict is a clash |

- If a base key is gone on both sides and each side has a key the other lacks, it is a clash `heading-renamed` (M40). Without this rule, two different renames of one heading would keep the body twice. Both sides deleting the same section is still clean (M41).
- Per-section conflicts (decided by Itamar on 3 Nov, his M2 rule). If any block clashes, the result is a `conflict` with `clashes` listing the clashing keys:
  - every clean block is merged as above;
  - a clashing block keeps theirs' version in the note. If theirs removed it, it stays removed (M46); if mine removed it, theirs' edited block stays (M45);
  - mine goes, whole and unchanged, to the conflict copy (6.1). The copy holds all of mine, not just the clashing sections, so nothing is lost and the section can be read in context.
  - Examples: one clash plus clean edits elsewhere (M44, P24), both added the same heading (M47), two clashes plus clean edits on both sides (M48).
  - When mine's only edits are in clashing blocks, the note simply equals theirs (M06, M07, M17, P09).
- Whole-note conflicts (note = theirs, copy = mine) remain for: `deleted-remotely`, `both-created`, `too-large`, `heading-renamed` (M40, M49), a line conflict in the frontmatter fallback (5.5, M43), and the safety net (5.5).

### 5.3 Block order

- Use theirs' order (M30).
- Insert each block that exists only in mine right after its nearest earlier block in mine's order that was kept. With no such block, insert it at the start (M15, M16, M31, M32).

### 5.4 Join

Blocks are joined as they are. If a block that has no line ending is no longer last, add the predominant line ending of theirs (M27).

### 5.5 Frontmatter change and safety check

- If base, mine and theirs do not all agree on having frontmatter, block keys would shift. In that case the whole file is merged with diff3 instead (M42, M43).
- Every merged note, clean or per-section, must pass a safety check. The check counts lines by their text, ignoring line endings. The note must:
  - keep every line that theirs added, and every line that mine added unless the result is a per-section conflict (then the copy holds all of mine);
  - contain no line that is in none of the inputs;
  - repeat no line more often than `max(mine, theirs, mine + theirs - base)`.
- Safety net: if the check fails, the file falls back to a whole-note conflict, reason `unsafe-merge`: the note keeps theirs byte for byte and mine goes, whole, to the copy. It never loses a line.
- How often it fires (3 Nov rerun): 1,576 of 20,000 aggressive random edit pairs in the property test, and 123 of 12,170 random edits on real brain notes. The property test asserts that it fires only when a side changed a structural line (a heading, fence or frontmatter delimiter), which moves body lines between blocks; a typical case is mine deleting a heading line while theirs edits that section. Ordinary text edits never reach it.

## 6. Conflict copy and paths

### 6.1 Conflict copy

- Path: `_inbox/conflict-<slug>-<YYYYMMDD-HHMMSS>.md`. The slug is the note path without `.md`, with `/` replaced by `-`, in NFC. The time is the op time in UTC.
- If that path is taken, ignoring case and normalisation, try `-2`, `-3` and so on (P10).
- Content: the header below, then mine exactly as it was. Strings are JSON-quoted, which is valid YAML (P23). `type: conflict` lets brain ingest skip these files (decided by Itamar on 3 Nov). The clashing sections are not in the header; they are listed in Needs attention via `clashes`.

```
---
type: conflict
conflict_of: "people/demo-person.md"
device: "spike-mac"
created: "2026-11-03T10:30:00Z"
---
```

### 6.2 Unicode normalisation

- New paths (creates, copies, trash) are written in NFC (P11).
- A path that already exists keeps its exact bytes, even if it is NFD (P12). The app must never rename by accident.

### 6.3 Case and normalisation clashes

Spike S1 showed that GitHub stores `Case.md` and `case.md`, or NFC and NFD spellings, as two files. A Mac or iPhone cannot hold both.

- The clash key is NFC plus lowercase. Folders are checked too: `People/x.md` clashes with an existing `people/` folder (P15).
- A new path whose clash key matches a different existing path, or another new path in the same batch, is refused with `case-clash`. The op stays in the outbox and appears in Needs attention (P13 to P16).
- The brain at HEAD has no such collisions today: 0 of 2,434 notes, and every path is NFC.

### 6.4 Path policy

The app refuses to write:

- any path that is not `.md`;
- any path with a segment starting with `.`;
- anything in a folder named `private` or `_capture` (case-insensitive);
- empty, `.` or `..` segments, or a leading `/`;
- control characters;
- more than 1 MiB of content (P18, P19).

The secret scan stays in the app layer and is not part of these vectors. No brain note at HEAD trips the policy.

## 7. Commit planner

`planCommit(baseTree, theirsTree, ops, renames, device, time)` returns:

- `entries`: writes and deletes, sorted by UTF-16 path;
- `attention`: items for Needs attention;
- `kept`: indexes of blocked ops, which stay in the outbox;
- `noops`: indexes of ops that need nothing.

It runs again on every pull and on every 422 retry, against the new head. All entries go into one atomic commit (Git Data API, see the v2 plan).

### 7.2 Renames

- An edit or delete of a path that GitHub has renamed follows the new path. The new path comes from compare's `previous_filename` (P07).
- Without that, a rename is assumed only when exactly one new path holds the exact base text (P06).

### 7.3 Deletes are re-checked after every pull (S1 finding)

| Case | Result |
| --- | --- |
| Path already gone on GitHub | no-op. Never send `sha: null` for a missing path, because GitHub fails the whole tree with 422 `BadObjectState` (P02) |
| GitHub text equals base | delete the path and write `_trash/<path>` in the same commit (P01) |
| `_trash/<path>` exists with other text | use `-2` (P04) |
| `_trash/<path>` exists with the same text | delete only (P05) |
| GitHub edited it | skip the delete, and add `delete-skipped` to Needs attention (P03) |

### 7.4 Creates

A create on a path that already exists is merged with base = none. The result is `both-created`, so the note keeps theirs and mine goes to a copy (P17).

### 7.6 Final guard

Before sending, assert three things, or the planner throws:

- every delete targets a path that exists on the new head;
- no two entries clash by key;
- every write passed the path policy.

## Decisions (3 Nov 2026, Itamar)

- Q1, same-point inserts: keep both lines, GitHub's first, as a clean merge (4.3).
- Q2, clashes: merge the clean sections; only the clashing sections keep GitHub's version in the note, and mine goes to the `_inbox` conflict copy, whole. This is the M2 rule (5.2). If the line check fails, the whole note keeps GitHub's version (5.5).
- Q3, copy header: `type: conflict`, `conflict_of`, `device`, `created` (6.1).

## Still open

- Not done: the Swift run of these vectors. Swift is not on the box, so this moves to S3 on the Mac.
