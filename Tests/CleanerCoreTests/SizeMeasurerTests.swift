import Testing
import Foundation
@testable import CleanerCore

// The expected byte counts are written as `Int64(kilobytes * 1_024)` on purpose.
//
// `#expect` expands to `__checkBinaryOperation`, which types its two operands
// with independent generic parameters. An untyped arithmetic expression such as
// `2_048 * 1_024` therefore resolves on its own and defaults to `Int`, so
// comparing it against an `Int64?` picks the `AnyHashable ==` overload. Inside
// that thunk the optional is not unwrapped, so the boxes hold `Optional<Int64>`
// and `Int`. Different base types compare false for any numbers, even when both
// sides print the same digits, which makes the assertion silently useless.
//
// Scope of the trap, so nobody has to rediscover it:
//   - Any arithmetic counts, sums as well as products.
//   - Any optional left side, not just a dictionary subscript.
//   - A bare literal such as `1_024` is fine; it still takes `Int64` from context.
//   - `!=`, `<` and `>` are fine; only `==` has the `AnyHashable` overload.
//   - Written by hand outside the macro the same comparison is true, because
//     hand-written erasure does unwrap the optional and NSNumber bridging makes
//     `AnyHashable(Int64) == AnyHashable(Int)` hold. Only the macro form breaks.

@Test func parsesDiskUsageOutput() async {
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/du -sk /a": ProcessResult(exitCode: 0, stdout: "2048\t/a\n", stderr: ""),
        "/usr/bin/du -sk /b": ProcessResult(exitCode: 0, stdout: "1\t/b\n", stderr: ""),
    ])
    let sizes = await DiskUsageMeasurer(runner: runner).sizes(of: ["/a", "/b"])
    #expect(sizes["/a"] == Int64(2_048 * 1_024))
    #expect(sizes["/b"] == 1_024)
}

@Test func toleratesPermissionErrorsInStderr() async {
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/du -sk /a": ProcessResult(
            exitCode: 1, stdout: "512\t/a\n", stderr: "du: /a/private: Permission denied\n"),
    ])
    // du exits non-zero when it could not read some children, but the total it
    // did compute is still useful, so it must not be discarded.
    let sizes = await DiskUsageMeasurer(runner: runner).sizes(of: ["/a"])
    #expect(sizes["/a"] == Int64(512 * 1_024))
}

/// A path `du` produced no number for is **left out of the result**, not reported as 0.
///
/// Zero already means something: `ios.simulatorCaches` is a genuine 0-byte row on this
/// machine and it is ticked. So a failure reported as 0 is indistinguishable from an empty
/// directory, and the row goes into a default clean with its size unknown. The only
/// simulator runtime here sits on a separate volume and is 17 GB — exactly the row that
/// would have been offered as "0 KB" beside a tick box.
@Test func aPathDuCouldNotMeasureIsAbsentRatherThanZero() async {
    let runner = FakeProcessRunner(responses: [
        // du said nothing usable at all.
        "/usr/bin/du -sk /gone": ProcessResult(
            exitCode: 1, stdout: "", stderr: "du: /gone: No such file or directory\n"),
        // du printed something with no number in the first field.
        "/usr/bin/du -sk /odd": ProcessResult(
            exitCode: 0, stdout: "du: cannot access\t/odd\n", stderr: ""),
        // The control: a real, genuinely empty directory measures as 0 and is present.
        "/usr/bin/du -sk /empty": ProcessResult(exitCode: 0, stdout: "0\t/empty\n", stderr: ""),
    ])
    let sizes = await DiskUsageMeasurer(runner: runner).sizes(of: ["/gone", "/odd", "/empty"])

    #expect(sizes["/gone"] == nil)
    #expect(sizes["/odd"] == nil)
    // Present, and zero. The over-fix guard: a measurer that dropped everything would
    // satisfy the two assertions above and leave the whole tool unable to tick anything.
    #expect(sizes.keys.contains("/empty"))
    #expect(sizes["/empty"] == 0)
}

/// The scanner-side half of the rule above: an unmeasured row is shown with its target
/// and left unticked, and a measured one is ticked as before.
@Test func anUnmeasuredRowIsOfferedUntickedAndAMeasuredZeroIsStillTicked() {
    let unmeasured = ScanHelpers.measured([:], "/gone")
    #expect(unmeasured.bytes == 0)
    #expect(unmeasured.unmeasured)

    let empty = ScanHelpers.measured(["/empty": 0], "/empty")
    #expect(empty.bytes == 0)
    #expect(!empty.unmeasured)

    let real = ScanHelpers.measured(["/big": 17_000_000_000], "/big")
    #expect(real.bytes == 17_000_000_000)
    #expect(!real.unmeasured)
}

