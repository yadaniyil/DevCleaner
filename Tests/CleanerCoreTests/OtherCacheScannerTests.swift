import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(temp: TempDir, sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil,
                     settings: Settings? = nil) -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: temp.path), protection: .empty, projects: [],
        devices: .empty, home: temp.path, androidSDKPath: temp.path + "/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

// MARK: CocoaPods

@Test func cocoaPodsCacheAndReposAreBothOffered() async {
    let temp = TempDir()
    let cache = temp.makeDirectory("Library/Caches/CocoaPods")
    let repos = temp.makeDirectory(".cocoapods/repos")

    let items = await CocoaPodsScanner().scan(context(
        temp: temp, sizes: [cache: 2_100_000_000, repos: 173_000_000]))

    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.isDeletable })
    let total: Int64 = items.reduce(0) { $0 + $1.sizeBytes }
    #expect(total == 2_273_000_000)
}

@Test func cocoaPodsSkipsTheHalfThatIsNotThere() async throws {
    let temp = TempDir()
    let repos = temp.makeDirectory(".cocoapods/repos")

    let items = await CocoaPodsScanner().scan(context(temp: temp, sizes: [repos: 173_000_000]))

    #expect(items.map(\.name) == ["CocoaPods spec repos"])
    let item = try #require(items.first)
    // Not "re-cloned": the CocoaPods trunk repository has been a CDN mirror rather than
    // a git clone since CocoaPods 1.8. "Re-fetched" also covers additional configured
    // spec repositories without making assumptions about how they are hosted.
    #expect(item.detail == "re-fetched on the next pod install")
}

// MARK: JavaScript package caches

@Test func jsPackageCachesAreOfferedWhereTheyExist() async {
    let temp = TempDir()
    let npm = temp.makeDirectory(".npm/_cacache")
    let pnpm = temp.makeDirectory("Library/pnpm/store")

    let items = await JSPackageCacheScanner().scan(context(
        temp: temp, sizes: [npm: 3_100_000_000, pnpm: 350_000_000]))

    #expect(items.map(\.name).sorted() == ["npm cache", "pnpm store"])
    let total: Int64 = items.reduce(0) { $0 + $1.sizeBytes }
    #expect(total == 3_450_000_000)
}

// MARK: local tool caches

@Test func localToolCachesOfferOnlyTheThreeExactRegenerableDirectories() async throws {
    let temp = TempDir()
    let android = temp.makeDirectory(".android/cache")
    let androidBuild = temp.makeDirectory(".android/build-cache")
    let dart = temp.makeDirectory(".dartServer")
    temp.makeFile(".android/adbkey")
    temp.makeFile(".android/debug.keystore")
    temp.makeDirectory(".android/avd")

    let items = await LocalToolCacheScanner().scan(context(temp: temp, sizes: [
        android: 300_000_000, androidBuild: 90_000_000, dart: 40_000_000,
    ]))

    #expect(items.map(\.name) == [
        "Android download cache", "Android build cache", "Dart analyzer cache",
    ])
    #expect(items.map(\.method) == [
        .removePath(android), .removePath(androidBuild), .removePath(dart),
    ])
    #expect(items.allSatisfy { $0.isDeletable })
    #expect(items.map(\.risk) == [.elevated, .safe, .safe])
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 430_000_000)
}

