import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

/// `change` is where the user's clicks go. Left out, the ticks are the scan's own.
///
/// Every fixture below names its rows explicitly, because `makeItem`'s defaults share one
/// `scannerID` and one `name` — which is exactly the pair this board collapses. Two rows left
/// on the defaults would arrive as one aggregate and quietly change what the test is about.
private func columns(
    _ items: [CleanupItem], expanded: Set<String> = [],
    change: (inout SelectionModel) -> Void = { _ in }
) -> [DecisionColumn] {
    let result = makeResult(items)
    var selection = SelectionModel(result: result)
    change(&selection)
    return DecisionBoardModel.columns(
        result: result, selection: selection, expanded: expanded, home: "/Users/test")
}

private func column(
    _ tier: DecisionTier, _ items: [CleanupItem], expanded: Set<String> = [],
    change: (inout SelectionModel) -> Void = { _ in }
) throws -> DecisionColumn {
    try #require(columns(items, expanded: expanded, change: change).first { $0.tier == tier })
}

/// Twelve projects, each with a `node_modules`, exactly as `ProjectBuildOutputScanner` emits
/// them: one `scannerID`, the relative folder as the name, the project's name as the detail.
/// `node_modules` is in that scanner's `networkRestored` set, so every one of these is
/// `.elevated` and the whole aggregate belongs in the think-twice column.
private func nodeModules(_ projects: [(String, Int64)]) -> [CleanupItem] {
    projects.map { name, size in
        makeItem(
            id: "projects.buildOutput|/Users/test/dev/\(name)/node_modules",
            scannerID: "projects.buildOutput", group: .projects,
            name: "node_modules", detail: name, sizeBytes: size, risk: .elevated,
            method: .removePath("/Users/test/dev/\(name)/node_modules"))
    }
}

// MARK: - which column a row lands in

/// The three columns are the three answers, in reading order: what the tool is confident
/// about, what it wants a second look at, what it will not touch.
@Test func theBoardIsThreeColumnsInDecisionOrder() {
    let all = columns([makeItem(id: "a", name: "DerivedData")])

    #expect(all.map(\.tier) == [.safe, .thinkTwice, .kept])
    #expect(all.map(\.title) == ["Safe to clean now", "Think twice", "Kept for you"])
    #expect(all[0].subtitle
        == "Comes back on its own — rebuilt or re-downloaded when it's next needed.")
    #expect(all[1].subtitle == "Removed permanently, or may not come back the way it was.")
    #expect(all[2].subtitle
        == "Running, newest, or recently used — never offered for cleaning.")
}

/// Deletable, to the Trash, ordinary risk, its bytes its own: the only combination that is
/// safe, and the one every other test here is measured against.
@Test func anOrdinaryDeletableRowIsSafe() {
    let item = makeItem(id: "derived", name: "DerivedData")
    #expect(item.decisionTier == .safe)
}

/// A simulator has no Trash whatever `Settings.moveToTrash` says — `simctl delete` destroys
/// the device directory outright — so it cannot sit under a heading promising the clean
/// comes back on its own.
@Test func aDeviceIsThinkTwiceBecauseItsRemovalIsPermanent() throws {
    let simulator = makeItem(
        id: "sim", group: .xcodeAndIOS, name: "iPhone 17 Pro", sizeBytes: 7_090_000_000,
        method: .deleteSimulator(udid: "AAA"))

    #expect(simulator.decisionTier == .thinkTwice)
    let thinkTwice = try column(.thinkTwice, [simulator])
    #expect(thinkTwice.rows.map(\.name) == ["iPhone 17 Pro"])
    #expect(thinkTwice.rows.first?.tags == [.permanent])
}

/// The Android NDK: 5.57 GB, offered unticked, and `.elevated` because it only comes back
/// over the network. The elevated risk is what moves it, not the unticked state — the two
/// arrive together on this row and are told apart by the test below.
@Test func theAndroidNDKIsThinkTwiceForItsRiskAndNotForItsTick() throws {
    let ndk = makeItem(
        id: "ndk", scannerID: "android.ndk", group: .android, name: "27.0.12077973",
        sizeBytes: 5_570_000_000, risk: .elevated, startsUnticked: true)

    #expect(ndk.decisionTier == .thinkTwice)
    let thinkTwice = try column(.thinkTwice, [ndk])
    #expect(thinkTwice.rows.map(\.name) == ["27.0.12077973"])
    #expect(thinkTwice.rows.first?.tick == GroupTick.none)
}

