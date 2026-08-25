import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(temp: TempDir, devices: DeviceInventory = .empty,
                     protection: ProtectionSet = .empty,
                     sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil,
                     settings: Settings? = nil) -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: temp.path), protection: protection, projects: [],
        devices: devices, home: temp.path,
        androidSDKPath: temp.path + "/Library/Android/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

/// The memberwise initialiser has eight arguments and no defaults. `protectedAVDs`
/// defaults to the kept emulator alone, which is what `ProtectionResolver` produces
/// when nothing else is recent enough or close enough to also survive.
private func protection(keptAVD: String?,
                        protectedAVDs: [String: ProtectionReason]? = nil,
                        gradle: [String: ProtectionReason] = [:]) -> ProtectionSet {
    ProtectionSet(
        projects: [:], keptSimulatorUDID: nil, keptAVDName: keptAVD,
        protectedSimulatorUDIDs: [:],
        protectedAVDNames: protectedAVDs ?? keptAVD.map { [$0: .mostRecentlyUsedDevice] } ?? [:],
        flutterVersions: [:], gradleDistributions: gradle, runtimeIdentifiers: [:])
}

private func avd(_ name: String, used: Date?, image: String? = nil) -> AndroidAVD {
    AndroidAVD(name: name, directoryPath: "/avd/\(name).avd",
               lastUsed: used, systemImageRelativePath: image)
}

private func settings(home: String, _ mutate: (inout Settings) -> Void) -> Settings {
    var value = Settings.makeDefault(home: home)
    mutate(&value)
    return value
}

// MARK: AVDs

@Test func offersEveryAVDExceptTheKeptOne() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now,
            image: "system-images/android-34/google_apis/arm64-v8a"),
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 60)),
    ])
    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: "sample_emulator"),
        sizes: ["/avd/sample_emulator.avd": 8_000_000_000,
                "/avd/sample_emulator_1.avd": 6_400_000_000]))

    #expect(items.count == 2)
    let kept = try #require(items.first { $0.name == "sample_emulator" })
    #expect(kept.protection == .mostRecentlyUsedDevice)
    #expect(kept.detail == "the emulator you keep")

    let stale = try #require(items.first { $0.name == "sample_emulator_1" })
    #expect(stale.isDeletable)
    #expect(stale.sizeBytes == 6_400_000_000)
    #expect(stale.method == .deleteAVD(name: "sample_emulator_1"))
}

/// Rule 2: assert the deletion target. `avdmanager delete` takes a name, not a path,
/// so the name inside the method and the identifier are the whole instruction.
@Test func avdItemsCarryTheNameToDeleteAndAnIdentifierThatEmbedsIt() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [avd("sample_avd", used: nil)])
    let items = await AVDScanner()
        .scan(context(temp: temp, devices: devices, protection: protection(keptAVD: nil)))
    let item = try #require(items.first)
    #expect(item.method == .deleteAVD(name: "sample_avd"))
    #expect(item.id == "android.avds|sample_avd")
    #expect(item.group == .android)
}

/// The emulator half of `anOfferedSimulatorIsMarkedElevatedAndSaysWhatDeletingItCosts`.
/// `avdmanager delete avd` has no Trash either, and the row carried `.safe` and no detail.
@Test func anOfferedAVDIsMarkedElevatedAndSaysWhatDeletingItCosts() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now),
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 60)),
    ])
    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: "sample_emulator"),
        sizes: ["/avd/sample_emulator.avd": 8_000_000_000,
                "/avd/sample_emulator_1.avd": 9_200_000_000]))

    let offered = try #require(items.first { $0.name == "sample_emulator_1" })
    #expect(offered.isDeletable)
    #expect(offered.risk == .elevated)
    #expect(ReportText.mark(for: offered) == "!")
    let detail = try #require(offered.detail)
    #expect(detail == AVDScanner.offeredDetail)
    #expect(detail.contains("no Trash and no undo"))

    let kept = try #require(items.first { $0.name == "sample_emulator" })
    #expect(kept.risk == .elevated)
    #expect(ReportText.mark(for: kept) == "-")
}

