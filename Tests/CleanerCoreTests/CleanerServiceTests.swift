import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)
private let finished = Date(timeIntervalSince1970: 1_786_000_042)

/// A service wired entirely to doubles.
///
/// `FakeFileRemover`, never `SystemFileRemover`: the real one would move every test
/// fixture into the developer's own Trash, run after run.
private func makeService(
    temp: TempDir, runner: any ProcessRunner,
    sizes: [String: Int64] = [:],
    settings mutate: (inout Settings) -> Void = { _ in },
    androidSDKPath: String? = nil
) throws -> CleanerService {
    var settings = Settings.makeDefault(home: temp.path)
    settings.projectRoots = [temp.path + "/dev"]
    mutate(&settings)
    let store = SettingsStore(directory: temp.url, home: temp.path)
    try store.save(settings)
    return makeServiceReadingStoredSettings(
        temp: temp, runner: runner, sizes: sizes, androidSDKPath: androidSDKPath)
}

/// The same wiring without writing any settings, for the tests that hand-edit
/// `settings.json` the way a user with a text editor can.
private func makeServiceReadingStoredSettings(
    temp: TempDir, runner: any ProcessRunner,
    sizes: [String: Int64] = [:],
    androidSDKPath: String? = nil
) -> CleanerService {
    CleanerService(
        settingsStore: SettingsStore(directory: temp.url, home: temp.path),
        runLog: RunLog(directory: temp.url.appendingPathComponent("runs")),
        runner: runner,
        remover: FakeFileRemover(),
        sizeMeasurer: FixedSizeMeasurer(sizes),
        fileManager: .default,
        home: temp.path,
        androidSDKPath: androidSDKPath ?? temp.path + "/Library/Android/sdk",
        clock: { finished })
}

private struct StubScanner: CleanupScanner {
    let id: String
    let group: GroupID
    let title: String
    let items: [CleanupItem]
    func scan(_ context: ScanContext) async -> [CleanupItem] { items }
}

private func stubContext(home: String) -> ScanContext {
    ScanContext(
        settings: .makeDefault(home: home), protection: .empty, projects: [], devices: .empty,
        home: home, androidSDKPath: home + "/Library/Android/sdk",
        sizeMeasurer: FixedSizeMeasurer([:]), runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

private func row(_ name: String, path: String, size: Int64,
                 scanner: String = "other.libraryCaches", group: GroupID = .otherCaches,
                 protection: ProtectionReason? = nil,
                 startsUnticked: Bool = false, sizeMayBeShared: Bool = false) -> CleanupItem {
    ScanHelpers.item(
        scannerID: scanner, group: group, path: path, name: name, sizeBytes: size,
        protection: protection, startsUnticked: startsUnticked,
        sizeMayBeShared: sizeMayBeShared)
}

// MARK: - the registry

/// Rule 3, at the level of the whole app. These identifiers are persisted in
/// `Settings.alwaysSkipScannerIDs`, so a rename silently switches a scanner back on for a
/// user who had switched it off, and a scanner dropped from the registry stops running
/// with nothing anywhere to say so.
@Test func theRegistryHoldsExactlyTheseSeventeenIdentifiers() {
    #expect(Set(CleanerService.scannerIDs) == [
        "xcode.derivedData", "xcode.archives", "xcode.deviceSupport",
        "ios.simulators", "ios.runtimes", "ios.simulatorCaches",
        "android.avds", "android.systemImages", "android.ndk", "android.gradle",
        "flutter.pubCache", "flutter.fvm",
        "projects.buildOutput",
        "other.cocoapods", "other.jsPackages", "other.localToolCaches",
        "other.libraryCaches",
    ])
    // The plan said fifteen. `android.ndk` arrived after it was written, and counting is
    // what catches the next one being added to the package but not to this list.
    #expect(CleanerService.allScanners().count == 17)
}

/// The order the popover draws, and the group each row lands in. Order is part of the
/// contract: a list that reshuffles between builds moves the tick boxes under the cursor.
@Test func theRegistryListsTheScannersInDisplayOrderWithTheirGroups() {
    let listed = CleanerService.allScanners().map { ($0.id, $0.group) }
    let expected: [(String, GroupID)] = [
        ("xcode.derivedData", .xcodeAndIOS),
        ("xcode.archives", .xcodeAndIOS),
        ("xcode.deviceSupport", .xcodeAndIOS),
        ("ios.simulators", .xcodeAndIOS),
        ("ios.runtimes", .xcodeAndIOS),
        ("ios.simulatorCaches", .xcodeAndIOS),
        ("android.avds", .android),
        ("android.systemImages", .android),
        ("android.ndk", .android),
        ("android.gradle", .android),
        ("flutter.pubCache", .flutterAndDart),
        ("flutter.fvm", .flutterAndDart),
        ("projects.buildOutput", .projects),
        ("other.cocoapods", .otherCaches),
        ("other.jsPackages", .otherCaches),
        ("other.localToolCaches", .otherCaches),
        ("other.libraryCaches", .otherCaches),
    ]
    #expect(listed.map(\.0) == expected.map(\.0))
    #expect(listed.map(\.1) == expected.map(\.1))
}

@Test func noScannerIsRegisteredTwiceAndEveryOneHasATitle() {
    let ids = CleanerService.scannerIDs
    #expect(Set(ids).count == ids.count)
    #expect(CleanerService.allScanners().allSatisfy { !$0.title.isEmpty })
}

/// Reads the source tree and fails if a `CleanupScanner` exists that the registry does not
/// name.
///
/// Every other test here can only check what is in the list. This is the only one that can
/// notice something missing from it, which is the failure that actually happened:
/// `NDKScanner` was written in Task 13's follow-up and the plan's list of fifteen has no
/// entry for it, so a registry copied from the plan would have left 5.57 GB of NDK
/// invisible and `android.ndk` un-skippable.
///
/// It reads `Sources/CleanerCore` beside this file. That is the repository, not the
/// developer's machine — the one deliberate exception to "no test reads real state" in this
/// suite, and it fails loudly rather than silently passing if the directory is not there.
@Test func everyScannerInTheSourceTreeIsInTheRegistry() throws {
    let sources = URL(fileURLWithPath: #filePath)   // …/Tests/CleanerCoreTests/<this file>
        .deletingLastPathComponent()                // …/Tests/CleanerCoreTests
        .deletingLastPathComponent()                // …/Tests
        .deletingLastPathComponent()                // the package root
        .appendingPathComponent("Sources/CleanerCore")
    #expect(FileManager.default.fileExists(atPath: sources.path),
            "the package sources must sit at \(sources.path) for this test to mean anything")

    let pattern = try NSRegularExpression(
        pattern: #"(?:struct|final class|class|actor)\s+(\w+)\s*:[^{\n]*\bCleanupScanner\b"#)
    let enumerator = try #require(
        FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

    var declared: Set<String> = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        let whole = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            declared.insert(String(text[range]))
        }
    }

    let registered = Set(CleanerService.allScanners().map { String(describing: type(of: $0)) })
    // Sanity: the search found something at all, so a broken pattern cannot pass by
    // finding nothing and comparing two empty sets.
    #expect(declared.count == 17)
    #expect(declared.subtracting(registered).isEmpty,
            "these scanners exist but are not in CleanerService.allScanners()")
    #expect(registered.subtracting(declared).isEmpty)
}

