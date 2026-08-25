import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

private let home = "/Users/test"

/// `change` is where the user's clicks go. Left out, the ticks are the scan's own — which
/// is the state every test written before the header followed the selection was about.
private func header(
    _ items: [CleanupItem], availableBytes: Int64 = 219_000_000_000,
    skipped: [String] = [], ignoredRoots: [String] = [], age: TimeInterval = 7_200,
    change: (inout SelectionModel) -> Void = { _ in }
) -> HeaderModel {
    let result = makeResult(
        items, availableBytes: availableBytes, skipped: skipped, ignoredRoots: ignoredRoots)
    var selection = SelectionModel(result: result)
    change(&selection)
    return HeaderModel(
        result: result, selection: selection, now: now.addingTimeInterval(age), home: home)
}

/// `reclaimableBytes` is the most a default clean can remove, not a promise. The headline
/// therefore begins "up to" and never says "freed".
@Test func theHeadlineIsAnUpperBoundAndSaysSo() {
    let model = header([makeItem(id: "a", sizeBytes: 58_000_000_000)])

    #expect(model.amountPrefix == "up to")
    #expect(model.amountText == "58.0 GB")
}

/// The big number is `reclaimableBytes` itself — the **top** of the range, never the
/// bottom and never the two added together.
///
/// This needs a scan with shared bytes in it, and it is the only test here that has one
/// and looks at `amountText`. On every other fixture `possiblySharedBytes` is zero, so
/// `top`, `top - shared` and `top + shared` are the same number and print the same digits:
/// the headline could be showing any of the three and nothing would say so. Showing the
/// bottom is the exact inversion of the rule this whole model exists for — it would read
/// "up to 56.2 GB" while the tool is about to remove 58.0 GB, and a user who checks the
/// arithmetic afterwards finds the app understated by 1.8 GB rather than overstated.
@Test func theHeadlineNumberIsTheTopOfTheRangeAndNotTheBottom() {
    let model = header([
        makeItem(id: "pnpm", sizeBytes: 1_830_000_000, sizeMayBeShared: true),
        makeItem(id: "rest", sizeBytes: 56_170_000_000),
    ])

    #expect(model.amountPrefix == "up to")
    // 58.0 GB is `top`. The bottom prints "56.2 GB" and the sum prints "59.8 GB", so all
    // three candidates are told apart by this one line.
    #expect(model.amountText == "58.0 GB")
}

@Test func theRangeAppearsOnlyWhenSomeOfTheBytesMayBeShared() {
    let plain = header([makeItem(id: "a", sizeBytes: 58_000_000_000)])
    #expect(plain.rangeText == nil)

    let shared = header([
        makeItem(id: "pnpm", sizeBytes: 1_830_000_000, sizeMayBeShared: true),
        makeItem(id: "rest", sizeBytes: 56_170_000_000),
    ])
    // The whole string, not three `contains` checks. The low end must come first: the
    // ends pinned only by substring let "58.0 GB – 56.2 GB" through, a backwards range
    // that reads as nonsense in the one place the honest lower bound is printed.
    #expect(shared.rangeText == "56.2 GB – 58.0 GB, because 1.8 GB of it may be shared "
        + "with files that are staying")
}

/// The hover text is the engine's own sentence, so the popover and `devcleaner scan`
/// cannot describe one scan two different ways.
@Test func theHeadlineHelpIsTheEnginesSentence() {
    let result = makeResult([makeItem(id: "a", sizeBytes: 58_000_000_000)])
    let model = HeaderModel(
        result: result, selection: SelectionModel(result: result), now: now, home: home)

    #expect(model.headlineHelp == ReportText.headline(result))
    #expect(model.headlineHelp.hasPrefix("up to "))
}

