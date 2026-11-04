# Wiki links and backlinks in the kit

Branch `cloud/links-kit`, from `editor-spike` (f6e792a). Kit only: no app screens, no sync or merge code touched.

## What is there

`Packages/BrainNotesKit/Sources/BrainNotesKit/Links/`, standard library only:

| File | What it does |
| --- | --- |
| `WikiLinks.swift` | `WikiLinks.parse(text) -> [WikiLink]` and `TextEdit`. |
| `LinkResolver.swift` | Which note a name means, and the shortest name that reaches a note. |
| `BacklinkIndex.swift` | Incremental index: `update`, `remove`, `move`/`applyMoves`, `backlinks(to:)`, `links(from:)`, `unresolved()`. |
| `RenamePlan.swift` | `renamePlan(moves:text:)`: the edits that keep every link's target when notes move. |

## Rules

**What a link is.** The same as the editor's styler (`MarkdownInline`, `FencedCode`): `[[`, no `[` or `]`, `]]`, on one
line; the first `|` starts the alias, the first `#` starts the heading. Not in fenced code (same fence rule), code spans,
escapes (`\[[x]]`), bare URLs, link destinations or images. `![[x]]` is an embed. `[[Note\|alias]]` in a table drops
the `\` from the name. Spaces, direction marks and `.md` around the name are not part of it.
`LinksEditorAgreementTests` (Apple only) holds the two parsers together.

**Positions** are UTF-8 bytes, the files' and Git's unit. The editor works in UTF-16; nothing here is for the editor.

**Resolving a name.** No case, no direction marks, any Unicode form (Swift string equality: Hebrew points in any order
match). `a/b` matches a path ending in `/a/b`. Ties: exact whole path, then the linking note's folder, then fewest
folders, then bytes. The index stores links as written and resolves when asked, so creating a note fixes links to it
and nothing has to be invalidated.

**Renames and moves.** One plan for any set of moves (rename, move, folder, swap). Every link that led to a note still
leads to it: links to a moved note, a moved note's own links that depended on its folder, and other notes' links that a
moved note would otherwise take over. The new name is the shortest that works, or the full path for links written with
a path. Only the name's bytes change. A link that still works is not touched, and neither is a link to a missing note.
Each edited note is parsed again before it goes into the plan; if the links don't come back as expected, that note is
listed in `skipped` instead. Also skipped: a file name with `#`, `|`, `[` or `]` (no link can name it), a note whose
text isn't available, and a move onto a path that is taken.

## How the app should use it (not built)

1. On launch, build `BacklinkIndex(notes:)` from the files (or keep it next to `SearchIndex` and `update` as notes save).
2. On every save, sync pull or delete: `update(path:text:)` / `remove(path:)`.
3. Rename or move: `renamePlan(moves:text:)`, write the moved file and every `plan.files` entry as one batch in the
   outbox (one commit), then `applyMoves` and `update` each edited note. Show `plan.skipped` to the user.
4. Backlinks panel: `backlinks(to:)`, each with `context` (its line).

## Linux

`swift test` in `Packages/BrainNotesKit` on Linux builds only `Links/` and `Tests/BrainNotesKitTests/Links/`.
`Package.swift` decides this with `#if canImport(CryptoKit) && canImport(Security) && canImport(Network) && canImport(Compression)`.
The rest of the kit needs those frameworks, and porting it would mean changing sync code. On Apple platforms the package
is as before, with the links code in the same `BrainNotesKit` module.

## What has not been run

There was no Swift toolchain in the session that wrote this (download.swift.org and the package mirrors were blocked),
so **none of this Swift has been compiled or run yet**. What was checked instead:

- A Python copy of the parser, resolver and planner passed every expected value in the Swift tests, and passed the
  "every link keeps its target" property on 20,000 random vaults (Hebrew names, folders, `.md`, embeds, code spans,
  swaps).
- A separate read of the Swift, looking only for compile errors.

The first thing to run:

    cd Packages/BrainNotesKit && swift test               # Linux: Links only
    cd Packages/BrainNotesKit && swift test --filter 'WikiLinks|LinkResolver|BacklinkIndex|RenamePlan|LinksEditorAgreement'  # macOS

> **Update on `cloud/integration`:** `Package.swift` now declares the whole kit (BrainNotesKit, BrainNotesTables, NoteSearch) on every host, and `swift test` was run there on Linux (Swift 6.1.3). Results and fixes: `.plan/cloud/integration.md`.
