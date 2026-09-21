import Testing
import Foundation
@testable import CleanerCore

private let referenceNow = Date(timeIntervalSince1970: 1_786_000_000)  // 2026-08-06

@Test func usesNewestSourceFileModificationDate() throws {
    let temp = TempDir()
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow.addingTimeInterval(-86_400 * 40))
    temp.makeFile("proj/lib/main.dart", modified: referenceNow.addingTimeInterval(-86_400 * 3))
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let inspector = ActivityInspector(runner: FakeProcessRunner(responses: [:]))
    let activity = inspector.lastActivity(of: project)
    #expect(activity != nil)
    let newest = try #require(activity)
    #expect(abs(newest.timeIntervalSince(referenceNow.addingTimeInterval(-86_400 * 3))) < 2)
}

@Test func ignoresBuildAndCacheDirectories() throws {
    let temp = TempDir()
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow.addingTimeInterval(-86_400 * 90))
    temp.makeFile("proj/build/app.apk", modified: referenceNow)
    temp.makeFile("proj/.build/debug/proj", modified: referenceNow)
    temp.makeFile("proj/Build/Products/proj.app", modified: referenceNow)
    temp.makeFile("proj/.dart_tool/package_config.json", modified: referenceNow)
    temp.makeFile("proj/node_modules/x/index.js", modified: referenceNow)
    temp.makeFile("proj/ios/Pods/Manifest.lock", modified: referenceNow)
    temp.makeFile("proj/.git/index", modified: referenceNow)
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let activity = try #require(
        ActivityInspector(runner: FakeProcessRunner(responses: [:]))
            .lastActivity(of: project))
    #expect(activity < referenceNow.addingTimeInterval(-86_400 * 60))
}

/// `~/dev/workspace-one/sample-game` builds into eleven `.build…` folders. Read as activity,
/// every build would protect the project from the clean those folders are offered for.
@Test func ignoresBuildVariantFoldersThatHoldBuildOutput() throws {
    let temp = TempDir()
    temp.makeFile("proj/Package.swift", modified: referenceNow.addingTimeInterval(-86_400 * 90))
    temp.makeFile("proj/.build-release/info.plist", modified: referenceNow)
    temp.makeFile("proj/.build-release/Build/Products/proj.app", modified: referenceNow)
    temp.makeFile("proj/.next/cache/x", modified: referenceNow)
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let activity = try #require(
        ActivityInspector(runner: FakeProcessRunner(responses: [:]))
            .lastActivity(of: project))
    #expect(activity < referenceNow.addingTimeInterval(-86_400 * 60))
}

/// The prefix alone is not build output. The scanner refuses to offer `.build-notes`, so
/// editing it has to count — one rule for deleting and for protecting.
@Test func aHandWrittenFolderWithTheBuildPrefixStillCountsAsActivity() throws {
    let temp = TempDir()
    temp.makeFile("proj/Package.swift", modified: referenceNow.addingTimeInterval(-86_400 * 90))
    temp.makeFile("proj/.build-notes/todo.md", modified: referenceNow.addingTimeInterval(-86_400))
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let activity = try #require(
        ActivityInspector(runner: FakeProcessRunner(responses: [:]))
            .lastActivity(of: project))
    #expect(abs(activity.timeIntervalSince(referenceNow.addingTimeInterval(-86_400))) < 2)
}

/// The other half of `aVariantFolderMarkedOnlyByAnEverydayWordIsNotOffered`, and the reason
/// that fix matters twice.
///
/// `debug` and `release` were build-output markers, so a hand-written `.build-scripts/`
/// with a `release` script in it — or a `.build-config/` with a `release/` folder of
/// plists — read as build output here. Editing it then stopped counting as working on the
/// project, so the project quietly lost its protection at the same moment its hand-written
/// folder became deletable. These are the user's files; touching them is activity.
@Test func editingAHandWrittenBuildFolderNamedWithEverydayWordsCountsAsActivity() throws {
    let temp = TempDir()
    let yesterday = referenceNow.addingTimeInterval(-86_400)
    temp.makeFile("proj/Package.swift", modified: referenceNow.addingTimeInterval(-86_400 * 90))
    // A file called `release`, and a directory called `release`.
    temp.makeFile("proj/.build-scripts/release", contents: "#!/bin/sh\n", modified: yesterday)
    temp.makeFile("proj/.build-config/release/Signing.plist", modified: yesterday)
    // Real build output beside them, touched by a build a minute ago, which must still be
    // ignored — or this test would pass on an inspector that had stopped ignoring anything.
    temp.makeFile("proj/.build-release/info.plist", modified: referenceNow)
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let activity = try #require(
        ActivityInspector(runner: FakeProcessRunner(responses: [:]))
            .lastActivity(of: project))

    #expect(abs(activity.timeIntervalSince(yesterday)) < 2)
}