// MARK: - the tick rule

/// Note 1, stated directly. `selectedByDefault` was an alias for `isDeletable` until the
/// NDK arrived; anything still ticking from `isDeletable` puts 5.57 GB of re-download into
/// a clean the user never agreed to.
@Test func theDefaultSelectionTicksFromSelectedByDefaultAndNeverFromIsDeletable() {
    let ordinary = row("gradle caches", path: "/tmp/one", size: 1_000)
    let ndk = row("27.0.12077973", path: "/tmp/ndk", size: 5_570_000_000,
                  scanner: "android.ndk", group: .android, startsUnticked: true)
    let protected = row("kept", path: "/tmp/kept", size: 4_000,
                        protection: .recentActivity(days: 14))
    let result = ScanResult(items: [ordinary, ndk, protected], generatedAt: now,
                            availableBytes: 0, skippedScannerIDs: [])

    #expect(result.defaultSelection.map(\.name) == ["gradle caches"])
    // The NDK is deletable. That is exactly why filtering on it is the bug.
    #expect(ndk.isDeletable)
    #expect(!ndk.selectedByDefault)
    #expect(result.items.filter(\.isDeletable).count == 2)
}

@Test func theNDKIsOfferedWithItsSizeAndLeftUntickedEndToEnd() async throws {
    let temp = TempDir()
    let sdk = temp.path + "/Library/Android/sdk"
    let one = temp.makeDirectory("Library/Android/sdk/ndk/26.3.11579264")
    let two = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let gradle = temp.makeDirectory(".gradle/caches/build-cache-1")

    let service = try makeService(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [one: 2_570_000_000, two: 3_000_000_000, gradle: 1_000_000],
        androidSDKPath: sdk)
    let result = await service.scan(now: now)

    let ndkRows = result.items.filter { $0.scannerID == "android.ndk" }
    #expect(ndkRows.count == 2)
    #expect(ndkRows.allSatisfy { $0.isDeletable })
    #expect(ndkRows.allSatisfy { !$0.selectedByDefault })
    // The headline is the Gradle row alone; the NDK's 5.57 GB is quoted separately.
    #expect(result.reclaimableBytes == 1_000_000)
    #expect(result.untickedDeletableBytes == 5_570_000_000)
    #expect(result.defaultSelection.allSatisfy { $0.scannerID != "android.ndk" })
    // Group totals follow the same rule, or the Android group alone reports the 5.57 GB.
    #expect(result.reclaimableBytes(in: .android) == 1_000_000)
}

@Test func aDefaultCleanLeavesTheNDKOnDiskAndTakesTheTickedRow() async throws {
    let temp = TempDir()
    let sdk = temp.path + "/Library/Android/sdk"
    let ndk = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let gradle = temp.makeDirectory(".gradle/caches/build-cache-1")

    let service = try makeService(
        temp: temp, runner: RecordingProcessRunner(),
        sizes: [ndk: 3_000_000_000, gradle: 1_000_000], androidSDKPath: sdk)
    let scan = await service.scan(now: now)
    let record = await service.clean(items: scan.defaultSelection, now: now, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: ndk))
    #expect(!FileManager.default.fileExists(atPath: gradle))
    #expect(record.trashedBytes == 1_000_000)
}

/// The user can still ask for it — unticked means "not by default", not "not at all".
@Test func anNDKRowTickedByHandIsRemovedLikeAnyOtherPath() async throws {
    let temp = TempDir()
    let sdk = temp.path + "/Library/Android/sdk"
    let ndk = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")

    let service = try makeService(
        temp: temp, runner: RecordingProcessRunner(),
        sizes: [ndk: 3_000_000_000], androidSDKPath: sdk)
    let scan = await service.scan(now: now)
    let chosen = try #require(scan.items.first { $0.scannerID == "android.ndk" })
    let record = await service.clean(items: [chosen], now: now, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: ndk))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
}

// MARK: - the default clean

/// The destructive tick decision, now somewhere a test can reach it.
///
/// It used to live in `main.swift` as `let selected = result.defaultSelection`, and an
/// executable target cannot be imported by a test target — so the single most destructive
/// line in the tool was verified only by a manual dry run, and the menu bar app was about
/// to repeat it. `cleanDefault` is the same decision as an ordinary method.
///
/// Three kinds of row in one scan, so the mutation `defaultSelection` →
/// `items.filter(\.isDeletable)` has something to fail on: an ordinary ticked cache, an
/// NDK row that is deletable and deliberately unticked, and a protected project the
/// executor would refuse anyway.
@Test func cleanDefaultRemovesExactlyTheRowsTheListingTicks() async throws {
    let temp = TempDir()
    let sdk = temp.path + "/Library/Android/sdk"
    let ndk = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let gradle = temp.makeDirectory(".gradle/caches/modules-2")
    // An active project, so its build folder is protected and its row is not deletable.
    temp.makeFile("dev/sample-project/pubspec.yaml", modified: now)
    let build = temp.makeDirectory("dev/sample-project/build")

    let service = try makeService(
        temp: temp, runner: RecordingProcessRunner(),
        sizes: [ndk: 3_000_000_000, gradle: 1_000_000, build: 500_000], androidSDKPath: sdk)
    let scan = await service.scan(now: now)

    let record = await service.cleanDefault(scan, now: now, progress: { _ in })

    // The ticked cache went.
    #expect(!FileManager.default.fileExists(atPath: gradle))
    // The unticked NDK stayed — 3 GB of re-download nobody asked for.
    #expect(FileManager.default.fileExists(atPath: ndk))
    // The protected project's build folder stayed, and was never even attempted: it is
    // not in the record at all, because it was never selected.
    #expect(FileManager.default.fileExists(atPath: build))
    #expect(!record.entries.contains { $0.target.contains("/dev/sample-project") })
    #expect(record.failedCount == 0)
    #expect(record.trashedBytes == 1_000_000)
}

