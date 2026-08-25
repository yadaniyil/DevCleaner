import Foundation
import CleanerCore

/// The three answers a user can give a row, and the only thing the board groups by.
///
/// **Not a restatement of `GroupID`.** The five groups say which technology a cache belongs
/// to, which is the question the popover answers and the wrong question for a window whose
/// job is a decision. "Xcode & iOS" holds derived data that a build rewrites in seconds and
/// a booted simulator that `simctl delete` destroys with no Trash and no undo; putting those
/// two under one heading asks the user to read every row before they can trust the heading.
/// Sorted by the decision instead, the heading carries the answer and the rows underneath it
/// only carry the sizes.
///
/// The order of `allCases` is the order the columns are drawn in, left to right: what the
/// tool is confident about, then what it wants a second look at, then what it will not touch.
/// A user who reads only the first column has still read a true and complete offer.
public enum DecisionTier: String, CaseIterable, Sendable {
    /// Deletable, restorable, ordinary risk, and its bytes are its own.
    case safe
    /// Deletable, and one of the three things that make a deletion worth a second thought:
    /// it is permanent, it only comes back over the network, or its size is not really
    /// its own.
    case thinkTwice
    /// Protected. Never offered, never ticked, and shown anyway so that "where did my
    /// 40 GB go?" has an answer.
    case kept

    public var title: String {
        switch self {
        case .safe:       return "Safe to clean now"
        case .thinkTwice: return "Think twice"
        case .kept:       return "Kept for you"
        }
    }

    /// The sentence under the heading, which is what makes the heading actionable. Each one
    /// says what happens **after** the clean, because that is the part the user cannot see
    /// from the row.
    public var subtitle: String {
        switch self {
        case .safe:
            return "Comes back on its own — rebuilt or re-downloaded when it's next needed."
        case .thinkTwice:
            return "Removed permanently, or may not come back the way it was."
        case .kept:
            return "Running, newest, or recently used — never offered for cleaning."
        }
    }
}

extension CleanupItem {
    /// Which column this row belongs in.
    ///
    /// Protection wins outright, and it is tested first for the same reason `GroupRow` guards
    /// its `.permanent` and `.notTickedByDefault` tags on `isDeletable`: a protected row is
    /// not being removed at all, so filing it under "removed permanently" would be a threat
    /// the column heading then contradicts. The kept column is the only one that can hold a
    /// row whose box refuses a click.
    ///
    /// The three ways into `thinkTwice` are the three ways a deletion can cost more than the
    /// row admits, and each is already carried on the item rather than inferred here:
    ///
    /// 1. `method.path == nil` — exactly the three device cases. `simctl delete`,
    ///    `simctl runtime delete` and `avdmanager delete avd` have no Trash whatever
    ///    `Settings.moveToTrash` says, so the undo the safe column promises does not exist.
    /// 2. `risk == .elevated` — it comes back only over the network, and that fetch can
    ///    fail. This is what puts the two Android NDK rows here, 5.57 GB that also start
    ///    unticked; `startsUnticked` is deliberately **not** a rule of its own, because it
    ///    says "the user has to ask for it" and not "getting it back is expensive". A row
    ///    that starts unticked purely because `du` could not measure it — every scanner
    ///    routes an unmeasured row through `startsUnticked` — is not thereby harder to
    ///    restore, and filing it beside the simulators would say it is.
    /// 3. `sizeMayBeShared` — the pnpm store and the bun cache. The number beside the row is
    ///    not the number that comes back, and a column headed "safe to clean now" above a
    ///    size that may free nothing at all is the one promise this tool must never make.
    ///
    /// Everything else is `safe`: deletable, to the Trash, rebuilt by the next build.
    public var decisionTier: DecisionTier {
        if protection != nil { return .kept }
        if method.path == nil || risk == .elevated || sizeMayBeShared { return .thinkTwice }
        return .safe
    }
}