/// `~/.bun/install/cache` is 1.46 GB on the machine this was written against, and it is
/// the only part of `~/.bun` that an install brings back. `~/.bun/bin` holds the globally
/// installed executables; offering the parent would take those with it.
@Test func onlyTheBunInstallCacheIsOfferedAndNotTheRestOfBun() async throws {
    let temp = TempDir()
    let cache = temp.makeDirectory(".bun/install/cache")
    temp.makeDirectory(".bun/bin")
    temp.makeDirectory(".bun/install/global")

    let items = await JSPackageCacheScanner().scan(context(temp: temp, sizes: [cache: 1_460_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "bun cache")
    #expect(item.method == .removePath(cache))
    #expect(item.sizeBytes == 1_460_000_000)
}

// MARK: allowlisted Library caches

@Test func libraryCachesUsesAnAllowlistAndIgnoresEverythingElse() async {
    let temp = TempDir()
    let xcode = temp.makeDirectory("Library/Caches/com.apple.dt.Xcode")
    let swiftpm = temp.makeDirectory("Library/Caches/org.swift.swiftpm")
    temp.makeDirectory("Library/Caches/com.spotify.client")
    temp.makeDirectory("Library/Caches/com.apple.Safari")

    let items = await LibraryCachesScanner().scan(context(
        temp: temp, sizes: [xcode: 916_000, swiftpm: 400_000_000]))

    #expect(items.map(\.name).sorted() == ["Swift Package Manager", "Xcode"])
    #expect(items.allSatisfy { $0.isDeletable })
}

@Test func libraryCachesMatchesJetBrainsAndAndroidStudioByPrefix() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/JetBrains/IntelliJIdea2026.1")
    temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")

    let items = await LibraryCachesScanner().scan(context(temp: temp))
    #expect(items.map(\.name).sorted() == ["Android Studio", "JetBrains IDEs"])
}

/// Rule 4: the fixture holds an entry that must not match. `~/Library/Caches/Google`
/// really does exist on a real dev machine and holds `Chrome` and `Chrome-headless` — a
/// browser cache, the exact thing the allowlist exists to keep out of a clean.
@Test func aBrowserCacheBesideTheAndroidStudioCacheIsNeverOffered() async throws {
    let temp = TempDir()
    let studio = temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")
    let chrome = temp.makeDirectory("Library/Caches/Google/Chrome")
    temp.makeDirectory("Library/Caches/Google/Chrome-headless")

    let items = await LibraryCachesScanner().scan(context(
        temp: temp, sizes: [studio: 3_000_000_000, chrome: 9_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "Android Studio")
    #expect(item.method == .removePath(studio))
    #expect(items.contains { $0.method == .removePath(chrome) } == false)
}

/// An allowlisted name is matched exactly unless the tool is known to append a version.
///
/// `com.apple.dt.Xcode.ITunesSoftwareService` sits beside `com.apple.dt.Xcode` in this
/// machine's `~/Library/Caches`. A prefix fallback applied to every entry offers it as
/// "Xcode" whenever the plain folder is absent — a different cache, under a name the
/// allowlist never gave it.
@Test func anExactAllowlistNameNeverMatchesALongerNeighbour() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/com.apple.dt.Xcode.ITunesSoftwareService")
    temp.makeDirectory("Library/Caches/org.swift.swiftpm.extra")
    temp.makeDirectory("Library/Caches/HomebrewPrivate")

    let items = await LibraryCachesScanner().scan(context(temp: temp))
    #expect(items.isEmpty)
}

/// Two installed versions produce two rows with the same name, so the folder name has
/// to reach the detail. Without it the user is asked to pick between rows they cannot
/// tell apart, and the paths are the only thing that differs.
@Test func twoAndroidStudioVersionsAreToldApartByTheirDetail() async throws {
    let temp = TempDir()
    let older = temp.makeDirectory("Library/Caches/Google/AndroidStudio2024.3")
    let newer = temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")

    let items = await LibraryCachesScanner().scan(context(
        temp: temp, sizes: [older: 1_200_000_000, newer: 3_000_000_000]))

    #expect(items.count == 2)
    #expect(items.map(\.name) == ["Android Studio", "Android Studio"])
    // Sorted by folder name, so the rows keep a fixed order between scans.
    #expect(items.map(\.method) == [.removePath(older), .removePath(newer)])
    let first = try #require(items.first)
    #expect(first.detail == "AndroidStudio2024.3, rebuilt the next time the IDE opens a project")
}

/// Rule 4 for the version scan. A plain file named like a version folder would be
/// offered as a multi-gigabyte IDE cache and measured as zero.
@Test func aFileNamedLikeAnAndroidStudioVersionIsNotOffered() async {
    let temp = TempDir()
    temp.makeFile("Library/Caches/Google/AndroidStudio2025.2")

    let items = await LibraryCachesScanner().scan(context(temp: temp))
    #expect(items.isEmpty)
}

// MARK: directory filter for the fixed locations

/// The same rule for the fixed-location scanners. A file left where a cache used to be
/// would be offered under the cache's name, and measured as zero.
@Test func aFileNamedLikeAFixedCacheLocationIsNotOffered() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory(".npm/_cacache")
    temp.makeFile("Library/pnpm/store")
    temp.makeFile("Library/Caches/CocoaPods")

    let jsItems = await JSPackageCacheScanner().scan(context(temp: temp, sizes: [real: 3_100_000_000]))
    #expect(jsItems.map(\.name) == ["npm cache"])
    let item = try #require(jsItems.first)
    #expect(item.method == .removePath(real))

    #expect(await CocoaPodsScanner().scan(context(temp: temp)).isEmpty)
}

// MARK: deletion targets

/// Rule 2: assert the deletion target. Name, detail and size all come from somewhere
/// other than the path, so asserting them does not constrain what would be removed — a
/// path mutated from the child to its parent passes every other check in this file.
@Test func otherCacheItemsPinTheirDeletionPaths() async throws {
    let temp = TempDir()
    let podsCache = temp.makeDirectory("Library/Caches/CocoaPods")
    let podsRepos = temp.makeDirectory(".cocoapods/repos")
    let npm = temp.makeDirectory(".npm/_cacache")
    let pnpm = temp.makeDirectory("Library/pnpm/store")
    let yarn = temp.makeDirectory("Library/Caches/Yarn")
    let android = temp.makeDirectory(".android/cache")
    let dart = temp.makeDirectory(".dartServer")
    let xcode = temp.makeDirectory("Library/Caches/com.apple.dt.Xcode")
    let jetbrains = temp.makeDirectory("Library/Caches/JetBrains")

    let pods = await CocoaPodsScanner().scan(context(temp: temp))
    let cacheItem = try #require(pods.first { $0.name == "CocoaPods cache" })
    #expect(cacheItem.method == .removePath(podsCache))
    #expect(cacheItem.id == "other.cocoapods|\(podsCache)")
    #expect(cacheItem.group == .otherCaches)
    #expect(cacheItem.detail == "re-downloaded on the next pod install")
    let reposItem = try #require(pods.first { $0.name == "CocoaPods spec repos" })
    #expect(reposItem.method == .removePath(podsRepos))
    #expect(reposItem.id == "other.cocoapods|\(podsRepos)")

    let js = await JSPackageCacheScanner().scan(context(temp: temp))
    #expect(try #require(js.first { $0.name == "npm cache" }).method == .removePath(npm))
    #expect(try #require(js.first { $0.name == "pnpm store" }).method == .removePath(pnpm))
    let yarnItem = try #require(js.first { $0.name == "Yarn cache" })
    #expect(yarnItem.method == .removePath(yarn))
    #expect(yarnItem.id == "other.jsPackages|\(yarn)")
    #expect(yarnItem.group == .otherCaches)

    let local = await LocalToolCacheScanner().scan(context(temp: temp))
    #expect(try #require(local.first { $0.name == "Android download cache" }).method
            == .removePath(android))
    #expect(try #require(local.first { $0.name == "Dart analyzer cache" }).method
            == .removePath(dart))

    let library = await LibraryCachesScanner().scan(context(temp: temp))
    let xcodeItem = try #require(library.first { $0.name == "Xcode" })
    #expect(xcodeItem.method == .removePath(xcode))
    #expect(xcodeItem.id == "other.libraryCaches|\(xcode)")
    #expect(xcodeItem.group == .otherCaches)
    // The container itself, not the version folders inside it.
    #expect(try #require(library.first { $0.name == "JetBrains IDEs" }).method
            == .removePath(jetbrains))
}

