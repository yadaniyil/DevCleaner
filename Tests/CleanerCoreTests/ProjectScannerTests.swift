import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(temp: TempDir, projects: [DiscoveredProject],
                     protection: ProtectionSet = .empty,
                     sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil,
                     settings: Settings? = nil,
                     activity: [String: Date] = [:]) -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: temp.path),
        protection: protection, projects: projects, activity: activity,
        devices: .empty, home: temp.path, androidSDKPath: temp.path + "/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

/// The memberwise initialiser takes eight arguments and none of them has a default,
/// and the Gradle field is keyed by distribution directory name rather than version.
private func protection(projects: [String: ProtectionReason]) -> ProtectionSet {
    ProtectionSet(
        projects: projects, keptSimulatorUDID: nil, keptAVDName: nil,
        protectedSimulatorUDIDs: [:], protectedAVDNames: [:],
        flutterVersions: [:], gradleDistributions: [:], runtimeIdentifiers: [:])
}

private func flutterProject(_ temp: TempDir, _ name: String) -> DiscoveredProject {
    DiscoveredProject(path: temp.path + "/dev/" + name, name: name)
}

// MARK: the folders that are offered

@Test func offersEveryBuildFolderOfAnUnprotectedProject() async {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/stale/build")
    let dartTool = temp.makeDirectory("dev/stale/.dart_tool")
    let pods = temp.makeDirectory("dev/stale/ios/Pods")
    let androidGradle = temp.makeDirectory("dev/stale/android/.gradle")
    temp.makeFile("dev/stale/pubspec.yaml")

    let project = DiscoveredProject(path: temp.path + "/dev/stale", name: "stale")
    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        sizes: [build: 2_000_000_000, dartTool: 50_000_000,
                pods: 400_000_000, androidGradle: 90_000_000]))

    #expect(items.count == 4)
    // Closure rather than the `\.isDeletable` key path the brief wrote: the `#expect`
    // macro expands a key-path argument into a call the compiler treats as throwing.
    #expect(items.allSatisfy { $0.isDeletable })
    #expect(items.allSatisfy { $0.detail == "stale" })
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 2_540_000_000)
}

@Test func projectWithNoBuildFoldersProducesNothing() async {
    let temp = TempDir()
    temp.makeFile("dev/clean/pubspec.yaml")
    let project = DiscoveredProject(path: temp.path + "/dev/clean", name: "clean")
    #expect(await ProjectBuildOutputScanner().scan(context(temp: temp, projects: [project])).isEmpty)
}

@Test func nodeModulesIsOfferedForNodeProjects() async throws {
    let temp = TempDir()
    let modules = temp.makeDirectory("dev/site/node_modules")
    temp.makeFile("dev/site/package.json")
    let project = DiscoveredProject(path: temp.path + "/dev/site", name: "site")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project], sizes: [modules: 800_000_000]))

    #expect(items.map(\.name) == ["node_modules"])
    let item = try #require(items.first)
    #expect(item.sizeBytes == 800_000_000)
}

@Test func itemNamesUseTheRelativePathSoTheyAreUnambiguous() async {
    let temp = TempDir()
    temp.makeDirectory("dev/app/build")
    temp.makeDirectory("dev/app/android/build")
    temp.makeFile("dev/app/pubspec.yaml")
    let project = DiscoveredProject(path: temp.path + "/dev/app", name: "app")

    let items = await ProjectBuildOutputScanner().scan(context(temp: temp, projects: [project]))
    #expect(items.map(\.name).sorted() == ["android/build", "build"])
}

/// Rule 4: a fixture of only matching entries cannot test a filter. Every other name
/// here is a real directory in a Flutter project on a real dev machine, and every one of them
/// holds source code, tests or version history. Offering `lib` would trash the project.
@Test func onlyTheNamedBuildFoldersAreOfferedOutOfEverythingElseAProjectHolds() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/app/build")
    temp.makeDirectory("dev/app/lib")
    temp.makeDirectory("dev/app/test")
    temp.makeDirectory("dev/app/assets")
    temp.makeDirectory("dev/app/.git")
    temp.makeDirectory("dev/app/ios/Runner")
    temp.makeDirectory("dev/app/android/app")
    temp.makeDirectory("dev/app/.idea")
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")], sizes: [build: 2_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "build")
    #expect(item.method == .removePath(build))
}

/// Rule 4 again, for the other half of the filter. `fileExists(atPath:)` alone is true
/// for a plain file, so a lock file or a stray script named `build` would be offered
/// under the name of a multi-gigabyte folder and measured as zero.
@Test func aPlainFileNamedLikeABuildFolderIsNotOffered() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("dev/app/.dart_tool")
    temp.makeFile("dev/app/build")
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")], sizes: [real: 50_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == ".dart_tool")
    #expect(item.method == .removePath(real))
}

/// A `build` pointing at another disk is a real setup, and it is worse than noise:
/// `du` does not follow a symlink given as its argument, so the row would claim zero
/// bytes, and trashing the link would remove the user's link while freeing nothing.
@Test func aSymlinkedBuildFolderIsNotOffered() async throws {
    let temp = TempDir()
    let elsewhere = temp.makeDirectory("elsewhere/build-output")
    let dartTool = temp.makeDirectory("dev/app/.dart_tool")
    temp.makeSymlink("dev/app/build", to: elsewhere)
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")],
        sizes: [dartTool: 50_000_000, elsewhere: 9_000_000_000]))

    #expect(items.map(\.name) == [".dart_tool"])
    let item = try #require(items.first)
    #expect(item.method == .removePath(dartTool))
}

/// `ProjectDiscovery.discover(roots:)` appends per root and never de-duplicates, so a
/// user whose `projectRoots` hold both `~/dev` and `~/dev/app` gets the same project
/// twice. Two rows with the same `CleanupItem.id` double the reclaimable total and give
/// the UI two rows it cannot tell apart.
@Test func aProjectListedTwiceProducesOneRowPerFolder() async {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/app/build")
    temp.makeFile("dev/app/pubspec.yaml")
    let project = flutterProject(temp, "app")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project, project], sizes: [build: 2_000_000_000]))

    #expect(items.count == 1)
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 2_000_000_000)
}