/// One line of a column — either a single scanned row, or several of them collapsed into
/// one and expandable in place.
///
/// Everything the view draws is already a string, a `Bool` or a `Double`. In particular the
/// bar is a `fraction` and never two sizes to divide: a view that divides is a view deciding
/// what the bars compare against, and no test can reach it there.
public struct DecisionRow: Sendable, Equatable, Identifiable {
    /// Stable across scans. A leaf carries its `CleanupItem.id`, which is the scanner and the
    /// path; an aggregate carries a key built from the tier, the scanner and the shared name.
    /// Both survive a rescan, which is what `expanded` is keyed on — an identifier containing
    /// an index or a `UUID` would silently close every open row the moment a background scan
    /// landed underneath the user.
    public let id: String
    public let name: String
    /// The secondary text: "12 projects" for an aggregate, or the item's own detail.
    public let detail: String?
    /// Which of the five groups this came from, for the dot beside the name. The board does
    /// not sort by technology any more, so this is the only thing left that says a row is an
    /// Android row — and without it a column of thirty names is thirty names.
    public let groupID: GroupID
    public let sizeText: String
    public let sizeBytes: Int64
    /// `0...1` against the largest row **on the whole board**, never within the column.
    ///
    /// Board-wide on purpose: the columns sit side by side, so bars scaled per column would
    /// draw a 200 MB row in a thin column exactly as wide as a 19 GB row in a full one. The
    /// point of the bar is the comparison the eye makes across the whole window.
    public let fraction: Double
    /// The existing `RowTag` vocabulary, in the order `GroupRow` appends them. Built by
    /// `GroupRow` itself rather than restated here, so the popover and this board cannot
    /// label one row two different ways.
    public let tags: [RowTag]
    /// A leaf reads `.all` or `.none`; an aggregate reads `.some` when its children disagree.
    public let tick: GroupTick
    /// False for a protected row and for an aggregate holding only protected rows: greyed,
    /// unticked, and its box refuses the click.
    public let isEnabled: Bool
    public let isExpandable: Bool
    public let isExpanded: Bool
    /// Empty unless this row is an expanded aggregate. Collapsed rows carry nothing, so a
    /// board that shows a hundred `node_modules` folders builds one view for them until the
    /// user asks — the same rule `PopoverGroup.rows` follows.
    public let children: [DecisionRow]
    /// Every `CleanupItem` this row's checkbox controls: one identifier for a leaf, all of
    /// them for an aggregate.
    ///
    /// Protected identifiers are listed too, and that is safe rather than sloppy:
    /// `SelectionModel.setTicked` refuses them, so the eligibility rule stays in the one
    /// place that has always owned it instead of being restated by every caller that builds
    /// a list of identifiers.
    public let itemIDs: [String]

    init(
        id: String, name: String, detail: String?, groupID: GroupID,
        sizeBytes: Int64, fraction: Double, tags: [RowTag], tick: GroupTick,
        isEnabled: Bool, isExpandable: Bool, isExpanded: Bool,
        children: [DecisionRow], itemIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.groupID = groupID
        self.sizeBytes = sizeBytes
        self.sizeText = ByteText.short(sizeBytes)
        self.fraction = fraction
        self.tags = tags
        self.tick = tick
        self.isEnabled = isEnabled
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.children = children
        self.itemIDs = itemIDs
    }

    /// What the twisty beside this row promises. Meaningless on a row that is not
    /// `isExpandable`, which has no twisty to hover.
    ///
    /// A two-string table keyed on state, and here rather than in the view for the same reason
    /// as `PopoverGroup.chevronSymbolName`: swapped, both readings still sound like a twisty,
    /// so every open aggregate would offer to open itself again and nothing in the suite would
    /// notice. The two are the only sentences on the board that describe an action rather than
    /// name a thing, which is why they say what the row *is made of* rather than "expand" —
    /// the children of an aggregate are the projects it stands for, and that is the question a
    /// user is asking when they hover a row reading "node_modules · 12 projects".
    public var expandHelp: String {
        isExpanded ? "Hide what this row is made of" : "Show what this row is made of"
    }
}

/// One column of the board: a decision, the sentence explaining it, what it is worth, and
/// its rows.
public struct DecisionColumn: Sendable, Equatable, Identifiable {
    public let tier: DecisionTier
    public let title: String
    public let subtitle: String
    /// A plain size, so the view can set it beside whatever verb the column needs — "58.0 GB
    /// goes" over the two deletable columns, "12.4 GB stays" over the kept one. No "up to"
    /// and no range: the honest range belongs to the headline above the board, which is the
    /// one number the user reads as a promise.
    ///
    /// For `safe` and `thinkTwice` this follows the **ticks**, so unticking a row drops it
    /// here exactly as it drops from the Clean button. For `kept` it ignores them, because
    /// nothing in that column can be ticked at all and a total that could move would suggest
    /// otherwise.
    public let totalText: String
    public let rows: [DecisionRow]

