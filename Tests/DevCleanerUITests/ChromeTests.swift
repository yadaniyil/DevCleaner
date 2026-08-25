import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

// MARK: - the menu bar item

@Test func theMenuBarShowsTheReclaimableAmount() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "a", sizeBytes: 58_000_000_000),
    ]))
    #expect(MenuBarLabel.text(selection: selection, showsAmount: true) == "58.0 GB")
}

@Test func theMenuBarShowsNoTextWhenTheUserAsksForTheIconAlone() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "a", sizeBytes: 58_000_000_000),
    ]))
    #expect(MenuBarLabel.text(selection: selection, showsAmount: false) == nil)
}

/// Before the first scan there is no honest number to show, and a "0 GB" in the menu bar
/// would say the machine is clean.
@Test func theMenuBarShowsNoTextBeforeTheFirstScan() {
    #expect(MenuBarLabel.text(selection: nil, showsAmount: true) == nil)
}

/// The menu bar and the header are on screen together whenever the popover is open, so the
/// menu bar follows the ticks by the same rule the header does.
///
/// Built from `ScanResult.reclaimableBytes` it is the scan's frozen default: untick the
/// 17.8 GB of devices and the icon still says 58.0 GB above a popover header saying
/// `up to 40.2 GB`. Ticks last for the session and the popover does not, so that overstatement
/// then follows the user around until the next scan lands.
@Test func theMenuBarFollowsTheTicks() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "caches", sizeBytes: 40_200_000_000),
        makeItem(id: "devices", sizeBytes: 17_800_000_000),
    ]))
    #expect(MenuBarLabel.text(selection: selection, showsAmount: true) == "58.0 GB")

    selection.setTicked(false, for: "devices")
    #expect(MenuBarLabel.text(selection: selection, showsAmount: true) == "40.2 GB")

    // Everything unticked is not "no scan yet": after a scan, zero is the honest answer and
    // is shown. `nil` there would put the icon back to its before-the-first-scan look while a
    // measured result is sitting in the popover.
    selection.setTicked(false, for: "caches")
    #expect(MenuBarLabel.text(selection: selection, showsAmount: true) == "0 KB")
}

/// The one row that is deletable and starts unticked, at the one place the number is read
/// without the popover being open. `isDeletable` here promises 5.6 GB of network download a
/// default clean does not touch.
@Test func theMenuBarLeavesOutBytesThatAreOfferedButNotTicked() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "caches", sizeBytes: 40_200_000_000),
        makeItem(id: "ndk", sizeBytes: 5_570_000_000, startsUnticked: true),
    ]))

    #expect(MenuBarLabel.text(selection: selection, showsAmount: true) == "40.2 GB")
}

@Test func thePopoverIsTheSizeTheSpecAsksFor() {
    #expect(PopoverMetrics.width == 440)
    #expect(PopoverMetrics.maxHeight == 640)
}

/// The desktop window is the decision board, and landscape is the pin: three columns set
/// side by side so their bars can be compared against one board-wide scale. A window no
/// bigger than the popover would be the top-right surface moved to the middle of the screen,
/// and a portrait one would be three columns too narrow to hold a name, a tag and a size on
/// one line — which is the popover again, only worse.
@Test func theMainWindowOpensWideEnoughForThreeColumns() {
    #expect(MainWindowMetrics.defaultWidth == 1180)
    #expect(MainWindowMetrics.defaultHeight == 740)
    #expect(MainWindowMetrics.defaultWidth > PopoverMetrics.width)
    #expect(MainWindowMetrics.defaultHeight > PopoverMetrics.maxHeight)
    // Landscape, not portrait: the board is three columns wide before it is anything tall.
    #expect(MainWindowMetrics.defaultWidth > MainWindowMetrics.defaultHeight)
    // Resizable, but never below the width three columns need — about 300 points each once
    // the margins and gutters are taken out — nor below the height that leaves the header,
    // a screenful of rows and the footer's warning callout all readable.
    #expect(MainWindowMetrics.minWidth >= 980)
    #expect(MainWindowMetrics.minWidth >= PopoverMetrics.width)
    #expect(MainWindowMetrics.minHeight >= 560)
}

// MARK: - the footer

@Test func theCleanButtonCarriesTheLiveSelectedTotal() {
    var selection = SelectionModel(result: makeResult([
        makeItem(id: "a", sizeBytes: 40_200_000_000),
        makeItem(id: "b", sizeBytes: 17_800_000_000),
    ]))
    #expect(FooterModel(selection: selection, moveToTrash: true).cleanTitle == "Review 58.0 GB")

    selection.setTicked(false, for: "b")
    #expect(FooterModel(selection: selection, moveToTrash: true).cleanTitle == "Review 40.2 GB")
}

