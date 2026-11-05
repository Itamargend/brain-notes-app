# cloud/a11y-rtl-audit

Branch from `editor-spike` @ f6e792a. An audit of the SwiftUI app target for accessibility (VoiceOver, Dynamic Type,
Reduce Motion, contrast) and Hebrew/RTL in the editor and lists, with small fixes. **`EditorToolbar.swift` / the
keyboard bar was not touched**: no line in it changed, and nothing calls into it differently.

## Toolchain

- No Swift installed. `download.swift.org` is blocked by the proxy (403). Docker Hub hit its rate limit (429), so
  `mirror.gcr.io/library/swift:6.2-noble` was pulled instead, which gave Swift 6.2 in Docker.
- Apple-only frameworks don't exist on Linux, so neither the app target nor full BrainNotesKit can build here.
- Each edited app file passes `swiftc -parse`. That is a syntax check only, with no type checking.
- A scratch harness (outside the repo) compiled BrainMerge + `NoteText`, `MarkdownInline`, `MarkdownEdits` and
  `Exact`, with a stub `PathPolicy`. Two Linux-only stubs were needed: `inlineMarkdown` became a plain
  `AttributedString` (corelibs has no Markdown parser), and `.byWords` became composed characters (unavailable on
  Linux). Neither stub is in the repo.

## Fixes made (commit 1)

| Where | What | Why |
|---|---|---|
| `NoteListView.swift` `StatusDot` | With **Differentiate Without Color**, a different SF Symbol for each state (`NoteSyncStatus.shapeSymbol`). Label and identifier unchanged | The orange and green dots are about 2.2:1 on white (WCAG 1.4.11 asks for 3:1), and colour was the only thing telling the states apart on screen |
| `NoteRow` | The dot's top offset is now `@ScaledMetric(relativeTo: .headline)` | At large text sizes the dot no longer lines up with the title |
| `SearchResultsView` folder caption | `.tertiary` changed to `.secondary` | Tertiary grey text is about 2.3:1, too faint for words |
| `FoldersView.swift` `CountRow` | Icon `accessibilityHidden`. Icon column is `@ScaledMetric` | VoiceOver said "tray, Inbox, 6" and "folder, projects, 3" |
| `RootView.swift` `RouteLink` (Mac) | The selected row gets the `.isSelected` trait | The 18% tint was the only sign of which row is open |
| `MarkdownViews.swift` viewer task row | Now `.accessibilityElement(children: .combine)`, and the label comes from `BlockView.taskLabel`, built from the rendered inline text | Before, the label was on a bare HStack and could land on the box and the text separately. It also read raw Markdown (`Done: **Buy** milk`) |
| viewer bullet row | `•` hidden from VoiceOver | It added a "bullet" stop before every item |
| iOS editor `Coordinator` | Restyles everything on `UIContentSizeCategory.didChangeNotification` and `boldTextStatusDidChangeNotification`. Only attributes change, never characters, and nothing happens while a composition is open | The styler sets fonts itself. Bold and heading fonts built with `withSymbolicTraits` lose their text style, so `adjustsFontForContentSizeCategory` couldn't resize an open note |
| `AttentionViews.swift` `VersionColumn` | Lines that exist in only one version get `accessibilityValue("Only in this version")` | The tint was the only signal of a difference |
| `NoteScreen.swift` | The save-problem and banner icons are hidden from VoiceOver, the save problem is one element, and the "Changed …" footnote moved from `.tertiary` to `.secondary` | Redundant icon names, and contrast |
| `OnboardingFlow.swift` | `.animation(reduceMotion ? nil : .smooth, value: current)` | Content slid between steps even with Reduce Motion on |
| `SignInAndSettings.swift` | Sign-in sheet icon hidden. Device code is now `@ScaledMetric(relativeTo: .largeTitle)` 44 (it already shrinks to fit one line) | Decorative icon, and Dynamic Type |

Checked and fine as it was: the accent pills (light accent with white text 5.1:1, dark accent with black text
7.5:1, accent text on grouped background 4.6:1); the per-paragraph direction in both the viewer and the editor;
code staying LTR; `.swipeActions(edge: .trailing)` and `.padding(.leading)` flipping correctly; the RLM in front of a
Hebrew row's date; marks staying visible under VoiceOver; the custom tick action; and the device code staying LTR
and being spelled out for VoiceOver.

## Tests

