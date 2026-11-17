# Contributing to Brain Notes

Thank you for helping make **Brain Notes** better.

## Ideas, Feature Requests & Community

- **Feature ideas & voting:** Open a thread in **[GitHub Discussions → Ideas](https://github.com/Itamargend/brain-notes-app/discussions/categories/ideas)** (or upvote an existing one so we know what matters most).
- **Live chat & feedback:** Join the **[Brain Notes Telegram group](https://t.me/brainnotesapp)**.
- **Bugs:** Open an issue using the **[Bug Report](https://github.com/Itamargend/brain-notes-app/issues/new/choose)** template with steps to reproduce.
- **Security vulnerabilities:** Please do **not** open a public issue for security bugs. Follow the disclosure instructions in **[SECURITY.md](SECURITY.md)**.

## Local Development Setup

You only need a Mac with **Xcode 26** or newer. There are no external servers, databases, or third-party CLIs required to build and test.

```bash
git clone https://github.com/Itamargend/brain-notes-app.git
cd brain-notes-app
open App/BrainNotes.xcodeproj
```

- **Sample Mode works out of the box:** Run the `BrainNotes` scheme (**⌘R**) and tap **Try with Sample Notes** to test editing, folders, search, tables, checklists, RTL, and conflict resolution completely offline.
- **Testing GitHub sync locally (optional):** Copy `App/Config/GitHubApp.example.xcconfig` to `App/Config/GitHubApp.local.xcconfig` and `App/Config/Signing.example.xcconfig` to `App/Config/Signing.local.xcconfig` (both `.local.xcconfig` files are git-ignored). Configure a GitHub App following **[SECURITY.md](SECURITY.md)**.

## Running the Test Suites Before Opening a PR

All core tests are deterministic and run offline against an in-process fake GitHub server:

```bash
# 1. Pure 3-way Markdown merge engine + spec & differential vectors
swift test

# 2. BrainNotesKit: sync engine, URL guards, FTS5 search, Markdown & table parsers, and policy rules
swift test --package-path Packages/BrainNotesKit
```

### Codebase Guardrails (`SourceRulesTests`)

`Packages/BrainNotesKit/Tests/BrainNotesKitTests/PolicyTests.swift` enforces strict security and architecture invariants across every source file:

1. **Zero secrets or tokens outside hardware Keychain** — never store tokens, repository names, or note data in `UserDefaults` / `@AppStorage`.
2. **Strict network & path isolation** — all network traffic goes through `RepoTarget.guardURL` (locked to a single verified private repository's numeric ID) or `DiscoveryGuard`, and all local paths pass through `PathPolicy`.
3. **Byte-exact Markdown preservation** — never normalize Unicode forms (`NFC`/`NFD`) or line endings behind the user's back, and never force-push (`force: true` is banned across the repository).
4. **No `print(` or `NSLog(`** — use the redacted `Log` helper so note contents and paths never enter Release system logs.

## License

By contributing to Brain Notes, you agree that your contributions will be licensed under the **[MIT License](LICENSE)**.
