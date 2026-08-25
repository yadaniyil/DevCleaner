import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

private func groups(
    _ items: [CleanupItem], expanded: Set<GroupID> = [],
    change: (inout SelectionModel) -> Void = { _ in }
) -> [PopoverGroup] {
    let result = makeResult(items)
    var selection = SelectionModel(result: result)
    change(&selection)
    return PopoverBodyModel.groups(
        result: result, selection: selection, expanded: expanded,
        home: "/Users/test", projectRoots: ["/Users/test/dev"])
}

/// Spec §8.2: five groups, collapsed by default.
@Test func everyGroupIsPresentAndCollapsedByDefault() {
    let all = groups([makeItem(id: "a", group: .android)])

    #expect(all.map(\.id) == GroupID.allCases)
    #expect(all.allSatisfy { !$0.isExpanded })
    #expect(all.allSatisfy { $0.rows.isEmpty })
}

@Test func anExpandedGroupCarriesItsRowsBiggestFirst() throws {
    let all = groups([
        makeItem(id: "small", group: .android, sizeBytes: 1_000_000_000),
        makeItem(id: "big", group: .android, sizeBytes: 19_000_000_000),
    ], expanded: [.android])
    let android = try #require(all.first { $0.id == .android })

    #expect(android.isExpanded)
    #expect(android.rows.map(\.id) == ["big", "small"])
}

@Test func onlyTheExpandedGroupCarriesRows() throws {
    let all = groups([
        makeItem(id: "a", group: .android),
        makeItem(id: "p", group: .projects),
    ], expanded: [.android])

    #expect(try #require(all.first { $0.id == .android }).rows.count == 1)
    #expect(try #require(all.first { $0.id == .projects }).rows.isEmpty)
}

@Test func eachRowArrivesWithItsOwnTickState() throws {
    let all = groups([
        makeItem(id: "on", group: .android),
        makeItem(id: "off", group: .android),
        makeItem(id: "kept", group: .android, protection: .pinnedDevice),
    ], expanded: [.android]) { selection in
        selection.setTicked(false, for: "off")
    }
    let android = try #require(all.first { $0.id == .android })

    #expect(android.rows.first { $0.id == "on" }?.tick == .all)
    #expect(android.rows.first { $0.id == "off" }?.tick == GroupTick.none)
    #expect(android.rows.first { $0.id == "kept" }?.tick == GroupTick.none)
    #expect(android.rows.first { $0.id == "kept" }?.isEnabled == false)
    // Both sides of `isEnabled`. With only the false case pinned, a passthrough returning
    // a constant `false` passes the suite and greys out every row in the popover, so
    // nothing can be ticked or unticked at all.
    #expect(android.rows.first { $0.id == "on" }?.isEnabled == true)
}

@Test func theGroupBoxShowsMixedWhenPartOfItIsTicked() throws {
    let all = groups([
        makeItem(id: "a", group: .android),
        makeItem(id: "b", group: .android),
    ]) { selection in
        selection.setTicked(false, for: "a")
    }

    #expect(try #require(all.first { $0.id == .android }).tick == .some)
    // Which group the box is asked about. Hardcode `.android` in the model and every box
    // in the popover mirrors Android's; because `ticksOnClick` unticks a full box, a
    // Projects box wrongly reading `.all` empties the group the user meant to fill.
    #expect(try #require(all.first { $0.id == .projects }).tick == GroupTick.none)
}

@Test func aGroupHeadlineCountsRowsAndSizesOnlyWhatIsTicked() throws {
    let all = groups([
        makeItem(id: "a", group: .android, sizeBytes: 19_000_000_000),
        makeItem(id: "kept", group: .android, sizeBytes: 9_780_000_000,
                 protection: .mostRecentlyUsedDevice),
    ])

    #expect(try #require(all.first { $0.id == .android }).headline == "2 rows · 19.0 GB")
    #expect(try #require(all.first { $0.id == .projects }).headline == "0 rows · 0 KB")
}

@Test func aGroupWithOneRowSaysRowNotRows() throws {
    let all = groups([makeItem(id: "a", group: .android)])
    #expect(try #require(all.first { $0.id == .android }).headline.contains("1 row ·"))
}

/// An expanded group with nothing in it says so, rather than opening onto blank space.
@Test func anEmptyGroupHasASentenceInsteadOfRows() throws {
    let all = groups([], expanded: [.android])
    let android = try #require(all.first { $0.id == .android })

    #expect(android.rows.isEmpty)
    // The sentence itself, not only the constant: `emptyText == theConstant` passes if both
    // are `""`, which is an expanded group opening onto the blank space this line exists to
    // fill.
    #expect(PopoverBodyModel.nothingInThisGroup == "Nothing found in this group.")
    #expect(android.emptyText == PopoverBodyModel.nothingInThisGroup)
    // The other four are just as empty and are **collapsed**, so they say nothing. Without
    // this line, dropping `isExpanded` from the condition changes nothing any assertion
    // above can see, and a closed popover grows four sentences under five closed headers.
    #expect(all.filter { !$0.isExpanded }.allSatisfy { $0.emptyText == nil })

    let withRows = groups([makeItem(id: "a", group: .android)], expanded: [.android])
    #expect(try #require(withRows.first { $0.id == .android }).emptyText == nil)
}

