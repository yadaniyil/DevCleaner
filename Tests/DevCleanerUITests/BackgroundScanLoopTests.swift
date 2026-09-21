import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

/// A clock the fake sleeper moves. Production never reads the wall clock; neither does any
/// test here, and nothing in this file waits for real time to pass.
///
/// A class with a lock rather than an actor: `BackgroundScanLoop` reads the clock from a
/// **synchronous** `@Sendable () -> Date`, which cannot await anything.
final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = now) { self.value = start }

    var current: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }

    var read: @Sendable () -> Date { { [self] in current } }
}

/// Sleeps for no time at all, remembers what it was asked for, and moves the clock by the
/// amount it was asked to wait.
///
/// It throws once it has slept `stopsAfter` times. That is how every test in this file
/// ends: the loop runs for ever by design, so a test that waited for it to return on its
/// own would hang, and a hanging test is a failure nobody can read.
actor FakeSleeper: Sleeping {
    /// Every wait the loop asked for, in order.
    private(set) var slept: [TimeInterval] = []
    /// Set when the loop came back for a sleep after being told to stop. Recorded and
    /// cancelled rather than left to spin: a loop that swallowed the throw would otherwise
    /// hang the whole run, and a run that hangs names no test and reports no failure.
    private(set) var ranAway = false
    private let stopsAfter: Int
    /// The hard stop, a little above `stopsAfter` so a loop that is *meant* to be entered
    /// again — a `.task` restarted after cancellation — can sleep once more without tripping
    /// it, while a loop that ignores the throw altogether still cannot spin.
    private let runawayAfter: Int
    private let clock: MovableClock?
    /// Runs while the loop is "asleep", so a test can make the world change under it.
    private let whileAsleep: @Sendable () async -> Void

    init(
        stopsAfter: Int = 1,
        clock: MovableClock? = nil,
        whileAsleep: @escaping @Sendable () async -> Void = {}
    ) {
        self.stopsAfter = stopsAfter
        self.runawayAfter = stopsAfter + 2
        self.clock = clock
        self.whileAsleep = whileAsleep
    }

    func sleep(seconds: TimeInterval) async throws {
        slept.append(seconds)
        guard slept.count <= runawayAfter else {
            ranAway = true
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        clock?.advance(by: seconds)
        await whileAsleep()
        if slept.count >= stopsAfter { throw CancellationError() }
        await Task.yield()
    }
}

/// One helper for "do this only the first time", so a `whileAsleep` closure stays honest
/// about happening once. A plain captured `var` is not `Sendable` from a `@Sendable` closure.
actor Once {
    private var done = false

    func claim() -> Bool {
        guard !done else { return false }
        done = true
        return true
    }
}

/// Holds the loop for a closure that has to reach it.
///
/// The loop is built from the sleeper and the target, so a closure on either of those cannot
/// capture it directly. Every test that presses Rescan needs this, because pressing Rescan is
/// a call **into production code** — `BackgroundScanLoop.rescan()` — and calling
/// `ScanScheduler.request(.manual, …)` from a test closure instead would be green about a
/// coordination the shipped app does not have.
@MainActor
final class LoopBox {
    var loop: BackgroundScanLoop?

    func rescan() async { await loop?.rescan() }
}

/// Stands in for `AppModel`, so a refused scan and a cancelled wait are both reachable
/// without a real 51-second scan and without any test hanging on one.
@MainActor
final class FakeScanTarget: ScanRunning {
    private(set) var starts = 0
    /// Answers `false` from `startScan()`, the way `AppModel` does while a clean is running.
    var refuses = false
    /// Runs inside `waitForWork()`, which is where a rescan click or a cancellation lands
    /// in real life: during the scan, not around it.
    var duringScan: () async -> Void = {}
    /// What the loop handed over as it was built. `weak`, so the two-way wiring the app uses
    /// does not become a cycle here that outlives the test.
    private(set) weak var requester: (any ScanRequesting)?

    func startScan() -> Bool {
        guard !refuses else { return false }
        starts += 1
        return true
    }

    func waitForWork() async { await duringScan() }

    func useForScanRequests(_ requester: any ScanRequesting) { self.requester = requester }
}

/// Records that something happened, for a `whileAsleep` closure that cannot return a value.
actor Flag {
    private(set) var isSet = false

    func set() { isSet = true }
}

private let oneHour: TimeInterval = 3_600

@MainActor
private func makeLoop(
    target: FakeScanTarget, scheduler: ScanScheduler, sleeper: FakeSleeper,
    clock: MovableClock
) -> BackgroundScanLoop {
    BackgroundScanLoop(
        model: target, scheduler: scheduler, sleeper: sleeper, clock: clock.read)
}

// MARK: - the launch scan

@MainActor
@Test func theLaunchScanStartsBeforeTheLoopSleepsAtAll() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let sleeper = FakeSleeper(clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)

    await makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock).run()

    #expect(target.starts == 1)
    // One sleep, and it happened after the scan: the loop asked for a whole interval,
    // which is what `secondsUntilDue` answers once a scan has finished.
    #expect(await sleeper.slept == [oneHour])
}

