# Security & Ownership

Brain Notes is built for a simple standard: anyone who installs the app should be able to connect **their own private notes repository** on GitHub and trust it with their brain — without trusting a Brain Notes server.

Your notes, your credentials, and your repository permissions stay between your device and GitHub. There is no Brain Notes backend, no account database, and no analytics tracker.

---

## How to verify this yourself (no code required)

You can verify all five guarantees in a minute:

1. **Your notes live on your device.** Turn on Airplane Mode and open Brain Notes. You can read every note, write new ones, edit tables, and search in English or Hebrew. Nothing depends on a cloud service staying up.
2. **Your repository is ordinary Markdown — on its own default branch.** Open your repository on GitHub in any browser. Every note is a plain `.md` file, and every sync is an ordinary fast-forward Git commit on your repository's default branch (`main`, `master`, `trunk`, etc.). If you delete Brain Notes tomorrow, your folder of Markdown files is still yours.
3. **Only the private repository you picked is ever opened.** When you install the Brain Notes GitHub App on GitHub, choose **Only select repositories** and select just your private notes repository. GitHub scopes the user token to the intersection of repositories you can access and repositories where the app is installed — and Brain Notes adds its own client-side guard locking every API call to the single private repository you selected. Public repositories are refused everywhere.
4. **Your GitHub password never touches the app.** Connecting GitHub copies an 8-character one-time code and opens `github.com/login/device` inside Apple's system authentication browser (`ASWebAuthenticationSession`). You approve on GitHub, never inside a custom password form, and you can inspect or revoke access anytime at [github.com/settings/applications](https://github.com/settings/applications).
5. **Switching or signing out means a real wipe.** In **Settings → Change notes repository**, Brain Notes wipes the previous repository's local files, SQLite journal (`-wal`/`-shm`), pins, staging area, search index, and in-memory note/undo buffers *before* opening the picker (warning first if you have unsynced edits). In **Settings → Sign out and wipe**, it wipes all local data, clears your stored selection, and deletes your Keychain credentials. Your notes on GitHub are untouched.

---

## How the security boundaries work in code

If you are auditing the codebase, here is where each boundary lives and how it is enforced:

