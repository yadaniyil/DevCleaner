import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

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
        return record
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

/// Spins until `condition` holds and gives up after five seconds, answering whether it held.
///
/// Bounded, and the answer asserted at every call site. swift-testing has no per-test time
/// limit here, so an unbounded `while … { await Task.yield() }` over a condition that never
/// comes true stalls the **whole** run: no failure message, no test named, and every other
/// test loses its result. That is the same reason this package bans `[0]` subscripting.
/// Five seconds is far more than any of these tests needs — every wait here is on a fake
/// that answers immediately — and short enough that a wedged test still reports.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
    }
    return true
}

/// The same five-second bound, for a condition that has to `await` — an actor's state, say.
///
/// A separate name rather than an overload: `waitUntil { … }` with a body that happens to be
/// async would bind to whichever overload the compiler picked, and picking the synchronous
/// one silently drops the wait.
@MainActor
private func waitUntilAwaiting(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
    }
    return true
}

@MainActor
private func waitUntilIdle(_ model: AppModel) async -> Bool {
    await waitUntil { !model.isBusy }
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
    #expect(model.selection?.isTicked("a") == true)
}

/// The header is built here, against the model's own clock, so `DevCleanerApp` never holds
/// a second one. A view calling `Date()` renders an age no test can pin, and it can differ
/// from `scanAgeText` on the same screen.
@MainActor
@Test func theHeaderIsBuiltFromTheResultAndTheModelsOwnClock() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult(
        [makeItem(id: "a", sizeBytes: 3_000_000_000)],
        ignoredRoots: ["/Users/test/work"]))

    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test",
        clock: { now.addingTimeInterval(7_200) })

    let header = try #require(model.header)
    #expect(header.amountText == "3.0 GB")
    // Two hours after the scan, because the injected clock says so. The wall clock would
    // put this days out and climbing.
    #expect(header.scanAgeText == "scanned 2h ago")
    // The model's own home, too, not just its clock: the header abbreviates paths against
    // it, and a header built with the wrong one prints `/Users/test/work` at the user.
    #expect(header.problems == ["Ignored, too wide to be a project root: ~/work"])
}

@MainActor
@Test func thereIsNoHeaderBeforeTheFirstScan() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(model.header == nil)
}

@MainActor
@Test func theModelOpensWithNothingWhenThereIsNoCache() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(model.result == nil)
    #expect(model.selection == nil)
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
    // The popover has something to draw the instant the scan starts: spec §9.
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

/// Spec §8.3: tick state is not persisted between scans.
@MainActor
@Test func aFreshScanRebuildsTheTicksRatherThanKeepingThem() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let model = AppModel(
        engine: FakeEngine(result: makeResult([makeItem(id: "a")])),
        cache: cache, home: "/Users/test", clock: { now })

    model.setTicked(false, for: "a")
    #expect(model.selection?.isTicked("a") == false)

    model.startScan()
    #expect(await waitUntilIdle(model))

    #expect(model.selection?.isTicked("a") == true)
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
/// still happens, the popover keeps the scan it had. It matters most for the day a scanner
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

/// A write error is about the last scan, not for ever. Without clearing it the popover
/// keeps showing "could not save" over a scan that saved perfectly well.
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
/// `ScanResult.generatedAt` comes from this value, and every "2h ago" in the popover is
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

// MARK: - cleaning

@MainActor
@Test func anUnchangedSelectionCleansThroughCleanDefault() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let engine = FakeEngine(result: makeResult([makeItem(id: "a")]))
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))

    let defaults = await engine.log.cleanDefaults
    let explicit = await engine.log.cleans
    #expect(defaults == 1)
    #expect(explicit.isEmpty)
}

@MainActor
@Test func aChangedSelectionCleansExactlyWhatIsTicked() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a"), makeItem(id: "b")]))
    let engine = FakeEngine()
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    model.setTicked(false, for: "b")
    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))

    let defaults = await engine.log.cleanDefaults
    let explicit = await engine.log.cleans
    #expect(defaults == 0)
    #expect(explicit == [["a"]])
}

