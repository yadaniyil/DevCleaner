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
    method: DeletionMethod? = nil, startsUnticked: Bool = false, sizeMayBeShared: Bool = false,
    untickedReason: ProtectionReason? = nil
) -> CleanupItem {
    CleanupItem(
        id: id, scannerID: scannerID, group: group, name: name, detail: detail,
        sizeBytes: sizeBytes, lastUsed: lastUsed, risk: risk, protection: protection,
        method: method ?? .removePath("/tmp/\(id)"),
        startsUnticked: startsUnticked, sizeMayBeShared: sizeMayBeShared,
        untickedReason: untickedReason)
}

func makeResult(
    _ items: [CleanupItem], generatedAt: Date = now, availableBytes: Int64 = 219_000_000_000,
    skipped: [String] = [], ignoredRoots: [String] = []
) -> ScanResult {
    ScanResult(
        items: items, generatedAt: generatedAt, availableBytes: availableBytes,
        skippedScannerIDs: skipped, ignoredProjectRoots: ignoredRoots)
}

// MARK: - rows shaped the way the project scanner really shapes them

/// The home every deck fixture is built under, and the one to hand `AppModel`.
///
/// The deck abbreviates paths against it and recovers each project's directory out of the
/// row's path, so a model built with a different home would produce cards whose paths and
/// identities do not match their fixtures.
let testHome = "/Users/test"

/// A row exactly as `ProjectBuildOutputScanner` builds one: the path is the project
/// directory plus the relative folder, the name **is** that relative folder, and the detail
/// is the project's name.
///
/// Shared rather than written per test file, because that construction is the contract the
/// deck reads backwards to group rows by project. A fixture that did not honour it would
/// test nothing — every row would be dropped as a suffix mismatch and every assertion
/// about an empty deck would pass.
func folderRow(
    project: String, folder: String, sizeBytes: Int64,
    projectName: String? = nil, risk: RiskLevel = .safe,
    lastUsed: Date? = nil, startsUnticked: Bool = false,
    untickedReason: ProtectionReason? = nil,
    scannerID: String = "projects.buildOutput"
) -> CleanupItem {
    let path = "\(testHome)/dev/\(project)/\(folder)"
    // The scanner appends the reason to the detail when one is holding the row back, and
    // the deck reads its own card name out of the path rather than out of this — so a
    // fixture that left the detail plain would hide exactly that bug.
    let detail = untickedReason
        .map { "\(projectName ?? project) · \($0.description)" }
        ?? (projectName ?? project)
    return CleanupItem(
        id: "\(scannerID)|\(path)", scannerID: scannerID, group: .projects,
        name: folder, detail: detail, sizeBytes: sizeBytes,
        lastUsed: lastUsed, risk: risk, protection: nil, method: .removePath(path),
        startsUnticked: startsUnticked || untickedReason != nil,
        untickedReason: untickedReason)
}

/// A row exactly as one of the **other** scanners builds one: a path somewhere under the
/// home the deck abbreviates against, the tool's own name, and the scanner's own sentence
/// about how it comes back.
///
/// `relativePath` rather than a full path, so a fixture cannot accidentally sit outside
/// `testHome` and make the card's location line read as an absolute path.
func toolRow(
    scanner: String = "xcode.derivedData", group: GroupID = .xcodeAndIOS,
    name: String, relativePath: String, sizeBytes: Int64,
    detail: String? = nil, risk: RiskLevel = .safe,
    protection: ProtectionReason? = nil, startsUnticked: Bool = false
) -> CleanupItem {
    let path = "\(testHome)/\(relativePath)"
    return CleanupItem(
        id: "\(scanner)|\(path)", scannerID: scanner, group: group, name: name,
        detail: detail, sizeBytes: sizeBytes, lastUsed: nil, risk: risk,
        protection: protection, method: .removePath(path),
        startsUnticked: startsUnticked)
}

