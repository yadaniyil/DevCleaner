import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

private func entry(
    _ name: String, _ outcome: ItemOutcome, bytes: Int64 = 0, reason: String? = nil
) -> RunEntry {
    RunEntry(itemID: name, name: name, target: "/tmp/\(name)", sizeBytes: bytes,
             outcome: outcome, trashedTo: outcome == .trashed ? "/Users/test/.Trash/\(name)" : nil,
             reason: reason)
}

private func record(
    _ entries: [RunEntry], before: Int64 = 100_000_000_000, after: Int64 = 100_060_000_000,
    notes: [String] = []
) -> RunRecord {
    RunRecord(
        startedAt: now, finishedAt: now.addingTimeInterval(300),
        availableBytesBefore: before, availableBytesAfter: after,
        entries: entries, notes: notes)
}

/// The measurement this whole screen exists for: a real run trashed 6.15 GB while free
/// space moved 60 MB. Three numbers, never merged.
@Test func theThreeNumbersAreKeptApart() {
    let summary = RunSummaryModel(
        record: record([
            entry("hosted", .trashed, bytes: 6_150_000_000),
            entry("iPhone 17", .deleted, bytes: 12_860_000_000),
        ]),
        logURL: nil)

    #expect(summary.trashedText.contains("6.2 GB"))
    #expect(summary.permanentText.contains("12.9 GB"))
    #expect(summary.freeSpaceText.contains("60 MB"))
    #expect(summary.threeNumbersNote == RunSummaryModel.threeNumbers)
}

/// Whole lines, not `contains`, over three numbers chosen so that no sum or difference of
/// any two of them prints the same digits as any of them.
///
/// The fixture above cannot do this and must not be asked to: it is a real dev machine's
/// measurement, and there 6.15 GB + 60 MB also prints "6.2 GB". Numbers far enough apart
/// are the only way to tell a line built from the right quantity from a line built from
/// the right quantity plus another one — the defect Task 4 shipped with sixteen tests
/// green. The counts differ too (2 against 3), so the two lines cannot swap counts either.
@Test func eachMoneyLineIsPinnedWholeAndCarriesItsOwnCount() {
    let summary = RunSummaryModel(
        record: record(
            [
                entry("hosted", .trashed, bytes: 3_000_000_000),
                entry("Yarn", .trashed, bytes: 400_000_000),
                entry("iPhone 17", .deleted, bytes: 20_000_000_000),
                entry("iPad Air", .deleted, bytes: 1_000_000_000),
                entry("Pixel 8", .deleted, bytes: 700_000_000),
            ],
            before: 200_000_000_000, after: 208_900_000_000),
        logURL: nil)

    #expect(summary.trashedText == "3.4 GB moved to the Trash (2 items)")
    #expect(summary.permanentText == "21.7 GB removed permanently (3 items)")
    #expect(summary.freeSpaceText == "8.9 GB change in free space")
    // Nothing was skipped or failed, so nothing may be listed as unfinished — a list built
    // from every entry would show five rows that all went through.
    #expect(summary.unfinished.isEmpty)
    #expect(RunSummaryModel.threeNumbers
        == "Those are three separate numbers. Trashing moves bytes; it does not release them.")
}

/// `ByteText.short` clamps a negative to zero, which is right for a size and wrong here:
/// a run that left the disk busier must not read "0 KB".
@Test func aFreeSpaceChangeThatWentBackwardsKeepsItsSign() {
    let summary = RunSummaryModel(
        record: record([], before: 100_000_000_000, after: 99_950_000_000), logURL: nil)

    #expect(summary.freeSpaceText.contains("-50 MB"))
}

@Test func theCountsAreSingularWhenThereIsOneOfThem() {
    let summary = RunSummaryModel(
        record: record([entry("hosted", .trashed, bytes: 1_000_000_000)]), logURL: nil)

    #expect(summary.trashedText.contains("1 item"))
    #expect(!summary.trashedText.contains("1 items"))

    // The other line has its own count and its own plural, and the two counts differ so a
    // line reading the wrong one shows.
    let devices = RunSummaryModel(
        record: record([
            entry("iPhone 17", .deleted, bytes: 12_860_000_000),
            entry("hosted", .trashed, bytes: 1), entry("Yarn", .trashed, bytes: 1),
        ]),
        logURL: nil)

    #expect(devices.permanentText.contains("1 item"))
    #expect(!devices.permanentText.contains("1 items"))
    #expect(devices.trashedText.contains("2 items"))
}

