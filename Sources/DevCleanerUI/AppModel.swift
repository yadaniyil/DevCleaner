import Foundation
import Observation
import CleanerCore

/// What the popover is doing, and everything it needs to draw.
///
/// `@MainActor` because every stored property here is read by a view during layout, and
/// `@Observable` so SwiftUI re-renders when one changes. Neither annotation puts work on
/// the main thread: every call into the engine goes through `CleanerEngine`, whose async
/// requirements are `@concurrent` and therefore run on the concurrent pool in this
/// language mode and the next one.
@MainActor
@Observable
public final class AppModel {
    /// Spec §8.2. What the app is **doing**, and nothing else. The two busy states carry the
    /// latest progress report so the view has something to say beyond a spinner.
    ///
    /// A finished run is deliberately not one of these. Its summary is `lastRun`, a stored
    /// value of its own, because the run ends by asking for a fresh scan and the user goes
    /// on reading the summary while that scan runs in the background. Folded into this enum the
    /// two would fight: either the scan takes the phase and the panel the user is reading
    /// disappears, or the summary keeps it and `isBusy` reads false over a running scan, so a
    /// second one can start beside it and overwrite `work`.
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning(ScanProgress?)
        case running(ExecutionProgress?)
    }

    /// Which of the app's two surfaces an event happened on. The popover and the main window
    /// share this one model, so an event that means "the user looked away" has to say who
    /// looked away — a close on one surface must not put away what the other is still showing.
    public enum Surface: Sendable, Equatable {
        case popover
        case mainWindow
    }

    public private(set) var phase: Phase = .idle
    /// The scan being shown. Survives across a rescan, so the popover never goes blank —
    /// but **not** across a clean, which makes every number in it false.
    public private(set) var result: ScanResult?
    public private(set) var selection: SelectionModel?
    /// The finished run whose summary panel is on screen, or `nil`. Cleared by
    /// `dismissSummary()` and by nothing else.
    public private(set) var lastRun: RunRecord?
    /// The surface the user watched `lastRun` on — the one whose review sheet started the
    /// clean. Set and cleared with `lastRun`, so `surfaceClosed` can tell the close that
    /// means "the user looked away from the summary" apart from a close on the surface that
    /// was merely also drawing it.
    public private(set) var lastRunSurface: Surface?
    public private(set) var settings: Settings
    /// Why the last scan could not be cached, if it could not. Shown rather than
    /// swallowed: without it the popover shows an age that never changes and nothing says
    /// why.
    public private(set) var lastCacheError: String?
    public var expandedGroups: Set<GroupID> = []
    /// Which aggregate rows of the decision board are open, by `DecisionRow.id`.
    ///
    /// A separate set from `expandedGroups` and keyed on a `String` rather than a `GroupID`,
    /// because the two surfaces open different things: the popover opens one of five fixed
    /// groups, the board opens an aggregate whose identity is a scanner and a shared name.
    /// Sharing one set would mean opening "Android" in the popover also opened whatever
    /// aggregate happened to hash alongside it.
    ///
    /// **Not** cleared between scans, unlike the ticks. `DecisionBoardModel.aggregateID` is
    /// stable across scans by construction, so a rescan landing under an open row leaves it
    /// open — which is the behaviour a background scan needs, since it arrives without the
    /// user asking. A tick is a decision about a specific measurement and must not survive;
    /// an open twisty is not.
    public var expandedDecisionRows: Set<String> = []
    /// The last scan progress seen, kept after the phase moves on so a test can assert the
    /// callback was wired up at all.
    public private(set) var sawScanProgress: ScanProgress?

    private let engine: any CleanerEngine
    private let cache: ScanCache
    private let clock: @Sendable () -> Date
    public let home: String
    private var work: Task<Void, Never>?
    /// The background loop, which owns the schedule. `weak` because it owns this model in
    /// turn, and `@ObservationIgnored` because nothing on screen is drawn from it.
    ///
    /// `nil` in every test that builds a model on its own, which is why the two things it is
    /// asked for — a scan after a clean, and a changed interval after a save — each have a
    /// test that builds the real loop as well.
    @ObservationIgnored private weak var scans: (any ScanRequesting)?

    public init(
        engine: any CleanerEngine,
        cache: ScanCache,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.cache = cache
        self.home = home
        self.clock = clock
        self.settings = engine.settings()
        // Spec §9: the popover opens instantly with the last cached result. Reading one
        // small JSON file is the whole of "instantly"; the 51-second scan is never on
        // this path.
        if let cached = cache.load() { apply(cached) }
    }

    public var isBusy: Bool {
        switch phase {
        case .scanning, .running: return true
        case .idle:               return false
        }
    }

    /// Told to the app by `BackgroundScanLoop` as that loop is built.
    public func useForScanRequests(_ requester: any ScanRequesting) { scans = requester }

    /// "2h ago", or `nil` when no scan has ever finished.
    public var scanAgeText: String? {
        guard let result else { return nil }
        return AgeText.since(result.generatedAt, now: clock())
    }

    /// Everything above the divider, ready to draw. `nil` before the first scan.
    ///
    /// Built here rather than in the view because `HeaderModel` needs a `now`, and the app
    /// must have exactly one clock. A second one in `DevCleanerApp` would render an age no
    /// test can pin, and it could disagree with `scanAgeText` on the same screen.
    /// The selection goes in as well, so the amount, the stacked bar and the "offered but
    /// not ticked" line follow the ticks — the same rule the group headlines and the Clean
    /// button already use. `result` and `selection` are set and cleared together, so the
    /// guard needs both and can never drop only one.
    public var header: HeaderModel? {
        guard let result, let selection else { return nil }
        return HeaderModel(result: result, selection: selection, now: clock(), home: home)
    }

    /// The decision-first window's header, ready to draw. `nil` before the first scan.
    ///
    /// Guarded on both `result` and `selection` exactly as `header` is: the two are set and
    /// cleared together, so the guard needs both and can never drop only one. The clock is
    /// this model's, for the same reason — a second one in the view renders an age no test
    /// can pin, and it could disagree with `scanAgeText` on the same screen.
    public var decisionHeader: DecisionHeaderModel? {
        guard let result, let selection else { return nil }
        return DecisionHeaderModel(
            result: result, selection: selection, now: clock(), home: home)
    }

    /// The three columns, ready to draw. Empty before the first scan, which is what the
    /// convenience overload answers for a model with no result.
    public var decisionColumns: [DecisionColumn] { DecisionBoardModel.columns(from: self) }

    /// Whether the expandable group list belongs on screen.
    ///
    /// Not simply "there is a result". A run summary is the answer to the question the user
    /// asked last, and the fresh scan that lands behind it must not push a hundred rows
    /// in between the summary and its Done button. Decided here rather than in the view,
    /// because it is a choice between two panels and not a layout.
    public var showsGroupList: Bool {
        guard case .idle = phase else { return false }
        return result != nil && lastRun == nil
    }

    /// The finished run, ready to draw. `nil` until a run ends and again once it is
    /// dismissed.
    ///
    /// The URL comes from the engine rather than from the record, because `RunRecord`
    /// does not carry where it was written: `RunLog.write` returns the URL and
    /// `CleanerService.store` discards it. The newest file in the runs directory is the
    /// one just written — unless the write failed, which `RunSummaryModel` detects from
    /// the record's own notes and answers with no link.
    public var summary: RunSummaryModel? {
        guard let lastRun else { return nil }
        return RunSummaryModel(record: lastRun, logURL: engine.newestRunLogURL())
    }

    // MARK: - scanning

    /// Starts a scan unless one is already under way. Returns whether it started.
    @discardableResult
    public func startScan() -> Bool {
        guard !isBusy else { return false }
        phase = .scanning(nil)
        let engine = self.engine
        let cache = self.cache
        let startedAt = clock()

        // Built once, before the task, rather than per report. `self` is captured strongly:
        // the model belongs to the app and outlives every popover, and the cycle it makes
        // with `work` ends when the task finishes and clears it.
        let report: @Sendable (ScanProgress) -> Void = { [self] progress in
            Task { @MainActor in self.applyScanReport(progress) }
        }

        work = Task { [self] in
            let scanned = await engine.scan(now: startedAt, progress: report)
            // A cancelled scan is not adopted and not cached. No scanner is cancellation
            // aware today, so `cancel()` cannot stop the ~51 seconds — but the result it
            // produces must not land, or the day a scanner does learn to stop early a
            // half-finished scan is written over the good cache and shown as a real one.
            guard !Task.isCancelled else { return abandonScan() }
            // Written before the state is applied, and off the main actor, so a slow
            // disk cannot stall the popover's redraw.
            let cacheError = await Self.store(scanned, in: cache)
            finish(scanned, cacheError: cacheError)
        }
        return true
    }

    /// Returns once the scan or run under way has finished, or straight away when there is
    /// none.
    ///
    /// For `BackgroundScanLoop`, which has to know when its scan ended. Awaiting the task
    /// itself rather than polling `isBusy`: it is exact, it costs nothing while waiting, and
    /// it needs no second sleep in a loop whose whole job is deciding how long to sleep.
    ///
    /// The handle is **not** handed out. `work` is what `cancel()` acts on, and a caller
    /// holding it could stop a clean halfway through from outside the state machine.
    ///
    /// It does not return early when the caller is cancelled, because the thing it waits for
    /// does not stop early either: no scanner checks for cancellation, so a cancelled scan
    /// measures for its full ~51 seconds. Promising sooner would be a promise this app
    /// cannot keep.
    public func waitForWork() async {
        await work?.value
    }

    /// Leaves the previous scan on screen and goes back to idle, so a cancelled scan costs
    /// nothing but the wait. Not `.idle` by way of `finish`, which would adopt the result.
    private func abandonScan() {
        phase = .idle
        work = nil
    }

    /// Takes one scan report, from wherever the engine happened to be running.
    ///
    /// Internal rather than folded into the closure so the rule below can be tested at all.
    /// A report is delivered by hopping onto the main actor, and the last report of a scan
    /// routinely arrives **after** the scan itself has returned — the engine reports from a
    /// synchronous closure off the main actor, and which of the two main-actor jobs runs
    /// first is the runtime's business. Without the guard that late report puts the popover
    /// back into `.scanning` and nothing ever takes it out again: `isBusy` stays true, and
    /// Scan and Clean both refuse for the rest of the session.
    func applyScanReport(_ progress: ScanProgress) {
        sawScanProgress = progress
        guard case .scanning = phase else { return }
        phase = .scanning(progress)
    }

    /// The same rule for a run, with the same consequence for the same reason.
    func applyRunReport(_ progress: ExecutionProgress) {
        guard case .running = phase else { return }
        phase = .running(progress)
    }

    /// Writes the cache and returns what went wrong, or `nil`.
    ///
    /// `nonisolated` and `@concurrent` on purpose. `Task { }` inside `startScan` inherits
    /// this class's `@MainActor` isolation, so a plain `try cache.save(...)` there would
    /// run the file write on the thread that draws the popover — small on a healthy disk,
    /// not small on a busy or encrypted one, and pointless either way because nothing on
    /// screen is waiting for it.
    @concurrent
    private nonisolated static func store(
        _ scanned: ScanResult, in cache: ScanCache
    ) async -> String? {
        do {
            try cache.save(scanned)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func finish(_ scanned: ScanResult, cacheError: String?) {
        apply(scanned)
        lastCacheError = cacheError
        phase = .idle
        work = nil
    }

    /// Spec §8.3: tick state is **not** persisted between scans. Every result builds a
    /// fresh `SelectionModel`, so a row the user unticked before a rescan comes back
    /// ticked — and a row that has since become protected comes back untickable.
    private func apply(_ scanned: ScanResult) {
        result = scanned
        selection = SelectionModel(result: scanned)
    }

    // MARK: - cleaning

    /// Starts a clean of whatever is ticked. Returns whether it started.
    ///
    /// `surface` is where the user confirmed the clean, and it is the surface the finished
    /// run's summary will belong to: both surfaces draw `summary`, but only this one's close
    /// puts it away — the rule is on `surfaceClosed`.
    @discardableResult
    public func startClean(from surface: Surface) -> Bool {
        guard !isBusy, let result, let selection else { return false }
        let items = selection.selectedItems
        guard !items.isEmpty else { return false }

        phase = .running(nil)
        let engine = self.engine
        let startedAt = clock()
        // The engine re-derives the list when the ticks are untouched. Handing over a
        // list the app assembled would put the most destructive decision in the tool back
        // where a test cannot reach it — which is the exact defect `cleanDefault` exists
        // to close.
        let usesDefaults = selection.isDefaultSelection

        let report: @Sendable (ExecutionProgress) -> Void = { [self] progress in
            Task { @MainActor in self.applyRunReport(progress) }
        }

        let cache = self.cache
        work = Task { [self] in
            let record = usesDefaults
                ? await engine.cleanDefault(result, now: startedAt, progress: report)
                : await engine.clean(items: items, now: startedAt, progress: report)
            // Off the main actor and before anything is drawn, exactly as the scan's write
            // is: the popover's redraw must not wait on a disk that is busy.
            let cacheError = await Self.discard(cache)
            // Nothing goes below this line — no test can see it. The reason is on `finishRun`.
            finishRun(record, cacheError: cacheError, surface: surface)
        }
        return true
    }

    /// Throws the stored scan away, and returns what went wrong, or `nil`.
    @concurrent
    private nonisolated static func discard(_ cache: ScanCache) async -> String? {
        do {
            try cache.discard()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Ends a run: shows its summary, drops the scan it invalidated, and asks for a new one.
    ///
    /// **Everything measured before the run is now false**, so none of it may survive: the
    /// headline, the range, the free-space figure, the five group totals, the bar and the
    /// Clean button were all built from rows this run has just removed, and `scanned 6m ago`
    /// claims they are newer than the clean. Left standing they are wrong by the whole of
    /// what was cleaned — 58.0 GB of it on a real dev machine — and the background loop would not
    /// correct them for up to a full interval, six hours by default, because a clean does not
    /// touch `lastFinishedAt`.
    ///
    /// The on-disk cache goes with them. Kept, it is read back on the very next launch and
    /// presented as the current state of the disk.
    ///
    /// The new scan is asked for through the loop rather than by calling `startScan()` here,
    /// for the reason on `BackgroundScanLoop.rescan`: the scheduler holds the countdown, and
    /// it is the request through that door which restarts it.
    ///
    /// **Nothing may be added after the call to this from `startClean`'s task.** No test can
    /// see it. Every test waits on `!isBusy`, which this satisfies the instant it sets
    /// `phase = .idle` and clears `work`, so any statement placed after the call runs
    /// unobserved and a mutation of it survives — which one did, and is recorded in the fix
    /// report as M37. That is harmless only because the call is the last statement in the
    /// task. Work that has to be waited for belongs above it, like the cache discard.
    private func finishRun(_ record: RunRecord, cacheError: String?, surface: Surface) {
        lastRun = record
        lastRunSurface = surface
        result = nil
        selection = nil
        lastCacheError = cacheError
        phase = .idle
        work = nil
        // Unstructured on purpose. This is called from the run's own task, which a Cancel
        // may already have cancelled, and a child would inherit that cancellation and skip
        // the scan — leaving the popover with nothing but a summary until the interval came
        // round. `Task { }` starts clean. A cancelled run still removed things, so it needs
        // the rescan just as much as one that finished.
        Task { [scans] in await scans?.rescan() }
    }

    /// Spec §8.2: stops before the next item; what is already removed stays removed.
    ///
    /// **A run stops; a scan does not.** No scanner checks for cancellation, so a cancelled
    /// scan keeps measuring for its full ~51 seconds and only its result is thrown away —
    /// the popover goes back to idle still showing the scan it had. Whatever wires a Cancel
    /// button to this must not promise a scan stops sooner than that.
    ///
    /// Cancelling this handle is enough because the engine call is awaited **on** this task,
    /// so the engine's work is a child of it and inherits the cancellation. `Executor` then
    /// asks `isCancelled` before each item, which is the only thing that stops it: its loop
    /// calls a synchronous `perform` and has no suspension point of its own, so without that
    /// check a cancelled run would carry on and delete everything.
    ///
    /// What does **not** work is starting the run without keeping the handle. Cancellation
    /// travels through the handle, not through the enclosing scope: `work` is unstructured,
    /// so nothing else reaches it.
    public func cancel() { work?.cancel() }

    /// Puts the summary panel away.
    ///
    /// It clears the summary and nothing else. There is nothing to restore: `finishRun`
    /// dropped the pre-clean scan rather than hiding it, so what the popover shows next is
    /// the scan running behind the panel, the scan that has already landed, or "no scan
    /// yet" — never the numbers the run made false. The surface goes with the record: the
    /// two are one fact, "this run's panel is on screen, owned by that surface", and half
    /// of it left standing would claim ownership of a summary that no longer exists.
    public func dismissSummary() {
        lastRun = nil
        lastRunSurface = nil
    }

    /// A surface has been closed. The summary belongs to the run the user just watched — on
    /// the surface they watched it from — not to the rest of the session.
    ///
    /// Without this, Done is the only way out. A user who closes the popover instead of
    /// pressing it reopens it twelve hours and two background scans later to yesterday's
    /// summary — still hiding the group list, and putting that run's free-space figure on the
    /// same screen as a fresh and different one in the header.
    ///
    /// Keyed on the **owning** surface closing, and the ownership matters: the popover and
    /// the main window draw the same `summary`, so a rule that cleared it on any close would
    /// let dismissing the menu-bar popover wipe the panel out of the main window the user is
    /// still reading — and closing the main window would do the reverse. Only the close of
    /// the surface the run was watched on is the user looking away from it; a close anywhere
    /// else is ignored here, which is also what makes the event safe to report on every
    /// close, including the ones where no run has happened at all.
    ///
    /// Keyed on closing rather than on a scan landing, and that difference matters too:
    /// a finished run asks for a scan of its own, which returns in about 51 seconds, so a rule
    /// that cleared the panel when a scan landed would wipe it out from under somebody still
    /// reading it.
    ///
    /// It clears the summary and nothing else. The scan behind the panel — very likely the
    /// fresh one the run asked for — is what the surface shows on the way back in.
    public func surfaceClosed(_ surface: Surface) {
        guard surface == lastRunSurface else { return }
        dismissSummary()
    }

    // MARK: - settings and ticks

    public func reloadSettings() { settings = engine.settings() }

    /// Called by the settings window after a successful save, so the popover picks up a
    /// changed menu bar preference or Trash mode without a rescan.
    ///
    /// The background interval is handed to the loop as well, because nothing else would
    /// ever read it again: `BackgroundScanLoop` is built once in `DevCleanerApp.init()` and
    /// held in `@State` by design, so its `ScanScheduler` was constructed from the value that
    /// was on disk at launch. Without this the user sets 1 hour, sees no error, and the app
    /// keeps scanning every 6 hours for the rest of the session — a setting accepted and
    /// silently discarded.
    ///
    /// The hand-over is on a task of its own because the scheduler is an actor and this is
    /// called from a button. The loop is asleep on the old answer when Save is pressed, so
    /// the new interval applies at its next wake at the latest either way.
    public func apply(_ updated: Settings) {
        settings = updated
        Task { [scans] in await scans?.useIntervalHours(updated.backgroundScanIntervalHours) }
    }

    public func toggleExpanded(_ group: GroupID) {
        if expandedGroups.contains(group) {
            expandedGroups.remove(group)
        } else {
            expandedGroups.insert(group)
        }
    }

    public func toggleDecisionRow(_ id: String) {
        if expandedDecisionRows.contains(id) {
            expandedDecisionRows.remove(id)
        } else {
            expandedDecisionRows.insert(id)
        }
    }

    public func setTicked(_ ticked: Bool, for id: String) {
        selection?.setTicked(ticked, for: id)
    }

    /// Sets every row an aggregate's checkbox controls — `DecisionRow.itemIDs`.
    ///
    /// Through `setTicked` one identifier at a time, never into `SelectionModel`'s store,
    /// for the reason on `SelectionModel.setGroup`: the eligibility rule exists once, so a
    /// protected identifier in the list is refused here exactly as it is refused by a row
    /// click. An aggregate whose children are partly protected therefore ticks what it can
    /// and leaves the rest, which is what its own `.all`/`.some` reading already promises.
    ///
    /// Not `setGroup`, which takes a `GroupID`: an aggregate is a scanner and a name, and
    /// its children can span groups the moment two scanners in different groups produce one.
    public func setRows(_ ids: [String], ticked: Bool) {
        for id in ids { selection?.setTicked(ticked, for: id) }
    }

    public func setGroup(_ group: GroupID, ticked: Bool) {
        selection?.setGroup(group, ticked: ticked)
    }
}