/// The same rule, on the scan the engine's sentence was written for.
///
/// `theHeadlineHelpIsTheEnginesSentence` alone does not hold anyone to it: with no shared
/// bytes `ReportText.headline` is exactly "up to 58.0 GB", so a hand-written
/// `"up to \(amountText)"` satisfies it while silently dropping the clause that admits
/// 1.8 GB of the number may never come back. Pinning the whole sentence is deliberate —
/// it is the sentence, not the call, that the user reads.
@Test func theHeadlineHelpKeepsTheEnginesSharedSentence() {
    let result = makeResult([
        makeItem(id: "pnpm", sizeBytes: 1_830_000_000, sizeMayBeShared: true),
        makeItem(id: "rest", sizeBytes: 56_170_000_000),
    ])
    let model = HeaderModel(
        result: result, selection: SelectionModel(result: result), now: now, home: home)

    #expect(model.headlineHelp == ReportText.headline(result))
    #expect(model.headlineHelp == "up to 58.0 GB — really 56.2 GB to 58.0 GB, because "
        + "1.8 GB of it may be shared with files that are staying")
}

@Test func theHeaderShowsFreeSpaceAndTheAgeOfTheScan() {
    let model = header([], availableBytes: 219_000_000_000, age: 7_200)

    #expect(model.freeSpaceText == "219.0 GB free")
    #expect(model.scanAgeText == "scanned 2h ago")
}

/// Free space is what is free **now**, and the scan that produced it removed nothing.
///
/// `theHeaderShowsFreeSpaceAndTheAgeOfTheScan` scans an empty machine, where the headline
/// is zero and every arithmetic on it comes out the same — so it cannot tell "219.0 GB
/// free" apart from "219.0 GB free once you clean". This one can: the two differ by the
/// 58.0 GB the popover is offering to remove.
@Test func theFreeSpaceLineIsTheSpaceOnTheDiskNow() {
    let model = header(
        [makeItem(id: "a", sizeBytes: 58_000_000_000)], availableBytes: 219_000_000_000)

    #expect(model.freeSpaceText == "219.0 GB free")
}

@Test func theUntickedLineAppearsOnlyWhenSomethingIsOfferedUnticked() {
    let none = header([makeItem(id: "a", sizeBytes: 1_000_000_000)])
    #expect(none.untickedText == nil)

    let some = header([
        makeItem(id: "a", sizeBytes: 1_000_000_000),
        makeItem(id: "ndk", sizeBytes: 5_570_000_000, startsUnticked: true),
    ])
    // The whole sentence. "offered but not ticked" and "offered and ticked" differ by one
    // word and say opposite things about what the Clean button is about to do, and a
    // `contains("5.6 GB")` check cannot tell them apart.
    #expect(some.untickedText == "5.6 GB more is offered but not ticked")
    // The headline is the ticked 1.0 GB alone. Pinned rather than merely checked for the
    // absence of "6.6", so that any other wrong number is caught as well.
    #expect(some.amountText == "1.0 GB")
}

/// "Offered" means the user can tick it. A kept row cannot be ticked at all, so its bytes
/// belong to neither line.
///
/// The two are not mutually exclusive in the model and are not exclusive in practice:
/// `AVDScanner` sets `startsUnticked` from whether `du` measured the emulator and
/// `protection` from when it was last used, so an emulator used this week that `du` could
/// not measure carries both. `untickedDeletableBytes` already excludes it; a hand-written
/// sum over `startsUnticked` does not, and offers the user bytes the popover will refuse
/// to let them tick.
@Test func aRowThatIsKeptIsNeverCountedAsOffered() {
    let model = header([
        makeItem(id: "a", sizeBytes: 1_000_000_000),
        makeItem(id: "recent-avd", sizeBytes: 8_000_000_000,
                 protection: .recentlyUsedDevice(days: 7), startsUnticked: true),
    ])

    #expect(model.untickedText == nil)
}

// MARK: - the header follows the user's ticks

/// One scan for the three tests below, with sizes chosen so that every figure they assert
/// prints its own digits. 30.0, 19.0 and 5.0 GB give 49.0 GB ticked by default, 24.0 GB of
/// Android once the NDK is ticked and 54.0 GB in total — six different strings, none of
/// which a wrong quantity could produce by accident.
private let threeRows = [
    makeItem(id: "derived", group: .xcodeAndIOS, sizeBytes: 30_000_000_000),
    makeItem(id: "emulator", group: .android, sizeBytes: 19_000_000_000),
    makeItem(id: "ndk", group: .android, sizeBytes: 5_000_000_000, startsUnticked: true),
]

