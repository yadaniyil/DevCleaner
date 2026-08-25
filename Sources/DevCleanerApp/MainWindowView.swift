import SwiftUI
import AppKit
import DevCleanerUI
import CleanerCore

/// The desktop window: the decision board.
///
/// The popover sorts by technology, because a menu bar strip has room for one column and
/// "which cache is this?" is the question a glance asks. This window asks the other one —
/// *may I delete it?* — and answers it with three columns set side by side: what the tool is
/// confident about, what it wants a second look at, and what it will not touch. The columns
/// are `DecisionBoardModel`'s, the header is `DecisionHeaderModel`'s, and the footer is the
/// popover's own `FooterModel`, so the two surfaces still cannot disagree about what a tick
/// or a warning means.
///
/// Nothing below this line classifies, totals or phrases anything. Every row arrives with its
/// name, its size, its tags, its tick and — crucially — its `fraction` already worked out
/// against the widest row on the **whole** board, so the one thing a view could plausibly get
/// wrong here (dividing two sizes and quietly choosing what the bars compare against) is not
/// something this file is able to do.
struct MainWindowView: View {
    private enum Sheet: String, Identifiable {
        case cleanupReview
        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    let scans: BackgroundScanLoop
    @Environment(\.openSettings) private var openSettings
    @State private var sheet: Sheet?