/// The whole list in one fixture, so that dropping an entry from `buildFolders` fails
/// here rather than quietly costing the user that folder's space forever.
///
/// The risk split matters too: `pod install` and `npm install` both go to the network,
/// and a lockfile can name a version that has since been unpublished. `.safe` in this
/// model means a build alone brings it back, which is not true of either.
@Test func everyNamedFolderIsOfferedAndOnlyTheNetworkOnesAreElevatedRisk() async {
    let temp = TempDir()
    for folder in [
        "build", ".dart_tool", ".symlinks", "ios/build", "android/build", "app/build",
        ".build", "DerivedData",
        "Pods", "ios/Pods", "macos/Pods",
        ".gradle", "android/.gradle",
        "node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".expo",
    ] {
        temp.makeDirectory("dev/app/\(folder)")
    }
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")]))

    #expect(items.map(\.name).sorted() == [
        ".build", ".dart_tool", ".expo", ".gradle", ".next", ".nuxt", ".parcel-cache",
        ".svelte-kit", ".symlinks", ".turbo", "DerivedData", "Pods",
        "android/.gradle", "android/build", "app/build", "build",
        "ios/Pods", "ios/build", "macos/Pods", "node_modules",
    ])
    let elevated = items.filter { $0.risk == .elevated }.map(\.name).sorted()
    #expect(elevated == ["Pods", "ios/Pods", "macos/Pods", "node_modules"])
    let safe = items.filter { $0.risk == .safe }.map(\.name).sorted()
    #expect(safe == [
        ".build", ".dart_tool", ".expo", ".gradle", ".next", ".nuxt", ".parcel-cache",
        ".svelte-kit", ".symlinks", ".turbo", "DerivedData",
        "android/.gradle", "android/build", "app/build", "build", "ios/build",
    ])
}

/// `target` is the one entry that cannot be on the fixed list, because `target` is an
/// ordinary directory name. A Flutter project's `target`, a Makefile-driven C project's,
/// an Xcode scheme's — all of them are the user's own work. `Cargo.toml` at the root is
/// the one thing that says this `target` belongs to Cargo.
///
/// Rule 4: both projects here have a `target`, so a scanner that offered it
/// unconditionally passes every other assertion in this file while trashing source.
@Test func targetIsOfferedOnlyForAProjectWithACargoManifest() async throws {
    let temp = TempDir()
    let rust = temp.makeDirectory("dev/rusty/target")
    temp.makeFile("dev/rusty/Cargo.toml")
    temp.makeDirectory("dev/app/target")
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp,
        projects: [DiscoveredProject(path: temp.path + "/dev/rusty", name: "rusty"),
                   flutterProject(temp, "app")],
        sizes: [rust: 4_100_000_000]))

    #expect(items.map(\.name) == ["target"])
    let item = try #require(items.first)
    #expect(item.detail == "rusty")
    #expect(item.method == .removePath(rust))
    #expect(item.sizeBytes == 4_100_000_000)
    #expect(item.risk == .safe)
}

// MARK: build-variant folders

/// The folders no fixed list can name. `~/dev/workspace-one/sample-game` holds `.build`
/// (946 MB) plus ten siblings — `.build-rel`, `.build-release`, `.build-cows`,
/// `.build-pond`, … — ≈3.2 GB together, each holding an Xcode derived-data tree. The
/// suffix is made up on the spot by whoever ran the build, so the only fixed part is the
/// `.build-` prefix and what a build leaves inside.
///
/// Sorted by name, like the worktree rows and for the same reason: `contentsOfDirectory`
/// promises no order, and a list that reshuffles between scans moves the row the user is
/// about to click.
@Test func buildVariantFoldersHoldingBuildOutputAreOfferedInNameOrder() async throws {
    let temp = TempDir()
    let plain = temp.makeDirectory("dev/game/.build")
    temp.makeDirectory("dev/game/.build/Build")
    let release = temp.makeDirectory("dev/game/.build-release")
    temp.makeDirectory("dev/game/.build-release/ModuleCache.noindex")
    let cows = temp.makeDirectory("dev/game/.build-cows")
    temp.makeFile("dev/game/.build-cows/info.plist")
    temp.makeDirectory("dev/game/Game.xcodeproj")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [DiscoveredProject(path: temp.path + "/dev/game", name: "game")],
        sizes: [plain: 946_000_000, release: 458_000_000, cows: 120_000_000]))

    // Unsorted, so the fixed list's `.build` is pinned ahead of the variants and the
    // variants are pinned in name order.
    #expect(items.map(\.name) == [".build", ".build-cows", ".build-release"])
    let variant = try #require(items.first { $0.name == ".build-release" })
    #expect(variant.method == .removePath(release))
    #expect(variant.id == "projects.buildOutput|\(release)")
    #expect(variant.sizeBytes == 458_000_000)
    #expect(variant.detail == "game")
    #expect(variant.risk == .safe)
    #expect(variant.isDeletable)
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 1_524_000_000)
}

/// Rule 4, and the reason the marker rule exists at all. This scanner reaches inside the
/// directories the user writes code in: `.build-notes` is as plausible a name for
/// something they wrote by hand as `.build-rel` is for build output, and the prefix alone
/// cannot tell them apart. A plain file and a symlink are both refused too — the symlink
/// because `du` does not follow one given as its argument, so the row would claim zero
/// bytes while trashing it costs the user their link.
@Test func aBuildVariantFolderWithoutBuildOutputInsideItIsNotOffered() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("dev/game/.build-rel")
    temp.makeDirectory("dev/game/.build-rel/Index.noindex")
    // Hand-written notes, an empty directory, a plain file, and a link to real output.
    temp.makeFile("dev/game/.build-notes/outline.md")
    temp.makeDirectory("dev/game/.build-notes/chapters")
    temp.makeDirectory("dev/game/.build-empty")
    temp.makeFile("dev/game/.build-plan")
    let elsewhere = temp.makeDirectory("elsewhere/.build-linked")
    temp.makeDirectory("elsewhere/.build-linked/Build")
    temp.makeSymlink("dev/game/.build-link", to: elsewhere)
    temp.makeDirectory("dev/game/Game.xcodeproj")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [DiscoveredProject(path: temp.path + "/dev/game", name: "game")],
        sizes: [real: 300_000_000, elsewhere: 9_000_000_000]))

    #expect(items.map(\.name) == [".build-rel"])
    #expect(try #require(items.first).method == .removePath(real))
}

/// Every marker, one fixture each, so dropping one from the set fails here rather than
/// quietly costing the user that folder's space for ever. Each name is something only a
/// build writes: the first four are Xcode derived data, the last two are SwiftPM's
/// build directory.
@Test func everyBuildOutputMarkerIsEnoughToOfferAVariantFolder() async {
    let temp = TempDir()
    let markers = ["Build", "ModuleCache.noindex", "Index.noindex", "info.plist",
                   "checkouts", "workspace-state.json"]
    for (index, marker) in markers.enumerated() {
        temp.makeFile("dev/game/.build-\(index)/\(marker)")
    }
    temp.makeDirectory("dev/game/Game.xcodeproj")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [DiscoveredProject(path: temp.path + "/dev/game", name: "game")]))

    #expect(items.map(\.name) == (0..<markers.count).map { ".build-\($0)" })
}