/// Rule 1 of `ScanScheduler`: a non-`nil` return from `finished(at:)` has **already** marked
/// the scheduler as running. Dropping it — `_ = await scheduler.finished(…)` — wedges the
/// actor for the rest of the session, and every later request answers `false` in silence.
///
/// **Two** follow-ups in a row, not one. A chain of one is satisfied by handling the first
/// link and dropping the rest, which is the same wedge one scan later; only the second link
/// tells a loop apart from a single `if`.
///
/// The clicks go through `rescan()`, the code the button calls. Calling
/// `scheduler.request(.manual, …)` from here instead would prove the scheduler coalesces and
/// nothing about whether the app ever asks it to.
///
/// **A click cannot really land here today.** Both Scan again buttons are
/// `.disabled(model.isBusy)`, so the UI cannot press one mid-scan, and this chain is only
/// reachable from a caller of `rescan()` that neither surface has. It is tested because the
/// rule it enforces —
/// start what `finished(at:)` hands back, every time — is what stops the scheduler wedging,
/// and because enabling that button, or adding a second caller, must not be the moment
/// anybody discovers the loop only ran one link.
@MainActor
@Test func everyFollowUpTheSchedulerHandsBackIsStarted() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let sleeper = FakeSleeper(clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)
    let box = LoopBox()
    // Rescan clicked during the launch scan, and again during the scan that answers it.
    var clicks = 0
    target.duringScan = {
        guard clicks < 2 else { return }
        clicks += 1
        await box.rescan()
    }
    let loop = makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock)
    box.loop = loop

    await loop.run()

    #expect(target.starts == 3)
    #expect(await scheduler.queued == nil)
    // Not wedged: a later request is still answered.
    #expect(await scheduler.request(.manual, now: clock.current))
}

// MARK: - every path that gives the scheduler back

/// Rule 2, the refusal path. The scheduler said yes and `AppModel` said no — a clean is
/// running, so `startScan()` refuses. Without `abandonScan()` the actor stays marked as
/// running for ever and the app silently stops scanning.
@MainActor
@Test func aScanTheAppRefusesGivesTheSchedulerBack() async {
    let target = FakeScanTarget()
    target.refuses = true
    let clock = MovableClock()
    let sleeper = FakeSleeper(clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)

    await makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock).run()

    #expect(target.starts == 0)
    // Abandoned, not finished: a scan that never happened must not push the next one out by
    // a whole interval, and `abandonScan()` records no finish time. Asked before the request
    // below, which marks the scheduler as running and would answer a whole interval instead.
    let due = await scheduler.secondsUntilDue(now: clock.current)
    #expect(due == 0)
    // Not wedged.
    #expect(await scheduler.request(.manual, now: clock.current))
}

