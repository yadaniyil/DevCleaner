import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

private let boardHome = "/Users/test"

/// `change` is where the user's clicks go. Left out, the ticks are the scan's own.
private func decisionHeader(
    _ items: [CleanupItem], availableBytes: Int64 = 219_000_000_000,
    skipped: [String] = [], ignoredRoots: [String] = [], age: TimeInterval = 7_200,
    change: (inout SelectionModel) -> Void = { _ in }
) -> DecisionHeaderModel {
    let result = makeResult(
        items, availableBytes: availableBytes, skipped: skipped, ignoredRoots: ignoredRoots)
    var selection = SelectionModel(result: result)
    change(&selection)
    return DecisionHeaderModel(
        result: result, selection: selection, now: now.addingTimeInterval(age),
        home: boardHome)
}

/// The amount is an upper bound and the prefix says so. A bare "58.0 GB" in large type is a
/// promise this tool cannot keep.
@Test func theBoardHeadlineIsAnUpperBoundAndSaysSo() {
    let model = decisionHeader([makeItem(id: "a", name: "DerivedData",
                                         sizeBytes: 58_000_000_000)])

    #expect(model.amountPrefix == "You can free up to")
    #expect(model.amountText == "58.0 GB")
}

/// The number is `selectedBytes` — the **top** of the honest range, never the bottom and never
/// the two ends added together. This needs a scan with shared bytes in it: on every other
/// fixture the three candidates print the same digits.
@Test func theBoardHeadlineNumberIsTheTopOfTheRange() {
    let model = decisionHeader([
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 1_830_000_000,
                 sizeMayBeShared: true),
        makeItem(id: "rest", name: "DerivedData", sizeBytes: 56_170_000_000),
    ])

    // 58.0 GB is the top. The bottom prints "56.2 GB" and the sum prints "59.8 GB".
    #expect(model.amountText == "58.0 GB")
}

/// With nothing shared the caption is one sentence, and it is still there.
///
/// Present on every scan rather than appearing only when something is shared: a second line
/// that comes and goes moves the whole board up and down as the user ticks the pnpm store.
@Test func theCaptionIsOneSentenceWhenNothingIsShared() {
    let model = decisionHeader([makeItem(id: "a", name: "DerivedData",
                                         sizeBytes: 58_000_000_000)])

    #expect(model.captionText == "That's everything ticked below.")
}

/// With shared bytes it grows the clause that keeps the number honest.
///
/// The whole sentence, not a `contains` check on the two sizes. The clause is the only place
/// this screen admits that the pnpm store and the bun cache may share blocks with
/// `node_modules` that are staying — and "at least 56.2 GB comes back for sure" and "56.2 GB
/// may be shared" are the same two numbers saying opposite things.
@Test func theCaptionAdmitsTheSharedBytesWhenThereAreAny() {
    let model = decisionHeader([
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 1_830_000_000,
                 sizeMayBeShared: true),
        makeItem(id: "rest", name: "DerivedData", sizeBytes: 56_170_000_000),
    ])

    #expect(model.captionText == "That's everything ticked below. At least 56.2 GB of it "
        + "comes back for sure — 1.8 GB may be shared with files that are staying.")
}

/// The clause follows the ticks. Untick the only shared row and the admission goes with it,
/// or the header keeps conceding 1.8 GB of a total that no longer contains it.
@Test func theSharedClauseGoesWhenTheSharedRowIsUnticked() {
    let rows = [
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 1_830_000_000,
                 sizeMayBeShared: true),
        makeItem(id: "rest", name: "DerivedData", sizeBytes: 56_170_000_000),
    ]
    let unticked = decisionHeader(rows) { $0.setTicked(false, for: "pnpm") }

    #expect(unticked.amountText == "56.2 GB")
    #expect(unticked.captionText == "That's everything ticked below.")
}

@Test func theBoardHeaderShowsFreeSpaceAndTheAgeOfTheScan() {
    let model = decisionHeader([], availableBytes: 219_000_000_000, age: 7_200)

    #expect(model.freeSpaceText == "219.0 GB free")
    #expect(model.scanAgeText == "scanned 2h ago")
}

/// Free space and the age are **not** selection-dependent and must not start following the
/// ticks along with everything else: the disk has not changed and nothing was measured again.
@Test func freeSpaceAndTheScanAgeStayWithTheScanOnTheBoard() {
    let model = decisionHeader(
        [makeItem(id: "a", name: "DerivedData", sizeBytes: 58_000_000_000)], age: 7_200
    ) { $0.setTicked(false, for: "a") }

    #expect(model.amountText == "0 KB")
    #expect(model.freeSpaceText == "219.0 GB free")
    #expect(model.scanAgeText == "scanned 2h ago")
}