/// `startsUnticked` on its own is **not** a reason to move a row.
///
/// It means "the user has to ask for it", not "getting it back is expensive", and every
/// scanner sets it for a row `du` could not measure. Treating it as a rule would file a
/// perfectly ordinary unmeasured cache beside the simulators — and every assertion in
/// `theAndroidNDKIsThinkTwiceForItsRiskAndNotForItsTick` would still pass, because that row
/// carries both.
@Test func aRowThatMerelyStartsUntickedIsStillSafe() throws {
    let unmeasured = makeItem(id: "u", name: "SwiftPM cache", startsUnticked: true)

    #expect(unmeasured.decisionTier == .safe)
    #expect(try column(.safe, [unmeasured]).rows.map(\.name) == ["SwiftPM cache"])
}

/// The pnpm store: the number beside it is not the number that comes back, so a heading
/// saying it comes back on its own would be the one promise this tool must never make.
@Test func aRowWhoseBytesMayBeSharedIsThinkTwice() throws {
    let pnpm = makeItem(
        id: "pnpm", name: "pnpm store", sizeBytes: 1_830_000_000, sizeMayBeShared: true)

    #expect(pnpm.decisionTier == .thinkTwice)
    #expect(try column(.thinkTwice, [pnpm]).rows.map(\.name) == ["pnpm store"])
}

@Test func aProtectedRowIsKept() throws {
    let booted = makeItem(
        id: "booted", group: .xcodeAndIOS, name: "iPhone 17 Pro",
        sizeBytes: 7_090_000_000, protection: .bootedDevice,
        method: .deleteSimulator(udid: "AAA"))

    #expect(booted.decisionTier == .kept)
    let kept = try column(.kept, [booted])
    #expect(kept.rows.map(\.name) == ["iPhone 17 Pro"])
    #expect(kept.rows.first?.isEnabled == false)
    #expect(kept.rows.first?.tick == GroupTick.none)
}

/// Protection is tested first, and it has to be.
///
/// A booted simulator is permanent *and* protected, so a model that tested permanence first
/// would file the one row the app promises never to touch under "removed permanently". The
/// row above satisfies every other tier test just as well; only the order of the two rules
/// tells them apart.
@Test func protectionOutranksEveryReasonToThinkTwice() {
    let worst = makeItem(
        id: "worst", name: "iPhone 17 Pro", risk: .elevated, protection: .bootedDevice,
        method: .deleteSimulator(udid: "AAA"), sizeMayBeShared: true)

    #expect(worst.decisionTier == .kept)
}

// MARK: - collapsing many rows of one kind

/// The case the board exists for: twelve projects' `node_modules` as one line the user can
/// tick once, and open when they want to see which projects they are.
@Test func manyProjectsOfOneKindCollapseIntoOneAggregate() throws {
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000),
                             ("gamma", 1_000_000_000)])
    let thinkTwice = try column(.thinkTwice, items)

    #expect(thinkTwice.rows.count == 1)
    let row = try #require(thinkTwice.rows.first)
    #expect(row.name == "node_modules")
    // "3 projects", not "3 items": every child has a detail and no two share one, so the
    // details are what tell these rows apart and the count can name them after that.
    #expect(row.detail == "3 projects")
    #expect(row.sizeBytes == 6_000_000_000)
    #expect(row.sizeText == "6.0 GB")
    #expect(row.isExpandable)
    #expect(row.itemIDs.count == 3)
}

/// The identifier is built from the tier, the scanner and the shared name — no index and no
/// `UUID` — so a background scan landing under an open row leaves it open.
@Test func anAggregateKeepsItsIdentifierAcrossScans() throws {
    let first = try column(.thinkTwice, nodeModules([("alpha", 3_000_000_000),
                                                     ("beta", 2_000_000_000)]))
    // A second scan: different sizes, one project gone, one new.
    let second = try column(.thinkTwice, nodeModules([("alpha", 9_000_000_000),
                                                      ("delta", 1_000_000_000)]))

    #expect(first.rows.first?.id == second.rows.first?.id)
    #expect(first.rows.first?.id
        == "decision|thinkTwice|projects.buildOutput|node_modules")
}