/// The over-fix guard: `cleanDefault` is not a no-op. A delegation that passed an empty
/// list would satisfy every "stayed" assertion above.
@Test func cleanDefaultOnAScanWithNothingTickedRemovesNothingAndStillReturnsARecord() async {
    let temp = TempDir()
    let service = makeServiceReadingStoredSettings(
        temp: temp, runner: RecordingProcessRunner())
    let empty = ScanResult(items: [], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])

    let record = await service.cleanDefault(empty, now: now, progress: { _ in })
    #expect(record.entries.isEmpty)
    #expect(record.startedAt == now)
}

// MARK: - the totals

@Test func theHeadlineTotalLeavesOutProtectedAndUntickedRows() {
    let result = ScanResult(items: [
        row("a", path: "/tmp/a", size: 100),
        row("b", path: "/tmp/b", size: 200, protection: .pinnedProject),
        row("c", path: "/tmp/c", size: 400, startsUnticked: true),
    ], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])

    #expect(result.reclaimableBytes == 100)
    #expect(result.untickedDeletableBytes == 400)
}

/// A row that is **both protected and unticked** — the one shape that tells
/// `untickedDeletableBytes` apart from a plain `startsUnticked` filter.
///
/// No scanner produced such a row until this fix wave, so dropping `isDeletable` from that
/// filter left all 439 tests passing. It produces them now: a protected simulator whose
/// runtime, or an unmeasurable path, comes back unticked as well. Without the filter the
/// tool would offer "and 7.1 GB more if you tick these" for rows it will refuse to delete.
@Test func untickedDeletableBytesLeavesOutARowThatIsProtectedAsWellAsUnticked() {
    let result = ScanResult(items: [
        row("offered", path: "/tmp/offered", size: 400, startsUnticked: true),
        row("kept", path: "/tmp/kept", size: 7_090_000_000,
            protection: .bootedDevice, startsUnticked: true),
    ], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])

    #expect(result.untickedDeletableBytes == 400)
    #expect(result.reclaimableBytes == 0)
}

/// Two rows naming one directory are one lot of bytes. Nothing produces such a pair today,
/// and the sum is the last place able to refuse one.
@Test func theHeadlineTotalCountsOneTargetOnce() {
    let result = ScanResult(items: [
        row("cache", path: "/tmp/shared", size: 1_000, scanner: "other.jsPackages"),
        row("cache", path: "/tmp/shared", size: 1_000, scanner: "other.libraryCaches"),
    ], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])

    #expect(result.items.count == 2)
    #expect(result.reclaimableBytes == 1_000)
    #expect(result.reclaimableBytes(in: .otherCaches) == 1_000)
}

@Test func twoSimulatorRowsForOneUDIDCountOnce() {
    let device = { (scanner: String) in
        CleanupItem(id: "\(scanner)|UDID-1", scannerID: scanner, group: .xcodeAndIOS,
                    name: "iPhone 17", detail: nil, sizeBytes: 12_860_000_000, lastUsed: nil,
                    risk: .safe, protection: nil, method: .deleteSimulator(udid: "UDID-1"))
    }
    let result = ScanResult(items: [device("ios.simulators"), device("ios.other")],
                            generatedAt: now, availableBytes: 0, skippedScannerIDs: [])
    #expect(result.reclaimableBytes == 12_860_000_000)
}

/// Two spellings of one directory, told apart only by resolving the parent. The engine
/// de-duplicates on the canonical form, which the plain string comparison in the totals
/// cannot see.
@Test func theEngineDropsASecondRowReachingTheSameDirectoryThroughASymlink() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("a/real/build")
    temp.makeSymlink("a/link", to: temp.path + "/a/real")
    let throughLink = temp.path + "/a/link/build"

    let engine = ScanEngine(scanners: [
        StubScanner(id: "one", group: .projects, title: "One",
                    items: [row("build", path: real, size: 5_000, group: .projects)]),
        StubScanner(id: "two", group: .projects, title: "Two",
                    items: [row("build", path: throughLink, size: 5_000, group: .projects)]),
    ])
    let result = await engine.scan(context: stubContext(home: temp.path))

    #expect(result.items.count == 1)
    #expect(result.reclaimableBytes == 5_000)
    let kept = try #require(result.items.first)
    #expect(kept.method == .removePath(real))
}

/// A symlink at the **leaf** is its own thing: removing the link is not removing what it
/// points at, so the two rows must not be merged.
@Test func aSymlinkAtTheLeafKeepsItsOwnIdentity() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("a/build")
    let link = temp.makeSymlink("a/build-link", to: real)

    let engine = ScanEngine(scanners: [
        StubScanner(id: "one", group: .projects, title: "One",
                    items: [row("build", path: real, size: 5_000, group: .projects)]),
        StubScanner(id: "two", group: .projects, title: "Two",
                    items: [row("build-link", path: link, size: 7_000, group: .projects)]),
    ])
    let result = await engine.scan(context: stubContext(home: temp.path))

    #expect(result.items.count == 2)
    #expect(result.reclaimableBytes == 12_000)
}

/// When two rows name one target and one of them says it must not be deleted, the
/// protected one is what survives into the list. Keeping the deletable one would leave the
/// interface a row it will tick for a target something refused.
@Test func theProtectedRowWinsWhenTwoScannersNameOneTarget() async throws {
    let temp = TempDir()
    let path = temp.makeDirectory("dev/live/build")

    let engine = ScanEngine(scanners: [
        StubScanner(id: "one", group: .projects, title: "One",
                    items: [row("build", path: path, size: 5_000, group: .projects)]),
        StubScanner(id: "two", group: .projects, title: "Two",
                    items: [row("build", path: path, size: 5_000, group: .projects,
                                protection: .recentActivity(days: 14))]),
    ])
    let result = await engine.scan(context: stubContext(home: temp.path))

    #expect(result.items.count == 1)
    let kept = try #require(result.items.first)
    #expect(kept.protection == .recentActivity(days: 14))
    #expect(result.reclaimableBytes == 0)
}

