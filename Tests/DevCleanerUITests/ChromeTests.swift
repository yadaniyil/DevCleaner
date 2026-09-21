import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

// The chrome both surfaces share: the window's size, and the handful of words neither of
// them owns. The menu bar item itself is in `StatusPanelTests`, beside the amount it shows.

// MARK: - the window

/// The desktop window is one card at a time, and portrait is the pin: a card is a name, a
/// path, one very large number and a stack of folder bars, read top to bottom. The width the
/// old decision board needed was for three columns side by side, and there are no columns
/// any more — a 34-point row holding one folder name and one size is mostly empty track at
/// 1180 points.
///
/// It is much bigger than the menu bar panel in both directions, and it has to be: the panel
/// is a glance at one number, and this is where every card, every folder bar and the 96-point
/// gain figure live.
@Test func theMainWindowOpensAsAPortraitCardRatherThanALandscapeBoard() {
    #expect(MainWindowMetrics.defaultWidth == 600)
    #expect(MainWindowMetrics.defaultHeight == 740)
    // Portrait, not landscape: the card is a column.
    #expect(MainWindowMetrics.defaultHeight > MainWindowMetrics.defaultWidth)
    // Resizable, but never below the width a folder row needs for its name, its restore
    // hint and its size on one line, nor below the height of the parts that cannot scroll:
    // the strip, the card's heading and gain, two rows, and the pinned action area.
    #expect(MainWindowMetrics.minWidth == 520)
    #expect(MainWindowMetrics.minHeight == 620)
    #expect(MainWindowMetrics.minWidth <= MainWindowMetrics.defaultWidth)
    #expect(MainWindowMetrics.minHeight <= MainWindowMetrics.defaultHeight)
    // The column may fill the default window, and must not be narrower than it.
    #expect(MainWindowMetrics.maxContentWidth >= MainWindowMetrics.defaultWidth)
}

// MARK: - the words neither surface owns

/// The three plain strings both windows draw, pinned by value. Nothing else asserts them,
/// and a reworded control is a product change rather than a typo fix.
@Test func theSharedControlsSayWhatTheyDo() {
    #expect(ChromeText.productName == "DevCleaner")
    #expect(ChromeText.settings == "Settings")
    #expect(ChromeText.runStarting == "Starting")
}

// MARK: - the progress lines

/// Both report-less lines are pinned to their words as well as to their constants.
///
/// `producer(nil) == theConstant` on its own passes if both are `""`, which is a blank line
/// where the app should be saying why it is going to sit there for a minute. The scan
/// sentence carries the wait — about a minute, on a machine where a full scan really takes
/// 51 seconds — and that promise is the whole reason the line exists.
@Test func theProgressLinesNameWhatIsHappening() {
    #expect(ChromeText.scanTakesAMinute
        == "Measuring every cache with du. This takes about a minute.")
    #expect(ChromeText.scanning(nil) == ChromeText.scanTakesAMinute)
    #expect(ChromeText.scanning(ScanProgress(
        completed: 3, total: 16, currentID: "android.avds",
        currentTitle: "Android emulators")) == "[3/16] Android emulators")

    #expect(ChromeText.running(nil) == ChromeText.runStarting)
    #expect(ChromeText.running(ExecutionProgress(
        completed: 7, total: 48, currentName: "DerivedData")) == "[7/48] DerivedData")
}
