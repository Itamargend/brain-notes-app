# Onboarding & Repository Switching

Brain Notes lets any person connect **their own private notes on GitHub** in about three taps, without jargon (`repo`, `token`, `OAuth`, `installation`) on onboarding screens and without any Brain Notes server.

---

## Screen-by-screen flow

### 1. Welcome / Connect (`StartView` — `onboarding.welcome` / `onboarding.connect`)
- **Headline**: *Welcome to Brain Notes*
- **Highlights**:
  - *Plain Markdown, synced with your notes on GitHub*
  - *Works offline, syncs when you’re back*
  - *Hebrew and English, side by side*
- **Privacy reassurance**:
  - *Notes travel straight from this device to GitHub. There is no Brain Notes server.*
  - *Brain Notes connects with a one-time code. No password is stored on this device.*
  - *Your sign-in stays in this device’s Keychain and only reaches the private notes you choose.*
- **Actions**:
  - **Connect GitHub** (`signin.start`) — begins the GitHub Device Flow.
  - **Try with Sample Notes** (`onboarding.sample`) — opens the bundled bilingual sample brain against an in-process fake GitHub with zero network or Keychain calls.
  - When offline, a quiet banner (`onboarding.offline`) suggests trying Sample Notes first.

---

### 2. Your code for GitHub (`DeviceCodeView` — `onboarding.code`)
The code comes first. **Nothing opens over it**: the person sees the code, then taps one button.
- **On tap of Connect GitHub**: Brain Notes requests a one-time device code using only the public `BN_GITHUB_CLIENT_ID` and shows it, large (`signin.code`). It starts polling GitHub for that one code (see *Polling* below). The browser is **not** opened yet.
- **On-screen copy**:
  - **Headline**: *Your code for GitHub*
  - The code, large and monospaced, left-to-right in every language (`signin.code`), with a small **Copy code** control (`signin.copy`) that stays on screen the whole time.
  - Three short steps: *Tap the button below. We copy the code and open GitHub.* / *Paste the code if it isn’t there already, then tap Authorize.* / *Come back here. Brain Notes carries on by itself.* (The copy never promises the code is filled in: GitHub may ignore the `?user_code=` we send.)
  - One primary button: **Copy code & open GitHub** (`signin.open`). **Every press** copies the code again (`localOnly` + `expirationDate` on iOS; change-count-tracked auto-clear on macOS — `DeviceCodeClipboard`) and opens GitHub.
  - Status line (`signin.waiting`): *Waiting for you to approve on GitHub* with the time the code has left. After two failed requests in a row it adds *Can’t reach GitHub right now. Brain Notes keeps trying.* (`signin.offline`); polling never stops for that.
- **The page that opens**: `verification_uri` (still required to be `https://github.com/…` with no credentials or port) with `?user_code=<code>` appended, built with `URLComponents`. One switch, `AppConfig.prefillDeviceCodeInURL` (default `true`), turns the parameter off. If GitHub ignores it the page is the plain code page.
- **Browser mode**: the in-app browser (`ASWebAuthenticationSession`) is **not ephemeral** by default, so someone already signed in to GitHub in Safari does not sign in again, and saved passwords and passkeys work. See *Connected as @login* for why that is safe and for the private-window option.
- **Returning to the app** (`scenePhase == .active` while still waiting): the code is copied again (a sign-in on Google or in Passwords will have replaced it) and GitHub is asked at once, but never sooner than its `interval` after the last request, so `slow_down` is not provoked. Nothing is cancelled when the app goes to the background.
- **Browser lifecycle**: closing the browser sheet is *"not yet"* — polling carries on. When GitHub approves, or the code ends (expired, refused, denied), Brain Notes closes the browser by itself and takes the code off the Mac pasteboard.
- **Polling** (`DeviceFlow.poll` → `PollOutcome`, driven by one `DevicePoller` per code): one request per GitHub `interval` (≥ 5 s, raised by `slow_down`), and it ends only on a verdict, a token, or the code’s expiry (plus one last request just after the expiry, in case an approval beat the clock). **Every other failure** — any transport error (including ones that are not `URLError`, such as `NSPOSIXErrorDomain` 53 “connection abort” after iOS suspends the app), a 5xx, an answer that is not JSON — is transient and retried. Answers for an older code (after *Get a new code*, Cancel, or a closed screen) are ignored by generation number.
- **How the wait can end**, in plain words: *This code expired.* → **Get a new code** (`signin.newCode`); *You chose not to allow access.* → **Try again** (`signin.newCode`); *GitHub couldn’t finish connecting. Try again in a moment.* → **Get a new code**.

