import Foundation

/// Waiting, behind a protocol so no test in this package sleeps for real time.
///
/// **Two things in the app wait, and they share this.** The loop below waits out a full
/// background interval — six hours by default — and `AppModel` waits out
/// `AppModel.cardResultSeconds`, the beat a cleaned card holds its result for before the deck
/// deals the next one. A test that waited for either would not be a test: the first is six
/// hours and the second turns a suite of seventy cleans into a minute of sleeping.
///
/// One protocol rather than two of the same shape, and the shape really is the same: a number
/// of seconds, thrown out of on cancellation. What differs is what each caller does with the
/// throw, and each says so where it waits — the loop stops for good, and the card's beat is
/// simply cut short.
public protocol Sleeping: Sendable {
    /// Throws `CancellationError` when the surrounding task is cancelled, exactly as
    /// `Task.sleep` does. The loop treats a throw as "stop", so a sleeper that swallowed
    /// cancellation would keep the app scanning after it was told to stop.
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskSleeper: Sleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// What the loop needs from the app: start a scan, and wait for it to end.
///
/// `AppModel` is the only implementation in the app. It is a protocol so the loop's failure
/// paths — a refused scan, a cancelled wait — are reachable without a real 51-second scan,
/// and so no test of the loop can hang waiting for one.
@MainActor
public protocol ScanRunning: AnyObject {
    /// `false` when the app is already busy, which is how `AppModel` answers during a clean.
    func startScan() -> Bool
    /// Returns when the scan — or whatever else the app was doing — has finished.
    func waitForWork() async
    /// Handed the loop as the loop is built, so the app can ask for scans of its own accord.
    ///
    /// The wiring is here rather than in `DevCleanerApp` because a line of it left out is
    /// invisible: a clean would silently keep its stale numbers, and a saved interval would
    /// silently do nothing, with no test in this package able to see either — a test target
    /// cannot import an executable target.
    func useForScanRequests(_ requester: any ScanRequesting)
}

extension AppModel: ScanRunning {}

/// What the app needs back from the loop.
///
/// Both calls go through `ScanScheduler` rather than round it. A scan the scheduler never
/// hears about leaves `lastFinishedAt` where it was, so the background interval falls due a
/// moment later and a second full ~51-second scan starts on top of the one just finished;
/// and a new interval applied by building a fresh scheduler would restart the countdown and
/// re-arm the launch scan.
@MainActor
public protocol ScanRequesting: AnyObject {
    /// Scan now, if the scheduler agrees. Returns when that scan has finished.
    func rescan() async
    /// Use this gap between background scans from now on.
    func useIntervalHours(_ hours: Int) async
}

extension BackgroundScanLoop: ScanRequesting {}

/// Spec §9: a full scan runs on app launch, on the background interval, and on manual
/// rescan. `ScanScheduler` decides; this is the only thing in the app that sleeps for long
/// — the other wait in the app is the card's result beat, which is under a second.
///
/// It lives here rather than in a `.task` modifier because every line of it is a decision —
/// how long to wait, when to give the scheduler back, whether a follow-up runs — and a test
/// target cannot import the executable those modifiers live in.
///
/// `Task.sleep` behind `Sleeping` rather than a `Timer`: this is already an async
/// context, and a timer would need a run loop and a class to hold it.
@MainActor
public final class BackgroundScanLoop {
    /// The floor under every wait.
    ///
    /// `ScanScheduler.abandonScan()` deliberately records no finish time, so before the
    /// first scan has ever completed `secondsUntilDue` keeps answering 0. A loop that slept
    /// for that answer would retry a scan that fails instantly with a zero-length sleep —
    /// four `du` processes per attempt, as fast as the machine can start them. The scheduler
    /// has no throttle by design, so the throttle is here.
    public static let minimumSleepSeconds: TimeInterval = 60

    private let model: any ScanRunning
    private let scheduler: ScanScheduler
    private let sleeper: any Sleeping
    private let clock: @Sendable () -> Date
    /// Guards against two copies of a forever-loop asking the same scheduler for scans.
    private var isLooping = false
    /// The launch scan belongs to the app starting, not to `run()` being called.
    ///
    /// SwiftUI owns when a `.task` runs, and `request(.launch, …)` is never gated by the
    /// interval — so a restarted task without this would start another full scan however
    /// recent the last one was.
    private var didRequestLaunchScan = false