/// One row of a kind stays one row. An aggregate wrapping a single child is a twisty that
/// opens onto a copy of itself.
@Test func aSingleRowOfItsKindIsNotWrappedInAnAggregate() throws {
    let only = try column(.thinkTwice, nodeModules([("alpha", 3_000_000_000)]))

    #expect(only.rows.count == 1)
    let row = try #require(only.rows.first)
    #expect(row.isExpandable == false)
    #expect(row.name == "node_modules")
    // Its own detail, not a count: the row is one project's folder and says so.
    #expect(row.detail == "alpha")
    #expect(row.id == "projects.buildOutput|/Users/test/dev/alpha/node_modules")
}

/// Rows whose details do not tell them apart are counted as plain items.
///
/// "12 projects" above a list where two lines read the same is a miscount the user can see.
@Test func rowsWithoutDistinctDetailsAreCountedAsItems() throws {
    let items = (1...3).map { index in
        makeItem(
            id: "cache-\(index)", scannerID: "other.libraryCaches", name: "Caches",
            sizeBytes: 1_000_000_000, method: .removePath("/tmp/cache-\(index)"))
    }
    let safe = try column(.safe, items)

    #expect(safe.rows.first?.detail == "3 items")
}

/// Two children of one project — a repeated detail — is the same miscount, and it is the case
/// a `count` check alone would let through.
@Test func repeatedDetailsAreCountedAsItemsRatherThanProjects() throws {
    let items = ["build", "other"].enumerated().map { index, folder in
        makeItem(
            id: "projects.buildOutput|/Users/test/dev/alpha/\(folder)",
            scannerID: "projects.buildOutput", group: .projects, name: "artifacts",
            detail: "alpha", sizeBytes: Int64(index + 1) * 1_000_000_000,
            method: .removePath("/Users/test/dev/alpha/\(folder)"))
    }
    let safe = try column(.safe, items)

    #expect(safe.rows.first?.detail == "2 items")
}

/// The children of a "N projects" aggregate are named after their projects. Their own name is
/// the heading above them, repeated N times, which says nothing about which one the user is
/// about to untick.
@Test func theChildrenOfAProjectAggregateAreNamedAfterTheirProjects() throws {
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000)])
    let id = "decision|thinkTwice|projects.buildOutput|node_modules"
    let thinkTwice = try column(.thinkTwice, items, expanded: [id])

    let row = try #require(thinkTwice.rows.first)
    #expect(row.children.map(\.name) == ["alpha", "beta"])
    // The detail is spent on the name, so nothing repeats it underneath.
    #expect(row.children.allSatisfy { $0.detail == nil })
    #expect(row.children.map(\.sizeText) == ["3.0 GB", "2.0 GB"])
}

/// Children exist only while the row is open. Built regardless, a board holding 257 projects'
/// folders makes several hundred rows on every redraw to draw a handful.
@Test func childrenAppearOnlyWhileTheAggregateIsOpen() throws {
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000)])
    let id = "decision|thinkTwice|projects.buildOutput|node_modules"

    let closed = try #require(try column(.thinkTwice, items).rows.first)
    #expect(closed.isExpanded == false)
    #expect(closed.children.isEmpty)
    // Expandable while closed, or there is nothing to click to open it.
    #expect(closed.isExpandable)

    let open = try #require(try column(.thinkTwice, items, expanded: [id]).rows.first)
    #expect(open.isExpanded)
    #expect(open.children.count == 2)
}

/// The twisty's hover text promises the direction the click will actually go.
///
/// Pinned by value and as a pair, because the failure is silent: swapped, both readings still
/// sound like a twisty, so an open aggregate would offer to open itself again and every
/// screenshot would look right. The words are the row's rather than the view's for exactly
/// that reason — in `MainWindowView` no assertion could reach the choice.
@Test func theTwistyHelpSaysWhichWayTheRowWillGo() throws {
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000)])
    let id = "decision|thinkTwice|projects.buildOutput|node_modules"

    let closed = try #require(try column(.thinkTwice, items).rows.first)
    #expect(closed.expandHelp == "Show what this row is made of")

    let open = try #require(try column(.thinkTwice, items, expanded: [id]).rows.first)
    #expect(open.expandHelp == "Hide what this row is made of")

    #expect(closed.expandHelp != open.expandHelp)
}

