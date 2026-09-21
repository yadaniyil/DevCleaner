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
@Test func theRegistryHoldsExactlyTheseTwentyThreeIdentifiers() {
    #expect(Set(CleanerService.scannerIDs) == [
        "xcode.derivedData", "xcode.archives", "xcode.deviceSupport",
        "ios.simulators", "ios.runtimes", "ios.simulatorCaches",
        "android.avds", "android.systemImages", "android.ndk", "android.gradle",
        "flutter.pubCache", "flutter.fvm",
        "projects.buildOutput",
        "other.cocoapods", "other.jsPackages", "other.localToolCaches",
        "other.libraryCaches", "other.appCaches", "other.xdgCache",
        "other.electronCaches",
        "big.downloads", "big.aiModels", "big.largeFiles",
    ])
    // The plan said fifteen. `android.ndk` arrived after it was written, and counting is
    // what catches the next one being added to the package but not to this list.
    #expect(CleanerService.allScanners().count == 23)
}

/// The order the listing prints, and the group each row lands in. Order is part of the
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
        ("other.appCaches", .otherCaches),
        ("other.xdgCache", .otherCaches),
        ("other.electronCaches", .otherCaches),
        ("big.downloads", .bigThings),
        ("big.aiModels", .bigThings),
        // Last of all, which is where the deck's interstitial and the "biggest first"
        // ordering of the big things both expect to find it.
        ("big.largeFiles", .bigThings),
    ]
    #expect(listed.map(\.0) == expected.map(\.0))
    #expect(listed.map(\.1) == expected.map(\.1))
}

/// The declaration the deck reads to decide whether a scanner is one card or one card each,
/// checked **against the registry** so it cannot fall behind it.
///
/// Three scanners differ from the default, and each of them because its rows are unrelated
/// to one another: a user may want `~/.cache/uv` gone and `~/.cache/pre-commit` kept, and
/// a 7 GB installer in `~/Downloads` has nothing to do with the video beside it. Every
/// other scanner's rows are one decision — all sixteen simulators, all twenty-two derived
/// data folders — and one card is the question.
@Test func exactlyThreeScannersAreDealtOneCardPerRow() {
    let perItem = CleanerService.allScanners()
        .filter { $0.deckDealing == .perItem }
        .map(\.id)
    #expect(perItem == ["other.xdgCache", "big.downloads", "big.aiModels"])
    // Read back through the lookup as well, which is where the deck asks: a declaration the
    // registry has and `scannerInfo` drops would deal these as one all-or-nothing card.
    for scanner in CleanerService.allScanners() {
        #expect(CleanerService.scanner(withID: scanner.id)?.dealing == scanner.deckDealing,
                "\(scanner.id)")
    }
    // Rule 4: a fixture where everything agreed could not tell the two values apart.
    #expect(CleanerService.scanner(withID: "xcode.derivedData")?.dealing == .grouped)
    #expect(CleanerService.scanner(withID: "big.downloads")?.dealing == .perItem)
}

/// **Exactly two scanners are dealt no card at all**, and both of them also refuse to be
/// ticked. The two halves are independent and both are needed.
///
/// `DeckDealing.mentionOnly` decides what the window *draws* — no card, a line on the end
/// card instead — and nothing that deletes has ever heard of it. What keeps these rows out
/// of `ScanResult.defaultSelection`, `CleanerService.cleanDefault`, `devcleaner clean` and
/// the status panel's amount is `CleanupItem.startsUnticked`, on every row, which is why it
/// is asserted here beside the declaration rather than only in the scanner's own file: a
/// scanner that declared one without the other would either be silently cleanable or
/// silently invisible.
@Test func exactlyTwoScannersAreMentionedRatherThanDealtAndNeitherIsEverTicked() async {
    let mentionOnly = CleanerService.allScanners()
        .filter { $0.deckDealing == .mentionOnly }
        .map(\.id)
    #expect(mentionOnly == ["other.appCaches", "other.electronCaches"])
    for id in mentionOnly {
        #expect(CleanerService.scanner(withID: id)?.dealing == .mentionOnly, "\(id)")
    }

    // And the rows themselves, from the real scanners over real fixtures.
    let temp = TempDir()
    let brave = temp.makeDirectory("Library/Caches/BraveSoftware")
    let slack = temp.makeDirectory("Library/Application Support/Slack/Cache")
    let context = ScanContext(
        settings: .makeDefault(home: temp.path), protection: .empty, projects: [],
        devices: .empty, home: temp.path, androidSDKPath: temp.path + "/sdk",
        sizeMeasurer: FixedSizeMeasurer([brave: 3_200_000_000, slack: 1_300_000_000]),
        runner: FakeProcessRunner(responses: [:]), fileManager: .default,
        now: Date(timeIntervalSince1970: 1_786_000_000))
    let rows = await AppCacheScanner().scan(context)
        + ElectronCacheScanner().scan(context)

    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.startsUnticked })
    #expect(rows.allSatisfy { !$0.selectedByDefault })
    // Deletable all the same, which is the distinction: nothing is *protecting* these, the
    // app has simply decided not to be the thing that removes them.
    #expect(rows.allSatisfy { $0.isDeletable })
}

