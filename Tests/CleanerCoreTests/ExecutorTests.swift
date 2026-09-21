import Testing
import Foundation
@testable import CleanerCore

private let startedAt = Date(timeIntervalSince1970: 1_786_000_000)

private func pathItem(_ path: String, name: String = "thing") -> CleanupItem {
    ScanHelpers.item(scannerID: "projects.buildOutput", group: .projects,
                     path: path, name: name, sizeBytes: 1_000)
}

/// Stands in for the real Trash. Deletes the file so "gone from its original
/// path" assertions still mean something, and reports a plausible Trash
/// location, without touching the developer's actual ~/.Trash.
final class FakeFileRemover: FileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(path: String, trashed: Bool)] = []

    func trash(_ path: String) throws -> String {
        try FileManager.default.removeItem(atPath: path)
        lock.lock(); calls.append((path, true)); lock.unlock()
        return "/Users/tester/.Trash/" + (path as NSString).lastPathComponent
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
        lock.lock(); calls.append((path, false)); lock.unlock()
    }

    var recorded: [(path: String, trashed: Bool)] {
        lock.lock(); defer { lock.unlock() }; return calls
    }
}

/// A Trash that is broken: `trash` always throws, `remove` still works.
///
/// The Trash really can refuse — a full volume, a `.Trashes` the user has no write access
/// to — and the visible-name rename turns that from one failure into three code paths: put
/// the folder back and report the original error, or fail to put it back and say where it
/// now is.
final class TrashRefusingRemover: FileRemoving, @unchecked Sendable {
    struct NoRoom: Error, LocalizedError {
        var errorDescription: String? { "the Trash has no room for it" }
    }

    private let lock = NSLock()
    private var attempts: [String] = []

    func trash(_ path: String) throws -> String {
        lock.lock(); attempts.append(path); lock.unlock()
        throw NoRoom()
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    /// Every path the executor asked it to trash, which is how a test sees the renamed one.
    var attempted: [String] {
        lock.lock(); defer { lock.unlock() }; return attempts
    }
}

/// A `FileManager` that lets a given number of renames through and then refuses.
///
/// `allowing: 0` is a filesystem where the cosmetic rename cannot happen at all — a
/// read-only project directory, a name the volume will not take — and the clean has to go
/// on regardless. `allowing: 1` is the rename working and the **rename back** failing after
/// the Trash refused, which is the one path that leaves data somewhere no scan will look.
///
/// A subclass rather than a protocol: `Executor` takes a `FileManager` because it uses four
/// other things on it, and overriding the one method keeps the rest real.
final class RenameRefusingFileManager: FileManager, @unchecked Sendable {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "the volume refused the rename" }
    }

    private let allowed: Int
    private let lock = NSLock()
    private var used = 0

    init(allowing allowed: Int) {
        self.allowed = allowed
        super.init()
    }

    override func moveItem(atPath srcPath: String, toPath dstPath: String) throws {
        lock.lock(); used += 1; let attempt = used; lock.unlock()
        guard attempt > allowed else {
            try super.moveItem(atPath: srcPath, toPath: dstPath)
            return
        }
        throw Refused()
    }
}

/// `RecordingProcessRunner` with one executable that cannot be started at all.
///
/// A missing binary makes `Process.run()` throw rather than exit non-zero, so
/// "`platform-tools` is not installed" is a different path through the code from
/// "adb ran and failed", and no stubbed exit code can stand in for it.
final class RunnerWithAMissingBinary: ProcessRunner, @unchecked Sendable {
    struct NotInstalled: Error, CustomStringConvertible {
        let executable: String
        var description: String { "\(executable) does not exist" }
    }

    private let lock = NSLock()
    private var commands: [String] = []
    private let missing: String

    init(missing: String) { self.missing = missing }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let key = commandKey(executable, arguments)
        lock.lock(); commands.append(key); lock.unlock()
        guard executable != missing else { throw NotInstalled(executable: executable) }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }; return commands
    }
}

private func makeExecutor(temp: TempDir, runner: any ProcessRunner,
                          projectPaths: [String] = [],
                          remover: any FileRemoving = FakeFileRemover(),
                          moveToTrash: Bool = true,
                          fileManager: FileManager = .default,
                          allowedRoots: [String]? = nil,
                          now: @escaping @Sendable () -> Date = { Date() }) -> Executor {
    let pathGuard = PathGuard(
        allowedRoots: allowedRoots ?? [temp.path + "/allowed"],
        forbiddenTargets: projectPaths)
    return Executor(guard: pathGuard, runner: runner, remover: remover,
                    fileManager: fileManager, home: temp.path, moveToTrash: moveToTrash,
                    now: now)
}

/// An executor whose guard is the real `PathGuard.forRun`, for the cases that are
/// about the roots themselves rather than about a hand-made allowlist.
private func makeRealGuardExecutor(temp: TempDir, runner: any ProcessRunner,
                                   remover: any FileRemoving = FakeFileRemover(),
                                   projectRoots: [String] = [],
                                   projectPaths: [String] = [],
                                   moveToTrash: Bool = true) -> Executor {
    Executor(
        guard: PathGuard.forRun(home: temp.path, projectRoots: projectRoots,
                                projectPaths: projectPaths),
        runner: runner, remover: remover, fileManager: .default,
        home: temp.path, moveToTrash: moveToTrash)
}

private func makeExecutableFile(_ temp: TempDir, _ relative: String) -> String {
    let path = temp.makeFile(relative, contents: "#!/bin/sh\n")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

// MARK: - path removal

@Test func trashesAGuardedPathAndRecordsWhereItWent() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/project/build")
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(target, name: "build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: target))
    #expect(record.entries.count == 1)
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(entry.trashedTo?.contains(".Trash") == true)
    #expect(entry.isRestorable)
    #expect(record.trashedBytes == 1_000)
    #expect(record.permanentlyDeletedBytes == 0)
}

@Test func permanentModeDeletesOutrightAndNeverTrashes() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/project/build")
    let remover = FakeFileRemover()
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover, moveToTrash: false)
        .run(items: [pathItem(target, name: "build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
    #expect(entry.trashedTo == nil)
    #expect(!entry.isRestorable)
    #expect(!remover.recorded.isEmpty)
    #expect(remover.recorded.allSatisfy { !$0.trashed })
    #expect(record.trashedBytes == 0)
    #expect(record.permanentlyDeletedBytes == 1_000)
}

// MARK: - SystemFileRemover, the production removal path

/// `trash` cannot be tested without the developer's own `~/.Trash`, and a volume that
/// has no Trash fails those tests for environmental reasons rather than because the
/// code is wrong. They are therefore opt-in:
///
///     DEVCLEANER_REAL_TRASH=1 swift test
///
/// `remove` needs nothing of the sort and is tested below without a gate.
private let realTrashTestsEnabled =
    ProcessInfo.processInfo.environment["DEVCLEANER_REAL_TRASH"] != nil

@Test(.enabled(if: realTrashTestsEnabled))
func aRealTrashRoundTripPutsTheItemInTheTrashAndCleansUpAfterItself() throws {
    // Touches the real Trash, so SystemFileRemover is not shipped untested.
    // It removes what it trashed before returning.
    let temp = TempDir()
    let target = temp.makeFile("allowed/scratch.txt", contents: "x")
    let landed = try SystemFileRemover().trash(target)
    defer { try? FileManager.default.removeItem(atPath: landed) }

    #expect(!FileManager.default.fileExists(atPath: target))
    #expect(FileManager.default.fileExists(atPath: landed))
    #expect(landed.contains(".Trash"))
}

/// Spec rule 5, on the production Trash call rather than on a double. A `build` that is
/// a symlink to another disk must cost the link and not the disk: resolving the path
/// before handing it to `trashItem` would move the whole target into the Trash.
@Test(.enabled(if: realTrashTestsEnabled))
func theRealTrashMovesASymlinkItselfAndLeavesItsTargetAlone() throws {
    let temp = TempDir()
    let realDirectory = temp.makeDirectory("outside/important")
    let kept = temp.makeFile("outside/important/keep.txt", contents: "x")
    let link = temp.makeSymlink("allowed/link", to: realDirectory)

    let landed = try SystemFileRemover().trash(link)
    // Removed whatever happened above, so a run that fails the assertions — a mutation
    // run, say — still leaves nothing behind in the developer's Trash.
    defer { try? FileManager.default.removeItem(atPath: landed) }

    #expect(FileManager.default.fileExists(atPath: realDirectory))
    #expect(FileManager.default.fileExists(atPath: kept))
    // `attributesOfItem` does not follow a symlink, so it can tell "the link is gone"
    // apart from "the link is still there and now dangles". `fileExists` cannot.
    #expect((try? FileManager.default.attributesOfItem(atPath: link)) == nil)
    let landedType =
        (try? FileManager.default.attributesOfItem(atPath: landed))?[.type] as? FileAttributeType
    #expect(landedType == .typeSymbolicLink)
    #expect(landed.contains(".Trash"))
}

/// The name the user will actually read, in the actual Trash, through the actual executor —
/// the one thing a double cannot tell us, and the whole point of the rename. The project is
/// named with a UUID so the run cannot collide with anything already in the developer's
/// Trash and have macOS number it.
@Test(.enabled(if: realTrashTestsEnabled))
func aRealRunLandsAProjectsBuildFolderInTheTrashUnderAVisibleName() async throws {
    let temp = TempDir()
    let project = "devcleaner-\(UUID().uuidString)"
    let target = temp.makeDirectory("allowed/\(project)/.build")
    temp.makeFile("allowed/\(project)/.build/output.o", contents: "x")

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: SystemFileRemover())
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    let entry = try #require(record.entries.first)
    let landed = try #require(entry.trashedTo)
    // Removed whatever happened above, so even a failing run leaves nothing behind in the
    // developer's Trash.
    defer { try? FileManager.default.removeItem(atPath: landed) }

    #expect(entry.outcome == .trashed)
    #expect(landed.contains(".Trash"))
    #expect((landed as NSString).lastPathComponent == "\(project) – .build")
    #expect(FileManager.default.fileExists(atPath: landed + "/output.o"))
    // And nothing is left in the project under either name.
    #expect(!FileManager.default.fileExists(atPath: target))
    #expect(!FileManager.default.fileExists(
        atPath: approved(temp, "allowed/\(project)/\(project) – .build")))
}

@Test func theSystemRemoverDeletesWhatItIsGiven() throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    temp.makeFile("allowed/build/output.o", contents: "x")

    try SystemFileRemover().remove(target)

    #expect(!FileManager.default.fileExists(atPath: target))
}

/// The permanent-removal half of rule 5, on the production call. Resolving the path
/// before handing it to `removeItem` would delete the directory the link points at.
@Test func theSystemRemoverUnlinksASymlinkItselfAndLeavesItsTargetAlone() throws {
    let temp = TempDir()
    let realDirectory = temp.makeDirectory("outside/important")
    let kept = temp.makeFile("outside/important/keep.txt", contents: "x")
    let link = temp.makeSymlink("allowed/link", to: realDirectory)

    try SystemFileRemover().remove(link)

    #expect(FileManager.default.fileExists(atPath: realDirectory))
    #expect(FileManager.default.fileExists(atPath: kept))
    #expect((try? FileManager.default.attributesOfItem(atPath: link)) == nil)
}

@Test func theSystemRemoverReportsAFailureRatherThanSwallowingIt() throws {
    let temp = TempDir()
    #expect(throws: (any Error).self) {
        try SystemFileRemover().remove(temp.path + "/never-existed")
    }
}

