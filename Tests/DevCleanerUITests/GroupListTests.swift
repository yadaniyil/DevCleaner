import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

private let home = "/Users/test"

private func sections(_ items: [CleanupItem], roots: [String] = []) -> [GroupSection] {
    GroupList.sections(from: makeResult(items), home: home, projectRoots: roots)
}

@Test func everyGroupIsListedEvenWhenItIsEmpty() {
    let all = sections([])
    #expect(all.map(\.id) == GroupID.allCases)
    #expect(all.allSatisfy { $0.rows.isEmpty })
}

@Test func rowsAreBiggestFirstWithTiesBrokenByIdentifier() throws {
    let all = sections([
        makeItem(id: "small", sizeBytes: 1_000),
        makeItem(id: "b-tie", sizeBytes: 5_000),
        makeItem(id: "a-tie", sizeBytes: 5_000),
    ])
    let section = try #require(all.first { $0.id == .otherCaches })

    #expect(section.rows.map(\.id) == ["a-tie", "b-tie", "small"])
}

/// The other side of the same rule.
///
/// `ReportText.byDescendingSize` is `internal` to CleanerCore, so `GroupList` restates the
/// ordering rather than calling it — and a restatement is a copy that can drift. This runs
/// one pair of tied rows through both and pins that the popover lists them in the order
/// `devcleaner scan` prints them.
///
/// `rowsAreBiggestFirstWithTiesBrokenByIdentifier` covers the copy in `GroupList`. This one
/// covers the original: dropping the tiebreak inside `ReportText` failed no test in the
/// whole suite before it existed, so the popover could have been pinned to an order the
/// report was free to change.
@Test func thePopoverOrdersTiedRowsTheSameWayTheScanReportDoes() throws {
    // Listed with the higher identifier first, so insertion order alone gives the wrong
    // answer on both sides and only the tiebreak can produce the expected one.
    let items = [
        makeItem(id: "b-tie", name: "bravo-row", sizeBytes: 5_000),
        makeItem(id: "a-tie", name: "alpha-row", sizeBytes: 5_000),
    ]
    let section = try #require(sections(items).first { $0.id == .otherCaches })
    #expect(section.rows.map(\.name) == ["alpha-row", "bravo-row"])

    // Scoped to the one group's own block — its heading down to the blank line that ends
    // it — rather than searched across the whole report. `range(of:)` takes the first
    // occurrence anywhere, so the moment the report grows a second section that names rows
    // (a plan, a footer, a skipped list) this would quietly start measuring that instead of
    // listing order, and keep passing while measuring the wrong thing.
    let printed = ReportText(home: home).scan(makeResult(items), now: now, moveToTrash: true)
    let heading = try #require(printed.range(of: "Other caches  —"))
    let block = try #require(printed[heading.upperBound...].components(separatedBy: "\n\n").first)
    let alpha = try #require(block.range(of: "alpha-row"))
    let bravo = try #require(block.range(of: "bravo-row"))
    #expect(alpha.lowerBound < bravo.lowerBound)
}

/// The handoff's "show the path". Two representative protected projects are both named
/// `shared-project-name`, both 13.6 MB, both detailed "changed in the last 14 days". The
/// deletion target is the only thing that separates them.
@Test func aRowShowsTheTargetSoTwoIdenticalRowsCanBeToldApart() throws {
    let all = sections([
        makeItem(id: "one", group: .projects, name: "shared-project-name",
                 detail: "changed in the last 14 days", sizeBytes: 13_600_000,
                 protection: .recentActivity(days: 14),
                 method: .removePath("/Users/test/dev/workspace-one")),
        makeItem(id: "two", group: .projects, name: "shared-project-name",
                 detail: "changed in the last 14 days", sizeBytes: 13_600_000,
                 protection: .recentActivity(days: 14),
                 method: .removePath("/Users/test/dev/workspace-two/client-app")),
    ])
    let section = try #require(all.first { $0.id == .projects })
    #expect(section.rows.count == 2)
    #expect(Set(section.rows.map(\.target))
        == ["~/dev/workspace-one", "~/dev/workspace-two/client-app"])
}

@Test func aDeviceRowNamesTheDeviceRatherThanAPath() throws {
    let all = sections([
        makeItem(id: "sim", group: .xcodeAndIOS, name: "iPhone 17",
                 sizeBytes: 12_860_000_000, method: .deleteSimulator(udid: "AAA")),
        makeItem(id: "rt", group: .xcodeAndIOS, name: "iOS 26.5",
                 sizeBytes: 17_000_000_000,
                 method: .deleteSimulatorRuntime(identifier: "iOS-26-5")),
        makeItem(id: "avd", group: .android, name: "sample_emulator_1",
                 sizeBytes: 4_130_000_000, method: .deleteAVD(name: "sample_emulator_1")),
    ])
    let xcode = try #require(all.first { $0.id == .xcodeAndIOS })
    #expect(xcode.rows.map(\.target) == ["runtime iOS-26-5", "simulator AAA"])
    let android = try #require(all.first { $0.id == .android })
    #expect(android.rows.first?.target == "emulator sample_emulator_1")
}

