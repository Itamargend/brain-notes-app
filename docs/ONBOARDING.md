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
  3. Opens `https://github.com/login/device` in an in-app `ASWebAuthenticationSession` (`InAppWebSession`).
- **On-screen copy**:
  - **Headline**: *Enter this code on GitHub*
  - Large monospaced code (`signin.code`) + one-tap **Copy code** button (`signin.copy`).
  - Three short steps explaining that the code is already copied, to paste and tap **Authorize**, and that Brain Notes continues automatically.
  - Re-open button: **Open GitHub to enter code** (`signin.open`) if the user closed the sheet early.
- **Browser lifecycle**:
  - Closing the browser sheet early is treated as *"not yet"* — background polling continues at GitHub's `interval` (honoring `slow_down`) until approval or expiry.
  - The moment polling succeeds, Brain Notes closes the in-app browser automatically, clears the code from the Mac pasteboard, saves the expiring token pair in Keychain, and checks `/user/installations`.

---

### 3. Choose your notes (`ChooseNotesView` — `onboarding.choose`)
Immediately after sign-in, Brain Notes queries `GET /user/installations` and `GET /user/installations/{id}/repositories`:

- **Case A — Exactly one private notes space is already approved**:
  - Selected automatically with zero extra taps; transitions straight to **You’re all set** (`ReadyView`) and begins the first sync.
- **Case B — No notes chosen on GitHub yet (`repositories.isEmpty`)**:
  - **Headline**: *Choose your notes*
  - **Hint**: *"Pick 'Only select repositories' and choose just your notes."* (`onboarding.installHint`)
  - **Primary button**: **Choose notes on GitHub** (`onboarding.installApp`) — opens `https://github.com/apps/<slug>/installations/new` in the in-app browser and polls `/user/installations` every few seconds (capped at `AppModel.maxInstallPolls`). As soon as a repository appears, the browser closes automatically (and if a single private one was chosen, Brain Notes starts syncing immediately). Optional `brainnotes://setup` callback URLs also trigger an immediate refresh.
  - **Secondary button**: **Create my brain** (`onboarding.createBrain`) — opens `https://github.com/new?name=brain&visibility=private&description=My%20Brain%20Notes` in the in-app browser with plain guidance: *"Create it as Private, then come back and tap Choose notes on GitHub below."* (No extra account-wide repository-creation permissions are requested.)
- **Case C — Multiple repositories or public repositories listed**:
  - Private repositories show `<owner>/<name>` with a **Private** badge (`onboarding.pick.<owner>/<name>`).
  - Public repositories are shown greyed out and disabled (`onboarding.public.<owner>/<name>`) with a **Public** badge and the plain explanation:
    > *"This notes repository is public, so anyone on the internet can read it. Brain Notes only opens private ones. Make it private on GitHub, then try again."*
  - If zero private repositories are listed, the screen explains why and offers **Choose notes on GitHub**, **Refresh**, and **Create my brain**.

---

### 4. You’re all set (`ReadyView` — `onboarding.ready`) + Empty notes space
- Shows download/indexing progress during first sync and enables **Open My Notes** (`onboarding.open`) as soon as sync completes (or immediately with a non-blocking status message if offline).
- **Empty repository support**: If the user just created a brand-new private repository with zero commits (`404` or `409` on ref/tree), first sync finishes cleanly with 0 notes, and `FoldersView` shows a welcoming **Write your first note** card (`home.firstNote`). Saving that first note bootstraps the repository's initial commit on its `default_branch` (`PUT /repos/<owner>/<name>/contents/<path>`, checked by `PathPolicy` and `SecretScan`), and subsequent edits sync via ordinary fast-forward Git commits.

---

### 5. Settings & recovery (`SettingsView`, `RepoIssueView`)
- **Settings → Notes on GitHub**:
  - Shows **Connected notes** as `<owner>/<name>` (`settings.repo`).
  - **Change notes repository** (`settings.changeRepo`): checks `checkUnsyncedBeforeRepoSwitch()` (saving any active editor buffer first). If unsynced local edits exist, presents an explicit plain-language confirmation dialog (`settings.changeRepo.confirm`). Confirmed switches wipe the old repository's entire local folder (`Brain/<repoId>/`), `selected-repo.json`, and in-memory note/undo state **before** opening `ChooseNotesView`, while keeping the user signed in.
  - **Sign out and wipe** (`settings.wipe`): wipes all local files, clears `selected-repo.json`, removes Keychain tokens, and returns to Connect.
- **Access revoked or made public later (`RepoIssueView` — `repoIssue.view`)**:
  - Re-checked on every session open and on `403`/`404` during sync, plus `verifyPrivateRepo()` at every sync start. If the repository was removed from the GitHub App or switched to public, syncing stops immediately and `RepoIssueView` explains what happened in plain English with **Try again** (for public repositories made private again) and **Choose your notes** / **Choose different notes** (which wipes the local copy after warning about any unsynced edits).