/// Rule 2, the cancellation path. The wait ends because the surrounding task was cancelled,
/// so no finish is ever reported and the scheduler has to be handed back by the caller.
@MainActor
@Test func aCancelledScanGivesTheSchedulerBackAndEndsTheLoop() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let sleeper = FakeSleeper(stopsAfter: 1, clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)
    // Cancels the task the loop is running on, from inside the scan — which is where a quit
    // lands. Cancelling the test's own task instead would take the assertions with it.
    target.duringScan = { withUnsafeCurrentTask { $0?.cancel() } }
    let loop = makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock)

    let job = Task { @MainActor in await loop.run() }
    await job.value

    #expect(target.starts == 1)
    // Never slept: the loop saw the cancellation and left.
    #expect(await sleeper.slept.isEmpty)
    // No finish recorded, so the countdown still starts from the last real scan.
    #expect(await scheduler.isDue(now: clock.current))
    #expect(await scheduler.request(.manual, now: clock.current))
}

/// Rule 3. `abandonScan()` deliberately records no finish time, so with no scan yet
/// completed `secondsUntilDue` answers 0 for ever. A loop that slept for that answer would
/// retry a fast-failing scan with a zero-length sleep — an unthrottled loop spawning `du`.
/// The throttle lives here because the scheduler has none.
@MainActor
@Test func aScanThatKeepsFailingIsThrottledRatherThanRetriedAtFullSpeed() async {
    let target = FakeScanTarget()
    target.refuses = true
    let clock = MovableClock()
    let sleeper = FakeSleeper(stopsAfter: 3, clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)

    await makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock).run()

    #expect(target.starts == 0)
    let slept = await sleeper.slept
    #expect(slept.count == 3)
    #expect(slept.allSatisfy { $0 == BackgroundScanLoop.minimumSleepSeconds })
    #expect(BackgroundScanLoop.minimumSleepSeconds == 60)
}

// MARK: - the interval

@MainActor
@Test func theIntervalScanRunsOnceTheIntervalHasElapsed() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let sleeper = FakeSleeper(stopsAfter: 2, clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)

    await makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock).run()

    // Launch, then one more an hour later.
    #expect(target.starts == 2)
    #expect(await sleeper.slept == [oneHour, oneHour])
}

// MARK: - the Rescan button

/// The button restarts the countdown, because the scheduler is the only thing that holds one.
///
/// Pointed at `AppModel.startScan()` instead — which is where the plan left it — the
/// scheduler never hears about the scan at all: `lastFinishedAt` stays where it was and the
/// answer below is 0, meaning the background interval is due again immediately.
@MainActor
@Test func aRescanTellsTheSchedulerTheScanHappened() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let scheduler = ScanScheduler(intervalHours: 6)
    let sleeper = FakeSleeper(clock: clock)

    await makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock).rescan()

    #expect(target.starts == 1)
    let due = await scheduler.secondsUntilDue(now: clock.current)
    #expect(due == 6 * oneHour)
    #expect(!(await scheduler.isDue(now: clock.current)))
    // Nothing slept: `rescan()` scans and returns, it does not join the loop's waiting.
    #expect(await sleeper.slept.isEmpty)
}

/// Rule 4, and the whole reason the button goes through the loop.
///
/// The user clicks Rescan half an hour before the background scan is due. That scan restarts
/// the countdown, so when the loop wakes its interval request is **dropped** — the actor at
/// rest, not wedged — and it sleeps out the half hour that is really left instead of running
/// a second full ~51-second scan a moment after the one the user just asked for.
///
/// The click is `BackgroundScanLoop.rescan()`, the call the button makes. Poking the
/// scheduler directly from here would leave this test green about a coordination the shipped
/// app does not have.
@MainActor
@Test func aRescanJustBeforeTheIntervalCostsOneMoreSleepAndNoSecondScan() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let scheduler = ScanScheduler(intervalHours: 1)
    let box = LoopBox()
    let clicked = Once()
    let sleeper = FakeSleeper(stopsAfter: 2, clock: clock, whileAsleep: {
        guard await clicked.claim() else { return }
        // The fake moves the clock by the whole sleep up front, so it is wound back for the
        // click and forward again: the click really did land half an hour before the wake.
        clock.advance(by: -1_800)
        await box.rescan()
        clock.advance(by: 1_800)
    })
    let loop = makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock)
    box.loop = loop

    await loop.run()

    // The launch scan and the user's rescan. Not a third.
    #expect(target.starts == 2)
    #expect(await sleeper.slept == [oneHour, 1_800])
    #expect(await scheduler.request(.manual, now: clock.current))
}

