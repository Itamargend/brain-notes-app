# Brain Notes app: status

Local branch `m3-app`. The operator has run the app on an iPhone 16 against `Itamargend/brain-notes-test`: sign-in, first sync, create and edit pushed as commits. Every automated test still runs against an in-process fake (`FakeGitHub`, plus an HTTP-level version of it in the tests), so no test has talked to the real GitHub. The onboarding screens below came after that run: they have not been on a phone or against real GitHub yet.

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

**Onboarding (`App/Sources/Onboarding/OnboardingFlow.swift`)**

- Welcome, Connect, device code, Ready. `AppModel.showsOnboarding` decides, from the phase and nothing else: `.needsSignIn`, or a Ready screen still open. A launch that finds tokens never gets here, whatever `bn.onboarded` says, and that includes a Keychain that can't be read right now and a token GitHub has stopped accepting.
- `DeviceCodeView` is shared with the plain sheet from Settings: big code that stays left to right in a Hebrew layout, Copy, Open, a quiet countdown from `expiresIn`, and Get a new code when the code runs out or is declined.
- Ready shows first-sync progress from the engine's snapshot. Open My Notes waits only while notes are moving: every state a first sync can stop in says what happened and lets the user through.
- Try with Sample Notes opens the demo session in under 2 s, with no transport and no Keychain. Connect GitHub in Settings cancels its listener, drops the session, deletes `BrainDemo/` and opens the live session, ending in `.needsSignIn`. The live `Brain/` folder is never touched.
- Sign out and wipe returns to Connect, also after a kill. A kill before Ready starts at Welcome again. Offline on Connect says so and points to the sample notes, with no retry loop.
- The accent is the slate blue asset, #4A6FA5 and #7A9CD3, checked in a test.

**Demo mode**: `-BNDemoFixtures` or `BN_DEMO=1`. Loads `Fixtures/demo-brain/` (48 notes), or `App/DemoFixtures/` (15) if that folder is missing from the bundle, onto the fake GitHub, then the real engine makes a conflict copy, a note deleted elsewhere and an unsynced note. `-BNScreen <folders|list|note|edit|search|compose|inbox|attention|conflict|signin|settings>`, `-BNHebrew`, and `-BNPhoneLayout` (the iPhone's navigation in a phone-sized Mac window). `-BNScreen <welcome|connect|code|ready>` opens an onboarding screen and implies demo mode with settings of its own, so `code` can't start a real device flow and `ready` can't mark the real app onboarded. `signin` now means Connect.

## Test numbers

Last full run, on this Mac, with the code as committed here:

- `bash scripts/verify.sh`: 14 tests, 110/110 merge vectors, 9,637 differential cases against the TypeScript reference. BrainMerge is untouched.
- `swift test` in `Packages/BrainNotesKit`: 239 tests in 42 suites.
- `xcodebuild -scheme BrainNotes -destination 'platform=macOS' build test`: no warnings, 312 tests pass, 0 skipped. That is those 239, then 73 in the app: `OnboardingTests` 26, `ScreenWalkTests` 47.
- Generic iOS build, and `build-for-testing` of `BrainNotesUITests` for Mac and iPhone: they compile. The XCUITests did not run.

Mutation checks of the onboarding rules. Each of these, applied alone in a throwaway worktree, made the test meant to notice it fail, and the same tests pass with no change: routing on `bn.onboarded` instead of the phase, onboarding while `.loading`, `.needsSignIn` for a moment on the way to the notes, a locked Keychain counted as signed out, a stale sample flag beating the token, a refused token sent to onboarding, the code's two halves following the layout direction, and a reload writing after its session has gone (5 of 5 runs). Three more were caught when applied together in an earlier pass: a cancelled listener still feeding the model, a cancelled sign-in run writing to the screen, and a wipe not setting `bn.onboarded`.

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
- **`bn.onboarded` has a second writer.** The task says it is set only on Ready. `signOutAndWipe` also sets it: someone who signed in before these screens existed never saw Ready, and without the flag they would land on Welcome instead of Connect, at once or after a kill.
- **There is a second flag, `bn.sampleMode`**, which the plan does not list. Without it, someone who chose the sample notes would be back at Connect on the next launch, and the plan wants the second launch to go straight to Folders. Tokens always win over it, and the launch that finds both removes it.
- **Sample notes start fresh at every launch.** The demo session rebuilds its folder, so text typed into a sample note lasts until the app quits. Settings says leaving removes it; nothing says quitting does.
- **Where the mockups and the plan disagree, the plan won**: sentence-case titles, Open My Notes instead of Start Writing, no tip card, no "See how your data is managed" link, Connect GitHub instead of Connect Your Brain with the plan's body text. SF Symbols only, so the sign-in button has no GitHub mark.

## Known gaps

- **Only the operator's runs have touched real GitHub**, and only before onboarding. The wire format is tested only against my reading of GitHub's API. The Ready screen's progress has seen a scripted transport and the demo engine, not a real first sync.
- **XCUITests have not run**, including the three new onboarding walks. They compile for Mac and iPhone, but this Mac refused them when last tried, before onboarding: "Timed out while enabling automation mode". I did not try again, since the attempt can put an authentication prompt on the screen. Enabling it is a system setting I did not change: `sudo automationmodetool enable-automationmode-without-authentication`, then run the `BrainNotesUITests` scheme. Until then, `ScreenWalkTests` shows every screen in a real window from inside the app, types through the real text view and presses onboarding's buttons through the accessibility tree, but it does not click. Tapping, swiping and navigating by touch are not covered.
- **No iOS run from here.** No simulator is installed; the iOS target compiles and that is all. `-BNPhoneLayout` shows the same navigation on a Mac, not iPhone rendering: grouped-list styling, keyboard handling, Liquid Glass toolbars, file protection and Keychain behaviour on a device are unseen by these tests. A Mac ignores Dynamic Type, so the largest text sizes on the onboarding screens are unseen too: a short window tests the same scroll-and-stay-put layout rule.
- **The onboarding pictures stay local**, in the git-ignored `.logs/shots/onboarding/`: `<phone|mac>-<screen>-<light|dark|hebrew>.png`, plus the states (`-offline-`, `-expired-`, `-declined-`, `-progress-`, `-problem-`, `-done-`). The plan says they go in the README, but this repo has no README.
- **`screencapture` is refused** in this environment ("could not create image from display"), so pictures come from the in-app tests (`.logs/shots/` after extracting from the xcresult). They draw the window into a bitmap, which does not reproduce sidebar vibrancy: the Mac sidebar's dots and text look washed out there. I expect that to be the capture, but have not seen the real window.
- **Budgets not measured on a device** (cold start, typing latency, memory, the 2 s for sample notes, which a test holds only on this Mac). `ScaleTests` runs the engine at the real brain's size on the Mac, in a debug build: first sync 4.2 s, search 2 ms, pull, merge and push of the 271 KB note 250 ms.
- **Not built** (in the plan but not in this task's list): Add to Brain intent, Face ID lock, wikilink navigation (`[[x]]` shows as plain text), rename in Inbox, local pins, format bar.
- **Editing is source with light styling**: headings get their look, marks stay visible. Rendered Markdown is in view mode.
- A conflict copy whose name is too long for the disk exists only on GitHub, so its comparison shows no "mine" side on this device.
- macOS keeps the token in the login keychain for ad-hoc builds, where `kSecAttrAccessible` is ignored. The iPhone build uses the data protection keychain as specified.