@Test func neverStartedAVDSaysSoInItsDetail() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [avd("fresh", used: nil)])
    let items = await AVDScanner()
        .scan(context(temp: temp, devices: devices, protection: protection(keptAVD: nil)))
    let item = try #require(items.first)
    #expect(item.detail == "never started · " + AVDScanner.offeredDetail)
    #expect(item.lastUsed == nil)
}

/// The rule the user chose, and the reason this scanner may not read `keptAVDName`
/// alone. `avdmanager delete` has no Trash: an emulator offered by mistake is gone
/// for good, so every emulator started inside the window must be kept.
@Test func everyRecentlyUsedAVDIsProtectedNotOnlyTheNewest() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now),
        avd("sample_avd", used: now.addingTimeInterval(-86_400 * 3)),
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 60)),
    ])

    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices,
        protection: protection(keptAVD: "sample_emulator", protectedAVDs: [
            "sample_emulator": .mostRecentlyUsedDevice,
            "sample_avd": .recentlyUsedDevice(days: 7),
        ])))

    let recent = try #require(items.first { $0.name == "sample_avd" })
    #expect(!recent.isDeletable)
    #expect(recent.protection == .recentlyUsedDevice(days: 7))
    #expect(recent.detail == "used in the last 7 days")

    let winner = try #require(items.first { $0.name == "sample_emulator" })
    #expect(winner.detail == "the emulator you keep")

    #expect(items.filter(\.isDeletable).map(\.name) == ["sample_emulator_1"])
}

/// Decision B: the detail comes from the reason itself, never from a catch-all.
/// A catch-all has to guess why an emulator that is not the kept one survived, and
/// the guess it made — "used at the same moment as the one you keep" — is false for
/// the newest emulator whenever the pin names an older one, which is exactly the
/// case here.
@Test func pinnedAVDSaysItIsPinnedAndTheNewestSaysItIsTheNewest() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 90)),
        avd("sample_emulator", used: now),
    ])

    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices,
        protection: protection(keptAVD: "sample_emulator_1", protectedAVDs: [
            "sample_emulator_1": .pinnedDevice,
            "sample_emulator": .mostRecentlyUsedDevice,
        ])))

    let pinned = try #require(items.first { $0.name == "sample_emulator_1" })
    #expect(pinned.protection == .pinnedDevice)
    #expect(pinned.detail == "pinned in settings")

    let newest = try #require(items.first { $0.name == "sample_emulator" })
    #expect(newest.protection == .mostRecentlyUsedDevice)
    #expect(newest.detail == "most recently used")

    #expect(items.filter(\.isDeletable).isEmpty)
}

/// The same emulators through the real `ProtectionResolver`, so both halves of the
/// guard are pinned together rather than only against a hand-built set.
///
/// Every emulator here is older than `deviceRecentUseDays`, which is the only regime
/// where the two-second tie rule decides anything. A pair dated `now` and `now − 1s`
/// would be protected by the 7-day rule whatever the tie rule did.
@Test func resolverAndAVDScannerTogetherKeepTwoEmulatorsOneSecondApart() async throws {
    let temp = TempDir()
    let old = now.addingTimeInterval(-86_400 * 30)
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: old.addingTimeInterval(-1)),
        avd("sample_emulator", used: old),
        avd("sample_avd", used: now.addingTimeInterval(-86_400 * 60)),
    ])
    let resolved = ProtectionResolver(settings: .makeDefault(home: temp.path))
        .resolve(projects: [], activity: [:], devices: devices, now: now)

    let items = await AVDScanner()
        .scan(context(temp: temp, devices: devices, protection: resolved))

    #expect(items.filter(\.isDeletable).map(\.name) == ["sample_avd"])
    // The emulator the tie rule alone saves. Nothing else in this fixture protects it.
    let twin = try #require(items.first { $0.name == "sample_emulator_1" })
    #expect(twin.protection == .mostRecentlyUsedDevice)
    #expect(twin.detail == "most recently used")
}