/// **No marker may be an ordinary English word.** `debug` and `release` were markers, and
/// they are what a person writing build scripts by hand calls things.
///
/// Both fixtures here are the user's own work. `.build-scripts/release` is a shell script;
/// `.build-config/release/` is a directory of plists. Under the old set each was offered
/// for deletion inside the directory the user writes code in — and because
/// `ActivityInspector.isIgnored` asks this same question, editing either of them also
/// stopped counting as working on the project, so the project lost its protection at the
/// same moment its hand-written folder became deletable.
///
/// The real SwiftPM folder beside them still has to be found, or the fix would have bought
/// safety by making the scanner useless: a SwiftPM build directory always carries
/// `workspace-state.json` next to its `debug`.
@Test func aVariantFolderMarkedOnlyByAnEverydayWordIsNotOffered() async throws {
    let temp = TempDir()
    // The user's own build scripts: a file called `release`, and a folder called `release`.
    temp.makeFile("dev/game/.build-scripts/release", contents: "#!/bin/sh\nxcodebuild\n")
    temp.makeFile("dev/game/.build-scripts/debug", contents: "#!/bin/sh\n")
    temp.makeDirectory("dev/game/.build-config/release")
    temp.makeFile("dev/game/.build-config/release/Signing.plist")
    temp.makeDirectory("dev/game/.build-config/debug")
    // A real SwiftPM build directory, which is what the two words were there for.
    let swiftpm = temp.makeDirectory("dev/game/.build-tools")
    temp.makeDirectory("dev/game/.build-tools/debug")
    temp.makeFile("dev/game/.build-tools/workspace-state.json", contents: "{}")
    temp.makeDirectory("dev/game/Game.xcodeproj")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [DiscoveredProject(path: temp.path + "/dev/game", name: "game")],
        sizes: [swiftpm: 1_200_000_000]))

    #expect(items.map(\.name) == [".build-tools"])
    #expect(try #require(items.first).method == .removePath(swiftpm))
    // Asked directly as well, because `ActivityInspector` asks it this way and a folder the
    // scanner refuses to offer has to count as the user's work over there too.
    let manager = FileManager.default
    #expect(!ProjectBuildOutputScanner.holdsBuildOutput(
        temp.path + "/dev/game/.build-scripts", fileManager: manager))
    #expect(!ProjectBuildOutputScanner.holdsBuildOutput(
        temp.path + "/dev/game/.build-config", fileManager: manager))
    #expect(ProjectBuildOutputScanner.holdsBuildOutput(swiftpm, fileManager: manager))
}

/// Rule 9 for the paths this adds, as `worktreeBuildFoldersJoinTheSameSingleMeasurementBatch`
/// does for the worktrees: a separate listing pass would be a second `sizes(of:)` call,
/// and nothing in the returned items would show it.
@Test func buildVariantFoldersJoinTheSameSingleMeasurementBatch() async throws {
    let temp = TempDir()
    let plain = temp.makeDirectory("dev/game/.build")
    temp.makeDirectory("dev/game/.build/Build")
    let variant = temp.makeDirectory("dev/game/.build-pond")
    temp.makeDirectory("dev/game/.build-pond/Build")
    temp.makeDirectory("dev/game/Game.xcodeproj")
    let measurer = CallCountingSizeMeasurer([plain: 946_000_000, variant: 210_000_000])

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [DiscoveredProject(path: temp.path + "/dev/game", name: "game")],
        sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [plain, variant].sorted())
}

/// A variant folder inside a protected project is a folder inside a protected project,
/// exactly like `build`: never offered, and its bytes belong in that project's summary row.
@Test func aBuildVariantFolderInsideAProtectedProjectIsNotOfferedAndJoinsItsSummary() async throws {
    let temp = TempDir()
    let plain = temp.makeDirectory("dev/game/.build")
    temp.makeDirectory("dev/game/.build/Build")
    let variant = temp.makeDirectory("dev/game/.build-cows")
    temp.makeDirectory("dev/game/.build-cows/Build")
    temp.makeDirectory("dev/game/Game.xcodeproj")
    let project = DiscoveredProject(path: temp.path + "/dev/game", name: "game")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .pinnedProject]),
        sizes: [plain: 946_000_000, variant: 120_000_000]))

    #expect(items.count == 1)
    let summary = try #require(items.first)
    #expect(summary.name == "game")
    #expect(!summary.isDeletable)
    #expect(summary.sizeBytes == 1_066_000_000)
}

// MARK: build output inside worktrees

/// The folder the fixed list misses. On a real dev machine
/// `Sample iOS App/.claude/worktrees/feature-sync/build` is 5.99 GB while the
/// project's own rows add up to 2.68 GB, so the row the user reads understates the
/// project by more than half.
///
/// One row per worktree, so cleaning the worktree that is finished does not take the one
/// still being worked in. Rule 4 rides along twice: a worktree with no build output and a
/// worktree holding source rather than build output both have to stay out, and so does
/// the `worktrees` folder itself. Rule 2: each row pins its own deletion path.
@Test func buildOutputInsideEachWorktreeIsOfferedAsItsOwnRow() async throws {
    let temp = TempDir()
    let own = temp.makeDirectory("dev/sample-ios-app/build")
    let first = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/feature-sync/build")
    let second = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/security-hardening/build")
    // A worktree that has never been built, and one that holds only source.
    temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/untouched")
    temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/docs-only/lib")
    temp.makeFile("dev/sample-ios-app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "sample-ios-app")],
        sizes: [own: 2_680_000_000, first: 5_990_000_000, second: 1_200_000_000]))

    // Unsorted, so the worktree rows are pinned in worktree-name order rather than in
    // whatever order `contentsOfDirectory` happened to return.
    #expect(items.map(\.name) == [
        "build",
        ".claude/worktrees/feature-sync/build",
        ".claude/worktrees/security-hardening/build",
    ])
    let worktree = try #require(items.first { $0.name == ".claude/worktrees/feature-sync/build" })
    #expect(worktree.method == .removePath(first))
    #expect(worktree.id == "projects.buildOutput|\(first)")
    #expect(worktree.sizeBytes == 5_990_000_000)
    #expect(worktree.detail == "sample-ios-app")
    #expect(worktree.isDeletable)
    // A build folder is rebuilt locally wherever it sits, so it is `.safe` here too.
    #expect(worktree.risk == .safe)

    #expect(try #require(items.first { $0.name == ".claude/worktrees/security-hardening/build" })
        .method == .removePath(second))
    // The project's whole holding is now visible, not just its own build folder.
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 9_870_000_000)
}

/// The rule that is absolute and that this change must not weaken. A worktree build
/// folder inside a **pinned** project is a folder inside a pinned project, exactly like
/// `build` or `ios/Pods`, so it is never offered — and its bytes belong in that project's
/// summary row, which is the row that answers "where did my 40 GB go?".
///
/// Pinned rather than merely active, deliberately. A pin is the user's own hard no and is
/// the reason this rule still exists; recent activity now produces an offered-unticked row
/// instead, which `anActiveProjectsFoldersAreOfferedUntickedWithTheReasonOnEachRow`
/// covers.
@Test func aWorktreeBuildFolderInsideAPinnedProjectIsNotOfferedAndJoinsItsSummary() async throws {
    let temp = TempDir()
    let own = temp.makeDirectory("dev/sample-ios-app/build")
    let worktree = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/feature-sync/build")
    temp.makeFile("dev/sample-ios-app/pubspec.yaml")
    let project = flutterProject(temp, "sample-ios-app")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .pinnedProject]),
        sizes: [own: 2_680_000_000, worktree: 5_990_000_000]))

    #expect(items.count == 1)
    let summary = try #require(items.first)
    #expect(summary.name == "sample-ios-app")
    #expect(!summary.isDeletable)
    #expect(!summary.selectedByDefault)
    #expect(summary.sizeBytes == 8_670_000_000)
    #expect(summary.method == .removePath(project.path))
}