/// Scenario A of the review finding. The user unticks the 19.0 GB emulator: the group
/// headline and the Clean button drop it, and so must the amount, the bar and the line that
/// says what is left on the table.
///
/// Built from the scan instead, the header reads `up to 49.0 GB` with the Android block at
/// full width over a section whose own headline now says 0 KB — one screen, two numbers,
/// disagreeing.
@Test func untickingARowMovesTheAmountTheBarAndTheOfferedLine() throws {
    let untouched = header(threeRows)
    #expect(untouched.amountText == "49.0 GB")
    #expect(untouched.segments.map(\.id) == [.xcodeAndIOS, .android])
    let androidBlock = try #require(untouched.segments.last)
    let android: Int64 = androidBlock.bytes
    #expect(android == 19_000_000_000)
    #expect(untouched.untickedText == "5.0 GB more is offered but not ticked")

    let unticked = header(threeRows) { $0.setTicked(false, for: "emulator") }

    #expect(unticked.amountText == "30.0 GB")
    // The Android block goes altogether: a sliver there would say the popover is about to
    // remove something from a group it will not touch.
    #expect(unticked.segments.map(\.id) == [.xcodeAndIOS])
    // 19.0 GB of emulator joins the 5.0 GB of NDK. "Offered and not ticked" is what the row
    // is now, whoever unticked it.
    #expect(unticked.untickedText == "24.0 GB more is offered but not ticked")
}

/// Scenario B, the worse one: the sentence inverts.
///
/// The user ticks the Android NDK. Built from the scan, `5.0 GB more is offered but not
/// ticked` stays on screen while the button below says `Clean 54.0 GB` — the sentence says
/// the opposite of what pressing it will do.
@Test func tickingTheRowThatStartsUntickedTakesTheOfferedLineAway() throws {
    let ticked = header(threeRows) { $0.setTicked(true, for: "ndk") }

    #expect(ticked.untickedText == nil)
    #expect(ticked.amountText == "54.0 GB")
    let androidBlock = try #require(ticked.segments.last)
    let android: Int64 = androidBlock.bytes
    #expect(android == 24_000_000_000)
}

/// The honest range goes with the amount, or the two ends stop matching the number printed
/// between them.
///
/// The pnpm store is the only row here whose bytes may be shared. Unticking it takes the
/// whole clause away; left on `ScanResult.possiblySharedBytes` the header would go on
/// admitting that 1.8 GB of a total which no longer contains it may be shared, and print an
/// upper end of 58.0 GB above a headline reading 56.2 GB.
@Test func theSharedRangeFollowsTheTicksAsWell() {
    let rows = [
        makeItem(id: "pnpm", sizeBytes: 1_830_000_000, sizeMayBeShared: true),
        makeItem(id: "rest", sizeBytes: 56_170_000_000),
    ]
    let untouched = header(rows)
    #expect(untouched.amountText == "58.0 GB")
    #expect(untouched.rangeText == "56.2 GB – 58.0 GB, because 1.8 GB of it may be shared "
        + "with files that are staying")

    let unticked = header(rows) { $0.setTicked(false, for: "pnpm") }

    #expect(unticked.amountText == "56.2 GB")
    #expect(unticked.rangeText == nil)
}