@Test func theExecutorDeletesThePathTheGuardApprovedNotTheOneItWasGiven() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/caches/build")
    let remover = FakeFileRemover()
    // Names the same directory through a detour. The guard resolves it; acting on the
    // supplied string would be acting on something the guard never checked.
    let supplied = temp.path + "/allowed/caches/../caches/build"
    // Read before the run, because `canonicalise` needs the directory to still exist.
    let approved = try #require(PathGuard.canonicalise(target))
    // A shared cache rather than a project row, so the path reaching the remover is the
    // approved one itself: a project's build folder is renamed on the way out, and
    // `theVisibleNameIsAssembledFromThePathTheGuardApproved` pins the same property there.
    let row = ScanHelpers.item(scannerID: "other.jsPackages", group: .otherCaches,
                               path: supplied, name: "build", sizeBytes: 1_000)

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [row], devices: .empty, startedAt: startedAt, progress: { _ in })

    let call = try #require(remover.recorded.first)
    #expect(call.path == approved)
    let entry = try #require(record.entries.first)
    #expect(entry.target == approved)
    #expect(!FileManager.default.fileExists(atPath: target))
}

@Test func refusesAPathOutsideTheAllowedRootsAndKeepsGoing() async throws {
    let temp = TempDir()
    let outside = temp.makeDirectory("elsewhere/build")
    let inside = temp.makeDirectory("allowed/ok/build")

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(outside, name: "outside"), pathItem(inside, name: "inside")],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: outside))
    #expect(!FileManager.default.fileExists(atPath: inside))
    let refused = try #require(record.entries.first { $0.name == "outside" })
    #expect(refused.outcome == .failed)
    #expect(refused.reason?.contains("allowed root") == true)
    let removed = try #require(record.entries.first { $0.name == "inside" })
    #expect(removed.outcome == .trashed)
}

@Test func refusesToDeleteAProjectDirectoryItself() async throws {
    let temp = TempDir()
    let project = temp.makeDirectory("allowed/sample-project")
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    projectPaths: [project])
        .run(items: [pathItem(project, name: "sample-project")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: project))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("protected target") == true)
}

/// Blocker from Task 16. `ProjectBuildOutputScanner` gives every protected project a
/// summary row whose deletion target is the project's own directory. `protection` is
/// what normally stops it, so this test removes that stop deliberately: the item
/// arrives unprotected, as it would if any code upstream ignored `isDeletable`, and
/// the guard has to refuse it on its own.
@Test func everyDiscoveredProjectDirectoryIsAForbiddenTargetOfTheRunGuard() async throws {
    let temp = TempDir()
    let projectRoot = temp.makeDirectory("dev")
    let project = temp.makeDirectory("dev/sample-project")
    let build = temp.makeDirectory("dev/sample-project/build")

    let summaryRowWithItsProtectionLost = CleanupItem(
        id: "projects.buildOutput|\(project)", scannerID: "projects.buildOutput",
        group: .projects, name: "sample-project", detail: nil, sizeBytes: 40_000_000_000,
        lastUsed: nil, risk: .safe, protection: nil, method: .removePath(project))

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(),
        projectRoots: [projectRoot], projectPaths: [project])
        .run(items: [summaryRowWithItsProtectionLost], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: project))
    #expect(FileManager.default.fileExists(atPath: build))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("protected target") == true)
    #expect(record.trashedBytes == 0)
    #expect(record.permanentlyDeletedBytes == 0)
}

@Test func removesASymlinkWithoutTouchingItsTarget() async {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    let realDirectory = temp.makeDirectory("outside/important")
    let link = temp.makeSymlink("allowed/link", to: realDirectory)

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(link, name: "link")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: link))
    #expect(FileManager.default.fileExists(atPath: realDirectory))
}

@Test func reportsAFailedRemovalWithoutStoppingTheRun() async throws {
    let temp = TempDir()
    let first = temp.makeDirectory("allowed/gone")
    let second = temp.makeDirectory("allowed/here")
    // Removed behind the executor's back, so `remover.trash` throws on it.
    try FileManager.default.removeItem(atPath: first)

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(first, name: "gone"), pathItem(second, name: "here")],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    let failed = try #require(record.entries.first { $0.name == "gone" })
    #expect(failed.outcome == .failed)
    #expect(failed.reason != nil)
    let removed = try #require(record.entries.first { $0.name == "here" })
    #expect(removed.outcome == .trashed)
    #expect(record.failedCount == 1)
    #expect(record.trashedCount == 1)
}

// MARK: - protection

/// A protected item reaching the executor is a bug upstream. The executor refuses it
/// anyway, before the guard is even consulted, because the cost of that bug is a live
/// project's build folder or a permanently deleted device.
@Test func refusesAnItemThatIsStillProtected() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/live-project/build")
    let remover = FakeFileRemover()
    let item = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects, path: target,
        name: "build", sizeBytes: 5_000, protection: .recentActivity(days: 14))

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: target))
    #expect(remover.recorded.isEmpty)
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("protected") == true)
    #expect(entry.reason?.contains("changed in the last 14 days") == true)
    #expect(record.trashedBytes == 0)
}

@Test func refusesAProtectedDeviceWithoutRunningAnyCommand() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [
        SimulatorDevice(udid: "AAA", name: "iPhone 17", runtimeIdentifier: "iOS-26-5",
                        isBooted: true,
                        sizeBytes: 12_860_000_000, lastBootedAt: startedAt),
    ], runtimes: [], avds: [])
    let item = CleanupItem(
        id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone 17", detail: nil, sizeBytes: 12_860_000_000, lastUsed: nil,
        risk: .safe, protection: .recentlyUsedDevice(days: 7),
        method: .deleteSimulator(udid: "AAA"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: devices, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("simctl delete") })
    // Not shut down either: preflight looks only at what will actually be executed.
    #expect(!runner.recorded.contains { $0.contains("simctl shutdown") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(record.permanentlyDeletedBytes == 0)
}

@Test func aProtectedGradleItemDoesNotStopTheDaemons() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/caches/modules-2")
    let runner = RecordingProcessRunner()
    let item = ScanHelpers.item(
        scannerID: "android.gradle", group: .android, path: target,
        name: "Downloaded dependencies", sizeBytes: 1,
        protection: .gradleVersionInUse(by: "sample-project"))

    _ = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("GradleDaemon") })
}

// MARK: - devices

/// The second of the two layers that keep a running simulator alive, and the one that
/// holds even when the first has been bypassed: the item handed over here carries **no**
/// protection, exactly as a caller with a stale scan result or a bug in its ticking would
/// hand it over.
///
/// It used to be deleted, and the run began by shutting it down in order to do so:
/// `simctl shutdown` killed the live session with no warning, then `simctl delete`
/// destroyed the device directory — every installed app, its databases, its user
/// defaults, its keychain. No Trash, no undo.
@Test func refusesToDeleteASimulatorThatIsRunningEvenWhenTheItemIsNotProtected() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [
        SimulatorDevice(udid: "AAA", name: "iPhone", runtimeIdentifier: "iOS-26-5",
                        isBooted: true, sizeBytes: 1, lastBootedAt: startedAt),
    ], runtimes: [], avds: [])

    let item = CleanupItem(
        id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .elevated,
        protection: nil, method: .deleteSimulator(udid: "AAA"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: devices, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("simctl delete") })
    // And it is not shut down to make the deletion possible. Ending the user's session
    // and then removing nothing is worse than doing nothing at all.
    #expect(!runner.recorded.contains { $0.contains("simctl shutdown") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .skipped)
    #expect(entry.reason?.contains("the simulator is running") == true)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// The over-fix guard for the refusal above. A rule that skipped every simulator would
/// pass that test and quietly stop the tool doing the thing it exists to do.
@Test func aSimulatorThatIsNotRunningIsStillDeleted() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [
        SimulatorDevice(udid: "AAA", name: "iPhone", runtimeIdentifier: "iOS-26-5",
                        isBooted: false, sizeBytes: 1, lastBootedAt: startedAt),
        // A different simulator is running. Being booted must protect that one alone.
        SimulatorDevice(udid: "BBB", name: "iPad", runtimeIdentifier: "iOS-26-5",
                        isBooted: true, sizeBytes: 1, lastBootedAt: startedAt),
    ], runtimes: [], avds: [])

    let item = CleanupItem(
        id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .elevated,
        protection: nil, method: .deleteSimulator(udid: "AAA"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: devices, startedAt: startedAt, progress: { _ in })

    #expect(runner.recorded.contains { $0.contains("simctl delete AAA") })
    // Devices report .deleted even though the executor is in Trash mode:
    // simctl removes them outright and has no Trash equivalent.
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
    #expect(entry.trashedTo == nil)
    #expect(!entry.isRestorable)
}

@Test func aBootedSimulatorThatIsNotBeingDeletedIsLeftRunning() async {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [
        SimulatorDevice(udid: "BBB", name: "iPad", runtimeIdentifier: "iOS-26-5",
                        isBooted: true, sizeBytes: 1, lastBootedAt: startedAt),
    ], runtimes: [], avds: [])
    let target = temp.makeDirectory("allowed/build")

    _ = await makeExecutor(temp: temp, runner: runner)
        .run(items: [pathItem(target)], devices: devices,
             startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("simctl shutdown") })
}

private let runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.iOS-18-2"

private func runtimeItem(
    _ identifier: String = runtimeIdentifier, sizeBytes: Int64 = 7_000_000_000
) -> CleanupItem {
    CleanupItem(
        id: "ios.runtimes|\(identifier)",
        scannerID: "ios.runtimes", group: .xcodeAndIOS, name: "iOS 18.2", detail: nil,
        sizeBytes: sizeBytes, lastUsed: nil, risk: .elevated, protection: nil,
        method: .deleteSimulatorRuntime(identifier: identifier))
}

/// **The bug this wave exists for.** `simctl runtime delete` does not take the runtime
/// identifier a row carries: on current Xcode a runtime is a disk image and the command
/// wants that image's UUID. Handed
/// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` it answered "No runtime disk images or
/// bundles found matching …", deleted nothing, and the user was told their permanent
/// deletion of 17.3 GB had failed.
///
/// The UUID is resolved from the inventory the run was handed — loaded fresh by
/// `CleanerService.clean`, rather than carried on a row that may have come from a
/// `cache.json` written days ago.
@Test func deletesARuntimeByTheUUIDOfItsDiskImage() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", name: "iOS 26.5",
            version: "26.5", buildVersion: "23F77", bundlePath: "/rt/26.5",
            images: [SimulatorRuntimeImage(
                identifier: "09A925DA-7B77-461C-B7E8-98E7F377116D", build: "23F77",
                sizeBytes: 8_494_282_293, deletable: true, state: "Ready")]),
    ], avds: [])
    let item = runtimeItem("com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                           sizeBytes: 8_494_282_293)

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: devices, startedAt: startedAt, progress: { _ in })

    #expect(runner.recorded.contains {
        $0 == "/usr/bin/xcrun simctl runtime delete 09A925DA-7B77-461C-B7E8-98E7F377116D"
    })
    // And never the runtime identifier, which is the call that deleted nothing.
    #expect(!runner.recorded.contains { $0.contains("SimRuntime.iOS-26-5") })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
    // `target` stays the runtime identifier whatever UUID the tool had to be handed: it is
    // what the row, the stored run log and `AppModel`'s pruning all key on.
    #expect(entry.target == "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    #expect(entry.trashedTo == nil)
    #expect(record.permanentlyDeletedBytes == 8_494_282_293)
    #expect(record.trashedBytes == 0)
}

/// Two builds of one version share a runtime identifier, so `ScanEngine` merges them into
/// one row and answering it means both images.
@Test func deletesEveryDiskImageBehindOneRuntimeRow() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(
            identifier: runtimeIdentifier, name: "iOS 18.2", version: "18.2",
            buildVersion: "22C150", bundlePath: "/rt/22C150",
            images: [SimulatorRuntimeImage(identifier: "IMG-A", build: "22C150",
                                           sizeBytes: 7_000_000_000, deletable: true,
                                           state: "Ready")]),
        SimulatorRuntime(
            identifier: runtimeIdentifier, name: "iOS 18.2", version: "18.2",
            buildVersion: "22C151", bundlePath: "/rt/22C151",
            images: [SimulatorRuntimeImage(identifier: "IMG-B", build: "22C151",
                                           sizeBytes: 6_000_000_000, deletable: true,
                                           state: "Ready")]),
    ], avds: [])

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [runtimeItem()], devices: devices, startedAt: startedAt,
             progress: { _ in })

    #expect(runner.recorded.contains { $0.hasSuffix("simctl runtime delete IMG-A") })
    #expect(runner.recorded.contains { $0.hasSuffix("simctl runtime delete IMG-B") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
}

