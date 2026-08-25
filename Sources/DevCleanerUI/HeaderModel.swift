import Foundation
import CleanerCore

/// One block of the thin stacked bar in the header, per spec §8.2.
public struct BarSegment: Sendable, Equatable, Identifiable {
    public let id: GroupID
    public let title: String
    public let bytes: Int64
    /// `0...1`. The view multiplies this by its width; it never divides.
    public let fraction: Double

    /// The hover text: which group this block is, and what it contributes.
    ///
    /// Here rather than in the view so the block's size goes through `ByteText.short` like
    /// every other size on screen, and so the pairing is pinned by a test. A computed
    /// property, so the initialiser and every existing caller are untouched.
    public var helpText: String { "\(title): \(ByteText.short(bytes))" }
}

/// Everything above the divider: the amount, what it is really worth, how much room there
/// is now, when this was measured, and anything that went wrong while measuring it.
public struct HeaderModel: Sendable, Equatable {
    /// "up to". A separate field from the number so the view can set it in a smaller face
    /// and still never lose it — a bare "58.0 GB" in large type is a promise the tool
    /// cannot keep.
    public let amountPrefix: String
    public let amountText: String
    /// The honest range, present only when some of the bytes may be shared with files
    /// that are staying. `nil` means the single number is the whole truth.
    public let rangeText: String?
    /// The full sentence, for hover. `ReportText.headline`, unmodified — and **empty** once
    /// the user has changed a tick.
    ///
    /// The engine's sentence describes the scan's own default tick, so it is only true while
    /// the ticks still are that. Served regardless, it contradicts the number it is there to
    /// explain: untick the 19.0 GB emulator and the header reads `up to 30.0 GB` above a
    /// hover reading `up to 49.0 GB`.
    ///
    /// Empty rather than reworded, and empty rather than rebuilt. Writing a second version of
    /// the sentence in the app is what `theHeadlineHelpKeepsTheEnginesSharedSentence` exists
    /// to forbid — it is the clause admitting that some of the bytes may never come back that
    /// a hand-written copy loses. Feeding the ticked rows back through
    /// `ReportText.headline` would be worse: it totals `selectedByDefault`, so a row the user
    /// ticked by hand would drop straight back out of its own sentence.
    ///
    /// An empty string, not an optional, so the view's `.help(model.headlineHelp)` needs no
    /// branch of its own — and a branch in the view is a decision no test can reach.
    public let headlineHelp: String
    public let freeSpaceText: String
    public let scanAgeText: String
    /// "5.6 GB more is offered but not ticked", or `nil`.
    public let untickedText: String?
    public let segments: [BarSegment]
    /// Things that went wrong or were switched off, in the user's words. Empty is the
    /// normal case.
    public let problems: [String]

