import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

@Test func aCacheRoundTripsAScanResult() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let result = makeResult([makeItem(id: "a", sizeBytes: 3_000_000_000)])

    try cache.save(result)

    let loaded = try #require(cache.load())
    #expect(loaded.items.count == 1)
    #expect(loaded.generatedAt == now)
    let bytes: Int64 = loaded.reclaimableBytes
    #expect(bytes == 3_000_000_000)
}

@Test func aMissingCacheLoadsAsNilRatherThanThrowing() {
    let temp = TempDir()
    #expect(ScanCache(directory: temp.url).load() == nil)
}

@Test func aCorruptCacheLoadsAsNilRatherThanThrowing() {
    let temp = TempDir()
    temp.write("cache.json", "{ this is not json")
    #expect(ScanCache(directory: temp.url).load() == nil)
}

/// The fourth candidate for the bug this project hit three times. `ScanResult
/// .init(from:)` already reads every soft key with `decodeIfPresent`; this asserts the
/// cache does not undo that by demanding a shape of its own.
@Test func aCachedScanMissingTheNewestFieldStillLoads() throws {
    let temp = TempDir()
    temp.write("cache.json", """
        {"generatedAt":"2026-08-10T09:00:00Z","items":[],"availableBytes":5}
        """)

    let loaded = try #require(ScanCache(directory: temp.url).load())
    #expect(loaded.ignoredProjectRoots.isEmpty)
    #expect(loaded.skippedScannerIDs.isEmpty)
    let bytes: Int64 = loaded.availableBytes
    #expect(bytes == 5)
}

/// A failed write must not take the previous cache with it. The write is atomic, so the
/// old file is either replaced whole or left alone; this pins the "left alone" half by
/// making the directory unwritable.
@Test func aFailedWriteLeavesTheGoodCacheInPlace() throws {
    let temp = TempDir()
    let directory = temp.url.appendingPathComponent("cache")
    let cache = ScanCache(directory: directory)
    try cache.save(makeResult([makeItem(id: "good", sizeBytes: 7_000_000_000)]))

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    #expect(throws: (any Error).self) {
        try cache.save(makeResult([makeItem(id: "new", sizeBytes: 1)]))
    }

    let loaded = try #require(cache.load())
    let bytes: Int64 = loaded.reclaimableBytes
    #expect(bytes == 7_000_000_000)
}

/// A clean makes the stored scan false, so the clean throws it away. Kept, it is read back
/// on the very next launch and drawn as the current state of the disk — instantly, at the
/// sizes the caches were before the run.
@Test func aDiscardedCacheIsGoneFromDiskAndFromTheNextLaunch() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a", sizeBytes: 3_000_000_000)]))
    #expect(cache.load() != nil)

    try cache.discard()

    #expect(cache.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.url.path))
}

/// A cache that is not there is already discarded. The machine that has never scanned
/// reaches this the first time a clean is run, and throwing there would report a failure
/// that is not one.
@Test func discardingACacheThatIsNotThereIsNotAFailure() throws {
    let temp = TempDir()
    try ScanCache(directory: temp.url).discard()
}

/// Anything else does throw, for the same reason a failed write does: a stale cache the app
/// could not delete is exactly the failure the delete exists to prevent, and swallowing it
/// leaves nothing on screen to say the next launch will lie.
@Test func aDiscardThatCannotRemoveTheFileThrows() throws {
    let temp = TempDir()
    let directory = temp.url.appendingPathComponent("cache")
    let cache = ScanCache(directory: directory)
    try cache.save(makeResult([makeItem(id: "a", sizeBytes: 7_000_000_000)]))

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    #expect(throws: (any Error).self) { try cache.discard() }
}

@Test func theCacheLivesBesideTheSettingsAndTheRunLog() {
    #expect(ScanCache.defaultDirectory() == SettingsStore.defaultDirectory())
    #expect(ScanCache(directory: ScanCache.defaultDirectory()).url.lastPathComponent
        == "cache.json")
}

/// The witness the two tests below rely on, checked before they rely on it.
///
/// It has to remember **any** main-thread callback, not the last one. The failure those
/// tests exist to catch is a ~29-second synchronous prefix on the main thread; a scan then
/// keeps firing progress from the concurrent pool afterwards, and a witness that overwrites
/// on every callback ends up holding `false` and reporting a clean run. Nothing about the
/// real engine makes that sequence visible today — which is the point: the sequence is what
/// the bug looks like, so the witness is checked directly rather than through it.
@Test func theThreadWitnessRemembersAMainThreadCallbackEvenWhenLaterOnesAreNot() async throws {
    let witness = ThreadWitness()
    await MainActor.run { witness.note() }
    // Detached, so it runs on the concurrent pool and never on the main thread. This is the
    // callback that used to overwrite the one above.
    await Task.detached { witness.note() }.value

    let everRanOnMainThread = try #require(witness.everRanOnMainThread as Bool?)
    #expect(everRanOnMainThread)
}