/// Two ticked rows naming one directory are one lot of bytes on disk, and the button says
/// so. `SelectionModel.selectedBytes` and `RemovalSplit` both de-duplicate on the deletion
/// target, exactly as the header's `reclaimableBytes` does; a hand-written `reduce(+)` in
/// the footer would put "Clean 58.0 GB" directly above a split line reading 40.2 GB.
@Test func theCleanButtonCountsOneTargetOnceWhenTwoRowsNameIt() {
    let oneDirectory = DeletionMethod.removePath("/tmp/one-directory")
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "a", sizeBytes: 40_200_000_000, method: oneDirectory),
        makeItem(id: "b", sizeBytes: 17_800_000_000, method: oneDirectory),
    ]))

    let footer = FooterModel(selection: selection, moveToTrash: true)
    #expect(footer.cleanTitle == "Review 40.2 GB")
    #expect(footer.splitText == "40.2 GB to the Trash · 0 KB permanent")
}

@Test func theCleanButtonIsDisabledWithNothingToClean() {
    var selection = SelectionModel(result: makeResult([makeItem(id: "a")]))
    selection.setTicked(false, for: "a")

    let footer = FooterModel(selection: selection, moveToTrash: true)
    #expect(!footer.isCleanEnabled)
    #expect(footer.cleanTitle == "Nothing selected")

    let empty = FooterModel(selection: nil, moveToTrash: true)
    #expect(!empty.isCleanEnabled)
}

/// Spec §7.3 and §8.2: what goes to the Trash and what is gone for good are different
/// amounts, and the second one is the one worth reading twice.
@Test func theFooterSplitsTheSelectionIntoTrashAndPermanent() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "cache", sizeBytes: 40_200_000_000),
        makeItem(id: "sim", sizeBytes: 17_800_000_000,
                 method: .deleteSimulator(udid: "AAA")),
    ]))

    let footer = FooterModel(selection: selection, moveToTrash: true)
    #expect(footer.splitText == "40.2 GB to the Trash · 17.8 GB permanent")
}

@Test func inPermanentModeEverythingCountsAsPermanent() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "cache", sizeBytes: 40_200_000_000),
        makeItem(id: "sim", sizeBytes: 17_800_000_000,
                 method: .deleteSimulator(udid: "AAA")),
    ]))

    let footer = FooterModel(selection: selection, moveToTrash: false)
    #expect(footer.splitText == "0 KB to the Trash · 58.0 GB permanent")
}

/// The warnings are the engine's sentences, shown **before** the button is pressed. There
/// is no Trash to look in afterwards.
@Test func thePermanenceWarningIsTheEnginesSentenceAndAppearsBeforehand() {
    let selection = SelectionModel(result: makeResult([
        makeItem(id: "cache", sizeBytes: 1),
        makeItem(id: "avd", sizeBytes: 1, method: .deleteAVD(name: "sample_emulator_1")),
    ]))

    let footer = FooterModel(selection: selection, moveToTrash: true)
    #expect(footer.warnings == [
        CleanerService.Warning.devicesAreRemovedPermanently,
        CleanerService.Warning.trashingDoesNotFreeSpaceYet,
    ])
    #expect(footer.warnings.first?.contains("normally removed permanently") == true)
    // A warning is something to read, not something to acknowledge. Every default clean on
    // a real dev machine removes a device — 17.8 GB of the 58.0 GB — so a footer that disabled
    // the button while a warning is showing would never let the normal clean run at all.
    #expect(footer.isCleanEnabled)
}

@Test func aSelectionWithNoDeviceInItRaisesNoPermanenceWarning() {
    let selection = SelectionModel(result: makeResult([makeItem(id: "cache")]))
    let footer = FooterModel(selection: selection, moveToTrash: true)

    #expect(footer.warnings == [CleanerService.Warning.trashingDoesNotFreeSpaceYet])
}

// MARK: - the progress lines

/// A run really stops; a scan really does not. No scanner checks for cancellation, so a
/// cancelled scan keeps measuring for its full ~51 seconds and only its result is thrown
/// away — `aCancelledScanIsNeitherShownNorCached` pins that the popover keeps the scan it
/// had. The footer shows Cancel in both states, so one sentence for both would promise the
/// wrong thing in one of them.
@MainActor
@Test func theCancelSentenceNeverPromisesThatAScanStops() {
    #expect(PopoverText.cancelHelp(phase: .running(nil))
        == "Cancelling stops before the next item. Anything already removed stays removed.")
    #expect(PopoverText.cancelHelp(phase: .scanning(nil))
        == "The scan carries on to the end. Cancelling only throws its result away, "
            + "leaving the numbers above as they are.")
    // A scan is a scan whether or not a report has arrived yet. Matching only the
    // report-less case would put the run's promise under a scan the moment it says
    // anything.
    #expect(PopoverText.cancelHelp(phase: .scanning(ScanProgress(
        completed: 3, total: 16, currentID: "android.avds",
        currentTitle: "Android emulators"))) == PopoverText.cancelDoesNotStopAScan)
    #expect(PopoverText.cancelHelp(phase: .idle) == PopoverText.cancelStopsBeforeTheNextItem)
    #expect(!PopoverText.cancelDoesNotStopAScan.lowercased().contains("stop"))
}