### 1. Multi-user double-guard & network lockdown (`Discovery.swift`, `PathPolicy.swift`, `GitHubHTTPClient.swift`, `SyncEngine.swift`)
- **GitHub boundary + client installation verification (`GitHubDiscoveryClient`)**: GitHub only lets a GitHub App user-to-server token reach repositories that are **both** in an installation of the Brain Notes GitHub App **and** accessible to that signed-in user. On top of that, Brain Notes never trusts a stored or typed `owner/name` on its own: a repository can be opened only if it is present in `GET /user/installations/{installation_id}/repositories` for an installation returned by `GET /user/installations` for the active token, matched simultaneously by positive numeric `repoId` (`> 0`) **and** byte-exact `owner` **and** `name` (`sameBytes`). This check runs when selecting a repository, every time a session opens (`AppModel.launchRepairAndVerify` and `SyncEngine` installation re-verification), and whenever a sync receives HTTP `403` or `404`. If the repository is no longer listed, syncing stops immediately and the user is shown a plain-language recovery screen that leads back to the picker.
- **Single-host, single-repo per-request guard (`RepoTarget.guardURL`)**: Every repository request in [`GitHubHTTPClient`](Packages/BrainNotesKit/Sources/BrainNotesKit/GitHubHTTPClient.swift) passes through [`RepoTarget.guardURL(_:)`](Packages/BrainNotesKit/Sources/BrainNotesKit/PathPolicy.swift) twice: when the `URLRequest` is constructed and right before it goes on the wire. It rejects any scheme except `https`, any host except `api.github.com`, any URL carrying user credentials, any `..` or percent-encoded path traversal, and any REST path outside `/repos/<picked owner>/<picked name>/...` (plus `/graphql` with variables bound to the picked `owner`/`name`).
- **Strict identifier & branch validation (`PathPolicy.swift`)**:
  - `owner` must match `^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$`.
  - `name` must match `^[A-Za-z0-9._-]{1,100}$`, must not be `.` or `..`, and must not end in `.git` (case-insensitive).
  - Whitespace, slashes, percent-encoding, control characters, empty strings, and Unicode homoglyphs (such as Cyrillic look-alikes) are rejected; comparisons use byte-exact UTF-8 equality (`sameBytes`).
  - `default_branch` from GitHub is validated against Git ref rules (printable ASCII, max 200 bytes, no `..`, no `@{`, no leading `-`, no leading/trailing `/` or `.`, no `//`, not ending in `.lock`, no space or `~^:?*[\`), persisted in `Brain/selected-repo.json`, refreshed on session open, and used everywhere instead of hardcoding `main`.
- **Minimal discovery guard (`DiscoveryGuard`)**: Non-repository calls go exclusively through [`GitHubDiscoveryClient`](Packages/BrainNotesKit/Sources/BrainNotesKit/Discovery.swift), whose `DiscoveryGuard.guardRequest(_:)` permits **only** `GET https://api.github.com/user` (no query), `GET https://api.github.com/user/installations`, and `GET https://api.github.com/user/installations/{positive_numeric_id}/repositories` (with positive integer `per_page` and `page` query items only). Every other endpoint (such as `/user/repos`, `/orgs/...`, `POST` requests, or non-numeric installation IDs) is refused before reaching the transport. Replies enforce the 32 MiB `ReplyLimit.json` byte cap (F-8) and paginate with a hard cap (`maxPages = 10`).
- **Private repositories only**: Brain Notes is strictly for private notes. If a repository has `private == false` or `visibility != "private"`, it is greyed out and unselectable in the picker, refused at session open, and refused before every sync (`GitHubClient.verifyPrivateRepo()`), stopping sync with the plain message:
  > *"This notes repository is public, so anyone on the internet can read it. Brain Notes only opens private ones. Make it private on GitHub, then try again."*
- **Redirect stripping**: First-sync tarball downloads redirect to `https://codeload.github.com`. `RedirectGuard` rejects redirects to any other host, requires `GET` over `https`, and strips the `Authorization` header before following the redirect.
- **Capped replies & zero disk cache**: Every REST/GraphQL reply stops at 32 MiB (`ReplyLimit.json`) and every auth reply stops at 64 KiB (`ReplyLimit.oauth`), checked against `Content-Length` and enforced while streaming. `GitHubSession` uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, and TLS 1.2 minimum.
- **GraphQL variables only**: `lastCommitDates` passes file paths and the repository's validated `owner`, `name`, and `defaultBranch` strictly as GraphQL variables, never interpolated into the query string, and validates all object IDs as 40-to-64-char lowercase hex SHAs (`checkedSha`).

### 2. Why Device Flow + `ASWebAuthenticationSession` (and zero `client_secret`) (`Auth.swift`, `InAppWebSession.swift`, `SignInAndSettings.swift`)
- **Why not GitHub's Web Application Flow?**: Verified against GitHub's documentation (*"Generating a user access token for a GitHub App"*) and GitHub's 2025-07-14 PKCE changelog: GitHub's Web Application Flow for GitHub Apps **still requires `client_secret`** at the `POST /login/oauth/access_token` code-exchange step even when PKCE (`code_challenge` / `code_verifier`) is sent. Because Brain Notes has no backend server and a mobile or desktop app binary cannot keep a `client_secret` confidential, shipping a secret in the app is unacceptable.
- **Secretless Device Flow with expiring user-to-server tokens**: Brain Notes uses GitHub's Device Flow (`POST /login/device/code` and polling `POST /login/oauth/access_token`, plus refresh-token rotation) using **only** the public GitHub App Client ID (`BN_GITHUB_CLIENT_ID`). Static tests in [`PolicyTests.swift`](Packages/BrainNotesKit/Tests/BrainNotesKitTests/PolicyTests.swift) scan every source file to enforce that `client_secret` never appears in code or requests.
- **Smooth in-app browser handoff**: Tapping **Connect GitHub** requests the device code, copies `userCode` to the local expiring pasteboard automatically, displays it large with a one-tap **Copy code** button, and opens `verificationURI` inside `ASWebAuthenticationSession` (`prefersEphemeralWebBrowserSession = false` so users already signed into GitHub in Safari don't have to re-type their password). When background polling succeeds, Brain Notes closes the browser sheet programmatically; if the user dismisses the browser early, Brain Notes treats that as "not yet" and keeps polling until approval or code expiry (respecting GitHub's `interval` and `slow_down` backoff).
- **Device-only Keychain & background eviction**: [`KeychainTokenStore`](Packages/BrainNotesKit/Sources/BrainNotesKit/Auth.swift) stores the expiring `ghu_...` access token and `ghr_...` refresh token with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Tokens are evicted from process memory once background outbox flush completes (`flushInBackground` / `forgetCachedTokens`).
- **No login-keychain fallback on signed Mac builds**: A team-signed Mac Release build uses only the Data Protection Keychain (`keychain-access-groups`) and never falls back to or migrates from the legacy login keychain (`errSecMissingEntitlement` fallback applies only to ad-hoc/unsigned Debug builds).
- **Reinstall hygiene & expiring clipboard**: `AppModel.installCheck` clears stale Keychain tokens left behind by a deleted previous install when `Brain/` and onboarding flags are absent. `DeviceCodeClipboard` marks the copied code `.localOnly` with `.expirationDate` on iOS and clears its exact pasteboard entry on macOS upon sign-in or expiry.

### 3. Per-repo local storage, wipe-before-switch & Data Protection (`FileStore.swift`, `Journal.swift`, `Discovery.swift`, `Session.swift`)
- **Isolated numeric repository folders**: Each repository's local state lives under `Brain/<repoId>/` (keyed by GitHub's positive numeric repository ID, e.g. `Brain/123456789/`), while the non-secret selection metadata (`installationId`, `repoId`, `owner`, `name`, `defaultBranch`, `isPrivate`) lives in `Brain/selected-repo.json`. Two users or two repositories never share a directory, even after renames.
- **Wipe-before-switch**: `BrainSession.wipeForRepoSwitch()` and `BrainSession.signOutAndWipe()` share the same local wipe path (`wipeLocalDataAndSelection()`): stopping the sync engine, deleting `Brain/<repoId>/` (`files/`, `files.staging/`, `journal.sqlite` + `-wal`/`-shm`, `pins.json`, `index/`), clearing `Brain/selected-repo.json`, and dropping all in-memory note lists, open editor references, and delete Undo/BlackHole snapshots (`AppModel.dropSession()`) *before* the repository picker opens.
- **Excluded from backups & encrypted at rest**: Both `Brain/` and `Brain/<repoId>/` are marked `isExcludedFromBackup = true` on iOS and macOS every time they open so iCloud backups and Time Machine never copy unsynced drafts or secret-scan-held notes. On iOS, `files/`, `files.staging/`, and `index/` use `FileProtectionType.complete`, while `Brain/`, `selected-repo.json`, and `journal.sqlite` use `FileProtectionType.completeUntilFirstUserAuthentication`.
- **Path traversal rejection, zero `UserDefaults` leakage, private logging**: `FileStore.url(for:)` rejects traversal segments; `UserDefaults` holds only three boolean flags (`bn.onboarded`, `bn.sampleMode`, `bn.installed`); `NoteStore` logs only via `os.Logger` with `privacy: .private`.

