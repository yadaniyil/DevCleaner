import Foundation
import CleanerCore

/// One entry of the key that tells the dots apart: a group, and the name beside its dot.
///
/// A type rather than the view walking `GroupID.allCases` itself, for the reason `BarSegment`
/// is a type: the order is a decision — it is `GroupList.sections`' order, so the key reads in
/// the order the popover lists the same five groups — and an order chosen inside a `reduce` in
/// `DevCleanerApp` is an order no test can see. The colour is deliberately not here: it is a
/// tint, it changes nothing about what a click removes, and putting it here would make this
/// library import SwiftUI.
public struct GroupLegendEntry: Sendable, Equatable, Identifiable {
    public let id: GroupID
    public let title: String
}

/// Everything above the three columns: the amount, the sentence that keeps it honest, how
/// much room there is now, when this was measured, the split bar, and anything that went
/// wrong while measuring.
///
/// The same rules as `HeaderModel`, said for a window rather than a popover. It is a separate
/// type instead of a field added to that one because the two headers answer with different
/// shapes — this one has no per-group stacked bar at all, since the board it sits above has
/// stopped sorting by group — and a single struct carrying both would leave every view
/// choosing which half to believe.
///
/// What is **not** duplicated: the problems list, which is `HeaderModel.problems(of:)`, so
/// both surfaces name a refused project root with the same words in the same order.
public struct DecisionHeaderModel: Sendable, Equatable {
    /// "You can free up to". A separate field from the number, so the view can set it in a
    /// smaller face and still never lose it — a bare "58.0 GB" in large type is a promise the
    /// tool cannot keep.
    public let amountPrefix: String
    public let amountText: String
    /// The sentence under the amount, and the only place the shared-bytes admission appears
    /// on this screen.
    ///
    /// Always present, unlike `HeaderModel.rangeText`, which is `nil` when nothing is shared.
    /// A header whose second line comes and goes moves the whole board up and down as the
    /// user ticks the pnpm store, so the sentence stays and only grows its second clause.
    public let captionText: String
    public let freeSpaceText: String
    public let scanAgeText: String

    /// The ticked bytes in the safe column — the same number the column's own total shows.
    public let safeBytes: Int64
    /// The ticked bytes in the think-twice column.
    public let thinkTwiceBytes: Int64
    /// Deletable bytes the user has **not** ticked: `SelectionModel.unselectedDeletableBytes`,
    /// which counts a row the user unticked by hand exactly as it counts the Android NDK. It
    /// is the segment that says what is still on the table.
    public let untickedBytes: Int64

    /// Named `…SizeText` rather than `untickedText`, deliberately. `HeaderModel.untickedText`
    /// is a *sentence* — "5.6 GB more is offered but not ticked" — and these three are bare
    /// sizes for a bar's labels. Two fields one word apart, one a sentence and one a number,
    /// is how a view ends up printing a size where a sentence belongs.
    public let safeSizeText: String
    public let thinkTwiceSizeText: String
    public let untickedSizeText: String

    /// The same size again, and `nil` when there is nothing left unticked — which is the
    /// legend's third entry appearing and disappearing, in the model rather than in the view.
    ///
    /// The entry is dropped rather than shown as "0 KB" because the segment it labels is not
    /// on the bar either: `TierSplitBar` draws no zero-width block, and a colour key to a
    /// block nobody can see is a legend entry for nothing. That is a decision about what the
    /// user sees, so it is here for the same reason `HeaderModel.untickedText` and
    /// `HeaderModel.rangeText` are optional rather than empty — a `> 0` written into the view
    /// is a branch no test can reach, and the failure it hides is silent: the legend would
    /// simply be one entry longer than the bar.
    ///
    /// `untickedSizeText` above stays unconditional. It is one of three bar labels that are
    /// read as a set, and a `nil` in the middle of that set would be a different kind of
    /// absence than this one.
    public let untickedLegendSizeText: String?

    /// The key to the dots, in `GroupList.sections` order. Always all five groups, including
    /// any that contributed no rows to this scan: it is a key to the colours the board uses,
    /// not a summary of what was found, and a key that lost its entries as a machine got
    /// cleaner would leave a dot on screen with nothing explaining it.
    public let groupLegend: [GroupLegendEntry]