/// Note 2's third problem: the pnpm store and the bun cache share their blocks with every
/// project that installed from them, so `du` there is not necessarily space that comes
/// back. npm and Yarn copy instead, so theirs is.
@Test func thePnpmAndBunRowsAreTheOnlyOnesWhoseSizeIsMarkedAsPossiblyShared() async throws {
    let temp = TempDir()
    let npm = temp.makeDirectory(".npm/_cacache")
    let pnpm = temp.makeDirectory("Library/pnpm/store")
    let yarn = temp.makeDirectory("Library/Caches/Yarn")
    let bun = temp.makeDirectory(".bun/install/cache")

    let result = try await makeService(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [npm: 100_000, pnpm: 367_071_232, yarn: 200_000, bun: 1_459_331_072]
    ).scan(now: now)

    let shared = result.items.filter(\.sizeMayBeShared).map(\.name).sorted()
    #expect(shared == ["bun cache", "pnpm store"])
    #expect(result.possiblySharedBytes == 1_826_402_304)
    #expect(result.reclaimableBytes == 1_826_702_304)
    // The honest range an interface shows: at least the copied caches, at most everything.
    #expect(result.reclaimableBytes - result.possiblySharedBytes == 300_000)
}

@Test func aProtectedSharedRowIsNotCountedAsPossiblyShared() {
    let result = ScanResult(items: [
        row("pnpm store", path: "/tmp/pnpm", size: 1_000, sizeMayBeShared: true),
        row("bun cache", path: "/tmp/bun", size: 2_000,
            protection: .pinnedProject, sizeMayBeShared: true),
    ], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])

    #expect(result.reclaimableBytes == 1_000)
    #expect(result.possiblySharedBytes == 1_000)
}

// MARK: - the disk is walked once

/// Rule 9's other half. `sizes(of:)` is the only place that spawns `du`, and a repeated
/// path there is a second full walk of the same directory for a number already known.
@Test func aRepeatedPathIsMeasuredOnce() async throws {
    let runner = RecordingProcessRunner(responses: [
        commandKey("/usr/bin/du", ["-sk", "/tmp/thing"]):
            ProcessResult(exitCode: 0, stdout: "12\t/tmp/thing\n", stderr: ""),
    ])
    let sizes = await DiskUsageMeasurer(runner: runner)
        .sizes(of: ["/tmp/thing", "/tmp/thing", "/tmp/thing"])

    #expect(runner.recorded.count == 1)
    let measured = try #require(sizes["/tmp/thing"])
    #expect(measured == 12_288)
}

/// Two overlapping project roots describe one project. Without de-duplication the service
/// walks it twice: `ActivityInspector` reads every file in it a second time and asks git
/// for the same commit again.
@Test func aProjectFoundThroughTwoOverlappingRootsIsInspectedOnce() async throws {
    let temp = TempDir()
    temp.makeFile("dev/app/pubspec.yaml", modified: now.addingTimeInterval(-86_400))
    temp.makeDirectory("dev/app/.git")
    temp.makeDirectory("dev/app/build")
    let project = temp.path + "/dev/app"

    let runner = RecordingProcessRunner()
    let service = try makeService(temp: temp, runner: runner) { settings in
        settings.projectRoots = [temp.path + "/dev", project]
    }
    _ = await service.scan(now: now)

    let gitCall = commandKey("/usr/bin/git", ["-C", project, "log", "-1", "--format=%ct"])
    #expect(runner.recorded.filter { $0 == gitCall }.count == 1)
}

// MARK: - project roots that are too wide

@Test func savingRefusesTheHomeDirectoryAsAProjectRoot() throws {
    let temp = TempDir()
    let store = SettingsStore(directory: temp.url, home: temp.path)
    var settings = Settings.makeDefault(home: temp.path)
    settings.projectRoots = [temp.path]

    #expect(throws: SettingsError.projectRootTooWide(temp.path)) { try store.save(settings) }
    // Nothing was written, so a refused save cannot half-apply.
    #expect(!FileManager.default.fileExists(atPath: temp.path + "/settings.json"))
}

@Test func savingRefusesTheRootDirectoryTheTildeAndTheEmptyString() throws {
    let temp = TempDir()
    temp.makeDirectory("dev")
    let store = SettingsStore(directory: temp.url, home: temp.path)

    // `dev/..` is the home directory reached by a different string, and a settings file is
    // hand-editable text, so the check has to resolve as well as compare.
    for bad in ["/", "~", "", "  ", temp.path + "/", "~/", temp.path + "/dev/.."] {
        var settings = Settings.makeDefault(home: temp.path)
        settings.projectRoots = [bad]
        #expect(throws: SettingsError.projectRootTooWide(bad)) { try store.save(settings) }
    }
}

/// A home directory that does not exist on a real dev machine cannot be resolved, so the
/// trailing slash has to be stripped before the strings are compared. This is the case
/// every other check here misses, and it is the ordinary one for a settings file copied
/// from another Mac.
@Test func aTrailingSlashDoesNotHideAHomeDirectoryThatCannotBeResolved() throws {
    let temp = TempDir()
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")
    var settings = Settings.makeDefault(home: "/Users/tester")
    settings.projectRoots = ["/Users/tester/"]

    #expect(throws: SettingsError.projectRootTooWide("/Users/tester/")) {
        try store.save(settings)
    }
    // The control: a real folder under that home is still fine.
    settings.projectRoots = ["/Users/tester/dev/"]
    try store.save(settings)
}

