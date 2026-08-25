import Foundation
import CleanerCore

/// The small labels beside a row's name, per spec §8.2.
///
/// Five, not three, because `.elevated` stopped being one thing. A row can be permanent
/// **and** safe (an emulator: it rebuilds from an installed system image, but
/// `avdmanager delete avd` has no Trash), and a row can be elevated **and** restorable
/// (git packages in the pub cache: they go to the Trash, but the upstream repository may
/// be gone). Folding permanence into risk loses one of those every time.
public enum RowTag: Sendable, Equatable, Hashable {
    /// Carries the reason's text rather than the `ProtectionReason` itself, so the tag is
    /// `Hashable` for `ForEach` without `ProtectionReason` having to be.
    case kept(String)
    case risk
    case permanent
    case mayBeShared
    case notTickedByDefault

    public var text: String {
        switch self {
        case .kept:               return "kept"
        case .risk:               return "risk"
        case .permanent:          return "permanent"
        case .mayBeShared:        return "shared"
        case .notTickedByDefault: return "not ticked"
        }
    }

    /// The hover text. Spec §8.2 asks for the protection reason on hover; the other four
    /// earn one for the same reason — the label is a word, and the sentence is what makes
    /// it actionable.
    public var help: String {
        switch self {
        case .kept(let reason):
            return "kept: \(reason)"
        case .risk:
            return "comes back only over the network, and that fetch can fail"
        // The engine's own sentences, so the popover and `devcleaner scan` say the same
        // thing about the same row.
        case .permanent:          return ReportText.permanentNote
        case .mayBeShared:        return ReportText.sharedNote
        case .notTickedByDefault: return ReportText.untickedNote
        }
    }
}

/// One line of the popover. Everything the view draws is already a string or a `Bool`.
public struct GroupRow: Sendable, Equatable, Identifiable {
    public let id: String
    /// The row this was built from, so the footer can total a selection without the view
    /// having to map back to the scan.
    public let item: CleanupItem
    public let name: String
    public let detail: String?
    /// What would actually be removed: an abbreviated path, or the device named.
    public let target: String
    public let sizeText: String
    public let tags: [RowTag]
    /// False for a protected row: greyed, unticked, and its box refuses the click.
    public let isEnabled: Bool

    public init(item: CleanupItem, reporter: ReportText) {
        self.id = item.id
        self.item = item
        self.name = item.name
        self.detail = item.detail
        self.target = reporter.target(of: item.method)
        self.sizeText = ByteText.short(item.sizeBytes)
        self.isEnabled = item.isDeletable

        // Appended in the order the view draws them, pinned by
        // `aRowWithSeveralTagsDrawsThemInAFixedOrder`.
        var tags: [RowTag] = []
        if let protection = item.protection { tags.append(.kept(protection.description)) }
        // Only where it can actually happen. A protected device is never removed, so
        // "permanent" beside a row marked kept reads as a threat the row then contradicts.
        // `method.path == nil` is exactly the three device cases.
        if item.isDeletable, item.method.path == nil { tags.append(.permanent) }
        if item.risk == .elevated { tags.append(.risk) }
        if item.sizeMayBeShared { tags.append(.mayBeShared) }
        // Guarded for the same reason as `.permanent`. "not ticked" means *offered, and
        // left for you to decide*; a protected row is not offered, and its box refuses
        // every click. `aProtectedRowIsNeverTaggedNotTickedBecauseItWasNeverOffered` fails
        // if this guard goes. Note the engine's `ReportText.targetLine` prints its unticked
        // note without this guard — the listing has a `[-]` in the box two columns to the
        // left saying the same thing, and the popover has no such column.
        if item.isDeletable, item.startsUnticked { tags.append(.notTickedByDefault) }
        self.tags = tags
    }
}

public struct GroupSection: Sendable, Equatable, Identifiable {
    public let id: GroupID
    public let title: String
    public let rows: [GroupRow]

    /// **No ticked total here.** What a clean would take from this group is
    /// `SelectionModel.selectedBytes(in:)`, which follows the user's ticks; this type is
    /// built from the scan alone and could only ever hold the scan's default tick, frozen at
    /// the moment `sections` ran and wrong from the user's first click. This struct is
    /// public, so a field named `tickedBytes` here sat one word away from the live value and
    /// duplicated the rule the header had already got wrong.
    ///
    /// Every row, protected and unticked ones included. The count and the size answer two
    /// different questions and must not be made to agree: "3 rows · 19.0 GB" is the truth
    /// when one of the three is kept and another is offered unticked.
    public var count: Int { rows.count }
}

public enum GroupList {
    /// All five groups, in `GroupID.allCases` order, empty ones included.
    ///
    /// Empty groups are kept so the popover's shape does not change between scans. A list
    /// that grows and shrinks a section at a time moves every row under the user's cursor,
    /// and the collapsed state in `AppModel` is keyed by group.
    public static func sections(
        from result: ScanResult, home: String, projectRoots: [String]
    ) -> [GroupSection] {
        let reporter = ReportText(home: home)
        return GroupID.allCases.map { group in
            let rows = result.items(in: group)
                .sorted(by: byDescendingSize)
                .map { GroupRow(item: $0, reporter: reporter) }
            return GroupSection(
                id: group,
                title: title(for: group, reporter: reporter, projectRoots: projectRoots),
                rows: rows)
        }
    }

    /// Spec §8.2 names the fourth group "Projects in ~/dev". The engine's `GroupID.title`
    /// is the neutral "Projects", because the engine does not know which roots this user
    /// configured, so the root is added here from the settings.
    static func title(
        for group: GroupID, reporter: ReportText, projectRoots: [String]
    ) -> String {
        guard group == .projects, !projectRoots.isEmpty else { return group.title }
        return "Projects in " + projectRoots.map(reporter.abbreviate).joined(separator: ", ")
    }

    /// Biggest first, ties broken by identifier so the list is the same on every scan.
    /// The same rule as `ReportText.byDescendingSize`, which is internal to CleanerCore
    /// and cannot be called from here; `rowsAreBiggestFirstWithTiesBrokenByIdentifier`
    /// pins it so the two orders cannot quietly diverge.
    static func byDescendingSize(_ left: CleanupItem, _ right: CleanupItem) -> Bool {
        left.sizeBytes == right.sizeBytes ? left.id < right.id : left.sizeBytes > right.sizeBytes
    }
}
