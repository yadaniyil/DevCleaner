import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(temp: TempDir, protection: ProtectionSet = .empty,
                     sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil,
                     settings: Settings? = nil,
                     home: String? = nil) -> ScanContext {
    let home = home ?? temp.path
    return ScanContext(
        settings: settings ?? .makeDefault(home: home), protection: protection, projects: [],
        devices: .empty, home: home, androidSDKPath: home + "/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

/// The memberwise initialiser has eight arguments and no defaults, and the Gradle
/// field is keyed by distribution directory name rather than by version.
private func protection(flutter: [String: ProtectionReason]) -> ProtectionSet {
    ProtectionSet(
        projects: [:], keptSimulatorUDID: nil, keptAVDName: nil,
        protectedSimulatorUDIDs: [:], protectedAVDNames: [:],
        flutterVersions: flutter, gradleDistributions: [:], runtimeIdentifiers: [:])
}

// MARK: pub cache

@Test func pubCacheIsOfferedAsHostedAndGitAtElevatedRisk() async throws {
    let temp = TempDir()
    let hosted = temp.makeDirectory(".pub-cache/hosted")
    let git = temp.makeDirectory(".pub-cache/git")

    let items = await PubCacheScanner().scan(context(
        temp: temp, sizes: [hosted: 7_000_000_000, git: 1_700_000_000]))

    // Fixed order, so the rows do not reshuffle between scans.
    #expect(items.map(\.name) == ["Hosted packages", "Git packages"])
    #expect(items.allSatisfy { $0.risk == .elevated })
    #expect(items.allSatisfy { $0.isDeletable })

    let hostedItem = try #require(items.first { $0.name == "Hosted packages" })
    #expect(hostedItem.sizeBytes == 7_000_000_000)
    #expect(hostedItem.detail == "re-downloaded from pub.dev on the next build")

    // The two parts fail differently, and the git row has to say so: a repository that
    // has moved or been deleted cannot be restored by rebuilding.
    let gitItem = try #require(items.first { $0.name == "Git packages" })
    #expect(gitItem.sizeBytes == 1_700_000_000)
    #expect(gitItem.detail?.contains("may no longer exist") == true)
}

/// Rule 4: a fixture of only matching entries cannot test a filter. Every name here is
/// a real entry in a real dev machine's `~/.pub-cache`, and all but three must survive: `bin`
/// and `global_packages` hold the globally activated command line tools, `active_roots`
/// and `hosted-hashes` are pub's own bookkeeping, while `_temp` holds incomplete downloads.
@Test func pubCacheOffersOnlyRegenerablePartsOutOfEverythingElseThatLivesThere() async throws {
    let temp = TempDir()
    let hosted = temp.makeDirectory(".pub-cache/hosted")
    let git = temp.makeDirectory(".pub-cache/git")
    temp.makeDirectory(".pub-cache/bin")
    temp.makeDirectory(".pub-cache/global_packages")
    temp.makeDirectory(".pub-cache/active_roots")
    temp.makeDirectory(".pub-cache/hosted-hashes")
    let temporary = temp.makeDirectory(".pub-cache/_temp")
    temp.makeDirectory(".pub-cache/log")
    temp.makeFile(".pub-cache/README.md")

    let items = await PubCacheScanner().scan(context(
        temp: temp, sizes: [hosted: 7_000_000_000, git: 1_700_000_000]))

    #expect(items.count == 3)
    #expect(Set(items.map(\.name)) == ["Hosted packages", "Git packages", "Temporary downloads"])
    let temporaryItem = try #require(items.first { $0.name == "Temporary downloads" })
    #expect(temporaryItem.method == .removePath(temporary))
    #expect(temporaryItem.risk == .safe)
}

@Test func pubCacheScannerSkipsPartsThatAreNotPresent() async {
    let temp = TempDir()
    temp.makeDirectory(".pub-cache/hosted")
    let items = await PubCacheScanner().scan(context(temp: temp))
    #expect(items.map(\.name) == ["Hosted packages"])
}

/// `~/.pub-cache` holds plain files beside its directories. One named like a part —
/// a leftover from a half-restored backup, say — would be offered as a multi-gigabyte
/// cache and measured as zero.
@Test func aFileNamedLikeAPubCachePartIsNotOffered() async {
    let temp = TempDir()
    temp.makeDirectory(".pub-cache/hosted")
    temp.makeFile(".pub-cache/git")

    let items = await PubCacheScanner().scan(context(temp: temp))
    #expect(items.map(\.name) == ["Hosted packages"])
}

/// Rule 2: assert the deletion target. Name, detail and size all come from somewhere
/// other than the path, so asserting them does not constrain what would be removed —
/// a path mutated from the child to `~/.pub-cache` itself passes every other check.
@Test func pubCacheItemsPinTheirDeletionPaths() async throws {
    let temp = TempDir()
    let hosted = temp.makeDirectory(".pub-cache/hosted")
    let git = temp.makeDirectory(".pub-cache/git")
    let temporary = temp.makeDirectory(".pub-cache/_temp")

    let items = await PubCacheScanner().scan(context(temp: temp))

    let hostedItem = try #require(items.first { $0.name == "Hosted packages" })
    #expect(hostedItem.method == .removePath(hosted))
    #expect(hostedItem.id == "flutter.pubCache|\(hosted)")
    #expect(hostedItem.group == .flutterAndDart)

    let gitItem = try #require(items.first { $0.name == "Git packages" })
    #expect(gitItem.method == .removePath(git))
    #expect(gitItem.id == "flutter.pubCache|\(git)")

    let temporaryItem = try #require(items.first { $0.name == "Temporary downloads" })
    #expect(temporaryItem.method == .removePath(temporary))
    #expect(temporaryItem.id == "flutter.pubCache|\(temporary)")
}

/// Rule 9: `sizes(of:)` batches its input and holds four `du` processes open at most,
/// so one call per part defeats that cap. Nothing in the returned items shows it.
@Test func pubCacheIsMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    let hosted = temp.makeDirectory(".pub-cache/hosted")
    let git = temp.makeDirectory(".pub-cache/git")
    let temporary = temp.makeDirectory(".pub-cache/_temp")
    let measurer = CallCountingSizeMeasurer([hosted: 7_000_000_000])

    let items = await PubCacheScanner().scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 3)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [git, hosted, temporary].sorted())
}