    /// `0...1`, each a share of ticked **plus** unticked.
    ///
    /// Not a share of the ticked total. The dashed unticked segment has to fit in the same
    /// bar as the two solid ones — that is what makes the bar readable as "here is what a
    /// clean takes, and here is what it leaves" — and dividing by the ticked total alone
    /// gives the unticked segment a width greater than the whole bar whenever more is left
    /// than taken, which on a default scan of a machine with a big NDK is the normal case.
    ///
    /// Protected bytes are in neither: they are not offered, so they are not on the table and
    /// giving them width would say a clean might take them.
    public let safeFraction: Double
    public let thinkTwiceFraction: Double
    public let untickedFraction: Double

    /// Things that went wrong or were switched off, in the user's words. Empty is the normal
    /// case. `HeaderModel`'s own list, not a second copy of the rule.
    public let problems: [String]

    /// The selection is not optional, and every amount comes from it rather than from the
    /// scan — the same rule, and for the same reason, as `HeaderModel.init`.
    /// `ScanResult.reclaimableBytes` is the scan's default tick frozen at the moment the scan
    /// landed, so a header built from it puts two disagreeing numbers on one screen the
    /// instant a box is clicked. Free space and the age of the scan stay scan-derived:
    /// neither moves when a box is clicked.
    public init(result: ScanResult, selection: SelectionModel, now: Date, home: String) {
        let reporter = ReportText(home: home)
        let top = selection.selectedBytes
        let shared = selection.selectedPossiblySharedBytes

        amountPrefix = "You can free up to"
        // `top` itself: the **upper** end, never the lower one and never the two added
        // together. Printing the lower end would invert the prefix above it — "up to 56.2 GB"
        // over a clean that removes 58.0 GB.
        amountText = ByteText.short(top)
        // The honest-range rule of `HeaderModel.rangeText`, rewritten as a sentence because
        // this header has room for one. The clause is the whole point: the pnpm store and the
        // bun cache may share blocks with `node_modules` that are staying, and those bytes
        // come back only when the last reference goes. Dropping it turns an upper bound into
        // a promise.
        captionText = shared > 0
            ? "That's everything ticked below. At least \(ByteText.short(top - shared)) of it "
                + "comes back for sure — \(ByteText.short(shared)) may be shared with files "
                + "that are staying."
            : "That's everything ticked below."
        freeSpaceText = "\(ByteText.short(result.availableBytes)) free"
        scanAgeText = "scanned \(AgeText.since(result.generatedAt, now: now))"

        // `DecisionBoardModel.bytes(in:)`, the same call each column's own total is drawn
        // from, so a segment of this bar and the number at the top of the column below it
        // cannot disagree. Never a hand-written sum over the tiers: that is a second
        // de-duplicating rule, and `ScanResult.totalBytes` is the only one this app has.
        safeBytes = DecisionBoardModel.bytes(in: .safe, result: result, selection: selection)
        thinkTwiceBytes = DecisionBoardModel.bytes(
            in: .thinkTwice, result: result, selection: selection)
        untickedBytes = selection.unselectedDeletableBytes

        safeSizeText = ByteText.short(safeBytes)
        thinkTwiceSizeText = ByteText.short(thinkTwiceBytes)
        untickedSizeText = ByteText.short(untickedBytes)
        // `> 0`, not a rounding threshold: a single unticked kilobyte is still an offer, and
        // the bar gives it a segment, so the legend gives it an entry.
        untickedLegendSizeText = untickedBytes > 0 ? untickedSizeText : nil

        groupLegend = GroupID.allCases.map { GroupLegendEntry(id: $0, title: $0.title) }

        // Zero on a machine with nothing to clean, and the guard is reachable: an empty scan,
        // or one where every deletable row has been unticked, leaves all three at zero. The
        // fallback draws no bar at all, which is the one reading consistent with a board
        // offering nothing.
        let onTheTable = safeBytes + thinkTwiceBytes + untickedBytes
        func share(_ bytes: Int64) -> Double {
            guard onTheTable > 0 else { return 0 }
            return Double(bytes) / Double(onTheTable)
        }
        safeFraction = share(safeBytes)
        thinkTwiceFraction = share(thinkTwiceBytes)
        untickedFraction = share(untickedBytes)

        problems = HeaderModel.problems(of: result, reporter: reporter)
    }
}
