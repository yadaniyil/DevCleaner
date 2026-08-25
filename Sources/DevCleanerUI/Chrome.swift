import Foundation
import CoreGraphics
import CleanerCore

/// A compact menu-bar window with enough width for names, sizes and safety labels.
public enum PopoverMetrics {
    public static let width: CGFloat = 440
    public static let maxHeight: CGFloat = 640

    /// What the group list is allowed to take: never less than one row, never more than
    /// this, and otherwise exactly as tall as its content.
    ///
    /// A `ScrollView` has no height of its own — it takes whatever it is offered. Under a
    /// `maxHeight` alone the enclosing stack sizes to its children's ideal heights, the
    /// scroll view's ideal height is zero, and the list collapses to nothing: the popover
    /// draws its header, a rule, and then the footer, with the whole point of the app
    /// missing in between. Nothing in the test suite can see that, because the collapse
    /// happens in layout, and no test can import the view that does it.
    ///
    /// A fixed height fixes the collapse and buys a second problem — five collapsed groups
    /// need about 150 points, so the rest is a grey void above the warnings. So the list is
    /// measured and clamped instead. `listMaxHeight` leaves room for the header, warning
    /// callout and action bar inside `maxHeight`. The popover clips rather than compresses
    /// if those fixed sections and the list ask for more than the maximum, so the list
    /// stays deliberately bounded.
    public static let listMinHeight: CGFloat = 44
    public static let listMaxHeight: CGFloat = 330
}

/// The main desktop window: a landscape decision board, not a taller popover.
///
/// The popover stays at 440 points because a menu bar window that big again would cover half
/// the screen it drops from, and it answers "which technology is this cache from?" — one
/// column of five collapsible groups, which is exactly the shape a narrow strip wants.
///
/// This window answers a different question, so it is a different shape. It sets the three
/// decisions side by side — safe, think twice, kept — and side by side is the whole point:
/// the bars are scaled against one board-wide maximum, so a 19 GB row in the middle column
/// draws visibly longer than a 200 MB row in the left one, and a user who reads only the
/// first column has still read a true offer. Three columns of names, sizes and tags need
/// width the way the popover needs height, which is why the default is landscape rather than
/// the 760×800 portrait this window used while it was still the popover with room to breathe.
///
/// The minimum is the smallest frame at which that arrangement is still what it claims to be:
/// 980 points is about 300 per column once the 20-point margins and two 14-point gutters are
/// taken out, which is where a bar row can still hold a name, a tag chip and a size on one
/// line, and 600 points is where the header, one screenful of rows and a footer whose warning
/// callout still reads as sentences all fit without the columns collapsing to a scroll bar
/// each. Below either, the board would be three narrow lists — which is the popover again,
/// only worse.
public enum MainWindowMetrics {
    public static let defaultWidth: CGFloat = 1180
    public static let defaultHeight: CGFloat = 740
    public static let minWidth: CGFloat = 980
    public static let minHeight: CGFloat = 600
}

/// Spec §8.1: a template icon plus the reclaimable amount, toggleable to icon-only.
public enum MenuBarLabel {
    /// A template symbol, so the system tints it for the current menu bar appearance.
    public static let symbolName = "internaldrive"
    public static let accessibilityTitle = "DevCleaner"

    /// The text beside the icon, or `nil` for icon only.
    ///
    /// `nil` before the first scan as well as when the setting is off. There is no honest
    /// number yet, and "0 GB" in the menu bar would say the machine has nothing to clean.
    /// After a scan, "0 KB" is honest and is shown: it says a clean would remove nothing,
    /// which is exactly true of a list the user has unticked.
    ///
    /// From the **selection**, not from `ScanResult.reclaimableBytes`. Both are on screen at
    /// once whenever the popover is open, so the scan's frozen default beside a header that
    /// follows the ticks is the same "two numbers, one screen" the header itself was just
    /// fixed for — untick the 19.0 GB emulator and the menu bar says 58.0 GB above a popover
    /// saying `up to 39.0 GB`. It outlives the popover, too: ticks last for the session, so a
    /// menu bar built from the scan overstates what a clean would do until the next one lands.
    public static func text(selection: SelectionModel?, showsAmount: Bool) -> String? {
        guard showsAmount, let selection else { return nil }
        return ByteText.short(selection.selectedBytes)
    }
}

/// Spec §8.2's footer: the primary button labelled with the live selected total, and what
/// pressing it would really do.
public struct FooterModel: Sendable, Equatable {
    public let cleanTitle: String
    public let isCleanEnabled: Bool
    /// "40.2 GB to the Trash · 17.8 GB permanent".
    public let splitText: String
    /// Shown **above** the button, before anything happens.
    public let warnings: [String]

    public init(selection: SelectionModel?, moveToTrash: Bool) {
        let items = selection?.selectedItems ?? []
        let bytes = selection?.selectedBytes ?? 0
        cleanTitle = items.isEmpty ? "Nothing selected" : "Review \(ByteText.short(bytes))"
        // Only whether anything is ticked. **Not** whether a warning is showing: a
        // permanence warning is raised by every default clean on a real dev machine — 17.8 GB of
        // the 58.0 GB is simulators and emulators — so disabling the button whenever
        // `warnings` is non-empty would leave it unpressable on the normal case. The
        // warning is there to be read, not to be acknowledged.
        isCleanEnabled = !items.isEmpty

        // `RemovalSplit` rather than a second sum here: it divides by whether a row can be
        // got back, which is not `moveToTrash` alone — `simctl delete`,
        // `simctl runtime delete` and `avdmanager delete avd` have no Trash whatever that
        // setting says — and it totals each side with the same de-duplicating rule as the
        // headline.
        let split = RemovalSplit(items: items, moveToTrash: moveToTrash)
        splitText = "\(ByteText.short(split.trashBytes)) to the Trash · "
            + "\(ByteText.short(split.permanentBytes)) permanent"

        // The engine's own sentences, conditional on the selection so neither becomes
        // wallpaper. "Normally removed permanently" is load-bearing: one fallback path,
        // used only when the Android command line tools are missing, really does use the
        // Trash. Writing a stronger sentence here would be a lie on that machine.
        warnings = CleanerService.warnings(for: items, moveToTrash: moveToTrash)
    }
}

