# Search across all notes: `NoteSearch` in BrainNotesKit

Branch `cloud/search-kit`, from `editor-spike` at f6e792a. Kit only: no app, sync or BrainMerge change.

## What it is

A new target and product, `NoteSearch`, in `Packages/BrainNotesKit`. It uses only Swift and Foundation, so it builds on Linux.

- `SearchText` splits text into words and folds them. It drops Hebrew points and cantillation, turns final letters into base letters, and drops direction marks, also inside a word. It lowercases Latin and removes accents. Geresh and gershayim join acronyms (`צה״ל`, `צה"ל`). Ranges are UTF-16 offsets into the original text.
- `NoteSearchIndex` is an in-memory index. `upsert` and `remove` keep it current as notes are added, changed and deleted. A rename is a remove and an upsert. It is safe to use from any thread.
- `NoteSearchResult` gives the id, title, `titleMatches`, `snippet`, `snippetMatches`, `bodyMatches`, `modified` and `score`. Ranges are merged UTF-16 offsets. They work as `NSRange` directly, or as `String.Index` through `NoteSearchResult.indexRanges(_:in:)`.

## Matching and ranking

Every query word must match. The best match counts, in this order:

1. the word itself;
2. the word with Hebrew prefix letters (ו ה ב ל מ ש כ, one or two) off the note's word or the query's word;
3. the start of a word ("plan" finds "planet");
4. the start of a word once the prefix letters are off;
5. inside a word.

Matches 4 and 5 need at least three typed letters. Any title match beats any body match. Then come the sum over the query words, then the newest note, notes without a date last, then the title.

Decisions on prefix letters, made to keep false positives low on short words:

- At least three letters must stay after stripping. `מים` is not `ים`, `כלב` is not `לב`, `בעל` is not `על`.
- The exception is after ה, the article, where two letters may stay: `הים`, `הגן`, `ההר`. This also lets `הלך` match `לך`, at a low rank.
- Letters never come off both sides at once. Otherwise `שלום` (less ש) would equal `הלום` (less ה). The cost: `בבית` does not find `לבית`. `בית` finds both.
- A prefix match marks only the typed part. A stripped match marks the word without its prefix.

## Wiring into the app (not done here)

The app still uses the SQLite FTS `SearchIndex`, and nothing in it changed. To switch:

1. Add the `NoteSearch` product to the app target.
2. Fill the index from `NoteStore` at launch. Use `NoteText.title(of:path:)` for the title and the body without its frontmatter. Body ranges are offsets into that body, so add the frontmatter's UTF-16 length to mark the file.
3. Call `upsert` and `remove` wherever `SearchIndex.upsert` and `remove` are called today.

## Verification

- `cd Packages/BrainNotesKit && swift test` on Linux declares only NoteSearch, with no dependencies to fetch. On a Mac the full kit and its tests are declared as before.
- `SearchScaleTests` builds 2,000 synthetic notes of about 2 KB, runs 17 queries, then changes and deletes 100 notes and queries again. The budgets are generous: 30 s to build, 1 s per query, 5 s for all queries. Timings print as `SCALE`.
- **This branch was written without a Swift toolchain.** The cloud session could not download one, so nothing has been compiled or run in Swift yet. Every test expectation was checked against a line-by-line Python port of the algorithm. That port caught one bug (a direction mark after a word was counted into its range) and two wrong expectations, all fixed. The first real `swift test` is still to come.