/// One name in two columns is two decisions and must stay two rows.
///
/// A `node_modules` that is safe and one that is elevated have different consequences, and an
/// aggregate spanning both would put a row into a column that describes the wrong one — with
/// a single checkbox ticking rows on both sides of the board.
@Test func oneNameInTwoTiersIsNeverMergedIntoOneAggregate() throws {
    let safeOnes = (1...2).map { index in
        makeItem(
            id: "safe-\(index)", scannerID: "projects.buildOutput", group: .projects,
            name: "build", detail: "project-\(index)", sizeBytes: 1_000_000_000,
            method: .removePath("/Users/test/dev/project-\(index)/build"))
    }
    let riskyOnes = (3...4).map { index in
        makeItem(
            id: "risky-\(index)", scannerID: "projects.buildOutput", group: .projects,
            name: "build", detail: "project-\(index)", sizeBytes: 1_000_000_000,
            risk: .elevated, method: .removePath("/Users/test/dev/project-\(index)/build"))
    }
    let all = columns(safeOnes + riskyOnes)
    let safe = try #require(all.first { $0.tier == .safe })
    let thinkTwice = try #require(all.first { $0.tier == .thinkTwice })

    #expect(safe.rows.count == 1)
    #expect(thinkTwice.rows.count == 1)
    #expect(safe.rows.first?.itemIDs == ["safe-1", "safe-2"])
    #expect(thinkTwice.rows.first?.itemIDs == ["risky-3", "risky-4"])
    // Two identifiers, or one click would open both aggregates in two different columns.
    #expect(safe.rows.first?.id != thinkTwice.rows.first?.id)
}

/// One name from two scanners is two kinds of thing. Merging on the name alone would put a
/// Flutter project's output and something else entirely under one checkbox.
@Test func oneNameFromTwoScannersIsNeverMergedIntoOneAggregate() throws {
    let safe = try column(.safe, [
        makeItem(id: "a", scannerID: "projects.buildOutput", name: "build",
                 sizeBytes: 2_000_000_000, method: .removePath("/a/build")),
        makeItem(id: "b", scannerID: "flutter.pubCache", name: "build",
                 sizeBytes: 1_000_000_000, method: .removePath("/b/build")),
    ])

    #expect(safe.rows.count == 2)
    #expect(safe.rows.allSatisfy { !$0.isExpandable })
}

// MARK: - what an aggregate claims

/// An aggregate carries only the tags **every** child carries.
///
/// A tag on an aggregate is a claim about everything the checkbox is about to remove. The
/// union would put "not ticked" over a row that is eleven-twelfths ticked, and — worse — a
/// `.kept` tag from one protected child over a box that happily ticks the other eleven.
@Test func anAggregateClaimsOnlyTheTagsEveryChildCarries() throws {
    let shared = makeItem(
        id: "one", scannerID: "projects.buildOutput", group: .projects, name: "node_modules",
        detail: "alpha", sizeBytes: 2_000_000_000, risk: .elevated,
        method: .removePath("/a/node_modules"), startsUnticked: true)
    let plain = makeItem(
        id: "two", scannerID: "projects.buildOutput", group: .projects, name: "node_modules",
        detail: "beta", sizeBytes: 1_000_000_000, risk: .elevated,
        method: .removePath("/b/node_modules"))
    let id = "decision|thinkTwice|projects.buildOutput|node_modules"
    let thinkTwice = try column(.thinkTwice, [shared, plain], expanded: [id])

    let row = try #require(thinkTwice.rows.first)
    // `.risk` is on both. `.notTickedByDefault` is on one, and does not survive.
    #expect(row.tags == [.risk])
    // The children keep their own, so nothing is lost — it is only the claim over all of
    // them that is narrowed.
    #expect(row.children.map(\.tags) == [[.risk, .notTickedByDefault], [.risk]])
}

/// The tick reading of an aggregate, all three ways.
///
/// `.some` is the whole reason an aggregate has a tick of its own: a mixed box invites a
/// click that fills the row up, and a mixed row drawn as `.none` invites one that empties it.
@Test func anAggregateReadsAllSomeOrNoneFromItsChildren() throws {
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000)])

    #expect(try column(.thinkTwice, items).rows.first?.tick == .all)
    #expect(try column(.thinkTwice, items) {
        $0.setTicked(false, for: "projects.buildOutput|/Users/test/dev/beta/node_modules")
    }.rows.first?.tick == .some)
    #expect(try column(.thinkTwice, items) {
        for item in items { $0.setTicked(false, for: item.id) }
    }.rows.first?.tick == GroupTick.none)
}

