# Markdown tables in BrainNotesKit

Branch `cloud/tables-kit`, from `editor-spike` at f6e792a.

## What it is

`BrainNotesTables`, a new target in `Packages/BrainNotesKit`. It's plain Swift: no Foundation, no Apple frameworks, no dependencies. `BrainNotesKit` re-exports it (`Sources/BrainNotesKit/Tables.swift`), so the app gets it without a project change.

- `TableDocument(parsing:)` cuts a note into `.text` and `.table` pieces. Joining them gives the note back byte for byte.
- `MarkdownTable` keeps each line as indent, outer pipes, trailing spaces, line ending, and per cell the padding before, the content as written, and the padding after. A line nothing has touched keeps its original bytes.
- Edits: `setCell`, `setHeader`, `insertRow`, `removeRow`, `insertColumn`, `removeColumn`, `setAlignment`. An edit rewrites only the lines it changes. `TableDocument.updateTable(at:)` changes one piece, so the rest of the file stays byte-identical. `utf16Range(ofTable:)` gives the editor one replacement range.

## Decisions

- **Pipes follow GitHub (cmark-gfm).** A pipe right after a backslash stays in its cell. Backticks don't protect a pipe: `` `a|b` `` is two cells on GitHub, so it's two cells here. `Cell.text` reads `\|` as `|`, inside code too. Setting a text writes every `|` as `\|`, so typed text always comes back the same.
- **New text is one line.** Line breaks become spaces and the ends are trimmed, which GitHub does anyway.
- **Padding.** An edited cell keeps its own padding. A new or emptied cell takes the row's padding, else the header's. Tables aren't realigned: the diff stays small. Alignment keeps the delimiter cell's width where it can (`-----` becomes `:----`).
- **Ragged rows stay ragged.** A short row isn't padded until a cell past its end is set. A new column is added to rows that reach it. Extra cells are kept.
- **Rows that would read differently get both outer pipes.** Every changed row is read back before it's written. A first cell starting `#`, `-`, `>` or a fence, an empty last cell, a header or delimiter row with no pipe left, a lone `|` (no cells to GitHub), or padding that would make 4 columns of indent: those rows are written as `| ... |`.
- **A header of only markers under a paragraph line gets a blank line above it** (added in review). Otherwise GitHub would read it as that line's delimiter row. The blank line is inside the table's replacement, so nothing before the table changes.
- **Line endings.** New lines use the header's line ending. The table's last line keeps the ending it had, so a table at the end of a file with no final newline still has none.
- **Where a table is: as cmark-gfm finds it** (reworked in review, see `.plan/cloud/review-tables-lists.md`). A paragraph line, then a delimiter row. Neither needs a pipe if the other has one (or the delimiter has a colon). A paragraph gets one try at a table. Lines that lazily continue a list item's or quote's paragraph aren't tables. Indents count from the text column of the list item the table is in. A table ends at a blank line, a line that starts another block, a lone `|`, a line 4 columns past the item's text (indented code), or a line left of the item. Nothing inside a fence or front matter is a table. Tables inside quotes stay text.
- **Linux.** Off macOS, `Package.swift` declares only the tables target and its tests. The dependencies stay declared everywhere, so `Package.resolved` doesn't change. Off a Mac, SwiftPM warns that they're unused.

## Known limits

- A table whose header is a list item's own first line (`- a | b` over `  --|--`), or lazily continues an item's paragraph, is a table on GitHub but text here: the header would hold the marker. It round-trips as text. Every disagreement left that I sampled from the differential runs (about 35) is a miss of this kind, next to a list item; none is a table GitHub doesn't show.
- Tables in quotes aren't recognised. They round-trip as text.
- HTML blocks aren't modelled: a table inside `<div>` … blank line is a table here, text on GitHub.
- No realignment ("pretty print") of a whole table yet.

## Verification status

Updated in review (`cloud/review-tables-lists`): compiled and tested on Linux with Swift 6.2.4, all table tests passing. The reader and the writer were also checked against cmark-gfm itself on random notes. Details are in `.plan/cloud/review-tables-lists.md`. Still unverified: a Mac build, `xcodebuild`, and the app.

The original note: this branch was first written without a toolchain and checked with a JavaScript mirror (600,000 random notes, 840,000 random edits).
