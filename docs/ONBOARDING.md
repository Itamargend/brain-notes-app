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

### 2. Enter code on GitHub (`DeviceCodeView` — `onboarding.code`)
- **What happens automatically on tap**:
  1. Brain Notes requests a one-time device code using only the public `BN_GITHUB_CLIENT_ID`.
  2. Copies the 8-character code to the pasteboard automatically (`localOnly` + `expirationDate` on iOS; change-count-tracked auto-clear on macOS).
  3. Opens `https://github.com/login/device` in an ephemeral in-app `ASWebAuthenticationSession` (`InAppWebSession.system()`, `prefersEphemeralWebBrowserSession = true`).
- **On-screen copy**:
  - **Headline**: *Enter this code on GitHub*
  - Large monospaced code (`signin.code`) + one-tap **Copy code** button (`signin.copy`).
  - Three short steps explaining that the code is already copied, to paste and tap **Authorize**, and that Brain Notes continues automatically.
  - Re-open button: **Open GitHub to enter code** (`signin.open`) if the user closed the sheet early.
- **Browser lifecycle**:
  - Closing the browser sheet early is treated as *"not yet"* — background polling continues at GitHub's `interval` (clamped to `>= 5s` and honoring `slow_down` backoff) until approval or expiry.
  - The moment polling succeeds, Brain Notes closes the in-app browser automatically, clears the code from the Mac pasteboard, verifies or saves the expiring token pair in Keychain, and moves to **Choose your notes**.

---

### 3. Choose your notes (`ChooseNotesView` — `onboarding.choose`)
Immediately after sign-in, Brain Notes queries `GET /user` first to confirm and display **Signed in as @login** (`onboarding.signedInAs`) alongside **Not you? Sign out** (`onboarding.notYouSignOut`) before opening or auto-selecting any repository, then queries `GET /user/installations` and `GET /user/installations/{id}/repositories` (4 MiB reply cap, up to `defaultMaxPages = 5` pages of 100 repositories with an overall `defaultMaxRequests = 20` request budget and `seenRaw >= total_count` checked before the page cap):

- **Case A — Exactly one private notes space is already approved (and scan is not truncated)**:
  - Once `@login` has been fetched and displayed on the screen, if auto-selection is enabled (initial onboarding only; disabled after **Change notes repository**), the single private repository is selected automatically and transitions to **You’re all set** (`ReadyView`), which continues showing **Signed in as @login** + **Not you? Sign out**.
- **Case B — No notes chosen on GitHub yet (`repositories.isEmpty`)**:
  - **Headline**: *Choose your notes*
  - **Hint**: *"Pick 'Only select repositories' and choose just your notes."* (`onboarding.installHint`)
  - **Primary button**: **Choose notes on GitHub** (`onboarding.installApp`) — opens `https://github.com/apps/<slug>/installations/new` in an ephemeral in-app browser and polls `/user/installations` every few seconds (capped at `AppModel.maxInstallPolls`, cancelled and awaited before token eviction if the app enters background). If opened from `.failed` or `.loading`, Brain Notes fetches baseline repository IDs before polling (and disables auto-pick if no baseline could be fetched). As soon as newly added repositories appear, the browser closes automatically — and auto-selects **only** during initial onboarding (`repoSelectionAutoSelect == true`) when a known baseline existed and the newly appeared repositories consist of a single private repository and zero public ones (otherwise showing the picker). Optional `brainnotes://setup` callback URLs and **Try again** / **Refresh** (`retryDiscovery()`) preserve `repoSelectionAutoSelect` so manual repo switches never auto-pick.
  - **Secondary button**: **Create my brain** (`onboarding.createBrain`) — opens `https://github.com/new?name=brain&visibility=private&description=My%20Brain%20Notes` in an ephemeral in-app browser with plain guidance: *"Create it as Private, then come back and tap Choose notes on GitHub below."* (No extra account-wide repository-creation permissions are requested.)
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