@MainActor
@Test func cleanIsRefusedWhenNothingIsTicked() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let engine = FakeEngine()
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    model.setTicked(false, for: "a")
    #expect(!model.startClean(from: .popover))
    #expect(model.phase == .idle)
    let defaults = await engine.log.cleanDefaults
    #expect(defaults == 0)
}

@MainActor
@Test func cleanIsRefusedWhenThereIsNoScanAtAll() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(!model.startClean(from: .popover))
}

@MainActor
@Test func aFinishedRunCarriesItsRecord() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let record = RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(9),
        availableBytesBefore: 1, availableBytesAfter: 2, entries: [])
    let model = AppModel(
        engine: FakeEngine(record: record), cache: cache,
        home: "/Users/test", clock: { now })

    model.startClean(from: .popover)
    #expect(await waitUntilIdle(model))

    #expect(model.lastRun == record)
    // Not a phase. The run is over and the app is free to scan again — which is exactly what
    // it does next — while the panel stays on screen until the user puts it away.
    #expect(model.phase == .idle)
    model.dismissSummary()
    #expect(model.lastRun == nil)
    #expect(model.summary == nil)
}

/// The run is given the injected clock too. `RunRecord.startedAt` is this value, and it is
/// what the stored run log is named after.
@MainActor
@Test func theCleanIsGivenTheInjectedClock() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let engine = FakeEngine()
    let stamp = now.addingTimeInterval(90)
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { stamp })

    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))

    let times = await engine.log.times
    #expect(times == [stamp])
}

/// A second clean is refused while one is running, exactly as a second scan is.
///
/// `work` is one slot. A second run would overwrite the first run's handle, `cancel()` would
/// then reach only the second, and the first would carry on deleting with nothing left that
/// could stop it.
@MainActor
@Test func aSecondCleanIsRefusedWhileOneIsRunning() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    #expect(!model.startClean(from: .popover))
    model.cancel()
    #expect(await waitUntilIdle(model))

    let defaults = await engine.log.cleanDefaults
    #expect(defaults == 1)
}

/// Spec §8.2: cancelling stops before the next item. The fake spins until its task is
/// cancelled, so this pins that `cancel()` really cancels the task the run is on —
/// which is what makes `Executor`'s per-item check fire.
@MainActor
@Test func cancellingStopsTheRun() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    #expect(model.isBusy)
    model.cancel()
    #expect(await waitUntilIdle(model))

    #expect(!model.isBusy)
}

/// Spec §8.2: what a cancelled run already removed stays removed — so the popover has to
/// show the summary for it, exactly as it does for a run that finished.
///
/// `cancellingStopsTheRun` cannot pin this on its own: it asserts `!isBusy`, and a `cancel()`
/// that sets `phase = .idle` and throws the record away satisfies that while leaving the user
/// with 6 GB in their Trash and no list of what is in it.
@MainActor
@Test func aCancelledRunStillEndsInItsSummary() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let record = RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(4),
        availableBytesBefore: 7, availableBytesAfter: 8,
        entries: [], notes: [Executor.Note.runWasCancelled])
    var engine = FakeEngine(record: record)
    engine.spinsUntilCancelled = true
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    model.cancel()
    #expect(await waitUntilIdle(model))

    #expect(model.lastRun == record)
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
/// Without this the popover goes back to `.scanning` and stays there: `isBusy` never clears
/// again, so Scan and Clean both refuse for the rest of the session. It is not a rare
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

/// The same for a run: the executor's last per-item report lands beside the run's return.
/// Dropping it is what stops the popover being stuck on "Cleaning…" over a run that is
/// already finished, with its summary never shown.
@MainActor
@Test func aRunReportThatArrivesAfterTheRunIsDropped() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let record = RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(5),
        availableBytesBefore: 3, availableBytesAfter: 4, entries: [])
    let model = AppModel(
        engine: FakeEngine(record: record), cache: cache,
        home: "/Users/test", clock: { now })

    model.startClean(from: .popover)
    #expect(await waitUntilIdle(model))
    #expect(model.lastRun == record)
    #expect(model.phase == .idle)

    model.applyRunReport(ExecutionProgress(completed: 1, total: 1, currentName: "Late"))

    #expect(model.phase == .idle)
    #expect(model.lastRun == record)
}