/// **Exactly one scanner is dealt as a checklist**, and like every other big thing its rows
/// are never ticked. The two halves are independent and both are needed.
///
/// `DeckDealing.checklist` decides what the window *draws* — one card, a checkbox per row —
/// and nothing that deletes has ever heard of it. What keeps these rows out of
/// `ScanResult.defaultSelection`, `CleanerService.cleanDefault`, `devcleaner clean` and the
/// status panel's amount is `CleanupItem.startsUnticked` on every row, which is why it is
/// asserted here beside the declaration: the page's ticks start all-on, and a scanner that
/// declared the card without the engine-level rule would hand a default clean somebody's
/// films the first time anything called `cleanDefault`.
@Test func exactlyOneScannerIsDealtAsAChecklistAndItsRowsAreNeverTicked() async {
    let checklists = CleanerService.allScanners()
        .filter { $0.deckDealing == .checklist }
        .map(\.id)
    #expect(checklists == ["big.largeFiles"])
    // Read back through the lookup as well, which is where the deck asks: a declaration the
    // registry has and `scannerInfo` drops would deal fifty unrelated files as one
    // all-or-nothing card with a button over the lot.
    #expect(CleanerService.scanner(withID: "big.largeFiles")?.dealing == .checklist)
    #expect(CleanerService.scanner(withID: "big.largeFiles")?.title == "Large files")

    // And the rows themselves, from the real scanner over a real file.
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/holiday.mov", bytes: 1_700_000_000)
    let rows = await LargeFilesScanner().scan(ScanContext(
        settings: .makeDefault(home: temp.path), protection: .empty, projects: [],
        devices: .empty, home: temp.path, androidSDKPath: temp.path + "/sdk",
        sizeMeasurer: FixedSizeMeasurer([:]),
        runner: FakeProcessRunner(responses: [
            commandKey("/usr/bin/mdfind",
                       ["-onlyin", temp.path, LargeFilesScanner.spotlightQuery]):
                ProcessResult(exitCode: 0, stdout: film, stderr: ""),
        ]),
        fileManager: .default, now: now))

    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.startsUnticked })
    #expect(rows.allSatisfy { !$0.selectedByDefault })
    // Deletable all the same, which is the distinction: nothing is *protecting* these, the
    // app simply refuses to be the thing that decides.
    #expect(rows.allSatisfy { $0.isDeletable })
}

/// Every big-things scanner carries its identifier as a static, because the deck and the
/// tests recognise those rows by it and the strings are also persisted in
/// `Settings.alwaysSkipScannerIDs`.
@Test func theBigThingsScannersCarryTheirIdentifiersAsStatics() {
    #expect(DownloadsScanner.scannerID == "big.downloads")
    #expect(DownloadsScanner().id == DownloadsScanner.scannerID)
    #expect(AIModelScanner.scannerID == "big.aiModels")
    #expect(AIModelScanner().id == AIModelScanner.scannerID)
    #expect(LargeFilesScanner.scannerID == "big.largeFiles")
    #expect(LargeFilesScanner().id == LargeFilesScanner.scannerID)
    #expect(XDGCacheScanner.scannerID == "other.xdgCache")
    #expect(XDGCacheScanner().id == XDGCacheScanner.scannerID)
}