---

### 2b. Connected as @login (`onboarding.confirm`) — required, before anything is saved
Right after approval Brain Notes asks GitHub who the new sign-in belongs to (`GET /user`, `BrainAccount.verifyCandidateToken`). The new token pair is held **in memory only**; nothing is in the Keychain and no repository has been listed.
- **Screen**: *Connected as @login* (`signin.confirm.login`), text only, with **Continue** (`signin.confirm.continue`) and **Use a different account** (`signin.confirm.different`).
- **Continue** hands the verified pair to `AppModel.signedIn(pair:verifiedUser:)`. With notes already on the device, the same-account check still runs first: the confirmed account’s id must equal `selection.userId` before tokens are saved or sync starts; a different account shows the existing plain mismatch message with **Sign out and wipe** (and **Use a different account**).
- **Use a different account** drops the unsaved pair and shows a **new code**. The next browser — and the access page and create-notes page that follow, for the rest of this onboarding run — opens in a **private window** (`ephemeral: true`), so Safari’s GitHub account is not offered again. (The dropped sign-in cannot be revoked by the app, which has no client secret; it is a short-lived token that was never stored, and it can be removed at github.com/settings/applications.)
- If the account check cannot run (no connection), *We couldn’t check your GitHub account…* with **Try again** (`signin.retryCheck`) asks again with the same approval — no new code is needed.

---

### 3. Choose your notes (`ChooseNotesView` — `onboarding.choose`)
After **Continue**, Brain Notes queries `GET /user` and displays **Signed in as @login** (`onboarding.signedInAs`) alongside **Not you? Sign out** (`onboarding.notYouSignOut`) before opening or auto-selecting any repository, then queries `GET /user/installations` and `GET /user/installations/{id}/repositories` (4 MiB reply cap, up to `defaultMaxPages = 5` pages of 100 repositories with an overall `defaultMaxRequests = 20` request budget and `seenRaw >= total_count` checked before the page cap):

- **Case A — Exactly one private notes space is already approved (and scan is not truncated)**:
  - Once `@login` has been fetched and displayed on the screen, if auto-selection is enabled (initial onboarding only; disabled after **Change notes repository**), the single private repository is selected automatically and transitions to **You’re all set** (`ReadyView`), which continues showing **Signed in as @login** + **Not you? Sign out**.
- **Case B — No notes shared with Brain Notes yet (no installation, or no repositories)**: the **access step**, never a blank screen.
  - **Headline**: *Give Brain Notes access to your notes* (`onboarding.access.title`)
  - **One line**: *On GitHub, choose ‘Only select repositories’ and pick your notes.* (`onboarding.installHint`)
  - **Primary button**: **Open GitHub to choose notes** (`onboarding.installApp`) — opens `https://github.com/apps/<slug>/installations/new` in the same browser mode as sign-in and polls `/user/installations` every few seconds (capped at `AppModel.maxInstallPolls`, cancelled and awaited before token eviction if the app enters background). The list is **checked again when the browser closes and when the app returns to the foreground** (backgrounding cancels the polling, so the foreground check replaces it), closing the GitHub page if notes appeared in the meantime. If opened from `.failed` or `.loading`, Brain Notes fetches baseline repository IDs before polling (and disables auto-pick if no baseline could be fetched). As soon as newly added repositories appear, the browser closes automatically — and auto-selects **only** during initial onboarding (`repoSelectionAutoSelect == true`) when a known baseline existed and the newly appeared repositories consist of a single private repository and zero public ones (otherwise showing the picker). Optional `brainnotes://setup` callback URLs and **Try again** / **Refresh** (`retryDiscovery()`) preserve `repoSelectionAutoSelect` so manual repo switches never auto-pick.
  - **Secondary button**: **Create a new private brain** (`onboarding.createBrain`) — opens `https://github.com/new?name=brain&visibility=private&description=My%20Brain%20Notes` in the same browser mode. When that page closes, the list is checked again and the same access step shows a one-line hint (`onboarding.createHint`): *Made your new notes? Now tap the button below and pick them.* (No extra account-wide repository-creation permissions are requested.)
