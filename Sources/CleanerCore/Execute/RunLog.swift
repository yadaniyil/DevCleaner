import Foundation

/// The record of what each run removed, kept on disk so it outlives the app.
///
/// There is no undo. Most path items go to the Trash and can be dragged back out of it,
/// but only by someone who knows **what** was removed and **where it landed** — that is
/// `RunEntry.trashedTo`, and this directory is the only place it is written down. Devices
/// are worse: `simctl delete`, `simctl runtime delete` and `avdmanager delete avd` remove
/// outright, so `RunRecord.permanentlyDeletedEntries` and
/// `Executor.Note.devicesWereRemovedPermanently` are the entire surviving evidence that
/// they ever existed.
///
/// One JSON file per run, named after the run's start time so the directory listing is
/// already in time order. The newest `retainedRuns` files are kept and the rest are
/// removed as new ones arrive.
public struct RunLog: Sendable {
    /// How many runs are kept on disk. Older files go as newer ones are written.
    public static let retainedRuns = 20

    /// How many runs one clock second can hold before names have to be reused.
    ///
    /// The stamp is second-resolution, so two runs starting inside the same second want
    /// the same file name. `write` walks `~02`…`~99` instead of replacing what is there;
    /// a hundredth run in one second is the only case that overwrites, and no run this
    /// app performs is anywhere near that fast.
    private static let sameSecondLimit = 99

    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/DevCleaner/runs`
    public static func defaultDirectory() -> URL {
        SettingsStore.defaultDirectory().appendingPathComponent("runs", isDirectory: true)
    }

    /// Stores one run and returns the file it was written to.
    ///
    /// Called for every run, including one where every single item failed: an empty
    /// result and a refused result look identical to a user who has no record of either.
    @discardableResult
    public func write(_ record: RunRecord) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = unusedURL(for: record.startedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Atomic, so a run that is interrupted mid-write leaves the previous run's file
        // whole rather than a half-written one that decodes to nothing.
        try encoder.encode(record).write(to: url, options: .atomic)

        prune()
        return url
    }

    /// The stored runs, newest first. Each still has to be read with `load`, which
    /// answers `nil` for a file that cannot be decoded.
    public func recent(limit: Int = RunLog.retainedRuns) -> [URL] {
        // `prefix` traps on a negative length, and a crash in place of a listing would
        // take the whole app down over an empty history.
        guard limit > 0 else { return [] }
        return names().prefix(limit).map { directory.appendingPathComponent($0) }
    }

    /// One stored run, or `nil` if the file is missing, empty or not decodable.
    ///
    /// Never throws and never traps. A damaged file costs that one run and nothing else:
    /// the other files in the directory still list and still load.
    public func load(at url: URL) -> RunRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunRecord.self, from: data)
    }

    // MARK: - files

    /// Every stored file, newest first. The name is the sort key — see `stamp`.
    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted(by: >)
    }

    private func prune() {
        for name in names().dropFirst(Self.retainedRuns) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// A file name for this start time that is not already taken.
    ///
    /// Writing straight to `<stamp>.json` would replace an existing run of the same
    /// second outright, and the replaced record is not recoverable from anywhere — it
    /// holds the only copy of that run's Trash locations. `~` (0x7E) sorts after `.`
    /// (0x2E), so `20260809-134500~02.json` still orders as newer than
    /// `20260809-134500.json`, and the two-digit sequence keeps that true to `~99`.
    private func unusedURL(for date: Date) -> URL {
        let stamp = Self.stamp(date)
        let first = directory.appendingPathComponent("\(stamp).json")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }

        for sequence in 2...Self.sameSecondLimit {
            let name = stamp + "~" + String(format: "%02d", sequence) + ".json"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    /// `20260809-134500` — fixed width so lexical order equals time order.
    ///
    /// UTC and `en_US_POSIX` on purpose. A device-local calendar would rename the file
    /// under a user whose region uses non-Arabic digits, and a local time zone would run
    /// the same hour twice on the night the clocks go back, putting two runs out of order.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
