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
- **Redirect stripping**: First-sync tarball downloads redirect to `https://codeload.github.com`. `RedirectGuard` rejects redirects to any other host, requires `GET` over `https`, and strips the `Authorization` header before following the redirect.
- **Zero disk cache**: `GitHubSession` uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, and TLS 1.2 minimum. Neither bearer tokens nor note bodies are ever written to `URLCache` (`Cache.db`) on disk.
- **GraphQL variables only**: `lastCommitDates` passes file paths strictly as GraphQL variables (`$p0`, `$p1`, ...), never interpolated into the query string, and validates all object IDs as 40-to-64-char lowercase hex SHAs (`checkedSha`).

### 2. Credentials & Keychain (`Auth.swift`, `SignInAndSettings.swift`)
- **No client secret**: Authentication uses GitHub's OAuth Device Flow (`https://github.com/login/device/code`) and token refresh with the public client ID only. No client secret exists in the app binary or git history.
- **Device-only Keychain**: [`KeychainTokenStore`](Packages/BrainNotesKit/Sources/BrainNotesKit/Auth.swift) stores the token pair with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The token cannot be read while the device is locked, is never synced to iCloud Keychain, and is never included in device backups.
- **Reinstall hygiene**: `AppModel.installCheck` detects when the app was deleted and reinstalled (Keychain item survived, but local app storage is gone) and clears the stale Keychain token on launch so a fresh install always starts signed out.
- **Expiring clipboard**: On iOS, copying the one-time device code sets `UIPasteboard.OptionsKey.expirationDate` to the code's expiration time so the code clears itself from the pasteboard automatically.

### 3. Local storage & Data Protection (`FileStore.swift`, `Journal.swift`, `SearchIndex.swift`)
- **Path traversal rejection**: [`FileStore.url(for:)`](Packages/BrainNotesKit/Sources/BrainNotesKit/FileStore.swift) rejects empty paths, empty segments, `.`, and `..` before touching the file system.
- **Encryption at rest**: On iOS, `files/`, `files.staging/`, and `index/` are marked with `FileProtectionType.complete` and `isExcludedFromBackup = true`. The repo root and `journal.sqlite` use `FileProtectionType.completeUntilFirstUserAuthentication` so an in-flight background flush can complete right after the screen locks.
- **Zero `UserDefaults` leakage**: `UserDefaults` holds only three boolean onboarding flags (`bn.onboarded`, `bn.sampleMode`, `bn.installed`). A static test in [`PolicyTests.swift`](Packages/BrainNotesKit/Tests/BrainNotesKitTests/PolicyTests.swift) scans all source files to guarantee `UserDefaults` is never used anywhere else.
- **Private unified logging**: [`NoteStore.swift`](Packages/BrainNotesKit/Sources/BrainNotesKit/NoteStore.swift) logs only via `os.Logger` with `privacy: .private` on paths and text. A static test in `PolicyTests.swift` enforces zero `print(` or `NSLog(` statements across the kit and app.

### 4. Git & content safety (`SyncEngine.swift`, `PathPolicy.swift`, `BrainMerge`)
- **Never force-push**: `updateRef` always sends `"force": false`. A static test in `PolicyTests.swift` scans the entire codebase to ensure `force: true` never appears.
- **Deletes go to `_trash/`**: Deleting a note in the app moves it to `_trash/<path>` on GitHub in the next commit instead of erasing it. Even unsynced local edits on a deleted note are saved to `_trash/unsynced-...` first.
- **Conflict copies, never overwrites**: Three-way merges run off the main thread using `BrainMerge` ([`docs/merge-spec.md`](docs/merge-spec.md)). If the same lines were edited on two devices, both versions are preserved and a conflict copy is created in `_inbox/` for side-by-side review in **Needs attention**.
- **Pre-commit secret & path scan**: API commits skip local git hooks, so [`SecretScan`](Packages/BrainNotesKit/Sources/BrainNotesKit/PathPolicy.swift) scans new edits for GitHub tokens (`ghp_...`, `github_pat_...`), AWS keys (`AKIA...`), PEM private keys, and API key assignments before pushing. Hits are parked in **Needs attention** and never committed. Dotfiles (`.obsidian/`, `.git/`), `private/`, and files over 1 MiB are never downloaded or committed.

---

## Reporting a security issue

If you find a security bug or a boundary that can be bypassed, please open an issue on [GitHub](https://github.com/Itamargend/brain-notes-app/issues) or reach out through [brain-notes-app.vercel.app](https://brain-notes-app.vercel.app/#support).