/// Rule 9 again, for the paths this change adds. A separate listing pass for worktrees
/// would be a second `sizes(of:)` call, and nothing in the returned items would show it.
@Test func worktreeBuildFoldersJoinTheSameSingleMeasurementBatch() async throws {
    let temp = TempDir()
    let own = temp.makeDirectory("dev/sample-ios-app/build")
    let worktree = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/feature-sync/build")
    temp.makeFile("dev/sample-ios-app/pubspec.yaml")
    let measurer = CallCountingSizeMeasurer([own: 2_680_000_000, worktree: 5_990_000_000])

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "sample-ios-app")], sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [own, worktree].sorted())
}

/// A plain file named `build` inside a worktree must not be offered, for the same reason
/// it must not be offered inside the project: it would be shown under the name of a
/// multi-gigabyte folder and measured as zero.
@Test func aPlainFileNamedBuildInsideAWorktreeIsNotOffered() async throws {
    let temp = TempDir()
    let real = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/real/build")
    temp.makeFile("dev/sample-ios-app/.claude/worktrees/fake/build")
    temp.makeFile("dev/sample-ios-app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "sample-ios-app")], sizes: [real: 1_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == ".claude/worktrees/real/build")
    #expect(item.method == .removePath(real))
}

/// A worktree of a Swift package builds into `.build`, not `build`, so both are offered
/// beside each other — one row each, exactly as the project's own `build` and `.build`
/// are two rows. Without the second name the biggest folder in an agent's worktree is
/// invisible, which is the same hole `worktreeBuildFolders` was written to close.
///
/// Rule 4 rides along: the worktree holding only `lib` contributes nothing.
@Test func bothBuildFolderSpellingsAreOfferedInsideEachWorktree() async throws {
    let temp = TempDir()
    let plain = temp.makeDirectory("dev/pkg/.claude/worktrees/feature-sync/build")
    let dotted = temp.makeDirectory("dev/pkg/.claude/worktrees/feature-sync/.build")
    let otherDotted = temp.makeDirectory("dev/pkg/.claude/worktrees/review/.build")
    temp.makeDirectory("dev/pkg/.claude/worktrees/docs-only/lib")
    temp.makeFile("dev/pkg/Package.swift")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [DiscoveredProject(path: temp.path + "/dev/pkg", name: "pkg")],
        sizes: [plain: 1_000_000_000, dotted: 2_400_000_000, otherDotted: 800_000_000]))

    #expect(items.map(\.name) == [
        ".claude/worktrees/feature-sync/build",
        ".claude/worktrees/feature-sync/.build",
        ".claude/worktrees/review/.build",
    ])
    #expect(try #require(items.first { $0.name == ".claude/worktrees/feature-sync/.build" })
        .method == .removePath(dotted))
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 4_200_000_000)
}

/// A worktree build folder is inside a project, so the project root the user declared
/// already covers it — no new `PathGuard` root, and the project directory itself is still
/// refused.
@Test func aWorktreeBuildFolderPassesTheRealRunGuard() throws {
    let temp = TempDir()
    let root = temp.makeDirectory("dev")
    let project = temp.makeDirectory("dev/sample-ios-app")
    let worktree = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/feature-sync/build")

    let sut = PathGuard.forRun(home: temp.path, projectRoots: [root], projectPaths: [project])

    #expect(throws: Never.self) { _ = try sut.validate(worktree) }
    #expect(throws: PathGuard.Violation.forbiddenTarget(project)) { _ = try sut.validate(project) }
}

// MARK: protection — the reason this scanner exists

@Test func aPinnedProjectContributesOneSummaryItemThatCannotBeDeleted() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/sample-project/build")
    let dartTool = temp.makeDirectory("dev/sample-project/.dart_tool")
    temp.makeFile("dev/sample-project/pubspec.yaml")

    let project = DiscoveredProject(path: temp.path + "/dev/sample-project", name: "sample-project")
    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .pinnedProject]),
        sizes: [build: 2_000_000_000, dartTool: 50_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "sample-project")
    #expect(item.protection == .pinnedProject)
    #expect(item.sizeBytes == 2_050_000_000)
    #expect(!item.isDeletable)
}

/// The rule this scanner was built on, softened for exactly one reason and no others.
///
/// A read-only scan of a real dev machine found **every** project with build output in it
/// marked "kept: changed in the last 14 days" — Sample Game 3.3 GB, Photo Tool
/// 2.8 GB, this repository 588 MB. Withholding all of that was right for the one-click bulk
/// clean the rule was written for, where the user never sees which folders go. It is wrong
/// for the deck, which puts one project on screen and waits for that project's own answer:
/// there, recent activity is something to **tell the user**, not a reason to hide the
/// 3.3 GB they came looking for.
///
/// So the folders are offered and start unticked, carrying the reason on the row. The
/// three things that make that safe rather than a weakening: nothing ticks them
/// (`selectedByDefault` is false, so `ScanResult.defaultSelection` and therefore
/// `cleanDefault` never include them), the row says why in words the user reads, and a
/// **pin** is untouched — that is still a hard `protection` and still a summary row.
@Test func anActiveProjectsFoldersAreOfferedUntickedWithTheReasonOnEachRow() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/Sample Game/.build")
    let pods = temp.makeDirectory("dev/Sample Game/ios/Pods")
    temp.makeFile("dev/Sample Game/pubspec.yaml")
    let project = flutterProject(temp, "Sample Game")
    let changed = now.addingTimeInterval(-86_400 * 3)

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .recentActivity(days: 14)]),
        sizes: [build: 3_300_000_000, pods: 400_000_000],
        activity: [project.path: changed]))

    // Two ordinary per-folder rows, and no summary row at all: the project is in the deck
    // now, so there is nothing left for a "where did my 3.3 GB go?" line to answer.
    #expect(items.map(\.name) == [".build", "ios/Pods"])
    #expect(items.allSatisfy { $0.protection == nil })
    #expect(items.allSatisfy { $0.isDeletable })
    // Offered, and every one of them left for the user to ask for.
    #expect(items.allSatisfy { $0.startsUnticked })
    #expect(items.allSatisfy { !$0.selectedByDefault })
    #expect(items.allSatisfy { $0.untickedReason == .recentActivity(days: 14) })
    // Real sizes, the usual risk split, and the project's own date — everything a card
    // needs to be worth reading.
    let output = try #require(items.first { $0.name == ".build" })
    #expect(output.sizeBytes == 3_300_000_000)
    #expect(output.risk == .safe)
    #expect(output.method == .removePath(build))
    #expect(output.lastUsed == changed)
    #expect(try #require(items.first { $0.name == "ios/Pods" }).risk == .elevated)
    // The row explains itself wherever it is listed, which for the deck and the CLI is
    // the only place the reason can appear.
    #expect(items.allSatisfy { $0.detail == "Sample Game · changed in the last 14 days" })
}

