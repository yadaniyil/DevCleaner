import Testing
@testable import DevCleanerUI
import CleanerCore

@Test func everyDeletableRowStartsTickedIncludingElevatedRisk() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "safe"),
        makeItem(id: "risky", risk: .elevated),
    ]))

    #expect(selection.isTicked("safe"))
    #expect(selection.isTicked("risky"))
}

/// The whole point of `selectedByDefault`. Ticking from `isDeletable` puts 5.57 GB of
/// Android NDK re-download into a clean the user never asked for.
@Test func aRowThatStartsUntickedIsOfferedButNotTicked() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "ndk", sizeBytes: 5_570_000_000, startsUnticked: true),
    ]))

    #expect(selection.isEnabled("ndk"))
    #expect(!selection.isTicked("ndk"))
    let bytes: Int64 = selection.selectedBytes
    #expect(bytes == 0)
}

@Test func anUnmeasuredRowIsOfferedButNotTicked() {
    // `ScanHelpers.measured` sets `startsUnticked` when `du` gave no answer. The row is
    // shown with a size of zero and must not be ticked: the user cannot approve a
    // deletion neither they nor the tool can size.
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "runtime", sizeBytes: 0, startsUnticked: true),
    ]))

    #expect(!selection.isTicked("runtime"))
}

@Test func aProtectedRowIsDisabledAndCannotBeTicked() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "kept", protection: .bootedDevice),
    ]))

    #expect(!selection.isEnabled("kept"))
    #expect(!selection.isTicked("kept"))

    selection.setTicked(true, for: "kept")
    #expect(!selection.isTicked("kept"))

    selection.toggle("kept")
    #expect(!selection.isTicked("kept"))
}

/// `toggle` is what a row click calls, and the only test that touched it used a protected
/// row — where `setTicked`'s guard rejects the call whatever `toggle` computed, so the
/// method's own body was never under test.
///
/// It has to go both ways. A body that dropped the `!` would tick a row and never untick
/// one: the user could add to the clean but never take anything out of it, which is the
/// silent cost this whole type exists to refuse.
@Test func togglingAnEnabledRowGoesBothWays() {
    var selection = SelectionModel(result: makeResult([makeItem(id: "a")]))

    #expect(selection.isTicked("a"))

    selection.toggle("a")
    #expect(!selection.isTicked("a"))

    selection.toggle("a")
    #expect(selection.isTicked("a"))
}

/// An identifier no scan produced is not a row: it cannot be clicked and cannot be ticked.
///
/// The second half matters more than the first. A `setTicked` that let one through would
/// put a phantom id into the ticked set that no untick can reach, because every untick
/// route also goes through the same guard. `isDefaultSelection` would then read false for
/// the rest of the popover's life, sending a user who changed nothing down the
/// `clean(items:)` path instead of `cleanDefault`.
@Test func anIdentifierNoScanProducedIsNeitherEnabledNorTickable() {
    var selection = SelectionModel(result: makeResult([makeItem(id: "a")]))

    #expect(!selection.isEnabled("no-such-row"))

    selection.setTicked(true, for: "no-such-row")
    #expect(!selection.isTicked("no-such-row"))
    #expect(selection.isDefaultSelection)
}

@Test func aGroupToggleReachesEveryEligibleRowBeneathIt() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "a", group: .android),
        makeItem(id: "b", group: .android),
        makeItem(id: "kept", group: .android, protection: .pinnedDevice),
        makeItem(id: "elsewhere", group: .projects),
    ]))

    selection.setGroup(.android, ticked: false)
    #expect(!selection.isTicked("a"))
    #expect(!selection.isTicked("b"))
    #expect(selection.isTicked("elsewhere"))

    selection.setGroup(.android, ticked: true)
    #expect(selection.isTicked("a"))
    #expect(selection.isTicked("b"))
    // Still refused: a group toggle is not a way round protection.
    #expect(!selection.isTicked("kept"))
}

/// Ticking a group box is the user asking for everything under that heading, the NDK
/// included. `startsUnticked` means "not without being asked", not "never" — and a group
/// toggle is being asked.
///
/// This is also the test that holds `setGroup` to going through `setTicked`. It is the only
/// group test whose rows are not all plain deletable ones, so it is the only one that
/// notices if a rule added to `setTicked` stops reaching a group toggle.
@Test func aGroupToggleReachesARowThatStartedUnticked() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "avd", group: .android),
        makeItem(id: "ndk", group: .android, startsUnticked: true),
    ]))

    #expect(!selection.isTicked("ndk"))

    selection.setGroup(.android, ticked: true)
    #expect(selection.isTicked("ndk"))
    #expect(selection.tick(of: .android) == .all)

    selection.setGroup(.android, ticked: false)
    #expect(!selection.isTicked("ndk"))
    #expect(!selection.isTicked("avd"))
}

@Test func aGroupReadsAllNoneOrMixed() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "a", group: .android),
        makeItem(id: "b", group: .android),
    ]))

    #expect(selection.tick(of: .android) == .all)
    selection.setTicked(false, for: "a")
    #expect(selection.tick(of: .android) == .some)
    selection.setTicked(false, for: "b")
    #expect(selection.tick(of: .android) == .none)
}

/// A group that holds nothing but protected rows can never be ticked, so its box must
/// read empty rather than "all of the nothing that is eligible".
@Test func aGroupOfProtectedRowsOnlyReadsNone() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "kept", group: .projects, protection: .pinnedProject),
    ]))

    #expect(selection.tick(of: .projects) == .none)
    #expect(selection.tick(of: .flutterAndDart) == .none)
}