/// The note whole, not `contains("40.2 GB")`.
///
/// The number alone is satisfied by any sentence with the number in it, and the sentence is
/// the part that matters here: trashing moved the bytes and did not release them, so a user
/// who reads only the amount goes looking for 40.2 GB of free space that is not there. The
/// second half — "until you do, that space is still in use" — is the whole point of showing
/// the note at all.
@Test func theEmptyTrashNoteAppearsOnlyWhenSomethingWasTrashed() throws {
    let with = RunSummaryModel(
        record: record([entry("hosted", .trashed, bytes: 40_200_000_000)]), logURL: nil)
    let note = try #require(with.emptyTrashNote)
    #expect(note == "Empty the Trash to actually free the 40.2 GB it now holds. "
        + "Until you do, that space is still in use.")

    let without = RunSummaryModel(
        record: record([entry("iPhone 17", .deleted, bytes: 1)]), logURL: nil)
    #expect(without.emptyTrashNote == nil)
}

/// The Trash holds the trashed bytes and nothing else. A simulator deleted by `simctl` is
/// already gone, so counting it here would send the user to empty the Trash for 12.9 GB
/// that is not in it — 40.2 GB, never 53.1 GB.
@Test func theEmptyTrashNoteNamesTheTrashedBytesAlone() throws {
    let summary = RunSummaryModel(
        record: record([
            entry("hosted", .trashed, bytes: 40_200_000_000),
            entry("iPhone 17", .deleted, bytes: 12_900_000_000),
        ]),
        logURL: nil)

    let note = try #require(summary.emptyTrashNote)
    #expect(note.contains("40.2 GB"))
    #expect(!note.contains("53.1 GB"))
    #expect(!note.contains("12.9 GB"))
}

/// A silent "skipped" is useless. On a machine with emulators but no `platform-tools`
/// every emulator row is skipped and the run frees about 14 GB less than the plan said —
/// the reason names what to install.
@Test func everySkippedAndFailedRowKeepsItsReason() {
    let summary = RunSummaryModel(
        record: record([
            entry("sample_emulator_1", .skipped,
                  reason: "adb could not be run at /sdk/platform-tools/adb"),
            entry("Archives", .failed, reason: "refused: it is protected (pinned)"),
        ]),
        logURL: nil)

    #expect(summary.unfinished.count == 2)
    #expect(summary.unfinished.first?.contains("adb could not be run") == true)
    #expect(summary.unfinished.first?.contains("sample_emulator_1") == true)
    #expect(summary.unfinished.last?.contains("refused") == true)

    // Both lines whole, and in this order. `contains` alone leaves two ways to be wrong:
    // a truncated reason keeps "adb could not be run" and loses `/sdk/platform-tools/adb`,
    // which is the part the user acts on; and the skipped-before-failed order is invisible
    // while the fixture happens to be written in that order. One equality pins both.
    #expect(summary.unfinished == [
        "sample_emulator_1: adb could not be run at /sdk/platform-tools/adb",
        "Archives: refused: it is protected (pinned)",
    ])
}

@Test func theRunsOwnNotesAreShown() {
    let summary = RunSummaryModel(
        record: record([], notes: [Executor.Note.devicesWereRemovedPermanently]),
        logURL: nil)

    #expect(summary.notes == [Executor.Note.devicesWereRemovedPermanently])
}

/// Spec §8.2 asks for a link to the run log. If the run log could not be written, the
/// newest file on disk belongs to some **earlier** run, and offering it would show the
/// user the wrong list at the one moment the list matters.
@Test func theLogLinkIsWithheldWhenTheRunCouldNotBeSaved() {
    let url = URL(fileURLWithPath: "/tmp/runs/20260810-090000.json")

    let saved = RunSummaryModel(record: record([]), logURL: url)
    #expect(saved.logURL == url)

    let lost = RunSummaryModel(
        record: record([], notes: [CleanerService.runLogNotWritten + "disk full"]),
        logURL: url)
    #expect(lost.logURL == nil)
    #expect(lost.notes.first?.hasPrefix(CleanerService.runLogNotWritten) == true)

    // Only *that* note withholds the link. Most runs carry a note — every run that removed
    // a device does — and withholding the link from all of them would hide the history from
    // the runs that most need it, with every test above still green.
    let noted = RunSummaryModel(
        record: record([], notes: [Executor.Note.devicesWereRemovedPermanently]),
        logURL: url)
    #expect(noted.logURL == url)
}

@Test func aCancelledRunSaysSoThroughItsNotes() {
    let summary = RunSummaryModel(
        record: record(
            [entry("CocoaPods", .skipped, reason: Executor.cancelledReason)],
            notes: [Executor.Note.runWasCancelled]),
        logURL: nil)

    #expect(summary.notes.contains(Executor.Note.runWasCancelled))
    #expect(summary.unfinished.first?.contains("you cancelled") == true)
}