/// A sleep that throws is the app being told to stop, and the loop has to leave rather than
/// come straight back for another one. Swallowing it turns a cancelled loop into a spin
/// through `secondsUntilDue` — busy, invisible, and for as long as the app is running.
@MainActor
@Test func aSleepThatThrowsEndsTheLoopRatherThanBeingRetried() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let sleeper = FakeSleeper(stopsAfter: 1, clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)

    await makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock).run()

    #expect(await sleeper.slept.count == 1)
    #expect(await !sleeper.ranAway)
}

// MARK: - being started twice

/// SwiftUI owns when a `.task` runs, and a second one must not mean a second forever-loop
/// asking the same scheduler for scans.
@MainActor
@Test func theLoopRefusesToRunASecondCopyOfItself() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let sleeper = FakeSleeper(stopsAfter: 1, clock: clock)
    let scheduler = ScanScheduler(intervalHours: 1)
    let loop = makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock)
    // The second `run()` arrives while the first is still inside the scan.
    var reentered = false
    target.duringScan = {
        guard !reentered else { return }
        reentered = true
        await loop.run()
    }

    await loop.run()

    #expect(target.starts == 1)
    // The scan count alone cannot see this: the second copy skips the launch scan and goes
    // straight to waiting, so what it costs is a second forever-loop asking the same
    // scheduler for scans. One sleep is the whole of one loop.
    #expect(await sleeper.slept == [oneHour])
    #expect(await !sleeper.ranAway)
}

/// A `.task` that is cancelled and started again **resumes** the interval loop, and does not
/// scan on launch a second time. Both halves matter and they fail in opposite directions.
///
/// Scanning again would be another full ~51-second scan however recent the last one was,
/// because `request(.launch, …)` is never gated by the interval. Not resuming is the quieter
/// one: if `isLooping` is never cleared, the second `run()` returns at the guard and the app
/// never scans again for the rest of the session, with nothing on screen to say so.
@MainActor
@Test func aRestartedLoopResumesWaitingAndDoesNotScanOnLaunchAgain() async {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let scheduler = ScanScheduler(intervalHours: 6)
    // One sleep ends each `run()`; the runaway bound sits above that, so the second run has
    // room to sleep once and a loop that ignored the throw still could not spin.
    let sleeper = FakeSleeper(stopsAfter: 1, clock: clock)
    let loop = makeLoop(target: target, scheduler: scheduler, sleeper: sleeper, clock: clock)

    await loop.run()
    #expect(target.starts == 1)
    #expect(await sleeper.slept == [6 * oneHour])

    // The launch scan happens before any sleep, so a second one would be counted whether the
    // loop got as far as sleeping or not.
    await loop.run()

    #expect(target.starts == 1)
    // …and the second run really did get into the waiting loop. Counting scans alone cannot
    // tell that apart from returning at the `isLooping` guard and doing nothing at all.
    #expect(await sleeper.slept.count == 2)
    #expect(await !sleeper.ranAway)
}

// MARK: - what it is wired to in the app

/// The loop drives `AppModel`, and `AppModel` really does scan when it is driven. A fake
/// target proves the rules above; this proves the rules are applied to the real thing.
@MainActor
@Test func theLoopScansThroughTheRealAppModel() async {
    let temp = TempDir()
    let engine = FakeEngine(result: makeResult([makeItem(id: "a", sizeBytes: 4_000_000_000)]))
    let model = AppModel(
        engine: engine, cache: ScanCache(directory: temp.url), home: "/Users/test",
        clock: { now })
    let clock = MovableClock()
    let scheduler = ScanScheduler(intervalHours: 1)

    await BackgroundScanLoop(
        model: model, scheduler: scheduler, sleeper: FakeSleeper(clock: clock),
        clock: clock.read).run()

    #expect(model.result?.items.first?.id == "a")
    #expect(!model.isBusy)
    #expect(await engine.log.scans == 1)
}