/// One image refusing fails the row, whatever the other one did.
///
/// Reported as success, this is a row that leaves gigabytes on the disk and tells the user
/// they are gone — so they stop looking for them. The reason is simctl's own stderr, which
/// is the only text that says what actually went wrong.
@Test func aRuntimeRowFailsWhenAnyOfItsDiskImagesDoes() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner(responses: [
        "/usr/bin/xcrun simctl runtime delete IMG-B":
            ProcessResult(exitCode: 1, stdout: "",
                          stderr: "Unable to delete: the image is in use\n"),
    ])
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(
            identifier: runtimeIdentifier, name: "iOS 18.2", version: "18.2",
            buildVersion: "22C150", bundlePath: "/rt/18.2",
            images: [SimulatorRuntimeImage(identifier: "IMG-A", build: "22C150",
                                           sizeBytes: 7_000_000_000, deletable: true,
                                           state: "Ready"),
                     SimulatorRuntimeImage(identifier: "IMG-B", build: "22C150",
                                           sizeBytes: 6_000_000_000, deletable: true,
                                           state: "Ready")]),
    ], avds: [])

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [runtimeItem()], devices: devices, startedAt: startedAt,
             progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("the image is in use") == true)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// **The legacy case, and the reason the old call is still here.** A runtime the inventory
/// knows no disk image for is a bundle runtime — or anything on an Xcode whose
/// `simctl runtime list` could not be read — and there the runtime identifier is what
/// `simctl runtime delete` takes and the only thing there is to hand it.
///
/// This test pinned the identifier call for every runtime until disk images were read.
@Test func deletesABundleRuntimeByItsRuntimeIdentifier() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()

    // `.empty`: an inventory that knows of no image for this runtime.
    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [runtimeItem()], devices: .empty, startedAt: startedAt,
             progress: { _ in })

    #expect(runner.recorded.contains {
        $0 == "/usr/bin/xcrun simctl runtime delete \(runtimeIdentifier)"
    })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
    #expect(entry.trashedTo == nil)
    #expect(record.permanentlyDeletedBytes == 7_000_000_000)
    #expect(record.trashedBytes == 0)
}

/// A runtime in the inventory with no image falls back too — it is the same answer as an
/// inventory that does not mention the runtime at all, and the branch is the one an older
/// Xcode takes for every row.
@Test func aRuntimeTheInventoryKnowsNoImageForStillUsesTheOldCall() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: runtimeIdentifier, name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "/rt/18.2"),
    ], avds: [])

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [runtimeItem()], devices: devices, startedAt: startedAt,
             progress: { _ in })

    #expect(runner.recorded.contains {
        $0 == "/usr/bin/xcrun simctl runtime delete \(runtimeIdentifier)"
    })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
}

/// The failure of the legacy call keeps carrying simctl's own message, exactly as it did.
@Test func aFailedBundleRuntimeDeletionCarriesTheToolsOwnMessage() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner(responses: [
        "/usr/bin/xcrun simctl runtime delete \(runtimeIdentifier)":
            ProcessResult(exitCode: 1, stdout: "",
                          stderr: "No runtime disk images or bundles found matching "
                              + "'\(runtimeIdentifier)'\n"),
    ])

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [runtimeItem()], devices: .empty, startedAt: startedAt,
             progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("No runtime disk images or bundles found") == true)
    #expect(record.permanentlyDeletedBytes == 0)
}

@Test func aFailedDeviceDeletionCarriesTheToolsOwnMessage() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner(responses: [
        "/usr/bin/xcrun simctl delete AAA":
            ProcessResult(exitCode: 1, stdout: "", stderr: "Unable to delete: device is booted\n"),
    ])
    let item = CleanupItem(
        id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone", detail: nil, sizeBytes: 5, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteSimulator(udid: "AAA"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("device is booted") == true)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// Spec §7.3. Devices ignore the Trash setting, so the record has to say in plain
/// words that nothing it removed can be got back — that is what Tasks 19 and 20 warn
/// the user with.
@Test func aRunThatRemovedADeviceSaysThatDeviceRemovalIsPermanent() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let item = CleanupItem(
        id: "android.avds|pixel", scannerID: "android.avds", group: .android,
        name: "pixel", detail: nil, sizeBytes: 9, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "pixel"))
    let sdkBin = temp.path + "/Library/Android/sdk"
    _ = makeExecutableFile(temp, "Library/Android/sdk/cmdline-tools/latest/bin/avdmanager")

    let record = await Executor(
        guard: PathGuard(allowedRoots: [temp.path + "/allowed"], forbiddenTargets: []),
        runner: RecordingProcessRunner(), remover: FakeFileRemover(),
        fileManager: .default, home: temp.path, moveToTrash: true,
        androidSDKPath: sdkBin)
        .run(items: [pathItem(target, name: "build"), item], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(record.notes.contains(Executor.Note.devicesWereRemovedPermanently))
    let permanent = record.permanentlyDeletedEntries
    #expect(permanent.count == 1)
    #expect(try #require(permanent.first).name == "pixel")
    #expect(record.trashedCount == 1)
}

/// `.deleted` is also where a path lands in permanent mode, so the note has to be tied
/// to the item having been a device, not to the outcome alone. Otherwise a user who
/// turned the Trash off is told their build folders were simulators.
@Test func permanentlyRemovedPathsDoNotClaimToBeDeviceRemovals() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    moveToTrash: false)
        .run(items: [pathItem(target)], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(record.permanentlyDeletedEntries.count == 1)
    #expect(!record.notes.contains(Executor.Note.devicesWereRemovedPermanently))
    #expect(record.notes.isEmpty)
}

@Test func aRunWithNoDeviceDoesNotClaimAnythingIsPermanent() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(target)], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(!record.notes.contains(Executor.Note.devicesWereRemovedPermanently))
    #expect(record.permanentlyDeletedEntries.isEmpty)
}

// MARK: - emulators

@Test func skipsARunningEmulatorInsteadOfDeletingIt() async throws {
    let temp = TempDir()
    let runner = RecordingProcessRunner(responses: [
        "\(temp.path)/Library/Android/sdk/platform-tools/adb devices":
            ProcessResult(exitCode: 0,
                          stdout: "List of devices attached\nemulator-5554\tdevice\n", stderr: ""),
        "\(temp.path)/Library/Android/sdk/platform-tools/adb -s emulator-5554 emu avd name":
            ProcessResult(exitCode: 0, stdout: "sample_emulator_1\nOK\n", stderr: ""),
    ])

    let items = [
        CleanupItem(id: "android.avds|sample_emulator_1", scannerID: "android.avds", group: .android,
                    name: "sample_emulator_1", detail: nil, sizeBytes: 1, lastUsed: nil,
                    risk: .safe, protection: nil, method: .deleteAVD(name: "sample_emulator_1")),
        CleanupItem(id: "android.avds|sample_avd", scannerID: "android.avds", group: .android,
                    name: "sample_avd", detail: nil, sizeBytes: 1, lastUsed: nil,
                    risk: .safe, protection: nil, method: .deleteAVD(name: "sample_avd")),
    ]
    _ = makeExecutableFile(temp, "Library/Android/sdk/cmdline-tools/latest/bin/avdmanager")

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: items, devices: .empty, startedAt: startedAt, progress: { _ in })

    let skipped = try #require(record.entries.first { $0.name == "sample_emulator_1" })
    #expect(skipped.outcome == .skipped)
    #expect(skipped.reason == "the emulator is running")
    let deleted = try #require(record.entries.first { $0.name == "sample_avd" })
    #expect(deleted.outcome == .deleted)
    #expect(!runner.recorded.contains { $0.contains("delete avd -n sample_emulator_1") })
}

/// An empty answer from adb and no answer at all are two different things, and reading
/// the second as the first is how a **running** emulator gets deleted for good.
/// `platform-tools` missing is the common way to get there: there is no adb to ask, so
/// nothing can be said about what is running.
@Test func noEmulatorIsDeletedWhenAdbIsNotInstalled() async throws {
    let temp = TempDir()
    let adb = "\(temp.path)/Library/Android/sdk/platform-tools/adb"
    let runner = RunnerWithAMissingBinary(missing: adb)
    _ = makeExecutableFile(temp, "Library/Android/sdk/cmdline-tools/latest/bin/avdmanager")
    let item = CleanupItem(
        id: "android.avds|sample_emulator_1", scannerID: "android.avds", group: .android,
        name: "sample_emulator_1", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "sample_emulator_1"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("delete avd") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .skipped)
    #expect(entry.reason?.contains(adb) == true)
    #expect(entry.reason?.contains("could not be run") == true)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// The other way adb fails to answer: it is installed, it runs, and it exits non-zero —
/// its server failing to start is the usual cause. Same verdict, and the reason carries
/// adb's own message so the user knows what to fix before running again.
@Test func noEmulatorIsDeletedWhenAdbExitsNonZero() async throws {
    let temp = TempDir()
    let adb = "\(temp.path)/Library/Android/sdk/platform-tools/adb"
    let runner = RecordingProcessRunner(responses: [
        "\(adb) devices": ProcessResult(
            exitCode: 1, stdout: "",
            stderr: "adb: failed to start daemon\n"),
    ])
    _ = makeExecutableFile(temp, "Library/Android/sdk/cmdline-tools/latest/bin/avdmanager")
    let item = CleanupItem(
        id: "android.avds|sample_emulator_1", scannerID: "android.avds", group: .android,
        name: "sample_emulator_1", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "sample_emulator_1"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("delete avd") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .skipped)
    #expect(entry.reason?.contains("exited with code 1") == true)
    #expect(entry.reason?.contains("failed to start daemon") == true)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// Third way, and the worst one: `adb devices` lists an emulator and then refuses to say
/// which AVD it is. Passing over that serial would leave exactly the running AVD
/// deletable, so the whole answer is treated as unknown.
@Test func noEmulatorIsDeletedWhenAdbWillNotSayWhichAVDIsRunning() async throws {
    let temp = TempDir()
    let adb = "\(temp.path)/Library/Android/sdk/platform-tools/adb"
    let runner = RecordingProcessRunner(responses: [
        "\(adb) devices": ProcessResult(
            exitCode: 0, stdout: "List of devices attached\nemulator-5554\tdevice\n", stderr: ""),
        "\(adb) -s emulator-5554 emu avd name": ProcessResult(
            exitCode: 1, stdout: "", stderr: "error: no console auth token\n"),
    ])
    _ = makeExecutableFile(temp, "Library/Android/sdk/cmdline-tools/latest/bin/avdmanager")
    let item = CleanupItem(
        id: "android.avds|sample_emulator_1", scannerID: "android.avds", group: .android,
        name: "sample_emulator_1", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "sample_emulator_1"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("delete avd") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .skipped)
    #expect(entry.reason?.contains("emulator-5554") == true)
}

/// The fallback that runs when the Android command line tools are missing is covered by
/// the same rule. It trashes the AVD's files itself, and doing that to a running
/// emulator leaves it running on files that are no longer where it left them.
@Test func theAVDFallbackAlsoStandsAsideWhenAdbCannotAnswer() async throws {
    let temp = TempDir()
    let adb = "\(temp.path)/Library/Android/sdk/platform-tools/adb"
    temp.makeDirectory(".android/avd")
    let avdDirectory = temp.makeDirectory(".android/avd/pixel.avd")
    let ini = temp.makeFile(".android/avd/pixel.ini", contents: "path=whatever")
    let remover = FakeFileRemover()
    let item = CleanupItem(
        id: "android.avds|pixel", scannerID: "android.avds", group: .android,
        name: "pixel", detail: nil, sizeBytes: 3_000, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "pixel"))

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RunnerWithAMissingBinary(missing: adb), remover: remover)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.isEmpty)
    #expect(FileManager.default.fileExists(atPath: avdDirectory))
    #expect(FileManager.default.fileExists(atPath: ini))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .skipped)
    #expect(record.trashedBytes == 0)
}

