import Foundation
import CleanerCore

/// The last scan, on disk, so the popover opens instantly instead of waiting 51 seconds.
///
/// Spec §9: `~/Library/Application Support/DevCleaner/cache.json`, beside `settings.json`
/// and the `runs` directory.
///
/// Nothing here throws on the way in. A cache is a convenience: a missing one means "no
/// scan yet", and a damaged one has to mean the same thing, because an app that will not
/// start because of its cache is worse than an app with no cache. Nothing is thrown away
/// on the way out either — the write is atomic, so a failure leaves the previous good
/// cache exactly where it was rather than truncating it.
public struct ScanCache: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("cache.json")
    }

    /// `~/Library/Application Support/DevCleaner`, the same directory `SettingsStore` and
    /// `RunLog` use. Deliberately their function rather than a second copy of the path:
    /// two spellings of one directory means a user who moves one file finds the other
    /// left behind.
    public static func defaultDirectory() -> URL { SettingsStore.defaultDirectory() }

    public var url: URL { fileURL }

    /// The stored scan, or `nil` if there is none or it cannot be read.
    ///
    /// `ScanResult.init(from:)` reads every field but `generatedAt` with
    /// `decodeIfPresent`, and drops an unreadable row rather than the whole document, so a
    /// cache written by an older build still loads. This must not undo that by adding a
    /// wrapper type with required keys of its own — the `ScanResult` **is** the document.
    public func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanResult.self, from: data)
    }

    /// Throws away the stored scan.
    ///
    /// Called when a clean has just made it false. Without this the popover reopens on the
    /// next launch showing the caches it removed, at the sizes they were before the run,
    /// with an age that says the measurement is newer than the clean.
    ///
    /// A cache that is not there is already discarded, so a missing file is success rather
    /// than an error — the machine that has never scanned reaches this the first time a
    /// clean is run from a cache-less popover.
    ///
    /// Throws for anything else, for the same reason `save` does: a stale cache the app
    /// could not delete is exactly the failure this exists to prevent, and swallowing it
    /// leaves nothing on screen to say the next launch will lie.
    public func discard() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Stores one scan and returns the file it was written to.
    ///
    /// Throws rather than swallowing, so the caller can say "the popover is showing a
    /// scan it could not save" instead of silently showing a stale age forever.
    @discardableResult
    public func save(_ result: ScanResult) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ISO 8601 on both sides, matching `RunLog`. The default `.deferredToDate` writes
        // a bare number of seconds, which is unreadable in a file a user may open, and
        // silently reads back wrong if the two strategies ever drift apart.
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a scan interrupted mid-write leaves the previous cache whole rather
        // than a half-written file that decodes to nothing.
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
