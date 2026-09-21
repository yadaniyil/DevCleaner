# DevCleaner — instructions for agents

A macOS app (SwiftPM, Swift 6.2, macOS 14+) that frees disk space on a developer's Mac. The
main window is a **deck**: one card at a time, **Skip** or **Clean up**. The menu bar item is
only a status panel that opens the window. There is also a CLI (`devcleaner`).

## Layout

- `Sources/CleanerCore` — the engine: scanners (`Scan/`), protection rules, `Executor`,
  `PathGuard`, run log, CLI text. No UI.
- `Sources/DevCleanerUI` — every decision and **every user-facing string** the app makes
  (`ProjectDeck.swift`, `AppModel.swift`, `StatusPanel.swift`, …). A test target cannot import
  an executable, so anything checkable lives here.
- `Sources/DevCleanerApp` — SwiftUI views only. They classify, total and phrase nothing.
- `Sources/devcleaner` — the CLI.
- `Tests/CleanerCoreTests`, `Tests/DevCleanerUITests` — swift-testing.

## Commands

```sh
swift build
swift test                        # full suite; must be green before you stop
Scripts/make-app.sh release       # → build/DevCleaner.app (ad-hoc signed)
open build/DevCleaner.app
swift run devcleaner scan         # read-only listing
swift run devcleaner clean --dry-run
```

## House rules

- TDD. swift-testing (`@Test func sentenceLikeName()`), a pinned clock, fakes in
  `Tests/*/Doubles.swift`. Tests use temp directories only — never the real home folder.
- Doc comments explain **why**, in the voice and density of the surrounding code.
- Sizes go through `ByteText.short`. Paths shown to people are `~`-abbreviated.
- An interface acts on `selectedByDefault`, never `isDeletable`. Protected rows are never
  handed to `engine.clean`.
- New `Codable` fields on stored types decode with `decodeIfPresent ?? default`.
- Scanners use **fixed lists** of places. Never "walk and offer whatever is big".

## Safety — this app deletes things in the user's home folder

- `PathGuard` licences stay as narrow as possible: narrow roots, exact paths, container
  folders as forbidden targets. Never add the home folder, `~/Library/Application Support`
  or a whole app folder as a root. A scanner that offers a new place must add its licence,
  or the row is refused after the user presses the button.
- Things that do not come back (`RiskLevel.irreplaceable`: the user's own files, AI models)
  always go to the Trash, are never default-ticked, and their button is click-only.
  Permanent deletions (simulators, runtimes, emulators) say "for good" and are click-only.
- "It is a cache" is not enough. Cleaning `~/.cache/huggingface` once broke a user's
  on-device dictation app, whose model lived there. If an app someone relies on keeps working
  data in a place, treat it as theirs: per-item, click-only, or not offered at all.
- When testing the real app on a real Mac: look, screenshot, press Skip — **never press
  Clean up on the user's files** unless they ask.
- Cleaning this project's own card trashes `build/DevCleaner.app` while it runs. Rebuild with
  `Scripts/make-app.sh release`.