/// Rule 4: a listing of only emulators cannot test the `emulator-` filter. A real
/// phone answers `adb devices` too, and `emu avd name` is meaningless for it.
@Test func onlyEmulatorSerialsAreAskedWhichAVDTheyAreRunning() async throws {
    let temp = TempDir()
    let adb = "\(temp.path)/Library/Android/sdk/platform-tools/adb"
    let runner = RecordingProcessRunner(responses: [
        "\(adb) devices": ProcessResult(
            exitCode: 0,
            stdout: "List of devices attached\nR58M12345XYZ\tdevice\nemulator-5554\tdevice\n",
            stderr: ""),
        "\(adb) -s emulator-5554 emu avd name":
            ProcessResult(exitCode: 0, stdout: "sample_avd\nOK\n", stderr: ""),
    ])
    let item = CleanupItem(
        id: "android.avds|sample_avd", scannerID: "android.avds", group: .android,
        name: "sample_avd", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "sample_avd"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("-s R58M12345XYZ") })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .skipped)
}

@Test func adbIsNotAskedAnythingWhenNoEmulatorIsSelected() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let runner = RecordingProcessRunner()

    _ = await makeExecutor(temp: temp, runner: runner)
        .run(items: [pathItem(target)], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(!runner.recorded.contains { $0.contains("adb") })
}

@Test func avdmanagerIsUsedWhenItIsInstalled() async throws {
    let temp = TempDir()
    temp.makeDirectory(".android/avd")
    let avdDirectory = temp.makeDirectory(".android/avd/pixel.avd")
    _ = makeExecutableFile(temp, "Library/Android/sdk/cmdline-tools/latest/bin/avdmanager")
    let runner = RecordingProcessRunner()
    let remover = FakeFileRemover()
    let item = CleanupItem(
        id: "android.avds|pixel", scannerID: "android.avds", group: .android,
        name: "pixel", detail: nil, sizeBytes: 1, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "pixel"))

    let record = await makeRealGuardExecutor(temp: temp, runner: runner, remover: remover)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(runner.recorded.contains { $0.contains("delete avd -n pixel") })
    // avdmanager owns the removal; the file remover is not involved, so the AVD is
    // permanent even in Trash mode.
    #expect(remover.recorded.isEmpty)
    #expect(FileManager.default.fileExists(atPath: avdDirectory))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
}

/// The fallback for a machine with no Android command line tools. It touches plain
/// files, so it honours the Trash setting — and it reports `.trashed`, because saying
/// "gone for good" about something sitting in the Trash would stop the user looking
/// for it.
@Test func theFallbackTrashesBothAVDFilesWhenAvdmanagerIsMissing() async throws {
    let temp = TempDir()
    temp.makeDirectory(".android/avd")
    let avdDirectory = temp.makeDirectory(".android/avd/pixel.avd")
    let ini = temp.makeFile(".android/avd/pixel.ini", contents: "path=whatever")
    let remover = FakeFileRemover()
    let item = CleanupItem(
        id: "android.avds|pixel", scannerID: "android.avds", group: .android,
        name: "pixel", detail: nil, sizeBytes: 3_000, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "pixel"))

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: avdDirectory))
    #expect(!FileManager.default.fileExists(atPath: ini))
    #expect(remover.recorded.count == 2)
    #expect(remover.recorded.allSatisfy { $0.trashed })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(entry.trashedTo?.contains("pixel.avd") == true)
    #expect(record.trashedBytes == 3_000)
}

@Test func theFallbackDeletesBothAVDFilesOutrightInPermanentMode() async throws {
    let temp = TempDir()
    temp.makeDirectory(".android/avd")
    let avdDirectory = temp.makeDirectory(".android/avd/pixel.avd")
    temp.makeFile(".android/avd/pixel.ini", contents: "path=whatever")
    let remover = FakeFileRemover()
    let item = CleanupItem(
        id: "android.avds|pixel", scannerID: "android.avds", group: .android,
        name: "pixel", detail: nil, sizeBytes: 3_000, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "pixel"))

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover, moveToTrash: false)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(!FileManager.default.fileExists(atPath: avdDirectory))
    #expect(remover.recorded.count == 2)
    #expect(remover.recorded.allSatisfy { !$0.trashed })
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .deleted)
    #expect(entry.trashedTo == nil)
}

@Test func theFallbackFailsRatherThanReportingSuccessWhenNothingIsThere() async throws {
    let temp = TempDir()
    temp.makeDirectory(".android/avd")
    let remover = FakeFileRemover()
    let item = CleanupItem(
        id: "android.avds|ghost", scannerID: "android.avds", group: .android,
        name: "ghost", detail: nil, sizeBytes: 3_000, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteAVD(name: "ghost"))

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.isEmpty)
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason?.contains("no emulator named ghost") == true)
    #expect(record.trashedBytes == 0)
    #expect(record.permanentlyDeletedBytes == 0)
}

// MARK: - Gradle preflight

@Test func stopsGradleDaemonsBeforeTouchingGradleFiles() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/caches/modules-2")
    let runner = RecordingProcessRunner()

    let item = ScanHelpers.item(scannerID: "android.gradle", group: .android,
                                path: target, name: "Downloaded dependencies", sizeBytes: 1)
    _ = await makeExecutor(temp: temp, runner: runner)
        .run(items: [item], devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(runner.recorded.contains { $0.contains("pkill") && $0.contains("GradleDaemon") })
}

@Test func gradleDaemonsAreNotStoppedWhenNoGradleItemIsSelected() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/x")
    let runner = RecordingProcessRunner()
    _ = await makeExecutor(temp: temp, runner: runner)
        .run(items: [pathItem(target)], devices: .empty, startedAt: startedAt, progress: { _ in })
    #expect(!runner.recorded.contains { $0.contains("GradleDaemon") })
}

// MARK: - progress, notes, free space

@Test func reportsProgressForEveryItem() async {
    let temp = TempDir()
    let items = (0..<3).map { pathItem(temp.makeDirectory("allowed/d\($0)"), name: "d\($0)") }

    let collected = Collector()
    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: items, devices: .empty, startedAt: startedAt) { collected.add($0) }

    #expect(collected.values.count == 3)
    #expect(collected.values.last?.completed == 3)
    #expect(collected.values.last?.total == 3)
}

@Test func progressCountsUpAndNamesTheItemItJustFinished() async {
    let temp = TempDir()
    let items = (0..<3).map { pathItem(temp.makeDirectory("allowed/d\($0)"), name: "d\($0)") }

    let collected = Collector()
    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: items, devices: .empty, startedAt: startedAt) { collected.add($0) }

    #expect(collected.values.map(\.completed) == [1, 2, 3])
    #expect(collected.values.map(\.currentName) == ["d0", "d1", "d2"])
}

@Test func notesThatXcodeWasOpenWithoutBlockingTheRun() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let runner = RecordingProcessRunner(responses: [
        "/usr/bin/pgrep -x Xcode": ProcessResult(exitCode: 0, stdout: "4213\n", stderr: ""),
    ])
    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [pathItem(target)], devices: .empty, startedAt: startedAt, progress: { _ in })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(record.notes.contains { $0.contains("Xcode was open") })
}

@Test func noXcodeNoteWhenXcodeIsNotRunning() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(target)], devices: .empty, startedAt: startedAt, progress: { _ in })
    #expect(record.notes.isEmpty)
}

@Test func recordsFreeSpaceBeforeAndAfter() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner())
        .run(items: [pathItem(target)], devices: .empty, startedAt: startedAt, progress: { _ in })
    #expect(record.availableBytesBefore > 0)
    #expect(record.availableBytesAfter > 0)
}

@Test func finishedAtComesFromTheInjectedClockAndStartedAtFromTheCaller() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let finished = Date(timeIntervalSince1970: 1_786_000_042)
    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    now: { finished })
        .run(items: [pathItem(target)], devices: .empty, startedAt: startedAt, progress: { _ in })
    #expect(record.startedAt == startedAt)
    #expect(record.finishedAt == finished)
}

// MARK: - the record's three separate numbers

/// Spec §7.2 rule 7. Trashed bytes, permanently deleted bytes and the measured
/// free-space change are three different things and are never merged.
@Test func theRecordKeepsTrashedAndPermanentlyDeletedBytesApart() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/build")
    let runner = RecordingProcessRunner()
    let simulator = CleanupItem(
        id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone", detail: nil, sizeBytes: 700, lastUsed: nil, risk: .safe,
        protection: nil, method: .deleteSimulator(udid: "AAA"))

    let record = await makeExecutor(temp: temp, runner: runner)
        .run(items: [pathItem(target, name: "build"), simulator], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(record.trashedBytes == 1_000)
    #expect(record.permanentlyDeletedBytes == 700)
    #expect(record.trashedCount == 1)
    #expect(record.deletedCount == 1)
}

@Test func freeSpaceChangeIsMeasuredAfterMinusBeforeAndNeverTheItemSizes() {
    let record = RunRecord(
        startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(5),
        availableBytesBefore: 100, availableBytesAfter: 250,
        entries: [
            RunEntry(itemID: "a", name: "a", target: "/a", sizeBytes: 9_000,
                     outcome: .trashed, trashedTo: "/Users/t/.Trash/a"),
            RunEntry(itemID: "b", name: "b", target: "BBB", sizeBytes: 40, outcome: .deleted),
            RunEntry(itemID: "c", name: "c", target: "/c", sizeBytes: 7, outcome: .failed,
                     reason: "nope"),
            RunEntry(itemID: "d", name: "d", target: "d", sizeBytes: 3, outcome: .skipped,
                     reason: "the emulator is running"),
        ])

    #expect(record.freeSpaceChangeBytes == 150)
    #expect(record.trashedBytes == 9_000)
    #expect(record.permanentlyDeletedBytes == 40)
    #expect(record.trashedCount == 1)
    #expect(record.deletedCount == 1)
    #expect(record.failedCount == 1)
    #expect(record.skippedCount == 1)
}

// MARK: - DeletionMethod.path

/// Carried forward from Task 3, which shipped `DeletionMethod.path` with no test. It
/// feeds `PathGuard`, so a wrong value means the guard guards nothing. Every case.
@Test func deletionMethodPathIsThePathToRemoveAndNilForEveryDeviceCase() {
    #expect(DeletionMethod.removePath("/Users/t/Library/Caches/Yarn").path
        == "/Users/t/Library/Caches/Yarn")
    #expect(DeletionMethod.deleteSimulator(udid: "AAA").path == nil)
    #expect(DeletionMethod.deleteSimulatorRuntime(identifier: "iOS-26-5").path == nil)
    #expect(DeletionMethod.deleteAVD(name: "pixel").path == nil)
}

// MARK: - PathGuard.forRun

/// Every location the committed scanners can emit. A missing root here means the row
/// is refused after the user ticks it and the app silently frees nothing.
private let locationsEveryScannerCanProduce = [
    "Library/Developer/Xcode/DerivedData/Runner-abcdef123456",     // xcode.derivedData
    "Library/Developer/Xcode/Archives/2026-01-04/Runner.xcarchive", // xcode.archives
    "Library/Developer/Xcode/iOS DeviceSupport/18.2 (22C150)",      // xcode.deviceSupport
    "Library/Developer/Xcode/watchOS DeviceSupport/11.2 (22S101)", // xcode.deviceSupport
    "Library/Developer/CoreSimulator/Caches",                       // ios.simulatorCaches
    "Library/Caches/CocoaPods",                                     // other.cocoapods
    "Library/Caches/Yarn",                                          // other.jsPackages
    "Library/Caches/org.swift.swiftpm",                             // other.libraryCaches
    "Library/Caches/Google/AndroidStudio2025.1",                    // other.libraryCaches
    "Library/pnpm/store",                                           // other.jsPackages
    "Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a", // android.systemImages
    "Library/Android/sdk/ndk/28.2.13676358",                        // android.ndk
    ".gradle/caches/modules-2",                                     // android.gradle
    ".gradle/caches/journal-1",                                    // android.gradle
    ".gradle/daemon",                                               // android.gradle
    ".gradle/wrapper/dists/gradle-8.14-all",                        // android.gradle
    ".android/avd/pixel.avd",                                       // android.avds fallback
    ".pub-cache/hosted",                                            // flutter.pubCache
    ".pub-cache/git",                                               // flutter.pubCache
    ".pub-cache/_temp",                                             // flutter.pubCache
    "fvm/versions/3.24.0",                                          // flutter.fvm
    ".fvm/versions/3.10.6",                                         // flutter.fvm
    "fvm/cache.git",                                                // flutter.fvm mirror
    ".fvm/cache.git",                                               // flutter.fvm mirror
    ".npm/_cacache",                                                // other.jsPackages
    ".cocoapods/repos",                                             // other.cocoapods
    ".bun/install/cache",                                           // other.jsPackages
    ".android/cache",                                               // other.localToolCaches
    ".android/build-cache",                                         // other.localToolCaches
    ".dartServer",                                                   // other.localToolCaches
    "dev/sample-project/build",                                             // projects.buildOutput
    "dev/sample-project/ios/Pods",                                          // projects.buildOutput
    "dev/sample-project/.claude/worktrees/feature-sync/build",            // projects.buildOutput
]