/// Rule 6: a non-default window, pinned from both sides of the cutoff. Two fixtures
/// far from the boundary leave `<` versus `<=` free, and the day count the scanner
/// prints has to be the configured one rather than a hard-coded 7.
@Test func theRecentUseCutoffIsInclusiveAndUsesTheConfiguredWindow() async throws {
    let temp = TempDir()
    let configured = settings(home: temp.path) { $0.deviceRecentUseDays = 3 }
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("newest", used: now),
        avd("exactly_at_cutoff", used: now.addingTimeInterval(-86_400 * 3)),
        avd("one_second_older", used: now.addingTimeInterval(-86_400 * 3 - 1)),
    ])
    let resolved = ProtectionResolver(settings: configured)
        .resolve(projects: [], activity: [:], devices: devices, now: now)

    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices, protection: resolved, settings: configured))

    let atCutoff = try #require(items.first { $0.name == "exactly_at_cutoff" })
    #expect(atCutoff.protection == .recentlyUsedDevice(days: 3))
    #expect(atCutoff.detail == "used in the last 3 days")
    #expect(items.filter(\.isDeletable).map(\.name) == ["one_second_older"])
}

/// Rule 9: `sizes(of:)` batches its input and holds four `du` processes open at most,
/// so one call per emulator defeats that cap. Nothing in the items shows it.
@Test func avdsAreMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now),
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 60)),
    ])
    let measurer = CallCountingSizeMeasurer(["/avd/sample_emulator.avd": 8_000_000_000])

    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: nil),
        sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == ["/avd/sample_emulator.avd", "/avd/sample_emulator_1.avd"])
}

@Test func avdScannerIsSilentWhenNoEmulatorsExist() async {
    let temp = TempDir()
    #expect(await AVDScanner().scan(context(temp: temp)).isEmpty)
}

/// The emulator half of `aRuntimeThatCouldNotBeMeasuredIsOfferedButNotTicked`
/// (`SimulatorScannerTests.swift`). `avdmanager delete` is exactly as permanent as
/// `simctl runtime delete` — no Trash, no undo — so an AVD whose size `du` could not
/// measure must not be ticked by default. Reported as 0 bytes it would have been
/// ticked with its real cost hidden: an emulator gone for good while the app showed
/// the user nothing to lose.
@Test func anAVDThatCouldNotBeMeasuredIsOfferedButNotTicked() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 60)),
    ])

    let items = await AVDScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: nil),
        sizeMeasurer: PartialSizeMeasurer([:])))

    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.sizeBytes == 0)
    #expect(item.startsUnticked)
    #expect(!item.selectedByDefault)
    #expect(ReportText.mark(for: item) == " ")
}

// MARK: system images

@Test func systemImageUsedByTheKeptAVDIsProtected() async throws {
    let temp = TempDir()
    let used = temp.makeDirectory("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
    let unused = temp.makeDirectory("Library/Android/sdk/system-images/android-30/default/x86_64")

    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now,
            image: "system-images/android-34/google_apis/arm64-v8a"),
    ])

    let items = await SystemImagesScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: "sample_emulator"),
        sizes: [used: 1_500_000_000, unused: 600_000_000]))

    #expect(items.count == 2)
    let kept = try #require(items.first { $0.name.contains("android-34") })
    #expect(!kept.isDeletable)
    #expect(kept.protection == .sdkInUse(by: "sample_emulator"))
    #expect(kept.detail == "used by sample_emulator")

    let offered = try #require(items.first { $0.name.contains("android-30") })
    #expect(offered.isDeletable)
    #expect(offered.detail == "no emulator uses it")
    #expect(offered.sizeBytes == 600_000_000)
    #expect(offered.method == .removePath(unused))
    #expect(offered.id == "android.systemImages|\(unused)")
}

