import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

// The model's own state machine: opening on a cache, scanning, and the settings it holds.
// The clean path is the deck's and lives in `AppModelDeckTests.swift`; the menu bar panel
// it feeds is in `StatusPanelTests.swift`.

// MARK: - the fake engine

actor EngineLog {
    private(set) var scans = 0
    private(set) var cleanDefaults = 0
    private(set) var cleans: [[String]] = []
    /// The `now:` every call was handed, newest last.
    ///
    /// Recorded because the model's injected clock is otherwise invisible: the fake ignores
    /// the parameter, so swapping `clock()` for `Date()` in `AppModel` — the one thing this
    /// project bans outright — changes nothing any test can see.
    private(set) var times: [Date] = []

    func scanned(at time: Date) { scans += 1; times.append(time) }
    func cleanedByDefault(at time: Date) { cleanDefaults += 1; times.append(time) }
    func cleaned(_ ids: [String], at time: Date) { cleans.append(ids); times.append(time) }
}

/// The engine's own copy of the settings, changeable **after** a model already holds the
/// engine — which is what the settings window does when it saves. `FakeEngine` is a struct,
/// so without a reference here a test could only ever set the settings the model read at
/// startup, and `reloadSettings()` could not be told from doing nothing.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Settings?

    func set(_ settings: Settings) { lock.lock(); value = settings; lock.unlock() }

    var current: Settings? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Answers instantly with a pinned result. `spinsUntilCancelled` makes `clean` wait for
/// cancellation instead of returning, which is how the cancel test stays deterministic
/// without a sleep.
struct FakeEngine: CleanerEngine {
    var result: ScanResult
    var record: RunRecord
    var storedSettings: Settings
    var saveError: (any Error)?
    var spinsUntilCancelled = false
    /// When set, `clean(items:)` answers with a record of **those** items rather than the
    /// pinned one: each trashed at its own size, except the identifiers in
    /// `refusedItemIDs`, which come back `.failed` with a reason.
    ///
    /// The deck needs it. Its clean is per project, and it prunes the scan by the item
    /// identifiers the returned record names — so a fake answering with a fixed record
    /// that mentions none of them can neither prune a row nor produce a problem line, and
    /// a test of either would pass over a model that did nothing at all.
    var recordsWhatItIsHanded = false
    var refusedItemIDs: Set<String> = []
    /// Identifiers the run stood aside from rather than failed on: a booted simulator, an
    /// emulator `adb` would not talk about. The distinction matters to the deck — a skipped
    /// row is still on the disk, so it must stay in the scan and come back as a problem line
    /// the user can act on — and `.failed` alone could not tell the two apart.
    var skippedItemIDs: Set<String> = []
    /// What the run reports that is not about one row: Xcode having been open, devices
    /// removed outright. The deck shows these before its Next button, so a test needs a way
    /// to put one in a record.
    var runNotes: [String] = []
    /// Identifiers the executor could not rename on the way to the Trash — a rename the
    /// volume refused, or a sibling name the guard would not have. Those land under their
    /// own name, which is the only way a dot-folder still reaches the Trash invisible.
    var unrenamedItemIDs: Set<String> = []
    /// What `newestRunLogURL()` answers. `nil` by default, which is the machine that has
    /// never stored a run.
    var runLogURL: URL?
    let log = EngineLog()
    let settingsBox = SettingsBox()

    init(
        result: ScanResult = makeResult([]),
        record: RunRecord? = nil,
        settings: Settings? = nil
    ) {
        self.result = result
        self.record = record ?? RunRecord(
            startedAt: now, finishedAt: now.addingTimeInterval(30),
            availableBytesBefore: 100_000_000_000, availableBytesAfter: 100_060_000_000,
            entries: [])
        self.storedSettings = settings ?? .makeDefault(home: "/Users/test")
    }

    @concurrent
    func scan(now scanNow: Date, progress: @Sendable (ScanProgress) -> Void) async -> ScanResult {
        await log.scanned(at: scanNow)
        progress(ScanProgress(
            completed: 3, total: 16, currentID: "android.avds",
            currentTitle: "Android emulators"))
        if spinsUntilCancelled {
            while !Task.isCancelled { await Task.yield() }
        }
        return result
    }