/// A witness nobody notified says so, rather than saying the run was clean. `false` and
/// `nil` are different answers and `theLiveEngineScansOffTheMainThread` distinguishes them.
@Test func aThreadWitnessThatWasNeverNotifiedReportsNothingRatherThanFalse() {
    #expect(ThreadWitness().everRanOnMainThread == nil)
}

/// Spec §9 and the handoff's performance note. Under the Swift 7 default a nonisolated
/// async function inherits the caller's isolation, and `CleanerService.scan` would then
/// run a ~29-second synchronous prefix on the main thread with a card on screen over
/// it. `@concurrent` on the `CleanerEngine` requirements is what stops that, and this is
/// the test that fails if somebody removes it.
@MainActor
@Test func theLiveEngineScansOffTheMainThread() async throws {
    let temp = TempDir()
    let witness = ThreadWitness()
    let engine = makeLiveEngine(temp: temp)

    let result = await engine.scan(now: now) { _ in witness.note() }

    #expect(result.generatedAt == now)
    // Two separate questions, and both have to be asked. `nil` means the progress callback
    // never ran, so there is no evidence either way; `false` means it ran and never on the
    // main thread, which is the thing being claimed. Passing the `Bool?` straight to
    // `#require` is ambiguous between unwrapping it and asserting the wrapped value, which
    // is what the warning here was — `as Bool?` says unwrap.
    let ranOnMainThread = try #require(witness.everRanOnMainThread as Bool?)
    #expect(!ranOnMainThread)
}

@MainActor
@Test func theLiveEngineCleansOffTheMainThread() async throws {
    let temp = TempDir()
    let witness = ThreadWitness()
    let engine = makeLiveEngine(temp: temp)
    let item = makeItem(id: "a", method: .removePath(temp.makeDirectory("Library/Caches/Yarn")))

    let record = await engine.clean(items: [item], now: now) { _ in witness.note() }

    #expect(record.entries.count == 1)
    // As above: unwrap first — `nil` would mean no progress callback ever arrived.
    let ranOnMainThread = try #require(witness.everRanOnMainThread as Bool?)
    #expect(!ranOnMainThread)
}

/// The tick rule, at the app boundary. `cleanDefault` must forward the whole `ScanResult`
/// to the service and let `defaultSelection` decide — never re-derive the list here and
/// never hand over `items`. An unticked row that reaches the executor is the Android NDK
/// case: 5.57 GB deleted, and only a network download brings it back.
@Test func theLiveEngineCleanDefaultLeavesAnUntickedRowAlone() async throws {
    let temp = TempDir()
    let engine = makeLiveEngine(temp: temp)
    let ticked = makeItem(
        id: "ticked", name: "Yarn",
        method: .removePath(temp.makeDirectory("Library/Caches/Yarn")))
    let unticked = makeItem(
        id: "unticked", name: "NDK",
        method: .removePath(temp.makeDirectory("Library/Caches/NDK")), startsUnticked: true)

    let record = await engine.cleanDefault(makeResult([ticked, unticked]), now: now) { _ in }

    let entry = try #require(record.entries.first)
    #expect(record.entries.count == 1)
    #expect(entry.name == "Yarn")
}

/// The "open the run log" link has nothing to open until a run has been stored, and the
/// service does not hand back where it wrote. `nil` first, then the file the run produced.
@Test func theNewestRunLogURLAppearsOnlyAfterARunIsStored() async throws {
    let temp = TempDir()
    let engine = makeLiveEngine(temp: temp)
    #expect(engine.newestRunLogURL() == nil)

    let item = makeItem(
        id: "a", method: .removePath(temp.makeDirectory("Library/Caches/Yarn")))
    _ = await engine.clean(items: [item], now: now) { _ in }

    let url = try #require(engine.newestRunLogURL())
    #expect(url.deletingLastPathComponent().lastPathComponent == "runs")
    #expect(url.pathExtension == "json")
}

@Test func theLiveEngineReadsAndWritesSettingsThroughTheService() throws {
    let temp = TempDir()
    let engine = makeLiveEngine(temp: temp)

    var settings = engine.settings()
    settings.activeThresholdDays = 21
    try engine.save(settings)

    #expect(engine.settings().activeThresholdDays == 21)
}

@Test func theLiveEngineRefusesAProjectRootThatIsTooWide() {
    let temp = TempDir()
    let engine = makeLiveEngine(temp: temp)
    var settings = engine.settings()
    settings.projectRoots = ["/"]

    #expect(throws: SettingsError.projectRootTooWide("/")) {
        try engine.save(settings)
    }
}
