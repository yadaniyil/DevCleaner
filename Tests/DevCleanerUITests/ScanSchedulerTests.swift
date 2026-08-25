import Testing
import Foundation
@testable import DevCleanerUI

@Test func theFirstRequestAlwaysStarts() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    #expect(await scheduler.request(.launch, now: now))
}

/// Nothing finished yet means overdue, not "wait six hours". `secondsUntilDue` already
/// answers 0 in that state, so the background loop sleeps for nothing and asks straight
/// away — and if the answer were `false`, that loop would spin without sleeping and
/// without ever scanning.
@Test func anIntervalRequestStartsWhenNoScanHasEverFinished() async {
    let scheduler = ScanScheduler(intervalHours: 6)

    #expect(await scheduler.isDue(now: now))
    #expect(await scheduler.request(.interval, now: now))
}

@Test func aRequestArrivingDuringAScanDoesNotStartASecondOne() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)

    #expect(!(await scheduler.request(.manual, now: now)))
    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(6 * 3_600))))
}

/// Overlapping requests coalesce: however many arrive while a scan is running, exactly
/// one follow-up runs afterwards. A scan takes 51 seconds and holds four `du` processes;
/// three queued rescans would take a quarter of an hour and measure the same disk.
@Test func manyRequestsDuringAScanCoalesceIntoOneFollowUp() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.request(.manual, now: now)
    _ = await scheduler.request(.manual, now: now)
    _ = await scheduler.request(.interval, now: now)

    let first = await scheduler.finished(at: now.addingTimeInterval(51))
    #expect(first == .manual)

    let second = await scheduler.finished(at: now.addingTimeInterval(102))
    #expect(second == nil)
}

/// `queued` reports the request being held, not merely the absence of one. Every other
/// assertion about it here reads `nil`, which a `queued` that answered `nil` always would
/// satisfy while the follow-up it is supposed to describe went unseen.
@Test func theCoalescedRequestIsVisibleWhileTheScanIsStillRunning() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    #expect(await scheduler.queued == nil)

    _ = await scheduler.request(.manual, now: now)
    #expect(await scheduler.queued == .manual)
}

/// Handing back a follow-up already counts as starting it. The caller runs what `finished`
/// returns without asking `request` again, so if the scheduler went back to not-running in
/// between, the next request would start a **second** scan on top of the follow-up: two
/// scans, eight `du` processes, one disk.
@Test func theFollowUpScanCountsAsRunningSoNothingStartsBesideIt() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.request(.manual, now: now)

    #expect(await scheduler.finished(at: now.addingTimeInterval(51)) == .manual)
    #expect(!(await scheduler.request(.manual, now: now.addingTimeInterval(52))))
}

// MARK: - the interval is not allowed in through the queue

/// The due check sits **above** the running check, so an interval request that is too early
/// is dropped outright rather than held as a follow-up. Held, it would run the moment the
/// current scan ended — the early scan the due check exists to prevent, one line later.
@Test func anIntervalRequestThatIsNotDueIsDroppedRatherThanQueued() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)
    // A rescan two hours later, still running when the timer's request arrives.
    #expect(await scheduler.request(.manual, now: now.addingTimeInterval(2 * 3_600)))

    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(2 * 3_600 + 60))))
    #expect(await scheduler.queued == nil)
}

/// An interval request that *was* due when it arrived is still spent by the time the scan it
/// waited behind has finished. The scan that just ran measured the same disk, so the timer
/// has nothing left to ask for; a second full scan zero seconds later is 51 seconds and four
/// more `du` processes for a number that cannot have moved.
@Test func aQueuedIntervalRequestIsSpentByTheScanThatJustFinished() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.request(.interval, now: now)
    #expect(await scheduler.queued == .interval)

    #expect(await scheduler.finished(at: now.addingTimeInterval(51)) == nil)
    #expect(await scheduler.queued == nil)
    // Dropped, not wedged: the scheduler is at rest and the next scan can still start.
    #expect(await scheduler.request(.manual, now: now.addingTimeInterval(60)))
}

/// Priority, not arrival order. The click lands after the timer's request and must replace
/// it — the timer's request is dropped when this scan ends, so a queue that kept the earlier
/// one would throw the user's click away with it and the rescan button would do nothing.
@Test func aRescanClickOutranksAnIntervalRequestAlreadyQueued() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.request(.interval, now: now)
    _ = await scheduler.request(.manual, now: now.addingTimeInterval(10))

    #expect(await scheduler.queued == .manual)
    #expect(await scheduler.finished(at: now.addingTimeInterval(51)) == .manual)
}

// MARK: - the loop must never be told to sleep for nothing

/// `isDue` cannot see that a scan is running and the countdown cannot either, so both would
/// answer "due now" for the whole of a scan started after the interval had elapsed. The
/// prescribed loop sleeps this long and then asks, so a zero here is a full-speed spin for
/// the 51 seconds the scan takes.
@Test func theSleepLengthIsAWholeIntervalWhileAScanIsRunning() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)
    #expect(await scheduler.request(.interval, now: now.addingTimeInterval(6 * 3_600)))

    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(6 * 3_600 + 10))
        == 6 * 3_600)
}

