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

/// `path` and `startsUnticked` default to what every call site written before the
/// large-files rule meant, so only the tests about that rule say anything about them.
private func makeItem(_ id: String, scanner: String, group: GroupID,
                      size: Int64, protection: ProtectionReason? = nil,
                      path: String? = nil, startsUnticked: Bool = false) -> CleanupItem {
    CleanupItem(id: id, scannerID: scanner, group: group, name: id, detail: nil,
                sizeBytes: size, lastUsed: nil, risk: .safe, protection: protection,
                method: .removePath(path ?? "/tmp/\(id)"), startsUnticked: startsUnticked)
}

/// `home` defaults to a path that exists nowhere, which is all the tests about collecting
/// and skipping need. The tests about a row sitting inside another row's target pass a real
/// `TempDir`, because that rule compares canonicalised paths and canonicalising is what a
/// made-up path cannot do.
private func makeContext(settings: Settings? = nil,
                         home: String = "/Users/tester") -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: home), protection: .empty, projects: [],
        devices: .empty,
        home: home, androidSDKPath: home + "/Library/Android/sdk",
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
/// the menu bar panel reports a skipped scanner as switched off.
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

// MARK: - a large file inside another row's target

/// A `big.largeFiles` row for a path, shaped as `LargeFilesScanner` shapes one.
private func largeFile(_ path: String) -> CleanupItem {
    CleanupItem(
        id: LargeFilesScanner.scannerID + "|" + path,
        scannerID: LargeFilesScanner.scannerID, group: .bigThings,
        name: (path as NSString).lastPathComponent, detail: nil, sizeBytes: 1_700_000_000,
        lastUsed: nil, risk: .irreplaceable, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// **The row is dropped whatever the containing row is**, because the reason differs and
/// both reasons cost the user something.
///
/// A ticked container — a project's `build` folder — would mean asking about one file
/// twice, once as part of a folder that comes back and once as a film that does not, and
/// whichever card was answered second would be describing bytes that had already gone. An
/// unticked container is the same double offer with the order reversed. A **protected**
/// container is the sharpest of the three: protection means "must not be deleted at all",
/// and offering a 1.2 GB scan inside a kept project with a checkbox beside it would be the
/// app taking the promise back one file at a time.
///
/// `big.largeFiles` is the only scanner that looks everywhere, so it is the only one whose
/// rows can land inside another's — which is why the rule reads in one direction.
@Test func aLargeFileInsideAnyOtherRowsTargetIsDroppedTickedUntickedOrProtected() async {
    let temp = TempDir()
    let ticked = temp.makeDirectory("dev/app/build")
    let unticked = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let kept = temp.makeDirectory("dev/live")

    let inTicked = temp.makeFile("dev/app/build/fixture.mov", contents: "x")
    let inUnticked = temp.makeFile(
        "Library/Android/sdk/ndk/27.0.12077973/toolchain.bin", contents: "x")
    let inKept = temp.makeFile("dev/live/work/scan.pdf", contents: "x")
    let loose = temp.makeFile("Documents/render.mov", contents: "x")

    let engine = ScanEngine(scanners: [
        StubScanner(id: "projects.buildOutput", group: .projects, title: "Build output",
                    items: [makeItem("build", scanner: "projects.buildOutput",
                                     group: .projects, size: 5_000, path: ticked)]),
        StubScanner(id: "android.ndk", group: .android, title: "NDK",
                    items: [makeItem("ndk", scanner: "android.ndk", group: .android,
                                     size: 5_570_000_000, path: unticked,
                                     startsUnticked: true)]),
        StubScanner(id: "projects.summary", group: .projects, title: "Kept projects",
                    items: [makeItem("live", scanner: "projects.buildOutput",
                                     group: .projects, size: 0,
                                     protection: .recentActivity(days: 14), path: kept)]),
        StubScanner(id: LargeFilesScanner.scannerID, group: .bigThings, title: "Large files",
                    items: [inTicked, inUnticked, inKept, loose].map(largeFile)),
    ])

    let result = await engine.scan(context: makeContext(home: temp.path))

    // Only the film that is inside nothing survives, and the four containing rows are all
    // still there — this drops the duplicate offer, never the row that owns the folder.
    #expect(result.items.filter { $0.scannerID == LargeFilesScanner.scannerID }
            .map(\.name) == ["render.mov"])
    #expect(result.items.count == 4)
}

/// **Separator-aware**, the standing rule in this package about path prefixes.
///
/// `~/dev/app/build` must not swallow `~/dev/app/build2`, and a row must not be dropped by
/// a container that merely *equals* a prefix of its own name. Both directions of the rule
/// are here because a bare `hasPrefix` passes neither and a rule that dropped too much
/// would lose the user a file they wanted to see with nothing on screen to say so.
@Test func onlyARowGenuinelyInsideAContainerIsDroppedNotOneWhoseNameStartsTheSame() async {
    let temp = TempDir()
    let container = temp.makeDirectory("dev/app/build")
    let sibling = temp.makeFile("dev/app/build2/huge.mov", contents: "x")
    let inside = temp.makeFile("dev/app/build/huge.mov", contents: "x")

    let engine = ScanEngine(scanners: [
        StubScanner(id: "projects.buildOutput", group: .projects, title: "Build output",
                    items: [makeItem("build", scanner: "projects.buildOutput",
                                     group: .projects, size: 5_000,
                                     path: container)]),
        StubScanner(id: LargeFilesScanner.scannerID, group: .bigThings, title: "Large files",
                    items: [sibling, inside].map(largeFile)),
    ])

    let result = await engine.scan(context: makeContext(home: temp.path))

    #expect(result.items.filter { $0.scannerID == LargeFilesScanner.scannerID }
            .map(\.method) == [.removePath(sibling)])
}

