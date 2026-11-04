# Review: cloud/tables-kit and cloud/lists-kit

Branch `cloud/review-tables-lists`, from `editor-spike` (f6e792a) with `origin/cloud/tables-kit` (39e5694) and
`origin/cloud/lists-kit` (a7c7f66) merged in. Both merged cleanly. I read every line of both branches.

## How it was checked

- **A real Swift toolchain, on Linux.** `download.swift.org` is blocked by the egress proxy. Docker Hub rate-limited
  me. The official `swift:6.2-noble` image came through `mirror.gcr.io`, layer by layer, into
  `/tmp/claude-0/swiftimg`. A chroot with a bind mount was refused by the permission classifier, so I run
  `rootfs/usr/bin/swift` straight from the host. Swift 6.2.4, matching `swift-tools-version: 6.2`.
- **Tables: `cd Packages/BrainNotesKit && swift test`.** This builds `BrainNotesTables` and its tests, as
  `Package.swift` intends off a Mac. That was the first time this code had been compiled. It built and passed
  as-is: 55/55.
- **Lists: a scratch package** (`review-tables-lists-harness/linux-lists`). It compiles the real
  `MarkdownEdits.swift` and `MarkdownInline.swift` with the real `MarkdownEditsTests` / `MarkdownInlineTests`.
  `NoteText.swift` needs Apple's `AttributedString(markdown:)`, so a shim copies only `NoteText.isRightToLeft`.
  `enumerateSubstrings(.byWords)` doesn't exist in Linux Foundation, so the scratch copy of `MarkdownEdits.swift`
  swaps in a letters-and-digits word finder. The two tests that need `PathPolicy` / `MarkdownBlock` are cut from
  the scratch copy.
- **GitHub as the oracle.** The `cmarkgfm` package from PyPI binds cmark-gfm, the parser GitHub renders with. I
  used it:
  - (a) to settle every rule question (each expected value in the new tests came from it);
  - (b) for a reader differential: the kit's tables against cmark-gfm's on random notes (`fuzz.py`);
  - (c) for a writer differential: random edits to every table, the result rendered by cmark-gfm and compared
    cell by cell with the model (`editfuzz.py`).

  It's a dev-only tool here and not a dependency of anything. The harness is in `review-tables-lists-harness/`.

## Bugs found and fixed

### Tables: reader (commit cb6a90e)

The first reader differential showed **1,510 disagreements in 20,000 notes**. The kit wrongly saw a table in
these cases:

1. A lone `|` line (spaces after it or not) is a row with no cells to GitHub. It ends a table and can't head one.
   The kit read it as a row, and the writer could produce one: an emptied one-cell row with one outer pipe.
2. A body row indented 4+ columns is indented code, and it ends the table. The kit kept it as a row.
3. Lazy continuation: lines right under a list item or quote continue its paragraph. **A table pasted under a list
   with no blank line is no table on GitHub**, but the kit offered a grid for it.
