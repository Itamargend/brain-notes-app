# cloud/integration

Branch `cloud/integration`, from `editor-spike` at f6e792a. Merges eight cloud branches one by one, each as a
`--no-ff` merge commit, in this order: `cloud/tables-kit`, `cloud/lists-kit`, `cloud/links-kit`, `cloud/search-kit`,
`cloud/move-pin-kit`, `cloud/add-to-brain-kit`, `cloud/kit-review`, `cloud/readme`. Then I fixed what the first real
build and test run found. No App sources changed. BrainMerge (`Sources/`, `Tests/`, `spec/`, the root `Package.swift`)
was not touched (`git diff editor-spike -- Sources Tests spec Tools Package.swift` is empty).

## Toolchain

`download.swift.org` is refused by this session's proxy. Ubuntu's archive is reachable, and its `swiftlang 6.1.3`
(packaged for a newer Ubuntu) runs on 24.04 once `libxml2.so.16` is added, also taken from the archive. The packages
were unpacked with `dpkg -x` into the scratchpad, not installed. GitHub was reachable, so SwiftPM fetched GRDB 7.12.0
as pinned.

The manifests say `swift-tools-version: 6.2` and `.v26` platforms, which 6.1 can't parse. Every build ran on a scratch
copy of the tree with those lowered (tools 6.1, `.macOS(.v15)`, `.iOS(.v18)`). The committed manifests are unchanged
in that respect.

## Conflict resolutions

Only `Packages/BrainNotesKit/Package.swift` conflicted, three times. Each branch had made its own Linux-only
manifest.

1. **links-kit into tables + lists.** tables-kit used `#if os(macOS)` with a tables-only package elsewhere. links-kit
   used `#if canImport(CryptoKit) && …` with a Links-only BrainNotesKit elsewhere. Kept both: tables-kit's
   `os(macOS)` test (it runs on the macOS host for iOS builds too). Off a Mac, the package declared the tables targets
   plus BrainNotesKit limited to `sources: ["Links"]`.
2. **search-kit.** search-kit rebuilt the manifest with `var` arrays and `#if canImport(Darwin)`, and declared no
   dependencies off Apple. Rewrote it as shared `products` and `portableTargets` (tables and NoteSearch) plus
   `kitTargets` chosen by `os(macOS)`. Dependencies stay declared everywhere, which keeps tables-kit's rule that
   `Package.resolved` reads the same on every host.
3. **kit-review.** kit-review made the whole kit portable (`Digest.swift`, `Inflate.swift`, `#if canImport` guards)
   and added GRDB to the test target. The manifest no longer needs a split, so it now declares everything on every
   host: BrainNotesKit (depends on BrainNotesTables, BrainMerge, GRDB), BrainNotesKitTests (also GRDB, from
   kit-review), BrainNotesTables and its tests with the `Fixtures` resource, and NoteSearch and its tests. There are
   three library products. The `@_exported import BrainNotesTables` in `Tables.swift` is kept, so the app gets the
   tables through BrainNotesKit.

`NoteStore.swift` was changed by both add-to-brain (`createOnly:`) and kit-review (`Log` / `QuietLog`), in different
places. Git merged it with no conflict, and it compiles.

## Fixes after merging (each its own commit)

- **7577eac, NoteSearch test.** `manyThreadsAtOnce` expected `search("body").count == 528`, but `search` has a default
  `limit: 50`. The test now passes `limit: 1_000`. The index was right.
- **Linux compile errors (two), found by the first full build after kit-review:**
  - `MarkdownEdits.word(touching:)`: corelibs marks `enumerateSubstrings(.byWords)` unavailable. Off Darwin, a plain
    scan finds the run of letters, marks and digits around the caret, keeping an apostrophe or a geresh/gershayim
    between letters. Apple keeps the enumeration.
  - `SyncEngine.reschedule`: Swift 6.1 rejects the inner `Task { await self?.tick() }` because it captures the outer
    closure's `weak self` var, which 6.1 counts as a sending race. It is now `Task { [weak self] in … }`, which
    behaves the same. 6.2 may accept the old form, but the new one is fine on both.
