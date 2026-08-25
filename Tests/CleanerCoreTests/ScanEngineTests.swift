import Testing
import Foundation
@testable import CleanerCore

private struct StubScanner: CleanupScanner {
    let id: String
    let group: GroupID
    let title: String
    let items: [CleanupItem]
    func scan(_ context: ScanContext) async -> [CleanupItem] { items }
}

/// Counts how many times each scanner was actually entered.
///
/// An actor, not an `NSLock`: on Swift 6.3.3 `NSLock.lock()` is unavailable from
/// an asynchronous context, and `CleanupScanner.scan` is `async`.
private actor RunCounter {
    private var counts: [String: Int] = [:]
    func record(_ id: String) { counts[id, default: 0] += 1 }
    func count(_ id: String) -> Int { counts[id] ?? 0 }
}

/// Reports being run, so a test can tell "the engine skipped me" apart from
/// "the engine ran me and then threw my items away".
private struct RecordingScanner: CleanupScanner {
    let id: String
    let group: GroupID
    let title: String
    let counter: RunCounter

    func scan(_ context: ScanContext) async -> [CleanupItem] {
        await counter.record(id)
        return [makeItem(id, scanner: id, group: group, size: 1_000)]
    }
}

private func makeItem(_ id: String, scanner: String, group: GroupID,
                      size: Int64, protection: ProtectionReason? = nil) -> CleanupItem {
    CleanupItem(id: id, scannerID: scanner, group: group, name: id, detail: nil,
                sizeBytes: size, lastUsed: nil, risk: .safe, protection: protection,
                method: .removePath("/tmp/\(id)"))
}

private func makeContext(settings: Settings = .makeDefault(home: "/Users/tester")) -> ScanContext {
    ScanContext(
        settings: settings, protection: .empty, projects: [], devices: .empty,
        home: "/Users/tester", androidSDKPath: "/Users/tester/Library/Android/sdk",
        sizeMeasurer: FixedSizeMeasurer([:]), runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: Date(timeIntervalSince1970: 1_786_000_000))
}

@Test func engineCollectsItemsFromEveryScanner() async {
    let engine = ScanEngine(scanners: [
        StubScanner(id: "xcode.derivedData", group: .xcodeAndIOS, title: "DerivedData",
                    items: [makeItem("a", scanner: "xcode.derivedData", group: .xcodeAndIOS, size: 100)]),
        StubScanner(id: "android.gradle", group: .android, title: "Gradle",
                    items: [makeItem("b", scanner: "android.gradle", group: .android, size: 200)]),
    ])
    let result = await engine.scan(context: makeContext())
    #expect(result.items.count == 2)
    #expect(result.reclaimableBytes == 300)
}

@Test func reclaimableTotalExcludesProtectedItems() async {
    let engine = ScanEngine(scanners: [
        StubScanner(id: "ios.simulators", group: .xcodeAndIOS, title: "Simulators", items: [
            makeItem("keep", scanner: "ios.simulators", group: .xcodeAndIOS, size: 1_000,
                     protection: .mostRecentlyUsedDevice),
            makeItem("drop", scanner: "ios.simulators", group: .xcodeAndIOS, size: 500),
        ]),
    ])
    let result = await engine.scan(context: makeContext())
    #expect(result.reclaimableBytes == 500)
}

@Test func skippedScannersAreNotRunAndAreReported() async {
    var settings = Settings.makeDefault(home: "/Users/tester")
    settings.alwaysSkipScannerIDs = ["flutter.pubCache"]

    let engine = ScanEngine(scanners: [
        StubScanner(id: "flutter.pubCache", group: .flutterAndDart, title: "pub-cache",
                    items: [makeItem("pub", scanner: "flutter.pubCache", group: .flutterAndDart, size: 8_000)]),
        StubScanner(id: "flutter.fvm", group: .flutterAndDart, title: "fvm",
                    items: [makeItem("fvm", scanner: "flutter.fvm", group: .flutterAndDart, size: 2_000)]),
    ])
    let result = await engine.scan(context: makeContext(settings: settings))
    #expect(result.items.map(\.id) == ["fvm"])
    #expect(result.skippedScannerIDs == ["flutter.pubCache"])
    #expect(result.reclaimableBytes == 2_000)
}

@Test func itemsCanBeFetchedPerGroup() async {
    let engine = ScanEngine(scanners: [
        StubScanner(id: "xcode.archives", group: .xcodeAndIOS, title: "Archives",
                    items: [makeItem("x", scanner: "xcode.archives", group: .xcodeAndIOS, size: 1)]),
        StubScanner(id: "android.avds", group: .android, title: "AVDs",
                    items: [makeItem("y", scanner: "android.avds", group: .android, size: 2)]),
    ])
    let result = await engine.scan(context: makeContext())
    #expect(result.items(in: .android).map(\.id) == ["y"])
    #expect(result.items(in: .projects).isEmpty)
}

@Test func scanResultSurvivesJSONRoundTripForCaching() async throws {
    let engine = ScanEngine(scanners: [
        StubScanner(id: "xcode.archives", group: .xcodeAndIOS, title: "Archives",
                    items: [makeItem("x", scanner: "xcode.archives", group: .xcodeAndIOS, size: 42,
                                     protection: .recentActivity(days: 14))]),
    ])
    let result = await engine.scan(context: makeContext())
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(ScanResult.self, from: data)
    // Whole-value equality, so this also covers generatedAt, availableBytes and
    // skippedScannerIDs surviving. generatedAt is what decides cache staleness.
    #expect(decoded == result)
    let decodedItem = try #require(decoded.items.first)
    #expect(decodedItem.sizeBytes == 42)
    let reason = try #require(decodedItem.protection)
    #expect(reason == .recentActivity(days: 14))
    // The item is protected, so it contributes nothing to the reclaimable total.
    #expect(decoded.reclaimableBytes == 0)
}