- **Verified on Linux** (harness, Swift 6.2): new `Packages/BrainNotesKit/Tests/BrainNotesKitTests/DirectionAuditTests.swift`,
  15 RTL and 4 LTR paragraphs (wiki link, bold, strikethrough, quote, list, `1)`, year first, emoji first, indented,
  `#` with no space, Arabic). All pass. In the same harness, every existing `MarkdownEditsTests` case passes except the
  8 caret-word tests, which fail only because of the `.byWords` stub (expected, a harness artifact).
- **Unverified** (written blind, needs a Mac run): an extension on `ScreenWalkTests` at the end of
  `App/AppTests/ScreenWalkTests.swift`. I added it to an existing file because the project is XcodeGen-generated, and a
  new file would mean regenerating `project.pbxproj`.
  - `testEveryNoteStateHasItsOwnShapeForWhenColourIsNotEnough`: shapes are distinct and real SF Symbols.
  - `testATaskIsReadWithoutItsMarkdownMarks`: English, Hebrew, and a link.
  - `testACountRowIsReadWithoutItsIconName`: the hosted home screen; the `home.inbox` label has "Inbox" and no "tray".
- **Unverified, not compiled**: none of the SwiftUI/UIKit changes were type-checked. Points to check on the Mac:
  - `.accessibilityAddTraits(isSelected ? .isSelected : [])` type inference.
  - `.accessibilityValue(onlyHere ? Text(...) : Text(verbatim: ""))`.
  - The Swift 6 sendability of the new `NotificationCenter` closures in the iOS coordinator. They capture `[weak self, weak view]`, both MainActor types, and use `MainActor.assumeIsolated`, the same pattern as the existing VoiceOver observer.
  - `BlockView` changed from `private` to internal so the test can reach `taskLabel`.
- `bash scripts/verify.sh` was not run. BrainMerge was not touched.

To run on the Mac:
```
cd Packages/BrainNotesKit && swift test --filter DirectionAuditTests
xcodebuild -project App/BrainNotes.xcodeproj -scheme BrainNotes -destination 'platform=macOS' test -only-testing:BrainNotesTests/ScreenWalkTests
```
(Check the test target name in `project.yml` if `-only-testing` doesn't match.)

## Larger findings (not fixed)

1. **A Hebrew paragraph that starts with a URL or inline code runs LTR.** Examples: `https://x.com שלום`,
   `` `code` שלום ``. This follows Unicode P2 (the first strong character decides), but the user meant a Hebrew
   sentence. Option: skip link/URL/code spans when looking for the first strong letter (`MarkdownInline` already knows
   the spans). This affects the viewer, the editor and file naming, so it needs a decision and fresh tests. I left it
   unpinned on purpose.
2. **The editor's Hebrew-italic fallback checks only U+0590–05FF.** Arabic italic gets the same nothing-happens
   problem. Widen it to the same ranges `NoteText.isRightToLeft` uses.
3. **Status icon hit target is 28×28** (`StatusIconButton`, iOS toolbar). Apple's minimum is 44×44. It belongs in
   the toolbar and status design, so I left it for the redesign.
4. **Viewer: tap-to-edit text has no trait or hint.** VoiceOver users can double-tap a paragraph to start editing,
   but nothing tells them. Consider one `accessibilityHint("Double-tap to edit")` on the viewer's `ScrollView`, or rely
   on the Edit button. Don't put it on every block.
5. **Mixed-direction folder paths in search captions.** `SearchIndex.folder(of:)` text gets no direction. A path
   like `projects/עברית/notes` can reorder visually. Consider an FSI/PDI isolate around each segment, or
   `paragraphDirection` from the first segment.
6. **Mac editor and Dynamic Type.** macOS 26's text-size setting isn't followed. The editor uses `preferredFont`
   once, with no observer. Low priority on Mac.
7. **The App UI is English-only.** `options.hebrew` flips only onboarding. If a Hebrew localization is ever added,
   check the hard-coded `"Done: "`/`"To do: "`, `"Only in this version"` and the `StatusBadge` strings. All of them
   are plain `String`, not `LocalizedStringResource`.
8. **Compare view, visually.** "Only in this version" is now spoken, but with Differentiate Without Color it still
   shows only as tint on screen. A leading bar or `+` gutter would fix it. That's a design choice.
9. **Countdown under VoiceOver.** The waiting label's text changes every second. If VoiceOver re-announces it, that's
   noisy. Check on a device. If so, round to the minute in the label.
