import Foundation

/// Decides when a scan may start. Spec §9: on launch, on the background interval, and on
/// manual rescan.
///
/// It starts nothing and sleeps for nothing. The caller owns the loop; this owns the
/// answer. That is the whole reason it can be tested with pinned dates instead of a timer,
/// and no test in this target waits for real time to pass.
public actor ScanScheduler {
    public enum Trigger: String, Sendable, Equatable {
        case launch
        case interval
        case manual

        /// Which request survives when several arrive during one scan and only one
        /// follow-up will run.
        ///
        /// A person clicking rescan outranks the app starting up, which outranks the
        /// timer. Arrival order is the wrong rule: a queued `.interval` is dropped when the
        /// running scan ends — see `finished(at:)` — so a rescan click that landed after it
        /// would be thrown away with it, and the button would do nothing.
        fileprivate var priority: Int {
            switch self {
            case .manual:   return 2
            case .launch:   return 1
            case .interval: return 0
            }
        }
    }

    /// A `var`, because the user can change it in the settings window while the app is
    /// running. Held as a `let` it was a setting accepted and silently discarded: Save wrote
    /// 1 hour to disk and the running app went on scanning every 6 hours until it was quit.
    private var intervalSeconds: TimeInterval
    private var isRunning = false
    /// The one request kept from however many arrived during a scan.
    private var queuedTrigger: Trigger?
    private var lastFinishedAt: Date?

    /// `max(1, hours)`: `Settings.backgroundScanIntervalHours` comes out of a file a user
    /// can hand-edit, and zero would mean "start another scan the moment this one ends" —
    /// four `du` processes and 51 seconds of disk, continuously, for ever.
    public init(intervalHours: Int) {
        self.intervalSeconds = Self.seconds(fromHours: intervalHours)
    }

    /// Changes the gap between background scans in the app that is already running.
    ///
    /// The countdown itself is **not** restarted, and no scan is started here. `isDue` and
    /// `secondsUntilDue` both measure from `lastFinishedAt`, so a scheduler already asleep
    /// honours the new value at its next wake at the latest — the loop asks `secondsUntilDue`
    /// once per lap. Shortening the interval below the time already elapsed makes the next
    /// answer 0, which is a scan on the next lap rather than one interrupting this one.
    ///
    /// Changing the number here rather than building a new `ScanScheduler` is the whole
    /// point. A fresh scheduler has no `lastFinishedAt`, so the first thing it does is agree
    /// to a launch scan — another full ~51 seconds and four more `du` processes every time
    /// the user presses Save.
    public func setIntervalHours(_ hours: Int) {
        intervalSeconds = Self.seconds(fromHours: hours)
    }

    /// `max(1, hours)`, in one place, so the floor cannot hold at construction and go
    /// missing on the way in from the settings window.
    private static func seconds(fromHours hours: Int) -> TimeInterval {
        TimeInterval(max(1, hours)) * 3_600
    }

    /// Whether the caller should start a scan now.
    ///
    /// `false` for an interval request that is not yet due, and for **any** request that
    /// arrives while a scan is running — the second case remembers the request instead.
    public func request(_ trigger: Trigger, now: Date) -> Bool {
        // Only the interval waits. A manual rescan is a person asking, and a launch is
        // the app having no result to show at all.
        //
        // Above the `isRunning` guard on purpose. Below it, an interval request the
        // scheduler has just judged too early would be *queued* instead of dropped, and
        // would then run the moment the current scan ended — the early scan the check
        // exists to prevent, arriving one line later.
        if trigger == .interval, !isDue(now: now) { return false }
        guard !isRunning else {
            keepAsFollowUp(trigger)
            return false
        }
        isRunning = true
        return true
    }

    /// Keeps the strongest of the requests that arrive during one scan, because only one
    /// follow-up will run.
    ///
    /// Equal strength keeps the one already held: three rescans clicked during one scan are
    /// one intention, and re-holding the newest would be the same answer for more work.
    private func keepAsFollowUp(_ trigger: Trigger) {
        guard let held = queuedTrigger else {
            queuedTrigger = trigger
            return
        }
        if trigger.priority > held.priority { queuedTrigger = trigger }
    }

    /// Records that a scan finished, and answers with the coalesced follow-up to run now,
    /// if one was requested while it was running.
    ///
    /// Returning the trigger already marks the scheduler as running again, so the caller
    /// starts the follow-up without asking `request` a second time and without a window
    /// in which a third request could slip past. A caller that cannot start what it is
    /// handed — or whose scan fails — must call `abandonScan()`, or nothing will ever run
    /// again.
    public func finished(at date: Date) -> Trigger? {
        isRunning = false
        lastFinishedAt = date
        guard let queued = queuedTrigger else { return nil }
        queuedTrigger = nil
        // The same rule `request` applies, at the other door. A scan just finished at
        // `date`, so `isDue(now: date)` is false by construction and a queued `.interval`
        // is *always* dropped here: the scan that finished measured the same disk the timer
        // wanted measured, and running it would start a second 51-second scan, with four
        // more `du` processes, zero seconds after the first ended.
        //
        // This is why `keepAsFollowUp` ranks by priority: a rescan click that arrived after
        // the timer's request must replace it, or the click dies with it.
        if queued == .interval, !isDue(now: date) { return nil }
        isRunning = true
        return queued
    }

    /// Gives up on a scan that will never report a finish, and returns the scheduler to
    /// rest.
    ///
    /// Without this the actor has a wedge with no way out. `isRunning` is set by `request`
    /// and again by `finished` when it hands back a follow-up, and only a later `finished`
    /// clears it — so a scan that fails on a path where the caller returns without calling
    /// `finished`, or a follow-up the caller never starts, leaves `isRunning` true for the
    /// rest of the session. Every `request` then answers `false` while `secondsUntilDue`
    /// keeps counting down to zero, so the background loop spins without ever scanning and
    /// nothing on screen says why.
    ///
    /// Records **no** finish time, on purpose: a scan that did not happen must not push the
    /// next one out by a full interval. The countdown keeps running from the last scan that
    /// really completed. Any coalesced follow-up is dropped with it — it was a request to
    /// rescan after a scan that never produced anything, and the user can ask again.
    public func abandonScan() {
        isRunning = false
        queuedTrigger = nil
    }

    /// True when no scan has ever finished, or the interval has elapsed since one did.
    public func isDue(now: Date) -> Bool {
        guard let lastFinishedAt else { return true }
        return now.timeIntervalSince(lastFinishedAt) >= intervalSeconds
    }

    /// How long the background loop should sleep before asking again. Zero when a scan is
    /// already due.
    ///
    /// Never zero while a scan is running. Only the scheduler knows a scan is under way —
    /// `isDue` does not, and the countdown does not — so without this the answer is 0 for
    /// the whole of every launch scan, and for every scan started once the interval had
    /// already elapsed. The loop the brief prescribes is "sleep this long, then ask", and a
    /// zero-length sleep makes that a full-speed spin for the 51 seconds a scan takes. A
    /// whole interval is the right answer: the earliest the next one can be due is an
    /// interval after this one finishes.
    public func secondsUntilDue(now: Date) -> TimeInterval {
        if isRunning { return intervalSeconds }
        guard let lastFinishedAt else { return 0 }
        // Clamped at both ends. The upper clamp is for a clock that jumps backwards — an
        // NTP correction, or the user changing the date — which makes the elapsed time
        // negative and would otherwise ask the loop to sleep for longer than the interval,
        // a week of no background scan after a week-long jump.
        return min(intervalSeconds, max(0, intervalSeconds - now.timeIntervalSince(lastFinishedAt)))
    }

    public var queued: Trigger? { queuedTrigger }
}
