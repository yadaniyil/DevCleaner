# DevCleaner

A macOS menu bar app that reclaims disk space taken by mobile-development caches —
Xcode DerivedData and archives, iOS simulators, Android SDK components and emulators,
Gradle, Flutter/Dart, and per-project build output — while protecting projects you are
actively working on, one simulator, one emulator, and the Flutter SDK versions your
active projects depend on.

Local-only: no network requests, no telemetry.

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6 toolchain (to build)

## Build and install

```sh
./Scripts/make-app.sh debug
```

This produces `build/DevCleaner.app` (ad-hoc signed) and `build/DevCleaner.zip`.
Move the app to `/Applications` and launch it.

There is also a command-line interface:

```sh
swift run devcleaner scan
swift run devcleaner clean --dry-run
```

## Tests

```sh
swift test
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