- **WikiLinks against the editor (links-kit against editor-spike).** `LinksEditorAgreementTests` failed on
  `[[a b]]`. The kit parser ended a line at U+2028 and U+0085. NSString `.byParagraphs`, which the editor uses,
  breaks only at LF, CR, CRLF and U+2029 (checked on Linux; this is CoreFoundation's paragraph rule). The parser and
  `BacklinkIndex`'s line counting now use the editor's breaks. `WikiLinksTests` gets a test for this, and its
  "not links" list drops the U+2028 case. The agreement test gets hand-picked cases and random pieces with U+2028,
  U+0085 and U+2029, so a Mac run checks this against Apple's Foundation too.
- **Pins (move-pin-kit) against the policy test (editor-spike).** `UserDefaultsPinsStore` failed
  `PolicyTests.noClientSecretAndNoTokenInUserDefaults` (UserDefaults only in the app model), and on a Mac too. Its
  key also outlives sign-out's wipe. I removed it and its two tests. `FilePinsStore`, which the plan already
  recommends and which the wipe deletes, and `MemoryPinsStore` stay. `docs/plan/move-pin-kit.md` says so.
- **`FencedCode.hasFenceLine`.** swift-corelibs-foundation's `.byParagraphs` enumeration ignores its `in:` range and
  walks the whole string (seen in a probe). Off Darwin it now steps through paragraphs with `getParagraphStart`.
  Apple is unchanged. The App's own uses of `.byParagraphs` are Apple-only and pass the whole range anyway.
- **PolicyTests, Apple facts.** Two tests only hold on Apple, so they now run only there: APFS reading an NFC path for
  an NFD file, and `isExcludedFromBackup` (corelibs doesn't keep the flag).
- Docs: a one-line "update on cloud/integration" in `docs/plan/{tables,links-kit,search-kit,add-to-brain}.md` and
  `docs/review/KIT-REVIEW.md`, whose Linux claims the unified manifest made stale. A "Linux run" subsection in the
  README.

Also checked: no type in BrainNotesTables or NoteSearch shares a name with one in BrainNotesKit or `App/Sources`, so
the re-export can't make a name ambiguous. No public kit API that the App uses was removed or changed. The only
signature change is `NoteStore.save(…, createOnly: Bool = false)`, which is internal and defaulted. The one public
type removed, `UserDefaultsPinsStore`, was new and unused.

## Verified (Linux, Swift 6.1.3, debug, 4 cores)

- `cd Packages/BrainNotesKit && swift build --build-tests`: builds the whole kit, tables, NoteSearch and all tests.
  The only warnings are unused values.
- `swift test`: **614 tests in 68 suites, 612 pass**. The two that fail are timing budgets:
  `searchIsFastOnABrainSizedIndex` (< 0.1 s) and `saveIsFastEnoughForABigNote` (< 0.2 s). They fail only under
  parallel load: run alone with `--filter`, both pass, and so does `aBrainSizedRepo`, which failed once under load.
  I didn't change any budget.
- `bash scripts/verify.sh` (BrainMerge): 110/110 vectors and **9,609 of 9,637** differential cases. All 28 misses are
  `foldKey` on Unicode 17 case pairs (U+16EA0–U+16EB8, U+A7CE, U+A7D2, U+A7D4), which Swift 6.1's Unicode tables
  don't have. The TypeScript reference and the Mac's newer Swift lowercase them. This is the toolchain, not the code.
- The swift-corelibs `.byParagraphs`, `paragraphRange` and line-separator behaviour these fixes rely on was checked
  with small probes.

## Not verified

- **Nothing on Apple.** No `swift test` on a Mac, no `xcodebuild` for macOS or iOS. The Apple sides of the `#if`
  branches (CryptoKit, Compression, Keychain, NWPathMonitor, os.Logger, `.byWords`) were compiled by nobody in this
  session.
- **Swift 6.2.** Everything ran on 6.1.3 with lowered manifests. 6.2's stricter or looser checks may differ.
- The U+0085 / U+2028 rule is assumed to match Apple's Foundation because CoreFoundation's code is shared. The new
  agreement cases will confirm or refute that on a Mac.
- The Linux word finder in `MarkdownEdits` is covered by the existing caret-in-a-word bold tests (`bo‸ld`, `מי‸לה`,
  `ג'ינ‸ס`, `c‸d`), which pass on Linux. Whether it matches `.byWords` on rarer text (numbers with separators, emoji,
  other scripts) is unchecked. It only runs off Apple.
- The App isn't wired to the new kit pieces (tables, lists, links, NoteSearch, moves, pins, Add to Brain). Each branch's
  `docs/plan/*.md` says how. The App target compiles against BrainNotesKit only, unverified here.
- `RealGitTests` and the HTTP tests ran against local fakes only. Nothing talked to GitHub.

## Before merging

```sh
cd Packages/BrainNotesKit && swift test
bash scripts/verify.sh
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' build test
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