/// End to end: what the engine reports during a run is what the popover shows.
///
/// The fake reports once and then spins until it is cancelled, so this waits for the state
/// rather than racing it. A `startClean` that hands the engine a closure going nowhere
/// leaves this waiting forever, which is the failure.
@MainActor
@Test func theRunPhaseCarriesWhatTheEngineReports() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a"), makeItem(id: "b")]))
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })

    // Unticked, so the run goes through `clean(items:)` — the fake's `cleanDefault` reports
    // nothing, because the engine derives that list itself.
    model.setTicked(false, for: "b")
    #expect(model.startClean(from: .popover))
    let expected = ExecutionProgress(completed: 1, total: 1, currentName: "Yarn")
    #expect(await waitUntil { model.phase == .running(expected) })

    model.cancel()
    #expect(await waitUntilIdle(model))
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

/// The settings window hands the saved value straight over, so the popover picks it up
/// without a rescan — and without losing the scan it is showing.
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

// MARK: - the rest of the surface

@MainActor
@Test func groupsExpandAndCollapse() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })

    #expect(model.expandedGroups.isEmpty)
    model.toggleExpanded(.android)
    #expect(model.expandedGroups == [.android])
    model.toggleExpanded(.android)
    #expect(model.expandedGroups.isEmpty)
}

@MainActor
@Test func aGroupToggleReachesTheSelection() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([
        makeItem(id: "a", group: .android), makeItem(id: "b", group: .android),
    ]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    model.setGroup(.android, ticked: false)
    #expect(model.selection?.tick(of: .android) == GroupTick.none)
}

// MARK: - the run summary

/// The summary belongs to `.finished` and to nothing else, and its link comes from the
/// engine rather than from the record — `RunRecord` does not carry where it was written.
@MainActor
@Test func theSummaryIsAvailableOnlyAfterARun() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let logURL = URL(fileURLWithPath: "/tmp/runs/20260810-090000.json")
    var engine = FakeEngine(record: RunRecord(
        startedAt: now, finishedAt: now, availableBytesBefore: 0,
        availableBytesAfter: 60_000_000,
        entries: [RunEntry(itemID: "a", name: "Yarn", target: "/tmp/a",
                           sizeBytes: 3_000_000_000, outcome: .trashed,
                           trashedTo: "/Users/test/.Trash/a")]))
    engine.runLogURL = logURL
    let model = AppModel(
        engine: engine, cache: cache, home: "/Users/test", clock: { now })

    #expect(model.summary == nil)
    model.startClean(from: .popover)
    #expect(await waitUntilIdle(model))

    let summary = try #require(model.summary)
    #expect(summary.trashedText.contains("3.0 GB"))
    #expect(summary.freeSpaceText.contains("60 MB"))
    #expect(summary.logURL == logURL)

    // Dismissing clears the record, so the panel has nothing left to draw.
    model.dismissSummary()
    #expect(model.summary == nil)
}

// MARK: - what a finished run invalidates

/// Everything the popover shows was measured **before** the run, so none of it may survive
/// one.
///
/// A 58.0 GB scan, cleaned. Left standing, the menu bar keeps saying 58.0 GB, the header
/// keeps offering it "up to 58.0 GB" with a free-space figure from before the clean and
/// "scanned 6m ago" claiming the measurement is newer than the run, and the Clean button
/// offers to remove it all again. Every one of those numbers is false, and nothing corrects
/// them for up to a whole background interval — six hours by default — because a clean does
/// not touch `lastFinishedAt`.
@MainActor
@Test func aFinishedRunDropsTheScanItJustMadeFalse() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "before", sizeBytes: 58_000_000_000)]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })
    #expect(model.header?.amountText == "58.0 GB")
    #expect(MenuBarLabel.text(selection: model.selection, showsAmount: true) == "58.0 GB")

    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))

    #expect(model.result == nil)
    #expect(model.selection == nil)
    #expect(model.header == nil)
    #expect(model.scanAgeText == nil)
    #expect(MenuBarLabel.text(selection: model.selection, showsAmount: true) == nil)
    #expect(PopoverBodyModel.groups(from: model).isEmpty)
    // Nothing left to press Clean over, so the button cannot be enabled above dropped data.
    #expect(!FooterModel(selection: model.selection, moveToTrash: true).isCleanEnabled)
    #expect(!model.startClean(from: .popover))
    // …and what the run did is still on screen.
    #expect(model.summary != nil)
}