/// The engine's hover sentence describes the scan's own default tick, so it is served only
/// while the ticks still are that.
///
/// Untick the 19.0 GB emulator and the header reads `up to 30.0 GB`; the sentence still says
/// `up to 49.0 GB`, because `ReportText.headline` totals `selectedByDefault` and cannot see a
/// click. One number explaining another and contradicting it is worse than no sentence, so
/// there is no sentence — the engine's wording is never rewritten here, and never rebuilt
/// from the ticked rows, which would put a hand-ticked row back through the same rule that
/// left it out.
@Test func theHoverSentenceIsWithheldOnceTheUserChangesATick() {
    let untouched = header(threeRows)
    #expect(untouched.headlineHelp == "up to 49.0 GB")

    let unticked = header(threeRows) { $0.setTicked(false, for: "emulator") }
    #expect(unticked.amountText == "30.0 GB")
    #expect(unticked.headlineHelp.isEmpty)

    // Ticking a row that started unticked is a change too, in the direction the sentence
    // understates rather than overstates. It is withheld either way.
    let ticked = header(threeRows) { $0.setTicked(true, for: "ndk") }
    #expect(ticked.amountText == "54.0 GB")
    #expect(ticked.headlineHelp.isEmpty)

    // Put the tick back and the sentence comes back with it. Without this line a model that
    // withheld the sentence for ever, from the first click on, would pass everything above.
    let restored = header(threeRows) {
        $0.setTicked(false, for: "emulator")
        $0.setTicked(true, for: "emulator")
    }
    #expect(restored.headlineHelp == "up to 49.0 GB")
}

/// Free space and the age of the scan are **not** selection-dependent, and must not start
/// following the ticks along with everything else. Neither moves when a box is clicked:
/// the disk has not changed and nothing has been measured again.
@Test func freeSpaceAndTheScanAgeStayWithTheScan() {
    let unticked = header(threeRows, age: 7_200) {
        $0.setTicked(false, for: "emulator")
        $0.setTicked(false, for: "derived")
    }

    #expect(unticked.amountText == "0 KB")
    #expect(unticked.freeSpaceText == "219.0 GB free")
    #expect(unticked.scanAgeText == "scanned 2h ago")
}

@Test func theBarSegmentsAreProportionalToWhatEachGroupContributes() throws {
    let model = header([
        makeItem(id: "x", group: .xcodeAndIOS, sizeBytes: 30_000_000_000),
        makeItem(id: "a", group: .android, sizeBytes: 10_000_000_000),
    ])

    #expect(model.segments.map(\.id) == [.xcodeAndIOS, .android])
    let first = try #require(model.segments.first)
    #expect(abs(first.fraction - 0.75) < 0.0001)
    #expect(abs(model.segments.reduce(0.0) { $0 + $1.fraction } - 1.0) < 0.0001)
    let bytes: Int64 = first.bytes
    #expect(bytes == 30_000_000_000)
    #expect(first.title == "Xcode & iOS")
}

/// The block's hover text. In the model rather than in the view, so the size goes through
/// `ByteText.short` like every other size on screen and the pairing of group to amount is
/// pinned somewhere a test can reach.
@Test func aBarBlockSaysWhichGroupItIsAndWhatItHolds() throws {
    let model = header([
        makeItem(id: "x", group: .xcodeAndIOS, sizeBytes: 30_000_000_000),
        makeItem(id: "a", group: .android, sizeBytes: 10_000_000_000),
    ])

    let first = try #require(model.segments.first)
    #expect(first.helpText == "Xcode & iOS: 30.0 GB")
    let second = try #require(model.segments.last)
    #expect(second.helpText == "Android: 10.0 GB")
}

/// The blocks are in `GroupID.allCases` order — the order `GroupList.sections` draws the
/// sections in, directly below the bar.
///
/// Not biggest first. Every other bar test here happens to list its groups biggest first
/// as well, so nothing else can tell the two rules apart. Sorted by size, the widest block
/// sits above whichever section came first, and the user reads a block against the wrong
/// heading.
@Test func theBarKeepsTheGroupOrderOfTheListBelowIt() {
    let model = header([
        makeItem(id: "x", group: .xcodeAndIOS, sizeBytes: 10_000_000_000),
        makeItem(id: "a", group: .android, sizeBytes: 30_000_000_000),
    ])

    #expect(model.segments.map(\.id) == [.xcodeAndIOS, .android])
}

