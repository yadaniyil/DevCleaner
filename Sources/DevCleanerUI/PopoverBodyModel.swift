import Foundation
import CleanerCore

/// One row, with its tick already resolved.
public struct PopoverRow: Sendable, Equatable, Identifiable {
    public let row: GroupRow
    public let tick: GroupTick

    public var id: String { row.id }
    public var isEnabled: Bool { row.isEnabled }
    public var name: String { row.name }
    public var detail: String? { row.detail }
    /// The path or the device. Two rows on a real dev machine are otherwise identical.
    public var target: String { row.target }
    public var sizeText: String { row.sizeText }
    public var tags: [RowTag] { row.tags }
}

/// One group, with its box, its headline and — only when expanded — its rows.
public struct PopoverGroup: Sendable, Equatable, Identifiable {
    /// Internal on purpose. Nothing outside this module has any use for it, and while it
    /// was public `group.section.tickedSizeText` sat one dot away from the live
    /// `group.tickedSizeText` below, offering the scan's frozen default under a nearly
    /// identical name. That field is gone from `GroupSection` altogether now; this stays
    /// internal so nothing like it can be reached from outside again. `id` and `title` still
    /// read it, from inside the module.
    let section: GroupSection
    public let tick: GroupTick
    public let isExpanded: Bool
    /// Empty while collapsed. The view has no filtering to do and `LazyVStack` builds
    /// nothing it will not draw; with 97 rows on a real dev machine that is the difference
    /// between five views and a hundred on every redraw.
    public let rows: [PopoverRow]
    /// What to say instead of rows when an expanded group has none.
    public let emptyText: String?
    /// What a clean would take from this group **as the ticks stand now**.
    ///
    /// `SelectionModel.selectedBytes(in:)`, the same call the header's bar segment for this
    /// group is drawn from. The scan's own `reclaimableBytes(in:)` is its default tick frozen
    /// at the moment `GroupList.sections` ran: right until the first click and wrong
    /// afterwards, because unticking a 19 GB row would leave the group still claiming 19 GB
    /// while the Clean button below had already dropped it. `theGroupHeadlineFollowsTheTicks`
    /// is the test that tells the two apart.
    public let tickedSizeText: String

    public var id: GroupID { section.id }
    public var title: String { section.title }

    public var symbolName: String {
        switch id {
        case .xcodeAndIOS:    return "apple.logo"
        case .android:        return "cpu"
        case .flutterAndDart: return "shippingbox"
        case .projects:       return "hammer"
        case .otherCaches:    return "externaldrive"
        }
    }

    /// Which way the twisty points. A two-symbol table keyed on state — the same shape as
    /// the tick table that had to be moved out of the checkbox, and invisible to every test
    /// for as long as it sits in `DevCleanerApp`: swapping the two would leave every closed
    /// group looking open and nothing would fail.
    public var chevronSymbolName: String { isExpanded ? "chevron.down" : "chevron.right" }

    /// "3 rows · 19.0 GB" — every row it holds, and only what cleaning would take.
    /// The two numbers answer different questions and are not made to agree: one of the
    /// three rows may be kept and another offered unticked.
    public var headline: String {
        "\(section.count) row\(section.count == 1 ? "" : "s") · \(tickedSizeText)"
    }
}

public enum PopoverBodyModel {
    public static let nothingInThisGroup = "Nothing found in this group."

    /// The whole body of the popover, ready to draw.
    ///
    /// Spec §8.2: five groups, collapsed by default, each with a checkbox that shows a
    /// mixed state, expanding to individually tickable rows. Everything the view needs is
    /// decided here so that no `if` about the data lives in SwiftUI, where no test can
    /// reach it.
    public static func groups(
        result: ScanResult, selection: SelectionModel?, expanded: Set<GroupID>,
        home: String, projectRoots: [String]
    ) -> [PopoverGroup] {
        GroupList.sections(from: result, home: home, projectRoots: projectRoots)
            .map { section in
                let isExpanded = expanded.contains(section.id)
                let rows = isExpanded
                    ? section.rows.map {
                        PopoverRow(
                            row: $0, tick: selection?.tick(ofRow: $0.id) ?? GroupTick.none)
                    }
                    : []
                return PopoverGroup(
                    section: section,
                    tick: selection?.tick(of: section.id) ?? GroupTick.none,
                    isExpanded: isExpanded,
                    rows: rows,
                    emptyText: isExpanded && section.rows.isEmpty ? nothingInThisGroup : nil,
                    // No selection means nothing is ticked, which is also what every box in
                    // the group shows in that case.
                    tickedSizeText: ByteText.short(
                        selection?.selectedBytes(in: section.id) ?? 0))
            }
    }
}

extension PopoverBodyModel {
    /// The same thing, from the model the view already has. Kept beside the tested
    /// function rather than in the view, so the argument wiring is checked by the compiler
    /// in a target a test can import.
    @MainActor
    public static func groups(from model: AppModel) -> [PopoverGroup] {
        guard let result = model.result else { return [] }
        return groups(
            result: result, selection: model.selection, expanded: model.expandedGroups,
            home: model.home, projectRoots: model.settings.projectRoots)
    }
}