/// The five labels, and the one hover sentence with nothing else holding it in place.
///
/// `text` is what Task 10 draws beside each row, and every other test here asserts tag
/// *identity* — `.contains(.permanent)`, `== [.kept("…")]` — which is satisfied whatever
/// the label says. Returning `""` from all five cases, or swapping "kept" and "permanent",
/// changed nothing in the suite before this test existed.
///
/// `RowTag.risk.help` is the only `help` not anchored to a `ReportText` constant, so it is
/// the only one that can be reworded without the engine noticing. The other four are pinned
/// against their constants where they are used.
@Test func everyTagDrawsItsOwnLabelAndRiskCarriesItsOwnSentence() {
    // The reason lives in `help`, so the label stays the same word for every protected row.
    #expect(RowTag.kept("running right now").text == "kept")
    #expect(RowTag.risk.text == "risk")
    #expect(RowTag.permanent.text == "permanent")
    #expect(RowTag.mayBeShared.text == "shared")
    #expect(RowTag.notTickedByDefault.text == "not ticked")

    #expect(RowTag.risk.help == "comes back only over the network, and that fetch can fail")
}

/// The order the tags are appended in is the order the view draws them, so it is behaviour
/// rather than an implementation detail. Every other tag test either uses `contains` or has
/// a single-tag row, which leaves the five appends free to be reordered silently.
///
/// Both fixtures are rows a real dev machine can actually produce. A simulator runtime carries
/// three at once: `simctl runtime delete` has no Trash, re-downloading one is gigabytes over
/// the network that can fail, and it is offered unticked for exactly that reason. A package
/// store carries the other three: its bytes may be shared with project `node_modules` that
/// are staying, and a row whose size `du` could not measure starts unticked.
@Test func aRowWithSeveralTagsDrawsThemInAFixedOrder() throws {
    let all = sections([
        makeItem(id: "rt", group: .xcodeAndIOS, name: "iOS 26.5", risk: .elevated,
                 method: .deleteSimulatorRuntime(identifier: "iOS-26-5"),
                 startsUnticked: true),
        makeItem(id: "pnpm", name: "pnpm store", risk: .elevated,
                 startsUnticked: true, sizeMayBeShared: true),
        // `kept` comes before every other tag it is allowed to sit beside. It cannot sit
        // beside `.permanent` or `.notTickedByDefault` at all — both are guarded on
        // `isDeletable` — so an elevated-risk SDK that is in use is the pair to pin.
        makeItem(id: "sdk", group: .flutterAndDart, name: "Flutter 3.24", risk: .elevated,
                 protection: .sdkInUse(by: "sample-project")),
    ])

    let xcode = try #require(all.first { $0.id == .xcodeAndIOS })
    let runtime = try #require(xcode.rows.first)
    #expect(runtime.tags == [.permanent, .risk, .notTickedByDefault])

    let other = try #require(all.first { $0.id == .otherCaches })
    let store = try #require(other.rows.first)
    #expect(store.tags == [.risk, .mayBeShared, .notTickedByDefault])

    let flutter = try #require(all.first { $0.id == .flutterAndDart })
    let sdk = try #require(flutter.rows.first)
    #expect(sdk.tags == [.kept("used by sample-project"), .risk])
}

/// Permanence is its own signal. `.elevated` now means two different things — "comes back
/// over the network" and "cannot come back at all" — so a device row carries both tags
/// and neither stands in for the other.
@Test func aDeviceRowIsTaggedPermanentSeparatelyFromRisk() throws {
    let all = sections([
        makeItem(id: "avd", group: .android, name: "sample_emulator_1",
                 risk: .safe, method: .deleteAVD(name: "sample_emulator_1")),
        makeItem(id: "pub", group: .flutterAndDart, name: "git packages", risk: .elevated),
    ])
    let android = try #require(all.first { $0.id == .android })
    let device = try #require(android.rows.first)
    #expect(device.tags.contains(.permanent))
    #expect(!device.tags.contains(.risk))

    let flutter = try #require(all.first { $0.id == .flutterAndDart })
    let pub = try #require(flutter.rows.first)
    #expect(pub.tags.contains(.risk))
    #expect(!pub.tags.contains(.permanent))
}

@Test func aProtectedRowIsTaggedKeptWithItsReasonAndNeverPermanent() throws {
    let all = sections([
        makeItem(id: "sim", group: .xcodeAndIOS, name: "Sample Design Simulator",
                 protection: .bootedDevice, method: .deleteSimulator(udid: "BBB")),
    ])
    let section = try #require(all.first { $0.id == .xcodeAndIOS })
    let row = try #require(section.rows.first)

    #expect(!row.isEnabled)
    #expect(row.tags == [.kept("running right now")])
    #expect(row.tags.first?.help == "kept: running right now")
}