/// **A root that contains the home directory.** `/Users` is home's parent, and it was
/// accepted: `PathGuard.forRun` then took it as an allowed root and permitted
/// `~/Documents`, `~/Library/Mail` and `/Users/Shared`. Refusing `/` and home while
/// accepting the directory one level above home refuses nothing at all.
@Test func savingRefusesARootThatContainsTheHomeDirectory() throws {
    let temp = TempDir()

    // As written. A home that does not exist on a real dev machine cannot be resolved, so this
    // is the string-comparison half of the rule — and it is the ordinary case for a
    // settings file copied from another Mac.
    let unresolvable = SettingsStore(directory: temp.url, home: "/Users/tester")
    for bad in ["/Users", "/Users/", "/"] {
        var settings = Settings.makeDefault(home: "/Users/tester")
        settings.projectRoots = [bad]
        #expect(throws: SettingsError.projectRootTooWide(bad)) { try unresolvable.save(settings) }
    }

    // An ancestor of a home that **cannot be resolved at all**, so `realpath` returns
    // nothing for either side and only the as-written comparison can refuse it. This is
    // the ordinary case for a settings file copied from another Mac, where neither the
    // home directory nor the root exists on this one.
    let elsewhere = SettingsStore(directory: temp.url, home: "/Users/tester/dev-home")
    for bad in ["/Users/tester", "/Users/tester/"] {
        var settings = Settings.makeDefault(home: "/Users/tester/dev-home")
        settings.projectRoots = [bad]
        #expect(throws: SettingsError.projectRootTooWide(bad)) { try elsewhere.save(settings) }
    }

    // And as `realpath` resolves it, with a home that really exists. `<home>/..` and
    // `<home>/../..` reach directories above the home directory by a different string.
    let store = SettingsStore(directory: temp.url, home: temp.path)
    for bad in [temp.path + "/..", temp.path + "/../..", "~/.."] {
        var settings = Settings.makeDefault(home: temp.path)
        settings.projectRoots = [bad]
        #expect(throws: SettingsError.projectRootTooWide(bad)) { try store.save(settings) }
    }
}

/// The neighbour trap, from the standing rule about path prefixes. `/Users/x` is **not**
/// an ancestor of a home of `/Users/xavier`, and a bare `hasPrefix` says it is. Without
/// the separator in the prefix, a user called `xavier` cannot name their colleague's
/// `/Users/x` as a shared code folder, and the tool refuses a perfectly ordinary root.
@Test func aRootThatOnlySharesAPrefixWithHomeIsNotTooWide() throws {
    let temp = TempDir()
    let store = SettingsStore(directory: temp.url, home: "/Users/xavier")
    var settings = Settings.makeDefault(home: "/Users/xavier")
    settings.projectRoots = ["/Users/x", "/Users/xavier/dev"]
    try store.save(settings)
    #expect(store.load().projectRoots == ["/Users/x", "/Users/xavier/dev"])
}

/// **A relative root.** `.`, `..` and `dev` resolve against the process working
/// directory, so what they name depends on where the app was launched from — the same
/// reason `PathGuard.validate` refuses a relative path outright.
@Test func savingRefusesARelativeProjectRoot() throws {
    let temp = TempDir()
    temp.makeDirectory("dev")
    let store = SettingsStore(directory: temp.url, home: temp.path)

    for bad in [".", "..", "dev", "./dev", "../Users"] {
        var settings = Settings.makeDefault(home: temp.path)
        settings.projectRoots = [bad]
        #expect(throws: SettingsError.projectRootTooWide(bad)) { try store.save(settings) }
    }
}

/// The over-fix guard. A rule that refuses everything would pass every test above.
@Test func savingKeepsAnOrdinaryProjectRootAndOneBesideATooWideOne() throws {
    let temp = TempDir()
    temp.makeDirectory("dev")
    let store = SettingsStore(directory: temp.url, home: temp.path)

    var good = Settings.makeDefault(home: temp.path)
    good.projectRoots = [temp.path + "/dev", temp.path + "/work", "~/code"]
    try store.save(good)
    // `~/code` is stored as written and comes back expanded: `save` writes what it is
    // given, and `load` is the one boundary that turns a tilde into a directory.
    #expect(store.load().projectRoots == [
        temp.path + "/dev", temp.path + "/work", temp.path + "/code",
    ])

    var mixed = good
    mixed.projectRoots = [temp.path + "/dev", "/"]
    #expect(throws: SettingsError.projectRootTooWide("/")) { try store.save(mixed) }
    // The good value from before is still what is stored.
    #expect(store.load().projectRoots.count == 3)
}

/// A hand-edited `settings.json` never passes through `save`, so the service has to refuse
/// the value again on the way in. Otherwise `ProjectDiscovery` walks the whole home
/// directory and `ActivityInspector` then walks everything it found there.
@Test func aHandEditedRootOfTheHomeDirectoryIsIgnoredRatherThanWalked() async throws {
    let temp = TempDir()
    temp.makeFile("Documents/notes/pubspec.yaml", modified: now)
    temp.makeDirectory("Documents/notes/build")
    temp.makeFile("settings.json", contents: #"{"projectRoots":["\#(temp.path)"]}"#)

    let result = await makeServiceReadingStoredSettings(
        temp: temp, runner: FakeProcessRunner(responses: [:])
    ).scan(now: now)

    #expect(result.ignoredProjectRoots == [temp.path])
    #expect(result.items(in: .projects).isEmpty)
}

/// And the guard still refuses anything under it, so ignoring the root is not what makes
/// the home directory safe.
@Test func aPathUnderAHandEditedWideRootIsStillRefusedByTheRunGuard() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("Documents/notes/build")
    temp.makeFile("settings.json", contents: #"{"projectRoots":["\#(temp.path)"]}"#)

    let service = makeServiceReadingStoredSettings(temp: temp, runner: RecordingProcessRunner())
    let forged = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects,
        path: target, name: "build", sizeBytes: 1)
    let record = await service.clean(items: [forged], now: now, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: target))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
}

// MARK: - a hand-edited tilde root, end to end