/// The lookup the main window's tool cards are titled from, checked **against the registry**
/// rather than against a list written here.
///
/// A card is one scanner, and its heading is that scanner's title — which a `ScanResult` row
/// does not carry. Built from `allScanners()`, the lookup cannot fall behind the registry the
/// way a hand-written list of fifteen fell behind `android.ndk`; this is the test that says
/// so, entry by entry.
@Test func everyRegisteredScannerCanBeLookedUpByItsID() {
    for scanner in CleanerService.allScanners() {
        let info = CleanerService.scanner(withID: scanner.id)
        #expect(info?.id == scanner.id, "\(scanner.id)")
        #expect(info?.title == scanner.title, "\(scanner.id)")
        #expect(info?.group == scanner.group, "\(scanner.id)")
    }
    #expect(CleanerService.scannerInfo.count == CleanerService.allScanners().count)
    // Two of the titles in full, so a reworded scanner shows up as a failing card heading
    // rather than silently changing what the window says.
    #expect(CleanerService.scanner(withID: "xcode.derivedData")?.title == "Derived data")
    #expect(CleanerService.scanner(withID: "ios.simulators")?.title == "iOS simulators")
}

/// `nil`, not a guess. A `cache.json` written by a build with a scanner this one does not
/// have is read back rather than discarded, so an interface can be handed an identifier that
/// is in no registry — and it has to answer with something visible instead of dropping the
/// rows.
@Test func anUnknownScannerIdentifierIsNotInTheLookup() {
    #expect(CleanerService.scanner(withID: "xcode.somethingNewer") == nil)
    #expect(CleanerService.scanner(withID: "") == nil)
}

/// The derived data scanner's identifier is a static, because the deck reads it to decide
/// whether to shorten a row's name, and the string is also persisted in
/// `Settings.alwaysSkipScannerIDs`.
@Test func theDerivedDataScannerCarriesItsIdentifierAsAStatic() {
    #expect(DerivedDataScanner.scannerID == "xcode.derivedData")
    #expect(DerivedDataScanner().id == DerivedDataScanner.scannerID)
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
    #expect(declared.count == 23)
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

// MARK: - the large-files licence, end to end

/// Over `LargeFileLicence.minimumBytes`, so a fixture only has to say "large".
private let large: Int64 = 1_700_000_000

/// A row shaped exactly as `LargeFilesScanner` shapes one, for a path of the caller's
/// choosing.
///
/// Hand-built rather than scanned, because that is the thing under test: the deck hands
/// `clean(items:)` a list of rows, and the licence has to be re-earned from **the row** —
/// whatever produced it, however long ago, whatever is at that path now.
private func largeFileRow(_ path: String, scanner: String = LargeFilesScanner.scannerID)
    -> CleanupItem {
    ScanHelpers.item(
        scannerID: scanner, group: .bigThings, path: path,
        name: (path as NSString).lastPathComponent, sizeBytes: large,
        risk: .irreplaceable, startsUnticked: true)
}

/// The path a row names after the scanner has canonicalised it — a `TempDir` lives under
/// `/var/folders`, and `/var` is a symlink to `/private/var`.
private func canonical(_ path: String) -> String {
    PathGuard.canonicaliseKeepingLeaf(path) ?? path
}

/// **The licence works, and it is the only thing that admits one of these paths.**
///
/// The positive control is the discriminating half. `~/Documents` is under no
/// `PathGuard.forRun` root and never will be — that is the whole design of this feature —
/// so the film is removed *only* because its row earned an exact path back, while every
/// refusal below is the same guard with the same roots saying no. Without the film in the
/// same run, a licence that granted nothing at all would pass every other assertion here.
@Test func aLargeFileIsRemovedBecauseItsOwnRowEarnedTheLicenceAndNothingElse() async throws {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/lesson 26.mp4", bytes: large)
    let service = try makeService(temp: temp, runner: RecordingProcessRunner())

    let record = await service.clean(
        items: [largeFileRow(film)], now: now, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: film))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    // The path the guard approved, which is the canonical one — the only string it is safe
    // to act on.
    #expect(entry.target == canonical(film))
    #expect(record.trashedBytes == large)
    #expect(record.failedCount == 0)
    // And the home folder did not become a root on the way: the film's own sibling, which
    // no row named, is still refused.
    let sibling = temp.makeFile("Documents/films/keep this.mp4", bytes: large)
    let second = await service.clean(
        items: [largeFileRow(sibling, scanner: "projects.buildOutput")],
        now: now, progress: { _ in })
    #expect(FileManager.default.fileExists(atPath: sibling))
    #expect(second.failedCount == 1)
}