/// The words on the seven plain controls, pinned by value. Nothing else asserts them, and a
/// reworded button is a product change rather than a typo fix.
@Test func theControlsAndTheEmptyStateSayWhatTheyDo() {
    #expect(PopoverText.productName == "DevCleaner")
    #expect(PopoverText.reviewCleanup == "Review cleanup")
    #expect(PopoverText.rescan == "Rescan")
    #expect(PopoverText.settings == "Settings")
    #expect(PopoverText.quit == "Quit DevCleaner")
    #expect(PopoverText.cancel == "Cancel")
    #expect(PopoverText.done == "Done")
    #expect(PopoverText.openRunLog == "Show the run log in Finder")
    #expect(PopoverText.noScanYet == "No scan yet. Choose Rescan to measure your caches.")
    // The empty state sends the user to a button that exists, by the name it really has.
    // Renaming the button without rewording the sentence leaves an instruction naming a
    // control that is not on screen.
    #expect(PopoverText.noScanYet.contains(PopoverText.rescan))
}

@Test func theReviewUsesTheSelectionCountAndSelectedBytes() {
    #expect(PopoverText.selectedItemCount(1) == "1 selected item")
    #expect(PopoverText.selectedItemCount(3) == "3 selected items")
    #expect(PopoverText.confirmationTitle(bytes: 58_000_000_000) == "Clean 58.0 GB")
}

/// The board's legend, pinned by value the same way the controls above are.
///
/// The third entry does not claim to be a tier — the first two are `DecisionTier.title` and
/// name columns, while this one names whatever the user has left unticked, spread across both
/// of them. A legend that called it "Kept" would be the kept column's name over a segment the
/// kept column has nothing to do with.
@Test func theSplitBarLegendNamesTheDashedSegmentWithoutClaimingItIsATier() {
    #expect(DecisionBoardText.untickedLegend == "Offered, not ticked")
    #expect(DecisionBoardText.groupLegendLead == "Dots mark where things live:")
    #expect(DecisionTier.allCases.map(\.title).contains(DecisionBoardText.untickedLegend)
        == false)
}

/// Two different dots. Drawn alike, the key would say the unticked bytes are part of the plan
/// — which is the one thing the dashed segment exists to deny.
@Test func theOfferedSegmentIsMarkedWithADifferentDotFromThePlannedOnes() {
    #expect(DecisionBoardText.solidDot != DecisionBoardText.hollowDot)
    #expect(DecisionBoardText.solidDot == "●")
    #expect(DecisionBoardText.hollowDot == "◌")
}

// MARK: - the tick box

@Test func aClickFillsAnyBoxThatIsNotAlreadyFull() {
    #expect(GroupTick.none.ticksOnClick)
    // A partly ticked group fills up. Emptying it would throw away ticks the user put
    // there on purpose, and the box gives no hint which of the two it would do.
    #expect(GroupTick.some.ticksOnClick)
    #expect(!GroupTick.all.ticksOnClick)
}

@Test func eachTickStateDrawsItsOwnBox() {
    #expect(GroupTick.all.symbolName == "checkmark.square.fill")
    #expect(GroupTick.some.symbolName == "minus.square.fill")
    #expect(GroupTick.none.symbolName == "square")
    // Three states, three different glyphs. Two states sharing one would put a box on
    // screen whose click the user cannot predict.
    let symbols = Set([GroupTick.all, .some, .none].map(\.symbolName))
    #expect(symbols.count == 3)
}

/// Both report-less lines are pinned to their words as well as to their constants.
///
/// `producer(nil) == theConstant` on its own passes if both are `""`, which is a blank line
/// where the popover should be saying why it is going to sit there for a minute. The scan
/// sentence carries the wait — about a minute, on a machine where a full scan really takes
/// 51 seconds — and that promise is the whole reason the line exists.
@Test func theProgressLinesNameWhatIsHappening() {
    #expect(PopoverText.scanTakesAMinute
        == "Measuring every cache with du. This takes about a minute.")
    #expect(PopoverText.scanning(nil) == PopoverText.scanTakesAMinute)
    #expect(PopoverText.scanning(ScanProgress(
        completed: 3, total: 16, currentID: "android.avds",
        currentTitle: "Android emulators")) == "[3/16] Android emulators")

    #expect(PopoverText.runStarting == "Starting")
    #expect(PopoverText.running(nil) == PopoverText.runStarting)
    #expect(PopoverText.running(ExecutionProgress(
        completed: 7, total: 48, currentName: "DerivedData")) == "[7/48] DerivedData")
}