/// The stored scan goes with it, or the next launch reads it back and presents the caches
/// this run removed as the current state of the disk — instantly, and with an age that only
/// grows.
@MainActor
@Test func aFinishedRunThrowsAwayTheStoredScanAsWell() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "before", sizeBytes: 58_000_000_000)]))
    #expect(cache.load() != nil)
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))

    #expect(cache.load() == nil)
    #expect(model.lastCacheError == nil)
    // The next launch, as the app would do it.
    let relaunched = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })
    #expect(relaunched.result == nil)
    #expect(relaunched.header == nil)
}

/// A cache that could not be deleted is reported rather than swallowed, for the same reason
/// a cache that could not be written is: a stale cache the app kept is exactly the failure
/// the deletion exists to prevent, and nothing else on screen would say the next launch is
/// about to lie.
@MainActor
@Test func aStoredScanThatCannotBeDeletedIsReported() async throws {
    let temp = TempDir()
    let directory = temp.url.appendingPathComponent("locked")
    let cache = ScanCache(directory: directory)
    try cache.save(makeResult([makeItem(id: "before", sizeBytes: 58_000_000_000)]))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))

    #expect(model.lastCacheError != nil)
    // The scan is dropped from the app whether or not the file could be removed. Keeping it
    // on screen because the delete failed would show the pre-clean numbers as current.
    #expect(model.result == nil)
    #expect(model.summary != nil)
}

/// A run ends by asking for a fresh scan, and it asks **through the loop**.
///
/// `AppModel.startScan()` would scan without the scheduler ever hearing about it, leaving
/// `lastFinishedAt` where it was: the background interval then falls due a moment later and
/// a second full ~51-second scan starts on top of the one that has just run. The countdown
/// asserted below is what tells the two apart.
@MainActor
@Test func aFinishedRunAsksTheLoopForAFreshScan() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "before", sizeBytes: 58_000_000_000)]))
    let engine = FakeEngine(
        result: makeResult([makeItem(id: "after", sizeBytes: 2_000_000_000)]))
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })
    let clock = MovableClock()
    let scheduler = ScanScheduler(intervalHours: 6)
    // Building the loop is what wires it to the model. Its forever-loop is never run here;
    // the only thing under test is the scan the model asks for by itself.
    let loop = BackgroundScanLoop(
        model: model, scheduler: scheduler, sleeper: FakeSleeper(clock: clock),
        clock: clock.read)

    // Waited for the **new** scan, not merely for a non-nil result: the cached one is
    // already there when the clean starts, so `result != nil` is true from the first check
    // and would race straight past everything under test.
    #expect(model.startClean(from: .popover))
    #expect(await waitUntil { model.result?.items.first?.id == "after" })

    #expect(model.result?.items.first?.id == "after")
    #expect(model.header?.amountText == "2.0 GB")
    let scans = await engine.log.scans
    #expect(scans == 1)
    // The rescan went through the scheduler, so the background interval is a full six hours
    // away rather than due immediately. This is the only assertion that tells a rescan
    // through the loop apart from a bare `startScan()`: a bare call never touches the
    // scheduler, leaving `isRunning` false and `lastFinishedAt` nil, so `secondsUntilDue`
    // stays 0, the wait below burns its whole bound, and both #expects fail.
    //
    // Be precise about what the wait observes, because the obvious reading is wrong: it is
    // satisfied by `isRunning`, which `rescan()` sets *before* the scan starts, not by
    // `finished(at:)` afterwards. With the clock frozen both states answer 21600 anyway
    // (`ScanScheduler.secondsUntilDue` returns the whole interval while running, and elapsed
    // is 0 right after a finish), so this assertion cannot distinguish "countdown restarted"
    // from "wedged mid-scan with `isRunning` stuck true". Do not copy this as a way to wait
    // for a scan to finish. Bounded at five seconds and the bound asserted, like every other
    // wait in this file.
    #expect(await waitUntilAwaiting {
        await scheduler.secondsUntilDue(now: clock.current) > 0
    })
    let due = await scheduler.secondsUntilDue(now: clock.current)
    #expect(due == 6 * 3_600)
    withExtendedLifetime(loop) {}
}