/// A row as one of the **per-item** scanners builds one: `other.xdgCache`.
///
/// A separate helper from `toolRow` because the thing the deck does with it is different —
/// one card per row rather than one card for the scanner — and the property that decides
/// that is the scanner's identifier, which a fixture must therefore get right.
///
/// The detail and the tick both come off the name through the scanner's **own** table, the
/// way the real scanner derives them: a folder it can name gets that tool's sentence and
/// starts ticked, and a folder it cannot gets the generic sentence and starts unticked. A
/// fixture that hard-coded either would be testing the wrong card — the whole difference the
/// deck draws between `~/.cache/uv` and `~/.cache/nimbus` is read back out of these two.
func xdgCacheRow(
    name: String, sizeBytes: Int64, detail: String? = nil, lastUsed: Date? = nil
) -> CleanupItem {
    let path = "\(testHome)/.cache/\(name)"
    return CleanupItem(
        id: "other.xdgCache|\(path)", scannerID: "other.xdgCache", group: .otherCaches,
        name: name, detail: detail ?? XDGCacheScanner.detail(forChildNamed: name),
        sizeBytes: sizeBytes, lastUsed: lastUsed, risk: .elevated, protection: nil,
        method: .removePath(path),
        startsUnticked: !XDGCacheScanner.knows(childNamed: name))
}