/// `~/dev` is the form the settings file's own documentation tells a user to write, and it
/// used to find nothing for ever: `ProjectDiscovery.walk` hands the string to
/// `contentsOfDirectory(atPath:)`, which reads `~` as an ordinary directory name and returns
/// nothing, and nothing anywhere said so. No project discovered means no project protected,
/// so every project's build output was offered for deletion.
///
/// The home here is the temporary directory, so `~/dev` and the directory it names are two
/// obviously different strings.
@Test func aHandEditedTildeRootIsWalkedInsteadOfSilentlyFindingNothing() async throws {
    let temp = TempDir()
    temp.makeFile("dev/active/pubspec.yaml", modified: now.addingTimeInterval(-86_400))
    let activeBuild = temp.makeDirectory("dev/active/build")
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")
    temp.makeFile("settings.json", contents: #"{"projectRoots":["~/dev"]}"#)

    let result = await makeServiceReadingStoredSettings(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [activeBuild: 3_000_000_000, staleBuild: 2_000_000_000]
    ).scan(now: now)

    // The root was walked, not refused.
    #expect(result.ignoredProjectRoots.isEmpty)
    let projectItems = result.items(in: .projects)
    #expect(projectItems.count == 2)
    // And the protection rules then ran on what it found, which is the half that costs
    // data: with no project discovered, nothing is protected.
    #expect(projectItems.first { $0.name == "active" }?.isDeletable == false)
    #expect(projectItems.first { $0.detail == "stale" }?.isDeletable == true)
}

/// The same root reaching `PathGuard.forRun`. An unexpanded `~/dev` cannot be resolved, so
/// `PathGuard.init` drops it from the allowed roots **and** from the forbidden targets, and
/// the guard the user configured stops existing in both directions: nothing under their
/// project root can be cleaned, and the entry meant to protect the root itself can never
/// match a real path.
@Test func buildOutputUnderAHandEditedTildeRootIsAllowedByTheRunGuard() async throws {
    let temp = TempDir()
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")
    temp.makeFile("settings.json", contents: #"{"projectRoots":["~/dev"]}"#)

    let service = makeServiceReadingStoredSettings(temp: temp, runner: RecordingProcessRunner())
    let item = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects,
        path: staleBuild, name: "build", sizeBytes: 1)
    let record = await service.clean(items: [item], now: now, progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(!FileManager.default.fileExists(atPath: staleBuild))
}

/// The other direction of the same guard: delete **inside** `~/dev`, never `~/dev` itself.
///
/// This one would also pass with the root unexpanded, for the wrong reason — an unresolvable
/// root protects everything by allowing nothing. It is here as the pair to the test above,
/// which is the one that discriminates: together they say the root became an allowed root
/// and stayed a forbidden target.
@Test func theProjectRootItselfIsStillRefusedWhenItCameFromATilde() async throws {
    let temp = TempDir()
    let root = temp.makeDirectory("dev")
    temp.makeFile("settings.json", contents: #"{"projectRoots":["~/dev"]}"#)

    let service = makeServiceReadingStoredSettings(temp: temp, runner: RecordingProcessRunner())
    let forged = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects,
        path: root, name: "dev", sizeBytes: 1)
    let record = await service.clean(items: [forged], now: now, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: root))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
}

/// A pinned project written with a tilde. The pin is compared against
/// `DiscoveredProject.path`, which is always absolute, so `~/dev/stale` used to match no
/// project at all — "keep this one whatever happens" turning silently into "offer its build
/// output", which is the exact outcome pinning exists to prevent.
@Test func aHandEditedTildePinProtectsTheProjectItNames() async throws {
    let temp = TempDir()
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")
    temp.makeFile("settings.json", contents: """
    {"projectRoots":["~/dev"],"pinnedProjectPaths":["~/dev/stale"]}
    """)

    let result = await makeServiceReadingStoredSettings(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [staleBuild: 2_000_000_000]
    ).scan(now: now)

    // A protected project gets the summary row named after the project itself; a
    // deletable one gets a `build` row with the project name as its detail.
    let stale = try #require(result.items(in: .projects).first { $0.name == "stale" })
    #expect(stale.isDeletable == false)
    let reason = try #require(stale.protection)
    #expect(reason == .pinnedProject)
}

// MARK: - the brief's end-to-end cases

@Test func scanProtectsARecentlyChangedProjectEndToEnd() async throws {
    let temp = TempDir()
    temp.makeFile("dev/active/pubspec.yaml", modified: now.addingTimeInterval(-86_400))
    let activeBuild = temp.makeDirectory("dev/active/build")
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")

    let result = try await makeService(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [activeBuild: 3_000_000_000, staleBuild: 2_000_000_000]
    ).scan(now: now)

    let projectItems = result.items(in: .projects)
    #expect(projectItems.first { $0.name == "active" }?.isDeletable == false)
    #expect(projectItems.first { $0.detail == "stale" }?.isDeletable == true)
    #expect(result.reclaimableBytes == 2_000_000_000)
    // The protected project keeps its row, carrying what it is holding, so "where did my
    // 3 GB go?" has an answer.
    let kept = try #require(projectItems.first { $0.name == "active" })
    #expect(kept.sizeBytes == 3_000_000_000)
}

@Test func skippedScannerIsHonouredEndToEnd() async throws {
    let temp = TempDir()
    temp.makeDirectory(".pub-cache/hosted")

    let service = try makeService(temp: temp, runner: FakeProcessRunner(responses: [:])) {
        $0.alwaysSkipScannerIDs = ["flutter.pubCache"]
    }
    let result = await service.scan(now: now)

    #expect(result.skippedScannerIDs.contains("flutter.pubCache"))
    #expect(result.items.allSatisfy { $0.scannerID != "flutter.pubCache" })
}

@Test func cleanTrashesSelectedItemsAndWritesTheRunLog() async throws {
    let temp = TempDir()
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")

    let service = try makeService(temp: temp, runner: RecordingProcessRunner(),
                                  sizes: [staleBuild: 2_000_000_000])
    let scan = await service.scan(now: now)
    let record = await service.clean(items: scan.defaultSelection, now: now, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: staleBuild))
    #expect(record.trashedCount == 1)
    #expect(record.trashedBytes == 2_000_000_000)
    #expect(RunLog(directory: temp.url.appendingPathComponent("runs")).recent().count == 1)
    // The stored run is readable, and the service reads it back the same way the history
    // window will.
    let stored = try #require(service.recentRuns().first)
    #expect(stored.trashedBytes == 2_000_000_000)
    #expect(stored.startedAt == now)
    #expect(stored.finishedAt == finished)
}

@Test func settingsCanSwitchTheWholeRunToPermanentDeletion() async throws {
    let temp = TempDir()
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")

    let service = try makeService(temp: temp, runner: RecordingProcessRunner(),
                                  sizes: [staleBuild: 2_000_000_000]) { $0.moveToTrash = false }
    let scan = await service.scan(now: now)
    let record = await service.clean(items: scan.defaultSelection, now: now, progress: { _ in })

    #expect(record.trashedCount == 0)
    #expect(record.deletedCount == 1)
}

@Test func cleanRefusesAnItemPointingAtAProjectDirectory() async throws {
    let temp = TempDir()
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let projectPath = temp.path + "/dev/stale"

    let service = try makeService(temp: temp, runner: RecordingProcessRunner())
    let forged = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects,
        path: projectPath, name: "stale", sizeBytes: 1)

    let record = await service.clean(items: [forged], now: now, progress: { _ in })
    #expect(FileManager.default.fileExists(atPath: projectPath))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
}