/// An unmeasured folder in an active project carries the reason too, and stays at nothing.
///
/// It is unticked twice over — once because `du` could not size it, once because the
/// project is active — and the two are told apart by the reason rather than by the flag:
/// `startsUnticked` with no `untickedReason` is exactly "unmeasured". The deck asks for a
/// size above zero and so leaves this row out, while `devcleaner scan` still lists it with its
/// size unknown.
@Test func anUnmeasuredFolderInAnActiveProjectCarriesTheReasonAndStaysAtNothing() async throws {
    let temp = TempDir()
    let measured = temp.makeDirectory("dev/app/build")
    temp.makeDirectory("dev/app/.dart_tool")
    temp.makeFile("dev/app/pubspec.yaml")
    let project = flutterProject(temp, "app")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .recentActivity(days: 14)]),
        sizeMeasurer: PartialSizeMeasurer([measured: 2_000_000_000])))

    let unmeasured = try #require(items.first { $0.name == ".dart_tool" })
    #expect(unmeasured.sizeBytes == 0)
    #expect(unmeasured.startsUnticked)
    #expect(unmeasured.untickedReason == .recentActivity(days: 14))
    #expect(try #require(items.first { $0.name == "build" }).sizeBytes == 2_000_000_000)
}

/// A reason never travels without the unticked flag it explains.
///
/// The pair is the contract every reader depends on: `cleanDefault` and the amount the menu
/// bar shows both derive from `selectedByDefault`, and a row carrying a reason to be left
/// alone while ticking itself by default would put a project the user is working in into a
/// blind clean with a sentence beside it saying it should not be.
@Test func anUntickedReasonAlwaysComesWithAnUntickedRow() async {
    let temp = TempDir()
    temp.makeDirectory("dev/active/build")
    temp.makeDirectory("dev/pinned/build")
    temp.makeDirectory("dev/stale/build")
    for name in ["active", "pinned", "stale"] { temp.makeFile("dev/\(name)/pubspec.yaml") }
    let active = flutterProject(temp, "active")
    let pinned = flutterProject(temp, "pinned")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp,
        projects: [active, pinned, flutterProject(temp, "stale")],
        protection: protection(projects: [
            active.path: .recentActivity(days: 14),
            pinned.path: .pinnedProject,
        ])))

    #expect(items.allSatisfy { $0.untickedReason == nil || $0.startsUnticked })
    // Rule 4: a fixture where every row carried a reason could not test the implication.
    #expect(items.contains { $0.untickedReason == nil })
    #expect(items.contains { $0.untickedReason != nil })
}

@Test func aProtectedProjectWithNothingToCleanProducesNoRowAtAll() async {
    let temp = TempDir()
    temp.makeFile("dev/sample-project/pubspec.yaml")
    let project = flutterProject(temp, "sample-project")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .pinnedProject])))

    #expect(items.isEmpty)
}

/// Decision B: the text explaining why a row is being held back is derived from the
/// reason, never from one sentence for everything. Both reasons that reach
/// `ProtectionSet.projects` today are here, and a single sentence is false for one of
/// them whichever sentence is chosen.
///
/// The two now arrive by different routes — a pin as a protected summary row, activity as
/// the detail of each offered folder — and `ProjectBuildOutputScanner.detail(for:)` is the
/// one function both of them go through, which is what keeps the wording from forking.
@Test func theReasonARowIsHeldBackComesFromTheReasonAndNotAFixedSentence() async throws {
    let temp = TempDir()
    temp.makeDirectory("dev/pinned/build")
    temp.makeDirectory("dev/active/build")
    temp.makeFile("dev/pinned/pubspec.yaml")
    temp.makeFile("dev/active/pubspec.yaml")
    let pinned = flutterProject(temp, "pinned")
    let active = flutterProject(temp, "active")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [pinned, active],
        protection: protection(projects: [
            pinned.path: .pinnedProject,
            active.path: .recentActivity(days: 21),
        ])))

    #expect(try #require(items.first { $0.name == "pinned" }).detail == "pinned in settings")
    // The days come from the settings this scan was handed, so 21 rather than the default.
    #expect(try #require(items.first { $0.detail?.hasPrefix("active") == true }).detail
            == "active · changed in the last 21 days")
}

/// Rule 5 and decision C, with four representative directories side by side under one
/// `~/dev`. A bare `hasPrefix` treats all four as one project: the three
/// unprotected ones would silently stop being offered, and their six gigabytes would be
/// reported under a name that is not theirs.
@Test func aProtectedProjectDoesNotCoverASiblingWhosePathMerelyStartsTheSame() async throws {
    let temp = TempDir()
    let baseProject = temp.makeDirectory("dev/sample-flutter/build")
    let second = temp.makeDirectory("dev/sample-flutter-002/build")
    let inplace = temp.makeDirectory("dev/sample-flutter-inplace/build")
    let flow = temp.makeDirectory("dev/sample-flutterflow/build")
    for name in ["sample-flutter", "sample-flutter-002",
                 "sample-flutter-inplace", "sample-flutterflow"] {
        temp.makeFile("dev/\(name)/pubspec.yaml")
    }
    let projects = ["sample-flutter", "sample-flutter-002",
                    "sample-flutter-inplace", "sample-flutterflow"]
        .map { flutterProject(temp, $0) }

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: projects,
        protection: protection(projects: [temp.path + "/dev/sample-flutter": .pinnedProject]),
        sizes: [baseProject: 2_000_000_000, second: 2_000_000_000,
                inplace: 2_000_000_000, flow: 2_000_000_000]))

    #expect(items.count == 4)
    let summary = try #require(items.first { !$0.isDeletable })
    #expect(summary.name == "sample-flutter")
    #expect(summary.sizeBytes == 2_000_000_000)

    #expect(items.filter(\.isDeletable).compactMap(\.detail).sorted()
            == ["sample-flutter-002", "sample-flutter-inplace", "sample-flutterflow"])
    #expect(try #require(items.first { $0.detail == "sample-flutter-002" }).method
            == .removePath(second))
    #expect(try #require(items.first { $0.detail == "sample-flutter-inplace" }).method
            == .removePath(inplace))
    #expect(try #require(items.first { $0.detail == "sample-flutterflow" }).method
            == .removePath(flow))
}