/// A row as `other.appCaches` builds one, and `other.electronCaches`.
///
/// Both are `DeckDealing.mentionOnly`, and both properties that makes true have to be in the
/// fixture: the scanner identifier, which is how the deck looks the dealing up, and
/// `startsUnticked`, which is what actually keeps the row out of every clean. A fixture
/// missing either would quietly test an ordinary cache card.
func appCacheRow(name: String, relativePath: String, sizeBytes: Int64) -> CleanupItem {
    let path = "\(testHome)/\(relativePath)"
    return CleanupItem(
        id: "other.appCaches|\(path)", scannerID: "other.appCaches", group: .otherCaches,
        name: name, detail: "the browser rebuilds it as you browse",
        sizeBytes: sizeBytes, lastUsed: nil, risk: .safe, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// The name is `"<App> – <subfolder>"`, built from the scanner's own separator, because that
/// is the construction `ProjectDeck.moreToGain` reads backwards to sum six of Slack's rows
/// into one line.
func electronCacheRow(app: String, folder: String, sizeBytes: Int64) -> CleanupItem {
    let path = "\(testHome)/\(ElectronCacheScanner.container)/\(app)/\(folder)"
    return CleanupItem(
        id: "other.electronCaches|\(path)", scannerID: "other.electronCaches",
        group: .otherCaches, name: app + ProjectRowPath.separator + folder,
        detail: ElectronCacheScanner.detail(app: app),
        sizeBytes: sizeBytes, lastUsed: nil, risk: .safe, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// A Hugging Face model row, as `big.aiModels` builds one: the path is the hub's
/// `models--<org>--<name>` directory and the name is that spelling undone.
///
/// Its own helper rather than a parameter on `modelRow`, because the two differ in the only
/// thing the incident was about — where the model lives and what the card calls it — and a
/// fixture that shared a path shape could not tell them apart.
func huggingFaceModelRow(
    org: String, model: String, sizeBytes: Int64, lastUsed: Date? = nil
) -> CleanupItem {
    let path = "\(testHome)/\(AIModelScanner.huggingFaceRelativeRoot)"
        + "/\(AIModelScanner.huggingFaceModelPrefix)\(org)--\(model)"
    return CleanupItem(
        id: "big.aiModels|\(path)", scannerID: "big.aiModels", group: .bigThings,
        name: "\(org)/\(model)", detail: AIModelScanner.huggingFaceDetail,
        sizeBytes: sizeBytes, lastUsed: lastUsed, risk: .irreplaceable, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// The one row `big.aiModels` offers for Ollama: the whole store, because its blobs are
/// shared between models and no per-model row could claim an honest size.
func ollamaRow(sizeBytes: Int64) -> CleanupItem {
    let path = "\(testHome)/\(AIModelScanner.ollamaRelativeRoot)"
    return CleanupItem(
        id: "big.aiModels|\(path)", scannerID: "big.aiModels", group: .bigThings,
        name: AIModelScanner.ollamaName, detail: AIModelScanner.ollamaDetail,
        sizeBytes: sizeBytes, lastUsed: nil, risk: .irreplaceable, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// A row as `big.downloads` builds one: one of the user's own files, `.irreplaceable`, and
/// never ticked.
///
/// Those three together are what the whole second half of the deck is built on, so a fixture
/// that dropped any of them would quietly test an ordinary per-item card instead.
func downloadRow(
    name: String, sizeBytes: Int64,
    detail: String = DownloadsScanner.installerDetail, lastUsed: Date? = nil
) -> CleanupItem {
    let path = "\(testHome)/Downloads/\(name)"
    return CleanupItem(
        id: "big.downloads|\(path)", scannerID: "big.downloads", group: .bigThings,
        name: name, detail: detail, sizeBytes: sizeBytes, lastUsed: lastUsed,
        risk: .irreplaceable, protection: nil, method: .removePath(path),
        startsUnticked: true)
}

/// The same, for `big.aiModels`, whose rows are named `<publisher>/<model>`.
func modelRow(
    publisher: String, model: String, sizeBytes: Int64, lastUsed: Date? = nil
) -> CleanupItem {
    let path = "\(testHome)/.lmstudio/models/\(publisher)/\(model)"
    return CleanupItem(
        id: "big.aiModels|\(path)", scannerID: "big.aiModels", group: .bigThings,
        name: "\(publisher)/\(model)", detail: AIModelScanner.detail,
        sizeBytes: sizeBytes, lastUsed: lastUsed, risk: .irreplaceable, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// A row as `big.largeFiles` builds one: one of the user's own files, found anywhere under
/// home, on its way to the deck's checklist page.
///
/// Every property here is part of the contract that page is built against, and each one is
/// load-bearing:
///
/// - `.bigThings` and `.irreplaceable` are what put the card behind the interstitial, take
///   its Return key away, paint it amber and make its wording name the Trash whatever the
///   Trash setting says. The deck reads **either** of them — see `ProjectCard.init(scanner:…)`
///   — so a fixture giving only one would hide the other reading.
/// - `startsUnticked` is what keeps the row out of every default route. The boxes the user
///   sees are the page's own.
/// - The **name is the file's**, which two rows can share: `scan.pdf` in two projects is the
///   case the row's `detail` exists for, and the reason identity is the identifier.
/// - The **detail is the `~`-abbreviated parent folder**, through `ReportText` exactly as the
///   scanner writes it, because that is the line on the row that tells those two apart.
/// - `lastUsed` is the file's modification date. `nil` is a file whose date could not be read.
///
/// `folder` is relative to `testHome`, so a fixture cannot accidentally sit outside the home
/// the page abbreviates against and read as an absolute path.
func largeFileRow(
    name: String, folder: String, sizeBytes: Int64, lastUsed: Date? = nil
) -> CleanupItem {
    let path = "\(testHome)/\(folder)/\(name)"
    return CleanupItem(
        id: "\(LargeFilesScanner.scannerID)|\(path)",
        scannerID: LargeFilesScanner.scannerID, group: .bigThings,
        name: name, detail: ReportText(home: testHome).abbreviate("\(testHome)/\(folder)"),
        sizeBytes: sizeBytes, lastUsed: lastUsed, risk: .irreplaceable, protection: nil,
        method: .removePath(path), startsUnticked: true)
}

/// A device support row, as `DeviceSupportScanner` builds one. `protection` is what makes it
/// the folder Xcode is using now, and a kept row must never reach `ProjectCard.items`.
func deviceSupportRow(
    name: String, sizeBytes: Int64, isKept: Bool = false
) -> CleanupItem {
    let path = "\(testHome)/Library/Developer/Xcode/iOS DeviceSupport/\(name)"
    return CleanupItem(
        id: "xcode.deviceSupport|\(path)", scannerID: "xcode.deviceSupport",
        group: .xcodeAndIOS, name: "iOS \(name)",
        detail: isKept
            ? DeviceSupportScanner.keptDetail(model: "iPhone17,2")
            : DeviceSupportScanner.offeredDetail(platform: "iOS", model: "iPhone17,2"),
        sizeBytes: sizeBytes, lastUsed: nil, risk: .elevated,
        protection: isKept ? .newestDeviceSupport : nil, method: .removePath(path))
}

/// A simulator row, as `SimulatorDevicesScanner` builds one: **no path**, because `simctl
/// delete` is the deletion and there is no file for the guard to check or the Trash to hold.
///
/// That one property is what the deck reads to decide a card cannot be undone, so a fixture
/// that gave these a path would quietly test the ordinary card instead of the dangerous one.
func simulatorRow(
    name: String, udid: String, sizeBytes: Int64,
    detail: String? = SimulatorDevicesScanner.offeredDetail,
    protection: ProtectionReason? = nil
) -> CleanupItem {
    CleanupItem(
        id: "ios.simulators|\(udid)", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: name, detail: detail, sizeBytes: sizeBytes, lastUsed: nil, risk: .elevated,
        protection: protection, method: .deleteSimulator(udid: udid))
}

/// A simulator runtime row: permanent like a simulator, and a several-gigabyte download from
/// Apple to get back.
func runtimeRow(
    name: String, identifier: String, sizeBytes: Int64,
    protection: ProtectionReason? = nil
) -> CleanupItem {
    CleanupItem(
        id: "ios.runtimes|\(identifier)", scannerID: "ios.runtimes", group: .xcodeAndIOS,
        name: name, detail: SimulatorRuntimesScanner.offeredDetail, sizeBytes: sizeBytes,
        lastUsed: nil, risk: .elevated, protection: protection,
        method: .deleteSimulatorRuntime(identifier: identifier))
}

/// The summary row `ProjectBuildOutputScanner` gives a protected project: named after the
/// project, carrying everything it holds, and pointed at the project's own directory.
///
/// Pinned by default, because that is the only reason the scanner still withholds a whole
/// project. `.recentActivity` now produces per-folder rows that are offered unticked, and a
/// protected row carrying it can only reach the app out of a `cache.json` written by an
/// older build — which one test here covers deliberately.
func protectedProjectRow(
    project: String, sizeBytes: Int64, reason: ProtectionReason = .pinnedProject
) -> CleanupItem {
    let path = "\(testHome)/dev/\(project)"
    return CleanupItem(
        id: "projects.buildOutput|\(path)", scannerID: "projects.buildOutput",
        group: .projects, name: project, detail: reason.description, sizeBytes: sizeBytes,
        lastUsed: nil, risk: .safe, protection: reason, method: .removePath(path))
}

// MARK: - waiting for the model's own tasks

/// Spins until `condition` holds and gives up after five seconds, answering whether it held.
///
/// Bounded, and the answer asserted at every call site. swift-testing has no per-test time
/// limit here, so an unbounded `while … { await Task.yield() }` over a condition that never
/// comes true stalls the **whole** run: no failure message, no test named, and every other
/// test loses its result. That is the same reason this package bans `[0]` subscripting.
/// Five seconds is far more than any of these tests needs — every wait here is on a fake
/// that answers immediately — and short enough that a wedged test still reports.
///
/// Here rather than in `AppModelTests.swift` because two files now drive the same model
/// through its own unstructured tasks, and a second copy of a bound is a second bound to
/// keep in step.
@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
    }
    return true
}

/// The same five-second bound, for a condition that has to `await` — an actor's state, say.
///
/// A separate name rather than an overload: `waitUntil { … }` with a body that happens to be
/// async would bind to whichever overload the compiler picked, and picking the synchronous
/// one silently drops the wait.
@MainActor
func waitUntilAwaiting(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
    }
    return true
}

@MainActor
func waitUntilIdle(_ model: AppModel) async -> Bool {
    await waitUntil { !model.isBusy }
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
/// app was frozen for half a minute. Accumulating costs nothing and cannot miss it.
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