/// The blocks are shares of the sum of the blocks, not shares of `reclaimableBytes`.
///
/// The two totals agree on every scan today, and stop agreeing the moment one deletion
/// target appears in two groups: `reclaimableBytes` counts that target once, while each
/// group's own total counts it again. Dividing by the headline would then draw a bar two
/// widths long, which the user sees as blocks running off the end of the popover.
@Test func theBarBlocksAddUpToOneWidthWhenTwoGroupsNameOneTarget() throws {
    let model = header([
        makeItem(id: "x", group: .xcodeAndIOS, sizeBytes: 10_000_000_000,
                 method: .removePath("/tmp/shared")),
        makeItem(id: "a", group: .android, sizeBytes: 10_000_000_000,
                 method: .removePath("/tmp/shared")),
    ])

    #expect(model.segments.map(\.id) == [.xcodeAndIOS, .android])
    #expect(abs(model.segments.reduce(0.0) { $0 + $1.fraction } - 1.0) < 0.0001)
    let first = try #require(model.segments.first)
    #expect(abs(first.fraction - 0.5) < 0.0001)
}

@Test func aGroupThatContributesNothingIsLeftOutOfTheBar() {
    let model = header([
        makeItem(id: "x", group: .xcodeAndIOS, sizeBytes: 30_000_000_000),
        makeItem(id: "kept", group: .projects, sizeBytes: 46_880_000_000,
                 protection: .recentActivity(days: 14)),
    ])

    #expect(model.segments.map(\.id) == [.xcodeAndIOS])
}

/// The bar is drawn from `selectedByDefault`, **never** from `isDeletable`.
///
/// The Android NDK is deletable and deliberately unticked. A bar built from `isDeletable`
/// gives it 5.57 GB of width, so the user reads a block that a default clean will not
/// touch — and every other test here still passes, because the only other place the two
/// values differ is a protected row, which `isDeletable` already excludes.
@Test func theBarLeavesOutBytesThatAreOfferedButNotTicked() throws {
    let model = header([
        makeItem(id: "x", group: .xcodeAndIOS, sizeBytes: 30_000_000_000),
        makeItem(id: "ndk", group: .android, sizeBytes: 5_570_000_000, startsUnticked: true),
    ])

    #expect(model.segments.map(\.id) == [.xcodeAndIOS])
    let only = try #require(model.segments.first)
    let bytes: Int64 = only.bytes
    #expect(bytes == 30_000_000_000)
    #expect(abs(only.fraction - 1.0) < 0.0001)
}

/// A machine with nothing to clean must not divide by zero.
@Test func aScanWithNothingTickedHasNoSegments() {
    let model = header([])

    #expect(model.segments.isEmpty)
    #expect(model.amountText == "0 KB")
}

/// The whole line, label included.
///
/// The label is the entire point of the line: "your setting was refused" and "you switched
/// this off" are different pieces of news and the user acts differently on each. Asserting
/// only that the path appears somewhere lets the two labels be swapped, and an ignored
/// root announced as "Switched off in settings: ~" sends the user to a settings screen to
/// turn something back on that was never off.
@Test func anIgnoredProjectRootIsReportedAsAProblem() {
    let model = header([], ignoredRoots: ["/Users/test"])

    #expect(model.problems == ["Ignored, too wide to be a project root: ~"])
}

@Test func aScannerSwitchedOffInSettingsIsReportedAsAProblem() {
    let model = header([], skipped: ["flutter.pubCache", "android.gradle"])

    #expect(model.problems == ["Switched off in settings: flutter.pubCache, android.gradle"])
}

/// Both kinds at once, with the refusal first.
///
/// Neither single-problem test can see the order, and the order is a judgement: an ignored
/// root is something the engine **refused** to do, so a whole area of the disk went
/// unmeasured and every number above is missing whatever lives there. A switched-off
/// scanner is the user's own decision, working as asked. The surprise goes first.
@Test func bothKindsOfProblemAreListedWithTheRefusalFirst() {
    let model = header(
        [], skipped: ["flutter.pubCache"], ignoredRoots: ["/Users/test/dev"])

    #expect(model.problems == [
        "Ignored, too wide to be a project root: ~/dev",
        "Switched off in settings: flutter.pubCache",
    ])
}