/// A second representative pair, `demo-repo` and `demo-repo copy`, where the
/// character that separates them is a space rather than a hyphen.
@Test func aProtectedProjectDoesNotCoverASiblingSeparatedByASpace() async throws {
    let temp = TempDir()
    temp.makeDirectory("dev/demo-repo/build")
    let copyBuild = temp.makeDirectory("dev/demo-repo copy/build")
    temp.makeFile("dev/demo-repo/pubspec.yaml")
    temp.makeFile("dev/demo-repo copy/pubspec.yaml")
    let original = flutterProject(temp, "demo-repo")
    let copy = flutterProject(temp, "demo-repo copy")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [original, copy],
        protection: protection(projects: [original.path: .pinnedProject]),
        sizes: [copyBuild: 1_500_000_000]))

    let offered = try #require(items.first { $0.isDeletable })
    #expect(offered.detail == "demo-repo copy")
    #expect(offered.method == .removePath(copyBuild))
    #expect(offered.sizeBytes == 1_500_000_000)
}

/// The user's rule is about the directory they are working in, not about which row the
/// folder is labelled with. A project can sit inside another project when
/// `Settings.projectRoots` names both — a melos workspace member, or the `example` app
/// of a Flutter plugin — and its build folder is still inside the protected project.
@Test func buildFoldersInsideAProtectedProjectAreNotOfferedEvenUnderAnotherProjectsName() async throws {
    let temp = TempDir()
    let outerBuild = temp.makeDirectory("dev/my_plugin/build")
    let innerBuild = temp.makeDirectory("dev/my_plugin/example/build")
    temp.makeFile("dev/my_plugin/pubspec.yaml")
    temp.makeFile("dev/my_plugin/example/pubspec.yaml")

    let outer = DiscoveredProject(
        path: temp.path + "/dev/my_plugin", name: "my_plugin")
    let inner = DiscoveredProject(
        path: temp.path + "/dev/my_plugin/example", name: "example")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [outer, inner],
        protection: protection(projects: [outer.path: .pinnedProject]),
        sizes: [outerBuild: 2_000_000_000, innerBuild: 500_000_000]))

    #expect(items.count == 1)
    let summary = try #require(items.first)
    #expect(summary.name == "my_plugin")
    #expect(!summary.isDeletable)
    // Both folders, so the row shows the whole space the protected project is holding.
    #expect(summary.sizeBytes == 2_500_000_000)
}

/// The mirror image of the test above: protecting the inner project must not withdraw
/// the outer project's own build folder, which is not inside it.
@Test func protectingAnInnerProjectDoesNotWithdrawTheOuterProjectsBuildFolder() async throws {
    let temp = TempDir()
    let outerBuild = temp.makeDirectory("dev/my_plugin/build")
    temp.makeDirectory("dev/my_plugin/example/build")
    temp.makeFile("dev/my_plugin/pubspec.yaml")
    temp.makeFile("dev/my_plugin/example/pubspec.yaml")

    let outer = DiscoveredProject(
        path: temp.path + "/dev/my_plugin", name: "my_plugin")
    let inner = DiscoveredProject(
        path: temp.path + "/dev/my_plugin/example", name: "example")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [outer, inner],
        protection: protection(projects: [inner.path: .pinnedProject]),
        sizes: [outerBuild: 2_000_000_000]))

    #expect(items.count == 2)
    let offered = try #require(items.first { $0.isDeletable })
    #expect(offered.detail == "my_plugin")
    #expect(offered.method == .removePath(outerBuild))
    #expect(try #require(items.first { !$0.isDeletable }).name == "example")
}

/// When both the outer and the inner project are protected, each folder belongs to the
/// nearest protected project that covers it. Attributing the inner one to the outer row
/// would report space under a project that is not holding it, and the user reads these
/// totals to decide which project to go and clean by hand.
@Test func aFolderIsAttributedToTheNearestProtectedProjectThatCoversIt() async throws {
    let temp = TempDir()
    let outerBuild = temp.makeDirectory("dev/my_plugin/build")
    let innerBuild = temp.makeDirectory("dev/my_plugin/example/build")
    temp.makeFile("dev/my_plugin/pubspec.yaml")
    temp.makeFile("dev/my_plugin/example/pubspec.yaml")

    let outer = DiscoveredProject(
        path: temp.path + "/dev/my_plugin", name: "my_plugin")
    let inner = DiscoveredProject(
        path: temp.path + "/dev/my_plugin/example", name: "example")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [outer, inner],
        protection: protection(projects: [
            outer.path: .pinnedProject,
            inner.path: .pinnedProject,
        ]),
        sizes: [outerBuild: 2_000_000_000, innerBuild: 500_000_000]))

    #expect(items.count == 2)
    #expect(try #require(items.first { $0.name == "my_plugin" }).sizeBytes == 2_000_000_000)
    #expect(try #require(items.first { $0.name == "example" }).sizeBytes == 500_000_000)
}

/// The nearest owner decides **which of the two treatments** a folder gets, not merely
/// which row it is counted under.
///
/// A pinned plugin holding an active `example` app: the inner folder is offered unticked,
/// because the nearest thing covering it is only active, and the outer folder is withheld
/// into the pin's summary row. Read the other way round — outer first, because it is the
/// shorter path — the inner folder would be swallowed by a pin the user never applied to
/// it, and 500 MB would be invisible in a window built to show exactly that.
@Test func theNearestOwnerDecidesWhetherAFolderIsWithheldOrOfferedUnticked() async throws {
    let temp = TempDir()
    let outerBuild = temp.makeDirectory("dev/my_plugin/build")
    let innerBuild = temp.makeDirectory("dev/my_plugin/example/build")
    temp.makeFile("dev/my_plugin/pubspec.yaml")
    temp.makeFile("dev/my_plugin/example/pubspec.yaml")

    let outer = DiscoveredProject(path: temp.path + "/dev/my_plugin", name: "my_plugin")
    let inner = DiscoveredProject(
        path: temp.path + "/dev/my_plugin/example", name: "example")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [outer, inner],
        protection: protection(projects: [
            outer.path: .pinnedProject,
            inner.path: .recentActivity(days: 14),
        ]),
        sizes: [outerBuild: 2_000_000_000, innerBuild: 500_000_000]))

    #expect(items.count == 2)
    let offered = try #require(items.first { $0.isDeletable })
    #expect(offered.method == .removePath(innerBuild))
    #expect(offered.sizeBytes == 500_000_000)
    #expect(offered.untickedReason == .recentActivity(days: 14))

    let summary = try #require(items.first { !$0.isDeletable })
    #expect(summary.name == "my_plugin")
    // The pin's summary counts its own folder and **not** the active project's, which is
    // now accounted for by a row of its own.
    #expect(summary.sizeBytes == 2_000_000_000)
}