/// The system-image half of decision A. `sample_avd` is not the emulator being kept,
/// only one used three days ago, so it survives the clean — and an image deleted out
/// from under it leaves an emulator that is still installed and no longer boots. A
/// scanner that reads `keptAVDName` alone offers that image.
@Test func systemImageOfAProtectedButNotKeptAVDIsAlsoProtected() async throws {
    let temp = TempDir()
    let keptImage = temp.makeDirectory(
        "Library/Android/sdk/system-images/android-36/google_apis_playstore/arm64-v8a")
    let recentImage = temp.makeDirectory(
        "Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a")

    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now,
            image: "system-images/android-36/google_apis_playstore/arm64-v8a"),
        avd("sample_avd", used: now.addingTimeInterval(-86_400 * 3),
            image: "system-images/android-35/google_apis/arm64-v8a"),
    ])

    let items = await SystemImagesScanner().scan(context(
        temp: temp, devices: devices,
        protection: protection(keptAVD: "sample_emulator", protectedAVDs: [
            "sample_emulator": .mostRecentlyUsedDevice,
            "sample_avd": .recentlyUsedDevice(days: 7),
        ]),
        sizes: [keptImage: 1_500_000_000, recentImage: 1_400_000_000]))

    #expect(items.filter(\.isDeletable).isEmpty)
    let recent = try #require(items.first { $0.name.contains("android-35") })
    #expect(recent.protection == .sdkInUse(by: "sample_avd"))
    #expect(recent.detail == "used by sample_avd")
}

/// An emulator this clean offers is still installed until the user confirms, and they
/// may untick it. The image stays offered — that is the point of the scanner — but it
/// has to say out loud which emulator would stop booting.
@Test func systemImageOfAnOfferedAVDIsStillOfferedAndNamesTheEmulator() async throws {
    let temp = TempDir()
    let image = temp.makeDirectory(
        "Library/Android/sdk/system-images/android-30/default/x86_64")
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 60),
            image: "system-images/android-30/default/x86_64"),
    ])

    let items = await SystemImagesScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: nil),
        sizes: [image: 600_000_000]))

    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.detail == "used by sample_emulator_1")
}

/// Every AVD on a real dev machine writes `image.sysdir.1` relative to the SDK root, but
/// older tooling writes it absolute. An absolute value compared as a whole string
/// matches nothing, and the guard silently stops protecting anything.
@Test func anAbsoluteImageSysdirStillProtectsTheImage() async throws {
    let temp = TempDir()
    let image = temp.makeDirectory(
        "Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now, image: image),
    ])

    let items = await SystemImagesScanner().scan(context(
        temp: temp, devices: devices, protection: protection(keptAVD: "sample_emulator"),
        sizes: [image: 1_500_000_000]))

    let item = try #require(items.first)
    #expect(item.protection == .sdkInUse(by: "sample_emulator"))
}

@Test func systemImagesAreListedAtTheABILevel() async throws {
    let temp = TempDir()
    let arm = temp.makeDirectory("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
    temp.makeDirectory("Library/Android/sdk/system-images/android-34/google_apis/x86_64")
    let items = await SystemImagesScanner().scan(context(temp: temp))
    #expect(items.count == 2)
    #expect(items.map(\.name).sorted()
            == ["android-34/google_apis/arm64-v8a", "android-34/google_apis/x86_64"])
    let first = try #require(items.first { $0.name.hasSuffix("arm64-v8a") })
    #expect(first.method == .removePath(arm))
}

/// Rule 4: a fixture of only directories cannot test a filter. `package.xml` and
/// `source.properties` are real files the SDK manager writes beside its directories,
/// and listing one as a system image would offer a stray file as though it were a
/// multi-gigabyte image.
@Test func onlyDirectoriesThreeLevelsDownAreListed() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
    temp.makeFile("Library/Android/sdk/system-images/package.xml")
    temp.makeFile("Library/Android/sdk/system-images/android-34/source.properties")
    temp.makeFile("Library/Android/sdk/system-images/android-34/google_apis/package.xml")
    temp.makeFile("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/build.prop")

    let items = await SystemImagesScanner().scan(context(temp: temp, sizes: [real: 1_500_000_000]))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "android-34/google_apis/arm64-v8a")
    #expect(item.method == .removePath(real))
}