/// Open and closed have to look different, and which symbol means which is a decision.
@Test func theChevronPointsDownOnlyWhileTheGroupIsOpen() throws {
    let all = groups([makeItem(id: "a", group: .android)], expanded: [.android])

    #expect(try #require(all.first { $0.id == .android }).chevronSymbolName == "chevron.down")
    #expect(try #require(all.first { $0.id == .projects }).chevronSymbolName == "chevron.right")
}

// MARK: - what the headline counts

/// The size beside a group follows the ticks, click by click.
///
/// `GroupSection.tickedSizeText` is the scan's **default** tick, frozen when
/// `GroupList.sections` ran. Reading it here leaves a group claiming 20.0 GB after the
/// user unticked 19 GB of it, while the Clean button one section below already says
/// 1.0 GB — two numbers on one screen, disagreeing.
@Test func theGroupHeadlineFollowsTheTicks() throws {
    let all = groups([
        makeItem(id: "big", group: .android, sizeBytes: 19_000_000_000),
        makeItem(id: "small", group: .android, sizeBytes: 1_000_000_000),
    ]) { selection in
        selection.setTicked(false, for: "big")
    }

    #expect(try #require(all.first { $0.id == .android }).headline == "2 rows · 1.0 GB")
}

/// The same de-duplicating rule as the headline above the list and the split below it.
/// A plain sum here would be a third answer to one question on a single screen.
@Test func aGroupCountsOneDirectoryOnceEvenWhenTwoRowsNameIt() throws {
    let path = "/Users/test/Library/Android/sdk/ndk"
    let all = groups([
        makeItem(id: "one", group: .android, sizeBytes: 3_000_000_000,
                 method: .removePath(path)),
        makeItem(id: "two", group: .android, sizeBytes: 3_000_000_000,
                 method: .removePath(path)),
    ])

    #expect(try #require(all.first { $0.id == .android }).headline == "2 rows · 3.0 GB")
}

/// No selection is not a half-drawn popover: every box is empty and every total is zero,
/// which is the one reading consistent with what those boxes show.
@Test func aBodyWithNoSelectionTicksNothing() throws {
    let all = PopoverBodyModel.groups(
        result: makeResult([makeItem(id: "a", group: .android, sizeBytes: 19_000_000_000)]),
        selection: nil, expanded: [.android], home: "/Users/test", projectRoots: [])
    let android = try #require(all.first { $0.id == .android })

    #expect(android.tick == GroupTick.none)
    #expect(android.rows.first?.tick == GroupTick.none)
    #expect(android.headline == "1 row · 0 KB")
}

// MARK: - what a row carries

/// Two representative protected Flutter projects are both named `shared-project-name`, both
/// 13.6 MB, with the same detail text. Without the path the popover offers the user two
/// identical lines and no way to tell which one it is about to delete.
@Test func twoRowsWithTheSameNameAreStillToldApartByTheirPath() throws {
    let all = groups([
        makeItem(id: "one", group: .projects, name: "shared-project-name", detail: "Flutter",
                 sizeBytes: 13_600_000, method: .removePath("/Users/test/dev/a/build")),
        makeItem(id: "two", group: .projects, name: "shared-project-name", detail: "Flutter",
                 sizeBytes: 13_600_000, method: .removePath("/Users/test/dev/b/build")),
    ], expanded: [.projects])
    let projects = try #require(all.first { $0.id == .projects })

    #expect(projects.rows.map(\.name) == ["shared-project-name", "shared-project-name"])
    #expect(projects.rows.map(\.detail) == ["Flutter", "Flutter"])
    #expect(projects.rows.map(\.sizeText) == ["14 MB", "14 MB"])
    #expect(projects.rows.map(\.target) == ["~/dev/a/build", "~/dev/b/build"])
}

/// The tags reach the view in the order it draws them. They are the only thing on the row
/// that says why 5.57 GB sits there unticked.
@Test func aRowCarriesItsTagsInTheOrderTheyAreDrawn() throws {
    let all = groups([
        makeItem(id: "ndk", group: .android, startsUnticked: true, sizeMayBeShared: true),
    ], expanded: [.android])

    let row = try #require(all.first { $0.id == .android }?.rows.first)
    #expect(row.tags == [.mayBeShared, .notTickedByDefault])
}

// MARK: - the model the view actually hands over

@MainActor
@Test func theConvenienceOverloadReadsEverythingFromTheModel() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([makeItem(id: "a", group: .android)]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })
    model.toggleExpanded(.android)

    let all = PopoverBodyModel.groups(from: model)
    #expect(try #require(all.first { $0.id == .android }).rows.map(\.id) == ["a"])
    // The selection, and the home and roots the title is built from. Each of the four
    // arguments this overload exists to assemble is visible in one of these three lines;
    // dropping any of them changes an answer here.
    #expect(try #require(all.first { $0.id == .android }).rows.first?.tick == .all)
    #expect(try #require(all.first { $0.id == .projects }).title == "Projects in ~/dev")

    let empty = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })
    #expect(PopoverBodyModel.groups(from: empty).isEmpty)
}