/// The summary stays readable while that scan runs underneath it, and is still there when
/// the scan lands — and putting it away does not bring the pre-clean numbers back.
@MainActor
@Test func theSummarySurvivesTheScanTheRunAskedForAndDismissingItRestoresNothing() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "before", sizeBytes: 58_000_000_000)]))
    let record = RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(300),
        availableBytesBefore: 100_000_000_000, availableBytesAfter: 140_200_000_000,
        entries: [RunEntry(itemID: "before", name: "DerivedData", target: "/tmp/before",
                           sizeBytes: 40_200_000_000, outcome: .trashed,
                           trashedTo: "/Users/test/.Trash/before")])
    let engine = FakeEngine(
        result: makeResult([makeItem(id: "after", sizeBytes: 2_000_000_000)]), record: record)
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })
    let clock = MovableClock()
    let loop = BackgroundScanLoop(
        model: model, scheduler: ScanScheduler(intervalHours: 6),
        sleeper: FakeSleeper(clock: clock), clock: clock.read)

    // Waited for the **new** scan, not merely for a non-nil result: the cached one is
    // already there when the clean starts, so `result != nil` is true from the first check
    // and would race straight past everything under test.
    #expect(model.startClean(from: .popover))
    #expect(await waitUntil { model.result?.items.first?.id == "after" })

    // The scan has landed and the panel is still the one the user was reading.
    let summary = try #require(model.summary)
    #expect(summary.trashedText == "40.2 GB moved to the Trash (1 item)")
    // The hundred rows of the new scan do not push in above the Done button.
    #expect(!model.showsGroupList)

    model.dismissSummary()

    #expect(model.summary == nil)
    // 2.0 GB, the scan taken after the run. Never 58.0 GB, which is what `dismissSummary`
    // would be putting back if it restored anything at all.
    #expect(model.header?.amountText == "2.0 GB")
    #expect(model.showsGroupList)
    withExtendedLifetime(loop) {}
}

/// The summary belongs to the run the user watched, not to the rest of the session.
///
/// Done is not the only way out of the popover. Closing it and reopening twelve hours and two
/// background scans later must not show yesterday's summary — still hiding the group list, and
/// putting that run's free-space figure beside a fresh and different one in the header.
@MainActor
@Test func closingThePopoverPutsTheRunSummaryAwayAndLeavesTheScanAlone() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "before", sizeBytes: 58_000_000_000)]))
    let engine = FakeEngine(
        result: makeResult([makeItem(id: "after", sizeBytes: 2_000_000_000)]))
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })
    let clock = MovableClock()
    let loop = BackgroundScanLoop(
        model: model, scheduler: ScanScheduler(intervalHours: 6),
        sleeper: FakeSleeper(clock: clock), clock: clock.read)

    #expect(model.startClean(from: .popover))
    #expect(await waitUntil { model.result?.items.first?.id == "after" })
    #expect(model.summary != nil)
    #expect(!model.showsGroupList)

    // The user closes the popover without pressing Done.
    model.surfaceClosed(.popover)

    #expect(model.summary == nil)
    #expect(model.lastRun == nil)
    // The scan the run asked for is untouched, so reopening shows the current numbers and the
    // list — not an empty popover.
    #expect(model.result?.items.first?.id == "after")
    #expect(model.header?.amountText == "2.0 GB")
    #expect(model.showsGroupList)
    withExtendedLifetime(loop) {}
}