/// An aggregate of protected rows refuses its box, and its `.kept` tag is the one claim that
/// really is true of all of them.
///
/// The tick is counted over **eligible** children, the same rule as `SelectionModel.tick(of:)`.
/// A kept aggregate has none, and an aggregate with none reads `.none` rather than `.some` —
/// a mixed box there would invite a click that could not change anything. `isEnabled` follows
/// the same count, so the view greys the row instead of drawing a box that silently refuses.
@Test func aKeptAggregateReadsNoneAndRefusesItsBox() throws {
    let protected = ["alpha", "beta"].map { name in
        makeItem(
            id: "projects.buildOutput|/Users/test/dev/\(name)",
            scannerID: "projects.buildOutput", group: .projects, name: "project",
            detail: "changed in the last 14 days", sizeBytes: 2_000_000_000,
            protection: .recentActivity(days: 14),
            method: .removePath("/Users/test/dev/\(name)"))
    }
    let kept = try column(.kept, protected)

    let row = try #require(kept.rows.first)
    #expect(row.isExpandable)
    #expect(row.tick == GroupTick.none)
    #expect(row.isEnabled == false)
    #expect(row.tags == [.kept("changed in the last 14 days")])
    // Both details are the same sentence, so these are counted as items rather than projects.
    #expect(row.detail == "2 items")
}

// MARK: - bars

/// Every bar is a share of the biggest row on the **whole board**, so a 200 MB row in a thin
/// column cannot draw as wide as a 19 GB row in a full one. Scaled per column, they would.
@Test func barsAreSharesOfTheBiggestRowOnTheWholeBoard() throws {
    let all = columns([
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 20_000_000_000),
        makeItem(id: "small", name: "SwiftPM", sizeBytes: 5_000_000_000),
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 10_000_000_000,
                 sizeMayBeShared: true),
    ])
    let safe = try #require(all.first { $0.tier == .safe })
    let thinkTwice = try #require(all.first { $0.tier == .thinkTwice })

    #expect(abs((safe.rows.first?.fraction ?? 0) - 1.0) < 0.0001)
    #expect(abs((safe.rows.last?.fraction ?? 0) - 0.25) < 0.0001)
    // The widest row in this column is 10 GB, and it draws at half width — not full width,
    // which is what a per-column scale would give it.
    #expect(abs((thinkTwice.rows.first?.fraction ?? 0) - 0.5) < 0.0001)
}

/// An aggregate is measured by what its checkbox would remove, which is the sum of its
/// children — not by its largest child, and not by any one of them.
@Test func anAggregateIsMeasuredByItsSummedSize() throws {
    let items = nodeModules([("alpha", 6_000_000_000), ("beta", 4_000_000_000)])
    let id = "decision|thinkTwice|projects.buildOutput|node_modules"
    let all = columns(
        items + [makeItem(id: "derived", name: "DerivedData", sizeBytes: 20_000_000_000)],
        expanded: [id])
    let thinkTwice = try #require(all.first { $0.tier == .thinkTwice })

    let row = try #require(thinkTwice.rows.first)
    #expect(row.sizeBytes == 10_000_000_000)
    #expect(abs(row.fraction - 0.5) < 0.0001)
    // Children are scaled against the same board-wide maximum, so a child's bar can be read
    // straight against a top-level row in the next column.
    #expect(abs((row.children.first?.fraction ?? 0) - 0.3) < 0.0001)
    #expect(abs((row.children.last?.fraction ?? 0) - 0.2) < 0.0001)
}

/// A board whose biggest row is zero bytes must not divide by it.
///
/// Reachable, unlike the division `HeaderModel` leaves unguarded: `ios.simulatorCaches` really
/// is 0 bytes and really is ticked, and a machine where `du` measured nothing produces a board
/// of real rows that are all zero. Unguarded, every bar is `nan` and draws at whatever width
/// SwiftUI feels like.
@Test func everyBarIsZeroWhenTheBiggestRowIsZeroBytes() throws {
    let safe = try column(.safe, [
        makeItem(id: "a", name: "Simulator caches", sizeBytes: 0),
        makeItem(id: "b", name: "SwiftPM", sizeBytes: 0),
    ])

    #expect(safe.rows.count == 2)
    #expect(safe.rows.allSatisfy { $0.fraction == 0 })
}

// MARK: - order

