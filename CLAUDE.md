# Brain Notes: guidance for contributors & coding agents

Brain Notes is a native SwiftUI app (iOS 26+ and macOS 26+) that edits a folder of Markdown notes stored in a
GitHub repo, offline-first, and syncs with the GitHub Git Data API. Merges use the `BrainMerge` package in
`Sources/BrainMerge` (spec in `merge-spec.md`, verified by `bash scripts/verify.sh`: 110/110 vectors, 9,637 differential cases).

## Hard rules
- By default, live sync talks ONLY to the configured repository (`RepoTarget.allowed`, defaulting to `Itamargend/brain-notes-test`). Any other repo is refused in code and tested.
- Ref updates always send `force: false`. Never `force: true`.
- Tokens live only in the Keychain. No client secret anywhere. Never print, log or commit the client ID or tokens.
  `App/Config/*.local.xcconfig` is git-ignored; commit only `*.example.xcconfig`.
- Do not change `BrainMerge` behaviour without updating the spec and vectors; `bash scripts/verify.sh` must stay green.
- Only synthetic content in fixtures (`Fixtures/demo-brain/`). Never commit personal notes.
- No third-party dependencies except GRDB (exact pinned version).

## Commands
- Merge library: `bash scripts/verify.sh`
- Kit tests: `cd Packages/BrainNotesKit && swift test`
- Mac: `xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' build test`
- iOS (generic build): `xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