@Test func theRunGuardAllowsEveryLocationTheCommittedScannersCanProduce() throws {
    let temp = TempDir()
    for location in locationsEveryScannerCanProduce { temp.makeDirectory(location) }
    let sut = PathGuard.forRun(
        home: temp.path, projectRoots: [temp.path + "/dev"],
        projectPaths: [temp.path + "/dev/sample-project"])

    for location in locationsEveryScannerCanProduce {
        let path = temp.path + "/" + location
        #expect(throws: Never.self, "\(location) must be deletable") {
            _ = try sut.validate(path)
        }
    }
}

/// The other half of the same rule. A root is a licence to delete everything under it,
/// so each of these neighbours — none of which any scanner produces, and several of
/// which are the user's own data — must stay out of reach.
@Test func theRunGuardRefusesTheNeighboursOfThoseLocations() throws {
    let temp = TempDir()
    for location in locationsEveryScannerCanProduce { temp.makeDirectory(location) }
    let neighbours = [
        "Library/Developer",                       // holds Xcode/UserData and CoreSimulator/Devices
        "Library/Developer/Xcode/UserData",        // snippets, breakpoints, key bindings
        "Library/Developer/Xcode/Templates",
        "Library/Android/sdk/platform-tools",      // adb itself
        "Library/Android/sdk/licenses",            // the accepted SDK licences
        // `android.ndk` offers one row per version inside this folder, so the folder is
        // an allowed root — and `validate` refuses a path equal to a root, so "trash the
        // whole NDK" is still not something a run can express.
        "Library/Android/sdk/ndk",
        ".android/adbkey",                         // the ADB private key
        ".android/debug.keystore",                 // debug signing identity
        // `flutter.fvm` offers `~/fvm/cache.git`, and the only directory containing it is
        // `~/fvm`. It is allowed as a single exact path rather than by making `~/fvm` a
        // root, so its home, the global SDK symlink beside it and a name that merely
        // starts the same are all still refused.
        "fvm",
        "fvm/default",
        "fvm/cache.git.bak",
        ".bun/bin",                                // globally installed bun executables
        "Documents",
    ]
    for neighbour in neighbours { temp.makeDirectory(neighbour) }

    let sut = PathGuard.forRun(
        home: temp.path, projectRoots: [temp.path + "/dev"],
        projectPaths: [temp.path + "/dev/sample-project"])

    for neighbour in neighbours {
        let path = temp.path + "/" + neighbour
        #expect(throws: PathGuard.Violation.outsideAllowedRoots(path),
                "\(neighbour) must not be deletable") {
            _ = try sut.validate(path)
        }
    }
}

/// The guard's own last rule, exercised from the side that matters here: every path
/// this app can produce lives under the home directory, so a root that contains the
/// home directory is one settings mistake away — `Settings.projectRoots` is editable
/// and becomes an allowed root verbatim. The home directory itself is never deletable,
/// whatever the roots say. Read-only: `validate` only resolves strings.
@Test func theGuardRefusesTheUsersHomeDirectoryHoweverWideTheRootsAre() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let sut = PathGuard(allowedRoots: ["/"], forbiddenTargets: [])
    #expect(throws: PathGuard.Violation.forbiddenTarget(home)) { _ = try sut.validate(home) }
}

@Test func theRunGuardForbidsBothTheProjectRootsAndEveryProjectInside() throws {
    let temp = TempDir()
    let root = temp.makeDirectory("dev")
    let project = temp.makeDirectory("dev/sample-project")
    let build = temp.makeDirectory("dev/sample-project/build")
    let sut = PathGuard.forRun(home: temp.path, projectRoots: [root], projectPaths: [project])

    #expect(throws: PathGuard.Violation.forbiddenTarget(root)) { _ = try sut.validate(root) }
    #expect(throws: PathGuard.Violation.forbiddenTarget(project)) { _ = try sut.validate(project) }
    // and the build folder inside it is still deletable, so the rule above is refusing
    // these two paths rather than everything.
    #expect(throws: Never.self) { _ = try sut.validate(build) }
}

/// `Settings.projectRoots` becomes an allowed root verbatim, and `SettingsStore.load()`
/// takes a hand-edited `settings.json` without validating it. The home directory as a
/// project root would make everything under it — `~/Documents`, `~/Library/Mail` —
/// deletable, with only "the root itself is forbidden" left standing. The run guard
/// drops it from the allowed side. Read-only: `validate` only resolves strings.
@Test func theRunGuardDoesNotTurnTheHomeDirectoryIntoAnAllowedRoot() throws {
    let temp = TempDir()
    let documents = temp.makeDirectory("Documents")
    let mail = temp.makeDirectory("Library/Mail")
    let sut = PathGuard.forRun(home: temp.path, projectRoots: [temp.path], projectPaths: [])

    #expect(throws: PathGuard.Violation.outsideAllowedRoots(documents)) {
        _ = try sut.validate(documents)
    }
    #expect(throws: PathGuard.Violation.outsideAllowedRoots(mail)) { _ = try sut.validate(mail) }
    // Dropped from the allowed roots, and still a forbidden target — one must not be
    // traded for the other.
    #expect(throws: PathGuard.Violation.forbiddenTarget(temp.path)) {
        _ = try sut.validate(temp.path)
    }
}

/// The same rule for `/`. Nothing is created, deleted or resolved beyond the two real
/// system paths this asks about.
@Test func theRunGuardDoesNotTurnTheRootDirectoryIntoAnAllowedRoot() throws {
    let temp = TempDir()
    let sut = PathGuard.forRun(home: temp.path, projectRoots: ["/"], projectPaths: [])

    #expect(throws: PathGuard.Violation.outsideAllowedRoots("/Applications")) {
        _ = try sut.validate("/Applications")
    }
    #expect(throws: PathGuard.Violation.outsideAllowedRoots("/System/Library")) {
        _ = try sut.validate("/System/Library")
    }
    #expect(throws: PathGuard.Violation.forbiddenTarget("/")) { _ = try sut.validate("/") }
}

/// The same rule for the directory that **contains** home, and for a relative root.
///
/// `/Users` is home's parent and was accepted as an allowed root, which let the guard
/// through to `~/Documents` and `~/Library/Mail` — the exact places the home-directory
/// rule above exists to keep out. A relative root is worse than wide: `PathGuard.init`
/// canonicalises it against the process working directory, so what it allows depends on
/// where the binary was launched from.
@Test func theRunGuardRefusesHomesParentAndARelativeRootAsAllowedRoots() throws {
    let temp = TempDir()
    let documents = temp.makeDirectory("Documents")
    let parent = (temp.path as NSString).deletingLastPathComponent
    let sut = PathGuard.forRun(
        home: temp.path, projectRoots: [parent, ".", "..", "Documents"], projectPaths: [])

    #expect(throws: PathGuard.Violation.outsideAllowedRoots(documents)) {
        _ = try sut.validate(documents)
    }
    // And the roots themselves are still forbidden targets, which is the second,
    // independent statement of the rule.
    #expect(throws: PathGuard.Violation.forbiddenTarget(parent)) { _ = try sut.validate(parent) }
}

/// And the rule takes only those two values away. A real project root listed beside one
/// of them still works, or the fix would be a different bug: every build folder refused.
@Test func aRealProjectRootStillWorksBesideOneThatIsTooWide() throws {
    let temp = TempDir()
    let projectRoot = temp.makeDirectory("dev")
    let build = temp.makeDirectory("dev/sample-project/build")
    let documents = temp.makeDirectory("Documents")
    let sut = PathGuard.forRun(
        home: temp.path, projectRoots: [temp.path, "/", projectRoot],
        projectPaths: [temp.path + "/dev/sample-project"])

    #expect(throws: Never.self) { _ = try sut.validate(build) }
    #expect(throws: PathGuard.Violation.outsideAllowedRoots(documents)) {
        _ = try sut.validate(documents)
    }
}

@Test func theRunGuardFollowsTheAndroidSDKWhenItIsNotInTheDefaultPlace() throws {
    let temp = TempDir()
    let elsewhere = temp.makeDirectory("Android/sdk")
    let image = temp.makeDirectory("Android/sdk/system-images/android-34/google_apis/arm64-v8a")
    temp.makeDirectory("Library/Android/sdk/system-images")

    let sut = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [],
                               androidSDKPath: elsewhere)
    #expect(throws: Never.self) { _ = try sut.validate(image) }
    // and the default location is no longer implied, because the caller named another one
    let defaultImage = temp.makeDirectory(
        "Library/Android/sdk/system-images/android-33/google_apis/x86_64")
    #expect(throws: PathGuard.Violation.outsideAllowedRoots(defaultImage)) {
        _ = try sut.validate(defaultImage)
    }
}

// MARK: - cancellation

/// Answers `true` exactly once — on the first ask after it is armed — and `false` every
/// time after that, so a test can make the flag flicker off again.
///
/// `Counter` cannot express this: once it has counted it answers `true` for the rest of the
/// run, which is exactly the case a non-sticky loop also gets right. Armed by a condition
/// rather than by counting asks, so it does not have to know how many times `run` looks at
/// the flag — a number that changed the moment the preflight gained a check of its own.
private final class FlickeringFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let isArmed: @Sendable () -> Bool

    init(armedBy isArmed: @escaping @Sendable () -> Bool) { self.isArmed = isArmed }

    func ask() -> Bool {
        guard isArmed() else { return false }
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Spec §8.2. Once the user has cancelled, a flag that goes back to `false` must not
/// restart the run: every remaining row stays skipped and stays on disk.
///
/// The flag flickers because a caller can make it flicker — `AppModel` passes the default
/// `Task.isCancelled`, but `isCancelled` is a public parameter and the next caller may hand
/// over a stored `Bool` it also clears. Without the sticky flag the third item here is
/// deleted after the user pressed Cancel.
@Test func aCancelledRunDoesNotRestartWhenTheFlagGoesBackToFalse() async throws {
    let temp = TempDir()
    let first = temp.makeDirectory("allowed/one/build")
    let second = temp.makeDirectory("allowed/two/build")
    let third = temp.makeDirectory("allowed/three/build")
    // True once, on the first ask after an item has been performed — the check before the
    // second item — and false for the rest of the run.
    let performed = Counter()
    let flag = FlickeringFlag(armedBy: { performed.hasCounted })

    let record = await makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), now: { startedAt }
    ).run(
        items: [pathItem(first, name: "one"), pathItem(second, name: "two"),
                pathItem(third, name: "three")],
        devices: .empty, startedAt: startedAt,
        isCancelled: { flag.ask() }, progress: { _ in performed.count() })

    #expect(record.entries.count == 3)
    let last = try #require(record.entries.last)
    #expect(last.outcome == .skipped)
    #expect(last.reason == Executor.cancelledReason)
    #expect(FileManager.default.fileExists(atPath: third))
    // The first item was performed before the cancellation and the second was not.
    #expect(!FileManager.default.fileExists(atPath: first))
    #expect(FileManager.default.fileExists(atPath: second))
}

