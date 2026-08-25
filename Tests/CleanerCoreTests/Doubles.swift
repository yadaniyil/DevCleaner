import Foundation
@testable import CleanerCore

/// Builds the dictionary key that both fake runners use to identify a command.
///
/// The parts are joined with a single space, so a stub can be written as a plain
/// string literal, `"/usr/bin/xcrun simctl list devices --json"`, and a recorded
/// command reads the same way a substring assertion expects. That is how tests
/// across this package write stubs and assertions.
///
/// The known limit: `["a b"]` and `["a", "b"]` produce the same key. No command
/// line in this package has an argument containing a space, and `TempDir` paths
/// are UUID-based, so the ambiguity is unreachable today. If a command ever does
/// take a spaced argument, change the separator here, in this one line, and
/// update the affected stubs.
func commandKey(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).joined(separator: " ")
}

/// Returns canned output keyed by the full command line. See `commandKey`.
struct FakeProcessRunner: ProcessRunner {
    let responses: [String: ProcessResult]

    init(responses: [String: ProcessResult]) { self.responses = responses }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let key = commandKey(executable, arguments)
        guard let response = responses[key] else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "no stub for: \(key)")
        }
        return response
    }
}

/// Records every command and returns success, so tests can assert which
/// external tools the Executor invoked without running them.
final class RecordingProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private let responses: [String: ProcessResult]

    init(responses: [String: ProcessResult] = [:]) { self.responses = responses }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let key = commandKey(executable, arguments)
        lock.lock()
        commands.append(key)
        lock.unlock()
        return responses[key] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}

/// A throwaway directory that deletes itself when the test ends.
final class TempDir: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devcleaner-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var path: String { url.path }

    @discardableResult
    func makeDirectory(_ relative: String) -> String {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target.path
    }

    @discardableResult
    func makeFile(_ relative: String, contents: String = "x", modified: Date? = nil) -> String {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: target, atomically: true, encoding: .utf8)
        if let modified {
            try! FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target.path
    }

    @discardableResult
    func makeSymlink(_ relative: String, to destination: String) -> String {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
        return target.path
    }
}

/// Counts calls from a synchronous callback, so a test can say "after the first item".
///
/// A class with a lock rather than an `actor`: `Executor`'s `progress` and `isCancelled`
/// are both synchronous closures and cannot await. `NSLock` is unavailable from *async*
/// contexts, which these are not.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func count() { lock.lock(); value += 1; lock.unlock() }

    var hasCounted: Bool {
        lock.lock(); defer { lock.unlock() }
        return value > 0
    }
}

/// Returns pre-set sizes; any path not listed measures as zero.
struct FixedSizeMeasurer: SizeMeasuring {
    let sizes: [String: Int64]
    init(_ sizes: [String: Int64]) { self.sizes = sizes }

    func sizes(of paths: [String]) async -> [String: Int64] {
        var result: [String: Int64] = [:]
        for path in paths { result[path] = sizes[path] ?? 0 }
        return result
    }
}

/// Answers for the paths it knows and **leaves the rest out of the dictionary**, which is
/// how `DiskUsageMeasurer` reports "could not measure".
///
/// `FixedSizeMeasurer` cannot express this: it answers 0 for anything it was not given, so
/// every path it is asked about comes back present. The distinction matters because 0 is a
/// real answer — `ios.simulatorCaches` is genuinely 0 bytes and genuinely ticked — while an
/// absent key means the tool does not know the size and must not tick the row.
struct PartialSizeMeasurer: SizeMeasuring {
    let known: [String: Int64]
    init(_ known: [String: Int64]) { self.known = known }

    func sizes(of paths: [String]) async -> [String: Int64] {
        var result: [String: Int64] = [:]
        for path in paths { if let size = known[path] { result[path] = size } }
        return result
    }
}

/// `FixedSizeMeasurer` plus a record of how it was called.
///
/// `DiskUsageMeasurer` batches its input and holds exactly four `du` processes
/// open, so a scanner that calls `sizes(of:)` once per path defeats that cap and
/// spawns one process per entry instead. Nothing about that is visible in the
/// items a scanner returns, so it needs its own assertion.
///
/// An `actor` rather than a lock: the protocol requirement is already `async`, so
/// actor isolation satisfies it directly, and `NSLock` cannot be held across the
/// suspension point.
actor CallCountingSizeMeasurer: SizeMeasuring {
    private let fixed: [String: Int64]
    private(set) var callCount = 0
    private(set) var batches: [[String]] = []

    init(_ sizes: [String: Int64] = [:]) { self.fixed = sizes }

    func sizes(of paths: [String]) async -> [String: Int64] {
        callCount += 1
        batches.append(paths)
        var result: [String: Int64] = [:]
        for path in paths { result[path] = fixed[path] ?? 0 }
        return result
    }
}