/// Rule 6, through the real `ProtectionResolver` and with a non-default
/// `activeThresholdDays`, because this scanner decides a project's build folders purely on
/// the answer that boundary gives. One project sits exactly on the cutoff and one a second
/// beyond it.
///
/// What the boundary decides is now whether the folders are **ticked**, not whether they
/// are offered: both projects get real per-folder rows, and only the one outside the window
/// starts ticked. The number in the reason still has to come from the settings this scan
/// was handed and from nowhere else, which is why the threshold here is 30 rather than the
/// default 14.
@Test func theActivityCutoffDecidesWhetherABuildFolderIsTicked() async throws {
    let temp = TempDir()
    let onCutoffBuild = temp.makeDirectory("dev/on-cutoff/build")
    let pastCutoffBuild = temp.makeDirectory("dev/past-cutoff/build")
    temp.makeFile("dev/on-cutoff/pubspec.yaml")
    temp.makeFile("dev/past-cutoff/pubspec.yaml")
    let onCutoff = flutterProject(temp, "on-cutoff")
    let pastCutoff = flutterProject(temp, "past-cutoff")

    // 30 rather than the default 14, so the number in the reason cannot come from
    // anywhere but the settings this scan was handed.
    var settings = Settings.makeDefault(home: temp.path)
    settings.activeThresholdDays = 30
    let cutoff = now.addingTimeInterval(-30 * 86_400)

    let resolved = ProtectionResolver(settings: settings).resolve(
        projects: [onCutoff, pastCutoff],
        activity: [onCutoff.path: cutoff,
                   pastCutoff.path: cutoff.addingTimeInterval(-1)],
        devices: .empty, now: now)

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [onCutoff, pastCutoff], protection: resolved,
        sizes: [onCutoffBuild: 3_000_000_000, pastCutoffBuild: 1_000_000_000],
        settings: settings))

    #expect(items.count == 2)
    let inside = try #require(items.first { $0.detail?.hasPrefix("on-cutoff") == true })
    #expect(inside.protection == nil)
    #expect(inside.untickedReason == .recentActivity(days: 30))
    #expect(!inside.selectedByDefault)
    #expect(inside.detail == "on-cutoff · changed in the last 30 days")
    #expect(inside.method == .removePath(onCutoffBuild))
    #expect(inside.sizeBytes == 3_000_000_000)

    // A closure rather than the `\.selectedByDefault` key path: the `#require` macro
    // expands a key-path argument into a call the compiler treats as throwing.
    let outside = try #require(items.first { $0.selectedByDefault })
    #expect(outside.name == "build")
    #expect(outside.detail == "past-cutoff")
    #expect(outside.untickedReason == nil)
    #expect(outside.method == .removePath(pastCutoffBuild))
}

// MARK: deletion targets

/// Rule 2. Name, detail and size all come from somewhere other than the path, so a
/// `path:` argument mutated from the folder to the project root passes every other
/// assertion in this file while offering to trash the user's source code.
@Test func everyOfferedFolderPinsItsOwnDeletionPath() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/app/build")
    let pods = temp.makeDirectory("dev/app/ios/Pods")
    let gradle = temp.makeDirectory("dev/app/android/.gradle")
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")]))

    let buildItem = try #require(items.first { $0.name == "build" })
    #expect(buildItem.method == .removePath(build))
    #expect(buildItem.id == "projects.buildOutput|\(build)")
    #expect(buildItem.group == .projects)

    #expect(try #require(items.first { $0.name == "ios/Pods" }).method == .removePath(pods))
    #expect(try #require(items.first { $0.name == "android/.gradle" }).id
            == "projects.buildOutput|\(gradle)")
}

/// The summary row for a protected project carries the project's own directory, so the
/// row has a stable identity and names the thing it is reporting on. That is the one
/// path in this whole app that is a directory of the user's source code, and it is kept
/// harmless by three independent things, not one: the row is never deletable, the
/// executor acts only on selected rows, and `PathGuard` refuses the path outright.
///
/// The third of those belongs to Task 17, which does not exist yet. This pins the
/// contract now, so that an executor built without the forbidden target fails here.
@Test func theProtectedSummaryRowNamesTheProjectAndIsRefusedByPathGuard() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/sample-project/build")
    temp.makeFile("dev/sample-project/pubspec.yaml")
    let project = flutterProject(temp, "sample-project")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .pinnedProject]),
        sizes: [build: 2_000_000_000]))

    let summary = try #require(items.first)
    #expect(summary.id == "projects.buildOutput|\(project.path)")
    #expect(summary.method == .removePath(project.path))
    #expect(!summary.isDeletable)

    let pathGuard = PathGuard(allowedRoots: [temp.path], forbiddenTargets: [project.path])
    #expect(throws: PathGuard.Violation.forbiddenTarget(project.path)) {
        _ = try pathGuard.validate(project.path)
    }
    // And the build folder underneath it still passes, so the guard above is refusing
    // this one path rather than everything.
    #expect(throws: Never.self) { _ = try pathGuard.validate(build) }
}

/// A pinned project's space must not be counted as space the user is about to get back.
@Test func aPinnedProjectsSpaceIsNotCountedAsReclaimable() async {
    let temp = TempDir()
    let keptBuild = temp.makeDirectory("dev/sample-project/build")
    let staleBuild = temp.makeDirectory("dev/stale/build")
    temp.makeFile("dev/sample-project/pubspec.yaml")
    temp.makeFile("dev/stale/pubspec.yaml")
    let kept = flutterProject(temp, "sample-project")
    let stale = flutterProject(temp, "stale")

    let result = await ScanEngine(scanners: [ProjectBuildOutputScanner()]).scan(context: context(
        temp: temp, projects: [kept, stale],
        protection: protection(projects: [kept.path: .pinnedProject]),
        sizes: [keptBuild: 9_000_000_000, staleBuild: 1_000_000_000]))

    #expect(result.items.count == 2)
    #expect(result.reclaimableBytes == 1_000_000_000)
    #expect(result.reclaimableBytes(in: .projects) == 1_000_000_000)
    // Not deletable at all, so not on the "you could also tick this" side either.
    #expect(result.untickedDeletableBytes == 0)
}

/// An active project's space is not reclaimable either, and it lands in a different total
/// from a pin's — which is the whole point of the two being different things.
///
/// The three numbers every surface is built from, on one fixture. `reclaimableBytes` is
/// what the headline promises and what `cleanDefault` removes, so 9 GB of a project the
/// user is working in must stay out of it. `untickedDeletableBytes` is "and this much more
/// is offered if you ask", which is exactly what the row now is. And the two must not both
/// count it, or the app would offer 10 GB where the disk has 1.
@Test func anActiveProjectsSpaceIsOfferedButNotTickedRatherThanReclaimable() async {
    let temp = TempDir()
    let activeBuild = temp.makeDirectory("dev/active/build")
    let staleBuild = temp.makeDirectory("dev/stale/build")
    temp.makeFile("dev/active/pubspec.yaml")
    temp.makeFile("dev/stale/pubspec.yaml")
    let active = flutterProject(temp, "active")

    let result = await ScanEngine(scanners: [ProjectBuildOutputScanner()]).scan(context: context(
        temp: temp, projects: [active, flutterProject(temp, "stale")],
        protection: protection(projects: [active.path: .recentActivity(days: 14)]),
        sizes: [activeBuild: 9_000_000_000, staleBuild: 1_000_000_000]))

    #expect(result.items.count == 2)
    #expect(result.reclaimableBytes == 1_000_000_000)
    #expect(result.reclaimableBytes(in: .projects) == 1_000_000_000)
    #expect(result.untickedDeletableBytes == 9_000_000_000)
    #expect(result.defaultSelection.map(\.detail) == ["stale"])
}