/// The other half of the eligible-rows-only rule, and the half
/// `aGroupOfProtectedRowsOnlyReadsNone` cannot reach: there, nothing is ticked, so counting
/// protected rows or not gives `.none` either way. Here the one tickable row is ticked and a
/// protected row sits beside it. The box must read `.all` — a mixed box offers a click that
/// cannot change anything, because the only row left is one no click may tick.
@Test func aGroupWhoseOnlyUntickedRowIsProtectedStillReadsAll() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "avd", group: .android),
        makeItem(id: "kept", group: .android, protection: .pinnedDevice),
    ]))

    #expect(selection.tick(of: .android) == .all)
}

@Test func theNDKStartsMixedRatherThanAllWithinItsGroup() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "avd", group: .android),
        makeItem(id: "ndk", group: .android, startsUnticked: true),
    ]))

    #expect(selection.tick(of: .android) == .some)
}

/// The same de-duplicating rule as the headline. Two rows naming one directory are one
/// lot of bytes, and a hand-written sum in the interface is a second chance to promise
/// space that exists once.
@Test func twoRowsNamingOneTargetCountOnceInTheSelectedTotal() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "a", sizeBytes: 2_000_000_000, method: .removePath("/tmp/same")),
        makeItem(id: "b", sizeBytes: 2_000_000_000, method: .removePath("/tmp/same")),
    ]))

    let bytes: Int64 = selection.selectedBytes
    #expect(bytes == 2_000_000_000)
}

@Test func theSelectedTotalFollowsTheTicks() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "a", sizeBytes: 40_200_000_000),
        makeItem(id: "b", sizeBytes: 17_800_000_000),
    ]))

    let full: Int64 = selection.selectedBytes
    #expect(full == 58_000_000_000)

    selection.setTicked(false, for: "b")
    let part: Int64 = selection.selectedBytes
    #expect(part == 40_200_000_000)
}

/// "Offered but not ticked" is a live reading, not the scan's `startsUnticked` flag.
///
/// A row the user unticked by hand is offered and not ticked in exactly the same sense as
/// the Android NDK, and a row that is protected is offered in neither: its box refuses every
/// click, so counting it would name bytes the popover will not let anyone have.
@Test func theUntickedOfferFollowsTheTicksAndLeavesProtectedRowsOut() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "cache", sizeBytes: 4_000_000_000),
        makeItem(id: "ndk", sizeBytes: 5_000_000_000, startsUnticked: true),
        // 30 GB, not 9: with 9 the answer below would be the same number whether the kept
        // row were counted or the two offered rows were added up, and the test could not
        // tell one from the other.
        makeItem(id: "kept", sizeBytes: 30_000_000_000, protection: .pinnedDevice),
    ]))

    let start: Int64 = selection.unselectedDeletableBytes
    #expect(start == 5_000_000_000)

    // The 4 GB the user just unticked joins the 5 GB that started that way. The kept row's
    // 30 GB stays out of it, which is what tells this apart from 39.0 GB.
    selection.setTicked(false, for: "cache")
    let unticked: Int64 = selection.unselectedDeletableBytes
    #expect(unticked == 9_000_000_000)

    selection.setGroup(.otherCaches, ticked: true)
    let none: Int64 = selection.unselectedDeletableBytes
    #expect(none == 0)
}

/// The shared part of the ticked total, which is what makes the header's range honest.
/// Unticking the pnpm store takes its 1.83 GB out of both numbers at once.
@Test func theSharedPartOfTheSelectionFollowsTheTicks() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "pnpm", sizeBytes: 1_830_000_000, sizeMayBeShared: true),
        makeItem(id: "rest", sizeBytes: 56_170_000_000),
    ]))

    let shared: Int64 = selection.selectedPossiblySharedBytes
    #expect(shared == 1_830_000_000)

    selection.setTicked(false, for: "pnpm")
    let none: Int64 = selection.selectedPossiblySharedBytes
    #expect(none == 0)
    // The plain rows are not counted as shared, whatever else happens to the total.
    let total: Int64 = selection.selectedBytes
    #expect(total == 56_170_000_000)
}

/// What Task 5 uses to decide between `cleanDefault` and `clean(items:)`.
@Test func anUntouchedSelectionIsTheDefaultSelection() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "a"),
        makeItem(id: "ndk", startsUnticked: true),
    ]))

    #expect(selection.isDefaultSelection)

    selection.setTicked(true, for: "ndk")
    #expect(!selection.isDefaultSelection)

    selection.setTicked(false, for: "ndk")
    #expect(selection.isDefaultSelection)
}

/// The direction `anUntouchedSelectionIsTheDefaultSelection` never goes, and the one that
/// costs the user data. Task 5 sends a default selection to `cleanDefault`, which re-derives
/// the full list inside the engine and ignores whatever the app is holding. Reading a
/// narrowed selection as "still the default" therefore deletes the rows the user just
/// unticked.
@Test func untickingARowLeavesTheDefaultSelection() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "a"),
        makeItem(id: "b"),
    ]))

    selection.setTicked(false, for: "a")
    #expect(!selection.isDefaultSelection)

    selection.setTicked(true, for: "a")
    #expect(selection.isDefaultSelection)
}

@Test func aRowTickIsAllOrNoneAndNeverMixed() {
    var selection = SelectionModel(result: makeResult([makeItem(id: "a")]))

    #expect(selection.tick(ofRow: "a") == .all)
    selection.setTicked(false, for: "a")
    #expect(selection.tick(ofRow: "a") == .none)
    #expect(selection.tick(ofRow: "no-such-row") == .none)
}

@Test func selectedItemsKeepsTheScanOrder() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "first"), makeItem(id: "second"), makeItem(id: "third"),
    ]))
    selection.setTicked(false, for: "second")

    #expect(selection.selectedItems.map(\.id) == ["first", "third"])
}