/// **The rules that are about where the file is**, each one refused through the real
/// service with the real guard.
///
/// One run, so the record itself says the licence is per file: the film in `~/Documents`
/// goes, and the five rows beside it — every one of them naming a real file over the floor,
/// every one of them handed over under this scanner's own identifier — fail. A licence
/// derived from anything coarser than the single path would have taken at least one of them
/// with it.
@Test func theLicenceRefusesLibraryHiddenPackagedAndForeignPathsThroughAWholeClean()
    async throws {
    let temp = TempDir()
    let outside = TempDir()

    let film = temp.makeFile("Documents/films/lesson 26.mp4", bytes: large)
    // `~/Library` is the machine's, not the user's — and `Application Support` is where
    // this app's own `settings.json`, `cache.json` and run log live. Deliberately not a
    // path under `Library/Caches`, which really is a `PathGuard.forRun` root for three
    // other scanners: this test is about the licence, so it names somewhere no root covers.
    let mail = temp.makeFile("Library/Mail/V10/big.mbox", bytes: large)
    // A hidden component is somebody's tool state, and `~/.Trash` is a list of things the
    // user has already thrown away.
    let trashed = temp.makeFile(".Trash/already-thrown-away.mov", bytes: large)
    // A frame inside a Photos library is not a file the user can answer about: removing it
    // corrupts the library rather than freeing space they chose to give up.
    let framed = temp.makeFile(
        "Pictures/Photos Library.photoslibrary/originals/0/IMG.mov", bytes: large)
    let payload = temp.makeFile(
        "Applications/Dictation.app/Contents/Resources/model.bin", bytes: large)
    // Not under this home at all. `mdfind` is told `-onlyin <home>` and still its output is
    // untrusted, and a row is more untrusted than that.
    let someoneElses = outside.makeFile("someone-elses.mov", bytes: large)

    let refused = [mail, trashed, framed, payload, someoneElses]
    let service = try makeService(temp: temp, runner: RecordingProcessRunner())

    let record = await service.clean(
        items: [largeFileRow(film)] + refused.map { largeFileRow($0) },
        now: now, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: film))
    for path in refused {
        #expect(FileManager.default.fileExists(atPath: path), "\(path)")
    }
    #expect(record.failedCount == refused.count)
    #expect(record.trashedBytes == large)
    // Refused by the guard, in the guard's own words, rather than by something downstream
    // that happened to fail. An exact allowance is the only thing that could have admitted
    // any of these, and none of them earned one.
    for entry in record.entries.dropFirst() {
        #expect(entry.outcome == .failed, "\(entry.name)")
        #expect(entry.reason?.contains("is not inside an allowed root") == true,
                "\(entry.name)")
    }
}

/// **The rules that are about what is at the path now.**
///
/// The scan is minutes old by the time anybody presses a button, and this is the case the
/// per-file licence exists for: the row still says "1.7 GB film", and on disk the path is a
/// directory, or a symlink into somebody's photo library, or a file that has been truncated
/// to nothing. Each swap happens **after** the row is built, so the row is exactly what an
/// honest scan produced and the refusal can only come from re-reading the disk.
@Test func theLicenceIsReEarnedAgainstTheDiskSoASwappedOrShrunkPathIsRefused() async throws {
    let temp = TempDir()
    let keeper = temp.makeFile("Pictures/wedding.mov", bytes: large)

    // Three honest rows, built while three real files over the floor were there.
    let swappedForADirectory = temp.makeFile("Documents/a.mov", bytes: large)
    let swappedForALink = temp.makeFile("Documents/b.mov", bytes: large)
    let shrunk = temp.makeFile("Documents/c.mov", bytes: large)
    let survivor = temp.makeFile("Documents/d.mov", bytes: large)
    let rows = [swappedForADirectory, swappedForALink, shrunk, survivor]
        .map { largeFileRow($0) }

    // A directory: removing it would be a whole tree gone for a row that claimed to be one
    // file.
    try FileManager.default.removeItem(atPath: swappedForADirectory)
    temp.makeFile("Documents/a.mov/inside/keep.txt", contents: "kept")
    // A symlink: its size is its target's, while trashing it frees nothing at all — and the
    // guard accepts a symlink at the leaf, so the licence is the only thing standing
    // between this row and the wedding video.
    try FileManager.default.removeItem(atPath: swappedForALink)
    temp.makeSymlink("Documents/b.mov", to: keeper)
    // Truncated since the scan: the row is describing something that no longer exists.
    guard truncate(shrunk, 12) == 0 else { fatalError("could not shrink \(shrunk)") }

    let service = try makeService(temp: temp, runner: RecordingProcessRunner())
    let record = await service.clean(items: rows, now: now, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: swappedForADirectory + "/inside/keep.txt"))
    // The link is still a link, and what it points at is untouched.
    #expect(FileManager.default.fileExists(atPath: swappedForALink))
    #expect(FileManager.default.fileExists(atPath: keeper))
    #expect(FileManager.default.fileExists(atPath: shrunk))
    // The one row that still describes what is there went, so this is not a clean that
    // refused everything.
    #expect(!FileManager.default.fileExists(atPath: survivor))
    #expect(record.failedCount == 3)
    #expect(record.trashedBytes == large)
}