@Test func gitHeadDateWinsWhenItIsNewer() throws {
    let temp = TempDir()
    let projectPath = temp.path + "/proj"
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow.addingTimeInterval(-86_400 * 90))
    temp.makeDirectory("proj/.git")
    let project = DiscoveredProject(path: projectPath, name: "proj")

    let commitEpoch = Int(referenceNow.addingTimeInterval(-86_400 * 2).timeIntervalSince1970)
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/git -C \(projectPath) log -1 --format=%ct":
            ProcessResult(exitCode: 0, stdout: "\(commitEpoch)\n", stderr: "")
    ])

    let activity = try #require(ActivityInspector(runner: runner).lastActivity(of: project))
    #expect(abs(activity.timeIntervalSince1970 - Double(commitEpoch)) < 2)
}

@Test func fileDateWinsWhenItIsNewerThanTheGitDate() throws {
    let temp = TempDir()
    let projectPath = temp.path + "/proj"
    temp.makeFile("proj/lib/main.dart", modified: referenceNow.addingTimeInterval(-86_400 * 2))
    temp.makeDirectory("proj/.git")
    let project = DiscoveredProject(path: projectPath, name: "proj")

    let commitEpoch = Int(referenceNow.addingTimeInterval(-86_400 * 90).timeIntervalSince1970)
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/git -C \(projectPath) log -1 --format=%ct":
            ProcessResult(exitCode: 0, stdout: "\(commitEpoch)\n", stderr: "")
    ])

    let activity = try #require(ActivityInspector(runner: runner).lastActivity(of: project))
    #expect(abs(activity.timeIntervalSince(referenceNow.addingTimeInterval(-86_400 * 2))) < 2)
}

@Test func gitIsNotConsultedWhenThereIsNoGitDirectory() {
    let temp = TempDir()
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow)
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let runner = RecordingProcessRunner()
    _ = ActivityInspector(runner: runner).lastActivity(of: project)
    #expect(runner.recorded.isEmpty)
}

@Test func gitFailureIsToleratedAndFileDatesStillWin() throws {
    let temp = TempDir()
    let projectPath = temp.path + "/proj"
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow.addingTimeInterval(-86_400 * 5))
    temp.makeDirectory("proj/.git")
    let project = DiscoveredProject(path: projectPath, name: "proj")

    // Git fails, but still prints something parseable, and newer than the file date.
    // Only the exit code separates this from a successful call, so a run that ignored
    // the exit code would return this epoch instead of the file date.
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/git -C \(projectPath) log -1 --format=%ct":
            ProcessResult(exitCode: 128,
                          stdout: "\(Int(referenceNow.timeIntervalSince1970))\n",
                          stderr: "fatal: your current branch does not have any commits yet")
    ])

    let activity = try #require(ActivityInspector(runner: runner).lastActivity(of: project))
    #expect(abs(activity.timeIntervalSince(referenceNow.addingTimeInterval(-86_400 * 5))) < 2)
}

@Test func symlinkedDirectoriesAreNotFollowed() throws {
    let temp = TempDir()
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow.addingTimeInterval(-86_400 * 90))
    // What fvm leaves in every project: a link to a complete SDK elsewhere. Its files
    // must not count as activity, and the walk must not spend its time in there — on a
    // real machine "elsewhere" is gigabytes, several projects share it, and a link back
    // up the tree would make the walk endless.
    let sdk = temp.makeFile("sdk/bin/flutter", modified: referenceNow)
    temp.makeSymlink("proj/.fvm-link", to: (sdk as NSString).deletingLastPathComponent)
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let activity = try #require(
        ActivityInspector(runner: FakeProcessRunner(responses: [:]))
            .lastActivity(of: project))
    #expect(activity < referenceNow.addingTimeInterval(-86_400 * 60))
}

@Test func aSymlinkCycleDoesNotHangTheWalk() throws {
    let temp = TempDir()
    temp.makeFile("proj/pubspec.yaml", modified: referenceNow.addingTimeInterval(-86_400 * 5))
    temp.makeSymlink("proj/sub/loop", to: temp.path + "/proj")
    let project = DiscoveredProject(path: temp.path + "/proj", name: "proj")

    let activity = try #require(
        ActivityInspector(runner: FakeProcessRunner(responses: [:]))
            .lastActivity(of: project))
    #expect(abs(activity.timeIntervalSince(referenceNow.addingTimeInterval(-86_400 * 5))) < 2)
}

@Test func emptyProjectDirectoryReturnsNil() {
    let temp = TempDir()
    temp.makeDirectory("empty")
    let project = DiscoveredProject(path: temp.path + "/empty", name: "empty")
    #expect(ActivityInspector(runner: FakeProcessRunner(responses: [:]))
        .lastActivity(of: project) == nil)
}
