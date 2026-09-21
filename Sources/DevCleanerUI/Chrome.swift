import Foundation
import CoreGraphics
import CleanerCore

/// The main desktop window: one card at a time, and the whole of the app.
///
/// The card asks one question — *may this go?* — about one project, one scanner or one of
/// the user's own files, and the shape follows from what that question needs to be readable.
/// Portrait, because a card is a name, a path, one very large number and a short stack of
/// folder bars — a column, read top to bottom — and the deck is the skyline above it. 600
/// points is about as wide as those bars want to be: wider, and a 34-point row holding one
/// folder name and one size is mostly empty track.
///
/// The menu bar is a 300-point status item now (`StatusPanelMetrics`), so this is the only
/// surface that removes anything. Nothing about that width constrains this one; they answer
/// different questions, and the strip's is "is it worth opening this?".
///
/// The minimum is the smallest frame at which the card is still the card. 520 points is where
/// the gain number set at 96 points and its unit still fit on one line beside nothing else,
/// and where a folder row can hold a name, its restore hint and its size without the hint
/// truncating to an ellipsis on every row. 620 points is the height of the parts that cannot
/// scroll — the strip, the card's heading and gain, two folder rows, and the pinned action
/// area — which is the point below which shrinking the window starts hiding the thing the
/// user is answering rather than the list underneath it.
public enum MainWindowMetrics {
    /// The `Window` scene's identifier, named in one place.
    ///
    /// `DevCleanerApp` declares the scene with it and the menu bar panel's primary button
    /// passes it to `openWindow(id:)`. `openWindow` does nothing at all — silently — when the
    /// identifier matches no scene, so two spellings would leave the panel's one real button
    /// dead with nothing on screen saying why.
    ///
    /// `deck`, not the `main` it was while this window was a landscape board. macOS keys a
    /// window's remembered frame on it, and the remembered frame of `main` is that board's —
    /// nearly 1300 points wide — so keeping the name would open the portrait deck inside the
    /// old window's shape on every Mac that ever ran it. A new name has no remembered frame,
    /// and `defaultSize` applies again.
    public static let sceneID = "deck"

    public static let defaultWidth: CGFloat = 600
    public static let defaultHeight: CGFloat = 740
    public static let minWidth: CGFloat = 520
    public static let minHeight: CGFloat = 620
    /// How wide the deck's column grows inside a window dragged wider than it needs.
    ///
    /// macOS restores a window's last frame, and the frame this window had before it was a
    /// deck was a 1180-point board — so the first launch of the deck opened it nearly 1300
    /// points wide, with a 30 MB folder drawn as a bar a foot long and Skip and Clean up at
    /// opposite edges of the screen. Past this width the column stays put, centred, and the
    /// extra window is margin. A little over the default so the default window is all card.
    public static let maxContentWidth: CGFloat = 680
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
    /// After a scan, "0 KB" is honest and is shown: it says a pass through the window would
    /// remove nothing, which is exactly true of a machine whose only cards are the user's own
    /// files.
    ///
    /// From the **deck**, through `ProjectDeck.defaultOfferText`, which is also what the panel
    /// under this label prints. One value read twice: the label and the panel are on screen
    /// together the moment anybody clicks the icon, and the old pair — a label totalling the
    /// scan beside a header totalling the live ticks — could differ by 19 GB on one screen.
    ///
    /// `ScanResult.reclaimableBytes` is deliberately not it, and neither is the sum over
    /// `isDeletable`; `ProjectDeck.defaultOfferBytes` carries all three reasons.
    public static func text(deck: ProjectDeck?, showsAmount: Bool) -> String? {
        guard showsAmount, let deck else { return nil }
        return deck.defaultOfferText
    }
}

/// The words both surfaces say.
///
/// Was `PopoverText`, while the popover was the app and the window borrowed from it. It is
/// the other way round now — these are the product's name, the Settings label and the
/// engine's two progress lines, and both the window and the menu bar panel draw them — so
/// the name no longer claims an owner.
public enum ChromeText {
    public static let productName = "DevCleaner"
    public static let settings = "Settings"
    public static let scanTakesAMinute =
        "Measuring every cache with du. This takes about a minute."
    public static let runStarting = "Starting"

    /// "[3/16] Android emulators" — the engine's own account of where a scan has got to.
    ///
    /// Read by the window's empty state and by the menu bar panel, so a scan the user
    /// started from either place is reported in the same words wherever they are looking.
    public static func scanning(_ progress: ScanProgress?) -> String {
        guard let progress else { return scanTakesAMinute }
        return "[\(progress.completed)/\(progress.total)] \(progress.currentTitle)"
    }

    public static func running(_ progress: ExecutionProgress?) -> String {
        guard let progress else { return runStarting }
        return "[\(progress.completed)/\(progress.total)] \(progress.currentName)"
    }
}