// MARK: risk

/// Every package cache here comes back over the network or not at all, which is what
/// `.elevated` means in this model — `.safe` is documented as "regenerated
/// automatically by a normal build". The pub cache and the Gradle dependency cache are
/// already marked this way for the same reason.
@Test func everyPackageCacheIsElevatedRiskBecauseItComesBackOverTheNetwork() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/CocoaPods")
    temp.makeDirectory(".cocoapods/repos")
    temp.makeDirectory(".npm/_cacache")
    temp.makeDirectory("Library/pnpm/store")
    temp.makeDirectory("Library/Caches/Yarn")
    temp.makeDirectory(".bun/install/cache")
    temp.makeDirectory(".android/cache")
    temp.makeDirectory(".android/build-cache")
    temp.makeDirectory(".dartServer")

    let pods = await CocoaPodsScanner().scan(context(temp: temp))
    let js = await JSPackageCacheScanner().scan(context(temp: temp))

    #expect(pods.count == 2)
    #expect(js.count == 4)
    #expect((pods + js).allSatisfy { $0.risk == .elevated })
}

/// The `~/Library/Caches` allowlist is mixed, so the risk is per entry. SwiftPM
/// re-clones its packages and Homebrew re-downloads its bottles; the IDE caches are
/// indexes rebuilt locally, which costs time but never a download.
@Test func onlyTheDownloadedLibraryCachesAreElevatedRisk() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/com.apple.dt.Xcode")
    temp.makeDirectory("Library/Caches/org.swift.swiftpm")
    temp.makeDirectory("Library/Caches/Homebrew")
    temp.makeDirectory("Library/Caches/JetBrains")
    temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")

    let items = await LibraryCachesScanner().scan(context(temp: temp))

    #expect(items.count == 5)
    #expect(items.filter { $0.risk == .elevated }.map(\.name).sorted()
            == ["Homebrew downloads", "Swift Package Manager"])
}

