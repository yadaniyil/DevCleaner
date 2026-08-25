import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(temp: TempDir, projects: [DiscoveredProject],
                     protection: ProtectionSet = .empty,
                     sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil,
                     settings: Settings? = nil) -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: temp.path),
        protection: protection, projects: projects,
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
    temp.makeDirectory("dev/app/build")
    temp.makeDirectory("dev/app/.dart_tool")
    temp.makeDirectory("dev/app/.symlinks")
    temp.makeDirectory("dev/app/android/.gradle")
    temp.makeDirectory("dev/app/android/build")
    temp.makeDirectory("dev/app/ios/Pods")
    temp.makeDirectory("dev/app/macos/Pods")
    temp.makeDirectory("dev/app/node_modules")
    temp.makeFile("dev/app/pubspec.yaml")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [flutterProject(temp, "app")]))

    #expect(items.map(\.name).sorted() == [
        ".dart_tool", ".symlinks", "android/.gradle", "android/build",
        "build", "ios/Pods", "macos/Pods", "node_modules",
    ])
    let elevated = items.filter { $0.risk == .elevated }.map(\.name).sorted()
    #expect(elevated == ["ios/Pods", "macos/Pods", "node_modules"])
    let safe = items.filter { $0.risk == .safe }.map(\.name).sorted()
    #expect(safe == [".dart_tool", ".symlinks", "android/.gradle", "android/build", "build"])
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
/// folder inside a protected project is a folder inside a protected project, exactly like
/// `build` or `ios/Pods`, so it is never offered — and its bytes belong in that project's
/// summary row, which is the row that answers "where did my 40 GB go?".
@Test func aWorktreeBuildFolderInsideAProtectedProjectIsNotOfferedAndJoinsItsSummary() async throws {
    let temp = TempDir()
    let own = temp.makeDirectory("dev/sample-ios-app/build")
    let worktree = temp.makeDirectory("dev/sample-ios-app/.claude/worktrees/feature-sync/build")
    temp.makeFile("dev/sample-ios-app/pubspec.yaml")
    let project = flutterProject(temp, "sample-ios-app")

    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .recentActivity(days: 14)]),
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

@Test func protectedProjectContributesOneSummaryItemThatCannotBeDeleted() async throws {
    let temp = TempDir()
    let build = temp.makeDirectory("dev/sample-project/build")
    let dartTool = temp.makeDirectory("dev/sample-project/.dart_tool")
    temp.makeFile("dev/sample-project/pubspec.yaml")

    let project = DiscoveredProject(path: temp.path + "/dev/sample-project", name: "sample-project")
    let items = await ProjectBuildOutputScanner().scan(context(
        temp: temp, projects: [project],
        protection: protection(projects: [project.path: .recentActivity(days: 14)]),
        sizes: [build: 2_000_000_000, dartTool: 50_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "sample-project")
    #expect(item.protection == .recentActivity(days: 14))
    #expect(item.sizeBytes == 2_050_000_000)
    #expect(!item.isDeletable)
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

/// Decision B: the text under a protected row is derived from the reason, never from
/// one sentence for everything protected. Both reasons that reach
/// `ProtectionSet.projects` today are here, and a single sentence is false for one of
/// them whichever sentence is chosen.
@Test func theProtectedRowDetailComesFromTheReasonAndNotAFixedSentence() async throws {
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
    #expect(try #require(items.first { $0.name == "active" }).detail
            == "changed in the last 21 days")
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
        protection: protection(projects: [original.path: .recentActivity(days: 14)]),
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
        protection: protection(projects: [outer.path: .recentActivity(days: 14)]),
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
            outer.path: .recentActivity(days: 14),
            inner.path: .pinnedProject,
        ]),
        sizes: [outerBuild: 2_000_000_000, innerBuild: 500_000_000]))

    #expect(items.count == 2)
    #expect(try #require(items.first { $0.name == "my_plugin" }).sizeBytes == 2_000_000_000)
    #expect(try #require(items.first { $0.name == "example" }).sizeBytes == 500_000_000)
}

/// Rule 6, through the real `ProtectionResolver` and with a non-default
/// `activeThresholdDays`, because this scanner offers or withholds a project's build
/// folders purely on the answer that boundary gives. One project sits exactly on the
/// cutoff and one a second beyond it.
@Test func theActivityCutoffDecidesWhetherABuildFolderIsOffered() async throws {
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
    let kept = try #require(items.first { $0.name == "on-cutoff" })
    #expect(kept.protection == .recentActivity(days: 30))
    #expect(kept.detail == "changed in the last 30 days")
    #expect(kept.sizeBytes == 3_000_000_000)

    let offered = try #require(items.first { $0.isDeletable })
    #expect(offered.name == "build")
    #expect(offered.detail == "past-cutoff")
    #expect(offered.method == .removePath(pastCutoffBuild))
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

/// A protected row must not be counted as space the user is about to get back.
@Test func aProtectedProjectsSpaceIsNotCountedAsReclaimable() async {
    let temp = TempDir()
    let keptBuild = temp.makeDirectory("dev/sample-project/build")
    let staleBuild = temp.makeDirectory("dev/stale/build")
    temp.makeFile("dev/sample-project/pubspec.yaml")
    temp.makeFile("dev/stale/pubspec.yaml")
    let kept = flutterProject(temp, "sample-project")
    let stale = flutterProject(temp, "stale")

    let result = await ScanEngine(scanners: [ProjectBuildOutputScanner()]).scan(context: context(
        temp: temp, projects: [kept, stale],
        protection: protection(projects: [kept.path: .recentActivity(days: 14)]),
        sizes: [keptBuild: 9_000_000_000, staleBuild: 1_000_000_000]))

    #expect(result.items.count == 2)
    #expect(result.reclaimableBytes == 1_000_000_000)
    #expect(result.reclaimableBytes(in: .projects) == 1_000_000_000)
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