    /// The words come from `PopoverText`, which owns them; this only picks per phase.
    private var progressText: String? {
        switch model.phase {
        case .idle: return nil
        case .scanning(let progress): return PopoverText.scanning(progress)
        case .running(let progress): return PopoverText.running(progress)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = model.decisionHeader {
                DecisionHeaderView(model: header)
            } else {
                Text(PopoverText.noScanYet)
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            if let cacheError = model.lastCacheError {
                Text(cacheError)
                    .font(.caption).foregroundStyle(.orange).wrapped()
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            // The flexible middle. In the popover these are stacked sections that collapse
            // when empty; a window cannot collapse, so whichever one has something to say
            // fills the space instead of leaving a void above the footer. The model already
            // makes them exclusive: the board needs an idle phase and no summary, and a
            // summary only exists while the board is away.
            //
            // `showsGroupList`, still: whether the result belongs on screen depends on the
            // phase, the scan and the run summary at once, and that choice is `AppModel`'s.
            // Only what fills the space has changed, from five collapsible groups to the
            // three columns.
            if model.showsGroupList {
                DecisionBoardView(model: model)
            } else if let summary = model.summary {
                SummaryView(summary: summary) { model.dismissSummary() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let progress = progressText {
                VStack {
                    Spacer()
                    ProgressLine(text: progress)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nothing to say yet: the header above already reads "no scan yet".
                // This only holds the footer at the bottom edge.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The middle shows the progress itself unless the board or a summary took the
            // space; then the line sits above the footer, exactly as in the popover — a
            // summary is read while the follow-up scan runs underneath it.
            if let progress = progressText, model.showsGroupList || model.summary != nil {
                Divider()
                ProgressLine(text: progress)
            }

            Divider()
            MainFooterView(
                model: model,
                scans: scans,
                openSettings: { openSettings() },
                review: { sheet = .cleanupReview })
        }
        .frame(minWidth: MainWindowMetrics.minWidth, minHeight: MainWindowMetrics.minHeight)
        .background(.background)
        .sheet(item: $sheet) { destination in
            switch destination {
            case .cleanupReview:
                CleanupReviewView(model: model, surface: .mainWindow)
            }
        }
        // Same rule as the popover: a run summary does not outlive the surface it was
        // read on. `AppModel.surfaceClosed` owns what closing means — including that this
        // close puts away only this window's own summary, never the popover's.
        .onDisappear { model.surfaceClosed(.mainWindow) }
    }
}

// MARK: - the header

/// The amount, the sentence that keeps it honest, and the split bar the three columns are a
/// zoomed-in view of.
///
/// Every string is the library's: the amounts and the legend's sizes are
/// `DecisionHeaderModel`'s, its fixed words are `DecisionBoardText`'s, and the two tier names
/// are `DecisionTier.title` — the same values the column headings below use, so the legend and
/// the headings cannot drift apart into two names for one column.
struct DecisionHeaderView: View {
    let model: DecisionHeaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.amountPrefix)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(model.amountText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.top, 2)
                    Text(model.captionText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .wrapped()
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.top, 5)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.freeSpaceText)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    Text(model.scanAgeText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            TierSplitBar(
                safe: model.safeFraction,
                thinkTwice: model.thinkTwiceFraction,
                unticked: model.untickedFraction)
                .padding(.top, 12)

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                legendEntry(
                    DecisionTier.safe.title, model.safeSizeText,
                    color: DecisionStyle.safeText)
                legendEntry(
                    DecisionTier.thinkTwice.title, model.thinkTwiceSizeText,
                    color: DecisionStyle.thinkTwiceText)
                // `untickedLegendSizeText` is `nil` when there is nothing left unticked, and
                // the entry goes with it. Which is a decision — see the field — so it is the
                // model's and not this file's; here it is only an `if let`.
                if let untickedSize = model.untickedLegendSizeText {
                    legendEntry(
                        DecisionBoardText.untickedLegend, untickedSize,
                        color: .secondary, dot: DecisionBoardText.hollowDot)
                }
                Spacer(minLength: 12)
                groupLegend
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.top, 6)

            ForEach(model.problems, id: \.self) { problem in
                Text(problem)
                    .font(.caption).foregroundStyle(.orange).wrapped()
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func legendEntry(
        _ title: String, _ size: String, color: Color,
        dot: String = DecisionBoardText.solidDot
    ) -> some View {
        (Text("\(dot) \(title)").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            + Text(" ")
            + Text(size).font(.system(size: 11, weight: .bold).monospacedDigit()))
            .lineLimit(1)
    }

    /// One `Text` rather than a stack of them, so a narrow window truncates the tail of the
    /// key instead of pushing the sizes on its left off the row.
    ///
    /// Both the lead-in and the entries are the model's, so the only thing decided here is
    /// which colour each dot is drawn in — which is the one part of a legend entry that is not
    /// in the data and could not be.
    private var groupLegend: Text {
        model.groupLegend.reduce(
            Text(DecisionBoardText.groupLegendLead).foregroundStyle(.secondary)
        ) { line, entry in
            line
                + Text(" \(DecisionBoardText.solidDot)").foregroundStyle(entry.id.dotColor)
                + Text(" \(entry.title)").foregroundStyle(.secondary)
        }
    }
}

/// What a clean takes and what it leaves, in one 12-point strip: the safe bytes, the
/// think-twice bytes, and — dashed, because it is an offer rather than a plan — the deletable
/// bytes still unticked.
///
/// The three fractions are shares of the same total, so they fill the bar between them. The
/// gaps are taken out of the width before the shares are applied; laid out as spacing on top
/// of three full-width shares the last segment would be squeezed by however many gaps there
/// happened to be, which is a different bar depending on which segments were zero.
struct TierSplitBar: View {
    let safe: Double
    let thinkTwice: Double
    let unticked: Double

    private static let gap: CGFloat = 2

    /// Zero-width segments are dropped rather than drawn at a minimum width. A hairline of
    /// orange over a selection with nothing permanent in it says there is something to think
    /// twice about when there is not.
    private var shown: [Double] { [safe, thinkTwice, unticked].map { $0 > 0 ? $0 : 0 } }

    var body: some View {
        GeometryReader { geometry in
            let visible = shown.filter { $0 > 0 }.count
            let available = max(0, geometry.size.width
                - Self.gap * CGFloat(max(0, visible - 1)))
            HStack(spacing: Self.gap) {
                if safe > 0 {
                    Rectangle().fill(DecisionStyle.safeBar)
                        .frame(width: available * safe)
                }
                if thinkTwice > 0 {
                    Rectangle().fill(DecisionStyle.thinkTwiceBar)
                        .frame(width: available * thinkTwice)
                }
                if unticked > 0 {
                    Rectangle()
                        .strokeBorder(
                            .tertiary,
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: available * unticked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - the board

struct DecisionBoardView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(model.decisionColumns) { column in
                DecisionColumnView(model: model, column: column)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tier: its icon, its heading, what it is worth, the sentence that makes the heading
/// actionable, and its rows.
///
/// Equal widths on purpose, and not because the three columns hold equal amounts — on a
/// real dev machine they do not. The bars inside them are scaled against one board-wide
/// maximum, and a column given width in proportion to its total would undo that: the same
/// number of bytes would draw at two lengths depending on which column it landed in.
struct DecisionColumnView: View {
    @Bindable var model: AppModel
    let column: DecisionColumn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: column.tier.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(column.tier.accent)
                Text(column.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(column.tier == .kept ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(column.totalText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(column.tier.totalTextColor)
                    .lineLimit(1)
            }
            Text(column.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .wrapped()
                .padding(.top, 3)
            Rectangle()
                .fill(column.tier.hairline)
                .frame(height: 1)
                .padding(.top, 10)
                .padding(.bottom, 4)

            // Its own scroll view, so a column of forty projects does not drag the two
            // beside it down with it — and so the three headings, which are the part a user
            // reads first, stay in place while any one of them is scrolled.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(column.rows) { row in
                        DecisionRowView(model: model, row: row, tier: column.tier)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(column.tier.wash))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(column.tier.border, lineWidth: 1))
    }
}

/// A top-level row and, when it is open, the rows it stands for.
///
/// Not recursive, because the data is not: `DecisionBoardModel` builds aggregates one level
/// deep and their children are always leaves. A recursive view here would promise a depth the
/// board cannot produce, and it would have to invent an indent per level to do it.
struct DecisionRowView: View {
    @Bindable var model: AppModel
    let row: DecisionRow
    let tier: DecisionTier

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            BarRow(model: model, row: row, tier: tier, isChild: false)
            // Empty unless the aggregate is open — `DecisionRow.children` carries nothing
            // while it is closed, so a board holding 257 projects builds a handful of views
            // rather than several hundred on every redraw.
            ForEach(row.children) { child in
                BarRow(model: model, row: child, tier: tier, isChild: true)
                    .padding(.leading, 21)
            }
        }
    }
}

/// The row **is** the bar.
///
/// The size sits inside the track it belongs to rather than in a column of its own, so a long
/// name cannot push a number away from the bar that measures it — which is the failure the
/// board exists to avoid, and the reason `fraction` is a field on the row rather than two
/// sizes for the view to divide.
struct BarRow: View {
    @Bindable var model: AppModel
    let row: DecisionRow
    let tier: DecisionTier
    let isChild: Bool

    private var trackHeight: CGFloat { isChild ? 20 : 26 }
    private var textSize: CGFloat { isChild ? 11 : 12 }
    private var inset: CGFloat { isChild ? 7 : 8 }

    var body: some View {
        HStack(spacing: 7) {
            // The kept column has no boxes at all. A disabled box on every one of its rows
            // would be forty invitations to click something that is never going to move.
            if tier != .kept {
                CheckBox(state: row.tick) { ticked in
                    model.setRows(row.itemIDs, ticked: ticked)
                }
                .font(.system(size: isChild ? 11 : 13))
                .disabled(!row.isEnabled)
            }
            track
        }
        .opacity(row.isEnabled ? 1 : 0.55)
    }

    private var track: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                fill.frame(width: max(0, geometry.size.width * row.fraction))
                label.padding(.horizontal, inset)
            }
        }
        .frame(height: trackHeight)
    }

    /// Solid for a row that is going, dashed for one that is merely offered — the same two
    /// readings the split bar in the header uses, so the strip at the top and the rows below
    /// it are drawn in one language. A protected row is neither: it is not on the table, and
    /// it fills flat grey.
    @ViewBuilder
    private var fill: some View {
        if row.isEnabled && row.tick == .none {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    tier.accent.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(tier.barFill(isChild: isChild))
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if row.isExpandable {
                // A `Button`, not a tap gesture: it takes keyboard focus and VoiceOver reads
                // it as an action. It sits beside the checkbox rather than wrapping the row,
                // because a button nested inside another button's label never receives its
                // click — which is what would happen to the tick box.
                Button {
                    model.toggleDecisionRow(row.id)
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(row.expandHelp)
            }
            // Only on the top level. A child of an aggregate is one of a set that shares a
            // scanner, and repeating the same dot down the indent adds a column of identical
            // marks to rows that are already told apart by their names.
            if !isChild {
                Circle().fill(row.groupID.dotColor).frame(width: 7, height: 7)
            }
            name
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(row.tags, id: \.self) { tag in
                TagChip(tag: tag)
            }
            Spacer(minLength: 6)
            Text(row.sizeText)
                .font(.system(size: textSize, weight: .bold))
                .monospacedDigit()
        }
    }

    /// One `Text`, so the detail wraps into the ellipsis with the name instead of being
    /// truncated as a box of its own beside a name that had room to spare.
    private var name: Text {
        let base = Text(row.name).font(.system(size: textSize, weight: .medium))
        guard let detail = row.detail else { return base }
        return base
            + Text(" · \(detail)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
    }
}

/// The popover's chip, at the board's scale. The word and the sentence behind it are
/// `RowTag`'s, so a `permanent` here and a `permanent` in the popover mean the same thing;
/// only the padding is this file's.
struct TagChip: View {
    let tag: RowTag

    var body: some View {
        Text(tag.text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            .help(tag.help)
    }
}

// MARK: - the footer

/// The popover's footer at a window's scale: the same `FooterModel`, the same warnings, the
/// same Clean semantics — laid out in one row, with the controls at the sizes a desktop
/// window's controls are meant to be rather than the borderless glyphs a 440-point strip
/// needs.
struct MainFooterView: View {
    @Bindable var model: AppModel
    let scans: BackgroundScanLoop
    let openSettings: () -> Void
    let review: () -> Void

    var body: some View {
        let footer = FooterModel(
            selection: model.selection, moveToTrash: model.settings.moveToTrash)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if !footer.warnings.isEmpty {
                    WarningCallout(warnings: footer.warnings)
                }
                Text(footer.splitText).font(.caption).foregroundStyle(.secondary).wrapped()
            }
            // Bounded, so the callout reads as a paragraph rather than a single line running
            // the whole 1180 points, and so the buttons on its right keep their places as
            // the warnings come and go.
            .frame(maxWidth: 560, alignment: .leading)

            Spacer(minLength: 12)

            Button {
                openSettings()
            } label: {
                Label(PopoverText.settings, systemImage: "gearshape")
            }
            // Through the loop, not straight to the model: the scheduler holds the countdown,
            // and a manual scan it never hears about leaves the background interval due a
            // minute later. `BackgroundScanLoop.rescan` says the rest.
            Button {
                Task { await scans.rescan() }
            } label: {
                Label(PopoverText.rescan, systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
            Button(PopoverText.quit) { NSApplication.shared.terminate(nil) }

            if model.isBusy {
                Button(PopoverText.cancel) { model.cancel() }
                    .controlSize(.large)
                    .help(PopoverText.cancelHelp(phase: model.phase))
            } else {
                Button(footer.cleanTitle, action: review)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!footer.isCleanEnabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - the palette

/// The board's colours and its symbol table.
///
/// This is the one thing a view in this app does own. A colour cannot be asserted by a test
/// that can read `DecisionColumn` — it is not in the data and it changes nothing about what a
/// click removes — and putting a `Color` in `DevCleanerUI` would make that library import
/// SwiftUI for something no decision depends on. What is **not** here is anything that a test
/// could disagree with: no titles, no sizes, no tick rules, no thresholds.
enum DecisionStyle {
    /// Light and dark are chosen by hand rather than left to `.green` and `.orange`, because
    /// the two totals are set at 24 points against a tinted card: the system greens are legible
    /// as a fill and thin as text, and the system orange on a pale orange wash is close to
    /// unreadable. `NSColor`'s dynamic provider means the choice is still the appearance's and
    /// not a snapshot of whichever one happened to be on at launch.
    static let safeText = dynamic(
        light: NSColor(srgbRed: 0.118, green: 0.620, blue: 0.212, alpha: 1),
        dark: NSColor(srgbRed: 0.353, green: 0.839, blue: 0.435, alpha: 1))
    static let thinkTwiceText = dynamic(
        light: NSColor(srgbRed: 0.788, green: 0.204, blue: 0.000, alpha: 1),
        dark: NSColor(srgbRed: 1.000, green: 0.573, blue: 0.361, alpha: 1))

    static let safeBar = Color(nsColor: .systemGreen)
    static let thinkTwiceBar = Color(nsColor: .systemOrange)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension DecisionTier {
    /// The tier's one colour, from which the card, the hairline and the bars are all shaded.
    var accent: Color {
        switch self {
        case .safe:       return DecisionStyle.safeBar
        case .thinkTwice: return DecisionStyle.thinkTwiceBar
        case .kept:       return Color(nsColor: .systemGray)
        }
    }

    /// A tick, a warning triangle, a padlock. Three shapes rather than three tints of one, so
    /// the columns are still told apart in a screenshot, on a projector, or by a user who
    /// cannot separate green from orange.
    var symbolName: String {
        switch self {
        case .safe:       return "checkmark.circle"
        case .thinkTwice: return "exclamationmark.triangle.fill"
        case .kept:       return "lock"
        }
    }

    var totalTextColor: Color {
        switch self {
        case .safe:       return DecisionStyle.safeText
        case .thinkTwice: return DecisionStyle.thinkTwiceText
        case .kept:       return .secondary
        }
    }

    var wash: Color { accent.opacity(self == .kept ? 0.04 : 0.05) }
    var border: Color { accent.opacity(self == .kept ? 0.25 : 0.35) }
    var hairline: Color { accent.opacity(self == .kept ? 0.2 : 0.25) }

    /// A child's bar is a shade lighter than its parent's, so an open aggregate reads as one
    /// row with a list under it rather than as five rows of equal standing.
    func barFill(isChild: Bool) -> Color { accent.opacity(isChild ? 0.18 : 0.22) }
}

extension GroupID {
    /// The dot beside a name, and the only thing left on this board that says a row is an
    /// Android row: the columns stopped sorting by technology, and without the dot a column
    /// of thirty names is thirty names.
    var dotColor: Color {
        switch self {
        case .xcodeAndIOS:    return .blue
        case .android:        return .green
        case .flutterAndDart: return .teal
        case .projects:       return .purple
        case .otherCaches:    return .gray
        }
    }
}