/// A row earns the licence **only** under this scanner's identifier.
///
/// Both rows name the same real file over the floor in the same place, and the only thing
/// that differs is `scannerID`. A forged row naming somebody's `~/Documents` under
/// `projects.buildOutput` is refused exactly as it was before this feature existed — the
/// licence added one path for one row and nothing about the identifier is cosmetic.
@Test func onlyTheLargeFilesScannersOwnIdentifierEarnsTheLicenceInAWholeClean() async throws {
    let temp = TempDir()
    let taxes = temp.makeFile("Documents/taxes 2025.pdf", bytes: large)
    let service = try makeService(temp: temp, runner: RecordingProcessRunner())

    let forged = await service.clean(
        items: [largeFileRow(taxes, scanner: "projects.buildOutput")],
        now: now, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: taxes))
    #expect(forged.failedCount == 1)
    #expect(forged.entries.first?.reason?.contains("is not inside an allowed root") == true)

    // The same path, the same run guard, this scanner's identifier: removed. Which is what
    // says the refusal above was about the identifier and not about the path.
    let honest = await service.clean(items: [largeFileRow(taxes)], now: now, progress: { _ in })
    #expect(!FileManager.default.fileExists(atPath: taxes))
    #expect(honest.failedCount == 0)
}

/// One of the user's own files goes to the Trash **whatever the setting says**, and it goes
/// under its own name.
///
/// `RiskLevel.irreplaceable` is what overrides permanent mode: there would be nothing
/// anywhere to get a film back from, so the row is trashed or it fails, and it never falls
/// through to a removal the user did not agree to.
///
/// **The name is the less obvious half, and the rename really is a live possibility for
/// these rows.** `ProjectRowPath.trashName` asks only that the path end in `/<name>`, which
/// is true of every file — so it answers "films – lesson 26.mp4" for this one, and a row
/// renamed on its way out would land in the Trash as something the user cannot recognise as
/// theirs. Two independent things refuse it, and the assertion below is worth reading as
/// covering both:
///
/// 1. `Executor.visibleSibling` is scoped to `projects.buildOutput`. That rename exists
///    because a Trash full of folders called `.build` is unreadable; a film already has the
///    name its owner gave it.
/// 2. The licence grants **exact paths only**. The sibling the rename would move to is not
///    one of them and sits under no root, so `visibleSibling`'s own `validate` refuses it
///    and returns "leave it alone" — which is the rule that still holds if anybody ever
///    widens the first one.
@Test func aLargeFileIsTrashedUnderItsOwnNameEvenWhenTheSettingSaysPermanent() async throws {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/lesson 26.mp4", bytes: large)
    let service = try makeService(
        temp: temp, runner: RecordingProcessRunner(),
        settings: { $0.moveToTrash = false })

    let record = await service.clean(items: [largeFileRow(film)], now: now, progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(entry.isRestorable)
    #expect(record.trashedBytes == large)
    #expect(record.permanentlyDeletedBytes == 0)
    // The name the rename would have used, so this test fails rather than passing vacuously
    // if `trashName` ever stops answering for a plain file — which is what would make the
    // assertion below true for the wrong reason.
    #expect(ProjectRowPath.trashName(of: canonical(film), named: "lesson 26.mp4")
            == "films – lesson 26.mp4")
    // `trashedTo` is where the user will be looking, so it has to be the name they know.
    #expect((entry.trashedTo as NSString?)?.lastPathComponent == "lesson 26.mp4")
    // And the warning the interface shows before the run says so, in permanent mode too.
    #expect(service.warnings(for: [largeFileRow(film)])
            == [CleanerService.Warning.trashingDoesNotFreeSpaceYet])
}