@Test func pubCacheScannerIsSilentWhenThereIsNoPubCache() async {
    let temp = TempDir()
    #expect(await PubCacheScanner().scan(context(temp: temp)).isEmpty)
}

// MARK: fvm

@Test func fvmVersionsInUseAreProtected() async throws {
    let temp = TempDir()
    let old = temp.makeDirectory("fvm/versions/3.10.6")
    let mid = temp.makeDirectory("fvm/versions/3.24.5")
    let current = temp.makeDirectory("fvm/versions/3.38.5")

    let items = await FVMScanner().scan(context(
        temp: temp, protection: protection(flutter: ["3.38.5": .sdkInUse(by: "sample-project")]),
        sizes: [old: 1_900_000_000, mid: 2_100_000_000, current: 2_000_000_000]))

    #expect(items.count == 3)
    let kept = try #require(items.first { $0.name == "3.38.5" })
    #expect(kept.protection == .sdkInUse(by: "sample-project"))
    #expect(kept.detail == "used by sample-project")
    #expect(!kept.isDeletable)

    let offered = try #require(items.first { $0.name == "3.10.6" })
    #expect(offered.detail == "no project asks for this version")

    #expect(items.filter(\.isDeletable).map(\.name).sorted() == ["3.10.6", "3.24.5"])
    let reclaimable: Int64 = items.filter(\.isDeletable).reduce(0) { $0 + $1.sizeBytes }
    #expect(reclaimable == 4_000_000_000)
}

@Test func fvmScannerAlsoLooksInTheDotFvmLocation() async throws {
    let temp = TempDir()
    let path = temp.makeDirectory(".fvm/versions/3.19.0")
    let items = await FVMScanner().scan(context(temp: temp, sizes: [path: 1_000_000_000]))
    #expect(items.map(\.name) == ["3.19.0"])
    let item = try #require(items.first)
    #expect(item.method == .removePath(path))
    #expect(item.sizeBytes == 1_000_000_000)
}