@Test func progressCountsThroughTheItemsTheServiceWasGiven() async throws {
    let temp = TempDir()
    let one = temp.makeDirectory(".gradle/caches/build-cache-1")
    let two = temp.makeDirectory(".gradle/daemon")

    let service = try makeService(temp: temp, runner: RecordingProcessRunner(),
                                  sizes: [one: 10, two: 20])
    let scan = await service.scan(now: now)
    let reported = Reported()
    _ = await service.clean(items: scan.defaultSelection, now: now) { progress in
        reported.add(progress)
    }

    #expect(reported.values.map(\.completed) == [1, 2])
    #expect(reported.values.allSatisfy { $0.total == 2 })
}

/// Collects progress callbacks. A class with a lock rather than an actor because the
/// callback is synchronous and cannot await.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ExecutionProgress] = []
    func add(_ progress: ExecutionProgress) {
        lock.lock(); collected.append(progress); lock.unlock()
    }
    var values: [ExecutionProgress] {
        lock.lock(); defer { lock.unlock() }; return collected
    }
}

// MARK: - composition: the SDK, the protection, the clock

/// The executor has to be given the same Android SDK the scan used. With the default one
/// instead, the guard has no root covering this NDK and the row is refused after the user
/// ticked it — the app reports success and frees nothing.
@Test func theExecutorIsGivenTheSameAndroidSDKTheScanUsed() async throws {
    let temp = TempDir()
    let sdk = temp.path + "/elsewhere/android-sdk"
    let ndk = temp.makeDirectory("elsewhere/android-sdk/ndk/27.0.12077973")

    let service = try makeService(temp: temp, runner: RecordingProcessRunner(),
                                  sizes: [ndk: 3_000_000_000], androidSDKPath: sdk)
    let scan = await service.scan(now: now)
    let chosen = try #require(scan.items.first { $0.scannerID == "android.ndk" })
    let record = await service.clean(items: [chosen], now: now, progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(!FileManager.default.fileExists(atPath: ndk))
}

@Test func protectionSummaryReportsWhatTheScanUsed() async throws {
    let temp = TempDir()
    temp.makeFile("dev/active/pubspec.yaml", modified: now.addingTimeInterval(-86_400))
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))

    let service = try makeService(temp: temp, runner: FakeProcessRunner(responses: [:]))
    let protection = await service.protectionSummary(now: now)

    #expect(protection.projects[temp.path + "/dev/active"]
            == .recentActivity(days: 14))
    #expect(protection.projects[temp.path + "/dev/stale"] == nil)
}

/// `makeDefault()` must not create `~/Library/Application Support/DevCleaner`. Building the
/// service is what an app does at launch, and a folder appearing before the user has
/// changed a single setting is a folder nobody asked for.
@Test func makeDefaultCreatesNothingOnDisk() {
    let directory = SettingsStore.defaultDirectory()
    let existedBefore = FileManager.default.fileExists(atPath: directory.path)
    _ = CleanerService.makeDefault()
    #expect(FileManager.default.fileExists(atPath: directory.path) == existedBefore)
}

/// A run whose record cannot be stored says so in the record. The stored file holds the
/// only copy of every `trashedTo` path, so a silent failure turns a recoverable delete into
/// a permanent one from the user's side.
@Test func aRunThatCouldNotBeLoggedSaysSoInsteadOfSwallowingIt() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory(".gradle/daemon")
    // A plain file where the log directory should be, so creating it fails.
    temp.makeFile("runs", contents: "not a directory")

    let service = try makeService(temp: temp, runner: RecordingProcessRunner(),
                                  sizes: [target: 1_000])
    let scan = await service.scan(now: now)
    let record = await service.clean(items: scan.defaultSelection, now: now, progress: { _ in })

    #expect(record.trashedCount == 1)
    #expect(record.notes.contains { $0.hasPrefix(CleanerService.runLogNotWritten) })
}

// MARK: - what the interface has to say

/// Note 8. `simctl delete` and `avdmanager delete` have no Trash and no undo, and the
/// warning has to be said before the run, not discovered after it. "Normally", not
/// "always": the avdmanager-missing fallback really does use the Trash.
@Test func theWarningBeforeARunSaysDeviceRemovalIsNormallyPermanent() {
    let simulator = CleanupItem(
        id: "ios.simulators|UDID-1", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone 17", detail: nil, sizeBytes: 12_860_000_000, lastUsed: nil,
        risk: .safe, protection: nil, method: .deleteSimulator(udid: "UDID-1"))

    let warnings = CleanerService.warnings(for: [simulator], moveToTrash: true)
    #expect(warnings.contains(CleanerService.Warning.devicesAreRemovedPermanently))
    #expect(CleanerService.Warning.devicesAreRemovedPermanently.contains("normally"))
    // No path row is selected, so the Trash sentence would be false here.
    #expect(!warnings.contains(CleanerService.Warning.trashingDoesNotFreeSpaceYet))
}

@Test func noPermanenceWarningWhenOnlyPathsAreSelected() {
    let warnings = CleanerService.warnings(
        for: [row("build", path: "/tmp/build", size: 10)], moveToTrash: true)
    #expect(warnings == [CleanerService.Warning.trashingDoesNotFreeSpaceYet])
}

@Test func noTrashWarningInPermanentMode() {
    let warnings = CleanerService.warnings(
        for: [row("build", path: "/tmp/build", size: 10)], moveToTrash: false)
    #expect(warnings.isEmpty)
}

/// A protected device is refused by the executor, so it must not raise a warning about a
/// permanence that is never going to happen.
@Test func aProtectedDeviceRaisesNoPermanenceWarning() {
    let kept = CleanupItem(
        id: "ios.simulators|UDID-1", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone 17", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .safe,
        protection: .mostRecentlyUsedDevice, method: .deleteSimulator(udid: "UDID-1"))
    #expect(CleanerService.warnings(for: [kept], moveToTrash: true).isEmpty)
}

/// Note 7. Trashed bytes, permanently deleted bytes and the free-space change are three
/// different numbers. A real run trashed 6.15 GB and moved free space by 60 MB, because the
/// Trash still held it; merging them tells the user emptying the Trash will do nothing.
@Test func trashedDeletedAndFreeSpaceAreThreeSeparateNumbers() {
    let record = RunRecord(
        startedAt: now, finishedAt: finished,
        availableBytesBefore: 100_000_000_000,
        availableBytesAfter: 100_060_000_000,
        entries: [
            RunEntry(itemID: "a", name: "build", target: "/tmp/a", sizeBytes: 6_150_000_000,
                     outcome: .trashed, trashedTo: "/Users/tester/.Trash/build"),
            RunEntry(itemID: "b", name: "iPhone 17", target: "UDID-1",
                     sizeBytes: 12_860_000_000, outcome: .deleted),
        ])

    #expect(record.trashedBytes == 6_150_000_000)
    #expect(record.permanentlyDeletedBytes == 12_860_000_000)
    #expect(record.freeSpaceChangeBytes == 60_000_000)
    #expect(record.permanentlyDeletedEntries.map(\.name) == ["iPhone 17"])
    #expect(record.entries.filter(\.isRestorable).map(\.name) == ["build"])
}