@Test func systemImagesScannerIsSilentWhenTheSDKIsAbsent() async {
    let temp = TempDir()
    #expect(await SystemImagesScanner().scan(context(temp: temp)).isEmpty)
}

@Test func systemImagesAreMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    temp.makeDirectory("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
    temp.makeDirectory("Library/Android/sdk/system-images/android-34/google_apis/x86_64")
    temp.makeDirectory("Library/Android/sdk/system-images/android-30/default/x86_64")
    let measurer = CallCountingSizeMeasurer()

    let items = await SystemImagesScanner()
        .scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 3)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.count == 3)
}

// MARK: Gradle

@Test func gradleCacheSubdirectoriesAreOfferedIndividually() async throws {
    let temp = TempDir()
    let modules = temp.makeDirectory(".gradle/caches/modules-2")
    let buildCache = temp.makeDirectory(".gradle/caches/build-cache-1")
    let transforms = temp.makeDirectory(".gradle/caches/transforms-4")
    let jars = temp.makeDirectory(".gradle/caches/jars-9")
    let journal = temp.makeDirectory(".gradle/caches/journal-1")
    let daemon = temp.makeDirectory(".gradle/daemon")
    // Rule 4: entries that must survive the filter untouched. `8.7` is a real directory
    // in a real dev machine's `~/.gradle/caches`, and `CACHEDIR.TAG` is a real file there.
    temp.makeDirectory(".gradle/caches/8.7")
    temp.makeFile(".gradle/caches/CACHEDIR.TAG")
    temp.makeFile(".gradle/caches/transforms-4.lock")

    let items = await GradleScanner().scan(context(temp: temp, sizes: [
        modules: 20_000_000_000, buildCache: 4_000_000_000,
        transforms: 1_000_000_000, jars: 200_000_000, journal: 25_000_000,
        daemon: 50_000_000,
    ]))

    #expect(Set(items.map(\.name)) == [
        "Downloaded dependencies", "Build cache", "transforms-4", "jars-9", "journal-1",
        "Daemon logs",
    ])
    #expect(items.filter(\.isDeletable).count == 6)
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 25_275_000_000)
}

/// Rule 2: assert the deletion target. Name and size come from different places than
/// the path, so asserting them does not constrain what would be removed.
@Test func gradleItemsPinTheirDeletionPaths() async throws {
    let temp = TempDir()
    let modules = temp.makeDirectory(".gradle/caches/modules-2")
    let daemon = temp.makeDirectory(".gradle/daemon")
    let dist = temp.makeDirectory(".gradle/wrapper/dists/gradle-8.14-all")

    let items = await GradleScanner().scan(context(temp: temp))

    let dependencies = try #require(items.first { $0.name == "Downloaded dependencies" })
    #expect(dependencies.method == .removePath(modules))
    #expect(dependencies.id == "android.gradle|\(modules)")
    #expect(try #require(items.first { $0.name == "Daemon logs" }).method == .removePath(daemon))
    #expect(try #require(items.first { $0.name == "gradle-8.14-all" }).method == .removePath(dist))
}

@Test func gradleWrapperDistributionForAProtectedProjectIsKept() async throws {
    let temp = TempDir()
    let kept = temp.makeDirectory(".gradle/wrapper/dists/gradle-8.7-bin")
    let stale = temp.makeDirectory(".gradle/wrapper/dists/gradle-6.9-all")

    let items = await GradleScanner().scan(context(
        temp: temp,
        protection: protection(keptAVD: nil,
                               gradle: ["gradle-8.7-bin": .gradleVersionInUse(by: "sample-project")]),
        sizes: [kept: 150_000_000, stale: 180_000_000]))

    let protectedDist = try #require(items.first { $0.name == "gradle-8.7-bin" })
    #expect(protectedDist.protection == .gradleVersionInUse(by: "sample-project"))
    #expect(protectedDist.detail == "Gradle distribution")
    #expect(try #require(items.first { $0.name == "gradle-6.9-all" }).isDeletable)
}