/// Both locations in one scan, and rule 9 across both of them: measuring each root
/// separately would be two `sizes(of:)` calls and would go unnoticed in the items.
@Test func fvmListsBothLocationsAndMeasuresThemInOneBatchedCall() async throws {
    let temp = TempDir()
    let modern = temp.makeDirectory("fvm/versions/3.38.5")
    let legacy = temp.makeDirectory(".fvm/versions/3.19.0")
    let measurer = CallCountingSizeMeasurer([modern: 2_000_000_000, legacy: 1_000_000_000])

    let items = await FVMScanner().scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(items.map(\.name) == ["3.38.5", "3.19.0"])
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [legacy, modern].sorted())
}

// MARK: the fvm download cache

/// `~/fvm/cache.git` is 786.1 MB on a real dev machine and no scanner claimed it. It is a bare
/// clone fvm keeps so that installing another Flutter version is a checkout rather than a
/// full download, so nothing in the toolchain is using it — the cost lands only on the
/// next `fvm install`, which re-clones roughly the same 786 MB.
@Test func fvmOffersItsDownloadCacheAsItsOwnRowTickedByDefault() async throws {
    let temp = TempDir()
    let version = temp.makeDirectory("fvm/versions/3.38.5")
    let mirror = temp.makeDirectory("fvm/cache.git")

    let items = await FVMScanner().scan(context(
        temp: temp, sizes: [version: 2_000_000_000, mirror: 786_100_000]))

    // Versions first, then the mirror, so the rows do not reshuffle between scans.
    #expect(items.map(\.name) == ["3.38.5", "fvm download cache"])
    let item = try #require(items.first { $0.name == "fvm download cache" })
    #expect(item.method == .removePath(mirror))
    #expect(item.id == "flutter.fvm|\(mirror)")
    #expect(item.sizeBytes == 786_100_000)
    #expect(item.isDeletable)
    // Ticked like any other cache — unlike the NDK, which the user has to ask for.
    #expect(item.selectedByDefault)
    #expect(!item.startsUnticked)
    // Re-cloned from GitHub, not rebuilt locally.
    #expect(item.risk == .elevated)
    #expect(item.detail == "re-cloned from GitHub the next time fvm installs a version")
    #expect(item.protection == nil)
}

/// Rule 4, for the entries that really sit in `~/fvm`. `versions` is the SDK folder this
/// scanner already lists one row per child of, `default` is the symlink the `flutter`
/// command on PATH resolves through, and a plain file named `cache.git` would be offered
/// under the name of a 786 MB folder and measured as zero.
@Test func onlyTheMirrorIsTakenOutOfEverythingElseThatSitsBesideIt() async throws {
    let temp = TempDir()
    let version = temp.makeDirectory("fvm/versions/3.38.5")
    let mirror = temp.makeDirectory("fvm/cache.git")
    temp.makeSymlink("fvm/default", to: version)
    temp.makeFile("fvm/.fvmrc")

    let items = await FVMScanner().scan(context(
        temp: temp, sizes: [version: 2_000_000_000, mirror: 786_100_000]))

    #expect(items.count == 2)
    #expect(items.map(\.name).sorted() == ["3.38.5", "fvm download cache"])
    #expect(try #require(items.first { $0.name == "fvm download cache" }).method
            == .removePath(mirror))
}

