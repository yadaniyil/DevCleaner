import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

/// The pinned clock every test in this target uses. Production code never reads the wall
/// clock; tests never let it.
let now = Date(timeIntervalSince1970: 1_786_000_000)

/// A throwaway directory that deletes itself when the test ends. Same shape as the one in
/// `CleanerCoreTests`; the two test targets are separate modules and cannot share it.
final class TempDir: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devcleaner-ui-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var path: String { url.path }

    @discardableResult
    func write(_ relative: String, _ contents: String) -> URL {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    @discardableResult
    func makeDirectory(_ relative: String) -> String {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target.path
    }
}

/// A row, with everything defaulted so a test names only what it is about.
func makeItem(
    id: String, scannerID: String = "other.libraryCaches", group: GroupID = .otherCaches,
    name: String = "row", detail: String? = nil, sizeBytes: Int64 = 1_000_000_000,
    lastUsed: Date? = nil, risk: RiskLevel = .safe, protection: ProtectionReason? = nil,
    method: DeletionMethod? = nil, startsUnticked: Bool = false, sizeMayBeShared: Bool = false
) -> CleanupItem {
    CleanupItem(
        id: id, scannerID: scannerID, group: group, name: name, detail: detail,
        sizeBytes: sizeBytes, lastUsed: lastUsed, risk: risk, protection: protection,
        method: method ?? .removePath("/tmp/\(id)"),
        startsUnticked: startsUnticked, sizeMayBeShared: sizeMayBeShared)
}

func makeResult(
    _ items: [CleanupItem], generatedAt: Date = now, availableBytes: Int64 = 219_000_000_000,
    skipped: [String] = [], ignoredRoots: [String] = []
) -> ScanResult {
    ScanResult(
        items: items, generatedAt: generatedAt, availableBytes: availableBytes,
        skippedScannerIDs: skipped, ignoredProjectRoots: ignoredRoots)
}

// MARK: - stubs for the three injectable ports of CleanerCore

/// Refuses every command, the way a machine with no `adb` and no `xcrun` would.
struct StubRunner: ProcessRunner {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        ProcessResult(exitCode: 127, stdout: "", stderr: "no stub for \(executable)")
    }
}

/// Deletes nothing. No test in this target may remove anything real.
struct StubRemover: FileRemoving {
    func trash(_ path: String) throws -> String { path + " (Trash)" }
    func remove(_ path: String) throws {}
}

/// Measures nothing, which is how `du` failing looks to a scanner.
struct StubMeasurer: SizeMeasuring {
    func sizes(of paths: [String]) async -> [String: Int64] { [:] }
}

/// A real `CleanerService` wired entirely to stubs, over a temporary home.
///
/// Real, not faked, because the one thing Task 1 has to prove about `LiveCleanerEngine` is
/// where its work runs, and a fake would run wherever the fake felt like.
func makeLiveEngine(temp: TempDir) -> LiveCleanerEngine {
    let store = SettingsStore(directory: temp.url, home: temp.path)
    let runLog = RunLog(directory: temp.url.appendingPathComponent("runs"))
    let service = CleanerService(
        settingsStore: store, runLog: runLog,
        runner: StubRunner(), remover: StubRemover(), sizeMeasurer: StubMeasurer(),
        fileManager: .default, home: temp.path,
        androidSDKPath: temp.path + "/Library/Android/sdk",
        clock: { now })
    return LiveCleanerEngine(service: service, runLog: runLog)
}

/// Records, from inside a **synchronous** callback, whether it **ever** ran on the main
/// thread.
///
/// Ever, not last. A scan fires progress once per scanner, and the failure this witness
/// exists to catch is a main-thread *synchronous prefix* — under the Swift 7 default,
/// `CleanerService.scan` spends about 29 seconds in a per-project `git log` loop before it
/// ever suspends. If that prefix ran on the main thread and the later callbacks arrived from
/// the concurrent pool, a last-writer field records `false` and the test passes while the
/// popover was frozen for half a minute. Accumulating costs nothing and cannot miss it.
///
/// A class with a lock rather than an `actor`: the progress callback is not `async`, so it
/// cannot await anything. The standing rule is that `NSLock` is unavailable from async
/// contexts; this is the sync side of that boundary, which is exactly where it is allowed.
///
/// `pthread_main_np()` rather than `Thread.isMainThread`, which is annotated
/// `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` and will not compile in the async tests that follow.
final class ThreadWitness: @unchecked Sendable {
    private let lock = NSLock()
    /// `nil` until the first callback: never notified at all is a different answer from
    /// notified and never on the main thread, and a test that cannot tell them apart passes
    /// when the callback was silently dropped.
    private var sawMainThread: Bool?

    func note() {
        let isMain = pthread_main_np() != 0
        lock.lock(); sawMainThread = (sawMainThread ?? false) || isMain; lock.unlock()
    }

    /// Named for what it now means. `ranOnMainThread` read as "the last one did", which is
    /// the reading that let the accumulate bug sit here unnoticed.
    var everRanOnMainThread: Bool? {
        lock.lock(); defer { lock.unlock() }
        return sawMainThread
    }
}