/// Every row says how the cache comes back, because that sentence is the only thing
/// telling the user what a tick costs them: a rebuild they will not notice, or a
/// download they cannot start on a plane. Pinned here so a wording change is deliberate.
@Test func everyOtherCacheRowSaysHowItComesBack() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/CocoaPods")
    temp.makeDirectory(".cocoapods/repos")
    temp.makeDirectory(".npm/_cacache")
    temp.makeDirectory("Library/pnpm/store")
    temp.makeDirectory("Library/Caches/Yarn")
    temp.makeDirectory(".bun/install/cache")
    temp.makeDirectory(".android/cache")
    temp.makeDirectory(".android/build-cache")
    temp.makeDirectory(".dartServer")
    temp.makeDirectory("Library/Caches/com.apple.dt.Xcode")
    temp.makeDirectory("Library/Caches/org.swift.swiftpm")
    temp.makeDirectory("Library/Caches/Homebrew")
    temp.makeDirectory("Library/Caches/JetBrains")
    temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")

    var details: [String: String] = [:]
    for scanner in [CocoaPodsScanner() as any CleanupScanner,
                    JSPackageCacheScanner(), LocalToolCacheScanner(), LibraryCachesScanner()] {
        for item in await scanner.scan(context(temp: temp)) {
            // A row with no detail at all records as "<none>", so dropping the text
            // fails here rather than quietly disappearing from the comparison.
            details[item.name] = item.detail ?? "<none>"
        }
    }

    #expect(details == [
        "CocoaPods cache": "re-downloaded on the next pod install",
        "CocoaPods spec repos": "re-fetched on the next pod install",
        "npm cache": "re-downloaded on the next npm install",
        "pnpm store": "re-downloaded on the next pnpm install",
        "Yarn cache": "re-downloaded on the next yarn install",
        "bun cache": "re-downloaded on the next bun install",
        "Android download cache": "re-downloaded by Android tools when needed",
        "Android build cache": "rebuilt on the next Android build",
        "Dart analyzer cache": "rebuilt when the analyzer next runs",
        "Xcode": "rebuilt the next time Xcode runs",
        "Swift Package Manager": "re-downloaded on the next package resolve",
        "Homebrew downloads": "re-downloaded on the next brew install",
        "JetBrains IDEs": "rebuilt the next time the IDE opens a project",
        "Android Studio": "AndroidStudio2025.2, rebuilt the next time the IDE opens a project",
    ])
}

// MARK: batching