/// Spec §8.2. A cancelled run stops before the next item, and every item it did not
/// reach is recorded with the reason rather than vanishing from the report.
@Test func aRunCancelledPartWayThroughStopsBeforeTheNextItem() async throws {
    let temp = TempDir()
    let first = temp.makeDirectory("allowed/one/build")
    let second = temp.makeDirectory("allowed/two/build")
    // Answers true only after the first item has been performed, so this pins "stops
    // before the next one" rather than "never starts".
    let performed = Counter()

    let record = await makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), now: { startedAt }
    ).run(
        items: [pathItem(first, name: "one"), pathItem(second, name: "two")],
        devices: .empty, startedAt: startedAt,
        isCancelled: { performed.hasCounted },
        progress: { _ in performed.count() })

    #expect(record.entries.count == 2)
    #expect(record.entries.first?.outcome == .trashed)
    let last = try #require(record.entries.last)
    #expect(last.outcome == .skipped)
    #expect(last.reason == Executor.cancelledReason)
    // Already removed stays removed; not yet reached stays put.
    #expect(!FileManager.default.fileExists(atPath: first))
    #expect(FileManager.default.fileExists(atPath: second))
    #expect(record.notes.contains(Executor.Note.runWasCancelled))
}

@Test func aRunCancelledBeforeItStartsRemovesNothing() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/one/build")
    let runner = RecordingProcessRunner()

    let record = await makeExecutor(
        temp: temp, runner: runner, now: { startedAt }
    ).run(
        items: [pathItem(target, name: "one")], devices: .empty, startedAt: startedAt,
        isCancelled: { true }, progress: { _ in })

    #expect(record.entries.first?.outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: target))
    let removed: Int64 = record.trashedBytes + record.permanentlyDeletedBytes
    #expect(removed == 0)
    // Nothing was even asked. Without this the name overstates the test: the preflight and
    // the Xcode check both shell out before the loop the cancellation check used to sit in.
    #expect(runner.recorded.isEmpty)
}

/// Spec §8.2. Cancel pressed before the run's task got going costs the user nothing —
/// including their Gradle daemons.
///
/// `preflight` runs `pkill -f GradleDaemon` for any `android.gradle` row, and the daemons
/// take a minute of rebuilding to come back. Killing them for a run that then deletes
/// nothing is a cost with no benefit at all.
@Test func aRunCancelledBeforeItStartsDoesNotStopTheGradleDaemons() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/gradle/caches")
    let runner = RecordingProcessRunner()
    let gradle = ScanHelpers.item(
        scannerID: "android.gradle", group: .android, path: target,
        name: "Gradle caches", sizeBytes: 1_000)

    let record = await makeExecutor(temp: temp, runner: runner, now: { startedAt }).run(
        items: [gradle], devices: .empty, startedAt: startedAt,
        isCancelled: { true }, progress: { _ in })

    #expect(runner.recorded.isEmpty)
    #expect(record.entries.first?.outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: target))
}

/// The **default** `isCancelled` is the real `Task.isCancelled`, and this is the only test
/// that says so.
///
/// Every other cancellation test here passes a closure of its own, and the `AppModel` tests
/// run against a fake engine that never reaches this type — so replacing the default with
/// `{ false }`, the exact regression that turns the app's Cancel button into a lie, passes
/// every one of them. This calls `run` with **no** `isCancelled:` argument from a task that
/// has already been cancelled.
///
/// The wait is bounded. An unbounded spin over a condition that never comes true stalls the
/// whole test run instead of failing one test.
@Test func theDefaultCancellationCheckIsTheRunningTaskBeingCancelled() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/one/build")
    let executor = makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), now: { startedAt })

    let handle = Task { () -> RunRecord? in
        let deadline = ContinuousClock.now + .seconds(5)
        while !Task.isCancelled {
            if ContinuousClock.now > deadline { return nil }
            await Task.yield()
        }
        return await executor.run(
            items: [pathItem(target, name: "one")], devices: .empty,
            startedAt: startedAt, progress: { _ in })
    }
    handle.cancel()
    let record = try #require(await handle.value)

    #expect(record.entries.first?.outcome == .skipped)
    #expect(record.entries.first?.reason == Executor.cancelledReason)
    #expect(FileManager.default.fileExists(atPath: target))
    #expect(record.notes.contains(Executor.Note.runWasCancelled))
}

/// The two sentences a cancelled run puts in front of the user, pinned as text.
///
/// Compared to the constants everywhere else, so emptying either one would pass. The row
/// reason is printed by `RunRecord.unfinishedReasons` as "\(name): \(reason)", where an
/// empty string reads as "Yarn: " and says nothing at all.
@Test func theCancellationWordingIsWhatTheUserReads() {
    #expect(Executor.cancelledReason
        == "you cancelled the run before this item, so nothing was attempted for it")
    #expect(Executor.Note.runWasCancelled
        == "You cancelled this run. Everything already removed stays removed; "
            + "the rest was left alone.")
}

/// Spec §8.2. Every row is reported, skipped ones included, so the counter the card
/// shows reaches its total instead of stopping part way with nothing said.
@Test func aCancelledRunKeepsReportingProgressToTheEnd() async throws {
    let temp = TempDir()
    let first = temp.makeDirectory("allowed/one/build")
    let second = temp.makeDirectory("allowed/two/build")
    let seen = Collector()

    _ = await makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), now: { startedAt }
    ).run(
        items: [pathItem(first, name: "one"), pathItem(second, name: "two")],
        devices: .empty, startedAt: startedAt,
        isCancelled: { true }, progress: { seen.add($0) })

    #expect(seen.values.count == 2)
    let last = try #require(seen.values.last)
    #expect(last.completed == 2)
    #expect(last.total == 2)
    #expect(last.currentName == "two")
}

/// A run nobody cancelled must not gain a note about cancellation.
@Test func anOrdinaryRunCarriesNoCancellationNote() async {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/one/build")

    let record = await makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), now: { startedAt }
    ).run(
        items: [pathItem(target, name: "one")], devices: .empty, startedAt: startedAt,
        progress: { _ in })

    #expect(!record.notes.contains(Executor.Note.runWasCancelled))
    #expect(record.entries.first?.outcome == .trashed)
}

/// Small thread-safe sink so the progress closure can stay `@Sendable`.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExecutionProgress] = []
    func add(_ progress: ExecutionProgress) {
        lock.lock(); storage.append(progress); lock.unlock()
    }
    var values: [ExecutionProgress] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

// MARK: - a name the user can see in the Trash

// The user cleaned six projects with the deck, moved 4.4 GB, opened the Trash and saw
// nothing: everything they had cleaned was called `.build`, `.build 12-22-29-584` or
// `.dart_tool`, and Finder hides a dot-name in the Trash exactly as it does everywhere
// else. They concluded the app had deleted the lot. So a project's build folder is renamed
// to "<project> – <folder>" before it goes, and every failure along the way falls back to
// what the executor did before.

/// The path the executor will actually have acted on, assembled from the same pieces the
/// test used to build the folder.
///
/// `PathGuard.validate` hands back a canonical parent, and on macOS a temporary directory
/// is reached through one (`/var` → `/private/var`), so a string built from `temp.path` is
/// never the string the remover was handed. Every path expectation below goes through here.
private func approved(_ temp: TempDir, _ relative: String) -> String {
    // The guard's own canonicaliser, i.e. `realpath`. Not `resolvingSymlinksInPath`, which
    // drops a leading `/private` again and so hands back the string we started with.
    let root = PathGuard.canonicalise(temp.path) ?? temp.path
    return (root as NSString).appendingPathComponent(relative)
}

@Test func aProjectsBuildFolderGoesToTheTrashUnderAVisibleName() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/Photo Tool iOS/.build")
    let remover = FakeFileRemover()

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    // Gone from the project, and handed to the Trash under the visible name.
    #expect(!FileManager.default.fileExists(atPath: target))
    let renamed = approved(
        temp, "allowed/Photo Tool iOS/Photo Tool iOS – .build")
    #expect(!FileManager.default.fileExists(atPath: renamed))
    #expect(remover.recorded.map(\.path) == [renamed])
    // A closure rather than `\.trashed`: `#expect` expands a key-path argument into a
    // throwing call, which then wants a `try` the assertion cannot carry.
    #expect(remover.recorded.allSatisfy { $0.trashed })

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    // The target stays the folder the user cleaned, whatever it was called on the way out:
    // the run log, `AppModel`'s pruning and the row's own identity all key on it.
    #expect(entry.target == approved(temp, "allowed/Photo Tool iOS/.build"))
    // The identity is the row's, unchanged: it is how `AppModel` matches this entry back to
    // the card the user decided about, and the row was made before any of this happened.
    #expect(entry.itemID == "projects.buildOutput|\(target)")
    // And where it landed is the half the user needs, because that is the name they will be
    // reading in the Trash.
    #expect(entry.trashedTo == "/Users/tester/.Trash/Photo Tool iOS – .build")
    #expect(record.trashedBytes == 1_000)
}

/// A folder Finder already shows gets the name too. Five projects' `build` folders in one
/// Trash are five identical things the user cannot tell apart or put back, which is the
/// other half of what the rename is for.
@Test func aFolderFinderAlreadyShowsIsStillNamedAfterItsProject() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/sample_app/build")
    let remover = FakeFileRemover()

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [pathItem(target, name: "build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path)
        == [approved(temp, "allowed/sample_app/sample_app – build")])
}

/// A nested name is renamed **beside the folder**, not at the project root: `ios/Pods`
/// becomes `<project>/ios/sample_app – ios-Pods`. The same directory is what keeps the
/// move a rename rather than a copy across the tree, and the name still carries every
/// component, so `ios/Pods` and `macos/Pods` stay apart in the Trash.
@Test func aNestedFolderIsRenamedBesideItselfRatherThanAtTheProjectRoot() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/sample_app/ios/Pods")
    let remover = FakeFileRemover()

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [pathItem(target, name: "ios/Pods")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path)
        == [approved(temp, "allowed/sample_app/ios/sample_app – ios-Pods")])
    // Nothing was created at the project root.
    #expect(!FileManager.default.fileExists(
        atPath: approved(temp, "allowed/sample_app/sample_app – ios-Pods")))
}

/// Something already at the visible name is never overwritten: the next number is used, the
/// way Finder itself does it. Reachable in practice from a previous run whose trash failed
/// **and** whose rename back failed with it — which is exactly the case where overwriting
/// would destroy the data the user was told how to recover.
@Test func aVisibleNameThatIsTakenIsNumberedRatherThanOverwritten() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/.build")
    let leftover = temp.makeFile("allowed/app/app – .build", contents: "from a failed run")
    let remover = FakeFileRemover()

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path) == [approved(temp, "allowed/app/app – .build 2")])
    // The leftover is untouched, contents and all.
    #expect(try String(contentsOfFile: leftover, encoding: .utf8) == "from a failed run")
}

/// The sibling is built from the path the **guard approved**, not the one the row carried.
///
/// A row can name its folder through a detour — a `..`, or a parent that is a symlink — and
/// `validate` resolves it. Assembling the new name from the row's own string would put the
/// rename somewhere the guard never checked, which is the one thing this whole feature must
/// not buy the user.
@Test func theVisibleNameIsAssembledFromThePathTheGuardApproved() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/caches/build")
    let remover = FakeFileRemover()
    let supplied = temp.path + "/allowed/caches/../caches/build"

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [pathItem(supplied, name: "build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path)
        == [approved(temp, "allowed/caches/caches – build")])
    #expect(try #require(record.entries.first).target
        == approved(temp, "allowed/caches/build"))
    #expect(!FileManager.default.fileExists(atPath: target))
}