    /// The selection is not optional, and the amount comes from it rather than from the
    /// scan.
    ///
    /// `ScanResult.reclaimableBytes` is the scan's **default** tick, frozen at the moment
    /// the scan landed. The group headlines and the Clean button already follow the user's
    /// ticks, so a header built from the scan puts two disagreeing numbers on one screen:
    /// untick the 19.0 GB emulator and the footer says `Clean 39.0 GB` under a header still
    /// reading `up to 58.0 GB` with the Android block at full width. The unticked line
    /// inverts outright — tick the Android NDK and `5.6 GB more is offered but not ticked`
    /// stays on screen beside a button that has just added exactly that 5.6 GB.
    ///
    /// Free space and the age of the scan stay scan-derived below: neither moves when a box
    /// is clicked.
    public init(result: ScanResult, selection: SelectionModel, now: Date, home: String) {
        let reporter = ReportText(home: home)
        // `SelectionModel.selectedBytes`, which totals the ticked rows and de-duplicates
        // targets — the same rule as `reclaimableBytes` applied to the live ticks, and the
        // same value the Clean button carries. Never `isDeletable`: the two Android NDK rows
        // are deletable and start unticked, and a headline built from `isDeletable` promises
        // 5.57 GB of re-download nobody asked for.
        let top = selection.selectedBytes
        let shared = selection.selectedPossiblySharedBytes

        amountPrefix = "up to"
        // `top` itself: the **upper** end of the range, never the lower one and never the
        // two ends added together. Printing the lower end would be this model's own rule
        // inverted — "up to 56.2 GB" above a clean that removes 58.0 GB — and it is only
        // visible on a scan that has shared bytes in it, which is what
        // `theHeadlineNumberIsTheTopOfTheRangeAndNotTheBottom` exists to provide.
        amountText = ByteText.short(top)
        // Printed as a range rather than one figure, because a single number there would
        // be wrong at one end or the other: the pnpm store and the bun cache may share
        // blocks with `node_modules` that are staying, and those bytes come back only
        // when the last reference goes.
        rangeText = shared > 0
            ? "\(ByteText.short(top - shared)) – \(ByteText.short(top)), because "
                + "\(ByteText.short(shared)) of it may be shared with files that are staying"
            : nil
        // `isDefaultSelection` — the same question `AppModel.startClean` asks before choosing
        // between `cleanDefault` and `clean(items:)`. One rule, one place: the sentence is
        // shown exactly when the engine would re-derive the same list it describes.
        headlineHelp = selection.isDefaultSelection ? ReportText.headline(result) : ""
        freeSpaceText = "\(ByteText.short(result.availableBytes)) free"
        scanAgeText = "scanned \(AgeText.since(result.generatedAt, now: now))"

        // Kept apart from the headline on purpose: the Android NDK is offered and not
        // ticked, and adding it to the amount would promise 5.57 GB a default clean does
        // not touch.
        //
        // From the selection, so ticking that NDK removes the sentence instead of leaving it
        // contradicting the button. `ScanResult.untickedDeletableBytes` answers for the
        // scan's default tick and cannot see a click.
        let unticked = selection.unselectedDeletableBytes
        untickedText = unticked > 0
            ? "\(ByteText.short(unticked)) more is offered but not ticked"
            : nil

        // `GroupID.allCases` order, which is the order `GroupList.sections` draws the
        // sections in. A bar sorted by size would put its widest block above a section
        // that is third down the list, and the block would then be read as belonging to
        // whatever section it happens to sit over.
        var contributions: [(GroupID, Int64)] = []
        for group in GroupID.allCases {
            // `selectedBytes(in:)`, the same call the group headline beside each section
            // uses — never a hand-written sum over `items(in:)`, never `isDeletable`, and
            // never the scan's `reclaimableBytes(in:)`, which would leave the Android block
            // at full width over a section whose own headline has just dropped 19.0 GB.
            let bytes = selection.selectedBytes(in: group)
            // A group holding only protected rows contributes no width. Drawing it as a
            // sliver would say the popover is about to remove something from it.
            if bytes > 0 { contributions.append((group, bytes)) }
        }
        // Divided by the sum of the parts, not by `reclaimableBytes`. The two agree on
        // every scan today and stop agreeing the moment one deletion target lands in two
        // groups: `reclaimableBytes` counts that target once, while each group's own total
        // counts it again. The blocks would then add up to two bar widths, which the user
        // sees as blocks running off the end of the popover —
        // `theBarBlocksAddUpToOneWidthWhenTwoGroupsNameOneTarget`.
        //
        // No zero guard on the division, deliberately. The filter above admits a group
        // only above zero, so `total` is at least `bytes` and `bytes` is at least 1
        // wherever this runs; a machine with nothing to clean produces no blocks at all
        // rather than a division. A guard would be a branch no test can reach and no
        // mutation can kill, and its zero fallback would draw a zero-width block —
        // exactly as invisible as the `nan` it would be there to prevent.
        let total = contributions.reduce(Int64(0)) { $0 + $1.1 }
        segments = contributions.map { group, bytes in
            BarSegment(
                id: group, title: group.title, bytes: bytes,
                fraction: Double(bytes) / Double(total))
        }

        self.problems = Self.problems(of: result, reporter: reporter)
    }

    /// Things that went wrong or were switched off, in the user's words.
    ///
    /// A function of its own rather than a block inside the initialiser, because the
    /// decision-first window's header asks the same question and must get the same two
    /// sentences in the same order. Two copies would drift, and the drift is invisible: both
    /// headers would still print *a* list of problems, and only a user who opened both
    /// surfaces on one machine could see them disagree.
    ///
    /// The refusal first, then the choice. `ScanContext.ignoredProjectRoots` is a root the
    /// engine **dropped** rather than walked — a hand-edited `settings.json` naming `~` — so
    /// an area of the disk went unmeasured and every number above is missing whatever lives
    /// there. Saying so is the difference between "your setting was ignored" and "you have no
    /// projects". A skipped scanner is the user's own setting, working as asked, and is the
    /// less surprising of the two.
    static func problems(of result: ScanResult, reporter: ReportText) -> [String] {
        var problems: [String] = []
        if !result.ignoredProjectRoots.isEmpty {
            problems.append("Ignored, too wide to be a project root: "
                + result.ignoredProjectRoots.map(reporter.abbreviate).joined(separator: ", "))
        }
        if !result.skippedScannerIDs.isEmpty {
            problems.append("Switched off in settings: "
                + result.skippedScannerIDs.joined(separator: ", "))
        }
        return problems
    }
}