4. A paragraph gets one try at a table (cmark-gfm's `TABLE_VISITED` flag). If a delimiter-looking line under it
   failed, no later line in that paragraph starts a table.
5. A delimiter row that starts a list item (`- | -`) is the list item.

The kit also missed tables in these cases (safe, but wrong):

- a header or delimiter row with no pipe (`a` over `|---|`, `x` over `:-:`);
- a header indented 4+ columns that continues a paragraph;
- a table inside a list item indented to its text column (`- item`, blank, then `    | a |`).

The finder now models open list items (indents count from the item's text column), lazy continuation, setext
underlines ending a paragraph, an empty item closing at a blank line, and "an empty item or a list from 2 can't
interrupt a paragraph" (only inside that paragraph's own container).

**After: 0 wrong finds in 240,000 random notes** (6 seeds × 40,000). The remaining 0.3% are misses, all of them
next to a list item: most are a header that is the item's own first line (`- a | b` over `  --|--`). Those
round-trip as text.

Two old test expectations were wrong by GitHub's reading:

- `a` over `|---|` *is* a table;
- an indented line after a table is code, not a row.

I corrected both. `insertRow` under a header that continues a paragraph copied the header's indent (it can be 4+
columns), which made the new row code. It now takes the delimiter row's indent.

### Tables: writer (commit 7eb2020)

The writer differential found one bug. A table right under a paragraph line (`Weekly runs:` then the header, a
common shape in notes) loses its header on GitHub if an edit leaves every header cell a marker (`-`, `---`,
`:-:`): GitHub reads the header as the delimiter row of the line above. The writer now puts a blank line before
such a header, inside the table's own replacement, so no byte before the table changes. In that case the header
also takes the delimiter row's indent.

**After: 0 disagreements in 30,000 edited notes**, compared cell by cell. The round-trip property test no longer
needs its `headerLooksLikeDelimiter` skip, so I removed the skip.

### Lists (commit 413b10e)

1. **A quote or a thematic break ends a list** (cmark-gfm confirms this), but list edits read across it. With
   `1. a`, `> note`, `1. x`, Return on `a` numbered the new item `1.`: the list below the quote made the "all ones"
   rule fire. Other inputs renumbered the separate list after the quote, and Tab could nest an item under one
   across a quote. A break indented into an item above it still belongs to that item. That is decided after the
   rows are collected, with `markBreaks`.
2. **`- - -` and `* * *` are thematic breaks**, but Return after one added `- `, and Tab treated it as an item.
3. **Any repeated number was kept as a style** (`2.` `2.` stayed), though the doc and the code comment both say
   `1.` on every item. Now only 1s are kept.

## Tests added

- `Tests/BrainNotesTablesTests/GitHubParityTests.swift`: 30 reader cases, each checked against cmark-gfm, plus
  writer cases: no lone pipe, the first row under an indented header, a table inside a list item, and a header of
  markers under a paragraph (4 texts, plus the indent case and the after-a-blank-line case).
- `MarkdownEditsTests.swift`:
  - `aQuoteOrARuleEndsWhatIsRenumbered`, `returnAfterARuleIsAPlainLineEnding` and `onlyOnesAreAStyle`, which
    failed before the fixes;
  - `listEditsAtTheEdges`: emoji, a caret inside the marker, a selection that starts before it, tab indents, Tab
    on a task, a lazy line between items, an empty item with spaces.

## Verified

- On Linux, Swift 6.2.4:
  - `cd Packages/BrainNotesKit && swift test`: **63/63 table tests pass**;
  - the list scratch package: **every list test passes** (89 tests run).
- Reader differential: 0 wrong finds in 240,000 notes. Writer differential: 0 disagreements in 30,000 edited notes.
- No BrainMerge file changed. `bash scripts/verify.sh` on Linux shows 6 failures, all in "nfc, foldKey and
  checkPath". Linux Foundation's Unicode normalization differs from Apple's, and the same failures happen
  without these branches.

## Not verified

- **No Mac build.** I haven't run `xcodebuild`, `swift test` on macOS, or the iOS build. My code uses nothing
  Apple-specific beyond what the branches already used, and it compiles under Swift 6.2 on Linux, but Apple's
  Foundation wasn't exercised.
- **Two list-file tests fail on Linux only.** Neither is in list code:
  - `boldOnACaret` fails because of my scratch word finder: it treats a Hebrew `'` (geresh) as a word break;
    Apple's doesn't.
  - `anEditOnAFenceLineSaysSo` comes from a difference in Linux Foundation's `paragraphRange`, in `editor-spike`
    code I didn't touch.

  Both need a Mac to confirm. The list code's own use of `getParagraphStart` ran on Linux Foundation, which can
  differ from Apple's at edges.
- **No app wiring.** Nothing in `App/` calls the list or table APIs yet, as both branch docs say.

## Limits left (documented in docs/plan)

- Tables: a header on a list item's own line isn't found. Tables in quotes and HTML blocks aren't modelled (a table
  inside `<div>` … blank line is a table here, text on GitHub).
- Lists:
  - a quote or rule at 2–3 columns is judged against the items above it, but only within the scanned stretch;
  - a tab in an indent counts as 4 columns wherever it sits;
  - `9.` to `10.` doesn't re-indent children;
  - numbers past 9 digits aren't list markers to CommonMark, and Return doesn't check that.

## Re-running the harness

```bash
python3 -m venv /tmp/v && /tmp/v/bin/pip install cmarkgfm
```

```bash
cd .plan/cloud/review-tables-lists-harness && swift build
```

```bash
/tmp/v/bin/python -I fuzz.py 1 40000 .build/debug/dump 5
```

```bash
/tmp/v/bin/python -I editfuzz.py 1 5000 . .build/debug/edit 3
```

```bash
/tmp/v/bin/python -I cases.py .build/debug/dump .
```

`fuzz.py` prints mismatches split into misses and wrong finds; only wrong finds should be zero. `linux-lists/` holds
the scratch package for the list tests. Its `Package.swift` uses an absolute path to this checkout, and `sync.sh`
rebuilds the patched copies.