/// And the project it is named after is the directory the folder really lives in, not the
/// one the row was reached through.
///
/// A symlinked project — `~/dev/current` pointing at `~/dev/app-v3`, or an `ios` that is a
/// link into a shared checkout — is the case where the two differ. `validate` resolves the
/// parent, so naming the folder off the row's own string would put "current – .build" on a
/// folder that is going to be put back into `app-v3`.
@Test func theVisibleNameIsTheDirectoryTheFolderActuallyLivesIn() async throws {
    let temp = TempDir()
    let project = temp.makeDirectory("allowed/app")
    let target = temp.makeDirectory("allowed/app/.build")
    temp.makeSymlink("allowed/current", to: project)
    let remover = FakeFileRemover()

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [pathItem(temp.path + "/allowed/current/.build", name: ".build")],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path) == [approved(temp, "allowed/app/app – .build")])
    #expect(!FileManager.default.fileExists(atPath: target))
}

/// The sibling is validated in its own right **before** anything moves, and a guard that
/// refuses it means the folder goes under its own name. The rename is cosmetic: it must
/// never be the reason the guard is worked around, and never the reason a clean removes
/// less than it said it would.
@Test func aSiblingTheGuardRefusesFallsBackToTheOriginalNameAndStillTrashes() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/.build")
    let remover = FakeFileRemover()
    // A guard with no allowed root at all and this one path allowed exactly. `PathGuard`'s
    // exact allowances are exact — "never a sibling, never a child, never the parent" — so
    // the row passes and the name it would be renamed to does not. The same happens for
    // real when the project directory is moved away between the two checks.
    let record = await Executor(
        guard: PathGuard(allowedRoots: [], forbiddenTargets: [],
                         allowedExactPaths: [target]),
        runner: RecordingProcessRunner(), remover: remover,
        home: temp.path, moveToTrash: true)
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    let original = approved(temp, "allowed/app/.build")
    #expect(remover.recorded.map(\.path) == [original])
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(entry.target == original)
    #expect(!FileManager.default.fileExists(atPath: target))
}

/// A rename the filesystem refuses costs the user the nicer name and nothing else.
@Test func aRenameTheFilesystemRefusesStillTrashesUnderTheOriginalName() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/.build")
    let remover = FakeFileRemover()

    let record = await makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover,
        fileManager: RenameRefusingFileManager(allowing: 0))
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    let original = approved(temp, "allowed/app/.build")
    #expect(remover.recorded.map(\.path) == [original])
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(entry.target == original)
    #expect(!FileManager.default.fileExists(atPath: target))
}

/// A Trash that refuses **after** a successful rename puts the folder back, so every future
/// scan finds it where it has always been. Without this, a failed clean would quietly cost
/// the user the folder's visibility and gain them no space.
@Test func aTrashThatRefusesAfterTheRenameLeavesTheFolderUnderItsOriginalName() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/.build")
    let marker = temp.makeFile("allowed/app/.build/marker", contents: "still here")
    let remover = TrashRefusingRemover()

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    // It was offered to the Trash under the visible name, and it is back where it started.
    let visible = approved(temp, "allowed/app/app – .build")
    #expect(remover.attempted == [visible])
    #expect(FileManager.default.fileExists(atPath: target))
    #expect(try String(contentsOfFile: marker, encoding: .utf8) == "still here")
    #expect(!FileManager.default.fileExists(atPath: visible))

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.target == approved(temp, "allowed/app/.build"))
    // The Trash's own reason, not the rename's: the rename worked.
    #expect(entry.reason == "the Trash has no room for it")
    #expect(record.trashedBytes == 0)
}

/// Both failing in a row is the one outcome that costs the user something real: gigabytes
/// sit in their project under a name no future scan recognises, so nothing will offer the
/// folder again and nothing will tell them it is there. The reason is the only record, so
/// it says where the folder is and what to call it.
@Test func aRenameThatCannotBeUndoneSaysWhereTheFolderNowIs() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/.build")
    let remover = TrashRefusingRemover()

    let record = await makeExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover,
        // The rename out works; the rename back does not.
        fileManager: RenameRefusingFileManager(allowing: 1))
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    let stranded = approved(temp, "allowed/app/app – .build")
    #expect(FileManager.default.fileExists(atPath: stranded))
    #expect(!FileManager.default.fileExists(atPath: target))

    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.target == approved(temp, "allowed/app/.build"))
    let reason = try #require(entry.reason)
    // The path it is at, and the name to give it back — the whole of what the user needs.
    #expect(reason.contains(stranded))
    #expect(reason.contains("rename it to .build"))
    #expect(reason.contains("the Trash has no room for it"))
    #expect(reason == Executor.couldNotBePutBackReason(
        "the Trash has no room for it", nowAt: stranded, originalName: ".build"))
    // It reads as a clause, because `RunRecord.unfinishedReasons` prints it after a colon.
    #expect(record.unfinishedReasons == [".build: \(reason)"])
}

/// Permanent mode renames nothing. There is no Trash for the user to look in, `remove`
/// takes the path it is given, and a rename would be two syscalls of risk for no reader.
@Test func permanentModeNeverRenamesAnything() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/.build")
    let remover = FakeFileRemover()

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                           remover: remover, moveToTrash: false)
        .run(items: [pathItem(target, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path) == [approved(temp, "allowed/app/.build")])
    #expect(remover.recorded.allSatisfy { !$0.trashed })
    #expect(!FileManager.default.fileExists(
        atPath: approved(temp, "allowed/app/app – .build")))
}

/// Every other scanner's row reaches the Trash exactly as it did before. Those are shared
/// caches inside a tool's own directory — `~/Library/Caches/Yarn`, a simulator runtime, the
/// pub cache — where the folder's name already is the name of the thing and the directory
/// above it is no project to put in front of it.
@Test func rowsFromEveryOtherScannerAreNotRenamed() async throws {
    let temp = TempDir()
    let yarn = temp.makeDirectory("allowed/Caches/Yarn")
    let remover = FakeFileRemover()
    let row = ScanHelpers.item(scannerID: "other.jsPackages", group: .otherCaches,
                               path: yarn, name: "Yarn", sizeBytes: 1_000)

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [row], devices: .empty, startedAt: startedAt, progress: { _ in })

    let original = approved(temp, "allowed/Caches/Yarn")
    #expect(remover.recorded.map(\.path) == [original])
    #expect(try #require(record.entries.first).target == original)
    #expect(!FileManager.default.fileExists(
        atPath: approved(temp, "allowed/Caches/Caches – Yarn")))
}

/// A row whose path does not end in its own name is never renamed, because nothing here
/// knows which project it belongs to and the name must never be a guess.
@Test func aRowWhosePathDoesNotEndInItsNameIsNotRenamed() async throws {
    let temp = TempDir()
    let target = temp.makeDirectory("allowed/app/somewhere-else")
    let remover = FakeFileRemover()

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [pathItem(target, name: "build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path)
        == [approved(temp, "allowed/app/somewhere-else")])
    #expect(try #require(record.entries.first).outcome == .trashed)
}

/// A `build` that is a symlink to another disk must still cost the link and not the disk.
/// `moveItem` renames a link as a link, so what reaches the remover is the link itself —
/// under a visible name — and what it points at is untouched.
@Test func renamingASymlinkedBuildFolderMovesTheLinkAndLeavesItsTargetAlone() async throws {
    let temp = TempDir()
    let elsewhere = temp.makeDirectory("outside/important")
    let kept = temp.makeFile("outside/important/keep.txt", contents: "x")
    let link = temp.makeSymlink("allowed/app/.build", to: elsewhere)
    let remover = FakeFileRemover()

    _ = await makeExecutor(temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [pathItem(link, name: ".build")], devices: .empty,
             startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path) == [approved(temp, "allowed/app/app – .build")])
    #expect(FileManager.default.fileExists(atPath: elsewhere))
    #expect(try String(contentsOfFile: kept, encoding: .utf8) == "x")
}

/// Cancellation is untouched: a cancelled run skips the rest of its list and renames
/// nothing on the way past.
@Test func aCancelledRunRenamesNothingItDidNotReach() async throws {
    let temp = TempDir()
    let first = temp.makeDirectory("allowed/one/.build")
    let second = temp.makeDirectory("allowed/two/.build")
    let remover = FakeFileRemover()
    let counter = Counter()

    let record = await makeExecutor(temp: temp, runner: RecordingProcessRunner(),
                                    remover: remover)
        .run(items: [pathItem(first, name: ".build"), pathItem(second, name: ".build")],
             devices: .empty, startedAt: startedAt,
             isCancelled: { counter.hasCounted },
             progress: { _ in counter.count() })

    #expect(remover.recorded.map(\.path) == [approved(temp, "allowed/one/one – .build")])
    #expect(FileManager.default.fileExists(atPath: second))
    #expect(!FileManager.default.fileExists(
        atPath: approved(temp, "allowed/two/two – .build")))
    #expect(record.entries.map(\.outcome) == [.trashed, .skipped])
}

// MARK: - the user's own files always go to the Trash

/// A row as a big-things scanner builds one: the user's own file, `.irreplaceable`, unticked.
private func bigThingItem(_ path: String, name: String) -> CleanupItem {
    ScanHelpers.item(
        scannerID: DownloadsScanner.scannerID, group: .bigThings, path: path, name: name,
        sizeBytes: 7_000_000_000, risk: .irreplaceable, startsUnticked: true)
}

/// In Trash mode, which is the ordinary case and the easy half.
@Test func aBigThingGoesToTheTrashInTrashMode() async throws {
    let temp = TempDir()
    let target = temp.makeFile("Downloads/Xcode_26.1_beta.xip")
    let remover = FakeFileRemover()

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover, moveToTrash: true)
        .run(items: [bigThingItem(target, name: "Xcode_26.1_beta.xip")],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.trashed) == [true])
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .trashed)
    #expect(entry.isRestorable)
    #expect(record.trashedBytes == 7_000_000_000)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// **And in permanent mode too, which is the whole rule.**
///
/// `moveToTrash` off means "remove outright" for everything a tool can make again. It may
/// not reach one of the user's own files: there would be nothing anywhere to get it back
/// from, and the setting was agreed to about caches. An ordinary cache row in the same run
/// is removed outright, so the test can tell the rule from the setting being ignored.
@Test func aBigThingStillGoesToTheTrashInPermanentMode() async throws {
    let temp = TempDir()
    let download = temp.makeFile("Downloads/Xcode_26.1_beta.xip")
    let cache = temp.makeDirectory(".cache/uv")
    let remover = FakeFileRemover()

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover, moveToTrash: false)
        .run(items: [
                bigThingItem(download, name: "Xcode_26.1_beta.xip"),
                ScanHelpers.item(scannerID: "other.xdgCache", group: .otherCaches,
                                 path: cache, name: "uv", sizeBytes: 1_100_000_000,
                                 risk: .elevated),
             ],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.trashed) == [true, false])
    #expect(record.entries.map(\.outcome) == [.trashed, .deleted])
    #expect(record.trashedBytes == 7_000_000_000)
    #expect(record.permanentlyDeletedBytes == 1_100_000_000)
}

/// If the Trash refuses, the row **fails**. It never falls through to a removal the user
/// never agreed to — that would turn a full `.Trashes` into a permanent deletion of
/// something irreplaceable, in permanent mode, silently.
@Test func aBigThingWhoseTrashFailsFailsRatherThanBeingDeleted() async throws {
    let temp = TempDir()
    let target = temp.makeFile("Downloads/Xcode_26.1_beta.xip")

    let record = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: TrashRefusingRemover(),
        moveToTrash: false)
        .run(items: [bigThingItem(target, name: "Xcode_26.1_beta.xip")],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(FileManager.default.fileExists(atPath: target))
    let entry = try #require(record.entries.first)
    #expect(entry.outcome == .failed)
    #expect(entry.reason == "the Trash has no room for it")
    #expect(record.trashedBytes == 0)
    #expect(record.permanentlyDeletedBytes == 0)
}