/// **No default route ever includes one of these rows**, checked over a real scan.
///
/// Every route in the app that removes something without the user pointing at a row reads
/// `ScanResult.defaultSelection`: `cleanDefault`, which is the only list `devcleaner clean`
/// and `clean --dry-run` ever build, and the status panel's amount, which is
/// `reclaimableBytes`. The ticks the user sees on the checklist page are the window's own,
/// and the engine's answer to all of these is the same: not ticked.
@Test func noDefaultRouteEverTicksALargeFileEndToEnd() async throws {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/lesson 26.mp4", bytes: 582_000_000)
    let gradle = temp.makeDirectory(".gradle/caches/modules-2")
    let service = try makeService(
        temp: temp,
        runner: FakeProcessRunner(responses: [
            commandKey("/usr/bin/mdfind",
                       ["-onlyin", temp.path, LargeFilesScanner.spotlightQuery]):
                ProcessResult(exitCode: 0, stdout: film, stderr: ""),
        ]),
        sizes: [gradle: 1_000_000])

    let scan = await service.scan(now: now)

    let rows = scan.items.filter { $0.scannerID == "big.largeFiles" }
    #expect(rows.map(\.name) == ["lesson 26.mp4"])
    #expect(rows.allSatisfy { $0.isDeletable })
    // The headline is the Gradle cache alone, and so is the group total: a status panel that
    // added the film in would be offering to move it.
    #expect(scan.reclaimableBytes == 1_000_000)
    #expect(scan.reclaimableBytes(in: .bigThings) == 0)
    #expect(scan.untickedDeletableBytes == 582_000_000)
    #expect(scan.defaultSelection.allSatisfy { $0.scannerID != "big.largeFiles" })

    // And the route itself, not just the list it reads: the film is still there afterwards.
    let record = await service.cleanDefault(scan, now: now, progress: { _ in })
    #expect(FileManager.default.fileExists(atPath: film))
    #expect(!FileManager.default.fileExists(atPath: gradle))
    #expect(record.trashedBytes == 1_000_000)
    #expect(!record.entries.contains { $0.target.contains("lesson 26.mp4") })
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
    // data: with no project discovered, nothing is held back at all, so both rows would
    // have come back ticked.
    #expect(projectItems.first { $0.detail?.hasPrefix("active") == true }?.selectedByDefault
            == false)
    #expect(projectItems.first { $0.detail == "stale" }?.selectedByDefault == true)
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

/// The whole rule, end to end through the real `ActivityInspector` and the real resolver:
/// a project touched yesterday is **offered unticked** and one untouched for two hundred
/// days is ticked.
///
/// This test used to assert the active project was not deletable at all. It was changed
/// deliberately, and the reason is in `ProjectBuildOutputScanner`'s own doc comment: on a
/// real dev machine every project holding build output came back "changed in the last 14
/// days", so a window that shows one project at a time and asks about it had nothing left
/// to show. What has to stay true is the number below — a default clean still takes
/// 2 GB and not 5 — because that is the promise the headline makes and the list
/// `cleanDefault` acts on.
@Test func scanOffersARecentlyChangedProjectsFoldersUntickedRatherThanWithholdingThem()
    async throws {
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
    #expect(projectItems.count == 2)
    let active = try #require(projectItems.first { $0.detail?.hasPrefix("active") == true })
    #expect(active.isDeletable)
    #expect(!active.selectedByDefault)
    #expect(active.untickedReason == .recentActivity(days: 14))
    #expect(active.detail == "active · changed in the last 14 days")
    #expect(active.sizeBytes == 3_000_000_000)
    #expect(active.method == .removePath(activeBuild))

    let stale = try #require(projectItems.first { $0.detail == "stale" })
    #expect(stale.selectedByDefault)
    #expect(stale.method == .removePath(staleBuild))

    // The two numbers the listing prints, and the 3 GB is in exactly one of them.
    #expect(result.reclaimableBytes == 2_000_000_000)
    #expect(result.untickedDeletableBytes == 3_000_000_000)
}

