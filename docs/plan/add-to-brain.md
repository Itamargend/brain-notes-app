# Add to Brain

Status: the kit side is built and tested on branch `cloud/add-to-brain-kit`. The App Intent is a draft
(`docs/plan/AddToBrainIntent.swift`) that is in no target yet: adding it needs Xcode and a device run.

## What it does

Text shared from another app, a link, or a quick thought typed into Shortcuts or Siri becomes a new note in
`_inbox/`. It is saved through the same write path as a note typed in the app (`NoteStore.save`), so it is in the
outbox as a create at once, shows in the Inbox at once, and the next push takes it, online or later.

## Kit API (`Packages/BrainNotesKit`)

| Piece | File | Role |
|---|---|---|
| `Capture` | `Capture.swift` | What the intent collects: `text`, `url`, `title`, `source`. |
| `Capture.Source` | `Capture.swift` | `share`, `shortcut`, `quick-note`. The raw values are written to the note and never change. |
| `CaptureNote.text(for:created:)` | `Capture.swift` | The note's full text. Pure: no disk, clock or network. Throws `CaptureProblem`. |
| `CaptureNote.fileStem(for:)` | `Capture.swift` | The file name without `.md`. |
| `NoteStore.capture(_:)` | `CaptureStore.swift` | Picks a free path in `_inbox` and saves it `createOnly`. Returns the path. |
| `BrainSession.capture(_:)` | `CaptureStore.swift` | Refuses the sample notes, runs `NoteStore.capture` off the caller's thread, then calls `engine.noteSaved()`. |
| `CaptureProblem` | `Capture.swift` | `empty`, `tooLarge`, `secret(kind)`, `sampleNotes`, `noFreeName`. |

## Intent parameters

`AddToBrainIntent`, title "Add to Brain". It runs in the app's own process (`openAppWhenRun = false`, in the app
target, not an extension): see "Process" below for why.

| Parameter | Type | Required | Default | Notes |
|---|---|---|---|---|
| `text` | `String?` | no | none | The body. Multi-line. Accepts the previous action's output in Shortcuts and the share sheet's text. Asked for when the intent runs with neither `text` nor `link`. |
| `link` | `URL?` | no | none | A web page or any URL with a scheme. A user name and password in it are dropped before it is written. |
| `title` | `String?` | no | none | A title the sender knows, such as a page title. Joined to one line. Without it, the first line of `text` names the note. |
| `source` | `CaptureSourceAppEnum` | no | `shortcut` | `share`, `shortcut`, `quick-note`. Hidden from the Shortcuts summary; a shortcut built for the share sheet sets `share`. |

At least one of `text`, `link` and `title` must have something other than white space.

**Result:** the new note's title, as a `String` value for the next action, and the dialog "Added to your Inbox".
The path is not returned: it can change if the note is edited before its first push (see "Names" below).