    @concurrent
    func clean(
        items: [CleanupItem], now cleanNow: Date,
        progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        await log.cleaned(items.map(\.id), at: cleanNow)
        progress(ExecutionProgress(completed: 1, total: items.count, currentName: "Yarn"))
        if spinsUntilCancelled {
            while !Task.isCancelled { await Task.yield() }
        }
        guard recordsWhatItIsHanded else { return record }
        let entries = items.map { item in
            let target = item.method.path ?? item.name
            if refusedItemIDs.contains(item.id) {
                return RunEntry(
                    itemID: item.id, name: item.name, target: target,
                    sizeBytes: item.sizeBytes, outcome: .failed,
                    reason: "refused: the guard said no")
            }
            if skippedItemIDs.contains(item.id) {
                // Nothing was attempted and nothing about the item is wrong, which is what
                // the executor reports for a running simulator or an emulator it cannot ask
                // about. The row is still there afterwards.
                return RunEntry(
                    itemID: item.id, name: item.name, target: target,
                    sizeBytes: item.sizeBytes, outcome: .skipped,
                    reason: "the simulator is running; deleting one cannot be undone, "
                        + "so it was left alone")
            }
            // A row with no path is a device, and `simctl delete`, `simctl runtime delete`
            // and `avdmanager delete avd` have no Trash to use — so it lands `.deleted`
            // whatever `moveToTrash` says, exactly as the real executor reports it. A fake
            // that trashed these would let the deck's "17.3 GB deleted for good" line pass
            // while the model was counting it as recoverable.
            guard item.method.path != nil else {
                return RunEntry(
                    itemID: item.id, name: item.name, target: target,
                    sizeBytes: item.sizeBytes, outcome: .deleted)
            }
            // Where it lands, decided the way the real executor decides it: a project's
            // build folder is renamed to "<project> – <folder>" first, so the user can
            // see it in the Trash and read which project it came from. A fake that
            // landed everything under `item.name` would make the end card's
            // "these are hidden" note look right in cases where it is now wrong.
            let renamed = item.scannerID == ProjectBuildOutputScanner.scannerID
                && !unrenamedItemIDs.contains(item.id)
                ? ProjectRowPath.trashName(of: target, named: item.name)
                : nil
            let landed = renamed ?? item.name
            return RunEntry(
                itemID: item.id, name: item.name, target: target,
                sizeBytes: item.sizeBytes, outcome: .trashed,
                trashedTo: "/Users/test/.Trash/\(landed)")
        }
        return RunRecord(
            startedAt: cleanNow, finishedAt: cleanNow.addingTimeInterval(4),
            availableBytesBefore: 100_000_000_000, availableBytesAfter: 100_060_000_000,
            entries: entries, notes: runNotes)
    }

    @concurrent
    func cleanDefault(
        _ result: ScanResult, now cleanNow: Date,
        progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        await log.cleanedByDefault(at: cleanNow)
        if spinsUntilCancelled {
            while !Task.isCancelled { await Task.yield() }
        }
        return record
    }

    func settings() -> Settings { settingsBox.current ?? storedSettings }
    func save(_ settings: Settings) throws { if let saveError { throw saveError } }
    func newestRunLogURL() -> URL? { runLogURL }
}

// MARK: - opening

@MainActor
@Test func theModelOpensWithTheCachedResultAndItsAge() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a", sizeBytes: 3_000_000_000)]))

    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test",
        clock: { now.addingTimeInterval(7_200) })

    let result = try #require(model.result)
    #expect(result.items.count == 1)
    #expect(model.scanAgeText == "2h ago")
    #expect(model.phase == .idle)
}

@MainActor
@Test func theModelOpensWithNothingWhenThereIsNoCache() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(model.result == nil)
    #expect(model.scanAgeText == nil)
    #expect(!model.isBusy)
}

@MainActor
@Test func theSettingsAreReadOnceAtStartup() {
    var settings = Settings.makeDefault(home: "/Users/test")
    settings.menuBarShowsAmount = false
    let model = AppModel(
        engine: FakeEngine(settings: settings), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(!model.settings.menuBarShowsAmount)
}

// MARK: - scanning

@MainActor
@Test func theCachedResultStaysVisibleWhileAScanRuns() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "old", sizeBytes: 1_000_000_000)]))
    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "new")])),
        cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startScan())
    // Both surfaces have something to draw the instant the scan starts: spec §9.
    #expect(model.result?.items.first?.id == "old")

    #expect(await waitUntilIdle(model))
    #expect(model.result?.items.first?.id == "new")
}

@MainActor
@Test func scanProgressReachesThePhase() async throws {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    model.startScan()
    #expect(await waitUntilIdle(model))
    // The progress callback hops back to the main actor, so it can land after the scan
    // itself has returned. Waited for rather than raced: asserting straight after
    // `isBusy` clears would pass on an idle machine and fail on a busy one.
    #expect(await waitUntil { model.sawScanProgress != nil })

    #expect(model.phase == .idle)
    // Unwrapped first. `#expect(model.sawScanProgress?.total == 16)` would compare an
    // optional against a bare integer literal, which the macro types independently and
    // satisfies by erasing both sides to `AnyHashable` — false whatever the numbers, with
    // both sides printing the same digits.
    let progress = try #require(model.sawScanProgress)
    #expect(progress.currentTitle == "Android emulators")
    #expect(progress.total == 16)
}

@MainActor
@Test func aFinishedScanWritesTheCache() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "new", sizeBytes: 9)])),
        cache: cache, home: "/Users/test", clock: { now })

    model.startScan()
    #expect(await waitUntilIdle(model))

    let stored = try #require(cache.load())
    #expect(stored.items.first?.id == "new")
    #expect(model.lastCacheError == nil)
}

