import CleanerCore

/// A checkbox with three readings. `.some` is the mixed state a group box shows when part
/// of what is under it is ticked.
public enum GroupTick: Sendable, Equatable {
    case none
    case some
    case all
}

/// Which rows are ticked, and nothing else.
///
/// Spec §8.3: tick state is **not** persisted between scans. That is not enforced here —
/// this type has no store — it is enforced by `AppModel` building a new one from every
/// scan result. The rule is in the type that could break it.
public struct SelectionModel: Sendable, Equatable {
    public let items: [CleanupItem]
    private var tickedIDs: Set<String>
    /// What the ticks were when the list first appeared. Task 5 compares against this to
    /// choose between `cleanDefault` and `clean(items:)`.
    private let defaultIDs: Set<String>

    /// Ticks `result.defaultSelection`, which is `selectedByDefault` — **never**
    /// `isDeletable`.
    ///
    /// The two spellings were the same value until `startsUnticked` arrived. They differ
    /// today by the two Android NDK rows, 5.57 GB that comes back only over the network,
    /// and by every row whose size `du` could not measure. Ticking from `isDeletable`
    /// charges a user who pressed Clean without reading the list for both.
    public init(result: ScanResult) {
        self.items = result.items
        self.defaultIDs = Set(result.defaultSelection.map(\.id))
        self.tickedIDs = self.defaultIDs
    }

    private func item(_ id: String) -> CleanupItem? { items.first { $0.id == id } }

    /// Whether the row's box can be clicked at all. False for a protected row and for an
    /// identifier this selection has never heard of.
    public func isEnabled(_ id: String) -> Bool { item(id)?.isDeletable ?? false }

    public func isTicked(_ id: String) -> Bool { tickedIDs.contains(id) }

    /// Refuses a protected row, whatever it is asked. `ProtectionResolver` decides what
    /// survives, the executor refuses a protected item a second time, and this is the
    /// layer in between: a click, a group toggle and a keyboard shortcut all arrive here.
    public mutating func setTicked(_ ticked: Bool, for id: String) {
        guard isEnabled(id) else { return }
        if ticked { tickedIDs.insert(id) } else { tickedIDs.remove(id) }
    }

    public mutating func toggle(_ id: String) { setTicked(!isTicked(id), for: id) }

    /// One row's box, in the same vocabulary as a group's, so the view draws one control.
    public func tick(ofRow id: String) -> GroupTick { isTicked(id) ? .all : .none }

    /// Spec §8.2: a group box shows a mixed state when it is partly ticked.
    ///
    /// Counted over **eligible** rows only. A group holding one deletable row and nine
    /// protected ones reads `.all` when that one row is ticked, because ticking the box
    /// again could not add anything — reading it as `.some` would offer a click that does
    /// nothing. A group with no eligible row at all reads `.none`.
    public func tick(of group: GroupID) -> GroupTick {
        let eligible = items.filter { $0.group == group && $0.isDeletable }
        guard !eligible.isEmpty else { return .none }
        let ticked = eligible.filter { tickedIDs.contains($0.id) }.count
        if ticked == 0 { return .none }
        return ticked == eligible.count ? .all : .some
    }

    /// Sets every eligible row beneath the group, and nothing outside it.
    ///
    /// Goes through `setTicked` rather than reaching into `tickedIDs`, so the eligibility
    /// rule exists once. This loop used to carry its own copy of the guard and its own
    /// insert/remove, which behaved identically — right up until anything was added to
    /// `setTicked`. Adding a refusal there would have applied to a row click and silently
    /// not to a group toggle, and no test would have shown the two drifting apart.
    ///
    /// The `isEnabled` lookup inside `setTicked` scans `items`, making this O(n²) over a
    /// group. At about a hundred rows, on a click, that is unmeasurable — worth paying for
    /// one copy of the rule.
    public mutating func setGroup(_ group: GroupID, ticked: Bool) {
        for item in items where item.group == group {
            setTicked(ticked, for: item.id)
        }
    }

    /// The ticked rows, in scan order. Order matters: this is the list handed to
    /// `CleanerService.clean`, and the executor works through it one at a time with
    /// progress reported per item.
    public var selectedItems: [CleanupItem] { items.filter { tickedIDs.contains($0.id) } }

    /// The live total under the Clean button.
    ///
    /// `ScanResult.totalBytes`, not `reduce(+)`. It de-duplicates on `DeletionMethod`, so
    /// two rows naming one directory contribute once — exactly as `reclaimableBytes` does
    /// in the header. Two different sums in one popover is two different answers.
    public var selectedBytes: Int64 { ScanResult.totalBytes(of: selectedItems) }

    /// The same total, for one group — the live number beside a group header.
    ///
    /// Here rather than in `PopoverBodyModel` so both totals the popover shows are added up
    /// by the same rule, in the same file, from the same `selectedItems`. Split across two
    /// types, a change to the de-duplicating rule updates one and silently misses the
    /// other, and the group headers stop agreeing with the Clean button below them.
    ///
    /// **Not** `ScanResult.reclaimableBytes(in:)`, which is the scan's default tick and stops
    /// being true at the user's first click. `GroupSection` used to carry a frozen copy of
    /// that under the name `tickedBytes`; it was deleted for exactly this reason.
    ///
    /// Read by the group headline beside each section **and** by the header's stacked bar, so
    /// a block in the bar and the number under it cannot disagree.
    public func selectedBytes(in group: GroupID) -> Int64 {
        ScanResult.totalBytes(of: selectedItems.filter { $0.group == group })
    }

    /// The part of `selectedBytes` whose blocks may be shared with files that are staying —
    /// the pnpm store and the bun cache, 1.83 GB together on a real dev machine.
    ///
    /// The live answer to `ScanResult.possiblySharedBytes`, which counts the scan's default
    /// tick. The header prints the honest range from the two together, so a user who unticks
    /// the pnpm store must see the range go with it: left on the scan's value, the header
    /// would keep admitting that 1.8 GB of a total no longer containing it may be shared, and
    /// the range's upper end would stop matching the number printed above it.
    public var selectedPossiblySharedBytes: Int64 {
        ScanResult.totalBytes(of: selectedItems.filter(\.sizeMayBeShared))
    }

    /// Deletable bytes the user has **not** ticked — what ticking the rest would add.
    ///
    /// The live answer to `ScanResult.untickedDeletableBytes`, which counts `startsUnticked`
    /// rows and so keeps saying "5.6 GB more is offered but not ticked" after the user has
    /// ticked exactly that 5.6 GB. Counted over `isDeletable`, never `startsUnticked`: a row
    /// the user unticked by hand is offered and not ticked in precisely the same sense, and a
    /// protected row is offered in neither.
    public var unselectedDeletableBytes: Int64 {
        ScanResult.totalBytes(
            of: items.filter { $0.isDeletable && !tickedIDs.contains($0.id) })
    }

    /// True while the ticks are still what the scan proposed.
    ///
    /// Task 5 uses it to call `cleanDefault`, which re-derives the list inside the engine,
    /// rather than handing over a list the app assembled. The engine's copy of the rule is
    /// the tested one.
    public var isDefaultSelection: Bool { tickedIDs == defaultIDs }
}
