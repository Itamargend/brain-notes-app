# List editing in the kit

Branch `cloud/lists-kit`, from `editor-spike` at `f6e792a`. Kit only: nothing in `App/` calls these yet.

## API (`MarkdownEdits`, `Packages/BrainNotesKit/Sources/BrainNotesKit/MarkdownEdits.swift`)

| Key | Call | Returns |
|---|---|---|
| Return | `newLine(in:selection:fences:)` | Always an `Edit`. Outside a list it is a plain line ending of the note's own kind, so it can replace the CRLF special case in `MarkdownViews.swift`. |
| Tab | `indentListItems(in:selection:fences:)` | `nil` if no chosen paragraph is a list item: let Tab do what it does elsewhere. An edit that `changesNothing` means it's still a list, with nowhere to go: swallow the key. |
| Shift-Tab | `outdentListItems(in:selection:fences:)` | Same as Tab. |
| (paste, delete) | `renumberLists(in:selection:fences:)` | Numbers the touched numbered lists from their first number. |

`fences` is optional: pass the editor's `FencedCode` if it has one, else the kit works it out for the note (only when the caret is on a list item).

## Behaviour

- **Continue**: same indent bytes and marker (`-`/`*`/`+`), `[ ] ` for a task (always open), next number with the same `.` or `)`.
- **Direction**: the new item gets its line's mark if it has one (leading or trailing), else `U+200F` if the line reads right to left. It always goes after the marker, as `toggleDirection` puts it. English lines get no mark.
- **End**: Return on an item with no text. If nested, it moves out one level first (as in Notes, Docs, Obsidian); at top level the whole line becomes empty, mark included, so no invisible character is left in the file.
- **Tab**: nests under the previous item at the same indent, past its marker (2 for `- `, 3 for `1. `, 4 for `10. `), or one tab if the list already uses tabs. The item's nested lines move with it. The first item at its level can't move.
- **Shift-Tab**: out to the parent's indent, nested lines along. Top-level: no change.
- **Renumbering**: only the lists the edit touched. A list numbered `1.` on every item keeps that (only `1.`: any other repeated number is put right). A list whose first item changed place, or was not first before, starts at 1. A misnumbered list is put right from its first number.
- **Boundaries**: a blank line, a heading, fenced code, or a quote or thematic break not indented into an item ends what is renumbered or moved (the last two added in review). Nothing outside it changes. `- - -` and `* * *` are thematic breaks, not items.

## Decisions to check

- **Nested empty item outdents before it ends the list.** The task said "end it on Return on an empty item"; this adds one step for nested items. To make it end at once, drop the `parent(of:)` branch in `newLine`.
- **Hebrew items get an RLM** even when their text is Hebrew already, so an empty new item starts on the right. Ending the list removes it again.
- **Loose lists** (blank lines between items) are numbered in parts: a blank line is a boundary. GitHub renders the numbers from the first item, so this only shows in the source.
- A number that grows a digit (`9.` to `10.`) doesn't re-indent the item's children.
- A tab in an indent counts as 4 columns wherever it sits; CommonMark counts to the next tab stop. Only mixed space-and-tab indents differ.

## To wire in the app (not done here)

`textView(_:shouldChangeTextIn:replacementText:)` on iOS and its NSTextView twin: route `"\n"` through `newLine`, and Tab / Shift-Tab (`insertTab:` / `insertBacktab:` on the Mac, key commands on iPad) through the two shift calls, applying the edit with the existing `apply(_:in:)` so each is one undo step.