/// The loop introduces itself to the app as it is built, so the app can ask for a scan of
/// its own accord — after a clean, when everything it was showing has just become false —
/// and change the interval when the settings window saves.
///
/// Wired here rather than in `DevCleanerApp` because a line left out there is invisible: a
/// test target cannot import an executable target, so nothing would fail while a clean kept
/// its stale numbers and a saved interval did nothing.
@MainActor
@Test func theLoopHandsItselfToTheAppAsItIsBuilt() {
    let target = FakeScanTarget()
    let clock = MovableClock()
    let loop = makeLoop(
        target: target, scheduler: ScanScheduler(intervalHours: 1),
        sleeper: FakeSleeper(clock: clock), clock: clock)

    #expect(target.requester === loop)
}

/// Spec §8.4's background interval, changed in the app that is already running.
///
/// The loop is built once in `DevCleanerApp.init()` and held in `@State` by design, so
/// nothing rebuilds it when Save is pressed and the scheduler was constructed from whatever
/// was on disk at launch. Without a way to change that number the user sets 1 hour, sees no
/// error, and the app keeps scanning every 6 hours until it is quit.
///
/// The clock never moves here, so the **only** thing that can change the length of the
/// second sleep is the interval itself.
@MainActor
@Test func aSavedIntervalChangesTheNextSleepWithoutARestart() async {
    let temp = TempDir()
    var stored = Settings.makeDefault(home: "/Users/test")
    stored.backgroundScanIntervalHours = 6
    let engine = FakeEngine(settings: stored)
    let model = AppModel(
        engine: engine, cache: ScanCache(directory: temp.url),
        home: "/Users/test", clock: { now })
    let scheduler = ScanScheduler(intervalHours: 6)
    let saved = Once()
    let landed = Flag()
    let sleeper = FakeSleeper(stopsAfter: 2, whileAsleep: {
        guard await saved.claim() else { return }
        var changed = Settings.makeDefault(home: "/Users/test")
        changed.backgroundScanIntervalHours = 1
        await MainActor.run { model.apply(changed) }
        // `apply` hands the new interval to the scheduler on a task of its own, because the
        // scheduler is an actor and Save is a button. Bounded at five seconds and the bound
        // asserted below: an unbounded wait on a change that never came would stall the whole
        // run, naming no test and reporting no failure.
        let deadline = ContinuousClock.now + .seconds(5)
        while await scheduler.secondsUntilDue(now: now) > oneHour {
            if ContinuousClock.now > deadline { return }
            await Task.yield()
        }
        await landed.set()
    })
    let loop = BackgroundScanLoop(
        model: model, scheduler: scheduler, sleeper: sleeper, clock: { now })

    await loop.run()

    #expect(await landed.isSet)
    // The launch scan's whole six hours, then one hour — the number the user saved, in the
    // session they saved it in.
    #expect(await sleeper.slept == [6 * oneHour, oneHour])
    // Saving a setting changes the schedule; it does not start a scan. The launch scan and
    // no other: a save that rescanned would cost a full ~51 seconds and four `du` processes
    // every time the user pressed the button, and every assertion above would still pass.
    let scans = await engine.log.scans
    #expect(scans == 1)
}

/// The interval comes from the user's settings, not from a number written in the app.
@MainActor
@Test func theIntervalComesFromTheSettings() async {
    let temp = TempDir()
    var stored = Settings.makeDefault(home: "/Users/test")
    stored.backgroundScanIntervalHours = 3
    let model = AppModel(
        engine: FakeEngine(settings: stored), cache: ScanCache(directory: temp.url),
        home: "/Users/test", clock: { now })
    let clock = MovableClock()
    let sleeper = FakeSleeper(clock: clock)

    await BackgroundScanLoop(model: model, sleeper: sleeper, clock: clock.read).run()

    #expect(await sleeper.slept == [3 * oneHour])
}