/// The tick rule, at the one place it is destructive: a default clean leaves a recently
/// changed project's folders on the disk.
///
/// `cleanDefault` re-derives its list from `ScanResult.defaultSelection` inside the engine,
/// so this is the test that says the softening above did not reach the blind one-click
/// path. It is the same shape as `aDefaultCleanLeavesTheNDKOnDiskAndTakesTheTickedRow`,
/// and for the same reason.
@Test func aDefaultCleanLeavesARecentlyChangedProjectsFoldersOnDisk() async throws {
    let temp = TempDir()
    temp.makeFile("dev/active/pubspec.yaml", modified: now.addingTimeInterval(-86_400))
    let activeBuild = temp.makeDirectory("dev/active/build")
    temp.makeFile("dev/stale/pubspec.yaml", modified: now.addingTimeInterval(-86_400 * 200))
    let staleBuild = temp.makeDirectory("dev/stale/build")
    let service = try makeService(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [activeBuild: 3_000_000_000, staleBuild: 2_000_000_000])
    let result = await service.scan(now: now)

    let record = await service.cleanDefault(result, now: now, progress: { _ in })

    // By identifier rather than by `target`, which is the **canonicalised** path the guard
    // approved — under a `TempDir` that is the `/private/var/…` spelling of the same
    // directory, and comparing the two strings tests `realpath` rather than the tick rule.
    #expect(record.entries.map(\.itemID) == ["projects.buildOutput|\(staleBuild)"])
    #expect(record.trashedBytes == 2_000_000_000)
    #expect(FileManager.default.fileExists(atPath: activeBuild))
    #expect(!FileManager.default.fileExists(atPath: staleBuild))

    // And ticking it by hand is still allowed, which is what the deck's Clean up button
    // does: handed the row explicitly, the engine removes it.
    let active = try #require(result.items.first { $0.method == .removePath(activeBuild) })
    let asked = await service.clean(items: [active], now: now, progress: { _ in })
    #expect(asked.entries.map(\.itemID) == [active.id])
    #expect(asked.trashedBytes == 3_000_000_000)
    #expect(!FileManager.default.fileExists(atPath: activeBuild))
}

/// The composition root already knows when each project last changed — it is what
/// `ProtectionResolver` decides protection on — and until now it threw the answer away
/// once protection was resolved. The deck's "last changed 4 months ago" comes from this
/// wiring, and only an end-to-end scan can see it: the scanner reads
/// `ScanContext.activity`, and a `makeContext` that never fills it in leaves every row
/// dated `nil` with nothing in the scanner's own tests to notice.
@Test func theScanCarriesWhenEachProjectLastChangedOntoItsRows() async throws {
    let temp = TempDir()
    let changed = now.addingTimeInterval(-86_400 * 200)
    temp.makeFile("dev/stale/pubspec.yaml", modified: changed)
    let build = temp.makeDirectory("dev/stale/build")

    let result = try await makeService(
        temp: temp, runner: FakeProcessRunner(responses: [:]),
        sizes: [build: 2_000_000_000]
    ).scan(now: now)

    let row = try #require(result.items(in: .projects).first { $0.detail == "stale" })
    #expect(row.lastUsed == changed)
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
    for key in ["startsUnticked", "sizeMayBeShared", "detail", "lastUsed", "protection",
                "untickedReason"] {
        object.removeValue(forKey: key)
    }
    let decoded = try JSONDecoder()
        .decode(CleanupItem.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(!decoded.startsUnticked)
    #expect(!decoded.sizeMayBeShared)
    #expect(decoded.untickedReason == nil)
    #expect(decoded.selectedByDefault)
    #expect(decoded.sizeBytes == 5)
    #expect(decoded.method == .removePath("/tmp/ndk"))
}

/// `untickedReason` survives a cache round trip, because the cache is what the app opens on:
/// lost in the write, the very next launch would deal a card for a project the user is
/// working in with no caution line on it and nothing saying why there should be one.
@Test func theUntickedReasonSurvivesTheRoundTrip() throws {
    let item = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects,
        path: "/tmp/active/.build", name: ".build", sizeBytes: 3_300_000_000,
        startsUnticked: true, untickedReason: .recentActivity(days: 14))

    let decoded = try JSONDecoder().decode(
        CleanupItem.self, from: try JSONEncoder().encode(item))

    #expect(decoded.untickedReason == .recentActivity(days: 14))
    #expect(decoded.startsUnticked)
    #expect(!decoded.selectedByDefault)
    #expect(decoded.isDeletable)
    #expect(decoded == item)
}

