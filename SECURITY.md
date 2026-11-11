# Security & Ownership

Brain Notes is built for a simple standard: you should be able to trust it with your own brain.

Your notes, your credentials, and your permissions stay in your hands. There is no Brain Notes server, no account database, and no analytics tracker.

---

## How to verify this yourself (no code required)

You do not have to take our word for how the app works. You can check all four claims in a minute:

1. **Your notes live on your device.** Turn on Airplane Mode and open Brain Notes. You can read every note, write new ones, edit tables, and search in English or Hebrew. Nothing depends on a cloud service staying up.
2. **Your repo is just normal Markdown.** Open your repository on GitHub in any browser. Every note is a plain `.md` file. Every sync is an ordinary Git commit on `main`. If you delete Brain Notes tomorrow, your folder of Markdown files is still yours.
3. **Your GitHub login stays between you and GitHub.** When you sign in, Brain Notes gives you an 8-character code and opens `github.com/login/device` in your browser. You type your password on GitHub, never inside the app. You can inspect or revoke the app's permission anytime at [github.com/settings/applications](https://github.com/settings/applications).
4. **Sign out means a real wipe.** In **Settings → Sign out and wipe**, Brain Notes deletes the Keychain token, every downloaded note, the local SQLite journal, and the search index from your device. Your notes on GitHub are untouched.

---

## How the security boundaries work in code

If you are auditing the codebase, here is where each boundary lives and how it is enforced:

### 1. Network lockdown (`GitHubHTTPClient.swift`, `PathPolicy.swift`)
- **Single-host, single-repo guard**: Every request in [`GitHubHTTPClient`](Packages/BrainNotesKit/Sources/BrainNotesKit/GitHubHTTPClient.swift) passes through [`RepoTarget.guardURL(_:)`](Packages/BrainNotesKit/Sources/BrainNotesKit/PathPolicy.swift) twice: when the `URLRequest` is built and right before it goes on the wire. It rejects any scheme except `https`, any host except `api.github.com`, any URL carrying user credentials, any `..` path segment, and any REST path outside `/repos/<owner>/<name>/...`.
- **Repo allow-list**: `RepoTarget` accepts only the repositories on `RepoTarget.allowList` (`Itamargend/brain-notes-test` and `Itamargend/brain`), compared byte for byte. A build names one of them on purpose in `BN_REPO_OWNER` / `BN_REPO_NAME`. Any other value, including a case or whitespace variant, opens no session and leaves the app on its "misconfigured" screen. Every request is then checked against the one repo the build names, never against the whole list.
- **Redirect stripping**: First-sync tarball downloads redirect to `https://codeload.github.com`. `RedirectGuard` rejects redirects to any other host, requires `GET` over `https`, and strips the `Authorization` header before following the redirect.
- **Zero disk cache**: `GitHubSession` uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, and TLS 1.2 minimum. Neither bearer tokens nor note bodies are ever written to `URLCache` (`Cache.db`) on disk.
- **GraphQL variables only**: `lastCommitDates` passes file paths strictly as GraphQL variables (`$p0`, `$p1`, ...), never interpolated into the query string, and validates all object IDs as 40-to-64-char lowercase hex SHAs (`checkedSha`).

### 2. Credentials & Keychain (`Auth.swift`, `SignInAndSettings.swift`)
- **No client secret**: Authentication uses GitHub's OAuth Device Flow (`https://github.com/login/device/code`) and token refresh with the public client ID only. No client secret exists in the app binary or git history.
- **Device-only Keychain**: [`KeychainTokenStore`](Packages/BrainNotesKit/Sources/BrainNotesKit/Auth.swift) stores the token pair with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The token cannot be read while the device is locked, is never synced to iCloud Keychain, and is never included in device backups.
- **No login-keychain fallback on a signed Mac build**: A Mac build uses the file-based login keychain only when it cannot use the data protection keychain at all (`errSecMissingEntitlement`: an ad-hoc or unsigned build). A team-signed build that finds no token of its own does not look there, and does not move an item from there either, since anything running as the user can plant one; signing in again is the cost of switching from an ad-hoc build. Sign out still deletes the item from both keychains. Only a Keychain that is locked right now counts as "may still be signed in"; any other Keychain error shows sign-in.
- **Reinstall hygiene**: `AppModel.installCheck` detects when the app was deleted and reinstalled (Keychain item survived, but local app storage is gone) and clears the stale Keychain token on launch so a fresh install always starts signed out.
- **Expiring clipboard**: On iOS, copying the one-time device code sets `UIPasteboard.OptionsKey.localOnly`, so it never travels by Universal Clipboard, and `expirationDate` to the code's expiration time, so it clears itself. macOS has neither option: `DeviceCodeClipboard` takes the code off the pasteboard after a successful sign-in or when the code expires, but only if the pasteboard still holds that exact copy (same change count and text), so anything copied since is left alone. If the app quits before then, the code stays until something else is copied; it is useless once it expires.