/// The rule reads **only** `big.largeFiles` rows, and only as the thing that might be
/// inside something.
///
/// Every other scanner names a directory inside a tool's own tree that it alone knows
/// about, and the pairs that do overlap — a Gradle cache under `~/.gradle`, a simulator
/// runtime — are already one row each by target. A rule that dropped any row sitting inside
/// any other would take the archive out of `~/Library/Developer/Xcode/Archives` the moment
/// something named the parent, so it is deliberately one-directional and deliberately about
/// one identifier.
@Test func anotherScannersRowInsideALargeFilesRowIsKept() async {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/holiday.mov", contents: "x")
    // Nonsense as a layout, and the point: the rule must not start reading in this
    // direction just because a path happens to sit under another.
    let cache = temp.makeFile("Documents/films/holiday.mov.cache/blob", contents: "x")

    let engine = ScanEngine(scanners: [
        StubScanner(id: LargeFilesScanner.scannerID, group: .bigThings, title: "Large files",
                    items: [largeFile(film)]),
        StubScanner(id: "other.libraryCaches", group: .otherCaches, title: "Caches",
                    items: [makeItem("blob", scanner: "other.libraryCaches",
                                     group: .otherCaches, size: 5_000,
                                     path: cache)]),
    ])

    let result = await engine.scan(context: makeContext(home: temp.path))
    #expect(result.items.count == 2)
}

/// A scan with no other rows in it drops nothing.
///
/// The guard against the fast path being wrong the other way: `droppingLargeFilesInside
/// AnotherRow` returns early when there is nothing to compare against, and a machine with
/// no Android SDK, no projects and no caches is an ordinary machine.
@Test func aScanHoldingNothingButLargeFilesKeepsEveryRow() async {
    let temp = TempDir()
    let films = ["Documents/a.mov", "Documents/b.mov"].map { temp.makeFile($0, contents: "x") }

    let engine = ScanEngine(scanners: [
        StubScanner(id: LargeFilesScanner.scannerID, group: .bigThings, title: "Large files",
                    items: films.map(largeFile)),
    ])

    let result = await engine.scan(context: makeContext(home: temp.path))
    #expect(result.items.map(\.method) == films.map { .removePath($0) })
}

/// A container reached through a **symlinked parent** still contains the row.
///
/// Both spellings of every target are compared, which is what this needs: the row's path
/// resolves to somewhere under the real folder while the container's own string names the
/// link. Unlike the de-duplication by target, where a wrong merge silently drops a row from
/// the list, the wrong answer here is to keep a second offer of somebody's file — so every
/// spelling that says "inside" is enough.
@Test func aLargeFileIsDroppedWhenTheContainerIsSpelledThroughASymlink() async {
    let temp = TempDir()
    temp.makeDirectory("dev/real/build")
    temp.makeSymlink("dev/link", to: temp.path + "/dev/real")
    let film = temp.makeFile("dev/real/build/fixture.mov", contents: "x")

    let engine = ScanEngine(scanners: [
        StubScanner(id: "projects.buildOutput", group: .projects, title: "Build output",
                    items: [makeItem("build", scanner: "projects.buildOutput",
                                     group: .projects, size: 5_000,
                                     path: temp.path + "/dev/link/build")]),
        StubScanner(id: LargeFilesScanner.scannerID, group: .bigThings, title: "Large files",
                    items: [largeFile(film)]),
    ])

    let result = await engine.scan(context: makeContext(home: temp.path))
    #expect(!result.items.contains { $0.scannerID == LargeFilesScanner.scannerID })
}

@Test func homePathJoinsOntoTheHomeDirectory() {
    #expect(makeContext().homePath("Library/Developer/Xcode")
            == "/Users/tester/Library/Developer/Xcode")
}