@Test func sizeMayBeSharedSurvivesTheRoundTrip() throws {
    let item = row("pnpm store", path: "/tmp/pnpm", size: 5, sizeMayBeShared: true)
    let decoded = try JSONDecoder().decode(
        CleanupItem.self, from: try JSONEncoder().encode(item))
    #expect(decoded.sizeMayBeShared)
    #expect(decoded == item)
}

/// A `cache.json` holding the cases this wave added loads in this build, whole.
///
/// `GroupID`, `RiskLevel` and `ProtectionReason` are all `Codable`, and a cached scan is
/// read back on the very next launch — so the first thing to check about a new case is that
/// the document it produces is one this build can read. If it were not, the rows would be
/// dropped by the lenient path and the window would open having quietly forgotten 49 GB it
/// had just measured.
@Test func aCachedScanHoldingTheNewGroupRiskAndProtectionLoadsInThisBuild() throws {
    let download = CleanupItem(
        id: "big.downloads|/tmp/Xcode.xip", scannerID: "big.downloads", group: .bigThings,
        name: "Xcode.xip", detail: "An installer. You can usually download it again.",
        sizeBytes: 7_000_000_000, lastUsed: now, risk: .irreplaceable, protection: nil,
        method: .removePath("/tmp/Xcode.xip"), startsUnticked: true)
    let keptSupport = ScanHelpers.item(
        scannerID: "xcode.deviceSupport", group: .xcodeAndIOS,
        path: "/tmp/iPhone17,2 27.0 (24A435)", name: "iOS iPhone17,2 27.0 (24A435)",
        sizeBytes: 7_000_000_000, risk: .elevated, protection: .newestDeviceSupport)
    let full = ScanResult(
        items: [download, keptSupport], generatedAt: now, availableBytes: 42,
        skippedScannerIDs: [])

    let decoded = try JSONDecoder().decode(
        ScanResult.self, from: try JSONEncoder().encode(full))

    #expect(decoded.items.count == 2)
    #expect(decoded.items == [download, keptSupport])
    #expect(decoded.items(in: .bigThings).map(\.risk) == [.irreplaceable])
    #expect(decoded.items.compactMap(\.protection) == [.newestDeviceSupport])
    // And the tick rule survives the round trip, which is the half that matters: a big
    // thing that came back ticked would be in the very next default clean.
    #expect(decoded.defaultSelection.isEmpty)
    #expect(decoded.reclaimableBytes == 0)
}

/// The other direction, which is the one the lenient decode exists for: a document written
/// by a **newer** build, holding a group, a risk or a protection reason this one has never
/// heard of. Each unknown costs its own row and nothing else.
@Test func aCachedScanFromANewerBuildStillCostsOnlyTheRowsThisBuildCannotRead() throws {
    let good = row("uv", path: "/tmp/uv", size: 1_100_000_000, scanner: "other.xdgCache")
    let full = ScanResult(items: [
        row("future", path: "/tmp/future", size: 900_000_000),
        good,
        row("alsoFuture", path: "/tmp/also", size: 800_000_000),
    ], generatedAt: now, availableBytes: 0, skippedScannerIDs: [])
    let data = try JSONEncoder().encode(full)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var rows = try #require(object["items"] as? [[String: Any]])
    #expect(rows.count == 3)
    // A group and a risk from a build that has not been written yet.
    rows[0]["group"] = "somethingNewerStill"
    rows[2]["risk"] = "unrecoverable"
    object["items"] = rows

    let decoded = try JSONDecoder()
        .decode(ScanResult.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.items.map(\.name) == ["uv"])
    #expect(decoded.reclaimableBytes == 1_100_000_000)
    // The case this build *does* know is not confused with an unknown one.
    #expect(GroupID(rawValue: "bigThings") == .bigThings)
    #expect(RiskLevel(rawValue: "irreplaceable") == .irreplaceable)
    #expect(GroupID(rawValue: "somethingNewerStill") == nil)
    #expect(RiskLevel(rawValue: "unrecoverable") == nil)
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