// MARK: - the tier split bar

/// The two solid segments are the two deletable columns' own totals, so a segment of the bar
/// and the number at the top of the column below it cannot disagree.
@Test func theSplitBarSegmentsAreTheColumnTotals() {
    let items = [
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 10_000_000_000,
                 sizeMayBeShared: true),
    ]
    let model = decisionHeader(items)

    #expect(model.safeBytes == 30_000_000_000)
    #expect(model.thinkTwiceBytes == 10_000_000_000)
    #expect(model.safeSizeText == "30.0 GB")
    #expect(model.thinkTwiceSizeText == "10.0 GB")
    #expect(model.amountText == "40.0 GB")
}

/// The dashed segment is in the same bar as the two solid ones, and every fraction is a share
/// of all three.
///
/// Divided by the ticked total alone, the unticked segment is wider than the whole bar
/// whenever more is left than taken — which a default scan with a big NDK on it is. Here
/// 30 GB safe, 10 GB think-twice and 10 GB unticked make 50 GB on the table: 0.6, 0.2, 0.2.
@Test func theSplitBarFractionsIncludeTheUntickedSegment() {
    let model = decisionHeader([
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 10_000_000_000,
                 sizeMayBeShared: true),
        makeItem(id: "ndk", name: "27.0.12077973", sizeBytes: 10_000_000_000,
                 risk: .elevated, startsUnticked: true),
    ])

    #expect(model.untickedBytes == 10_000_000_000)
    #expect(model.untickedSizeText == "10.0 GB")
    #expect(abs(model.safeFraction - 0.6) < 0.0001)
    #expect(abs(model.thinkTwiceFraction - 0.2) < 0.0001)
    #expect(abs(model.untickedFraction - 0.2) < 0.0001)
    let whole = model.safeFraction + model.thinkTwiceFraction + model.untickedFraction
    #expect(abs(whole - 1.0) < 0.0001)
}

/// Unticking a row moves it from a solid segment into the dashed one, and the bar stays one
/// width. Nothing leaves the table by being unticked — it is still offered.
@Test func untickingARowMovesItFromItsColumnIntoTheUntickedSegment() {
    let items = [
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 10_000_000_000,
                 sizeMayBeShared: true),
    ]
    let model = decisionHeader(items) { $0.setTicked(false, for: "derived") }

    #expect(model.safeBytes == 0)
    #expect(model.thinkTwiceBytes == 10_000_000_000)
    #expect(model.untickedBytes == 30_000_000_000)
    #expect(abs(model.safeFraction - 0.0) < 0.0001)
    #expect(abs(model.thinkTwiceFraction - 0.25) < 0.0001)
    #expect(abs(model.untickedFraction - 0.75) < 0.0001)
}

/// Protected bytes are in no segment at all. They are not offered, so they are not on the
/// table, and giving them width would say a clean might take them.
@Test func protectedBytesAreInNoSegmentOfTheSplitBar() {
    let model = decisionHeader([
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "project", group: .projects, name: "sample-project",
                 sizeBytes: 46_880_000_000, protection: .recentActivity(days: 14)),
    ])

    #expect(model.safeBytes == 30_000_000_000)
    #expect(model.thinkTwiceBytes == 0)
    #expect(model.untickedBytes == 0)
    #expect(abs(model.safeFraction - 1.0) < 0.0001)
}

/// A machine with nothing on the table must not divide by zero. Unguarded, all three
/// fractions are `nan` and SwiftUI draws them at whatever width it likes.
@Test func aBoardWithNothingOnTheTableHasNoBar() {
    let empty = decisionHeader([])
    #expect(empty.safeFraction == 0)
    #expect(empty.thinkTwiceFraction == 0)
    #expect(empty.untickedFraction == 0)
    #expect(empty.amountText == "0 KB")

    // Not only the empty scan: a board of protected rows is just as empty of offers, and it
    // is the case a `result.items.isEmpty` guard would miss.
    let allKept = decisionHeader([
        makeItem(id: "project", name: "sample-project", sizeBytes: 46_880_000_000,
                 protection: .pinnedProject),
    ])
    #expect(allKept.safeFraction == 0)
    #expect(allKept.untickedFraction == 0)
}

// MARK: - the legend under the bar

/// The legend's third entry carries the same size the dashed segment is worth, through
/// `ByteText.short` like every other size on screen.
@Test func theUntickedLegendEntryCarriesTheSizeOfTheSegmentItLabels() {
    let model = decisionHeader([
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "ndk", name: "27.0.12077973", sizeBytes: 10_000_000_000,
                 risk: .elevated, startsUnticked: true),
    ])

    #expect(model.untickedLegendSizeText == "10.0 GB")
    #expect(model.untickedLegendSizeText == model.untickedSizeText)
}