**Errors** (shown as the intent's dialog; nothing is written for any of them):

| Kit error | Dialog |
|---|---|
| `CaptureProblem.empty` | "Nothing to add. Share some text or a link." |
| `CaptureProblem.tooLarge` | "That's over 1 MB, too large for one note." |
| `CaptureProblem.secret` | "This looks like it holds a password or key, so it wasn't added." The kind is not shown or logged. |
| `CaptureProblem.sampleNotes` | "You're using the sample notes. Connect GitHub to add to your brain." |
| no session (`.needsSignIn`, `.misconfigured`, `.failed`) | "Open Brain Notes and sign in first." |
| `CaptureProblem.noFreeName`, disk errors | "Couldn't save. Try again." |

**App Shortcuts** (phrases must contain the app name): "Add to Brain in ${applicationName}", "Save to
${applicationName}", "Capture in ${applicationName}". Hebrew phrases go into the app's string catalog with the
Hebrew localisation; they are not in the draft.

## The note

```
---
type: capture
created: "2026-10-26T07:33:20Z"
source: "share"
url: "https://example.com/articles/42"
---
# How tide tables work

https://example.com/articles/42
```

- Frontmatter, in this order: `type: capture`, `created` (UTC, whole seconds, the same format as op times),
  `source`, and `url` only when there is a link. Values are YAML double-quoted strings, written by BrainMerge's
  `yamlStr`, as conflict copies' headers are. `NoteText.frontmatterValue` reads them back without the quotes.
- Body: a `# ` heading when a title was given (unless the text already starts with it) or when only a link was
  shared (the heading is the link's host); then the text; then the link, unless the text already contains it.
  Parts are separated by a blank line.
- Line endings become `\n`. Blank lines before the text and white space after it go. The note ends with one `\n`.
- Refused before anything is written: nothing to add; over 1 MiB with the frontmatter (merge spec 6.4); a
  secret-shaped string, by the same `SecretScan` that blocks commits. A saved note with a secret would sit in Needs
  attention and never sync, so saying no straight away is better for something sent from another app: the text
  is still where it came from.

## Names

The file is `_inbox/<stem>.md`, where `<stem>` is what the app already calls a new note
(`PathPolicy.fileName(fromFirstLine:)` on the first body line), plus two rules for captures:

- **Kept as typed:** Hebrew and any other script, spaces, emoji. NFC.
- **Removed:** control characters, and invisible ones (bidi marks such as U+200F, zero-width spaces and joiners),
  which a Hebrew share often carries and which would make two names look the same. Markdown marks of the first
  line. Leading and trailing dots and spaces.
- **Replaced with `-`:** `/ \ : * ? " < > |`, which no disk or no Windows checkout takes.
- **Length:** 60 characters (the app's rule), and also at most 180 UTF-8 bytes (`CaptureNote.maxStemBytes`), cut
  at a character boundary so a flag or an accented letter is never split. 60 Hebrew letters are 120 bytes and
  pass; 60 flags are 480 bytes and would not fit in one file name on any disk.
- **Windows device names** (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, also as `nul.txt`) get
  `-note`. A clone of the repo on Windows cannot create these files.
- Nothing left: `Untitled`.

**Collisions:** the folder takes the spelling GitHub already has (`_Inbox/` if that is what the tree holds). A
name taken in any spelling (by clash key, so `Idea.md`, `IDEA.md` and NFD twins all count), by a note in the
journal or by a file on the disk that the journal does not know, gets `-2`, `-3`, and so on. A name that would
still break a path rule or not fit on the disk falls back to `Capture.md`.

**Race:** the free name comes from a read, and the save is a later write. Two captures at once could pick the same
name, and a plain save of the second would treat it as an edit of the first and replace its unsynced text. So the
capture saves with `createOnly`: the check and the write are one transaction, and a taken name is picked again
(at most 8 times, then `noFreeName`).

**Renamed before its first push:** a note that has never been pushed follows its first line when edited (that is
the existing save rule). A capture edited in the app before it syncs can get a new name then, and that rename
does not apply the two extra capture rules. The result therefore returns the title, not the path.

## Sync

Nothing special. The capture is a `create` op in the outbox. `BrainSession.capture` calls `engine.noteSaved()`,
so the push follows the usual idle wait, or happens at once when the app goes to the background. Offline, it waits
and lands later. A clash on push follows the merge spec like any new note.

## Process

The intent runs in the app's process: the system launches the app in the background if needed. It does not go in
an App Intents or Share extension, because:

- The journal (`journal.sqlite`), the note files and the Keychain item live in the app's container. An extension
  would need an App Group container and a shared Keychain access group, which moves where every note lives and
  needs a migration.
- Two processes writing the same journal would need cross-process locking (GRDB `DatabasePool` with WAL, plus a
  way to tell the running engine). The engine assumes it is the only writer.

The cost: a share from another app goes through Shortcuts ("Show in Share Sheet", passing Shortcut Input to this
intent) rather than an "Add to Brain" row of its own in the share sheet. A real share extension is a later step,
with the App Group move as its own task.

## App wiring (needs Xcode, not done)

1. Add `AddToBrainIntent.swift` from the draft to the `BrainNotes` target (iOS and macOS).
2. Register the model at launch: `AppDependencyManager.shared.add { model }` in `BrainNotesApp.init`.
3. Add `AppModel.capture(_:)`: wait for the launch to settle past `.loading`, use the live session, call
   `session.capture`, then `reloadLists()`. Sketch in the draft.
4. Hebrew strings for the dialogs and phrases.
5. Device checks: a share from Safari through a shortcut, the app killed and not running, the device locked
   (file protection is complete-until-first-unlock, so a capture before the first unlock after a restart must fail
   with "Couldn't save", not lose text), offline, signed out, sample notes.

## Not covered by the kit tests

- The intent itself, Shortcuts, Siri, and the share sheet. They need an Xcode build and a device.
- A real cross-process race: the tests cover the `createOnly` check and the re-pick, not two processes.
- The kit's tests have not run on Linux. The package imports `CryptoKit`, `os`, `Security` and `Network` in
  existing files, which have no Linux builds, so `swift test` in `Packages/BrainNotesKit` builds only on Apple
  platforms. The new files use only Foundation, BrainMerge and GRDB.

> **Update on `cloud/integration`:** `Package.swift` now declares the whole kit (BrainNotesKit, BrainNotesTables, NoteSearch) on every host, and `swift test` was run there on Linux (Swift 6.1.3). Results and fixes: `.plan/cloud/integration.md`.