@Test func aPlainFileNamedLikeTheMirrorIsNotOffered() async throws {
    let temp = TempDir()
    let version = temp.makeDirectory("fvm/versions/3.38.5")
    temp.makeFile("fvm/cache.git")

    let items = await FVMScanner().scan(context(temp: temp, sizes: [version: 2_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "3.38.5")
    #expect(item.method == .removePath(version))
}

@Test func noMirrorRowWhenFvmHasNeverDownloadedOne() async {
    let temp = TempDir()
    temp.makeDirectory("fvm/versions/3.38.5")
    let items = await FVMScanner().scan(context(temp: temp))
    #expect(items.map(\.name) == ["3.38.5"])
}

/// The older layout keeps its own mirror, so both are found.
@Test func theMirrorIsFoundInTheDotFvmLayoutToo() async throws {
    let temp = TempDir()
    let mirror = temp.makeDirectory(".fvm/cache.git")

    let items = await FVMScanner().scan(context(temp: temp, sizes: [mirror: 500_000_000]))

    let item = try #require(items.first)
    #expect(item.name == "fvm download cache")
    #expect(item.method == .removePath(mirror))
    #expect(item.sizeBytes == 500_000_000)
}

/// Rule 9 across both kinds of row. Measuring the mirror separately from the versions
/// would be a second `sizes(of:)` call and nothing in the items would show it.
@Test func theMirrorIsMeasuredInTheSameBatchAsTheSDKs() async throws {
    let temp = TempDir()
    let version = temp.makeDirectory("fvm/versions/3.38.5")
    let mirror = temp.makeDirectory("fvm/cache.git")
    let measurer = CallCountingSizeMeasurer([version: 2_000_000_000, mirror: 786_100_000])

    let items = await FVMScanner().scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [mirror, version].sorted())
    #expect(try #require(items.first { $0.name == "fvm download cache" }).sizeBytes == 786_100_000)
}

/// The interaction that would make the row free nothing. Task 17's fvm root stops at
/// `fvm/versions` on purpose, to keep `~/fvm/default` — the symlink the `flutter` command
/// resolves through — out of the run's reach. So the mirror is not inside any root, and
/// it is allowed as a single exact path instead: the second half of this test is the
/// point, because widening the root to `~/fvm` would allow all three of these.
@Test func theMirrorPassesTheRealRunGuardWhileItsNeighboursStillDoNot() throws {
    let temp = TempDir()
    let version = temp.makeDirectory("fvm/versions/3.38.5")
    let mirror = temp.makeDirectory("fvm/cache.git")
    let legacyMirror = temp.makeDirectory(".fvm/cache.git")
    let fvmHome = temp.makeDirectory("fvm")
    let defaultLink = temp.makeDirectory("fvm/default")
    let lookalike = temp.makeDirectory("fvm/cache.git.bak")

    let sut = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])

    #expect(throws: Never.self) { _ = try sut.validate(mirror) }
    #expect(throws: Never.self) { _ = try sut.validate(legacyMirror) }
    // and the SDKs are still reachable through the root that was already there
    #expect(throws: Never.self) { _ = try sut.validate(version) }

    for neighbour in [fvmHome, defaultLink, lookalike] {
        #expect(throws: PathGuard.Violation.outsideAllowedRoots(neighbour),
                "\(neighbour) must not be deletable") {
            _ = try sut.validate(neighbour)
        }
    }
}

/// Rule 4. A stray file left by a failed install would otherwise be listed as an
/// installed SDK, measured as zero and offered for deletion.
@Test func onlyDirectoriesUnderVersionsAreListedAsSDKs() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("fvm/versions/3.38.5")
    temp.makeFile("fvm/versions/install.lock")

    let items = await FVMScanner().scan(context(temp: temp, sizes: [real: 2_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "3.38.5")
    #expect(item.method == .removePath(real))
}

/// Rule 2, plus the modification date the list sorts and labels by.
@Test func fvmItemsPinTheirDeletionPathAndCarryTheirModifiedDate() async throws {
    let temp = TempDir()
    let path = temp.makeDirectory("fvm/versions/3.24.5")
    let stamp = now.addingTimeInterval(-86_400 * 40)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)

    let items = await FVMScanner().scan(context(temp: temp, sizes: [path: 2_100_000_000]))

    let item = try #require(items.first)
    #expect(item.method == .removePath(path))
    #expect(item.id == "flutter.fvm|\(path)")
    #expect(item.group == .flutterAndDart)
    let lastUsed = try #require(item.lastUsed)
    #expect(abs(lastUsed.timeIntervalSince(stamp)) < 1)
}

