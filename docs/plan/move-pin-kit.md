# Kit: move notes and folders, shared empty folders, local pins

Branch `cloud/move-pin-kit`, from `editor-spike` at f6e792a. Only `Packages/BrainNotesKit` changes. No App
wiring yet: the last section lists what the App needs.

## What a move is on GitHub

A move is one commit made with the same calls a push makes: `getCommit(head)`, `createTree(baseTree:writes:)`,
`createCommit`, then `updateRef(force: false)`. Each moved file is two tree writes:

- `TreeWrite(path: old, change: .delete)`
- `TreeWrite(path: new, change: .content(text))`

`TreeWrite` sends text, not a blob sha. The mover checks that `GitBlob.sha(text)` equals the old path's sha in
GitHub's tree before it sends anything. Git then stores the new path with the same blob, and GitHub's compare
reports a rename. A file whose bytes are not exact UTF-8 can't be sent this way, so the move is refused
(`MoveProblem.notText`). Nothing is ever written over.

The commit message follows the push format: `notes: move <old> -> <new>`, a blank line, then
`Brain-Notes-Device:` and `Brain-Notes-Op:` trailers. The date is fixed before the first call.

## Safety: the engine's own records

- **Before the ref update**, the mover writes the engine's `LandingPlan` to `pending_push`, the same record a push
  writes. Suppose the response is lost or the app is killed after that point. The engine's next run then
  verifies the ref and lands the move with its own `land` code. No sync code changed for this.
- **After a successful ref update**, the mover lands the move itself in one journal transaction. It moves the
  file, moves the row with the same blob sha, sets base and remote head, and clears `pending_push`. Then it
  updates the index.
- **If GitHub rejects the ref update with a 422**, the mover clears the record, changes nothing on the device and
  throws `remoteChanged`. Sync first, then try again.
- **After a timeout or a 5xx**, the mover reads the ref once. If the commit is there, the move lands. If not, the
  result is `.unconfirmed` and the engine finishes it.

## When a move is refused

These checks run before any write:

- **No first sync yet:** `notSyncedYet`.
- **A push still waiting to be confirmed:** `pushPending`.
- **GitHub has changes this device has not pulled** (head is not the journal's base): `behind`. Sync first.
- **A note with changes not on GitHub yet** (an outbox op, a dirty row, a note never pushed): `unsynced([paths])`.
  Moving an unsynced note would need a new outbox op kind, which is sync code. Sync first.
- **A folder holding files this app doesn't sync**, such as images, dot files, `private/` or a case twin of the
  folder: `leftBehind([paths])`. Moving only the notes would split the folder on GitHub.
- **A destination the path rules refuse**: `notAllowed`. That covers `private`, `_capture`, a hidden `_` folder,
  a dot segment, an empty segment, `..`, a folder name ending in `.md`, and a path too long for the disk.
- **Moving `_inbox` itself**: `notAllowed`.
- **Moving a folder into itself or one of its own subfolders**: `intoItself`. Case and NFC/NFD spellings
  count.
- **A move to where the note or folder already is**: `alreadyThere`.

## Names

- **The destination folder takes the spelling it already has.** `respell` gives case and NFC/NFD to match
  what's on GitHub.
- **A taken name gets a number:** `name.md` becomes `name 2.md`, then `name 3.md`. A folder `notes` becomes
  `notes 2`. A name counts as taken by clash key, as on an iPhone's disk. That counts GitHub's whole tree
  (not only notes), this device's unpushed notes and its empty folders.
- **Hebrew names work like any other.** Typed paths are made NFC.

## Empty folders

The kit already decided that `NoteStore.createFolder` makes a folder on this device only. The folder reaches
GitHub with its first note, and nothing is committed before then. A `.gitkeep` can never sync, because
`checkPath` refuses dot segments and non-`.md` files. That stays as it is.

For a folder that should exist on GitHub before it has a note, the mover adds a placeholder.

**Placeholder: `<folder>/_folder.md`.** It's the only kind of name that fits the kit's rules. It is `.md` with
no dot segment, so `checkPath` lets it through. The leading `_` marks it as the app's own file, like `_inbox`
and `_trash`. Its text says what it is. `FolderPlaceholder.isPlaceholder` recognises it, and
`FolderPlaceholder.listing` splits a list of paths into notes and folders kept by a placeholder.

`PathPolicy.isVisible` is **not** changed (existing behaviour stays). Until the App filters with
`FolderPlaceholder.listing`, the placeholder shows in lists as a note called `_folder`.

`NoteMover.createFolder(named:in:)` does all or nothing. It uses `NoteStore.createFolder`'s name rules, then
commits the placeholder. If GitHub can't be reached, the new empty folder is removed again and the error is
thrown. The App can then fall back to the local-only `NoteStore.createFolder`.
`keepFolderOnGitHub(_:)` commits a placeholder for a folder that already exists here.

Moving a folder that exists only on this device, with no notes on GitHub, is a local rename with no network
call. Empty subfolders inside a moved folder move with it on disk.

## Pins

Pins are per device and never synced. They are not part of the repo, and the engine never sees them.

- **The `PinsStore` protocol** has two requirements, `paths()` and `update(_:)`, which reads, changes and writes
  in one step. Everything else is in an extension: `pin`, `unpin`, `isPinned`, `notesMoved`, `noteDeleted`,
  `dropMissing`, `apply(_ event:exists:)` and `pinnedFirst`.
- **Two stores:**
  - `MemoryPinsStore`, for tests and previews.
  - `FilePinsStore`, JSON in `<store root>/pins.json`. That is outside `files/`, so it never syncs, and
    sign-out's wipe deletes it with the rest.
  - (A third, `UserDefaultsPinsStore`, was removed on `cloud/integration`: the kit's policy test allows
    `UserDefaults` only in the app model, and a defaults key survives sign-out's wipe.)

  All are behind `#if canImport(Foundation)`.
- **A pin follows its note.** A move made here calls `notesMoved`, and so does a whole folder's move. A rename
  from GitHub arrives as `SyncEvent.noteMoved` and is handled by `apply`.
- **A pin goes when its note goes.** `NoteStore.delete(path:pins:)` unpins. `apply` drops pins whose notes a
  sync removed, and `dropMissing` cleans up at launch.

  `apply` drops pins only when a run ends, meaning a snapshot that is not busy. The engine reports a rename's
  old path in `.notesChanged` before it sends `.noteMoved`. Dropping pins at `.notesChanged` would lose the pin
  of every note renamed on another device.
- **Pinned notes sort first** (`pinnedFirst`). The sort is stable, so the list's own order holds within each
  group.

## Not done here

- **App wiring.** `BrainSession` has to build a `NoteMover` (it needs the session's `GitHubClient`) and a
  `FilePinsStore(store:)`. The note list needs `pinnedFirst` and a pin action. The home screen needs
  `FolderPlaceholder.listing`. Engine events go to `pins.apply`.
- **Offline moves.** A move needs GitHub now. An outbox "move" op would need engine and BrainMerge changes.
- **Moving notes with unsynced edits.** These are refused, as described above.
- **Renaming a note or folder in place.** The planner could do it (same calls, new last segment), but it was not
  asked for.