    public var id: DecisionTier { tier }
}

public enum DecisionBoardModel {
    /// The whole board, ready to draw.
    ///
    /// `expanded` holds `DecisionRow.id`s rather than `GroupID`s: an aggregate is the only
    /// thing that opens here, and there are as many of them as there are scanners with
    /// repeated names.
    public static func columns(
        result: ScanResult, selection: SelectionModel?, expanded: Set<String>, home: String
    ) -> [DecisionColumn] {
        let reporter = ReportText(home: home)

        // Built per tier first **without** their bars, because the denominator is not known
        // until every column exists — which is the whole point of a board-wide scale. Two
        // passes, rather than each column guessing a maximum from the rows it happens to
        // hold.
        let planned: [(tier: DecisionTier, rows: [PlannedRow])] =
            DecisionTier.allCases.map { tier in
                (tier, plan(
                    tier: tier, items: result.items.filter { $0.decisionTier == tier },
                    selection: selection, expanded: expanded, reporter: reporter))
            }

        // The largest **top-level** row anywhere on the board. Children cannot set it: an
        // aggregate is never smaller than any child it holds, so a child can only ever tie
        // with its own parent.
        let widest = planned.flatMap(\.rows).map(\.sizeBytes).max() ?? 0

        return planned.map { tier, rows in
            DecisionColumn(
                tier: tier, title: tier.title, subtitle: tier.subtitle,
                totalText: ByteText.short(bytes(in: tier, result: result, selection: selection)),
                rows: rows.map { $0.build(widest) })
        }
    }

    /// What this column is worth as the ticks stand now.
    ///
    /// `safe` and `thinkTwice` filter `SelectionModel.selectedItems` and total with
    /// `ScanResult.totalBytes`, which is the same de-duplicating rule as the headline, the
    /// Clean button and every group headline in the popover — never a `reduce(+)`, which
    /// would be a fourth answer to one question on a screen already showing three of them.
    ///
    /// `kept` totals the protected rows from the **scan**, because no tick can reach them.
    /// Routed through `selectedItems` it would read 0 KB, and a column headed "Kept for you"
    /// saying nothing is being kept is the one reading that is never true.
    static func bytes(
        in tier: DecisionTier, result: ScanResult, selection: SelectionModel?
    ) -> Int64 {
        guard tier != .kept else {
            return ScanResult.totalBytes(of: result.items.filter { $0.decisionTier == .kept })
        }
        let ticked = selection?.selectedItems ?? []
        return ScanResult.totalBytes(of: ticked.filter { $0.decisionTier == tier })
    }

    /// A row that knows its size and its identity but not yet its bar, because the bar needs
    /// the whole board. `build` takes the board-wide maximum and nothing else, so the
    /// denominator travels in one direction and cannot be recovered, guessed or re-derived
    /// anywhere below.
    struct PlannedRow {
        let id: String
        let sizeBytes: Int64
        let build: (Int64) -> DecisionRow
    }

    /// `0...1`, and `0` on a board whose biggest row is zero bytes.
    ///
    /// The guard is reachable, unlike the one `HeaderModel` deliberately leaves out of its
    /// bar: an empty scan has no rows at all, but a scan of a machine where `du` measured
    /// nothing produces real rows that are all 0 bytes — `ios.simulatorCaches` really is
    /// 0 bytes and really is ticked. Without it every bar on such a board is `nan`, which
    /// SwiftUI draws at whatever width it likes.
    static func fraction(_ bytes: Int64, of widest: Int64) -> Double {
        guard widest > 0 else { return 0 }
        return Double(bytes) / Double(widest)
    }