/// Rule 9: `sizes(of:)` batches its input and holds four `du` processes open at most,
/// so one call per location defeats that cap. Nothing in the returned items shows it.
@Test func eachOtherCacheScannerMeasuresEverythingInOneBatchedCall() async throws {
    let temp = TempDir()
    let podsCache = temp.makeDirectory("Library/Caches/CocoaPods")
    let podsRepos = temp.makeDirectory(".cocoapods/repos")
    let npm = temp.makeDirectory(".npm/_cacache")
    let pnpm = temp.makeDirectory("Library/pnpm/store")
    let xcode = temp.makeDirectory("Library/Caches/com.apple.dt.Xcode")
    let studio = temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")
    let android = temp.makeDirectory(".android/cache")
    let dart = temp.makeDirectory(".dartServer")

    let podsMeasurer = CallCountingSizeMeasurer([podsCache: 2_100_000_000])
    let pods = await CocoaPodsScanner().scan(context(temp: temp, sizeMeasurer: podsMeasurer))
    #expect(pods.count == 2)
    var callCount = await podsMeasurer.callCount
    #expect(callCount == 1)
    var batch = try #require(await podsMeasurer.batches.first)
    #expect(batch.sorted() == [podsCache, podsRepos].sorted())

    let jsMeasurer = CallCountingSizeMeasurer([npm: 3_100_000_000])
    let js = await JSPackageCacheScanner().scan(context(temp: temp, sizeMeasurer: jsMeasurer))
    #expect(js.count == 2)
    callCount = await jsMeasurer.callCount
    #expect(callCount == 1)
    batch = try #require(await jsMeasurer.batches.first)
    #expect(batch.sorted() == [npm, pnpm].sorted())

    let libraryMeasurer = CallCountingSizeMeasurer([xcode: 916_000])
    let library = await LibraryCachesScanner().scan(context(temp: temp, sizeMeasurer: libraryMeasurer))
    #expect(library.count == 2)
    callCount = await libraryMeasurer.callCount
    #expect(callCount == 1)
    batch = try #require(await libraryMeasurer.batches.first)
    #expect(batch.sorted() == [xcode, studio].sorted())

    let localMeasurer = CallCountingSizeMeasurer([android: 300_000_000])
    let local = await LocalToolCacheScanner().scan(context(temp: temp, sizeMeasurer: localMeasurer))
    #expect(local.count == 2)
    callCount = await localMeasurer.callCount
    #expect(callCount == 1)
    batch = try #require(await localMeasurer.batches.first)
    #expect(batch.sorted() == [android, dart].sorted())
}

// MARK: nothing installed

@Test func otherScannersAreSilentWhenNothingIsInstalled() async {
    let temp = TempDir()
    #expect(await CocoaPodsScanner().scan(context(temp: temp)).isEmpty)
    #expect(await JSPackageCacheScanner().scan(context(temp: temp)).isEmpty)
    #expect(await LocalToolCacheScanner().scan(context(temp: temp)).isEmpty)
    #expect(await LibraryCachesScanner().scan(context(temp: temp)).isEmpty)
}

// MARK: identity

/// Rule 3. The identifiers are persisted in `Settings.alwaysSkipScannerIDs`, so
/// renaming one silently un-skips it for an existing user.
@Test func otherCacheScannerIdentitiesAndGroupsAreStable() {
    #expect(CocoaPodsScanner().id == "other.cocoapods")
    #expect(JSPackageCacheScanner().id == "other.jsPackages")
    #expect(LocalToolCacheScanner().id == "other.localToolCaches")
    #expect(LibraryCachesScanner().id == "other.libraryCaches")
    #expect(CocoaPodsScanner().group == .otherCaches)
    #expect(JSPackageCacheScanner().group == .otherCaches)
    #expect(LocalToolCacheScanner().group == .otherCaches)
    #expect(LibraryCachesScanner().group == .otherCaches)
    #expect(CocoaPodsScanner().title == "CocoaPods")
    #expect(JSPackageCacheScanner().title == "JavaScript package caches")
    #expect(LocalToolCacheScanner().title == "Local tool caches")
    #expect(LibraryCachesScanner().title == "Developer tool caches")
}

/// The other half of rule 3, with a non-default `Settings`: the strings a user's
/// settings file already holds have to be the strings these scanners publish today.
@Test func skippingByIdentifierUsesTheStringsTheseCacheScannersPublish() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/CocoaPods")
    temp.makeDirectory(".npm/_cacache")
    temp.makeDirectory(".android/cache")
    temp.makeDirectory("Library/Caches/com.apple.dt.Xcode")

    var settings = Settings.makeDefault(home: temp.path)
    settings.alwaysSkipScannerIDs = [
        "other.cocoapods", "other.jsPackages", "other.localToolCaches", "other.libraryCaches",
    ]

    let result = await ScanEngine(
        scanners: [
            CocoaPodsScanner(), JSPackageCacheScanner(), LocalToolCacheScanner(),
            LibraryCachesScanner(),
        ]
    ).scan(context: context(temp: temp, settings: settings))

    #expect(result.items.isEmpty)
    #expect(result.skippedScannerIDs
            == [
                "other.cocoapods", "other.jsPackages", "other.localToolCaches",
                "other.libraryCaches",
            ])
}