    public init(
        model: any ScanRunning,
        scheduler: ScanScheduler,
        sleeper: any Sleeping = TaskSleeper(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.model = model
        self.scheduler = scheduler
        self.sleeper = sleeper
        self.clock = clock
        // Both directions wired in one place, at the one moment both objects exist. The app
        // holds this only weakly, so the reference back does not keep the loop alive.
        model.useForScanRequests(self)
    }

    /// Spec §8.4's background interval, changed in the app that is already running.
    ///
    /// The scheduler's number is replaced; the scheduler itself is not. A shorter interval
    /// takes effect at the loop's next wake at the latest, because the loop asks
    /// `secondsUntilDue` once per lap and is already asleep on the old answer when Save is
    /// pressed. That is one sleep of delay in the worst case, against a rebuilt loop that
    /// would start a fresh ~51-second launch scan on every Save.
    public func useIntervalHours(_ hours: Int) async {
        await scheduler.setIntervalHours(hours)
    }

    /// The interval comes from the settings the model already loaded, so the app does not
    /// build a second engine to read one number — and so no number is written in the view.
    public convenience init(
        model: AppModel,
        sleeper: any Sleeping = TaskSleeper(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            model: model,
            scheduler: ScanScheduler(intervalHours: model.settings.backgroundScanIntervalHours),
            sleeper: sleeper,
            clock: clock)
    }

    /// Scans on launch and then on the interval, until the task running it is cancelled.
    public func run() async {
        guard !isLooping else { return }
        isLooping = true
        defer { isLooping = false }

        if !didRequestLaunchScan {
            didRequestLaunchScan = true
            if await scheduler.request(.launch, now: clock()) { await scanUntilSettled() }
        }

        while !Task.isCancelled {
            let due = await scheduler.secondsUntilDue(now: clock())
            do {
                try await sleeper.sleep(seconds: max(Self.minimumSleepSeconds, due))
            } catch {
                return
            }
            // A `false` here is the scheduler **at rest**, not wedged: an interval request
            // that is not yet due is dropped without ever marking a scan as running, so
            // there is nothing to give back. Sleeping again is the whole answer.
            guard await scheduler.request(.interval, now: clock()) else { continue }
            await scanUntilSettled()
        }
    }

    /// The Rescan button, spec §9's third trigger.
    ///
    /// It goes through the scheduler rather than straight to `AppModel.startScan()`, because
    /// the scheduler is what holds the countdown and `finished(at:)` is the only thing that
    /// restarts it. Called the other way, a rescan five hours fifty-nine minutes into a
    /// six-hour interval leaves `lastFinishedAt` six hours old — so a minute later the
    /// interval agrees, and a second full ~51-second scan starts four more `du` processes on
    /// a machine the user is sitting in front of. That is the exact waste `finished(at:)`
    /// exists to prevent, arriving through the one door it does not watch.
    ///
    /// A `false` from `request` means a scan is already running, and the click has been kept
    /// as the follow-up that scan will hand back — so returning here starts nothing and loses
    /// nothing.
    public func rescan() async {
        guard await scheduler.request(.manual, now: clock()) else { return }
        await scanUntilSettled()
    }

    /// Runs the scan the scheduler has just approved, and then every follow-up it hands
    /// back, until it hands back none.
    ///
    /// A non-`nil` return from `finished(at:)` has **already** marked the scheduler as
    /// running. Dropping it — `_ = await scheduler.finished(…)`, which is all it takes to
    /// silence the unused-result warning — wedges the actor for the rest of the session:
    /// every later request answers `false`, `secondsUntilDue` keeps counting down, and
    /// nothing on screen says the app has stopped scanning.
    private func scanUntilSettled() async {
        var followUp = await runOneScan()
        while followUp != nil {
            followUp = await runOneScan()
        }
    }

    /// Runs one scan and settles the scheduler on **every** path, then answers with the
    /// follow-up to run now, or `nil`.
    ///
    /// One function with every exit covered, because `defer` — the shape that cannot be
    /// forgotten — cannot contain an `await`, and `abandonScan()` is a call to an actor.
    /// Every `return` below is either an `abandonScan()` or the `finished(at:)` that
    /// replaces it. Leaving one out is the silent failure: the scheduler stays marked as
    /// running, the app stops scanning, and both surfaces go on showing an ageing result.
    private func runOneScan() async -> ScanScheduler.Trigger? {
        guard model.startScan() else {
            // The scheduler agreed and the app did not — a clean is running. No finish time
            // is recorded, so the next scan is still due immediately and the sleep floor
            // above is what keeps this from becoming a spin.
            await scheduler.abandonScan()
            return nil
        }
        await model.waitForWork()
        guard !Task.isCancelled else {
            await scheduler.abandonScan()
            return nil
        }
        return await scheduler.finished(at: clock())
    }
}