    /// One column's rows: same-kind items collapsed, everything biggest first.
    static func plan(
        tier: DecisionTier, items: [CleanupItem], selection: SelectionModel?,
        expanded: Set<String>, reporter: ReportText
    ) -> [PlannedRow] {
        // Keyed on scanner **and** name, and grouped only within one tier.
        //
        // The scanner is half the key because a name alone is not one kind of thing: two
        // scanners can both call a row `build`, and merging those would put a Flutter
        // project's output and something else entirely under one checkbox. The tier is the
        // outer loop rather than part of the key so the rule reads the way it must behave —
        // a `node_modules` that is safe and one that is elevated are two different decisions,
        // and an aggregate spanning both would put a row into a column that describes the
        // wrong consequence for it.
        //
        // `ProjectBuildOutputScanner` is what this exists for: every project's artifact row
        // is `scannerID: "projects.buildOutput"`, `name:` the relative folder and `detail:`
        // the project's name, so twelve projects with a `node_modules` collapse to one row
        // named `node_modules` with twelve children named after their projects.
        //
        // Insertion order is kept by hand rather than walked out of the dictionary.
        // `Dictionary` promises no order, and a board that reshuffles between scans moves
        // the tick boxes under the user's cursor — the same reason `ProjectScanner` records
        // `protectedOrder` beside its totals.
        var order: [Key] = []
        var members: [Key: [CleanupItem]] = [:]
        for item in items {
            let key = Key(scannerID: item.scannerID, name: item.name)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(item)
        }

        let rows: [PlannedRow] = order.compactMap { key in
            guard let group = members[key], let first = group.first else { return nil }
            guard group.count > 1 else {
                return leaf(first, selection: selection, reporter: reporter)
            }
            return aggregate(
                key: key, tier: tier, members: group, selection: selection,
                expanded: expanded, reporter: reporter)
        }
        return rows.sorted(by: byDescendingSize)
    }

    /// The same order as `GroupList.byDescendingSize` and `ReportText.byDescendingSize`:
    /// biggest first, ties broken by identifier so the board is the same on every scan.
    /// Applied at both levels, so opening an aggregate does not reveal a differently sorted
    /// list than the one it sits in.
    static func byDescendingSize(_ left: PlannedRow, _ right: PlannedRow) -> Bool {
        left.sizeBytes == right.sizeBytes
            ? left.id < right.id
            : left.sizeBytes > right.sizeBytes
    }

    struct Key: Hashable {
        let scannerID: String
        let name: String
    }

    private static func leaf(
        _ item: CleanupItem, selection: SelectionModel?, reporter: ReportText,
        renamedToItsDetail: Bool = false
    ) -> PlannedRow {
        // Through `GroupRow`, not around it. The tag list — which tags, in which order, and
        // the two that are withheld from a protected row — is a decision that already exists
        // and is already pinned by `GroupListTests`. A second copy here would drift, and the
        // popover and the board would then label one row two different ways.
        let built = GroupRow(item: item, reporter: reporter)
        // A child of a "12 projects" aggregate is named by the project it belongs to. Its own
        // name is the aggregate's heading repeated twelve times, which says nothing about
        // which one the user is about to untick.
        let name = renamedToItsDetail ? (item.detail ?? built.name) : built.name
        let detail = renamedToItsDetail ? nil : built.detail
        let tick = selection?.tick(ofRow: built.id) ?? GroupTick.none
        return PlannedRow(id: built.id, sizeBytes: item.sizeBytes) { widest in
            DecisionRow(
                id: built.id, name: name, detail: detail, groupID: item.group,
                sizeBytes: item.sizeBytes, fraction: fraction(item.sizeBytes, of: widest),
                tags: built.tags, tick: tick, isEnabled: built.isEnabled,
                isExpandable: false, isExpanded: false, children: [], itemIDs: [built.id])
        }
    }

