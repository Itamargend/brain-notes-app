# Brain Notes app: guidance for coding agents

Brain Notes is a native SwiftUI app (iOS 26+ and macOS 26+) that edits a folder of Markdown notes stored in a
GitHub repo, offline-first, and syncs with the GitHub Git Data API. Merges use the `BrainMerge` package in
`Sources/BrainMerge` (spec in `merge-spec.md`, verified by `bash scripts/verify.sh`: 110/110 vectors, 9,637 differential cases).

The detailed task and architecture are in `.plan/A-app.md` (local only). Read it first.

## Hard rules
- The app talks ONLY to the test repo `Itamargend/brain-notes-test`. Any other repo must be refused in code (and tested).
- Ref updates always send `force: false`. Never `force: true`.
- Tokens live only in the Keychain. No client secret anywhere. Never print, log or commit the client ID or tokens.
  `App/Config/*.local.xcconfig` is git-ignored; commit only `*.example.xcconfig`.
- No network tools (`curl`, `gh`, `wget`), no `git push`, no remotes. Commit locally on branch `m3-app`.
- Do not change BrainMerge behaviour; if you touch it, `bash scripts/verify.sh` must stay green.
- Only synthetic content in fixtures. No real personal notes.
- No third-party dependencies except GRDB (exact pinned version).

## Commands
- Merge library: `bash scripts/verify.sh`
- Kit tests: `cd Packages/BrainNotesKit && swift test`
- Mac: `xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' build test`
- iOS (no simulator installed): `xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