/// The same spin, on the path every launch takes: nothing has finished, so the countdown
/// answers 0 for the entire launch scan.
@Test func theSleepLengthIsAWholeIntervalDuringTheLaunchScan() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    #expect(await scheduler.secondsUntilDue(now: now) == 0)

    #expect(await scheduler.request(.launch, now: now))

    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(10)) == 6 * 3_600)
}

/// A clock that jumps backwards — an NTP correction, or the user changing the date — makes
/// the elapsed time negative. Unclamped, the loop is told to sleep for longer than the
/// interval: a week-long jump would mean a week with no background scan.
@Test func aBackwardsClockNeverAsksForMoreThanOneInterval() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(-7 * 86_400))
        == 6 * 3_600)
}

// MARK: - recovering from a scan that never reports a finish

/// A scan that fails on a path where the caller returns without calling `finished` would
/// otherwise leave `isRunning` true for the rest of the session: every request refused,
/// while the countdown still reaches zero, so the loop spins and never scans.
@Test func aScanThatNeverReportsAFinishCanBeAbandoned() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)
    _ = await scheduler.request(.manual, now: now.addingTimeInterval(60))
    _ = await scheduler.request(.manual, now: now.addingTimeInterval(70))

    await scheduler.abandonScan()

    #expect(await scheduler.queued == nil)
    // No finish was recorded: the countdown still runs from the scan that really completed,
    // so a failure cannot silence the background scan for a whole interval.
    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(80)) == 6 * 3_600 - 80)
    #expect(await scheduler.request(.manual, now: now.addingTimeInterval(90)))
}

/// The other way in, and the one the docs warn about: `finished` hands back a follow-up,
/// which already counts as running, and the caller does not start it.
@Test func aFollowUpTheCallerNeverStartedCanBeAbandoned() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.request(.manual, now: now)
    #expect(await scheduler.finished(at: now.addingTimeInterval(51)) == .manual)

    await scheduler.abandonScan()

    #expect(await scheduler.request(.manual, now: now.addingTimeInterval(60)))
}

@Test func aScanThatNobodyInterruptedLeavesNothingQueued() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.manual, now: now)

    #expect(await scheduler.finished(at: now.addingTimeInterval(51)) == nil)
    #expect(await scheduler.queued == nil)
}

@Test func anIntervalRequestWaitsForTheInterval() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(3_600))))
    #expect(await scheduler.request(.interval, now: now.addingTimeInterval(6 * 3_600)))
}

/// A manual rescan is the user asking now. It never waits for the interval.
@Test func aManualRequestIgnoresTheInterval() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    #expect(await scheduler.request(.manual, now: now.addingTimeInterval(60)))
}

@Test func theSleepLengthCountsDownFromTheLastFinishedScan() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    #expect(await scheduler.secondsUntilDue(now: now) == 0)

    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(3_600)) == 5 * 3_600)
    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(999_999)) == 0)
}

// MARK: - changing the interval in the running app

/// The gap can be changed while the app is running, and the countdown is **not** restarted
/// when it is.
///
/// Restarting it — which is what building a fresh `ScanScheduler` would do — throws away
/// `lastFinishedAt`, so the next thing the app does is agree to another launch scan: a full
/// ~51 seconds and four more `du` processes every time the user presses Save.
@Test func aShorterIntervalAppliesToTheNextDecisionWithoutRestartingTheCountdown() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)
    // Two hours in, six hours is not up.
    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(2 * 3_600))))

    await scheduler.setIntervalHours(1)

    // Still counting from the scan that finished at `now`: half an hour after it, half an
    // hour of the new hour is left. A countdown restarted by the change would answer a full
    // hour, and one cleared altogether would answer 0.
    #expect(await scheduler.secondsUntilDue(now: now.addingTimeInterval(1_800)) == 1_800)
    #expect(await scheduler.request(.interval, now: now.addingTimeInterval(2 * 3_600)))
}

/// The other direction, which a change that only ever shortens would get wrong while every
/// assertion above stayed green.
@Test func aLongerIntervalAppliesTheSameWay() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    await scheduler.setIntervalHours(12)

    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(6 * 3_600))))
    #expect(await scheduler.request(.interval, now: now.addingTimeInterval(12 * 3_600)))
}

/// The floor holds on the way in from the settings window too, not only at construction.
/// Zero there means "start another scan the moment this one ends", for ever.
@Test func anIntervalChangedToZeroIsStillTreatedAsOneHour() async {
    let scheduler = ScanScheduler(intervalHours: 6)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    await scheduler.setIntervalHours(0)

    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(1_800))))
    #expect(await scheduler.request(.interval, now: now.addingTimeInterval(3_600)))
}

/// A settings file naming 0 hours would spin a scan continuously, holding four `du`
/// processes open for ever.
@Test func anIntervalOfZeroIsTreatedAsOneHour() async {
    let scheduler = ScanScheduler(intervalHours: 0)
    _ = await scheduler.request(.launch, now: now)
    _ = await scheduler.finished(at: now)

    #expect(!(await scheduler.request(.interval, now: now.addingTimeInterval(60))))
    #expect(await scheduler.request(.interval, now: now.addingTimeInterval(3_600)))
}
