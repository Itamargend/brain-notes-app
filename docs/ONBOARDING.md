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
- **Browser mode**: the in-app browser (`ASWebAuthenticationSession`) is **not ephemeral** by default, so someone already signed in to GitHub in Safari does not sign in again, and saved passwords and passkeys work. See *2b. Signed in, straight to GitHub* for how the account is checked and for the private-window option.
- **Returning to the app** (`scenePhase == .active` while still waiting): GitHub is asked at once, but never sooner than its `interval` after the last request, so `slow_down` is not provoked. On iPhone the code is also copied again (a sign-in on Google or in Passwords will have replaced it). On a Mac the code is copied only when the person taps **Copy code & open GitHub** or **Copy code**, so a window that becomes active again does not overwrite what they copied meanwhile. Nothing is cancelled when the app goes to the background.
- **Browser lifecycle**: closing the browser sheet is *"not yet"* — polling carries on. When GitHub approves, or the code ends (expired, refused, denied), Brain Notes closes the browser by itself and takes the code off the Mac pasteboard.
- **Polling** (`DeviceFlow.poll` → `PollOutcome`, driven by one `DevicePoller` per code): one request per GitHub `interval` (≥ 5 s, raised by `slow_down`), and it ends only on a verdict, a token, or the code’s expiry (plus one last request just after the expiry, in case an approval beat the clock). **Every other failure** — any transport error (including ones that are not `URLError`, such as `NSPOSIXErrorDomain` 53 “connection abort” after iOS suspends the app), a 5xx, an answer that is not JSON — is transient and retried. Answers for an older code (after *Get a new code*, Cancel, or a closed screen) are ignored by generation number.
- **How the wait can end**, in plain words: *This code expired.* → **Get a new code** (`signin.newCode`); *You chose not to allow access.* → **Try again** (`signin.newCode`); *GitHub couldn’t finish connecting. Try again in a moment.* → **Get a new code**.

---

### 2b. Signed in, straight to GitHub (still `onboarding.code`) — no confirm screen
Right after approval Brain Notes asks GitHub who the new sign-in belongs to (`GET /user`, `BrainAccount.verifyCandidateToken`), with the pair in memory only, then hands it to `AppModel.signedIn(pair:verifiedUser:)` **at once** — there is no *Connected as* screen and no Continue.
- With notes already on the device, the same-account check runs before anything is saved: the account’s id must equal `selection.userId` before tokens are saved or sync starts; a different account shows the existing plain mismatch message with **Sign out and wipe** and **Use a different account** (`signin.refused.*`).
- On a first sign-in the token is saved and GitHub’s access page opens immediately (see 3). The code screen stays, and shows:
  - a quiet **Signed in as @login** line (`signin.signedInAs`) with a small **Use a different account** link (`signin.different`);
  - *Waiting for GitHub…* (`signin.waitingForGitHub`) and *Choose your notes on GitHub, then close its window.*;
  - **Open GitHub** (`signin.reopenGitHub`), which reopens the same access page, and the toolbar **Cancel** (`signin.cancel`). Neither is ever disabled while waiting — build 6 disabled every control here, which looked stuck when GitHub’s window sat behind the app with an unchanged grant.
- **Cancel** and **Use a different account** call `AppModel.cancelFirstTimeSignIn()`: GitHub’s page closes, polling stops, and the saved token comes out of the Keychain (a sign-in still being saved stops after its next wait). **Use a different account** then shows a **new code**; the next browser — and the access page and create-notes page that follow, for the rest of this onboarding run — opens in a **private window** (`ephemeral: true`), so Safari’s GitHub account is not offered again. (The dropped sign-in cannot be revoked by the app, which has no client secret; it is a short-lived token, and it can be removed at github.com/settings/applications.)
- If the account check cannot run (no connection), *We couldn’t check your GitHub account…* with **Try again** (`signin.retryCheck`) asks again with the same approval — no new code is needed.
- If the system browser does not start at all, that counts as the page being closed at once (`InAppWebSession.reportFailedStart`), so the wait always ends.

