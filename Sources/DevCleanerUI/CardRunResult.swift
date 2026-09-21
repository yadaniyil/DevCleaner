import Foundation
import CleanerCore

// What a card shows once its clean is over.
//
// The deck used to show nothing. A run ended, `AppModel` cleared the progress it was
// reporting, and the card went back to exactly what it had said before the button was
// pressed: every bar full, the same big number, the same offer. A user who deleted 8.5 GB of
// simulator runtime watched the bar drain, watched it refill, and could not tell whether the
// space had really gone — and because the executor adds a note after removing a device, the
// card they were left looking at was *held* behind "Next project" under a sentence in orange,
// which reads as a failure. Both halves of that came from the same place: the card knew what
// the run was **doing** and nothing about what it had **done**.
//
// So the run's own record is resolved into this, once, the moment the run ends, and the card
// draws from it until the deck moves on. Every rule here is about the record and never about
// the progress reports, the setting, or what the button offered: those three are what the
// card promised, and this is what happened.

/// What one card's finished run did, ready to draw.
///
/// Built from the card that was cleaned and the `RunRecord` the engine answered with, so the
/// two cannot come apart: the rows it says are gone are rows of this card, and the amount it
/// says is left is measured over this card's own list.
///
/// Held by `AppModel.cardResult` for as long as the card is on screen — a short beat on a
/// clean that went through, or until Next is pressed on one that did not.
public struct CardRunResult: Equatable, Sendable {
    /// The rows that are really gone, by `CleanupItem.id`.
    ///
    /// The set the card's bars are drained from **and** the set the scan is pruned by — one
    /// value for both, because they are one question asked by two parts of the app. Held
    /// separately they could disagree, and the disagreement has a direction: a row drained on
    /// the card but left in the scan is a folder the user believes is gone and the next
    /// session offers again.
    public let removedItemIDs: Set<String>
    /// "8.5 GB → 0 GB": what the card held, and what is left of it.
    public let headline: SizeHeadline
    /// "Deleted for good.", "Moved to the Trash.", or `nil` when nothing went at all.
    public let confirmation: String?
    /// The lines under the rows: every row that did not go, with its reason, then the run's
    /// own notes. Per-row reasons first, because those are the ones with something to fix.
    ///
    /// The whole list, notes included, whether or not it is what stops the deck — see
    /// `holdsTheCard`. It is also what the session's `ProjectDecision.cleaned` carries, so
    /// the record of the run and the report on screen are one list.
    public let problems: [String]
    /// Whether the deck stops on this card until the user presses Next.
    ///
    /// Not simply `!problems.isEmpty`, and that is the fix: a note that only restates what
    /// the card has already said twice must not turn a successful permanent deletion into a
    /// held, orange-looking report. `ProjectDeckText.noteHoldsTheCard` is the rule, and it
    /// matches on the engine's own constant.
    public let holdsTheCard: Bool

    public init(
        removedItemIDs: Set<String>, headline: SizeHeadline, confirmation: String?,
        problems: [String], holdsTheCard: Bool
    ) {
        self.removedItemIDs = removedItemIDs
        self.headline = headline
        self.confirmation = confirmation
        self.problems = problems
        self.holdsTheCard = holdsTheCard
    }

    /// Reads a finished run against the card it was started from.
    ///
    /// **The two amounts are measured over `card.items`**, the list that was handed over, and
    /// not over the record's entries. `ScanResult.totalBytes` de-duplicates on
    /// `DeletionMethod`, so measuring the card's own list is what makes "8.5 GB" here the same
    /// 8.5 GB that was set at 96 points a second ago — where a `reduce(+)` over entries could
    /// promise bytes that exist once. It is also what makes the checklist page behave: `items`
    /// there is the **ticked** rows, so the page reads "what you ticked → what is left of it",
    /// which is the question the press answered. The page's other figure — "of 41.3 GB", what
    /// there was to choose from — is gone from the headline, deliberately: the choosing is
    /// over.
    public init(card: ProjectCard, record: RunRecord) {
        let removed = Self.removedItemIDs(of: record)
        let notes = record.notes
        self.init(
            removedItemIDs: removed,
            headline: SizeHeadline(
                before: ScanResult.totalBytes(of: card.items),
                after: ScanResult.totalBytes(
                    of: card.items.filter { !removed.contains($0.id) })),
            confirmation: Self.confirmation(of: record),
            problems: record.unfinishedReasons + notes,
            // A row that did not go is always worth stopping for: it is still on the disk and
            // still inside the total the user was promised. A note is worth stopping for
            // unless it is one the card has already made.
            holdsTheCard: !record.unfinishedReasons.isEmpty
                || notes.contains(where: ProjectDeckText.noteHoldsTheCard))
    }

    /// Whether this row of the card is gone — its bar empty and its name struck through, and
    /// staying that way.
    ///
    /// By identifier, never by the row's place on the card or its position in the run. Those
    /// two part company on a checklist page, where the rows the user left unticked are drawn
    /// and were in no run; asked by position, such a row would strike itself through while
    /// the file it names sat untouched on the disk.
    public func removed(_ folderID: String) -> Bool { removedItemIDs.contains(folderID) }

    /// The identifiers of the rows a run really removed.
    ///
    /// `.trashed` and `.deleted` only. A `.failed` or `.skipped` row is still on the disk, and
    /// pruning it would take a real folder out of both surfaces' totals and off its own card
    /// — so the space would look recovered and the folder would never be offered again. The
    /// card's own bars follow the same list, so a bar cannot be empty over something that is
    /// there.
    static func removedItemIDs(of record: RunRecord) -> Set<String> {
        Set(record.entries
            .filter { $0.outcome == .trashed || $0.outcome == .deleted }
            .map(\.itemID))
    }

    /// Where the rows that went really landed, in one sentence.
    ///
    /// Counted off the entries rather than summed in bytes, because a row of nothing still
    /// went somewhere: a 0-byte folder that was trashed belongs in "Moved to the Trash." and
    /// a bytes test would leave the card silent about it.
    ///
    /// `nil` when nothing went — every row refused or skipped. There is nothing to confirm
    /// then, the headline reads "8.5 GB → 8.5 GB", and the problem lines say why; a
    /// confirmation over that would be the card contradicting itself.
    static func confirmation(of record: RunRecord) -> String? {
        switch (record.trashedCount > 0, record.deletedCount > 0) {
        case (true, true):   return ProjectDeckText.movedAndDeleted
        case (true, false):  return ProjectDeckText.movedToTheTrash
        case (false, true):  return ProjectDeckText.deletedForGood
        case (false, false): return nil
        }
    }
}