/// The protection key is the full distribution directory name, not a version number.
///
/// Both halves of the comparison run here: the real `ProtectionResolver` reads a real
/// pre-release `distributionUrl`, and the scanner lists the real directory Gradle
/// creates for it. A version key truncates `gradle-9.0-rc-1-bin.zip` to `9.0`, which
/// then also matches the final release `gradle-9.0-bin` — protecting a distribution no
/// project uses while the one the project needs is decided by luck.
@Test func gradleProtectionMatchesTheFullDistributionNameNotJustTheVersion() async throws {
    let temp = TempDir()
    temp.makeFile("dev/sample-project/pubspec.yaml")
    temp.makeFile("dev/sample-project/android/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.0-rc-1-bin.zip\n")
    let rc = temp.makeDirectory(".gradle/wrapper/dists/gradle-9.0-rc-1-bin")
    let release = temp.makeDirectory(".gradle/wrapper/dists/gradle-9.0-bin")

    let project = DiscoveredProject(
        path: temp.path + "/dev/sample-project", name: "sample-project")
    let resolved = ProtectionResolver(settings: .makeDefault(home: temp.path)).resolve(
        projects: [project],
        activity: [project.path: now.addingTimeInterval(-86_400)],
        devices: .empty, now: now)

    let items = await GradleScanner().scan(context(
        temp: temp, protection: resolved, sizes: [rc: 150_000_000, release: 180_000_000]))

    let kept = try #require(items.first { $0.name == "gradle-9.0-rc-1-bin" })
    #expect(kept.protection == .gradleVersionInUse(by: "sample-project"))
    #expect(kept.method == .removePath(rc))

    let offered = try #require(items.first { $0.name == "gradle-9.0-bin" })
    #expect(offered.isDeletable)
    #expect(offered.sizeBytes == 180_000_000)
    #expect(offered.method == .removePath(release))
}

/// A `-bin` distribution and an `-all` distribution of the same version are separate
/// downloads sitting side by side. A version key protects both when a project names
/// only one of them.
@Test func onlyTheDistributionFlavourAProjectNamesIsKept() async throws {
    let temp = TempDir()
    temp.makeFile("dev/sample-project/build.gradle")
    temp.makeFile("dev/sample-project/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-all.zip\n")
    let all = temp.makeDirectory(".gradle/wrapper/dists/gradle-8.14-all")
    let bin = temp.makeDirectory(".gradle/wrapper/dists/gradle-8.14-bin")

    let project = DiscoveredProject(
        path: temp.path + "/dev/sample-project", name: "sample-project")
    let resolved = ProtectionResolver(settings: .makeDefault(home: temp.path)).resolve(
        projects: [project],
        activity: [project.path: now.addingTimeInterval(-86_400)],
        devices: .empty, now: now)

    let items = await GradleScanner().scan(context(
        temp: temp, protection: resolved, sizes: [all: 220_000_000, bin: 150_000_000]))

    #expect(try #require(items.first { $0.name == "gradle-8.14-all" }).protection
            == .gradleVersionInUse(by: "sample-project"))
    #expect(try #require(items.first { $0.name == "gradle-8.14-bin" }).isDeletable)
}

/// Rule 4 for the wrapper directory. `CACHEDIR.TAG` is a real file sitting beside the
/// distribution folders in a real dev machine's `~/.gradle/wrapper/dists`.
@Test func onlyDistributionDirectoriesAreListedUnderWrapperDists() async throws {
    let temp = TempDir()
    let dist = temp.makeDirectory(".gradle/wrapper/dists/gradle-7.5-all")
    temp.makeFile(".gradle/wrapper/dists/CACHEDIR.TAG")

    let items = await GradleScanner().scan(context(temp: temp, sizes: [dist: 130_000_000]))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "gradle-7.5-all")
    #expect(item.sizeBytes == 130_000_000)
}

@Test func gradleScannerIsSilentWhenNothingIsInstalled() async {
    let temp = TempDir()
    #expect(await GradleScanner().scan(context(temp: temp)).isEmpty)
}