### 3. Local storage & Data Protection (`FileStore.swift`, `Journal.swift`, `SearchIndex.swift`)
- **Path traversal rejection**: [`FileStore.url(for:)`](Packages/BrainNotesKit/Sources/BrainNotesKit/FileStore.swift) rejects empty paths, empty segments, `.`, and `..` before touching the file system.
- **Out of backups**: Everything of a repo lives in one folder, `Brain/<repo>/`: the notes, first sync's staging folder, `journal.sqlite` and the files SQLite makes next to it, the search index, and `pins.json`. That whole folder is marked `isExcludedFromBackup = true` on iOS and macOS every time it opens, so neither iCloud/device backups nor Time Machine copy unsynced text, including notes the secret scan kept from GitHub. A device restored from a backup signs in and downloads the notes again; text not yet synced when the backup was made is not in it.
- **Encryption at rest**: On iOS, `files/`, `files.staging/`, and `index/` are marked with `FileProtectionType.complete`. The repo folder and `journal.sqlite` use `FileProtectionType.completeUntilFirstUserAuthentication` (files created there later, such as SQLite's rollback journal and `pins.json`, get the same class) so an in-flight background flush can complete right after the screen locks.
- **Zero `UserDefaults` leakage**: `UserDefaults` holds only three boolean onboarding flags (`bn.onboarded`, `bn.sampleMode`, `bn.installed`). A static test in [`PolicyTests.swift`](Packages/BrainNotesKit/Tests/BrainNotesKitTests/PolicyTests.swift) scans all source files to guarantee `UserDefaults` is never used anywhere else.
- **Private unified logging**: [`NoteStore.swift`](Packages/BrainNotesKit/Sources/BrainNotesKit/NoteStore.swift) logs only via `os.Logger` with `privacy: .private` on paths and text. A static test in `PolicyTests.swift` enforces zero `print(` or `NSLog(` statements across the kit and app.

### 4. Git & content safety (`SyncEngine.swift`, `PathPolicy.swift`, `BrainMerge`)
- **Never force-push**: `updateRef` always sends `"force": false`. A static test in `PolicyTests.swift` scans the entire codebase to ensure `force: true` never appears.
- **Deletes go to `_trash/`**: Deleting a note in the app moves it to `_trash/<path>` on GitHub in the next commit instead of erasing it. Even unsynced local edits on a deleted note are saved to `_trash/unsynced-...` first.
- **Conflict copies, never overwrites**: Three-way merges run off the main thread using `BrainMerge` ([`docs/merge-spec.md`](docs/merge-spec.md)). If the same lines were edited on two devices, both versions are preserved and a conflict copy is created in `_inbox/` for side-by-side review in **Needs attention**.
- **Pre-commit secret & path scan**: API commits skip local git hooks, so [`SecretScan`](Packages/BrainNotesKit/Sources/BrainNotesKit/PathPolicy.swift) scans new edits for GitHub tokens (`ghp_...`, `github_pat_...`), AWS keys (`AKIA...`), PEM private keys, and API key assignments before pushing. Hits are parked in **Needs attention** and never committed. Dotfiles (`.obsidian/`, `.git/`) and `private/` are never stored or committed, and notes over 1 MiB are never committed.
- **Bounded first sync**: The first-sync tarball is read under [`FirstSyncLimits`](Packages/BrainNotesKit/Sources/BrainNotesKit/Tarball.swift): a 128 MiB download (checked against `Content-Length` up front and again as bytes arrive), 512 MiB inflated (counted while inflating, so a gzip bomb stops there), 100,000 entries, and 64 MiB for any one entry. Each note the app stores goes to the staging folder the moment it is read, so one note at a time is in memory; everything else streams past. When the tarball fails and first sync falls back to the blobs API, the same limits hold: at most 100,000 notes, 64 MiB per blob (the HTTP client stops reading a blob's answer past what that size encodes to), and 512 MiB in all, with each note written to staging as it arrives. Blobs fetched later (pulls, merges) are held to 64 MiB each and 512 MiB per batch, and a run keeps at most 64 MiB of them for retries. A repository past a limit stops first sync with a "too large" message and is not retried until **Sync now**.

---

## Reporting a security issue

If you find a security bug or a boundary that can be bypassed, please open an issue on [GitHub](https://github.com/Itamargend/brain-notes-app/issues) or reach out through [brain-notes-app.vercel.app](https://brain-notes-app.vercel.app/#support).