/// Nothing unticked, no entry — `nil` rather than "0 KB". `TierSplitBar` draws no zero-width
/// block, so an entry here would be a colour key to a segment nobody can see.
@Test func theUntickedLegendEntryIsAbsentWhenNothingIsLeftUnticked() {
    let everythingTicked = decisionHeader([
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 58_000_000_000),
    ])
    #expect(everythingTicked.untickedBytes == 0)
    #expect(everythingTicked.untickedLegendSizeText == nil)

    // A board of protected rows is just as empty of offers, and it is the case a
    // `result.items.isEmpty` guard would miss.
    let allKept = decisionHeader([
        makeItem(id: "project", group: .projects, name: "sample-project",
                 sizeBytes: 46_880_000_000, protection: .pinnedProject),
    ])
    #expect(allKept.untickedLegendSizeText == nil)
}

/// Absent at zero and present at one kilobyte: the entry follows whether anything is offered,
/// never whether the offer is worth mentioning. A row too small to round up is still a row the
/// user can tick, and the bar already gives it a segment.
@Test func theUntickedLegendEntryAppearsAtTheFirstUntickedByte() {
    let model = decisionHeader([
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "crumb", name: "crumb", sizeBytes: 1_000, startsUnticked: true),
    ])

    #expect(model.untickedBytes == 1_000)
    #expect(model.untickedLegendSizeText == "1 KB")
}

/// The entry follows the ticks, like every other number on this header. Untick the lot and the
/// legend gains its third entry; tick the lot and it loses it again.
@Test func theUntickedLegendEntryFollowsTheTicks() {
    let items = [makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000)]

    #expect(decisionHeader(items).untickedLegendSizeText == nil)
    let unticked = decisionHeader(items) { $0.setTicked(false, for: "derived") }
    #expect(unticked.untickedLegendSizeText == "30.0 GB")
}

/// Every group, in the order the popover lists the same five — not the order they happen to
/// appear on the board, which sorts by size and by decision.
///
/// All five on every scan, including groups that contributed nothing: it is a key to the
/// colours the dots are drawn in, not a summary of what was found, and an entry that vanished
/// as a machine got cleaner would leave a dot on screen with nothing explaining it.
@Test func theGroupLegendNamesEveryGroupInTheOrderTheSectionsUse() {
    let model = decisionHeader([makeItem(id: "a", name: "DerivedData")])

    #expect(model.groupLegend.map(\.id) == GroupID.allCases)
    #expect(model.groupLegend.map(\.title) == GroupID.allCases.map(\.title))
    #expect(model.groupLegend.count == 5)
    // The names are the sections' own, so the key and the popover cannot come to call one
    // group two things.
    #expect(model.groupLegend.first?.title == GroupID.xcodeAndIOS.title)

    let empty = decisionHeader([])
    #expect(empty.groupLegend.map(\.id) == GroupID.allCases)
}

// MARK: - problems

/// The same two sentences, in the same order, as the popover's header — because they are the
/// popover header's own function and not a second copy of the rule.
@Test func theBoardHeaderNamesTheSameProblemsAsThePopoverHeader() {
    let items = [makeItem(id: "a", name: "DerivedData")]
    let result = makeResult(
        items, skipped: ["flutter.pubCache"], ignoredRoots: ["/Users/test/dev"])
    let selection = SelectionModel(result: result)
    let board = DecisionHeaderModel(
        result: result, selection: selection, now: now, home: boardHome)
    let popover = HeaderModel(
        result: result, selection: selection, now: now, home: boardHome)

    #expect(board.problems == [
        "Ignored, too wide to be a project root: ~/dev",
        "Switched off in settings: flutter.pubCache",
    ])
    #expect(board.problems == popover.problems)
}

@Test func aCleanScanHasNoProblems() {
    #expect(decisionHeader([makeItem(id: "a", name: "DerivedData")]).problems.isEmpty)
}

// MARK: - the model the view actually hands over

@MainActor
@Test func theBoardHeaderComesFromTheModelsOwnClock() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult(
        [makeItem(id: "a", name: "DerivedData", sizeBytes: 58_000_000_000)],
        generatedAt: now.addingTimeInterval(-7_200)))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: boardHome, clock: { now })

    let header = try #require(model.decisionHeader)
    #expect(header.amountText == "58.0 GB")
    #expect(header.scanAgeText == "scanned 2h ago")
    // The selection is wired in, or the amount could not follow a click.
    model.setTicked(false, for: "a")
    #expect(try #require(model.decisionHeader).amountText == "0 KB")
}