/// What a tick box draws, and what clicking it asks for.
///
/// Both belong to the state rather than to the view. A view holding this table is a view
/// deciding what a click does: swapping the `.all` and `.none` glyphs, or turning
/// `ticksOnClick` into `self == .none`, changes what the user sees and what their click
/// removes, and neither is reachable from a test while it sits in `DevCleanerApp`.
extension GroupTick {
    /// SF Symbol names, one per state. Three different boxes, so no two states look alike:
    /// a `.some` group drawn as `.none` invites a click that empties it instead of filling
    /// it.
    public var symbolName: String {
        switch self {
        case .all:  return "checkmark.square.fill"
        case .some: return "minus.square.fill"
        case .none: return "square"
        }
    }

    /// What the next click asks for. Only a full box unticks: a partly ticked group fills
    /// up, which is what a mixed box invites and the reading that cannot throw away ticks
    /// the user put there on purpose.
    public var ticksOnClick: Bool { self != .all }
}

/// Every other word the popover says.
public enum PopoverText {
    public static let productName = "DevCleaner"
    public static let reviewCleanup = "Review cleanup"
    public static let rescan = "Rescan"
    public static let settings = "Settings"
    public static let quit = "Quit DevCleaner"
    public static let cancel = "Cancel"
    public static let done = "Done"
    public static let openRunLog = "Show the run log in Finder"
    public static let noScanYet = "No scan yet. Choose Rescan to measure your caches."
    public static let scanTakesAMinute =
        "Measuring every cache with du. This takes about a minute."
    public static let runStarting = "Starting"
    /// Shown beside the Cancel button during a run.
    ///
    /// Says nothing about a scan on purpose. No scanner checks for cancellation, so a
    /// cancelled scan keeps measuring for its full ~51 seconds and only its result is
    /// thrown away; a sentence promising it stops sooner would be false.
    public static let cancelStopsBeforeTheNextItem =
        "Cancelling stops before the next item. Anything already removed stays removed."
    /// Shown beside the same Cancel button during a **scan**, where the promise above
    /// would be false: no scanner checks for cancellation, so the measuring carries on for
    /// its full ~51 seconds and the only thing the button can do is throw the result away.
    public static let cancelDoesNotStopAScan =
        "The scan carries on to the end. Cancelling only throws its result away, "
        + "leaving the numbers above as they are."

    /// Which of the two sentences belongs beside Cancel.
    ///
    /// Takes the phase, not a `Bool`. Reducing four states to "is this a scan" **is** the
    /// decision, and in `DevCleanerApp` no test could reach it: a view that answered `false`
    /// would put the run's promise back under a scan, which is the exact sentence this pair
    /// exists to keep apart.
    public static func cancelHelp(phase: AppModel.Phase) -> String {
        if case .scanning = phase { return cancelDoesNotStopAScan }
        return cancelStopsBeforeTheNextItem
    }

    public static func scanning(_ progress: ScanProgress?) -> String {
        guard let progress else { return scanTakesAMinute }
        return "[\(progress.completed)/\(progress.total)] \(progress.currentTitle)"
    }

    public static func running(_ progress: ExecutionProgress?) -> String {
        guard let progress else { return runStarting }
        return "[\(progress.completed)/\(progress.total)] \(progress.currentName)"
    }

    public static func selectedItemCount(_ count: Int) -> String {
        "\(count) selected item\(count == 1 ? "" : "s")"
    }

    public static func confirmationTitle(bytes: Int64) -> String {
        "Clean \(ByteText.short(bytes))"
    }
}

/// The words under the split bar: the key to the dashed segment, and the key to the coloured
/// dots beside the row names.
///
/// Here beside `PopoverText` rather than in the window that draws them, for the same reason
/// `MenuBarLabel` is here rather than in the menu bar item: a string in `DevCleanerApp` is a
/// string no test can read, and "Offered, not ticked" is the only thing on that screen that
/// names the dashed segment — the two solid entries take their names from `DecisionTier.title`,
/// which the column headings below already use. Left in the view, the legend could come to
/// call it something the columns do not, and nothing would fail.
///
/// The two glyphs are here with the words they punctuate rather than with the colours in
/// `DecisionStyle`, because they are characters the user reads and not a tint: swapping the
/// filled dot for the hollow one would say the unticked bytes are going.
public enum DecisionBoardText {
    /// Beside a segment that is part of the plan.
    public static let solidDot = "●"
    /// Beside the dashed segment. Hollow because the bytes it labels are an offer rather than
    /// a plan, which is the same reading the bar itself draws.
    public static let hollowDot = "◌"
    /// The third entry of the legend. The first two are `DecisionTier.title`; this one names
    /// the dashed segment, which is not a tier — it is whatever the user has left unticked,
    /// spread across the two that are.
    public static let untickedLegend = "Offered, not ticked"
    /// The lead-in to the group key. It says what the dots are *for*: the board stopped
    /// sorting by technology, so a row's dot is the only thing left that says it is an Android
    /// row, and a bare row of coloured dots would be a key to nothing.
    public static let groupLegendLead = "Dots mark where things live:"
}