/// Biggest first, ties broken by identifier — the same rule as `GroupList.byDescendingSize`
/// and `ReportText.byDescendingSize`, applied at **both** levels so opening an aggregate does
/// not reveal a differently sorted list than the one it sits in.
@Test func rowsAndChildrenAreBiggestFirstWithTiesBrokenByIdentifier() throws {
    // The parameter is annotated because `detail:` takes a `String?`: left to infer, the
    // solver is free to read the whole array as `[String?]`, and every interpolation above
    // then writes `Optional("zulu")` into the identifier this test sorts on.
    let sameSize = ["zulu", "alpha"].map { (project: String) in
        makeItem(
            id: "projects.buildOutput|/Users/test/dev/\(project)/build",
            scannerID: "projects.buildOutput", group: .projects, name: "build",
            detail: project, sizeBytes: 1_000_000_000,
            method: .removePath("/Users/test/dev/\(project)/build"))
    }
    let id = "decision|safe|projects.buildOutput|build"
    let safe = try column(
        .safe,
        sameSize + [
            makeItem(id: "small", name: "SwiftPM", sizeBytes: 500_000_000),
            makeItem(id: "big", name: "DerivedData", sizeBytes: 30_000_000_000),
        ],
        expanded: [id])

    // The aggregate is 2.0 GB, so it sits between the 30 GB row and the 500 MB one.
    #expect(safe.rows.map(\.name) == ["DerivedData", "build", "SwiftPM"])
    // Two children of equal size: the identifier decides, and `alpha`'s path sorts first.
    let row = try #require(safe.rows.first { $0.isExpandable })
    #expect(row.children.map(\.name) == ["alpha", "zulu"])
}

// MARK: - column totals

/// The safe and think-twice totals follow the ticks, click by click. Built from the scan
/// instead, a column would still claim 19 GB after the user unticked it while the Clean button
/// below had already dropped it — two numbers on one screen, disagreeing.
@Test func aDeletableColumnTotalFollowsTheTicks() throws {
    let items = [
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "swiftpm", name: "SwiftPM", sizeBytes: 1_000_000_000),
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 2_000_000_000,
                 sizeMayBeShared: true),
    ]

    #expect(try column(.safe, items).totalText == "31.0 GB")
    #expect(try column(.thinkTwice, items).totalText == "2.0 GB")

    let unticked = columns(items) { $0.setTicked(false, for: "derived") }
    #expect(try #require(unticked.first { $0.tier == .safe }).totalText == "1.0 GB")
    // The other column does not move: unticking is per row, not per board.
    #expect(try #require(unticked.first { $0.tier == .thinkTwice }).totalText == "2.0 GB")
}

/// The kept total ignores the ticks, because nothing in that column can be ticked.
///
/// Routed through the selection it would read 0 KB, and a column headed "Kept for you" saying
/// nothing is kept is the one reading that is never true.
@Test func theKeptTotalIsTheProtectedBytesAndIgnoresEveryTick() throws {
    let items = [
        makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
        makeItem(id: "project", group: .projects, name: "sample-project",
                 sizeBytes: 46_880_000_000, protection: .recentActivity(days: 14)),
    ]

    #expect(try column(.kept, items).totalText == "46.9 GB")
    // Untick everything that can be unticked: the kept total is unchanged.
    #expect(try column(.kept, items) { $0.setTicked(false, for: "derived") }.totalText
        == "46.9 GB")
}

/// One directory named by two rows is one lot of bytes on disk. A plain sum here would be a
/// second answer to a question `ScanResult.totalBytes` has already answered everywhere else on
/// the screen.
@Test func aColumnCountsOneDirectoryOnceEvenWhenTwoRowsNameIt() throws {
    let path = "/Users/test/Library/Android/sdk/ndk"
    let safe = try column(.safe, [
        makeItem(id: "one", name: "one", sizeBytes: 3_000_000_000, method: .removePath(path)),
        makeItem(id: "two", name: "two", sizeBytes: 3_000_000_000, method: .removePath(path)),
    ])

    #expect(safe.totalText == "3.0 GB")
}

