import Foundation
import CleanerCore

/// Everything the app is allowed to ask the engine for, and the only door it goes through.
///
/// Two reasons for a protocol over calling `CleanerService` directly.
///
/// **Isolation.** Every async requirement is `@concurrent`. `CleanerService.scan` and
/// `clean` are nonisolated `async` functions, and in the Swift 6 language mode a
/// nonisolated async function runs on the concurrent pool whoever calls it. Under the
/// Swift 7 default (SE-0461) it would instead inherit the caller's isolation — and every
/// caller here is `@MainActor`, so a 51-second scan whose first ~29 seconds are a
/// synchronous per-project `git log` loop would run on the main thread with the popover
/// open on top of it. `@concurrent` states the answer instead of depending on the mode.
///
/// **Testability.** `AppModel` is the state machine, and a state machine tested against
/// the real engine would need a real scan. A fake conforming to this protocol answers
/// instantly with a pinned `ScanResult`.
public protocol CleanerEngine: Sendable {
    @concurrent
    func scan(now: Date, progress: @Sendable (ScanProgress) -> Void) async -> ScanResult

    /// Cleans **exactly what it is handed**. Only for a selection the user has changed;
    /// otherwise use `cleanDefault`.
    @concurrent
    func clean(
        items: [CleanupItem], now: Date, progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord

    /// Cleans the rows the listing ticks, deciding nothing itself.
    ///
    /// This exists because the tick rule must not be re-derived outside the engine.
    /// `defaultSelection` is `selectedByDefault`, never `isDeletable`: the Android NDK is
    /// deletable, deliberately unticked, and 5.57 GB of network download to get back.
    @concurrent
    func cleanDefault(
        _ result: ScanResult, now: Date, progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord

    func settings() -> Settings
    /// Throws `SettingsError.projectRootTooWide` rather than storing `~` or `/`.
    func save(_ settings: Settings) throws
    /// The newest stored run, for the "open the run log" link. `nil` when none exists.
    func newestRunLogURL() -> URL?
}

public struct LiveCleanerEngine: CleanerEngine {
    private let service: CleanerService
    private let runLog: RunLog

    /// `RunLog` is held a second time, beside the one inside `CleanerService`, because the
    /// service writes runs but does not hand back where it wrote them: `RunLog.write`
    /// returns the URL and `CleanerService.store` discards it. Both point at
    /// `RunLog.defaultDirectory()`, so `recent(limit: 1)` is the file the service just
    /// wrote. Task 7 refuses to offer the link when the record says the write failed.
    public init(
        service: CleanerService = .makeDefault(),
        runLog: RunLog = RunLog(directory: RunLog.defaultDirectory())
    ) {
        self.service = service
        self.runLog = runLog
    }

    @concurrent
    public func scan(
        now: Date, progress: @Sendable (ScanProgress) -> Void
    ) async -> ScanResult {
        await service.scan(now: now, progress: progress)
    }

    @concurrent
    public func clean(
        items: [CleanupItem], now: Date, progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        await service.clean(items: items, now: now, progress: progress)
    }

    @concurrent
    public func cleanDefault(
        _ result: ScanResult, now: Date, progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        await service.cleanDefault(result, now: now, progress: progress)
    }

    public func settings() -> Settings { service.settings() }

    public func save(_ settings: Settings) throws { try service.save(settings) }

    public func newestRunLogURL() -> URL? { runLog.recent(limit: 1).first }
}