---

### 3. Granting access on GitHub & Choose your notes (`ChooseNotesView` — `onboarding.choose`)
Right after sign-in, Brain Notes queries `GET /user/installations` and immediately opens GitHub's `https://github.com/apps/<slug>/installations/new` (first install) or the existing installation's configure page (`https://github.com/settings/installations/<id>`, or `https://github.com/organizations/<org>/settings/installations/<id>` for an organization) in the same browser mode — without landing on an in-app Choose notes screen first and **never auto-picking before the user visits GitHub**. While GitHub is open, Brain Notes checks `GET /user/installations` and `GET /user/installations/{id}/repositories` (4 MiB reply cap, up to `defaultMaxPages = 5` pages of 100 repositories with an overall `defaultMaxRequests = 20` request budget and `seenRaw >= total_count` checked before the page cap) immediately, every three seconds (capped at `AppModel.maxInstallPolls`, cancelled and awaited before token eviction if the app enters background), when the browser closes, on optional `brainnotes://setup` callbacks (rechecking `GET /user` and ignoring any `installation_id` query item on its own), and when the app returns to the foreground:

- **Case A — Return from GitHub with a single private repository granted**:
  - After the user grants access on GitHub, if `GET /user` succeeds, the scan is not truncated, the installation does not grant **All repositories** (`repository_selection != "all"`), and the granted list contains exactly one repository and it is private, Brain Notes verifies and connects it automatically and goes **straight into the notes** — first-time and after **Settings → Change notes…** alike. The first sync runs in the background; the notes list shows *Getting your notes* and the sync status its progress. There is no ready screen. Cold launches with no stored selection never auto-pick without a user grant.
- **Case B — No notes shared with Brain Notes yet (browser closed before granting access)**: a **minimal** access step, never a blank screen.
  - Shows **Signed in as @login** (`onboarding.signedInAs`) and a single toolbar **Sign out** (`onboarding.signOut`).
  - **Headline**: *Choose your notes* (`onboarding.access.title`), no icon or boxed hints
  - **One line**: *On GitHub, choose ‘Only select repositories’ and pick your notes.* (`onboarding.installHint`)
  - **Primary button**: **Choose repositories on GitHub** (`onboarding.installApp`) — opens GitHub's install or configure page in the same browser mode as sign-in, checks immediately and every three seconds, and rechecks when the browser closes and when the app returns to the foreground.
  - **Secondary button**: **Create a new private brain** (`onboarding.createBrain`) — opens `https://github.com/new?name=brain&visibility=private&description=My%20Brain%20Notes` in the same browser mode. When that page closes, the list is checked again and the same access step shows a one-line hint (`onboarding.createHint`): *Made your new notes? Now choose them on GitHub.* (No extra account-wide repository-creation permissions are requested.)
- **Case C — Multiple repositories, "All repositories" grant, public repositories, or truncated installation (> 500 repos)**:
  - Shows **Signed in as @login** (`onboarding.signedInAs`), a single toolbar **Sign out** (`onboarding.signOut`), the repository list, and **Create a new private brain** (`onboarding.createBrain`).
  - Private repositories show `<owner>/<name>` with a **Private** badge (`onboarding.pick.<owner>/<name>`). Repository selection is single-flight (`isSelectingRepository`).
  - Public repositories are shown greyed out and disabled (`onboarding.public.<owner>/<name>`) with a **Public** badge and the plain explanation:
    > *"This notes repository is public, so anyone on the internet can read it. Brain Notes only opens private ones. Make it private on GitHub, then try again."*
  - If an installation lists too many repositories to scan completely, `ChooseNotesView` shows `DiscoveryResult.truncatedMessage` asking the user to choose **Only select repositories** on GitHub.
  - If zero private repositories are listed, the screen explains why and offers **Choose repositories on GitHub**, **Refresh**, and **Create a new private brain**.

---