@Test func helperListsChildrenSkippingHiddenEntries() {
    let temp = TempDir()
    temp.makeDirectory("root/one")
    temp.makeDirectory("root/two")
    temp.makeFile("root/.DS_Store")
    let children = ScanHelpers.children(of: temp.path + "/root")
    #expect(children.map(\.name).sorted() == ["one", "two"])
}

@Test func helperReturnsEmptyForMissingDirectory() {
    let temp = TempDir()
    #expect(ScanHelpers.children(of: temp.path + "/nope").isEmpty)
}

/// The id carries the scanner id as well as the path. Two scanners are not meant
/// to report the same path — that would double-count in `reclaimableBytes`, which
/// does not de-duplicate — but the id is a persisted format, so the prefix is
/// insurance rather than a licence to overlap.
@Test func helperItemIDIsScannerIDAndPathSoTwoScannersNeverCollide() {
    let path = "/Users/tester/Library/Developer/Xcode/DerivedData/MyApp-abc123"

    let built = ScanHelpers.item(
        scannerID: "xcode.derivedData", group: .xcodeAndIOS,
        path: path, name: "MyApp-abc123", sizeBytes: 2_048)

    #expect(built.id == "xcode.derivedData|" + path)
    // Whole-value equality pins every default in one go: detail, lastUsed, risk,
    // protection and the .removePath method built from the path.
    #expect(built == CleanupItem(
        id: "xcode.derivedData|" + path, scannerID: "xcode.derivedData",
        group: .xcodeAndIOS, name: "MyApp-abc123", detail: nil, sizeBytes: 2_048,
        lastUsed: nil, risk: .safe, protection: nil, method: .removePath(path)))
    #expect(built.isDeletable)

    let other = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects,
        path: path, name: "MyApp-abc123", sizeBytes: 2_048)
    #expect(built.id != other.id)
}

/// Every scanner filters on `isDirectory` before measuring. If that field were
/// stuck at one value, all fifteen would return nothing and the app would report
/// zero reclaimable with no error at all.
@Test func helperMarksDirectoriesApartFromFilesAndReportsPathAndDate() throws {
    let temp = TempDir()
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    temp.makeDirectory("root/adir")
    temp.makeFile("root/afile.txt", contents: "hello", modified: stamp)

    let children = ScanHelpers.children(of: temp.path + "/root")

    let directory = try #require(children.first { $0.name == "adir" })
    #expect(directory.isDirectory)
    #expect(directory.path == temp.path + "/root/adir")

    let file = try #require(children.first { $0.name == "afile.txt" })
    #expect(!file.isDirectory)
    #expect(file.path == temp.path + "/root/afile.txt")
    let modified = try #require(file.modified)
    #expect(modified == stamp)
}

/// Finding nothing is the normal case, not a failure: a machine with no Android
/// SDK makes several scanners return an empty list. The rest of the scan must
/// still run, and an empty result must not be reported as a skipped scanner —
/// the popover draws a skipped scanner as switched off.
@Test func engineKeepsGoingAfterAScannerFindsNothing() async {
    let engine = ScanEngine(scanners: [
        StubScanner(id: "android.sdk", group: .android, title: "SDK", items: []),
        StubScanner(id: "flutter.fvm", group: .flutterAndDart, title: "fvm",
                    items: [makeItem("fvm", scanner: "flutter.fvm", group: .flutterAndDart, size: 2_000)]),
    ])
    let result = await engine.scan(context: makeContext())
    #expect(result.items.map(\.id) == ["fvm"])
    #expect(result.reclaimableBytes == 2_000)
    #expect(result.skippedScannerIDs.isEmpty)
}

/// Absent items are not enough: an engine that runs every scanner and discards
/// the skipped one's items afterwards looks identical from the outside, while
/// still paying the full `du` cost the user switched the scanner off to avoid.
@Test func skippedScannerIsNeverCalled() async {
    var settings = Settings.makeDefault(home: "/Users/tester")
    settings.alwaysSkipScannerIDs = ["flutter.pubCache"]

    let counter = RunCounter()
    let engine = ScanEngine(scanners: [
        RecordingScanner(id: "flutter.pubCache", group: .flutterAndDart,
                         title: "pub-cache", counter: counter),
        RecordingScanner(id: "flutter.fvm", group: .flutterAndDart,
                         title: "fvm", counter: counter),
    ])
    _ = await engine.scan(context: makeContext(settings: settings))

    let skippedRuns = await counter.count("flutter.pubCache")
    let otherRuns = await counter.count("flutter.fvm")
    #expect(skippedRuns == 0)
    #expect(otherRuns == 1)
}

@Test func engineKeepsScannerOrderAndStampsTheInjectedTime() async {
    let engine = ScanEngine(scanners: [
        StubScanner(id: "first", group: .xcodeAndIOS, title: "First",
                    items: [makeItem("a", scanner: "first", group: .xcodeAndIOS, size: 1)]),
        StubScanner(id: "second", group: .android, title: "Second",
                    items: [makeItem("b", scanner: "second", group: .android, size: 2)]),
    ])
    let result = await engine.scan(context: makeContext())
    #expect(result.items.map(\.id) == ["a", "b"])
    #expect(result.generatedAt == Date(timeIntervalSince1970: 1_786_000_000))
}

@Test func homePathJoinsOntoTheHomeDirectory() {
    #expect(makeContext().homePath("Library/Developer/Xcode")
            == "/Users/tester/Library/Developer/Xcode")
}