// MARK: measurement

/// Rule 9. `sizes(of:)` batches its input and holds four `du` processes open at most,
/// and this is the scanner with the most paths to measure — 257 projects on this
/// machine. A call per folder would spawn a `du` per folder and thrash the disk, and
/// nothing in the returned items would show it.
///
/// The protected project's folders have to be in the same batch, because its summary
/// row reports their total.
@Test func everyFolderIncludingProtectedOnesIsMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    let staleBuild = temp.makeDirectory("dev/stale/build")
    let staleDartTool = temp.makeDirectory("dev/stale/.dart_tool")
    let keptBuild = temp.makeDirectory("dev/sample-project/build")
    temp.makeFile("dev/stale/pubspec.yaml")
    temp.makeFile("dev/sample-project/pubspec.yaml")
    let stale = flutterProject(temp, "stale")
    let kept = flutterProject(temp, "sample-project")

    let measurer = CallCountingSizeMeasurer([
        staleBuild: 2_000_000_000, staleDartTool: 50_000_000, keptBuild: 3_000_000_000,
    ])

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [stale, kept],
        protection: protection(projects: [kept.path: .pinnedProject]),
        sizeMeasurer: measurer))

    #expect(items.count == 3)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.sorted() == [keptBuild, staleBuild, staleDartTool].sorted())
    #expect(try #require(items.first { $0.name == "sample-project" }).sizeBytes == 3_000_000_000)
}

// MARK: when the project last changed

/// The deck's card says "last changed 4 months ago", and this row is the only place that
/// date can come from: `CleanerService` already asks `ActivityInspector` for it — it is
/// what `ProtectionResolver` decides protection on — and then threw it away. Re-deriving
/// it in the interface would be a second walk of the project and a second answer to a
/// question the scan has already answered.
///
/// One date per project, on every one of its rows: the date is a fact about the project,
/// so a card built from any of its folders reads the same.
@Test func theProjectsLastActivityReachesEveryFolderRow() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/app/build")
    let pods = temp.makeDirectory("dev/app/ios/Pods")
    temp.makeFile("dev/app/pubspec.yaml")
    let changed = now.addingTimeInterval(-86_400 * 120)

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")],
        sizes: [build: 2_000_000_000, pods: 400_000_000],
        activity: [temp.path + "/dev/app": changed]))

    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.lastUsed == changed })
}

/// A project the inspector could not date keeps `nil` rather than borrowing a date from
/// somewhere. The card then shows no "last changed" line at all, which is the only
/// reading that is not a guess — and a project whose activity **is** known must not lend
/// its date to the one beside it.
@Test func aProjectWithNoKnownActivityLeavesTheRowsDateEmpty() async throws {
    let temp = TempDir()
    temp.makeDirectory("dev/dated/build")
    temp.makeDirectory("dev/undated/build")
    temp.makeFile("dev/dated/pubspec.yaml")
    temp.makeFile("dev/undated/pubspec.yaml")
    let changed = now.addingTimeInterval(-86_400 * 3)

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "dated"), flutterProject(temp, "undated")],
        activity: [temp.path + "/dev/dated": changed]))

    #expect(try #require(items.first { $0.detail == "dated" }).lastUsed == changed)
    #expect(try #require(items.first { $0.detail == "undated" }).lastUsed == nil)
}

/// A pinned project's summary row carries no date.
///
/// It is one row standing for a whole project's holdings rather than a folder, it is
/// never in the deck, and the reason beside it — "pinned in settings" — already says
/// everything the row is for. A date there would invite the question the pin has already
/// answered.
@Test func thePinnedSummaryRowCarriesNoLastChangedDate() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/pinned/build")
    temp.makeFile("dev/pinned/pubspec.yaml")
    let project = flutterProject(temp, "pinned")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .pinnedProject]),
        sizes: [build: 2_000_000_000],
        activity: [project.path: now.addingTimeInterval(-86_400)]))

    #expect(items.count == 1)
    #expect(try #require(items.first).lastUsed == nil)
}

/// An active project's folders keep the date, which is the line the card needs most.
///
/// "You changed this in the last 14 days" is the caution; "last changed 3 days ago" is the
/// fact behind it, and a user deciding whether they are finished with a project reads the
/// second one. Withholding it here — as the pinned summary row does — would leave the card
/// making a claim with nothing under it.
@Test func anActiveProjectsOfferedRowsKeepTheirLastChangedDate() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/active/build")
    temp.makeFile("dev/active/pubspec.yaml")
    let project = flutterProject(temp, "active")
    let changed = now.addingTimeInterval(-86_400 * 3)

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .recentActivity(days: 14)]),
        sizes: [build: 2_000_000_000],
        activity: [project.path: changed]))

    #expect(items.count == 1)
    #expect(try #require(items.first).lastUsed == changed)
}

/// An active project's folder is deletable, so the run guard has to let it through — and
/// the project's own directory still has to be refused. The card's Clean up button is
/// worth nothing if the guard turns the run down after the user has pressed it.
@Test func anActiveProjectsFolderPassesTheRealRunGuardAndItsDirectoryStillDoesNot() throws {
    let temp = TempDir()
    let root = temp.makeDirectory("dev")
    let project = temp.makeDirectory("dev/active")
    let build = temp.makeDirectory("dev/active/.build")

    let sut = PathGuard.forRun(home: temp.path, projectRoots: [root], projectPaths: [project])

    #expect(throws: Never.self) { _ = try sut.validate(build) }
    #expect(throws: PathGuard.Violation.forbiddenTarget(project)) {
        _ = try sut.validate(project)
    }
}

// MARK: identity

/// Rule 3. The identifier is persisted in `Settings.alwaysSkipScannerIDs`, so renaming
/// it silently un-skips this scanner for a user who had turned it off — and this is the
/// one scanner that reaches inside their source directories.
@Test func projectScannerIdentityAndGroupAreStable() {
    #expect(ProjectBuildOutputScanner().id == "projects.buildOutput")
    #expect(ProjectBuildOutputScanner().group == .projects)
    #expect(ProjectBuildOutputScanner().title == "Project build folders")
}

/// The other half of rule 3, with a non-default `Settings`: the string a user's
/// settings file already holds has to be the string this scanner publishes today.
@Test func skippingTheProjectScannerUsesTheStringItPublishes() async {
    let temp = TempDir()
    temp.makeDirectory("dev/app/build")
    temp.makeFile("dev/app/pubspec.yaml")

    var settings = Settings.makeDefault(home: temp.path)
    settings.alwaysSkipScannerIDs = ["projects.buildOutput"]

    let result = await ScanEngine(scanners: [ProjectBuildOutputScanner()]).scan(context: context(
        temp: temp, projects: [flutterProject(temp, "app")], settings: settings))

    #expect(result.items.isEmpty)
    #expect(result.skippedScannerIDs == ["projects.buildOutput"])
}