/// Closing a popover that has no summary in it changes nothing. The event arrives on every
/// close, including the ones where no run has happened at all.
@MainActor
@Test func closingThePopoverWithNoSummaryLeavesEverythingWhereItWas() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a", sizeBytes: 3_000_000_000)]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    model.surfaceClosed(.popover)

    #expect(model.result?.items.first?.id == "a")
    #expect(model.selection?.isTicked("a") == true)
    #expect(model.showsGroupList)
    #expect(model.phase == .idle)
}

/// The summary belongs to the surface the run was watched on, and only that surface's close
/// puts it away.
///
/// Two surfaces share this one model, and both close through the same event. With one shared
/// clearing rule, dismissing the menu-bar popover — which happens on every stray click of the
/// desktop — wiped the summary out of the main window the user was still reading. A run
/// confirmed on the main window therefore survives any number of popover closes, and goes
/// away when its own window does.
@MainActor
@Test func closingThePopoverLeavesTheMainWindowsSummaryAlone() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let record = RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(9),
        availableBytesBefore: 1, availableBytesAfter: 2, entries: [])
    let model = AppModel(
        engine: FakeEngine(record: record), cache: cache,
        home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .mainWindow))
    #expect(await waitUntilIdle(model))
    #expect(model.lastRun == record)
    #expect(model.lastRunSurface == .mainWindow)

    // The popover closes — a close, but not of the surface this summary belongs to.
    model.surfaceClosed(.popover)
    #expect(model.lastRun == record)
    #expect(model.summary != nil)

    // The window the run was watched on closes, and the summary goes with it.
    model.surfaceClosed(.mainWindow)
    #expect(model.lastRun == nil)
    #expect(model.summary == nil)
}

/// The same rule with the surfaces swapped: closing the main window must not reach into the
/// popover and take away the summary of a run confirmed there.
@MainActor
@Test func closingTheMainWindowLeavesThePopoversSummaryAlone() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let record = RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(9),
        availableBytesBefore: 1, availableBytesAfter: 2, entries: [])
    let model = AppModel(
        engine: FakeEngine(record: record), cache: cache,
        home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .popover))
    #expect(await waitUntilIdle(model))
    #expect(model.lastRunSurface == .popover)

    model.surfaceClosed(.mainWindow)
    #expect(model.lastRun == record)
    #expect(model.summary != nil)

    model.surfaceClosed(.popover)
    #expect(model.lastRun == nil)
    #expect(model.summary == nil)
}

/// Done is stronger than a close: it is the user putting the panel away by hand, and it works
/// from whichever surface it is pressed on — including the one that did not run the clean.
/// It clears the ownership with the record, so a later close of the owning surface has
/// nothing left to act on.
@MainActor
@Test func dismissSummaryClearsTheSummaryFromEitherSurface() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    #expect(model.startClean(from: .mainWindow))
    #expect(await waitUntilIdle(model))
    #expect(model.lastRunSurface == .mainWindow)

    // Done, pressed on the popover's copy of the panel.
    model.dismissSummary()

    #expect(model.lastRun == nil)
    #expect(model.lastRunSurface == nil)
}

/// The group list is not on screen while the app is measuring, so a scan cannot leave a
/// stale list under a progress line that says the numbers are being replaced.
@MainActor
@Test func theGroupListIsPutAwayWhileAScanRuns() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a")]))
    var engine = FakeEngine(result: makeResult([makeItem(id: "a")]))
    engine.spinsUntilCancelled = true
    let model = AppModel(engine: engine, cache: cache, home: "/Users/test", clock: { now })
    #expect(model.showsGroupList)

    #expect(model.startScan())
    #expect(!model.showsGroupList)

    model.cancel()
    #expect(await waitUntilIdle(model))
    #expect(model.showsGroupList)
}