/// A Flutter SDK is around two gigabytes back over the network, and the toolchain does
/// not work until that download finishes — the same reason a Gradle distribution is
/// elevated, at thirteen times the size. `.safe` would mean a rebuild restores it.
@Test func everyFlutterSDKIsElevatedRisk() async {
    let temp = TempDir()
    temp.makeDirectory("fvm/versions/3.10.6")
    temp.makeDirectory("fvm/versions/3.38.5")

    let items = await FVMScanner().scan(context(
        temp: temp, protection: protection(flutter: ["3.38.5": .sdkInUse(by: "eir")])))

    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.risk == .elevated })
}

/// Decision C: the text is derived from the reason, never from one fixed sentence for
/// everything protected. `.recentActivity` does not reach this map today, and that is
/// the point — a catch-all would print "used by a project" for it, which is not what
/// happened. The reason's own words are the only text guaranteed not to lie.
@Test func fvmDetailComesFromTheReasonAndNotAFixedSentence() async throws {
    let temp = TempDir()
    temp.makeDirectory("fvm/versions/3.24.5")
    temp.makeDirectory("fvm/versions/3.38.5")

    let items = await FVMScanner().scan(context(temp: temp, protection: protection(flutter: [
        "3.24.5": .recentActivity(days: 14),
        "3.38.5": .sdkInUse(by: "eir"),
    ])))

    #expect(try #require(items.first { $0.name == "3.24.5" }).detail
            == "changed in the last 14 days")
    #expect(try #require(items.first { $0.name == "3.38.5" }).detail == "used by eir")
}

/// Decision B, through the real `ProtectionResolver` so both halves are pinned at once.
///
/// A Flutter SDK is kept when **any** discovered project names it, even a project the
/// clean itself offers. Gradle is deliberately the opposite — a distribution is kept
/// only for a protected project — and this test holds both ends of that asymmetry, so
/// that "fixing" one to match the other fails here.
@Test func aFlutterSDKAnyProjectNamesIsKeptEvenWhenThatProjectIsNotProtected() async throws {
    let temp = TempDir()
    temp.makeFile("dev/example-flutter-app/pubspec.yaml")
    temp.makeFile("dev/example-flutter-app/.fvmrc", contents: #"{"flutter": "3.24.5"}"#)
    temp.makeFile("dev/example-flutter-app/android/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.7-bin.zip\n")
    let kept = temp.makeDirectory("fvm/versions/3.24.5")
    let stale = temp.makeDirectory("fvm/versions/3.10.6")

    let project = DiscoveredProject(
        path: temp.path + "/dev/example-flutter-app",
        name: "example-flutter-app")
    // Touched eleven months ago: far outside `activeThresholdDays`, so the project
    // itself is offered for cleaning.
    let resolved = ProtectionResolver(settings: .makeDefault(home: temp.path)).resolve(
        projects: [project],
        activity: [project.path: now.addingTimeInterval(-86_400 * 330)],
        devices: .empty, now: now)

    #expect(resolved.projects.isEmpty)
    // The Gradle half of the asymmetry: nothing kept, because the project is not.
    #expect(resolved.gradleDistributions.isEmpty)

    let items = await FVMScanner().scan(context(
        temp: temp, protection: resolved, sizes: [kept: 2_100_000_000, stale: 1_900_000_000]))

    let keptItem = try #require(items.first { $0.name == "3.24.5" })
    #expect(keptItem.protection == .sdkInUse(by: "example-flutter-app"))
    #expect(keptItem.detail == "used by example-flutter-app")
    #expect(items.filter(\.isDeletable).map(\.name) == ["3.10.6"])
}

/// `fvm global <version>` links `~/fvm/default` at one SDK and its own instructions put
/// `~/fvm/default/bin` on PATH. No project file names that version, so nothing else in
/// a scan protects it — and trashing it leaves the `flutter` command broken for every
/// project that does not pin a version.
@Test func theFvmGlobalDefaultSDKIsKeptEvenWhenNoProjectNamesIt() async throws {
    let temp = TempDir()
    let global = temp.makeDirectory("fvm/versions/3.24.5")
    let other = temp.makeDirectory("fvm/versions/3.10.6")
    temp.makeSymlink("fvm/default", to: global)

    let items = await FVMScanner().scan(context(
        temp: temp, sizes: [global: 2_100_000_000, other: 1_900_000_000]))

    let kept = try #require(items.first { $0.name == "3.24.5" })
    #expect(kept.protection == .sdkInUse(by: "the fvm global default"))
    #expect(kept.detail == "used by the fvm global default")
    // Only the linked one. A guard that protected every version would hide the 1.9 GB
    // this scan exists to find.
    #expect(items.filter(\.isDeletable).map(\.name) == ["3.10.6"])
}

/// fvm writes an absolute target, but a link made by hand is usually relative to the
/// directory holding it. Read literally, `versions/3.24.5` matches no installed SDK and
/// the guard silently stops protecting anything.
@Test func aRelativeGlobalDefaultLinkStillProtectsItsSDK() async throws {
    let temp = TempDir()
    let global = temp.makeDirectory("fvm/versions/3.24.5")
    temp.makeSymlink("fvm/default", to: "versions/3.24.5")

    let items = await FVMScanner().scan(context(temp: temp, sizes: [global: 2_100_000_000]))

    let item = try #require(items.first)
    #expect(item.protection == .sdkInUse(by: "the fvm global default"))
}

/// Both sides of the comparison are resolved before they meet. The home directory here
/// is reached through a symlink, so the listing yields `…/link/fvm/versions/3.24.5`
/// while the link fvm wrote records `…/real/fvm/versions/3.24.5` — two names for one
/// directory. Compared as written they differ, the guard finds nothing, and the SDK
/// behind the `flutter` command on PATH is offered for deletion.
@Test func theGlobalDefaultIsFoundEvenWhenTheHomeDirectoryIsReachedThroughASymlink() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("real/fvm/versions/3.24.5")
    temp.makeSymlink("real/fvm/default", to: real)
    temp.makeSymlink("link", to: temp.path + "/real")

    let items = await FVMScanner().scan(context(temp: temp, home: temp.path + "/link"))

    let item = try #require(items.first)
    #expect(item.name == "3.24.5")
    #expect(item.protection == .sdkInUse(by: "the fvm global default"))
}

