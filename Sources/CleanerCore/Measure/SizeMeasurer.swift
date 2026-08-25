import Foundation

/// Measures directories.
///
/// **A path that could not be measured is absent from the result, never present as 0.**
/// That distinction is load-bearing: `ios.simulatorCaches` is a genuine 0-byte row on this
/// machine and is ticked, so a measurement failure reported as 0 is indistinguishable from
/// a real empty directory. It matters most where it is least visible — the only simulator
/// runtime here sits on a separate volume and is 17 GB, and a `du` that cannot reach it
/// would have offered it as "0 KB" beside a tick box. `ScanHelpers.measured` turns the
/// missing key into `CleanupItem.startsUnticked`, so an unmeasured row is shown and left
/// for the user rather than swept into a default clean.
public protocol SizeMeasuring: Sendable {
    func sizes(of paths: [String]) async -> [String: Int64]
}

public struct DiskUsageMeasurer: SizeMeasuring {
    private let runner: any ProcessRunner
    private let concurrency: Int

    public init(runner: any ProcessRunner, concurrency: Int = 4) {
        self.runner = runner
        self.concurrency = max(1, concurrency)
    }

    public func sizes(of paths: [String]) async -> [String: Int64] {
        // De-duplicated first, order kept. A repeated path measures to the same number
        // twice, and the second `du` is a second full walk of the same directory — with
        // `~/dev` and `~/dev/app` both named as project roots, `ProjectDiscovery` returns
        // that project twice and every one of its build folders arrives here twice. The
        // result is a dictionary keyed by path, so nothing downstream can tell the
        // difference except the time it took.
        var seen: Set<String> = []
        let unique = paths.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, Int64?).self) { group in
            var iterator = unique.makeIterator()

            func addNext(_ group: inout TaskGroup<(String, Int64?)>) {
                guard let path = iterator.next() else { return }
                group.addTask { (path, measure(path)) }
            }

            for _ in 0..<concurrency { addNext(&group) }

            var result: [String: Int64] = [:]
            while let (path, size) = await group.next() {
                // Left out when `measure` could not answer, so the caller can tell "could
                // not measure" from "measured, and it is empty" — see `SizeMeasuring`.
                if let size { result[path] = size }
                addNext(&group)   // keeps exactly `concurrency` du processes alive
            }
            return result
        }
    }

    /// `du -sk` prints kilobytes and a tab, then the path. A non-zero exit code
    /// means some children were unreadable; the printed total is still correct
    /// for everything it could read, so it is kept rather than discarded.
    ///
    /// `nil` means no total was produced at all — `du` could not be started, or printed
    /// something with no number in the first field. That is not zero bytes, and reporting
    /// it as zero put a row the tool knows nothing about into a default clean.
    private func measure(_ path: String) -> Int64? {
        guard let result = try? runner.run("/usr/bin/du", ["-sk", path]) else { return nil }
        let firstField = result.stdout.split(separator: "\t").first.map(String.init) ?? ""
        guard let kilobytes = Int64(firstField.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return kilobytes * 1_024
    }
}