/// Note 6. `.skipped` on its own tells the user nothing. The reason names `adb` and where
/// it was looked for, so the fix is "install platform-tools, then run again", and it has to
/// survive the trip through the service.
@Test func anEmulatorSkippedBecauseAdbCannotBeReachedCarriesTheReasonToTheCaller() async throws {
    let temp = TempDir()
    // Deliberately not the default `~/Library/Android/sdk`. The reason has to name the adb
    // the service was configured with, or a machine whose SDK is elsewhere is told to fix
    // a path it does not have.
    let sdk = temp.path + "/elsewhere/android-sdk"
    let runner = RunnerWithAMissingBinary(missing: sdk + "/platform-tools/adb")

    let service = try makeService(temp: temp, runner: runner, androidSDKPath: sdk)
    let emulator = CleanupItem(
        id: "android.avds|Pixel_9", scannerID: "android.avds", group: .android,
        name: "Pixel_9", detail: nil, sizeBytes: 8_000_000_000, lastUsed: nil,
        risk: .safe, protection: nil, method: .deleteAVD(name: "Pixel_9"))

    let record = await service.clean(items: [emulator], now: now, progress: { _ in })

    #expect(record.skippedCount == 1)
    let skipped = try #require(record.skippedEntries.first)
    let reason = try #require(skipped.reason)
    #expect(reason.contains("adb"))
    #expect(reason.contains(sdk + "/platform-tools/adb"))
    #expect(reason.contains("cannot be undone"))
    #expect(record.unfinishedReasons == ["Pixel_9: " + reason])
    // Nothing was removed, and nothing claims to have been.
    #expect(record.trashedBytes == 0)
    #expect(record.permanentlyDeletedBytes == 0)
}

@Test func aFailedRowAlsoReachesTheCallerWithItsReason() async throws {
    let temp = TempDir()
    let service = try makeService(temp: temp, runner: RecordingProcessRunner())
    let outside = ScanHelpers.item(
        scannerID: "other.libraryCaches", group: .otherCaches,
        path: temp.path + "/nowhere/thing", name: "thing", sizeBytes: 1)

    let record = await service.clean(items: [outside], now: now, progress: { _ in })
    #expect(record.failedCount == 1)
    let reason = try #require(record.failedEntries.first?.reason)
    #expect(!reason.isEmpty)
    #expect(record.unfinishedReasons.count == 1)
}

// MARK: - decoding a document written by another build

/// Note 9. `Settings`, `CleanupItem` and `RunRecord` have each hit this bug once. Every
/// field added since is read with `decodeIfPresent`, and this fails the moment one is not.
@Test func aCachedScanMissingTheNewestFieldStillLoads() throws {
    let full = ScanResult(
        items: [row("a", path: "/tmp/a", size: 100)], generatedAt: now,
        availableBytes: 42, skippedScannerIDs: ["flutter.fvm"],
        ignoredProjectRoots: ["/Users/tester"])
    let data = try JSONEncoder().encode(full)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "ignoredProjectRoots")
    let stripped = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ScanResult.self, from: stripped)
    #expect(decoded.ignoredProjectRoots.isEmpty)
    #expect(decoded.items.count == 1)
    #expect(decoded.availableBytes == 42)
    #expect(decoded.skippedScannerIDs == ["flutter.fvm"])
    #expect(decoded.reclaimableBytes == 100)
}

@Test func aCachedScanWithOnlyItsTimestampDecodesToDefaults() throws {
    let data = try JSONEncoder().encode(
        ScanResult(items: [], generatedAt: now, availableBytes: 0, skippedScannerIDs: []))
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["items", "availableBytes", "skippedScannerIDs", "ignoredProjectRoots"] {
        object.removeValue(forKey: key)
    }
    let decoded = try JSONDecoder()
        .decode(ScanResult.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.generatedAt == now)
    #expect(decoded.items.isEmpty)
    #expect(decoded.availableBytes == 0)
    #expect(decoded.skippedScannerIDs.isEmpty)
    #expect(decoded.ignoredProjectRoots.isEmpty)
}

@Test func aCleanupItemMissingEverySoftKeyStillDecodes() throws {
    let item = row("ndk", path: "/tmp/ndk", size: 5, startsUnticked: true, sizeMayBeShared: true)
    let data = try JSONEncoder().encode(item)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["startsUnticked", "sizeMayBeShared", "detail", "lastUsed", "protection"] {
        object.removeValue(forKey: key)
    }
    let decoded = try JSONDecoder()
        .decode(CleanupItem.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(!decoded.startsUnticked)
    #expect(!decoded.sizeMayBeShared)
    #expect(decoded.selectedByDefault)
    #expect(decoded.sizeBytes == 5)
    #expect(decoded.method == .removePath("/tmp/ndk"))
}

@Test func sizeMayBeSharedSurvivesTheRoundTrip() throws {
    let item = row("pnpm store", path: "/tmp/pnpm", size: 5, sizeMayBeShared: true)
    let decoded = try JSONDecoder().decode(
        CleanupItem.self, from: try JSONEncoder().encode(item))
    #expect(decoded.sizeMayBeShared)
    #expect(decoded == item)
}

/// One unreadable row costs that row, not the whole cached scan.
@Test func aCachedScanWithOneUnreadableRowKeepsTheOthers() throws {
    let full = ScanResult(items: [
        row("a", path: "/tmp/a", size: 100),
        row("b", path: "/tmp/b", size: 200),
    ], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])
    let data = try JSONEncoder().encode(full)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var rows = try #require(object["items"] as? [[String: Any]])
    #expect(rows.count == 2)
    rows[0].removeValue(forKey: "id")
    object["items"] = rows

    let decoded = try JSONDecoder()
        .decode(ScanResult.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.items.map(\.name) == ["b"])
    #expect(decoded.reclaimableBytes == 200)
}
