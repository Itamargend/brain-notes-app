# Brain Notes app: status

Local branch `m3-app`. Nothing has talked to the real GitHub yet: everything below ran against an in-process fake (`FakeGitHub`, plus an HTTP-level version of it in the tests). The first real run is the operator's, on the iPhone, against `Itamargend/brain-notes-test`.

## What works

**Sync engine (`Packages/BrainNotesKit`)**

- First sync: tarball into a staging folder, every file checked against the recursive tree's blob shas, swapped in only then. Anything the tarball didn't deliver comes from the blobs API.
- Pull: ETag poll, compare, tree diff over 300 files, renames, deletes. Clean notes change on disk; dirty notes keep their text and merge at push.
- Push: one commit per batch from BrainMerge `planCommit`, tree on the head's tree, fixed op time as commit date, message ending in `Brain-Notes-Op: <uuid>`, `force: false` always.
- Races: 422 pulls, merges and retries up to 3 times with 1 to 4 s jitter, then Needs attention. Clean sections merge; a true clash keeps GitHub's text and writes my whole note to an `_inbox` conflict copy in the same commit.
- Lost responses: the commit and what it means for the device are written to the journal before the ref update. After a timeout, a 5xx or a kill, Verifying reads the ref and either finishes the landing, retries the same sha, or rebuilds. No duplicate commits.
- Typing during a push is kept: that note stays dirty, based on what was pushed, so GitHub's side of a merge survives the next push.
- Errors: 401 refreshes once, then Signed out with all data kept. 403/429 pause until the stated time. 404 is Access lost. 5xx and timeouts back off 2, 4, 8 s up to 5 min. A rejected op goes to Needs attention and the others still land. Offline makes no calls and catches up.
- Rewritten main stops sync and says so; a fresh sync keeps unsynced text as copies.
- Launch repair: a file that differs from the journal is a local edit, never overwritten; a missing file is downloaded, never treated as a delete; unsynced text comes back from the outbox after a device restore.
- Safety in code: the repo guard (`RepoTarget`) on every request, path policy, secret check on new text, tokens only in the Keychain, no secret anywhere, redirects only to GitHub's tarball host, no URL cache on disk, `privacy: .private` for paths and text.

**App (`App/`)**, one multiplatform target, iOS 26 and macOS 26

Folders home, note list with status dots and relative dates, rendered note view, editor with Hebrew RTL per paragraph and autosave, search (Hebrew and English, including Hebrew prefix letters and points), compose named from the first line, Inbox with conflict copies marked, Needs attention with both versions side by side and Keep both / Use this one / Restore, device-flow sign-in with big code, Settings, privacy cover in the app switcher, no Spotlight.

**Demo mode**: `-BNDemoFixtures` or `BN_DEMO=1`. Loads `Fixtures/demo-brain/` (48 notes), or `App/DemoFixtures/` (15) if that folder is missing from the bundle, onto the fake GitHub, then the real engine makes a conflict copy, a note deleted elsewhere and an unsynced note. `-BNScreen <folders|list|note|edit|search|compose|inbox|attention|conflict|signin|settings>`, `-BNHebrew`, and `-BNPhoneLayout` (the iPhone's navigation in a phone-sized Mac window).

## Test numbers

See the summary at the end of this file for the last full run.

## Decisions worth checking

- **The plan's "landed" check is reversed, so I did not follow it.** A-app.md says `compare ours...head` status `behind`/`identical` means our commit landed. `behind` means head is *before* our commit, so it has not landed. Spike S1 measured `ahead` on a landed commit, and GitHub's docs agree. The code uses `ahead`/`identical`, with a test named `behindDoesNotCountAsLanded`.
- **The outbox holds the note's text, not just a hash.** That lets a push finish while note files are locked, and lets unsynced edits survive a device backup, which excludes the files. Journal protection is complete-until-first-unlock as the plan says, so unsynced text is readable after first unlock, like the base snapshots already are.
- **Saves carry the text they started from** (`editingFrom`), so an editor holding older text merges with a sync instead of overwriting it.
- **Backgrounding skips the one-commit-a-minute cap.** It may be the last chance for hours. Leaving a note respects the cap.
- **Notes this device can't hold stay on GitHub only**, listed in Needs attention: a case or NFC/NFD twin (`People/a.md` next to `people/b.md`), which gets its file once the name is free, and a name too long for the disk. The planner still sees them, so commits leave them alone.
- **Any 422 on the ref is a race**, as the plan says, whatever its message. Other 422s (a bad tree) park that op.
- **Deleting a note with unpushed typing** also writes that text to `_trash/<note>-unsynced-<time>.md`, since the plan says a delete never loses text. A note that never reached GitHub is simply gone.
- **A secret already on GitHub does not block.** Only a newly added one does; otherwise such a note could never be edited again.
- **Commit identity** is `Brain Notes <brain-notes-app@noreply.invalid>`, fixed so that a retry has the same sha.
- **Debug Mac builds have no App Sandbox**: a sandboxed ad-hoc build cannot host the in-app tests. Release has it, and was launched once in demo mode inside its container.

## Known gaps

- **Not run against real GitHub.** The wire format is tested only against my reading of GitHub's API. Expect the first real run to find something.
- **XCUITests have not run.** They compile for Mac and iPhone, but this Mac refuses them: "Timed out while enabling automation mode". Enabling it is a system setting I did not change: `sudo automationmodetool enable-automationmode-without-authentication`, then run the `BrainNotesUITests` scheme. Until then, `ScreenWalkTests` shows every screen in a real window from inside the app and types through the real text view, but it does not click. Tapping, swiping and navigating by touch are not covered.
- **Never run on iOS.** No simulator is installed; the iOS target compiles and that is all. `-BNPhoneLayout` shows the same navigation on a Mac, not iPhone rendering: grouped-list styling, keyboard handling, Liquid Glass toolbars, file protection and Keychain behaviour on a device are unseen.
- **`screencapture` is refused** in this environment ("could not create image from display"), so pictures come from the in-app tests (`.logs/shots/` after extracting from the xcresult). They draw the window into a bitmap, which does not reproduce sidebar vibrancy: the Mac sidebar's dots and text look washed out there. I expect that to be the capture, but have not seen the real window.
- **Budgets not measured on a device** (cold start, typing latency, memory). `ScaleTests` runs the engine at the real brain's size on the Mac, in a debug build: first sync 4.2 s, search 2 ms, pull, merge and push of the 271 KB note 250 ms.
- **Not built** (in the plan but not in this task's list): Add to Brain intent, Face ID lock, wikilink navigation (`[[x]]` shows as plain text), rename in Inbox, local pins, format bar.
- **Editing is source with light styling**: headings get their look, marks stay visible. Rendered Markdown is in view mode.
- A conflict copy whose name is too long for the disk exists only on GitHub, so its comparison shows no "mine" side on this device.
- macOS keeps the token in the login keychain for ad-hoc builds, where `kSecAttrAccessible` is ignored. The iPhone build uses the data protection keychain as specified.