/// No selection is not a half-drawn board: every box is empty and both deletable totals are
/// zero, which is the one reading consistent with what those boxes show. The kept column is
/// unaffected, because it never depended on a tick.
@Test func aBoardWithNoSelectionTicksNothing() throws {
    let all = DecisionBoardModel.columns(
        result: makeResult([
            makeItem(id: "derived", name: "DerivedData", sizeBytes: 30_000_000_000),
            makeItem(id: "kept", name: "sample-project", sizeBytes: 2_000_000_000,
                     protection: .pinnedProject),
        ]),
        selection: nil, expanded: [], home: "/Users/test")

    #expect(try #require(all.first { $0.tier == .safe }).totalText == "0 KB")
    #expect(try #require(all.first { $0.tier == .safe }).rows.first?.tick == GroupTick.none)
    #expect(try #require(all.first { $0.tier == .kept }).totalText == "2.0 GB")
}

// MARK: - what a leaf carries

/// The dot beside the name is the only thing left saying which technology a row belongs to,
/// now that the board has stopped sorting by it. The tags are `GroupRow`'s own, so the popover
/// and the board cannot label one row two different ways.
@Test func aRowCarriesItsGroupAndTheSharedTagVocabulary() throws {
    let ndk = makeItem(
        id: "ndk", scannerID: "android.ndk", group: .android, name: "27.0.12077973",
        detail: "Android Studio downloads it again", sizeBytes: 5_570_000_000,
        risk: .elevated, startsUnticked: true)
    let row = try #require(try column(.thinkTwice, [ndk]).rows.first)

    #expect(row.groupID == .android)
    #expect(row.detail == "Android Studio downloads it again")
    #expect(row.sizeText == "5.6 GB")
    #expect(row.tags == [.risk, .notTickedByDefault])
    #expect(row.tags == GroupRow(item: ndk, reporter: ReportText(home: "/Users/test")).tags)
    // A leaf's checkbox controls itself and nothing else.
    #expect(row.itemIDs == ["ndk"])
}

// MARK: - the model the view actually hands over

@MainActor
@Test func theBoardOverloadReadsEverythingFromTheModel() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000)])
    try cache.save(makeResult(items))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    let id = "decision|thinkTwice|projects.buildOutput|node_modules"
    let closed = try #require(model.decisionColumns.first { $0.tier == .thinkTwice })
    #expect(closed.rows.first?.isExpanded == false)
    #expect(closed.totalText == "5.0 GB")

    model.toggleDecisionRow(id)
    #expect(model.expandedDecisionRows == [id])
    let open = try #require(model.decisionColumns.first { $0.tier == .thinkTwice })
    #expect(open.rows.first?.children.map(\.name) == ["alpha", "beta"])

    model.toggleDecisionRow(id)
    #expect(model.expandedDecisionRows.isEmpty)

    let empty = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: "/Users/test", clock: { now })
    #expect(empty.decisionColumns.isEmpty)
    #expect(empty.decisionHeader == nil)
}

/// One click on an aggregate's box reaches every row it controls.
@MainActor
@Test func settingAnAggregatesRowsTicksEveryChild() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let items = nodeModules([("alpha", 3_000_000_000), ("beta", 2_000_000_000)])
    try cache.save(makeResult(items))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    let row = try #require(
        model.decisionColumns.first { $0.tier == .thinkTwice }?.rows.first)
    model.setRows(row.itemIDs, ticked: false)

    #expect(model.selection?.selectedItems.isEmpty == true)
    #expect(try #require(model.decisionColumns.first { $0.tier == .thinkTwice })
        .rows.first?.tick == GroupTick.none)

    model.setRows(row.itemIDs, ticked: true)
    #expect(model.selection?.selectedBytes == 5_000_000_000)
    #expect(try #require(model.decisionColumns.first { $0.tier == .thinkTwice })
        .rows.first?.tick == .all)
}

/// `setRows` goes through `SelectionModel.setTicked`, which refuses a protected identifier —
/// so an aggregate holding one can be handed its whole list without ticking what must not be
/// ticked. Reaching into the store instead would put the app's most destructive decision
/// behind a rule that exists in two places.
@MainActor
@Test func settingRowsRefusesAProtectedIdentifier() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([
        makeItem(id: "deletable", name: "DerivedData", sizeBytes: 1_000_000_000),
        makeItem(id: "kept", name: "sample-project", sizeBytes: 2_000_000_000,
                 protection: .pinnedProject),
    ]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: "/Users/test", clock: { now })

    model.setRows(["deletable", "kept"], ticked: true)

    #expect(model.selection?.selectedItems.map(\.id) == ["deletable"])
}