### 4. Straight into the notes + Empty notes space
- There is **no** *You’re all set* screen and no **Open My Notes** (removed in build 7, first-time and Settings). Picking notes — or GitHub granting exactly one private repository — opens the notes list at once, with the first sync in the background (`ProgressView` *Getting your notes* over an empty list, and the usual sync status). Problems the first sync meets (account mismatch, access lost, truncated, public) show as the usual `RepoIssueView`, not on a separate screen. Try with Sample Notes opens the sample notes directly too (`-BNScreen sample`; `ready` is kept as an alias).
- **Empty repository support**: If the user just created a brand-new private repository with zero commits (`404` or `409` on ref/tree), first sync finishes cleanly with 0 notes, and `FoldersView` shows a welcoming **Write your first note** card (`home.firstNote`). Saving that first note bootstraps the repository's initial commit on its `default_branch` (`PUT /repositories/<repoId>/contents/<path>`, checked by `PathPolicy` and `SecretScan`; if one candidate gets `422`, Brain Notes parks it and tries the next unparked candidate), and subsequent edits sync via ordinary fast-forward Git commits.

---

### 5. Settings & recovery (`SettingsView`, `RepoIssueView`)
- **Settings**:
  - **Account** shows **Signed in as @login** (`settings.signedInAs`) only (with a single **Sign out and wipe** action at the bottom of Settings); **Notes** shows `<owner>/<name>` (`settings.repo`) and **Change notes…** (`settings.changeRepo`).
  - **Change notes…** (`settings.changeRepo`): checks `checkUnsyncedBeforeRepoSwitch()` (saving any active editor buffer first). If unsynced local edits exist, presents an explicit plain-language confirmation dialog (`settings.changeRepo.confirm`). Confirmed switches keep current notes open (`phase == .ready`) and open GitHub's installation configure page immediately without wiping local notes first: cancelling on GitHub leaves current local notes untouched, while granting a replacement private repository verifies `GET /user` and installation access first, wipes `<baseFolder>/Brain` (the old repository's local folder `Brain/<repoId>/`, orphan numeric folders, legacy folders, and `selected-repo.json`, without following symlinks) and clears in-memory note/undo state, and returns directly to the notes.
  - **Build-1 local data deleted on update**: Build-1 carry-over/migration has been dropped — **testers on build 1 must sync on build 1 before updating**. On live launch (never demo), `<baseFolder>/Brain` and every legacy non-numeric build-1 folder (`Brain/<non-numeric>`) are marked excluded from backup until removed and deleted without reading, opening, parsing, or migrating anything inside them (unlinking symlinks without traversing their targets).
  - **Sign out and wipe** (`settings.wipe`): deletes `<baseFolder>/Brain` and `<baseFolder>/BrainDemo` without following symlinks (verifying both paths are gone), clears `selected-repo.json`, cancels in-flight refreshes, removes Keychain tokens, and returns to Connect.
- **Account check, access revoked, branch renamed, truncated installation, or unverified owner (`RepoIssueView` — `repoIssue.view`)**:
  - Re-checked on every live launch (`launchRepairAndVerify`), on **Try again** (`retryCurrentRepository()`), and on `403`/`404` during sync, plus `verifyPrivateRepo()` at every sync and move start. Both launch and **Try again** require `GET /user` to succeed and match `selection.userId`: if `/user` fails, local notes stay hidden, sync does not start, and `RepoIssueView` offers a plain retry state (*"Can't check your GitHub account right now. Try again."* on network/server errors); if `/user` mismatches `selection.userId`, it shows the same `@login` refusal as re-sign-in. If the repository is unreachable/delisted (`.notListed`), switched to public (`.publicRepo`), or behind a truncated >500-repo installation (`.truncated`), syncing stops immediately and `RepoIssueView` offers a non-wiping **Try again** (`repoIssue.retry` — which refreshes `default_branch` in place via `updateVerifiedSelection` without opening a second store or wiping local notes) alongside **Choose your notes** / **Choose different notes** and **Sign out and wipe**. If a legacy selection lacks a verified `userId` while signed out (`.unverifiedOwner`), local notes remain hidden until the owner signs in and is verified via `GET /user`.