/// "not ticked" means *offered, and left for you to decide*. A protected row is not offered
/// at all, so the two labels side by side tell the user the box can be clicked when it
/// refuses every click — the same mistake as "permanent" beside "kept", one row down.
///
/// The combination is reachable: `startsUnticked` is set by the scanner that produced the
/// row and `protection` by `ProtectionResolver` afterwards, and neither knows about the
/// other. An SDK that starts unticked and is then found to be in use carries both.
@Test func aProtectedRowIsNeverTaggedNotTickedBecauseItWasNeverOffered() throws {
    let all = sections([
        makeItem(id: "ndk", group: .android, name: "NDK 27.0", sizeBytes: 5_570_000_000,
                 protection: .sdkInUse(by: "sample-project"), startsUnticked: true),
    ])
    let section = try #require(all.first { $0.id == .android })
    let row = try #require(section.rows.first)

    #expect(!row.isEnabled)
    #expect(row.tags == [.kept("used by sample-project")])
}

@Test func aSharedSizeAndAnUntickedRowEachCarryTheirOwnTag() throws {
    let all = sections([
        makeItem(id: "pnpm", name: "pnpm store", sizeBytes: 1_830_000_000,
                 sizeMayBeShared: true),
        makeItem(id: "ndk", group: .android, name: "NDK 27.0", sizeBytes: 5_570_000_000,
                 startsUnticked: true),
    ])
    let other = try #require(all.first { $0.id == .otherCaches })
    let pnpm = try #require(other.rows.first)
    #expect(pnpm.tags.contains(.mayBeShared))
    #expect(pnpm.tags.first { $0 == .mayBeShared }?.help == ReportText.sharedNote)

    let android = try #require(all.first { $0.id == .android })
    let ndk = try #require(android.rows.first)
    #expect(ndk.tags.contains(.notTickedByDefault))
    #expect(ndk.tags.first { $0 == .notTickedByDefault }?.help == ReportText.untickedNote)

    // The popover and `devcleaner scan` must say the same thing about the same row, so the
    // permanence sentence is the engine's own and not a second wording of it.
    #expect(RowTag.permanent.help == ReportText.permanentNote)
}

/// The count is every row the group holds, protected and unticked ones included — it is
/// the "3 rows" of "3 rows · 19.0 GB", and the two halves answer different questions.
///
/// There is no size here at all. `GroupSection` is built from the scan alone, so any total
/// it carried could only be the scan's default tick, frozen and wrong from the user's first
/// click; the live one is `SelectionModel.selectedBytes(in:)` and
/// `theGroupHeadlineFollowsTheTicks` is what pins it.
@Test func aGroupCountsEveryRowItHoldsIncludingTheOnesACleanWouldNotTouch() throws {
    let all = sections([
        makeItem(id: "a", group: .android, sizeBytes: 19_000_000_000),
        makeItem(id: "ndk", group: .android, sizeBytes: 5_570_000_000, startsUnticked: true),
        makeItem(id: "kept", group: .android, sizeBytes: 9_780_000_000,
                 protection: .mostRecentlyUsedDevice),
    ])
    let section = try #require(all.first { $0.id == .android })

    #expect(section.count == 3)
    #expect(section.rows.map(\.id) == ["a", "kept", "ndk"])
}

@Test func theProjectsGroupNamesTheRootsItScanned() throws {
    let one = try #require(
        sections([], roots: ["/Users/test/dev"]).first { $0.id == .projects })
    #expect(one.title == "Projects in ~/dev")

    let two = try #require(
        sections([], roots: ["/Users/test/dev", "/Users/test/work"])
            .first { $0.id == .projects })
    #expect(two.title == "Projects in ~/dev, ~/work")

    let none = try #require(sections([], roots: []).first { $0.id == .projects })
    #expect(none.title == "Projects")
}

@Test func theOtherFourGroupsKeepTheEnginesTitles() {
    let all = sections([], roots: ["/Users/test/dev"])
    #expect(all.filter { $0.id != .projects }.map(\.title)
        == ["Xcode & iOS", "Android", "Flutter & Dart", "Other caches"])
}

/// The genuine 0-byte row. Hiding rows from a list the user is about to approve is worse
/// than showing an odd one.
@Test func aZeroByteRowIsStillListed() throws {
    let all = sections([
        makeItem(id: "caches", group: .xcodeAndIOS, name: "Simulator caches", sizeBytes: 0),
    ])
    let section = try #require(all.first { $0.id == .xcodeAndIOS })
    let row = try #require(section.rows.first)

    #expect(row.sizeText == "0 KB")
    #expect(row.isEnabled)
}

@Test func aRowKeepsItsDetailAndItsItem() throws {
    let all = sections([
        makeItem(id: "build", group: .projects, name: "build", detail: "sample-project",
                 sizeBytes: 2_000_000_000,
                 method: .removePath("/Users/test/dev/sample-project/build")),
    ])
    let section = try #require(all.first { $0.id == .projects })
    let row = try #require(section.rows.first)

    #expect(row.name == "build")
    #expect(row.detail == "sample-project")
    #expect(row.sizeText == "2.0 GB")
    #expect(row.item.scannerID == "other.libraryCaches")
    #expect(row.target == "~/dev/sample-project/build")
}