- **Case C — Multiple repositories, public repositories, or truncated installation (> 500 repos)**:
  - Private repositories show `<owner>/<name>` with a **Private** badge (`onboarding.pick.<owner>/<name>`). Repository selection is single-flight (`isSelectingRepository`).
  - Public repositories are shown greyed out and disabled (`onboarding.public.<owner>/<name>`) with a **Public** badge and the plain explanation:
    > *"This notes repository is public, so anyone on the internet can read it. Brain Notes only opens private ones. Make it private on GitHub, then try again."*
  - If an installation lists too many repositories to scan completely, `ChooseNotesView` shows `DiscoveryResult.truncatedMessage` asking the user to choose **Only select repositories** on GitHub.
  - If zero private repositories are listed, the screen explains why and offers **Choose notes on GitHub**, **Refresh**, and **Create my brain**.

---

### 4. You’re all set (`ReadyView` — `onboarding.ready`) + Empty notes space
- Displays **Signed in as @login** (`onboarding.signedInAs`) and **Not you? Sign out** (`onboarding.notYouSignOut`) on live sessions (including after single-repo auto-pick), shows *"Getting your notes"* (`onboarding.checking`, `.checking`) while installation and repository-privacy checks run and download/indexing progress (`onboarding.progress`, `.firstSync`) once both checks pass, and enables **Open My Notes** (`onboarding.open`) as soon as sync completes (or immediately with a non-blocking status message if offline).
- **Empty repository support**: If the user just created a brand-new private repository with zero commits (`404` or `409` on ref/tree), first sync finishes cleanly with 0 notes, and `FoldersView` shows a welcoming **Write your first note** card (`home.firstNote`). Saving that first note bootstraps the repository's initial commit on its `default_branch` (`PUT /repositories/<repoId>/contents/<path>`, checked by `PathPolicy` and `SecretScan`; if one candidate gets `422`, Brain Notes parks it and tries the next unparked candidate), and subsequent edits sync via ordinary fast-forward Git commits.

---

### 5. Settings & recovery (`SettingsView`, `RepoIssueView`)
- **Settings → Notes on GitHub**:
  - Shows **Signed in as @login** (`settings.signedInAs`) with **Not you? Sign out** (`settings.notYouSignOut`), and **Connected notes** as `<owner>/<name>` (`settings.repo`).
  - **Change notes repository** (`settings.changeRepo`): checks `checkUnsyncedBeforeRepoSwitch()` (saving any active editor buffer first). If unsynced local edits exist, presents an explicit plain-language confirmation dialog (`settings.changeRepo.confirm`). Confirmed switches wipe `<baseFolder>/Brain` (the old repository's local folder `Brain/<repoId>/`, orphan numeric folders, legacy folders, and `selected-repo.json`, without following symlinks) and clear in-memory note/undo state **before** opening `ChooseNotesView` in manual picker mode (`repoSelectionAutoSelect == false`), while keeping the user signed in.
  - **Build-1 local data deleted on update**: Build-1 carry-over/migration has been dropped — **testers on build 1 must sync on build 1 before updating**. On live launch (never demo), `<baseFolder>/Brain` and every legacy non-numeric build-1 folder (`Brain/<non-numeric>`) are marked excluded from backup until removed and deleted without reading, opening, parsing, or migrating anything inside them (unlinking symlinks without traversing their targets).
  - **Sign out and wipe** (`settings.wipe`): deletes `<baseFolder>/Brain` and `<baseFolder>/BrainDemo` without following symlinks (verifying both paths are gone), clears `selected-repo.json`, cancels in-flight refreshes, removes Keychain tokens, and returns to Connect.
- **Account check, access revoked, branch renamed, truncated installation, or unverified owner (`RepoIssueView` — `repoIssue.view`)**:
  - Re-checked on every live launch (`launchRepairAndVerify`), on **Try again** (`retryCurrentRepository()`), and on `403`/`404` during sync, plus `verifyPrivateRepo()` at every sync and move start. Both launch and **Try again** require `GET /user` to succeed and match `selection.userId`: if `/user` fails, local notes stay hidden, sync does not start, and `RepoIssueView` offers a plain retry state (*"Can't check your GitHub account right now. Try again."* on network/server errors); if `/user` mismatches `selection.userId`, it shows the same `@login` refusal as re-sign-in. If the repository is unreachable/delisted (`.notListed`), switched to public (`.publicRepo`), or behind a truncated >500-repo installation (`.truncated`), syncing stops immediately and `RepoIssueView` offers a non-wiping **Try again** (`repoIssue.retry` — which refreshes `default_branch` in place via `updateVerifiedSelection` without opening a second store or wiping local notes) alongside **Choose your notes** / **Choose different notes** and **Sign out and wipe**. If a legacy selection lacks a verified `userId` while signed out (`.unverifiedOwner`), local notes remain hidden until the owner signs in and is verified via `GET /user`.