/// The visible-name rename must not touch these rows. A download already reads as itself in
/// the Trash, and renaming `Xcode_26.1_beta.xip` to something else would take a file the user
/// recognises and make it unfindable — the exact problem the rename exists to solve, inverted.
@Test func aBigThingIsNeverRenamedOnItsWayToTheTrash() async throws {
    let temp = TempDir()
    let target = temp.makeFile("Downloads/Xcode_26.1_beta.xip")
    let remover = FakeFileRemover()

    _ = await makeRealGuardExecutor(
        temp: temp, runner: RecordingProcessRunner(), remover: remover)
        .run(items: [bigThingItem(target, name: "Xcode_26.1_beta.xip")],
             devices: .empty, startedAt: startedAt, progress: { _ in })

    #expect(remover.recorded.map(\.path) == [approved(temp, "Downloads/Xcode_26.1_beta.xip")])
    #expect(remover.recorded.first.map { !$0.path.contains(ProjectRowPath.separator) } == true)
}

// MARK: - the new locations the run guard admits, and the ones it refuses

/// Every location a committed scanner can name has to be reachable, or the row is refused
/// after the user ticks it and the clean silently frees nothing.
@Test func theRunGuardAdmitsEveryLocationTheNewScannersCanName() async throws {
    let temp = TempDir()
    let xdgChild = temp.makeDirectory(".cache/uv")
    let download = temp.makeFile("Downloads/Docker.dmg")
    let model = temp.makeDirectory(".lmstudio/models/lmstudio-community/Qwen3-30B-GGUF")
    let huggingFace = temp.makeDirectory(
        ".cache/huggingface/hub/models--ml-labs--whisper-large-v3-gguf")
    let ollama = temp.makeDirectory(".ollama/models")

    let guarded = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])
    for path in [xdgChild, download, model, huggingFace, ollama] {
        #expect((try? guarded.validate(path)) != nil, "\(path)")
    }
}

/// **The forty-eight desktop-app cache paths are refused**, and that is the change rather
/// than an oversight.
///
/// They used to be `allowedExactPaths`, generated from `ElectronCacheScanner`'s own list. The
/// scanner is `DeckDealing.mentionOnly` now — no card, and every row `startsUnticked`, so it
/// is absent from `defaultSelection` and therefore from `cleanDefault`, which is the only
/// list `devcleaner clean` and `clean --dry-run` ever build. The CLI cannot tick one row and
/// the menu bar stopped cleaning when it became a status item, so nothing can ask for one of
/// these paths.
///
/// A licence nobody can exercise is not free: each of these sits inside an app folder that
/// also holds `Code/User` — every setting, keybinding and snippet — and `Slack/Cookies`, the
/// reason the user is still signed in. So the licence went and the refusal is now stated
/// twice: outside every root, and a forbidden target one level up.
@Test func theRunGuardRefusesEveryElectronCachePath() async throws {
    let temp = TempDir()
    // Every fixture made **before** the guard, because `PathGuard.init` canonicalises its
    // roots and forbidden targets with `realpath` and silently drops whatever does not
    // exist. A guard built over an empty directory refuses everything for the wrong reason
    // and would pass this test while proving nothing.
    let paths = ElectronCacheScanner.relativeCachePaths.map { temp.makeDirectory($0) }
    let guarded = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])

    #expect(paths.count == 48)
    for (relative, path) in zip(ElectronCacheScanner.relativeCachePaths, paths) {
        #expect((try? guarded.validate(path)) == nil, "\(relative)")
        #expect(PathGuard.runRelativeExactPaths.contains(relative) == false, "\(relative)")
    }
    // The container and the app folders stay forbidden targets all the same. Nothing can
    // reach anything under them now, so this is belt and braces — kept because it is the
    // statement that still refuses them if a root is ever added above one.
    #expect(PathGuard.runRelativeForbiddenTargets.contains(ElectronCacheScanner.container))
    for app in ElectronCacheScanner.relativeAppPaths {
        #expect(PathGuard.runRelativeForbiddenTargets.contains(app), "\(app)")
    }
}

/// `AppCacheScanner` needed no licence removed, and this says why rather than leaving it
/// looking like the Electron half was done and this one forgotten.
///
/// Its rows sit under `Library/Caches`, which `other.cocoapods`, `other.jsPackages` and
/// `other.libraryCaches` all still offer children of — so the root cannot be narrowed, and a
/// browser folder is admitted by it exactly as the other 150 children of that directory are.
/// What keeps them safe is the same thing that keeps `com.apple.mail` safe: no route in the
/// app offers them. The scanner is `.mentionOnly` and its rows are never ticked, which is
/// asserted from the scan's side in `AppCacheScannerTests`.
@Test func theBrowserCachesKeepNoLicenceOfTheirOwnBecauseTheirRootIsSharedWithThreeScanners() {
    #expect(PathGuard.runRelativeRoots.contains("Library/Caches"))
    for relative in ["Library/Caches/BraveSoftware", "Library/Caches/Google/Chrome",
                     "Library/Caches/com.spotify.client"] {
        #expect(PathGuard.runRelativeExactPaths.contains(relative) == false, "\(relative)")
    }
}

/// **Every model store `other.xdgCache` refuses to offer is also a forbidden target**, and
/// that is the half the dictation-app incident turned out to need.
///
/// `~/.cache` is an allowed root — the scanner offers its direct children — so "no scanner
/// names it" was the only thing keeping `~/.cache/huggingface` out of reach, which is
/// precisely the arrangement that let it be offered in the first place. The list is
/// generated from the scanner's own set, so a name added there cannot be left un-forbidden
/// here.
@Test func everyExcludedModelStoreIsAForbiddenTargetOfTheRunGuard() async throws {
    let temp = TempDir()
    // Fixtures first: `PathGuard.init` canonicalises with `realpath` and drops what does
    // not exist, so a guard built before them would have neither the roots nor the
    // forbidden targets this test is about.
    let stores = XDGCacheScanner.excludedChildren.sorted()
        .map { temp.makeDirectory(".cache/\($0)") }
    let containers = [".cache/huggingface", ".cache/huggingface/hub"]
        .map { temp.makeDirectory($0) }
    let model = temp.makeDirectory(".cache/huggingface/hub/models--openai--whisper-large-v3")
    let guarded = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])

    // The containers as well as the stores: `hub` is every model at once and
    // `.cache/huggingface` is the directory the incident was about. Both refused as
    // **targets**, although `hub` is an allowed root and `.cache` is one too — which is the
    // whole point of saying it twice.
    for path in stores + containers {
        #expect(throws: PathGuard.Violation.forbiddenTarget(path)) {
            _ = try guarded.validate(path)
        }
    }
    for name in XDGCacheScanner.excludedChildren {
        #expect(PathGuard.runRelativeForbiddenTargets.contains(".cache/\(name)"), "\(name)")
    }
    // Rule 4: a model *inside* the hub is still admitted, so the refusals above are about
    // the containers and not about the whole tree.
    #expect((try? guarded.validate(model)) != nil)
}

/// **`~/.ollama` is never a root.** It holds `id_ed25519`, the private key Ollama signs
/// registry requests with, and the one row `big.aiModels` offers there is `models` — so the
/// store goes in as an exact path and nothing above or beside it is reachable at all.
@Test func theRunGuardAdmitsTheOllamaStoreWithoutARootOverItsKeys() async throws {
    let temp = TempDir()
    let store = temp.makeDirectory(".ollama/models")
    let key = temp.makeFile(".ollama/id_ed25519")
    let manifest = temp.makeDirectory(".ollama/models/manifests")
    let ollama = temp.path + "/.ollama"

    let guarded = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])

    #expect((try? guarded.validate(store)) != nil)
    // The key, the directory that holds it, and a path inside the store that no scanner
    // names: all outside every root, because there is no root anywhere near here.
    for path in [key, ollama, manifest] {
        #expect((try? guarded.validate(path)) == nil, "\(path)")
    }
    // Stated in the source as an absence, so a reader who cannot see why the root is
    // missing does not add one.
    #expect(PathGuard.runRelativeRoots.contains(PathGuard.ollamaIsNeverARoot) == false)
    #expect(PathGuard.runRelativeForbiddenTargets.contains(PathGuard.ollamaIsNeverARoot))
    #expect(PathGuard.runRelativeExactPaths.contains(".ollama/models"))
    // And the store must **not** be a forbidden target, because forbidden is checked before
    // the exact list — a stray entry there would refuse the one row that is offered.
    #expect(PathGuard.runRelativeForbiddenTargets.contains(".ollama/models") == false)
}

/// The containers and their neighbours are refused, and each of them for a reason worth
/// stating: every tool cache at once, the whole Downloads folder, every downloaded model, an
/// editor's settings, a chat app's signed-in session — or, if a root were ever widened by one
/// component, `~/Desktop` and `~/Pictures` beside it.
@Test func theRunGuardRefusesTheContainersAndNeighboursOfTheNewLocations() async throws {
    let temp = TempDir()
    let containers = [
        ".cache", "Downloads", ".lmstudio", ".lmstudio/models",
        "Library/Application Support",
        "Library/Application Support/Code",
        "Library/Application Support/Code/User",
        "Library/Application Support/Slack",
        "Library/Application Support/Slack/Cookies",
        "Library/Application Support/Slack/storage",
        // An app the allowlist does not name at all: outside every root and every exact
        // path, so even its cache subfolder is refused.
        "Library/Application Support/Telegram Desktop/Cache",
        // `~/Downloads` is a root now, and these are its **siblings**. Making the home
        // directory a root by accident is the failure that would admit all of them, and
        // three of the four hold things no clean could ever justify losing.
        "Desktop", "Documents", "Pictures", "Movies",
        // LM Studio's own configuration, beside the `models` folder that is the root.
        ".lmstudio/config",
    ].map { temp.makeDirectory($0) }

    let guarded = PathGuard.forRun(home: temp.path, projectRoots: [], projectPaths: [])
    for path in containers {
        #expect((try? guarded.validate(path)) == nil, "\(path)")
    }
}

/// The forbidden list is a **second** statement of the containers, independent of the roots.
/// `validate` already refuses a path equal to a root, and the exact-path list already leaves
/// an app folder outside every root; this is the rule that still holds if somebody later
/// widens a root by one component or decides a per-app root would be tidier.
@Test func theContainersAreForbiddenTargetsAsWellAsNotBeingAdmitted() async throws {
    let temp = TempDir()
    let downloads = temp.makeDirectory("Downloads")
    let cache = temp.makeDirectory(".cache")
    let appFolder = temp.makeDirectory("Library/Application Support/Code")

    // A guard whose allowed roots are deliberately too wide — the home directory itself —
    // so the only thing that can refuse these is the forbidden set.
    let guarded = PathGuard(
        allowedRoots: [temp.path],
        forbiddenTargets: PathGuard.runRelativeForbiddenTargets.map {
            (temp.path as NSString).appendingPathComponent($0)
        })

    for path in [downloads, cache, appFolder] {
        #expect(throws: PathGuard.Violation.forbiddenTarget(path)) {
            _ = try guarded.validate(path)
        }
    }
    #expect(PathGuard.runRelativeForbiddenTargets.contains("Downloads"))
    #expect(PathGuard.runRelativeForbiddenTargets.contains(".cache"))
    #expect(PathGuard.runRelativeForbiddenTargets.contains(".lmstudio/models"))
    #expect(PathGuard.runRelativeForbiddenTargets
        .contains("Library/Application Support/Code"))
}

/// The exact-path list is now exactly six entries, and each one is a path whose **parent**
/// holds something no clean could justify losing: `~/fvm/default`, `~/.android/adbkey`,
/// `~/.ollama/id_ed25519`.
///
/// Read as a whole rather than as a set of `contains` checks, so a path added to it has to
/// be noticed here — which is the point of the list being short.
@Test func theRunGuardsExactPathsAreTheSixWhoseParentsMustStayOutOfReach() {
    #expect(PathGuard.runRelativeExactPaths == [
        "fvm/cache.git", ".fvm/cache.git",
        ".android/cache", ".android/build-cache",
        ".dartServer",
        ".ollama/models",
    ])
    // Generated from the scanner's own constant rather than typed, so the guard and
    // `big.aiModels` cannot name two different Ollama stores.
    #expect(PathGuard.runRelativeExactPaths.contains(AIModelScanner.ollamaRelativeRoot))
}
