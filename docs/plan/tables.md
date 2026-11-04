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
- **Rows that would read differently get both outer pipes.** Every changed row is read back before it's written. A first cell starting `#`, `-`, `>` or a fence, an empty last cell, a header or delimiter row with no pipe left, or an emptied first header cell whose spaces would make 4 columns of indent: those rows are written as `| ... |`.
- **Line endings.** New lines use the header's line ending. The table's last line keeps the ending it had, so a table at the end of a file with no final newline still has none.
- **Where a table ends:** at a blank line, or a line that starts a quote, heading, fence, thematic break or list item. Any other line is a row, as in the GFM spec. Nothing inside a fence or front matter is a table. Tables inside quotes or list items stay text.
- **Linux.** Off macOS, `Package.swift` declares only the tables target and its tests. The dependencies stay declared everywhere, so `Package.resolved` doesn't change. Off a Mac, SwiftPM warns that they're unused.

## Known limits

- A header made only of delimiter cells (`| --- | :-: |`) can be read as the delimiter row of the line above it, if that line has the same number of cells. GitHub reads it that way too. The property tests skip that case.
- Tables in quotes and list items aren't recognised. They round-trip as text.
- No realignment ("pretty print") of a whole table yet.

## Verification status

**Not compiled or run here.** This cloud session couldn't download a Swift toolchain: the egress proxy refused `download.swift.org`, and apt, pip and npm were unreachable too. To make up for that:

- I mirrored the parser, the writer and every edit line for line in JavaScript. A property run on the mirror passed 600,000 random notes and 840,000 random edits with no failures. Each run checked byte-identical round-trips, that the bytes outside the edited table didn't change, the same table count on re-read, and that the table re-reads as the model. That run found one bug, which is fixed in both versions: the emptied-header indent case above.
- I checked every golden value in the Swift tests against the mirror.

Before merging: run `cd Packages/BrainNotesKit && swift test` on Linux and `swift test` / `xcodebuild` on a Mac. The likeliest failures are compile-level, not logic.