@Test func measuresEveryRequestedPath() async {
    var responses: [String: ProcessResult] = [:]
    let paths = (0..<20).map { "/p\($0)" }
    for (index, path) in paths.enumerated() {
        responses["/usr/bin/du -sk \(path)"] =
            ProcessResult(exitCode: 0, stdout: "\(index + 1)\t\(path)\n", stderr: "")
    }
    let sizes = await DiskUsageMeasurer(runner: FakeProcessRunner(responses: responses))
        .sizes(of: paths)
    #expect(sizes.count == 20)
    #expect(sizes["/p19"] == Int64(20 * 1_024))
}

@Test func emptyInputReturnsEmptyResult() async {
    let sizes = await DiskUsageMeasurer(runner: FakeProcessRunner(responses: [:])).sizes(of: [])
    #expect(sizes.isEmpty)
}

/// The other way `du` can fail to answer: the process cannot be started at all, so
/// `run` throws rather than returning a bad result. `FakeProcessRunner` never throws, so
/// that branch of `measure` has no other way to be reached from a test — and it is the
/// branch a machine with a broken `/usr/bin/du` or a sandbox denial actually takes.
private struct ThrowingProcessRunner: ProcessRunner {
    struct Failure: Error {}
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        throw Failure()
    }
}

@Test func aPathWhoseDuCouldNotBeStartedIsAbsentRatherThanZero() async {
    let sizes = await DiskUsageMeasurer(runner: ThrowingProcessRunner()).sizes(of: ["/a", "/b"])
    #expect(sizes.isEmpty)
    #expect(sizes["/a"] == nil)
}

/// Records how many measurements were ever running at the same time.
///
/// Lives here rather than in `Doubles.swift` because only this file needs it.
/// Each call holds its slot for a couple of milliseconds by spinning, so that
/// overlap is actually observable. Spinning rather than sleeping keeps the whole
/// test under ten milliseconds of real time instead of adding a fixed delay to
/// every run of the suite.
private final class ConcurrencyProbeRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var highWater = 0

    /// The largest number of measurements seen running at once.
    var maxLive: Int {
        lock.lock(); defer { lock.unlock() }
        return highWater
    }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        lock.lock()
        live += 1
        highWater = max(highWater, live)
        lock.unlock()

        let deadline = Date().addingTimeInterval(0.002)
        while Date() < deadline {}

        lock.lock()
        live -= 1
        lock.unlock()

        return ProcessResult(exitCode: 0, stdout: "1\t\(arguments.last ?? "")\n", stderr: "")
    }
}

/// The cap is the whole reason this type exists instead of a plain `map`. Without
/// it a scan of a machine with many Flutter projects would launch several hundred
/// `du` processes at once, which makes a disk-bound scan slower, not faster.
///
/// The assertions are `<=` rather than `==` on purpose. At most `concurrency`
/// tasks exist in the group at any moment, so `<=` is structurally guaranteed and
/// cannot flake, whereas hitting the cap exactly needs the cooperative thread pool
/// to be at least that wide and would fail on a smaller machine. `<=` is still
/// enough to catch removing the cap, which lets every path start at once.
@Test func limitsConcurrentMeasurements() async {
    let paths = (0..<20).map { "/p\($0)" }

    // The default must not exceed 4. Raising it is the harmful direction: more
    // du processes on disk-bound work makes the scan slower, not faster.
    let byDefault = ConcurrencyProbeRunner()
    let defaultSizes = await DiskUsageMeasurer(runner: byDefault).sizes(of: paths)
    // `maxLive >= 1` guards against a vacuous pass: if nothing ever ran, every
    // upper-bound assertion below would hold trivially.
    #expect(defaultSizes.count == 20)
    #expect(byDefault.maxLive >= 1)
    #expect(byDefault.maxLive <= 4)

    // An explicit cap must be honoured rather than ignored. The tighter bound
    // here fails if the parameter is dropped and the default is used instead.
    let explicitlyTwo = ConcurrencyProbeRunner()
    let twoSizes = await DiskUsageMeasurer(runner: explicitlyTwo, concurrency: 2)
        .sizes(of: Array(paths.prefix(8)))
    #expect(twoSizes.count == 8)
    #expect(explicitlyTwo.maxLive >= 1)
    #expect(explicitlyTwo.maxLive <= 2)
}