### 4. Git & content safety (`SyncEngine.swift`, `PathPolicy.swift`, `BrainMerge`)
- **Never force-push & empty-repo bootstrap**: `updateRef` always sends `"force": false` (enforced by static test). When a newly created private repository is completely empty (0 commits; `404` or `409 Git Repository is empty` on ref/tree), Brain Notes opens an empty workspace cleanly without crashing or retry-looping, and bootstraps the repository's initial commit on `default_branch` via GitHub's Contents API (`PUT /repos/<owner>/<name>/contents/<path>`, after running `PathPolicy` and `SecretScan`) when the user saves their first note; all subsequent commits use ordinary Git Data fast-forward commits.
- **Deletes go to `_trash/` & conflicts never overwrite**: Deleting a note moves it to `_trash/<path>` on GitHub. Concurrent edits merge via `BrainMerge` ([`docs/merge-spec.md`](docs/merge-spec.md)) and stage conflict copies in `_inbox/` + **Needs attention** rather than overwriting.
- **Pre-commit secret scan, 1 MiB note cap, and bounded first sync**: [`SecretScan`](Packages/BrainNotesKit/Sources/BrainNotesKit/PathPolicy.swift) blocks accidental pushes of tokens, AWS keys, PEM keys, and API secrets; dotfiles and `private/` are excluded; notes above 1 MiB are held back; tarball and blob downloads are strictly bounded by `FirstSyncLimits` (128 MiB compressed, 512 MiB inflated, 100,000 entries, 64 MiB per entry).

---

## Required GitHub App Configuration (for the app owner)

To support any user connecting their own private notes repository with zero server and zero `client_secret`, configure the **Brain Notes** GitHub App on GitHub with these exact settings:

| Setting | Required Value | Why |
| :--- | :--- | :--- |
| **GitHub App visibility** | **Public** | Allows any TestFlight / App Store user to install the app on their own private notes repository. |
| **App slug (`BN_GITHUB_APP_SLUG`)** | Matches the GitHub App's URL slug (default `brain-notes-app`) | Used to open `https://github.com/apps/<slug>/installations/new` during onboarding. |
| **Repository permissions → Contents** | **Read and write** | Required to read Markdown blobs/trees/tarballs and push note commits. |
| **Repository permissions → Metadata** | **Read-only** | Mandatory default on GitHub Apps; lets `/user/installations/{id}/repositories` list selected repositories and their `private` / `default_branch` fields. |
| **All other Repository, Organization & Account permissions** | **No access** | Least privilege: Brain Notes never asks for account-wide repo creation, issues, pull requests, workflows, emails, or profile writes. |
| **Enable Device Flow** | **Enabled (checked)** | Lets iOS and macOS authenticate users with only the public `Client ID` and no `client_secret`. |
| **Expire user authorization tokens** | **Enabled (checked)** | Issues short-lived `ghu_...` access tokens paired with rotating `ghr_...` refresh tokens. |
| **Request user authorization (OAuth) during installation** | **Disabled (unchecked)** | Web OAuth exchange requires `client_secret`; Brain Notes authenticates via Device Flow first and then installs/discovers repositories. |
| **Setup URL** *(optional)* | Blank, or `brainnotes://setup` | Optional fast-return deep link after installing the GitHub App; Brain Notes polls `/user/installations` while the sheet is open and does not depend on Setup URL being set. |
| **Webhook** | **Inactive (unchecked)** | There is no Brain Notes server to receive webhooks. |

---

## Reporting a security issue

If you find a security bug or a boundary that can be bypassed, please open an issue on [GitHub](https://github.com/Itamargend/brain-notes-app/issues) or reach out through [brain-notes-app.vercel.app](https://brain-notes-app.vercel.app/#support).