@Test func gradleIsMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    temp.makeDirectory(".gradle/caches/modules-2")
    temp.makeDirectory(".gradle/caches/transforms-4")
    temp.makeDirectory(".gradle/daemon")
    temp.makeDirectory(".gradle/wrapper/dists/gradle-8.14-all")
    let measurer = CallCountingSizeMeasurer()

    let items = await GradleScanner().scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 4)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.count == 4)
}

/// A Gradle distribution and its dependency cache are re-downloaded, not rebuilt, so
/// they are `.elevated`: a clean on a bad connection costs the user a build they
/// cannot run. What is regenerated locally stays `.safe`.
@Test func onlyTheDownloadedPartsOfGradleAreMarkedElevatedRisk() async throws {
    let temp = TempDir()
    temp.makeDirectory(".gradle/caches/modules-2")
    temp.makeDirectory(".gradle/caches/build-cache-1")
    temp.makeDirectory(".gradle/caches/transforms-4")
    temp.makeDirectory(".gradle/daemon")
    temp.makeDirectory(".gradle/wrapper/dists/gradle-8.14-all")

    let items = await GradleScanner().scan(context(temp: temp))
    let elevated = items.filter { $0.risk == .elevated }.map(\.name).sorted()
    #expect(elevated == ["Downloaded dependencies", "gradle-8.14-all"])
}

// MARK: NDK

/// One row per installed version, never one row for the whole `ndk` folder. This
/// machine has two versions and 5.57 GB in them; a single row makes "keep the one my
/// build uses, hand back the other" impossible.
///
/// Rule 4 rides along: `source.properties` is a plain file the SDK manager writes, and
/// offering it under the name of a three-gigabyte folder would show a row measured at
/// zero. Rule 2: each row pins its own deletion path.
@Test func ndkOffersOneRowPerInstalledVersionAndNotTheWholeFolder() async throws {
    let temp = TempDir()
    let older = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let newer = temp.makeDirectory("Library/Android/sdk/ndk/28.2.13676358")
    temp.makeFile("Library/Android/sdk/ndk/source.properties")

    let items = await NDKScanner().scan(context(
        temp: temp, sizes: [older: 2_600_000_000, newer: 2_970_000_000]))

    #expect(items.count == 2)
    #expect(items.map(\.name) == ["27.0.12077973", "28.2.13676358"])

    let old = try #require(items.first { $0.name == "27.0.12077973" })
    #expect(old.method == .removePath(older))
    #expect(old.id == "android.ndk|\(older)")
    #expect(old.sizeBytes == 2_600_000_000)
    #expect(try #require(items.first { $0.name == "28.2.13676358" }).method == .removePath(newer))
}

/// The decision this scanner exists to express. The rows are deletable and carry their
/// size, so the user sees the 5.57 GB — and they are **not ticked**, so a default clean
/// never starts a multi-gigabyte re-download nobody asked for.
@Test func ndkRowsAreOfferedWithTheirSizeButAreNotTickedByDefault() async throws {
    let temp = TempDir()
    let version = temp.makeDirectory("Library/Android/sdk/ndk/28.2.13676358")

    let items = await NDKScanner().scan(context(temp: temp, sizes: [version: 2_970_000_000]))

    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.startsUnticked)
    #expect(!item.selectedByDefault)
    #expect(item.sizeBytes == 2_970_000_000)
    #expect(item.protection == nil)
    // It comes back over the network and nothing builds until it does.
    #expect(item.risk == .elevated)
    #expect(item.detail == "Android Studio downloads it again when a build needs native code")
}

