import Foundation
import CleanerCore

/// What a finished run did, per spec §7.4 and §8.2.
///
/// **Three numbers, never merged.** Bytes moved to the Trash, bytes removed permanently,
/// and the measured change in free space are three different quantities. A real run on
/// a real dev machine trashed 6.15 GB and changed free space by 60 MB, because the Trash still
/// held the rest; one merged "freed" figure would send the user to empty the Trash
/// expecting nothing to happen.
public struct RunSummaryModel: Sendable, Equatable {
    public let trashedText: String
    public let permanentText: String
    public let freeSpaceText: String
    public let threeNumbersNote: String
    /// Present only when something really is sitting in the Trash.
    public let emptyTrashNote: String?
    /// One line per row that was skipped or failed, each carrying its reason.
    public let unfinished: [String]
    public let notes: [String]
    /// The stored run, for "open the run log". `nil` when the run could not be stored.
    public let logURL: URL?

    public static let threeNumbers =
        "Those are three separate numbers. Trashing moves bytes; it does not release them."

    public init(record: RunRecord, logURL: URL?) {
        trashedText = "\(ByteText.short(record.trashedBytes)) moved to the Trash "
            + "(\(record.trashedCount) \(record.trashedCount == 1 ? "item" : "items"))"
        permanentText = "\(ByteText.short(record.permanentlyDeletedBytes)) removed permanently "
            + "(\(record.deletedCount) \(record.deletedCount == 1 ? "item" : "items"))"
        // `ReportText.signed`, not `ByteText.short`: the latter clamps a negative to zero,
        // so a run that left the disk 50 MB busier would print "0 KB" and look like it did
        // nothing at all.
        freeSpaceText = "\(ReportText.signed(record.freeSpaceChangeBytes)) change in free space"
        threeNumbersNote = Self.threeNumbers

        // Bytes, not `trashedCount`: a row trashed with an unmeasured size would otherwise
        // produce "free the 0 KB it now holds". It takes a hand-picked selection to happen
        // at all — `defaultSelection` leaves unmeasured rows out — and the count is still
        // on the line above, so nothing about the run is hidden.
        emptyTrashNote = record.trashedBytes > 0
            ? "Empty the Trash to actually free the \(ByteText.short(record.trashedBytes)) "
                + "it now holds. Until you do, that space is still in use."
            : nil

        // `RunRecord.unfinishedReasons` puts skipped rows first, because a skipped row is
        // usually the one the user can fix — install `platform-tools`, start the adb
        // server — and run again.
        unfinished = record.unfinishedReasons
        notes = record.notes

        // `CleanerService.store` adds this note when the run happened but its record could
        // not be written. The newest file in the runs directory then belongs to an earlier
        // run, and opening it would show the wrong list at the one moment the list is the
        // only record of where trashed items went.
        //
        // This note and no other. Most runs carry a note — every run that removed a device
        // carries `Executor.Note.devicesWereRemovedPermanently` — and withholding the link
        // whenever `notes` is non-empty would take the history away from the runs that most
        // need it.
        let recordWasLost = record.notes.contains {
            $0.hasPrefix(CleanerService.runLogNotWritten)
        }
        self.logURL = recordWasLost ? nil : logURL
    }
}