@MainActor
@Test func aCacheThatCannotBeWrittenIsReportedRatherThanSwallowed() async throws {
    let temp = TempDir()
    let directory = temp.url.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "a")])),
        cache: ScanCache(directory: directory), home: "/Users/test", clock: { now })

    model.startScan()
    #expect(await waitUntilIdle(model))

    #expect(model.result?.items.first?.id == "a")
    #expect(model.lastCacheError != nil)
}

@MainActor
@Test func aSecondScanIsRefusedWhileOneIsRunning() async {
    var engine = FakeEngine()
    engine.spinsUntilCancelled = false
    let model = AppModel(
        engine: engine, cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(model.startScan())
    #expect(!model.startScan())
    #expect(await waitUntilIdle(model))
    let scans = await engine.log.scans
    #expect(scans == 1)
}

/// Spec §8.3 the other way round: what a cancelled scan measured is **not** adopted and not
/// cached.
///
/// No scanner stops early today, so this is what cancelling a scan actually buys: the wait
/// still happens, the app keeps the scan it had. It matters most for the day a scanner
/// does learn to stop, when the alternative is a half-finished scan written over the good
/// cache and shown as the real thing.
@MainActor
@Test func aCancelledScanIsNeitherShownNorCached() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url.appendingPathComponent("cache"))
    try cache.save(makeResult([makeItem(id: "old")]))
    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "new")])),
        cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startScan())
    model.cancel()
    #expect(await waitUntilIdle(model))

    #expect(model.phase == .idle)
    #expect(model.result?.items.first?.id == "old")
    let stored = try #require(cache.load())
    #expect(stored.items.first?.id == "old")
}

/// A write error is about the last scan, not for ever. Without clearing it the menu bar
/// panel keeps showing "could not save" over a scan that saved perfectly well.
@MainActor
@Test func aCacheErrorGoesAwayOnceAScanIsWrittenAgain() async throws {
    let temp = TempDir()
    let directory = temp.url.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "a")])),
        cache: ScanCache(directory: directory), home: "/Users/test", clock: { now })

    model.startScan()
    #expect(await waitUntilIdle(model))
    #expect(model.lastCacheError != nil)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    model.startScan()
    #expect(await waitUntilIdle(model))

    #expect(model.lastCacheError == nil)
}

/// The engine is handed the injected clock, not the wall clock.
///
/// `ScanResult.generatedAt` comes from this value, and every "2h ago" in the app is
/// measured from it. Nothing else here can tell `clock()` from `Date()`, because the fake
/// ignores the parameter and a real `Date()` would still produce a plausible result.
@MainActor
@Test func theScanIsGivenTheInjectedClock() async {
    let engine = FakeEngine()
    let stamp = now.addingTimeInterval(-3_600)
    let model = AppModel(
        engine: engine, cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { stamp })

    model.startScan()
    #expect(await waitUntilIdle(model))

    let times = await engine.log.times
    #expect(times == [stamp])
}

// MARK: - progress reports

@MainActor
@Test func aScanReportWhileScanningReachesThePhase() async {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(model.startScan())
    let report = ScanProgress(
        completed: 9, total: 16, currentID: "flutter.pubCache", currentTitle: "Pub cache")
    model.applyScanReport(report)

    #expect(model.phase == .scanning(report))
    #expect(await waitUntilIdle(model))
}

/// A report that lands after the scan has finished is dropped.
///
/// Without this the app goes back to `.scanning` and stays there: `isBusy` never clears
/// again, so Scan again and Clean up both refuse for the rest of the session. It is not a rare
/// ordering — the engine reports from a synchronous closure off the main actor, every report
/// is bounced onto the main actor, and the last one of a scan lands beside the scan's own
/// return.
@MainActor
@Test func aScanReportThatArrivesAfterTheScanIsDropped() async {
    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "a")])),
        cache: ScanCache(directory: TempDir().url), home: "/Users/test", clock: { now })

    model.startScan()
    #expect(await waitUntilIdle(model))
    #expect(model.phase == .idle)

    model.applyScanReport(ScanProgress(
        completed: 15, total: 16, currentID: "late", currentTitle: "Late"))

    #expect(model.phase == .idle)
    #expect(!model.isBusy)
}

// MARK: - settings

@MainActor
@Test func settingsSavedElsewhereAreReadAgainOnReload() {
    let engine = FakeEngine()
    let model = AppModel(
        engine: engine, cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })
    #expect(model.settings.menuBarShowsAmount)

    var changed = Settings.makeDefault(home: "/Users/test")
    changed.menuBarShowsAmount = false
    engine.settingsBox.set(changed)
    model.reloadSettings()

    #expect(!model.settings.menuBarShowsAmount)
}

/// The settings window hands the saved value straight over, so the menu bar picks it up
/// without a rescan — and without losing the scan the window is showing.
@MainActor
@Test func appliedSettingsReplaceTheOldOnesAndKeepTheScan() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    var changed = Settings.makeDefault(home: "/Users/test")
    changed.menuBarShowsAmount = false
    model.apply(changed)

    #expect(!model.settings.menuBarShowsAmount)
    #expect(model.result?.items.first?.id == "a")
}