    /// **Never called with fewer than two members.** One row of a kind stays one row: an
    /// aggregate wrapping a single child is a twisty that opens onto a copy of itself, and
    /// its plural counts would have to grow a singular case that no board could ever show.
    private static func aggregate(
        key: Key, tier: DecisionTier, members: [CleanupItem], selection: SelectionModel?,
        expanded: Set<String>, reporter: ReportText
    ) -> PlannedRow {
        let id = aggregateID(key: key, tier: tier)
        let isExpanded = expanded.contains(id)

        // Every child has a detail and no two share one — so the details are what tell these
        // rows apart, and the count may name them after what they are. `detail` is the
        // project's name in `ProjectBuildOutputScanner`, which is precisely this case.
        // Anything else — a nil detail anywhere, or two rows of one project — is counted as
        // plain items, because "12 projects" above a list where two lines read the same is a
        // miscount the user can see.
        let details = members.compactMap(\.detail)
        let byProject = details.count == members.count && Set(details).count == members.count
        let detail = byProject ? "\(members.count) projects" : "\(members.count) items"

        let children = members
            .map { leaf($0, selection: selection, reporter: reporter,
                        renamedToItsDetail: byProject) }
            .sorted(by: byDescendingSize)

        // `ScanResult.totalBytes`, not `reduce(+)`. Nothing produces two rows for one target
        // today — `ScanEngine` drops the second, comparing canonical paths — but this sum
        // feeds a column total and a bar width, and it is the last place able to refuse a
        // promise of bytes that exist once.
        let size = ScanResult.totalBytes(of: members)
        let ids = members.map(\.id)

        // The same counting rule as `SelectionModel.tick(of:)`, over **eligible** members
        // only. An aggregate holding one deletable row and nine protected ones reads `.all`
        // when that one row is ticked, because clicking the box again could add nothing, and
        // a `.some` there would offer a click that does nothing.
        let eligible = members.filter(\.isDeletable)
        let ticked = eligible.filter { selection?.isTicked($0.id) ?? false }.count
        let tick: GroupTick = eligible.isEmpty || ticked == 0
            ? .none
            : (ticked == eligible.count ? .all : .some)

        let tags = sharedTags(of: members, reporter: reporter)
        let group = members[0].group
        return PlannedRow(id: id, sizeBytes: size) { widest in
            DecisionRow(
                id: id, name: key.name, detail: detail, groupID: group,
                sizeBytes: size, fraction: fraction(size, of: widest), tags: tags,
                tick: tick, isEnabled: !eligible.isEmpty,
                isExpandable: true, isExpanded: isExpanded,
                // Empty while collapsed. The view has no filtering to do and builds nothing
                // it will not draw — the same rule as `PopoverGroup.rows`, and with 257
                // projects on a real dev machine it is the difference between
                // a handful of rows and several hundred on every redraw.
                children: isExpanded ? children.map { $0.build(widest) } : [],
                itemIDs: ids)
        }
    }

    /// The tags **every** member carries, in the order `GroupRow` draws them.
    ///
    /// The intersection, never the union. A tag on an aggregate is a claim about everything
    /// its checkbox is about to remove: "permanent" over a row where eleven of twelve
    /// children go to the Trash is a warning the user learns to ignore, and the union hides
    /// the opposite mistake as well — a `.kept` tag from one protected child would mark the
    /// whole row kept while its box happily ticks the other eleven.
    static func sharedTags(of members: [CleanupItem], reporter: ReportText) -> [RowTag] {
        let lists = members.map { GroupRow(item: $0, reporter: reporter).tags }
        guard let first = lists.first else { return [] }
        let shared = lists.dropFirst().reduce(into: Set(first)) { $0.formIntersection($1) }
        return first.filter(shared.contains)
    }

    /// Stable across scans, and distinct per column.
    ///
    /// The tier is in the key because `expanded` is keyed on this identifier and the same
    /// scanner and name **can** land in two columns — a scanner that marks one of its rows
    /// elevated and leaves the rest safe produces exactly that. One identifier shared across
    /// two columns would open both aggregates from a single click.
    static func aggregateID(key: Key, tier: DecisionTier) -> String {
        "decision|\(tier.rawValue)|\(key.scannerID)|\(key.name)"
    }
}

extension DecisionBoardModel {
    /// The same thing, from the model the view already has — the shape `PopoverBodyModel`
    /// uses, and kept beside the tested function for the same reason: the argument wiring is
    /// then checked by the compiler in a target a test can import.
    @MainActor
    public static func columns(from model: AppModel) -> [DecisionColumn] {
        guard let result = model.result else { return [] }
        return columns(
            result: result, selection: model.selection,
            expanded: model.expandedDecisionRows, home: model.home)
    }
}