/// A project naming the version says more than "the global default does", so it wins
/// the label. Either way the SDK is kept.
@Test func aProjectNameBeatsTheGlobalDefaultLabelForTheSameSDK() async throws {
    let temp = TempDir()
    let global = temp.makeDirectory("fvm/versions/3.38.5")
    temp.makeSymlink("fvm/default", to: global)

    let items = await FVMScanner().scan(context(
        temp: temp, protection: protection(flutter: ["3.38.5": .sdkInUse(by: "eir")])))

    let item = try #require(items.first)
    #expect(item.protection == .sdkInUse(by: "eir"))
}

@Test func fvmScannerIsSilentWhenFvmIsNotInstalled() async {
    let temp = TempDir()
    #expect(await FVMScanner().scan(context(temp: temp)).isEmpty)
}

// MARK: identity

/// Rule 3. The identifiers are persisted in `Settings.alwaysSkipScannerIDs`, so
/// renaming one silently un-skips it for an existing user.
@Test func flutterScannerIdentitiesAndGroupsAreStable() {
    #expect(PubCacheScanner().id == "flutter.pubCache")
    #expect(FVMScanner().id == "flutter.fvm")
    #expect(PubCacheScanner().group == .flutterAndDart)
    #expect(FVMScanner().group == .flutterAndDart)
}

/// The other half of rule 3, with a non-default `Settings`: the strings a user's
/// settings file already holds have to be the strings the scanners publish today.
@Test func skippingByIdentifierUsesTheStringsTheseScannersPublish() async {
    let temp = TempDir()
    temp.makeDirectory(".pub-cache/hosted")
    temp.makeDirectory("fvm/versions/3.38.5")

    var settings = Settings.makeDefault(home: temp.path)
    settings.alwaysSkipScannerIDs = ["flutter.pubCache", "flutter.fvm"]

    let result = await ScanEngine(scanners: [PubCacheScanner(), FVMScanner()])
        .scan(context: context(temp: temp, settings: settings))

    #expect(result.items.isEmpty)
    #expect(result.skippedScannerIDs == ["flutter.pubCache", "flutter.fvm"])
}