/// The other half of the decision, and the one that would go unnoticed: adding an
/// unticked row must not untick anything else. Two scanners in one engine run, and every
/// Gradle row still starts ticked exactly as it did before this field existed.
@Test func onlyTheNDKRowsStartUntickedAndEveryOtherScannersRowsStayTicked() async throws {
    let temp = TempDir()
    temp.makeDirectory("Library/Android/sdk/ndk/28.2.13676358")
    temp.makeDirectory(".gradle/caches/modules-2")
    temp.makeDirectory(".gradle/caches/build-cache-1")
    temp.makeDirectory(".gradle/daemon")

    let result = await ScanEngine(scanners: [NDKScanner(), GradleScanner()])
        .scan(context: context(temp: temp))

    let unticked = result.items.filter { !$0.selectedByDefault }.map(\.scannerID)
    #expect(unticked == ["android.ndk"])
    let gradle = result.items.filter { $0.scannerID == "android.gradle" }
    #expect(gradle.count == 3)
    #expect(gradle.allSatisfy { $0.selectedByDefault })
    #expect(gradle.allSatisfy { !$0.startsUnticked })
}

/// The interaction that makes the whole row worthless if it is missed. Task 17 chose
/// `<sdk>/system-images` as the Android root **specifically so that `ndk` could not be
/// reached**, so an NDK scanner shipped on its own would have every row refused after
/// the user ticked it, and the app would report freeing nothing.
///
/// The neighbours are the point of the second half: the root is `<sdk>/ndk`, not the SDK
/// itself, so `platform-tools` — which holds `adb` — stays out of reach.
@Test func ndkVersionPathsPassTheRealRunGuardAndTheSDKAroundThemDoesNot() throws {
    let temp = TempDir()
    let version = temp.makeDirectory("Library/Android/sdk/ndk/28.2.13676358")
    let ndkRoot = temp.makeDirectory("Library/Android/sdk/ndk")
    let platformTools = temp.makeDirectory("Library/Android/sdk/platform-tools")
    let licenses = temp.makeDirectory("Library/Android/sdk/licenses")

    let sut = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])

    #expect(throws: Never.self) { _ = try sut.validate(version) }
    // The folder holding the versions is the root itself, and `validate` refuses a path
    // equal to a root — so "trash the whole NDK" is not something the run can express.
    #expect(throws: PathGuard.Violation.outsideAllowedRoots(ndkRoot)) {
        _ = try sut.validate(ndkRoot)
    }
    for neighbour in [platformTools, licenses] {
        #expect(throws: PathGuard.Violation.outsideAllowedRoots(neighbour)) {
            _ = try sut.validate(neighbour)
        }
    }
}

@Test func ndkScannerIsSilentWhenNoNDKIsInstalled() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Android/sdk/platform-tools")
    #expect(await NDKScanner().scan(context(temp: temp)).isEmpty)
}

/// Rule 9. Two versions, one batched `sizes(of:)` call.
@Test func ndkVersionsAreMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    let older = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let newer = temp.makeDirectory("Library/Android/sdk/ndk/28.2.13676358")
    let measurer = CallCountingSizeMeasurer([older: 2_600_000_000, newer: 2_970_000_000])

    let items = await NDKScanner().scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [older, newer].sorted())
}

// MARK: identity

/// Rule 3. The identifiers are persisted in `Settings.alwaysSkipScannerIDs`, so
/// renaming one silently un-skips it for an existing user.
@Test func androidScannerIdentitiesAndGroupsAreStable() {
    #expect(AVDScanner().id == "android.avds")
    #expect(SystemImagesScanner().id == "android.systemImages")
    #expect(GradleScanner().id == "android.gradle")
    #expect(NDKScanner().id == "android.ndk")
    #expect(AVDScanner().group == .android)
    #expect(SystemImagesScanner().group == .android)
    #expect(GradleScanner().group == .android)
    #expect(NDKScanner().group == .android)
    #expect(NDKScanner().title == "Android NDK")
}

/// The other half of rule 3, with a non-default `Settings`: the string a user's settings
/// file already holds has to be the string this scanner publishes today.
@Test func skippingTheNDKScannerUsesTheStringItPublishes() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Android/sdk/ndk/28.2.13676358")

    let result = await ScanEngine(scanners: [NDKScanner()]).scan(context: context(
        temp: temp, settings: settings(home: temp.path) {
            $0.alwaysSkipScannerIDs = ["android.ndk"]
        }))

    #expect(result.items.isEmpty)
    #expect(result.skippedScannerIDs == ["android.ndk"])
}
